import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import tempfile
import unittest
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

import worker


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.rows=[{'id':1,'start':0.5,'end':2.4,'text':'今日はテストです。','review':True},
                   {'id':2,'start':2.5,'end':4.7,'text':'ありがとうございます。','review':False}]
        self.translations=[{'id':1,'zh':'今天是测试。','review':False},{'id':2,'zh':'谢谢大家。','review':False}]
        self.cfg=worker.read(Path(__file__).with_name('config.example.json'))

    def test_preserves_timing_ids_and_uncertainty(self):
        merged=worker.merge(self.rows,self.translations)
        self.assertEqual([(r['id'],r['start'],r['end']) for r in merged],[(1,.5,2.4),(2,2.5,4.7)])
        self.assertTrue(merged[0]['review'])

    def test_rejects_wrong_order_count_and_injected_markup(self):
        for value in [self.translations[::-1],self.translations[:1],['invalid',self.translations[1]],
                      [{'id':1,'zh':r'{\p1}drawing'},self.translations[1]]]:
            with self.subTest(value=value),self.assertRaises(ValueError):
                worker.merge(self.rows,value)

    def test_rejects_nonfinite_and_out_of_range_timing(self):
        for end in [float('nan'),float('inf'),-1,10]:
            with self.subTest(end=end),self.assertRaises(ValueError):
                worker.validate_cues([dict(self.rows[0],end=end)],duration=5)

    def test_exports_actual_ass_and_never_marks_human_review_complete(self):
        with tempfile.TemporaryDirectory() as root:
            rows=worker.merge(self.rows,self.translations)
            worker.export(rows,Path(root))
            content=(Path(root)/'Bilingual.ass').read_text(encoding='utf-8-sig')
            self.assertIn('[V4+ Styles]',content)
            self.assertIn('Dialogue: 0,0:00:00.50,0:00:02.40',content)
            self.assertIn(r'今日はテストです。\N今天是测试。',content)
            quality=worker.quality(rows,5)
            self.assertFalse(quality['human_listening_complete'])
            self.assertEqual(quality['state'],'awaiting_human_review')

    def test_unknown_request_stops_before_reading_secret_or_network(self):
        with tempfile.TemporaryDirectory() as root:
            folder=Path(root)/'job/text/batch';folder.mkdir(parents=True)
            worker.save(folder/'request-state.json',{'state':'request_in_progress_or_unknown'})
            with patch.object(worker,'open_relay_request',side_effect=AssertionError('network forbidden')):
                with self.assertRaisesRegex(RuntimeError,'manual reconciliation'):
                    worker.relay(self.rows,folder,self.cfg,'translate',[])

    def test_official_text_endpoint_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError,'existing GPT relay'):
                worker.relay(self.rows,Path(root)/'job/text/batch',dict(self.cfg,gpt_base_url='https://api.openai.com/v1'),'translate',[])

    def test_request_budget_is_checked_before_network(self):
        with tempfile.TemporaryDirectory() as root,patch.dict(os.environ,{'SUBTITLE_GPT_TOKEN':'unit-test-not-a-real-credential'}):
            with patch.object(worker,'open_relay_request',side_effect=AssertionError('network forbidden')):
                with self.assertRaisesRegex(RuntimeError,'allowance exhausted'):
                    worker.relay(self.rows,Path(root)/'job/text/batch',self.cfg,'translate',[])

    def test_success_checkpoint_prevents_repeat_charge(self):
        response={'status':'completed','usage':{'input_tokens':10},'output':[{'type':'message','content':[{'type':'output_text','text':json.dumps(self.translations)}]}]}
        class Reply:
            status=200
            def read(self,limit):return json.dumps(response).encode()
            def close(self):pass
        with tempfile.TemporaryDirectory() as root,patch.dict(os.environ,{'SUBTITLE_GPT_TOKEN':'unit-test-not-a-real-credential'}),patch.object(worker,'open_relay_request',return_value=Reply()) as request:
            folder=Path(root)/'job/text/batch'
            config=dict(self.cfg,max_text_requests=1)
            a=worker.relay(self.rows,folder,config,'translate',[])
            b=worker.relay(self.rows,folder,config,'translate',[])
            self.assertEqual(a,b)
            self.assertEqual(request.call_count,1)
            self.assertEqual(worker.read(Path(root)/'job/request-ledger.json')['attempted'],1)

    def test_redirect_cannot_forward_bearer_to_another_endpoint(self):
        paths=[]
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                paths.append(self.path)
                self.send_response(307)
                self.send_header('Location','/must-not-receive-credential')
                self.send_header('Content-Length','0')
                self.end_headers()
            def log_message(self,*args):pass
        server=HTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with patch.dict(os.environ,{'no_proxy':'127.0.0.1','NO_PROXY':'127.0.0.1'}):
                response=worker.open_relay_request(f'http://127.0.0.1:{server.server_port}/v1','dummy-test-value',{})
                self.assertEqual(response.status,307)
                response.close()
            self.assertEqual(paths,['/v1/responses'])
        finally:
            server.shutdown();server.server_close();thread.join()

    def test_execute_requires_explicit_approval(self):
        args=argparse.Namespace(config=Path(__file__).with_name('config.example.json'),video=__file__,execute=True)
        with patch.object(worker,'probe',return_value=10):
            with self.assertRaisesRegex(ValueError,'not been approved'):
                worker.run(args)

    def test_reused_asr_exports_provenance_without_loading_whisper(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            video=root/'input.mp4';video.write_bytes(b'test video identity')
            primary=root/'primary.json';worker.save(primary,self.rows)
            secondary=root/'secondary.json';worker.save(secondary,self.rows)
            config=root/'config.json';worker.save(config,dict(self.cfg,billable_execution_approved=True,max_text_requests=2))
            args=argparse.Namespace(config=config,video=video,execute=True,secondary=secondary,
                primary=primary,primary_source_sha256=worker.digest(video),work_root=root,job_id='reuse')
            job=root/'reuse';job.mkdir();(job/'audio.wav').write_bytes(b'prepared audio')
            def translated(rows,*unused):
                return worker.merge(rows,self.translations)
            with patch.object(worker,'probe',return_value=5),patch.object(worker,'transcribe',side_effect=AssertionError('Whisper must not run')),patch.object(worker,'relay',side_effect=translated):
                worker.run(args)
                proof=worker.read(job/'delivery/recognition-provenance.json')
                self.assertEqual(proof['primary_mode'],'reused_existing_result')
                self.assertEqual(proof['primary_reference_sha256'],worker.digest(primary))
                self.assertTrue((job/'delivery/Bilingual.ass').is_file())
                worker.save(primary,[dict(self.rows[0],text='変更'),self.rows[1]])
                with self.assertRaisesRegex(ValueError,'inputs/config changed'):
                    worker.run(args)

    def test_reused_asr_rejects_mismatched_video_before_model_calls(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            video=root/'input.mp4';video.write_bytes(b'changed video')
            primary=root/'primary.json';worker.save(primary,self.rows)
            secondary=root/'secondary.json';worker.save(secondary,self.rows)
            config=root/'config.json';worker.save(config,dict(self.cfg,billable_execution_approved=True,max_text_requests=2))
            args=argparse.Namespace(config=config,video=video,execute=True,secondary=secondary,
                primary=primary,primary_source_sha256='0'*64,work_root=root,job_id='mismatch')
            with patch.object(worker,'probe',return_value=5),patch.object(worker,'relay',side_effect=AssertionError('No model calls')):
                with self.assertRaisesRegex(ValueError,'bound to the input video SHA256'):
                    worker.run(args)


if __name__=='__main__':
    unittest.main()

