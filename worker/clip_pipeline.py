"""Cloud-only public YouTube preparation and local clip rendering.

No provider calls or website publishing in this entrypoint. Private metadata,
transcripts, downloads and rendered media stay outside the source checkout.
"""
import argparse
import html
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from urllib.parse import parse_qs, urlsplit
import urllib.error
import urllib.request

import billing
import worker

YT_VERSION = '2026.8.19'
TERMS = ('浮気判定', '浮気', 'どこから')
FONT = Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc')
FONT_LICENSE = Path('/usr/share/doc/fonts-noto-cjk/copyright')
ROOT = Path('/workspace/subtitle-clips')


def canonical_url(value):
    p = urlsplit(value)
    if (p.scheme != 'https' or p.hostname not in ('www.youtube.com','youtube.com','youtu.be')
            or p.username or p.password or p.port not in (None,443)):
        raise ValueError('public_youtube_https_url_required')
    if p.hostname == 'youtu.be':
        ident = p.path.strip('/')
    elif p.path == '/watch':
        ident = parse_qs(p.query).get('v',[''])[0]
    elif p.path.startswith(('/live/','/shorts/')):
        ident = p.path.split('/')[2]
    else:
        raise ValueError('unsupported_youtube_url')
    if not re.fullmatch(r'[A-Za-z0-9_-]{11}',ident):
        raise ValueError('invalid_video_id')
    return ident, 'https://www.youtube.com/watch?v='+ident


def private_root(path):
    path = Path(path).resolve()
    if not path.is_relative_to(ROOT) or path == ROOT:
        raise ValueError('clip_state_requires_separate_cloud_directory')
    path.mkdir(parents=True,exist_ok=True,mode=0o700)
    path.chmod(0o700)
    return path


class Deadline:
    def __init__(self, seconds=7200):
        if not 1 <= seconds <= 14400:
            raise ValueError('process_deadline_out_of_range')
        self.end = time.monotonic()+seconds

    def remaining(self):
        left = self.end-time.monotonic()
        if left <= 0:
            raise TimeoutError('process_deadline_exceeded')
        return left

    def run(self,args,**kwargs):
        return subprocess.run(args,check=True,timeout=self.remaining(),
                              stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,**kwargs)


class SafeLog:
    def debug(self,*unused): pass
    def warning(self,*unused): pass
    def error(self,*unused): pass


def ydl_options(deadline):
    if importlib.metadata.version('yt-dlp') != YT_VERSION:
        raise ValueError('pinned_yt_dlp_required')
    return {'logger':SafeLog(),'quiet':True,'noplaylist':True,
            'retries':0,'extractor_retries':0,'fragment_retries':0,
            'socket_timeout':min(25,deadline.remaining()),'cachedir':False,
            'remote_components':set(),'js_runtimes':{'node':{'path':shutil.which('node') or 'node'}},
            'cookiefile':None,'cookiesfrombrowser':None,
            'progress_hooks':[lambda _:deadline.remaining()]}


def probe(url,root,deadline):
    ident,url = canonical_url(url)
    # First normal page request distinguishes proxy denial from YouTube auth.
    request=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(request,timeout=min(25,deadline.remaining())) as response:
            response.read(1024)
    except urllib.error.URLError as error:
        policy_denied='Tunnel connection failed: 403' in str(error.reason)
        result={'state':'network_policy_blocked' if policy_denied else 'access_unavailable',
                'video_id':ident,'attempted_host':'www.youtube.com',
                'actually_blocked_hosts':['www.youtube.com'] if policy_denied else [],
                'title':None,'duration':None,'subtitle_availability':'unknown'}
        worker.save(root/'probe.json',result)
        return result
    from yt_dlp import YoutubeDL
    try:
        with YoutubeDL(ydl_options(deadline)) as ydl:
            info=ydl.extract_info(url,download=False)
    except Exception:
        # No alternate clients, cookies, impersonation, tokens or auth bypass.
        result={'state':'extraction_unavailable','video_id':ident,
                'title':None,'duration':None,'subtitle_availability':'unknown'}
        worker.save(root/'probe.json',result)
        return result
    if info.get('id') != ident:
        raise ValueError('source_video_identity_mismatch')
    if info.get('availability') not in (None,'public','unlisted') or info.get('is_live'):
        raise ValueError('source_not_public_completed_video')
    duration=info.get('duration')
    if not source_duration_allowed(duration):
        raise ValueError('source_duration_missing_or_over_six_hours_report_first')
    worker.save(root/'source-info.private.json',info)
    result={'state':'metadata_ready','video_id':ident,'title':info.get('title'),
            'duration':duration,'subtitles':list(info.get('subtitles',{})),
            'automatic_captions':list(info.get('automatic_captions',{})),
            'extractor_version':YT_VERSION}
    worker.save(root/'probe.json',result)
    return result


def source_duration_allowed(duration):
    return type(duration) in (float,int) and math.isfinite(duration) and 0<duration<=21600


def caption_rows(data):
    """YouTube json3: collapse rolling caption duplicates without inventing text."""
    result=[]
    for event in data.get('events',[]):
        text=html.unescape(''.join(s.get('utf8','') for s in event.get('segs',[]))).strip()
        if not text: continue
        text=re.sub(r'<[^>]*>','',text).replace('\n',' ').strip()
        start=event.get('tStartMs',0)/1000
        end=start+event.get('dDurationMs',0)/1000
        if end <= start: continue
        if result and text==result[-1]['text']:
            result[-1]['end']=max(result[-1]['end'],end)
            continue
        result.append({'id':len(result)+1,'start':start,'end':end,'text':text})
    worker.validate_cues(result)
    return result


def captions(root,deadline):
    info=worker.read(root/'source-info.private.json')
    options=[]
    for kind in ('subtitles','automatic_captions'):
        for lang,formats in info.get(kind,{}).items():
            if lang not in ('ja','ja-orig'): continue
            options.extend((kind,lang,f) for f in formats if f.get('ext')=='json3')
    if not options:
        worker.save(root/'caption-status.json',{'state':'no_japanese_captions_use_cloud_whisper'})
        return False
    kind,lang,fmt=options[0]
    u=urlsplit(fmt['url'])
    if u.scheme!='https' or u.hostname not in ('www.youtube.com','youtube.com'):
        raise ValueError('unexpected_caption_host_report_for_policy_review')
    with urllib.request.urlopen(fmt['url'],timeout=min(25,deadline.remaining())) as response:
        raw=response.read(30_000_001)
    if len(raw)>30_000_000:raise ValueError('caption_size_exceeded')
    rows=caption_rows(json.loads(raw))
    worker.validate_cues(rows,info['duration'])
    worker.save(root/'transcript.json',rows)
    worker.save(root/'transcript-provenance.json',{'kind':kind,'language':lang,
                'video_id':info['id'],'caption_sha256':__import__('hashlib').sha256(raw).hexdigest()})
    return True


def download_source(url,root,deadline,selection):
    ident,url=canonical_url(url)
    info=worker.read(root/'source-info.private.json')
    if info['id']!=ident:raise ValueError('source_video_identity_mismatch')
    # Public transcript is available before acquisition: verify reviewed absolute
    # boundaries, then acquire ONLY this range, never the full livestream.
    if not source_duration_allowed(info['duration']):raise ValueError('source_duration_over_six_hours')
    selected=_selection_rows(worker.read(root/'transcript.json'),selection,info['duration'])
    if selection.get('transcript_sha256')!=worker.digest(root/'transcript.json'):
        raise ValueError('selection_transcript_changed')
    source=root/'source.mp4'; marker=root/'source-verified.json'
    if marker.exists():
        if worker.digest(source)!=worker.read(marker)['sha256']:
            raise ValueError('cached_source_changed')
        if (worker.read(marker).get('origin_start'),worker.read(marker).get('origin_end')) != (selection['start'],selection['end']):
            raise ValueError('cached_source_range_changed')
        return source
    if source.exists():raise ValueError('unverified_source_requires_review')
    if shutil.disk_usage(root).free < 4*1024**3:raise ValueError('insufficient_cloud_disk')
    from yt_dlp import YoutubeDL
    from yt_dlp.utils import download_range_func
    opts=ydl_options(deadline)
    opts.update({'format':'bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]',
                 'outtmpl':str(root/'source.%(ext)s'),'merge_output_format':'mp4',
                 'max_filesize':1024**3,'overwrites':False,
                 'download_ranges':download_range_func(None,[(selection['start'],selection['end'])]),
                 'force_keyframes_at_cuts':True})
    def bound(progress):
        deadline.remaining()
        if progress.get('downloaded_bytes',0)>1024**3 or shutil.disk_usage(root).free<1024**3:
            raise ValueError('source_download_size_or_disk_limit')
    opts['progress_hooks']=[bound]
    with YoutubeDL(opts) as ydl:ydl.download([url])
    if not source.is_file() or source.stat().st_size>1024**3:
        raise ValueError('source_missing_or_oversized')
    duration=worker.probe(source)
    if abs(duration-(selection['end']-selection['start']))>2:
        raise ValueError('download_duration_mismatch')
    worker.save(marker,{'video_id':ident,'sha256':worker.digest(source),
                       'bytes':source.stat().st_size,'duration':duration,
                       'timeline_duration':info['duration'],'origin_start':selection['start'],
                       'origin_end':selection['end'],'source_sha_scope':'complete_downloaded_selected_range_not_whole_livestream'})
    return source


def scan(root,deadline):
    if (root/'source-verified.json').exists():
        source=root/'source.mp4'; identity=worker.read(root/'source-verified.json')
    elif (root/'uploaded-source-verified.json').exists():
        source=root/'uploaded-source.media';identity=worker.read(root/'uploaded-source-verified.json')
    else:
        source=root/'scan-input.media';identity=worker.read(root/'scan-source-verified.json')
    if worker.digest(source)!=identity['sha256']:raise ValueError('source_checksum_mismatch')
    from runtime import model_ready
    ready=model_ready(load=True)
    if not ready['ready']:raise ValueError('pinned_cloud_whisper_not_ready')
    from faster_whisper import WhisperModel
    model=WhisperModel('/workspace/subtitle-models/large-v3-turbo',device='cpu',
                      compute_type='int8',cpu_threads=2,num_workers=1,local_files_only=True)
    import numpy as np
    import wave
    rows=[]
    for start in range(0,math.ceil(identity['duration']),120):
        deadline.remaining()
        checkpoint=root/'scan'/f'{start:06}.json'
        if checkpoint.exists():
            saved=worker.read(checkpoint)
            if saved['source_sha256']!=identity['sha256']:raise ValueError('scan_identity_changed')
            rows.extend(saved['rows']);continue
        audio=root/'scan'/f'{start:06}.wav';audio.parent.mkdir(exist_ok=True)
        deadline.run(['ffmpeg','-v','error','-y','-ss',str(start),'-i',str(source),
                      '-t',str(min(120,identity['duration']-start)),'-vn','-ac','1','-ar','16000',str(audio)])
        with wave.open(str(audio),'rb') as stream:
            pcm=np.frombuffer(stream.readframes(stream.getnframes()),dtype=np.int16).astype(np.float32)/32768
        segments,_=model.transcribe(pcm,language='ja',vad_filter=True,beam_size=5)
        part=[]
        for segment in segments:
            deadline.remaining()
            if segment.text.strip():
                offset=identity.get('origin_start',0)
                part.append({'id':len(rows)+len(part)+1,'start':offset+start+segment.start,
                             'end':offset+min(identity['duration'],start+segment.end),'text':segment.text.strip(),
                             'avg_logprob':segment.avg_logprob,'no_speech_prob':segment.no_speech_prob,
                             'review':segment.avg_logprob<-.8 or segment.no_speech_prob>.6})
        worker.save(checkpoint,{'source_sha256':identity['sha256'],'rows':part})
        rows.extend(part);audio.unlink()
    worker.validate_cues(rows,identity.get('timeline_duration',identity['duration']))
    worker.save(root/'whisper-transcript.json',rows)
    worker.save(root/'whisper-provenance.json',{'kind':'cloud_whisper_scan',
                'source_sha256':identity['sha256'],'revision':ready['revision'],
                'uploaded_source_sha256':identity.get('uploaded_source_sha256'),
                'chunk_seconds':120,'coverage_start':identity.get('origin_start',0),
                'coverage_end':identity.get('origin_end',identity['duration']),
                'chunk_boundaries_need_context_review':True})
    if not (root/'transcript.json').exists():
        worker.save(root/'transcript.json',rows)
        worker.save(root/'transcript-provenance.json',worker.read(root/'whisper-provenance.json'))


def download_scan_audio(url,root,deadline):
    """Captionless fallback: bounded audio only, never full HD stream download."""
    ident,url=canonical_url(url);info=worker.read(root/'source-info.private.json')
    if info['id']!=ident or not source_duration_allowed(info['duration']):raise ValueError('invalid_scan_source')
    if (root/'scan-source-verified.json').exists():raise ValueError('scan_source_exists_use_checkpoint')
    if shutil.disk_usage(root).free<2*1024**3:raise ValueError('insufficient_scan_disk')
    from yt_dlp import YoutubeDL
    opts=ydl_options(deadline)
    opts.update({'format':'bestaudio[abr<=96]/bestaudio','outtmpl':str(root/'scan-input.%(ext)s'),
                 'max_filesize':512*1024**2,'overwrites':False})
    def bound(progress):
        deadline.remaining()
        if progress.get('downloaded_bytes',0)>512*1024**2 or shutil.disk_usage(root).free<1024**3:
            raise ValueError('scan_audio_size_or_disk_limit')
    opts['progress_hooks']=[bound]
    with YoutubeDL(opts) as ydl:
        downloaded=ydl.extract_info(url,download=True)
        path=Path(ydl.prepare_filename(downloaded))
    if not path.is_file() or path.stat().st_size>512*1024**2:raise ValueError('scan_audio_missing_or_oversized')
    target=root/'scan-input.media';path.replace(target)
    duration=worker.probe(target)
    if abs(duration-info['duration'])>3:raise ValueError('scan_audio_duration_mismatch')
    worker.save(root/'scan-source-verified.json',{'video_id':ident,'sha256':worker.digest(target),
                'bytes':target.stat().st_size,'duration':duration,'source_kind':'full_stream_audio_only'})


def transcript_path(root,selection):
    return root/('whisper-transcript.json' if selection.get('transcript_kind')=='whisper' else 'transcript.json')


def candidates(rows):
    worker.validate_cues(rows)
    ranked=[]
    for i,row in enumerate(rows):
        matched=[term for term in TERMS if term in row['text']]
        # "どこから" alone does not establish the infidelity topic.
        if not any('浮気' in rows[k]['text'] for k in range(max(0,i-4),min(len(rows),i+5))):continue
        if not matched:continue
        lo=i
        while lo>0 and row['start']-rows[lo]['start']<45:lo-=1
        hi=i
        while hi+1<len(rows) and rows[hi]['end']-row['end']<100:hi+=1
        score=10*('浮気判定' in matched)+3*('浮気' in matched)+('どこから' in matched)
        ranked.append({'start':rows[lo]['start'],'end':rows[hi]['end'],
                       'anchor_id':row['id'],'score':score,'matched_terms':matched,
                       'context_cue_ids':[r['id'] for r in rows[lo:hi+1]],
                       'state':'candidate_requires_topic_and_boundary_review'})
    ranked.sort(key=lambda c:(-c['score'],c['start']))
    unique=[]
    for item in ranked:
        if not any(abs(item['start']-r['start'])<30 for r in unique):unique.append(item)
    return unique[:10]


def validate_selection(root,selection):
    transcript=transcript_path(root,selection)
    rows=worker.read(transcript);worker.validate_cues(rows)
    source=worker.read(root/'source-verified.json')
    if (selection.get('source_sha256')!=source['sha256'] or
            selection.get('transcript_sha256')!=worker.digest(transcript)):
        raise ValueError('selection_identity_mismatch')
    return _selection_rows(rows,selection,source.get('timeline_duration',source['duration']))


def _selection_rows(rows,selection,duration):
    if (selection.get('topic_confirmed') is not True or
            selection.get('complete_exchange_confirmed') is not True or
            not selection.get('boundary_reason') or not selection.get('reviewed_by')):
        raise ValueError('topic_and_complete_exchange_review_required')
    a,b=selection.get('start'),selection.get('end')
    if (type(a) not in (float,int) or type(b) not in (float,int) or
            not math.isfinite(a) or not math.isfinite(b) or not 0<=a<b<=duration):
        raise ValueError('invalid_selection_times')
    if b-a>4200:raise ValueError('clip_over_authorized_4200_seconds')
    # No speech cue may be cut in half at either boundary.
    if any(r['start']+.05<a<r['end']-.05 or r['start']+.05<b<r['end']-.05 for r in rows):
        raise ValueError('selection_cuts_speech_cue')
    selected=[r for r in rows if r['start']>=a-.05 and r['end']<=b+.05]
    if not any('浮気' in r['text'] for r in selected):raise ValueError('topic_not_found')
    return [dict(r,id=i+1,start=max(0,r['start']-a),end=min(b-a,r['end']-a))
            for i,r in enumerate(selected)]


def render(root,selection,translated_path,title,deadline):
    selected=validate_selection(root,selection)
    if not FONT.is_file() or not FONT_LICENSE.is_file():raise ValueError('licensed_cjk_font_missing')
    if not re.search(r'[\u3400-\u9fff]',title) or len(title)>26 or '\n' in title:
        raise ValueError('short_accurate_chinese_title_required')
    if selection.get('approved_chinese_title')!=title:raise ValueError('title_not_reviewed_against_topic')
    source=root/'source.mp4'
    if worker.digest(source)!=selection['source_sha256']:raise ValueError('source_checksum_mismatch')
    translated=worker.read(translated_path)
    # Exactly preserve selected Japanese text/timing and translation IDs.
    if len(translated)!=len(selected):raise ValueError('translation_count_changed')
    for expected,actual in zip(selected,translated):
        if any(actual.get(k)!=expected[k] for k in ('id','text','start','end')):
            raise ValueError('translated_source_or_timing_changed')
    worker.merge(selected,[{'id':r['id'],'zh':r.get('zh'),'review':True} for r in translated])
    output=root/'render';output.mkdir(exist_ok=True)
    worker.export(translated,output)
    worker.save(output/'cues.json',translated)
    worker.save(output/'quality.json',worker.quality(translated,selection['end']-selection['start']))
    worker.save(output/'selection.json',selection)
    provenance=worker.read(root/('whisper-provenance.json' if selection.get('transcript_kind')=='whisper' else 'transcript-provenance.json'))
    secondary=root/'paid/secondary-coverage.json'
    provenance['secondary_coverage']=worker.read(secondary) if secondary.exists() else {'intervals':[],'full_segment_dual_asr':False}
    worker.save(output/'recognition-provenance.json',provenance)
    usage_path=root/'paid/usage.json'
    worker.save(output/'usage.json',worker.read(usage_path) if usage_path.exists() else
                {'requests':[],'actual_billing_verified':False,'translation_provenance':'supplied_reviewed_translation'})
    (output/'title.txt').write_text(title,encoding='utf-8')
    # Fixed local basenames keep untrusted filenames/text out of filter syntax.
    source_record=worker.read(root/'source-verified.json')
    local_start=selection['start']-source_record.get('origin_start',0)
    if local_start<0:raise ValueError('selection_not_in_downloaded_range')
    if shutil.disk_usage(root).free<4*1024**3:raise ValueError('insufficient_render_disk')
    base=['ffmpeg','-v','error','-y','-ss',str(local_start),'-i',str(source),
          '-t',str(selection['end']-selection['start'])]
    encoding=['-map','0:v:0','-map','0:a:0','-c:v','libx264','-preset','veryfast',
              '-crf','21','-maxrate','1600k','-bufsize','3200k','-pix_fmt','yuv420p',
              '-c:a','aac','-b:a','128k','-movflags','+faststart']
    deadline.run(base+encoding+['original.mp4'],cwd=output)
    deadline.run(['ffmpeg','-v','error','-y','-i','original.mp4','-vf',
                  'ass=Chinese.ass:fontsdir=/usr/share/fonts/opentype/noto']+encoding+['subtitled.mp4'],cwd=output)
    middle=(selection['end']-selection['start'])/2
    cover_filter=("scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,"
                  "drawbox=x=0:y=510:w=1280:h=210:color=black@0.65:t=fill,"
                  f"drawtext=fontfile={FONT}:textfile=title.txt:expansion=none:fontcolor=white:fontsize=48:"
                  "x=(w-text_w)/2:y=585")
    deadline.run(['ffmpeg','-v','error','-y','-ss',str(middle),'-i','original.mp4',
                  '-vf',cover_filter,'-frames:v','1','cover.png'],cwd=output)
    files=[{'name':p.name,'bytes':p.stat().st_size,'sha256':worker.digest(p)}
           for p in sorted(output.iterdir()) if p.name not in ('manifest.json','title.txt')]
    expected=selection['end']-selection['start']
    for name in ('original.mp4','subtitled.mp4'):
        if (output/name).stat().st_size>1024**3:raise ValueError('render_exceeds_one_gib')
        if abs(worker.probe(output/name)-expected)>.3:raise ValueError('render_duration_mismatch')
    worker.save(output/'manifest.json',{'state':'rendered_not_uploaded','source_sha256':selection['source_sha256'],
                'selection':selection,'cue_count':len(translated),'files':files,
                'cover_frame_seconds_in_clip':middle,'font_license':'Noto CJK SIL OFL 1.1',
                'human_review_required':True,'billing_verified':False})
    return {'state':'rendered_not_uploaded','cue_count':len(translated),'files':len(files)}


def main(argv=None):
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=('probe','prepare','capture','scan-audio','scan','candidates','render'))
    p.add_argument('--url');p.add_argument('--root',required=True)
    p.add_argument('--deadline-seconds',type=int,default=7200)
    p.add_argument('--selection');p.add_argument('--translated');p.add_argument('--title')
    args=p.parse_args(argv)
    try:
        root=private_root(args.root);deadline=Deadline(args.deadline_seconds)
        with billing.exclusive(root/'.clip.lock'):
            if args.action=='probe':result=probe(args.url,root,deadline)
            elif args.action=='prepare':
                # Only prepare after successful probe; no blind retry on access refusal.
                if worker.read(root/'probe.json')['state']!='metadata_ready':raise ValueError('successful_probe_required')
                has_captions=captions(root,deadline)
                result={'state':'captions_checked_source_not_downloaded','japanese_captions_available':has_captions}
            elif args.action=='capture':
                download_source(args.url,root,deadline,worker.read(args.selection))
                result={'state':'selected_range_downloaded_and_hashed'}
            elif args.action=='scan-audio':
                download_scan_audio(args.url,root,deadline)
                result={'state':'scan_audio_downloaded_no_full_video'}
            elif args.action=='scan':
                if (root/'whisper-transcript.json').exists():raise ValueError('whisper_transcript_exists_do_not_replace')
                scan(root,deadline);result={'state':'cloud_scan_completed'}
            elif args.action=='candidates':
                found=candidates(worker.read(root/'transcript.json'))
                worker.save(root/'candidates.json',found)
                result={'state':'candidates_require_review' if found else 'topic_not_found','count':len(found)}
            else:result=render(root,worker.read(args.selection),Path(args.translated),args.title,deadline)
        print(json.dumps(result,ensure_ascii=False));return 0
    except Exception as error:
        print(json.dumps({'state':'stopped','error_type':type(error).__name__,
                          'paid_requests_sent':False,'details':'inspect_private_checkpoint_no_automatic_retry'}));return 1


if __name__=='__main__':raise SystemExit(main())

