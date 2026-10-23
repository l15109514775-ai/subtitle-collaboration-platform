"""HTTP simulations only. Real CloudBase deployment/RLS is tested separately."""
import base64
import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

import clip_media as media
import clip_pipeline as pipeline
import clip_sources
import platform_worker as platform
import worker

JOB='11111111-1111-4111-8111-111111111111'
LEASE='22222222-2222-4222-8222-222222222222'
DELIVERY='33333333-3333-4333-8333-333333333333'


class Response(io.BytesIO):
    status=200


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.claim={'job_id':JOB,'lease_id':LEASE}

    def test_unknown_publish_reconciles_exact_payload_without_reading_new_files(self):
        delivery=self.root/'render';delivery.mkdir()
        for name in media.SMALL_FILES:(delivery/name).write_bytes(name.encode())
        client=Mock();client.call.side_effect=RuntimeError('network unavailable')
        control=self.root/'control'
        with self.assertRaises(platform.ReconciliationRequired):media.publish(client,self.claim,control,delivery)
        original=worker.read(control/'publish-payload.json')
        for path in delivery.iterdir():path.unlink()
        client.call.side_effect=None;client.call.return_value={'state':'succeeded','delivery_id':DELIVERY}
        result=media.publish(client,self.claim,control,delivery)
        self.assertEqual(result['delivery_id'],DELIVERY)
        self.assertEqual(client.call.call_args.args[2],original)
        client.reset_mock();media.publish(client,self.claim,control,delivery)
        client.call.assert_not_called()

    def test_unknown_upload_cannot_be_overwritten_on_resume(self):
        path=self.root/'original.mp4';path.write_bytes(b'fixture')
        client=Mock();prefix='cloud-clips/'+'a'*64
        client.call.return_value={'state':'media_reserved','media_id':DELIVERY,'part_bytes':media.PART_BYTES,
            'overwrite':False,'expires_at':'2099-01-01T00:00:00+00:00','capability':prefix,
            'parts':[{'index':1,'bytes':7,'object_name':prefix+'/part-000001'}]}
        client.object_request.side_effect=RuntimeError('unknown upload')
        for error in (RuntimeError,platform.ReconciliationRequired):
            with self.assertRaises(error):media.upload_media(client,self.claim,self.root/'control',path,'clean',pipeline.Deadline(30),lambda:None)
        self.assertEqual(client.object_request.call_count,1)

    def test_media_readback_checks_actual_full_sha(self):
        payload=b'fixture-video-bytes';path=self.root/'original.mp4';path.write_bytes(payload)
        digest=hashlib.sha256(payload).hexdigest();prefix='cloud-clips/'+'b'*64;name=prefix+'/part-000001'
        client=Mock()
        def call(action,job,body):
            if action=='reserve_media':return {'state':'media_reserved','media_id':DELIVERY,
                'part_bytes':media.PART_BYTES,'overwrite':False,'expires_at':'2099-01-01T00:00:00+00:00',
                'capability':prefix,'parts':[{'index':1,'bytes':len(payload),'object_name':name}]}
            if action=='read_part':return {'state':'read_part_ready','object_name':name,'bytes':len(payload)}
            if action=='finish_media':
                self.assertEqual(body['worker_verified_sha256'],digest)
                return {'state':'worker_sha_verified','worker_sha_verified':True,'server_sha_verified':False}
            self.fail('unexpected action')
        client.call.side_effect=call
        client.object_request.side_effect=lambda method,*a,**kw:Response(b'{}' if method=='POST' else payload)
        result=media.upload_media(client,self.claim,self.root/'control',path,'clean',pipeline.Deadline(30),lambda:None)
        self.assertEqual(result,DELIVERY)
        state=worker.read(self.root/'control/media/clean/finished.json')
        self.assertTrue(state['worker_sha_verified']);self.assertFalse(state['server_sha_verified'])

    def test_storage_transport_stays_on_exact_host_with_scoped_headers(self):
        with patch.dict('os.environ',{'SUBTITLE_PLATFORM_TOKEN':'dummy-worker','SUBTITLE_PLATFORM_GATEWAY_KEY':'dummy-anon'}),patch.object(platform,'opener') as opener:
            client=media.ClipClient();prefix='cloud-clips/'+'a'*64
            client.object_request('POST',prefix+'/part-000001',prefix,'video/mp4',b'bytes')
            request=opener.return_value.open.call_args.args[0]
            self.assertEqual(request.get_header('X-cloud-clip-object'),prefix+'/part-000001')
            self.assertEqual(request.get_header('X-upsert'),'false')
            self.assertTrue(request.full_url.startswith('https://'+platform.HOST+'/'))
            with self.assertRaises(ValueError):client.object_request('GET','https://evil/','bad')

    def test_lease_rejection_blocks_reservation_and_existing_trial_ledger_unused(self):
        client=Mock();client.call.return_value={'state':'cancelled'}
        lease=media.ClipLease(client,self.claim,self.root/'control')
        with self.assertRaises(platform.LeaseLost):lease.reserve('text')
        self.assertEqual(client.call.call_count,1)
        self.assertFalse((self.root/'control/reservations').exists())

    def test_private_source_get_has_no_worker_or_gateway_headers(self):
        raw=b'private-fixture-source';sha=hashlib.sha256(raw).hexdigest()
        claim={'source_kind':'upload','source_bytes':len(raw),'source_sha256':sha,'source_duration':30,
               'original_offset':8673,'source_is_topic_only':True,'source_expires_at':'2099-01-01T00:00:00+00:00',
               'sources':[{'index':1,'byte_size':len(raw),'url':'https://'+platform.HOST+'/fixture-private-part'}]}
        http=Mock();http.open.return_value=Response(raw)
        with patch.object(platform,'opener',return_value=http),patch.object(worker,'probe',return_value=30):
            target=clip_sources.download_upload(claim,self.root,pipeline.Deadline(30),lambda:None)
        request=http.open.call_args.args[0]
        self.assertIsNone(request.get_header('Authorization'))
        self.assertIsNone(request.get_header('X-cloud-clip-worker'))
        self.assertIsNone(request.get_header('Cookie'))
        self.assertEqual(worker.digest(target),sha)
        self.assertEqual(worker.read(self.root/'uploaded-source-verified.json')['origin_start'],8673)

    def test_uploaded_source_corruption_never_becomes_verified(self):
        raw=b'bad source';claim={'source_kind':'upload','source_bytes':len(raw),'source_sha256':'a'*64,
          'source_duration':30,'source_expires_at':'2099-01-01T00:00:00+00:00',
          'sources':[{'index':1,'byte_size':len(raw),'url':'https://'+platform.HOST+'/fixture'}]}
        http=Mock();http.open.return_value=Response(raw)
        with patch.object(platform,'opener',return_value=http):
            with self.assertRaises(ValueError):clip_sources.download_upload(claim,self.root,pipeline.Deadline(30),lambda:None)
        self.assertFalse((self.root/'uploaded-source-verified.json').exists())
        self.assertFalse((self.root/'uploaded-source.pending').exists())


if __name__=='__main__':unittest.main()

