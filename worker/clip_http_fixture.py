"""Explicit zero-budget isolated storage HTTP test. Never publishes a delivery.

Requires a main-task supplied exact fixture job with BOTH allowances zero.
Does not create jobs, call providers or probe YouTube. Small PNG is a transport
fixture, never the requested livestream cover or video.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import urllib.error
import urllib.request
from uuid import UUID

from clip_media import ClipClient
from clip_pipeline import Deadline
import platform_worker as platform
import worker

PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX9sAAAAASUVORK5CYII=')


def run_fixture(job,root,deadline):
    UUID(job);root=Path(root);root.mkdir(parents=True,exist_ok=True,mode=0o700)
    client=ClipClient();session=root/'claim.json';results=[];http_count=0
    if session.exists():raise ValueError('fixture_already_attempted_inspect_state_do_not_reclaim')
    worker.save(session,{'state':'submitted_or_unknown','job_id':job})
    claim=client.call('claim',job,{})
    worker.save(session,{'state':'claimed','claim':claim})
    if (claim.get('state')!='running' or claim.get('job_id')!=job or
        claim.get('max_text_requests')!=0 or claim.get('max_qwen_requests')!=0):
        raise ValueError('explicit_zero_budget_fixture_job_required')
    lease=claim['lease_id'];UUID(lease)
    def rpc(action,**data):
        deadline.remaining()
        return client.call(action,job,{'lease_id':lease,**data})
    def request(method,path,headers=None,data=None):
        nonlocal http_count
        deadline.remaining();http_count+=1
        if http_count>12:raise ValueError('fixture_http_limit_exceeded')
        req=urllib.request.Request('https://'+platform.HOST+path,method=method,data=data,
            headers={'Authorization':'Bearer '+platform.gateway_key(),**(headers or {})})
        try:
            with client.http.open(req,timeout=min(30,deadline.remaining())) as response:
                return response.status,response.read(20000)
        except urllib.error.HTTPError as error:
            status=error.code
            body=error.read(20000).decode('utf-8',errors='replace').lower();error.close()
            category=('row_level_security_denied' if 'row-level security' in body or 'row level security' in body
                      else 'permission_denied' if 'permission denied' in body
                      else 'gateway_authentication_rejected' if 'jwt' in body or 'missing_credentials' in body
                      else 'http_rejected_unclassified')
            worker.save(root/'last-rejection.json',{'http_status':status,'category':category})
            return status,b''
        except Exception:raise platform.PlatformUnavailable('fixture_network_unavailable_no_retry') from None
    try:
        rpc('heartbeat')
        selection={'source_title':'明确HTTP存储隔离夹具（非目标视频）','source_duration':1,
                   'source_sha256':hashlib.sha256(PNG).hexdigest(),'start':0,'end':1,
                   'topic_confirmed':True,'complete_exchange_confirmed':True,
                   'boundary_reason':'Explicit zero-budget HTTP fixture only',
                   'evidence':[{'kind':'http_transport_fixture_not_video_acceptance'}]}
        rpc('record_selection',selection=selection)
        plan=rpc('reserve_media',role='cover',filename='http-fixture.png',mime='image/png',
                 bytes=len(PNG),sha256=hashlib.sha256(PNG).hexdigest())
        worker.save(root/'media-plan.private.json',plan)
        if plan.get('state')!='media_reserved' or len(plan.get('parts',[]))!=1:raise ValueError('fixture_media_reservation_failed')
        name=plan['parts'][0]['object_name'];prefix=plan['capability']
        if name.rsplit('/',1)[0]!=prefix:raise ValueError('fixture_capability_mismatch')
        path='/v1/storages/object/subtitle-deliveries/'+name
        headers={'x-cloud-clip-object':name,'x-cloud-clip-capability':prefix,
                 'x-cloud-clip-worker':os.environ['SUBTITLE_PLATFORM_TOKEN'],'x-upsert':'false',
                 'Content-Type':'image/png'}
        status,_=request('POST',path,headers,PNG)
        results.append({'check':'scoped_insert','http_status':status,'passed':status in (200,201)})
        if status not in (200,201):raise ValueError('scoped_insert_failed_keep_policy_closed')
        status,raw=request('GET',path,headers)
        matched=status==200 and raw==PNG
        results.append({'check':'scoped_readback_sha','http_status':status,'passed':matched})
        if not matched:raise ValueError('scoped_readback_failed_keep_policy_closed')
        no_worker=dict(headers);no_worker.pop('x-cloud-clip-worker')
        status,_=request('GET',path,no_worker)
        results.append({'check':'no_worker_read_denied','http_status':status,'passed':status in (401,403,404)})
        wrong=dict(headers);wrong['x-cloud-clip-capability']='cloud-clips/'+'0'*64
        status,_=request('GET',path,wrong)
        results.append({'check':'wrong_capability_read_denied','http_status':status,'passed':status in (401,403,404)})
        cross_name='cloud-clips/'+'0'*64+'/part-000001'
        cross=dict(headers);cross['x-cloud-clip-object']=cross_name
        status,_=request('POST','/v1/storages/object/subtitle-deliveries/'+cross_name,cross,PNG)
        results.append({'check':'cross_path_insert_denied','http_status':status,'passed':status in (401,403)})
        overwrite=dict(headers);overwrite['x-upsert']='true'
        status,_=request('POST',path,overwrite,b'changed-fixture')
        results.append({'check':'upsert_overwrite_denied','http_status':status,'passed':status in (400,401,403,409)})
        status,raw=request('GET',path,headers)
        results.append({'check':'original_bytes_preserved','http_status':status,'passed':status==200 and raw==PNG})
        status,_=request('POST','/v1/storages/object/list/subtitle-deliveries',headers,
                         json.dumps({'prefix':prefix+'/','limit':1,'offset':0}).encode())
        results.append({'check':'list_denied','http_status':status,'passed':status in (401,403),
                        'inconclusive':status in (400,404,405)})
        if not all(r['passed'] for r in results):raise ValueError('storage_http_isolation_not_proven')
        result=rpc('finish_media',media_id=plan['media_id'],worker_verified_sha256=hashlib.sha256(PNG).hexdigest())
        if result.get('state')!='worker_sha_verified':raise ValueError('fixture_finish_not_confirmed')
        return {'state':'storage_http_fixture_passed','checks':results,'http_requests':http_count,
                'fixture_bytes':len(PNG),'paid_requests':0,'delivery_published':False,
                'server_sha_verified':False}
    finally:
        report={'checks':results,'http_requests':http_count,'paid_requests':0,'delivery_published':False}
        worker.save(root/'http-fixture-report.json',report)
        # A fixture never becomes a successful product delivery.
        try:
            stopped=rpc('stop',state='failed',stage='explicit_http_fixture_finished_not_video_acceptance')
            worker.save(root/'stop-state.json',{'state':stopped.get('state'),'reported':stopped.get('state')=='failed'})
        except Exception:worker.save(root/'stop-unsent.json',{'state':'failed','needs_main_task_cleanup':True})


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job-id',required=True);parser.add_argument('--root',required=True)
    parser.add_argument('--execute-http-fixture',action='store_true')
    args=parser.parse_args()
    if not args.execute_http_fixture:
        print(json.dumps({'state':'checked_not_executed','paid_requests':0}));return 0
    try:
        result=run_fixture(args.job_id,args.root,Deadline(300));print(json.dumps(result));return 0
    except Exception as error:
        print(json.dumps({'state':'stopped','error_type':type(error).__name__,
                          'details':'inspect_private_safe_report','paid_requests':0,'delivery_published':False}));return 1


if __name__=='__main__':raise SystemExit(main())

