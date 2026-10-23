"""Verify private uploaded source in Cloud, without sending worker identity to it."""
from datetime import datetime,timezone
import hashlib
from pathlib import Path
import shutil
from urllib.parse import urlsplit
import urllib.request

import platform_worker as platform
import worker


def download_upload(claim,root,deadline,heartbeat):
    root=Path(root);destination=root/'uploaded-source.media';verified=root/'uploaded-source-verified.json'
    if claim.get('source_kind')!='upload':raise ValueError('upload_source_claim_required')
    expected=claim['source_sha256'];size=claim['source_bytes'];duration=claim['source_duration']
    if not 0<size<=4*1024**3 or not 0<duration<=21600:raise ValueError('uploaded_source_bounds_invalid')
    offset=claim.get('original_offset',0)
    if offset<0 or offset+duration>21600:raise ValueError('uploaded_source_offset_invalid')
    if verified.exists():
        saved=worker.read(verified)
        if saved['sha256']!=expected or worker.digest(destination)!=expected or saved['origin_start']!=offset:
            raise ValueError('cached_uploaded_source_changed')
        return destination
    if destination.exists():raise ValueError('unverified_cached_upload_requires_review')
    expiry=datetime.fromisoformat(claim['source_expires_at'])
    if expiry.tzinfo is None or expiry<=datetime.now(timezone.utc):raise ValueError('uploaded_source_urls_expired')
    if shutil.disk_usage(root).free<size+1024**3:raise ValueError('insufficient_upload_download_disk')
    sources=claim['sources']
    if len(sources)!=(size+4*1024**2-1)//(4*1024**2):raise ValueError('source_part_count_mismatch')
    pending=root/'uploaded-source.pending';digest=hashlib.sha256();total=0
    # This opener has inherited proxy/CA and redirect refusal but no API identity,
    # cookies or gateway header. A signed source URL itself is the capability.
    http=platform.opener()
    try:
        with pending.open('wb') as out:
            for index,part in enumerate(sources,1):
                deadline.remaining();heartbeat()
                parsed=urlsplit(part['url'])
                if (parsed.scheme!='https' or parsed.hostname!=platform.HOST or
                    parsed.username or parsed.password or parsed.fragment or parsed.port not in (None,443)):
                    raise ValueError('uploaded_source_url_host_rejected')
                if part['index']!=index or not 0<part['byte_size']<=4*1024**2:
                    raise ValueError('source_part_order_or_size_invalid')
                request=urllib.request.Request(part['url'],method='GET')
                with http.open(request,timeout=min(60,deadline.remaining())) as response:
                    if response.status!=200:raise ValueError('source_download_not_successful')
                    raw=response.read(part['byte_size']+1)
                if len(raw)!=part['byte_size']:raise ValueError('source_part_size_mismatch')
                out.write(raw);digest.update(raw);total+=len(raw)
            out.flush()
            __import__('os').fsync(out.fileno())
        if total!=size or digest.hexdigest()!=expected:raise ValueError('uploaded_source_full_hash_mismatch')
        actual_duration=worker.probe(pending)
        if abs(actual_duration-duration)>3:raise ValueError('uploaded_source_duration_mismatch')
        pending.replace(destination)
        worker.save(verified,{'sha256':expected,'bytes':total,'duration':actual_duration,
                    'origin_start':offset,'origin_end':offset+actual_duration,
                    'timeline_duration':offset+actual_duration,'is_topic_only':claim.get('source_is_topic_only',False),
                    'source_kind':'private_upload','youtube_url':claim.get('source_url'),
                    'cloud_full_sha_verified':True})
        return destination
    except BaseException:
        pending.unlink(missing_ok=True);raise


def capture_upload(root,selection,deadline):
    """Cut only a reviewed range from the fully SHA-verified private input."""
    from clip_pipeline import _selection_rows
    root=Path(root);record=worker.read(root/'uploaded-source-verified.json')
    source=root/'uploaded-source.media'
    if worker.digest(source)!=record['sha256']:raise ValueError('uploaded_source_changed')
    _selection_rows(worker.read(root/'transcript.json'),selection,record['timeline_duration'])
    if selection['transcript_sha256']!=worker.digest(root/'transcript.json'):
        raise ValueError('uploaded_selection_transcript_changed')
    start=selection['start']-record['origin_start'];end=selection['end']-record['origin_start']
    if not 0<=start<end<=record['duration']:raise ValueError('selection_outside_uploaded_material')
    if shutil.disk_usage(root).free<3*1024**3:raise ValueError('insufficient_selected_capture_disk')
    if (root/'source.mp4').exists():raise ValueError('selected_source_exists_do_not_replace')
    deadline.run(['ffmpeg','-v','error','-y','-ss',str(start),'-i',str(source),'-t',str(end-start),
                  '-map','0:v:0','-map','0:a:0','-vf',"scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",
                  '-c:v','libx264','-preset','veryfast','-crf','21','-maxrate','1600k','-bufsize','3200k',
                  '-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-movflags','+faststart',str(root/'source.mp4')])
    target=root/'source.mp4';duration=worker.probe(target)
    if target.stat().st_size>1024**3 or abs(duration-(end-start))>.3:raise ValueError('selected_capture_size_or_duration_mismatch')
    worker.save(root/'source-verified.json',{'sha256':worker.digest(target),'bytes':target.stat().st_size,
                'duration':duration,'origin_start':selection['start'],'origin_end':selection['end'],
                'timeline_duration':record['timeline_duration'],'uploaded_source_sha256':record['sha256'],
                'source_sha_scope':'complete_selected_source_file'})
    return target

