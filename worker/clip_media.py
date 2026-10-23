"""New clip RPC and bounded media transport; never uses the old trial RPC.

No CLI auto-execution. Main task must deploy/test the contract before wiring a
real exact-job run. Unknown paid reservation/publish outcomes are not retried.
"""
import base64
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import re
import threading
import urllib.error
import urllib.request
from uuid import UUID,uuid4

import platform_worker as platform
import worker

API='https://'+platform.HOST+'/v1/rdb/rest/rpc/st_cloud_clip_call'
PART_BYTES=4*1024**2
SMALL_FILES=platform.REQUIRED_FILES+('selection.json',)


class ClipClient:
    def __init__(self):
        if not os.environ.get('SUBTITLE_PLATFORM_TOKEN'):raise platform.ConfigurationMissing('dedicated_worker_identity_missing')
        platform.gateway_key()
        self.http=platform.opener()

    def call(self,action,job,payload=None):
        UUID(str(job))
        if action not in ('claim','heartbeat','reserve_request','record_selection','reserve_media',
                          'read_part','finish_media','publish','stop'):
            raise platform.PlatformError('invalid_clip_action')
        key=os.environ['SUBTITLE_PLATFORM_TOKEN'];gateway=platform.gateway_key()
        request=urllib.request.Request(API,data=json.dumps({'p_key':key,'p_action':action,
            'p_job':str(job),'p_payload':payload or {}}).encode(),method='POST',
            headers={'Content-Type':'application/json','Authorization':'Bearer '+gateway})
        try:
            with self.http.open(request,timeout=30) as response:
                if response.status!=200:raise platform.PlatformUnavailable('clip_rpc_http_failure')
                raw=response.read(3_000_001)
        except Exception:
            raise platform.PlatformUnavailable('clip_rpc_unavailable_no_automatic_retry') from None
        if len(raw)>3_000_000 or key.encode() in raw or gateway.encode() in raw:
            raise platform.PlatformUnavailable('clip_rpc_response_rejected')
        try:data=json.loads(raw)
        except ValueError:raise platform.PlatformUnavailable('clip_rpc_invalid_json') from None
        if not isinstance(data,dict) or data.get('error') or data.get('code'):
            raise platform.PlatformUnavailable('clip_rpc_unrecognized_response')
        return data

    def object_request(self,method,name,capability,mime=None,data=None):
        if not re.fullmatch(r'cloud-clips/[0-9a-f]{64}/part-[0-9]{6}',name):
            raise ValueError('invalid_exact_part_path')
        if name.rsplit('/',1)[0]!=capability:raise ValueError('part_capability_mismatch')
        headers={'Authorization':'Bearer '+platform.gateway_key(),
                 'x-cloud-clip-object':name,'x-cloud-clip-capability':capability,
                 'x-cloud-clip-worker':os.environ['SUBTITLE_PLATFORM_TOKEN'],
                 'x-upsert':'false'}
        if mime:headers['Content-Type']=mime
        request=urllib.request.Request('https://'+platform.HOST+
          '/v1/storages/object/subtitle-deliveries/'+name,method=method,data=data,headers=headers)
        try:return self.http.open(request,timeout=180)
        except Exception:raise platform.PlatformUnavailable('clip_media_http_unavailable_do_not_overwrite') from None


class ClipLease:
    def __init__(self,client,claim,control):
        self.client=client;self.claim=claim;self.control=Path(control)
        self.lock=threading.Lock();self.failure=None;self.ended=threading.Event()
        self.thread=None
        for marker in (self.control/'reservations').glob('*.json'):
            if worker.read(marker).get('state')=='submitted_or_unknown':
                raise platform.ReconciliationRequired('unknown_reservation_requires_reconciliation')

    def payload(self,**values):return {'lease_id':self.claim['lease_id'],**values}

    def heartbeat(self):
        with self.lock:
            if self.failure:raise self.failure
            try:
                result=self.client.call('heartbeat',self.claim['job_id'],self.payload())
                if result.get('state')!='running' or result.get('lease_seconds')!=2700:
                    raise platform.LeaseLost('clip_heartbeat_not_confirmed')
                worker.save(self.control/'heartbeat-counts.json',{
                    'text':result['text_requests'],'qwen':result['qwen_requests']})
                return result
            except Exception as error:
                self.failure=error;raise

    def reserve(self,provider):
        self.heartbeat()
        request_id=str(uuid4())
        marker=self.control/'reservations'/(request_id+'.json')
        worker.save(marker,{'state':'submitted_or_unknown','provider':provider})
        try:
            result=self.client.call('reserve_request',self.claim['job_id'],
                                    self.payload(provider=provider,request_id=request_id))
        except Exception as error:
            self.failure=error
            raise
        if result.get('state')!='reserved_once' or result.get('request_id')!=request_id:
            self.failure=platform.PlatformUnavailable('reservation_not_confirmed_do_not_send')
            raise self.failure
        worker.save(marker,{'state':'reserved_once','provider':provider})

    def _loop(self):
        while not self.ended.wait(40):
            try:self.heartbeat()
            except Exception:return

    def __enter__(self):
        self.heartbeat();self.thread=threading.Thread(target=self._loop,daemon=True);self.thread.start();return self

    def __exit__(self,*unused):
        self.ended.set()
        if self.thread:self.thread.join(timeout=35)


def upload_media(client,claim,control,path,role,deadline,heartbeat):
    path=Path(path);control=Path(control)
    if path.is_symlink() or not path.is_file():raise ValueError('regular_media_file_required')
    mime='image/png' if role=='cover' else 'video/mp4'
    size=path.stat().st_size
    if not 0<size<=1024**3 or (role=='cover' and size>10_000_000):raise ValueError('media_size_exceeded')
    full_sha=worker.digest(path)
    specification={'lease_id':claim['lease_id'],'role':role,'filename':path.name,'mime':mime,
                   'bytes':size,'sha256':full_sha}
    folder=control/'media'/role
    plan_file=folder/'reservation.json'
    if plan_file.exists():
        saved=worker.read(plan_file)
        if saved['specification']!=specification:raise ValueError('media_specification_changed')
        plan=saved['plan']
    else:
        heartbeat()
        plan=client.call('reserve_media',claim['job_id'],specification)
        if plan.get('state')!='media_reserved' or plan.get('part_bytes')!=PART_BYTES or plan.get('overwrite') is not False:
            raise ValueError('media_reservation_not_confirmed')
        worker.save(plan_file,{'specification':specification,'plan':plan})
    expiry=datetime.fromisoformat(plan['expires_at'])
    if expiry.tzinfo is None or expiry<=datetime.now(timezone.utc):raise ValueError('media_capability_expired')
    parts=plan['parts']
    if len(parts)!=(size+PART_BYTES-1)//PART_BYTES:raise ValueError('media_part_count_mismatch')
    with path.open('rb') as stream:
        for i,part in enumerate(parts,1):
            deadline.remaining();heartbeat()
            raw=stream.read(PART_BYTES)
            if part['index']!=i or part['bytes']!=len(raw):raise ValueError('media_part_layout_mismatch')
            marker=folder/f'part-{i:06}.json'
            digest=hashlib.sha256(raw).hexdigest()
            if marker.exists():
                state=worker.read(marker)
                if state.get('state')!='uploaded' or state.get('sha256')!=digest:
                    raise platform.ReconciliationRequired('unknown_part_upload_do_not_overwrite')
                continue
            worker.save(marker,{'state':'submitted_or_unknown','sha256':digest,'bytes':len(raw)})
            with client.object_request('POST',part['object_name'],plan['capability'],mime,raw) as response:
                if response.status not in (200,201):raise platform.PlatformUnavailable('part_upload_not_confirmed')
                response.read(10000)
            worker.save(marker,{'state':'uploaded','sha256':digest,'bytes':len(raw)})
    # Read actual stored bytes once, in order, and hash the entire concatenation.
    accumulated=hashlib.sha256();total=0
    for part in parts:
        deadline.remaining();heartbeat()
        read_plan=client.call('read_part',claim['job_id'],{'lease_id':claim['lease_id'],
                              'media_id':plan['media_id'],'index':part['index']})
        if (read_plan.get('state')!='read_part_ready' or read_plan.get('object_name')!=part['object_name'] or
                read_plan.get('bytes')!=part['bytes']):raise ValueError('readback_part_identity_mismatch')
        with client.object_request('GET',part['object_name'],plan['capability']) as response:
            if response.status!=200:raise ValueError('readback_not_successful')
            raw=response.read(part['bytes']+1)
        if len(raw)!=part['bytes']:raise ValueError('readback_part_size_mismatch')
        local=worker.read(folder/f"part-{part['index']:06}.json")
        if hashlib.sha256(raw).hexdigest()!=local['sha256']:raise ValueError('readback_part_hash_mismatch')
        accumulated.update(raw);total+=len(raw)
    if total!=size or accumulated.hexdigest()!=full_sha:raise ValueError('readback_full_hash_mismatch')
    result=client.call('finish_media',claim['job_id'],{'lease_id':claim['lease_id'],
        'media_id':plan['media_id'],'worker_verified_sha256':full_sha})
    if result.get('state')!='worker_sha_verified' or result.get('worker_sha_verified') is not True:
        raise ValueError('media_finish_not_confirmed')
    worker.save(folder/'finished.json',{'media_id':plan['media_id'],'worker_sha_verified':True,
                'server_sha_verified':False,'sha256':full_sha,'bytes':size})
    return plan['media_id']


def publish(client,claim,control,delivery):
    control=Path(control);delivery=Path(delivery)
    state_file=control/'publish-state.json';payload_file=control/'publish-payload.json'
    if state_file.exists() and worker.read(state_file).get('state')=='published':return worker.read(state_file)
    if payload_file.exists():payload=worker.read(payload_file)
    else:
        files=[];total=0
        for name in SMALL_FILES:
            path=delivery/name
            if path.is_symlink() or not path.is_file():raise ValueError('small_delivery_file_missing')
            raw=path.read_bytes();total+=len(raw)
            if len(raw)>500000 or total>2000000:raise ValueError('small_delivery_bundle_limit')
            files.append({'name':name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),
                          'base64':base64.b64encode(raw).decode()})
        payload={'lease_id':claim['lease_id'],'files':files}
        worker.save(payload_file,payload)
    worker.save(state_file,{'state':'submitted_or_unknown'})
    try:
        result=client.call('publish',claim['job_id'],payload)
        if result.get('state')!='succeeded':raise ValueError('publish_not_confirmed')
        UUID(result['delivery_id'])
    except Exception:raise platform.ReconciliationRequired('clip_publish_unknown_reconcile_exact_payload_only') from None
    state={'state':'published','job_id':claim['job_id'],'delivery_id':result['delivery_id']}
    worker.save(state_file,state);return state

