"""Only synthetic state; no provider or website traffic."""
import argparse
from datetime import datetime,timezone,timedelta
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

import billing
import operational_report as reports
import platform_worker as platform
import worker

JOB='810f48af-ddaa-4305-a9b3-353c697ddfcc'
LEASE='0185c222-33f3-4a17-9bf4-53ddc9718c80'
DELIVERY='5269f05f-9d1f-4c65-babb-e149590ae892'


class OperationsTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.root=Path(tmp.name)
        self.job=self.root/'jobs'/JOB;self.control=self.root/'control'/JOB
        self.claim={'job_id':JOB,'lease_id':LEASE,'state':'running','source_expires_at':(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat(),
                    'byte_size':3,'sha256':'a'*64,'sources':[{'byte_size':3,'url':'https://'+platform.HOST+'/synthetic'}],
                    'max_video_seconds':60,'max_text_requests':20,'max_secondary_requests':2}
        self.client=Mock();self.client.call.return_value={'state':'succeeded','delivery_id':DELIVERY}
        self.args=argparse.Namespace(job_id=JOB,work_root=self.root,publish_only=True)

    def saved_payload(self):
        worker.save(self.control/'session.json',{'claim':self.claim,'claimed_at':0})
        payload={'lease_id':LEASE,'files':[{'synthetic':'already encoded bytes'}],'model':'gpt-6-luna','progress':{}}
        worker.save(self.control/'publish-payload.json',payload)
        return payload

    def execute(self):
        with patch.object(platform,'Client',return_value=self.client),patch.object(worker,'run',side_effect=AssertionError('no model execution')),patch.object(platform,'download',side_effect=AssertionError('no source download')),patch.object(platform,'config_ready',side_effect=AssertionError('no model setup')):
            return platform.execute(self.args)

    def test_publish_only_never_claims_or_rebuilds_saved_bytes(self):
        payload=self.saved_payload();before=(self.control/'publish-payload.json').read_bytes()
        self.assertEqual(self.execute()['state'],'published')
        self.client.call.assert_called_once_with('publish',JOB,payload)
        self.assertEqual((self.control/'publish-payload.json').read_bytes(),before)

    def test_publish_only_requires_original_session(self):
        with self.assertRaisesRegex(platform.ReconciliationRequired,'original_workspace_session'):self.execute()
        self.client.call.assert_not_called()

    def test_publish_only_requires_payload_and_never_falls_back_to_models(self):
        worker.save(self.control/'session.json',{'claim':self.claim,'claimed_at':0})
        with self.assertRaisesRegex(platform.ReconciliationRequired,'saved_payload_no_model_fallback'):self.execute()
        self.client.call.assert_not_called()

    def test_publish_only_rejects_another_job_session(self):
        self.saved_payload();worker.save(self.control/'session.json',{'claim':dict(self.claim,job_id=DELIVERY),'claimed_at':0})
        with self.assertRaises(platform.InvalidInput):self.execute()
        self.client.call.assert_not_called()

    def test_publish_only_rejects_changed_lease_without_rpc(self):
        payload=self.saved_payload();worker.save(self.control/'publish-payload.json',dict(payload,lease_id=DELIVERY))
        with self.assertRaisesRegex(platform.ReconciliationRequired,'lease_changed'):self.execute()
        self.client.call.assert_not_called()

    def test_unknown_publish_remains_single_attempt_and_preserves_payload(self):
        self.saved_payload();before=(self.control/'publish-payload.json').read_bytes()
        self.client.call.side_effect=platform.PlatformUnavailable('unavailable')
        with self.assertRaises(platform.ReconciliationRequired):self.execute()
        self.assertEqual(self.client.call.call_count,1)
        self.assertEqual((self.control/'publish-payload.json').read_bytes(),before)

    def test_expired_lease_is_not_replaced_or_reclaimed(self):
        self.saved_payload();self.client.call.side_effect=platform.LeaseLost('expired')
        with self.assertRaises(platform.ReconciliationRequired):self.execute()
        self.assertEqual([c.args[0] for c in self.client.call.call_args_list],['publish'])

    def test_confirmed_publish_is_returned_without_network(self):
        self.saved_payload();worker.save(self.control/'publish-state.json',{'state':'published','delivery_id':DELIVERY})
        self.assertEqual(self.execute()['delivery_id'],DELIVERY);self.client.call.assert_not_called()

    def test_usage_distinguishes_missing_zero_and_partial_coverage(self):
        worker.save(self.job/'text/000-translate/request-state.json',{'state':'completed','phase':'translate','usage':{'input_tokens':0,'output_tokens':3,'secret':'must-never-appear'}})
        worker.save(self.job/'text/001-review/request-state.json',{'state':'completed','phase':'review','usage':{'output_tokens':4}})
        worker.save(self.job/'qwen/000/request-state.json',{'state':'completed','usage':None})
        result=reports.snapshot(self.job,self.control)
        self.assertEqual(result['usage']['text']['input_tokens'],0)
        self.assertEqual(result['usage']['text']['input_tokens_reports'],1)
        self.assertEqual(result['usage']['text']['output_tokens'],7)
        self.assertIsNone(result['usage']['qwen']['input_tokens'])
        self.assertNotIn('secret',json.dumps(result));self.assertFalse(result['actual_billing_verified'])

    def test_unknown_and_rejected_requests_are_not_successes_or_free_calls(self):
        for folder,state in [('a','api_rejected'),('b','request_in_progress_or_unknown'),('c','not_sent')]:
            worker.save(self.job/'text'/folder/'request-state.json',{'state':state,'error':'private-response'})
        result=reports.snapshot(self.job,self.control)
        self.assertEqual(result['request_states'],{'completed':0,'not_sent':1,'rejected':1,'unknown':1})
        self.assertEqual(result['recovery']['mode'],'manual_reconciliation')
        self.assertNotIn('private-response',json.dumps(result))

    def test_progress_stays_bounded_without_paths_urls_tokens_or_transcripts(self):
        for i in range(400):
            worker.save(self.job/'text'/f'{i:06}-translate'/'request-state.json',{'state':'completed','phase':'translate','usage':{'input_tokens':100,'output_tokens':50},'body':'private transcript','url':'https://private.invalid','token':'private-key'})
        result=reports.snapshot(self.job,self.control)
        encoded=json.dumps(result,ensure_ascii=False)
        self.assertLess(len(encoded.encode()),3000)
        for forbidden in ('private transcript','private.invalid','private-key',str(self.root)):
            self.assertNotIn(forbidden,encoded)
        self.assertFalse(result['recovery']['permanent_backup'])

    def test_progress_requires_payload_before_offering_publish_only(self):
        worker.save(self.control/'publish-state.json',{'state':'submitted_or_unknown'})
        self.assertEqual(reports.snapshot(self.job,self.control)['recovery']['mode'],'checkpoints_only')
        self.saved_payload()
        self.assertEqual(reports.snapshot(self.job,self.control)['recovery']['mode'],'same_lease_publish_only')

    def test_corrupt_or_oversized_marker_is_unknown_without_private_echo(self):
        path=self.job/'text/a/request-state.json';path.parent.mkdir(parents=True)
        path.write_text('private-not-json',encoding='utf-8')
        self.assertEqual(reports.snapshot(self.job,self.control)['request_states']['unknown'],1)
        path.write_text('x'*500001,encoding='utf-8')
        self.assertEqual(reports.snapshot(self.job,self.control)['request_states']['unknown'],1)

    def test_quality_has_precise_ids_intervals_and_independent_reasons(self):
        rows=[{'id':1,'start':0,'end':10,'text':'テスト','zh':'测试','review':False},
              {'id':2,'start':1,'end':1.2,'text':'テスト','zh':'这是一条很快的字幕','review':True}]
        result=worker.quality(rows,10)
        warnings=[w for w in result['warnings'] if w['id']==2]
        self.assertEqual({w['code'] for w in warnings},{'short_duration','reading_speed','review_requested','overlap'})
        self.assertTrue(all((w['start'],w['end'])==(1,1.2) for w in warnings))
        self.assertEqual(result['affected_cue_count'],1)
        self.assertFalse(result['human_listening_complete']);self.assertFalse(result['semantic_accuracy_verified'])

    def test_dense_report_keeps_true_totals_and_bounded_delivery(self):
        rows=[{'id':i+1,'start':0,'end':.2,'text':'テスト','zh':'需要人工复核的内容','review':True} for i in range(3000)]
        full=worker.quality(rows,1);short=reports.compact_quality(full)
        self.assertTrue(short['warnings_truncated'])
        self.assertEqual(short['warning_count'],len(full['warnings']))
        self.assertEqual(short['affected_cue_count'],3000)
        self.assertLess(len(worker.encode_json(short).encode()),300000)
        self.assertEqual(len(full['warnings']),11999)
