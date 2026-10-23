"""Offline HTTP simulations only; no website requests, ASR or paid model calls."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import urllib.error

import billing
import platform_worker as platform
import worker

JOB = '810f48af-ddaa-4305-a9b3-353c697ddfcc'
LEASE = '0185c222-33f3-4a17-9bf4-53ddc9718c80'
DELIVERY = '5269f05f-9d1f-4c65-babb-e149590ae892'


class Response(io.BytesIO):
    def __init__(self, raw, status=200, headers=None):
        super().__init__(raw)
        self.status=status
        self.headers=headers or {}


class PlatformTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        context=patch.object(billing,'TRIAL_STATE_ROOT',self.root/'trial')
        context.start(); self.addCleanup(context.stop)
        self.data=b'private synthetic media bytes'
        self.claim={'job_id':JOB,'lease_id':LEASE,'state':'running','source_expires_at':datetime.fromtimestamp(time.time()+23*3600,timezone.utc).isoformat(),'file_name':'../untrusted.mp4',
            'mime_type':'video/mp4','byte_size':len(self.data),
            'sha256':hashlib.sha256(self.data).hexdigest(),
            'sources':[{'path':'untrusted/server/path','url':'https://'+platform.HOST+'/private?signed=dummy',
                        'byte_size':len(self.data)}],
            'max_video_seconds':60,'max_text_requests':20,'max_secondary_requests':2}
        self.client=Mock()
        self.client.call.return_value={'state':'running','lease_seconds':2700}

    def delivery(self):
        folder=self.root/'delivery'; folder.mkdir(exist_ok=True)
        for name in platform.REQUIRED_FILES:
            (folder/name).write_bytes(b'\xef\xbb\xbf'+name.encode()+b'\r\n')
        return folder

    def test_default_only_checks_and_does_not_claim(self):
        with patch.object(platform,'Client',side_effect=AssertionError('no network')):
            self.assertEqual(platform.main(['--job-id',JOB,'--work-root',str(self.root)]),0)

    def test_rpc_uses_gateway_header_and_separate_capability_json_without_redirect(self):
        http=Mock()
        http.open.return_value=Response(b'{"state":"running","lease_seconds":2700}')
        with patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-platform-identity','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-publishable-gateway'}),patch.object(platform,'opener',return_value=http):
            client=platform.Client()
            client.call('heartbeat',JOB,{'lease_id':LEASE,'stage':'preparing','progress':{}})
        req=http.open.call_args.args[0]
        self.assertEqual(req.full_url,platform.API)
        self.assertEqual(json.loads(req.data),{'p_key':'dummy-platform-identity',
            'p_action':'heartbeat','p_job':JOB,'p_payload':{'lease_id':LEASE,'stage':'preparing','progress':{}}})
        self.assertEqual(req.get_header('Authorization'),'Bearer dummy-publishable-gateway')
        self.assertIsNone(req.get_header('Cookie'))
        self.assertTrue(any(isinstance(h,worker.NoRelayRedirect) for h in platform.opener().handlers))

    def test_gateway_key_is_required_and_known_admin_or_personal_jwt_is_rejected(self):
        with patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-platform-identity'},clear=True):
            with self.assertRaises(platform.ConfigurationMissing):platform.Client()
        for role in ('service_role','authenticated','admin'):
            middle=base64.urlsafe_b64encode(json.dumps({'role':role}).encode()).decode().rstrip('=')
            with patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-platform-identity',
                                       'SUBTITLE_PLATFORM_GATEWAY_KEY':'header.'+middle+'.dummy-signature'}):
                with self.assertRaises(platform.ConfigurationMissing):platform.Client()

    def test_rpc_rejects_revocation_bad_json_error_envelopes_and_redirects(self):
        for content in (b'{"ok":false,"error":"revoked"}',b'[]',b'not json'):
            http=Mock();http.open.return_value=Response(content)
            with patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-platform-identity','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-publishable-gateway'}),patch.object(platform,'opener',return_value=http):
                with self.assertRaises(platform.PlatformError):platform.Client().call('heartbeat',JOB,{'lease_id':LEASE})
        http=Mock()
        http.open.side_effect=urllib.error.HTTPError(platform.API,302,'redirect',{},None)
        with patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-platform-identity','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-publishable-gateway'}),patch.object(platform,'opener',return_value=http):
            with self.assertRaises(platform.PlatformError):platform.Client().call('claim',JOB,{})
        self.assertEqual(http.open.call_count,1)

    def test_real_rpc_success_objects_have_no_ok_or_data_envelope(self):
        examples=[('claim',self.claim,{}),('claim',{'state':'no_job'},{}),
            ('heartbeat',{'state':'running','lease_seconds':2700},{'lease_id':LEASE}),
            ('stop',{'state':'waiting_configuration'},{'lease_id':LEASE,'state':'waiting_configuration'}),
            ('stop',{'state':'waiting_reconciliation'},{'lease_id':LEASE,'state':'waiting_reconciliation'}),
            ('stop',{'state':'failed'},{'lease_id':LEASE,'state':'failed'}),
            ('publish',{'state':'succeeded','delivery_id':DELIVERY,'human_review_required':True},{'lease_id':LEASE}),
            ('publish',{'state':'succeeded','delivery_id':DELIVERY},{'lease_id':LEASE})]
        for action,reply,payload in examples:
            http=Mock();http.open.return_value=Response(json.dumps(reply).encode())
            with (self.subTest(action=action,reply_state=reply['state']),
                  patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-cap','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-gateway'}),
                  patch.object(platform,'opener',return_value=http)):
                self.assertEqual(platform.Client().call(action,JOB,payload),reply)

    def test_every_http_heartbeat_failure_stops_without_matching_reason_text(self):
        for status,code in [(400,'DATABASE_P0001'),(401,'DATABASE_42501'),(401,'MISSING_CREDENTIALS')]:
            http=Mock();raw=json.dumps({'code':code,'message':'arbitrary private reason','requestId':JOB}).encode()
            http.open.side_effect=urllib.error.HTTPError(platform.API,status,'dummy',{},io.BytesIO(raw))
            with (patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-cap','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-gateway'}),
                  patch.object(platform,'opener',return_value=http)):
                client=platform.Client();lease=platform.Lease(client,self.claim)
                with billing.request_guard(lease.before_reserve),self.assertRaises(platform.PlatformError) as raised:
                    billing.reserve(self.root/'job',platform.limited_config(self.claim),'text')
                self.assertNotIn('private reason',str(raised.exception))
                self.assertFalse((self.root/'trial'/f'{billing.TRIAL_SCOPE}.json').exists())
                self.assertEqual(http.open.call_count,1)

    def test_legacy_ok_or_wrapped_heartbeat_is_not_a_success(self):
        for reply in ({'ok':True},{'data':{'state':'running','lease_seconds':2700}},
                      {'state':'running'},{'state':'running','lease_seconds':False}):
            self.client.call.return_value=reply
            with self.subTest(reply=reply),self.assertRaises(platform.PlatformUnavailable):
                platform.Lease(self.client,self.claim).before_reserve('qwen')

    def test_no_job_is_normal_and_does_not_cache_a_lease_or_start_models(self):
        self.client.call.return_value={'state':'no_job'}
        args=argparse.Namespace(job_id=JOB,work_root=self.root)
        with patch.object(platform,'Client',return_value=self.client),patch.object(worker,'run',side_effect=AssertionError('no models')):
            self.assertEqual(platform.execute(args),{'state':'no_job'})
            self.assertEqual(platform.execute(args),{'state':'no_job'})
        self.assertEqual([call.args[0] for call in self.client.call.call_args_list],['claim','claim'])
        self.assertFalse((self.root/'control'/JOB/'session.json').exists())

    def test_server_source_expiration_is_honored_before_local_23_hour_limit(self):
        claim=dict(self.claim,source_expires_at=datetime.fromtimestamp(time.time()-1,timezone.utc).isoformat())
        with patch.object(platform,'opener',side_effect=AssertionError('expired URL must not be fetched')):
            with self.assertRaises(platform.InputExpired):
                platform.download(claim,self.root/'expired.media',time.time(),lambda:None)
        for value in (None,'invalid','2026-10-21T12:00:00'):
            with self.subTest(value=value),self.assertRaises(platform.InvalidInput):
                platform.validate_claim(dict(self.claim,source_expires_at=value))

    def test_stop_refreshes_counts_after_rejected_or_unknown_reservation(self):
        control=self.root/'control'
        ledger=billing.TRIAL_STATE_ROOT/(billing.TRIAL_SCOPE+'.json')
        for state in ('waiting_reconciliation','failed','waiting_configuration'):
            worker.save(ledger,{'text':2,'qwen':2})
            self.client.call.return_value={'state':state}
            platform.stop(self.client,self.claim,control,state,'model_request_needs_reconciliation',
                          {'text_requests':1,'secondary_requests':1})
            expected={'text_requests':2,'secondary_requests':2}
            self.assertEqual(self.client.call.call_args.args[2]['progress'],expected)
            self.assertEqual(worker.read(control/'stop-state.json')['progress'],expected)

    def test_stop_reported_only_when_matching_state_is_confirmed(self):
        control=self.root/'control'
        self.client.call.return_value={'state':'waiting_reconciliation'}
        platform.stop(self.client,self.claim,control,'waiting_reconciliation','model_request_needs_reconciliation',{})
        self.assertTrue(worker.read(control/'stop-state.json')['reported'])
        self.client.call.return_value={'state':'running','lease_seconds':2700}
        platform.stop(self.client,self.claim,control,'failed','input_or_processing_failed',{})
        self.assertFalse(worker.read(control/'stop-state.json')['reported'])

    def test_only_exact_https_source_domain_and_port_are_allowed(self):
        bad=['http://'+platform.HOST+'/x','https://'+platform.HOST+'.evil.example/x',
             'https://evil.example/x','https://name@'+platform.HOST+'/x',
             'https://'+platform.HOST+':444/x','https://'+platform.HOST+'/x#fragment',
             'https://'+platform.HOST+'/x\n',None]
        for url in bad:
            with self.subTest(url=url),self.assertRaises(platform.InvalidInput):platform.safe_source_url(url)

    def test_streamed_multichunk_download_full_hash_and_no_identity_leak(self):
        parts=[self.data[:5],self.data[5:]]
        claim=dict(self.claim,sources=[{'path':f'{i}','url':'https://'+platform.HOST+f'/private/{i}',
                                      'byte_size':len(part)} for i,part in enumerate(parts)])
        http=Mock();http.open.side_effect=[Response(p,headers={'Content-Length':str(len(p))}) for p in parts]
        check=Mock()
        with patch.dict(os.environ,{'SUBTITLE_PLATFORM_TOKEN':'dummy-platform-identity','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-publishable-gateway'}),patch.object(platform,'opener',return_value=http):
            output=platform.download(claim,self.root/'input/source.media',time.time(),check)
        self.assertEqual(output.read_bytes(),self.data)
        self.assertEqual(http.open.call_count,2)
        for call in http.open.call_args_list:
            req=call.args[0]
            self.assertEqual(req.get_method(),'GET');self.assertIsNone(req.data)
            self.assertIsNone(req.get_header('Authorization'));self.assertIsNone(req.get_header('Cookie'))
            self.assertNotIn('dummy-platform-identity',repr(req.headers))
        self.assertGreaterEqual(check.call_count,4)

    def test_corrupt_oversized_truncated_or_length_mismatch_source_is_not_kept(self):
        cases=[(self.data[:-1],{}),(self.data+b'x',{}),(b'X'*len(self.data),{}),
               (self.data,{'Content-Length':'999'})]
        for index,(data,headers) in enumerate(cases):
            http=Mock();http.open.return_value=Response(data,headers=headers)
            target=self.root/str(index)/'source.media'
            with patch.object(platform,'opener',return_value=http),self.assertRaises(platform.InvalidInput):
                platform.download(self.claim,target,time.time(),lambda:None)
            self.assertFalse(target.exists());self.assertFalse(target.with_suffix('.pending').exists())

    def test_expired_sources_and_source_redirect_stop_without_refresh(self):
        http=Mock()
        with patch.object(platform,'opener',return_value=http),self.assertRaises(platform.InputExpired):
            platform.download(self.claim,self.root/'expired/source.media',time.time()-platform.SOURCE_TTL-1,lambda:None)
        http.open.assert_not_called()
        for status in (302,403,410):
            http=Mock();http.open.side_effect=urllib.error.HTTPError(self.claim['sources'][0]['url'],status,'dummy',{},None)
            with patch.object(platform,'opener',return_value=http),self.assertRaises(platform.PlatformError):
                platform.download(self.claim,self.root/str(status)/'source.media',time.time(),lambda:None)
            self.assertEqual(http.open.call_count,1)

    def test_verified_local_source_can_resume_after_url_expiry(self):
        path=self.root/'source.media';path.write_bytes(self.data)
        with patch.object(platform,'opener',side_effect=AssertionError('no network')):
            self.assertEqual(platform.download(self.claim,path,0,lambda:None),path)

    def test_cancel_or_network_failure_blocks_every_new_fee_reservation(self):
        cfg=platform.limited_config(self.claim)
        self.client.call.side_effect=[{'state':'running','lease_seconds':2700},platform.LeaseLost('cancelled')]
        lease=platform.Lease(self.client,self.claim)
        with lease,billing.request_guard(lease.before_reserve):
            with self.assertRaises(platform.LeaseLost):billing.reserve(self.root/'job',cfg,'text')
        self.assertFalse((self.root/'trial'/f'{billing.TRIAL_SCOPE}.json').exists())
        self.assertEqual(self.client.call.call_count,2)
        for call in self.client.call.call_args_list:
            self.assertEqual(call.args[2]['lease_id'],LEASE)

    def test_periodic_heartbeat_failure_is_latched_even_if_service_recovers(self):
        lease=platform.Lease(self.client,self.claim)
        self.client.call.side_effect=platform.PlatformUnavailable('offline')
        with self.assertRaises(platform.PlatformUnavailable):lease.pulse()
        self.client.call.side_effect=None;self.client.call.return_value={'state':'running','lease_seconds':2700}
        with self.assertRaises(platform.PlatformUnavailable):lease.before_reserve('qwen')
        self.assertEqual(self.client.call.call_count,1)

    def test_one_forced_heartbeat_for_every_reservation_and_no_guard_bypass(self):
        cfg=platform.limited_config(self.claim)
        with self.assertRaisesRegex(RuntimeError,'live lease guard'):
            billing.reserve(self.root/'job',cfg,'text')
        lease=platform.Lease(self.client,self.claim)
        with lease,billing.request_guard(lease.before_reserve):
            billing.reserve(self.root/'job',cfg,'text')
            billing.reserve(self.root/'job',cfg,'qwen')
        self.assertEqual(self.client.call.call_count,3)
        self.assertEqual(worker.read(self.root/'trial'/f'{billing.TRIAL_SCOPE}.json')['qwen'],1)

    def test_server_allowances_map_to_client_trial_ceilings(self):
        cfg=platform.limited_config(dict(self.claim,max_video_seconds=9999,max_text_requests=999,max_secondary_requests=999))
        self.assertEqual((cfg['max_video_seconds'],cfg['max_text_requests'],cfg['max_qwen_requests']),(1200,400,40))
        cfg=platform.limited_config(dict(self.claim,max_text_requests=4,max_secondary_requests=1))
        self.assertEqual((cfg['max_text_requests'],cfg['max_qwen_requests']),(4,1))

    def test_bundle_uses_exact_original_bytes_and_enforces_required_files_limits(self):
        folder=self.delivery()
        files=platform.bundle(folder)
        self.assertEqual({r['name'] for r in files},set(platform.REQUIRED_FILES))
        for row in files:
            raw=(folder/row['name']).read_bytes()
            self.assertEqual(base64.b64decode(row['base64']),raw)
            self.assertEqual(row['sha256'],hashlib.sha256(raw).hexdigest());self.assertEqual(row['bytes'],len(raw))
        (folder/'usage.json').write_bytes(b'x'*500001)
        with self.assertRaises(platform.InvalidInput):platform.bundle(folder)
        for name in platform.REQUIRED_FILES:(folder/name).write_bytes(b'x'*230000)
        with self.assertRaises(platform.InvalidInput):platform.bundle(folder)
        (folder/'usage.json').unlink()
        with self.assertRaises(platform.InvalidInput):platform.bundle(folder)

    def test_publish_timeout_then_same_lease_reconciliation_does_not_invoke_models(self):
        folder=self.delivery();control=self.root/'control'
        self.client.call.side_effect=platform.PlatformUnavailable('timeout')
        with self.assertRaises(platform.ReconciliationRequired):
            platform.publish(self.client,self.claim,control,folder,{'cue_count':2})
        first=self.client.call.call_args
        self.client.call.side_effect=None;self.client.call.return_value={'state':'succeeded','delivery_id':DELIVERY}
        with patch.object(worker,'run',side_effect=AssertionError('models must not run')):
            result=platform.publish(self.client,self.claim,control)
            self.assertEqual(result['delivery_id'],DELIVERY)
        self.assertEqual(first,self.client.call.call_args)
        platform.publish(self.client,self.claim,control)
        self.assertEqual(self.client.call.call_count,2)

    def test_resume_unknown_publish_takes_precedence_over_models_or_download(self):
        control=self.root/'control'/JOB
        worker.save(control/'session.json',{'claim':self.claim,'claimed_at':time.time()})
        worker.save(control/'publish-payload.json',{'lease_id':LEASE,'model':'gpt-6-luna','files':[],'progress':{}})
        worker.save(control/'publish-state.json',{'state':'submitted_or_unknown'})
        self.client.call.return_value={'state':'succeeded','delivery_id':DELIVERY}
        with patch.object(platform,'Client',return_value=self.client),patch.object(worker,'run',side_effect=AssertionError('no models')):
            result=platform.execute(argparse.Namespace(job_id=JOB,work_root=self.root))
        self.assertEqual(result['state'],'published');self.assertEqual(self.client.call.call_count,1)
        self.assertEqual(self.client.call.call_args.args[0],'publish')

    def test_unknown_claim_is_not_automatically_repeated(self):
        control=self.root/'control'/JOB;worker.save(control/'claim-state.json',{'state':'submitted_or_unknown'})
        with patch.object(platform,'Client',return_value=self.client),self.assertRaises(platform.ReconciliationRequired):
            platform.execute(argparse.Namespace(job_id=JOB,work_root=self.root))
        self.client.call.assert_not_called()

    def test_configuration_failure_reports_waiting_configuration_with_lease(self):
        self.client.call.side_effect=lambda action,*args:self.claim if action=='claim' else {'state':'running','lease_seconds':2700}
        with patch.object(platform,'Client',return_value=self.client),patch.object(platform,'config_ready',side_effect=platform.ConfigurationMissing('missing')):
            with self.assertRaises(platform.PlatformError):platform.execute(argparse.Namespace(job_id=JOB,work_root=self.root))
        action,job,payload=self.client.call.call_args.args
        self.assertEqual((action,job,payload['state'],payload['lease_id']),('stop',JOB,'waiting_configuration',LEASE))
        self.assertNotIn('missing',payload['stage'])

    def test_full_adapter_path_with_mocked_processing_and_exact_nine_file_publish(self):
        self.client.call.side_effect=lambda action,*args: self.claim if action=='claim' else ({'state':'succeeded','delivery_id':DELIVERY} if action=='publish' else {'state':'running','lease_seconds':2700})
        def process(args):
            cfg=worker.read(args.config)
            self.assertTrue(cfg['platform_managed'])
            billing.reserve(args.work_root/JOB,cfg,'qwen')
            billing.reserve(args.work_root/JOB,cfg,'text')
            billing.reserve(args.work_root/JOB,cfg,'text')
            delivery=args.work_root/JOB/'delivery';delivery.mkdir(parents=True)
            for name in platform.REQUIRED_FILES:(delivery/name).write_bytes(name.encode())
        def downloaded(claim,path,claimed_at,check):
            check();path.parent.mkdir(parents=True);path.write_bytes(self.data);return path
        with (patch.object(platform,'Client',return_value=self.client),
              patch.object(platform,'config_ready'),patch.object(platform,'download',side_effect=downloaded),
              patch.object(worker,'run',side_effect=process)):
            result=platform.execute(argparse.Namespace(job_id=JOB,work_root=self.root))
        self.assertEqual(result['state'],'published')
        actions=[c.args[0] for c in self.client.call.call_args_list]
        self.assertEqual(actions,['claim','heartbeat','heartbeat','heartbeat','heartbeat','heartbeat','publish'])
        payload=self.client.call.call_args.args[2]
        self.assertEqual({key:payload['progress'][key] for key in ('text_requests','secondary_requests')},{'text_requests':2,'secondary_requests':1})
        self.assertEqual(payload['progress']['operations_v1']['completed']['delivery_files'],9)
        self.assertFalse(payload['progress']['operations_v1']['actual_billing_verified'])
        self.assertNotIn('sources',json.dumps(payload['progress']))
        self.assertEqual(len(payload['files']),9)
        self.assertEqual(payload['lease_id'],LEASE)

    def test_unknown_model_result_reports_waiting_reconciliation(self):
        self.client.call.side_effect=lambda action,*args:self.claim if action=='claim' else {'state':'running','lease_seconds':2700}
        def unknown(args):
            worker.save(args.work_root/JOB/'text/000000-translate/request-state.json',
                        {'state':'request_in_progress_or_unknown'})
            raise TimeoutError()
        with (patch.object(platform,'Client',return_value=self.client),patch.object(platform,'config_ready'),
              patch.object(platform,'download',return_value=self.root/'source.media'),
              patch.object(worker,'run',side_effect=unknown)):
            with self.assertRaises(platform.PlatformError):
                platform.execute(argparse.Namespace(job_id=JOB,work_root=self.root))
        self.assertEqual(self.client.call.call_args.args[0],'stop')
        self.assertEqual(self.client.call.call_args.args[2]['state'],'waiting_reconciliation')

    def test_denied_pre_reserve_does_not_poison_model_checkpoint_as_unknown(self):
        cfg=platform.limited_config(self.claim)
        folder=self.root/'job/text/000000-translate'
        rows=[{'id':1,'text':'テスト','start':0,'end':1}]
        with patch.dict(os.environ,{'SUBTITLE_GPT_TOKEN':'dummy-gpt'}),billing.request_guard(lambda provider:(_ for _ in ()).throw(platform.LeaseLost('cancelled'))):
            with patch.object(worker,'open_relay_request',side_effect=AssertionError('no model network')):
                with self.assertRaises(platform.LeaseLost):worker.relay(rows,folder,cfg,'translate',[])
        self.assertEqual(worker.read(folder/'request-state.json')['state'],'not_sent')


if __name__=='__main__':unittest.main()

