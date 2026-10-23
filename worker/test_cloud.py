"""Offline protocol/checkpoint tests. All provider replies are explicit mocks."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave
from unittest.mock import Mock, patch

import billing
import qwen_asr
import runtime
import worker
import qwen_recovery


class CloudWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        state_patch = patch.object(billing, 'TRIAL_STATE_ROOT', self.root / 'allowance')
        state_patch.start(); self.addCleanup(state_patch.stop)
        self.cfg = dict(worker.read(Path(__file__).with_name('config.example.json')),
            billable_execution_approved=True, max_video_seconds=60, max_text_requests=20, max_qwen_requests=2,
            qwen_base_url='https://dashscope.aliyuncs.com/compatible-mode/v1')

    def audio(self, seconds=1):
        path = self.root / 'source.wav'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
            f'sine=frequency=440:duration={seconds}', '-ac', '1', '-ar', '16000', str(path)], check=True)
        return path

    def test_trial_budget_is_cumulative_across_jobs_and_work_roots(self):
        for number in range(20):
            billing.reserve(self.root / str(number) / 'job', self.cfg, 'text')
        with self.assertRaisesRegex(RuntimeError, 'Cumulative'):
            billing.reserve(self.root / 'elsewhere' / 'job', self.cfg, 'text')
        for number in range(2):
            billing.reserve(self.root / str(number), self.cfg, 'qwen')
        with self.assertRaisesRegex(RuntimeError, 'Cumulative'):
            billing.reserve(self.root / 'new', self.cfg, 'qwen')

    def test_cached_aac_padding_is_trimmed_to_exact_source_samples(self):
        audio=self.audio(1.00725)
        worker.prepare_audio(self.root/'unused.mp4',audio,1.0,1)
        with wave.open(str(audio),'rb') as source:
            self.assertEqual(source.getnframes(),16000)
        worker.prepare_audio(self.root/'unused.mp4',audio,1.0,1)
        self.assertEqual(worker.probe(audio),1.0)

    def test_excess_decoded_audio_and_over_limit_source_still_rejected(self):
        audio=self.audio(1.2)
        with self.assertRaisesRegex(ValueError,'beyond codec padding'):
            worker.prepare_audio(self.root/'unused.mp4',audio,1.0,1)
        with self.assertRaisesRegex(ValueError,'Source exceeds'):
            worker.prepare_audio(self.root/'unused.mp4',audio,1.0001,1)

    def test_new_decode_is_capped_before_recognition(self):
        source=self.audio(1.00725)
        audio=self.root/'audio.wav'
        worker.prepare_audio(source,audio,1.0,1)
        with wave.open(str(audio),'rb') as result:
            self.assertEqual(result.getnframes(),16000)

    def test_whisper_receives_normalized_pcm_without_pyav_file_decoder(self):
        import numpy as np
        from types import SimpleNamespace
        audio = self.audio()
        job = self.root / 'pcm-job'
        model_path = self.root / 'model'; model_path.mkdir()
        received = []

        def recognize(samples, **options):
            self.assertIsInstance(samples, np.ndarray)
            self.assertEqual(samples.dtype, np.float32)
            self.assertEqual(samples.shape, (16000,))
            self.assertGreater(float(np.max(np.abs(samples))), 0)
            self.assertLessEqual(float(np.max(np.abs(samples))), 1)
            received.append(samples)
            segment = SimpleNamespace(start=0.1, end=0.8, text='synthetic test',
                avg_logprob=0, no_speech_prob=0, words=[])
            return iter([segment]), None

        # This test checks our PCM boundary, not the inference backend itself.
        # Install explicit test doubles so a clean offline test environment does
        # not need either large runtime package just to resolve a mock target.
        model = Mock()
        decoder = Mock(side_effect=AssertionError('PyAV file decoder must not run'))
        with patch.dict('sys.modules', {
            'faster_whisper': SimpleNamespace(WhisperModel=model),
            'av': SimpleNamespace(open=decoder),
        }):
            model.return_value.transcribe.side_effect = recognize
            cfg = dict(self.cfg, whisper_model_path=str(model_path))
            rows = worker.transcribe(audio, job, cfg)
            self.assertEqual(worker.transcribe(audio, job, cfg), rows)
        self.assertEqual(len(received), 1)
        decoder.assert_not_called()
        self.assertEqual(len(rows), 1)
        self.assertFalse((job / 'asr/00000.wav').exists())

    def test_trial_rejects_larger_budgets_duration_and_runtime(self):
        for delta in ({'max_text_requests':401}, {'max_qwen_requests':41},
                      {'max_video_seconds':1201}, {'device':'cuda'}, {'cpu_threads':3}):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                billing.validate_limits(dict(self.cfg, **delta))

    def test_trial_cannot_switch_to_a_different_source_sample(self):
        billing.bind_source(self.cfg, 'a'*64)
        billing.reserve(self.root/'job',self.cfg,'text')
        billing.bind_source(self.cfg, 'a'*64)
        with self.assertRaisesRegex(ValueError,'another source video'):
            billing.bind_source(self.cfg,'b'*64)
        ledger=worker.read(self.root/'allowance'/f'{billing.TRIAL_SCOPE}.json')
        self.assertEqual(ledger['text'],1)

    def test_model_install_verifies_revision_sizes_hashes_and_detects_corruption(self):
        model_root=self.root/'runtime';model_root.mkdir()
        destination=self.root/'model'
        lock={'repository':'test/mock-model','revision':'a'*40,'files':['model.bin','config.json'],
              'expected_download_bytes_upper_bound':1000,'destination':str(destination)}
        worker.save(model_root/'model.lock.json',lock)
        contents={'model.bin':b'mock-only-model-not-real-asr','config.json':b'{}'}
        siblings=[]
        for name,content in contents.items():
            siblings.append({'rfilename':name,'size':len(content),'blobId':hashlib.sha1(
                b'blob '+str(len(content)).encode()+b'\0'+content).hexdigest()})
        def download(url,timeout):
            if '/api/models/' in url:
                return io.BytesIO(json.dumps({'sha':lock['revision'],'siblings':siblings}).encode())
            return io.BytesIO(contents[url.rsplit('/',1)[1]])
        with patch.object(runtime,'ROOT',model_root),patch('urllib.request.urlopen',side_effect=download):
            runtime.install_model()
            self.assertTrue(runtime.model_ready()['ready'])
            manifest=worker.read(destination/'model-manifest.json')
            self.assertEqual(manifest['total_bytes'],sum(map(len,contents.values())))
            (destination/'model.bin').write_bytes(b'corrupted')
            self.assertFalse(runtime.model_ready()['ready'])

    def test_qwen_requires_explicit_credential_and_allowed_domain(self):
        policy = self.root / 'policy.json'
        worker.save(policy, {'version':1,'http_network_policy':{'type':'restricted','egress_rules':[]}})
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'credential is absent'):
                qwen_asr.readiness(self.cfg, policy)
        with patch.dict(os.environ, {'SUBTITLE_QWEN_TOKEN':'dummy-unit-test'}):
            with self.assertRaisesRegex(ValueError, 'target domain'):
                qwen_asr.readiness(self.cfg, policy)
        for url in ('http://dashscope.aliyuncs.com/compatible-mode/v1',
                    'https://api.openai.com/v1', 'https://evil.example/compatible-mode/v1'):
            with self.assertRaises(ValueError):
                qwen_asr.endpoint(dict(self.cfg,qwen_base_url=url))

    def test_qwen_inline_chunk_provenance_usage_and_resume_without_resend(self):
        audio = self.audio(2)
        job = self.root / 'job'
        cfg = dict(self.cfg, qwen_chunk_seconds=1)
        calls = []
        class Reply:
            status = 200
            def read(self, limit):
                return json.dumps({'id':'mock-id','choices':[{'finish_reason':'stop',
                    'message':{'content':'テストです。'}}], 'usage':{'input_tokens':12}}).encode()
            def close(self): pass
        def request(url, key, payload):
            calls.append(payload)
            inline=payload['messages'][0]['content'][0]['input_audio']['data']
            self.assertTrue(inline.startswith('data:audio/wav;base64,'))
            self.assertEqual(base64.b64decode(inline.split(',')[1])[:4],b'RIFF')
            return Reply()
        with (patch.object(qwen_asr,'readiness',return_value=('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions','dummy-test-value')),
             patch.object(qwen_asr,'open_request',side_effect=request)):
            rows=qwen_asr.recognize(audio,job,cfg)
        self.assertEqual([(r['start'],r['end']) for r in rows],[(0,1),(1,2)])
        self.assertEqual(len(calls),2)
        self.assertTrue(all(r['timing_method']=='source_audio_chunk_interval_not_word_alignment' for r in rows))
        self.assertEqual(worker.read(job/'qwen/00000/request-state.json')['usage'],{'input_tokens':12})
        with patch.object(qwen_asr,'open_request',side_effect=AssertionError('network forbidden')):
            self.assertEqual(rows,qwen_asr.recognize(audio,job,cfg))

    def test_qwen_codec_tail_uses_two_chunks_and_never_sends_past_60_seconds(self):
        import wave
        audio = self.audio(60.000375)
        lengths = []
        class Reply:
            status = 200
            def read(self, limit):
                return json.dumps({'choices':[{'finish_reason':'stop',
                    'message':{'content':'synthetic test'}}]}).encode()
            def close(self): pass
        def request(url, key, payload):
            inline = payload['messages'][0]['content'][0]['input_audio']['data']
            with wave.open(io.BytesIO(base64.b64decode(inline.split(',')[1])), 'rb') as source:
                lengths.append(source.getnframes())
            return Reply()
        with (patch.object(qwen_asr, 'readiness', return_value=('unused','dummy-test-value')),
              patch.object(qwen_asr, 'open_request', side_effect=request)):
            rows = qwen_asr.recognize(audio, self.root/'tail-job', self.cfg)
        self.assertEqual([(r['start'],r['end']) for r in rows], [(0,30),(30,60)])
        self.assertEqual(lengths, [480000,480000])
        with (patch.object(worker, 'probe', return_value=60.002),
              patch.object(qwen_asr, 'open_request') as request):
            with self.assertRaisesRegex(ValueError, 'exceeds'):
                qwen_asr.recognize(audio, self.root/'too-long', self.cfg)
            request.assert_not_called()

    def test_qwen_unknown_request_is_not_resent_after_restart(self):
        audio=self.audio()
        job=self.root/'job'
        worker.save(job/'qwen/00000/request-state.json',{'state':'request_in_progress_or_unknown'})
        with patch.object(qwen_asr,'open_request',side_effect=AssertionError('network forbidden')):
            with self.assertRaisesRegex(RuntimeError,'manual reconciliation'):
                qwen_asr.recognize(audio,job,self.cfg)

    def recovery_fixture(self):
        root = self.root/'platform'; job_id = 'test-job'; job = root/'jobs'/job_id
        audio = self.audio(60.000375)
        source = root/'inputs'/job_id/'source.media'; source.parent.mkdir(parents=True)
        source.write_bytes(audio.read_bytes())
        worker.save(root/'configs'/(job_id+'.json'),self.cfg)
        worker.save(job/'identity.json',{'input_sha256':worker.digest(source),
            'config_sha256':qwen_recovery.config_hash(self.cfg)})
        worker.save(job/'qwen/00000/request-state.json',
            {'state':'api_rejected','http_status':401,'automatic_retries':0})
        billing.bind_source(self.cfg,worker.digest(source))
        billing.reserve(job,self.cfg,'qwen')
        record = qwen_recovery.plan(root,job_id)
        path = self.root/'recovery-plan.json'; worker.save(path,record)
        return root,job_id,job,audio,path

    def test_recovery_plan_preserves_401_budget_and_requires_unchanged_source(self):
        root,jid,job,audio,path = self.recovery_fixture()
        self.assertEqual(worker.read(path)['state'],'planned_not_activated')
        self.assertFalse((job/'reconciliation').exists())
        self.assertEqual(worker.read(billing.TRIAL_STATE_ROOT/(billing.TRIAL_SCOPE+'.json'))['qwen'],1)
        (root/'inputs'/jid/'source.media').write_bytes(b'changed source')
        with self.assertRaisesRegex(ValueError,'source'):
            qwen_recovery.apply_plan(root,jid,self.cfg,path)

    def test_recovery_adapter_cannot_select_another_queue_job(self):
        import platform_worker
        with patch.object(platform_worker, 'Client') as client:
            with self.assertRaises(platform_worker.ConfigurationMissing):
                platform_worker.execute(argparse.Namespace(job_id=None,work_root=self.root,
                    qwen_recovery_plan=self.root/'plan.json'))
            client.assert_not_called()

    def test_recovery_rejects_unknown_or_modified_prior_request(self):
        root,jid,job,audio,path = self.recovery_fixture()
        worker.save(job/'qwen/00000/request-state.json',{'state':'request_in_progress_or_unknown'})
        with self.assertRaises(ValueError): qwen_recovery.plan(root,jid)
        with self.assertRaises(ValueError): qwen_recovery.apply_plan(root,jid,self.cfg,path)

    def test_explicit_full60_recovery_spends_only_remaining_attempt_and_never_retries(self):
        import wave
        root,jid,job,audio,path = self.recovery_fixture()
        marker = job/'qwen/00000/request-state.json'; original = marker.read_bytes()
        cfg = qwen_recovery.apply_plan(root,jid,self.cfg,path)
        self.assertEqual(marker.read_bytes(),original)
        self.assertEqual(worker.read(job/'reconciliation/original-identity.json')['config_sha256'],
                         qwen_recovery.config_hash(self.cfg))
        class Reply:
            status = 200
            def read(self,limit): return json.dumps({'choices':[{'finish_reason':'stop',
                'message':{'content':'synthetic test'}}],'usage':{'input_tokens':10}}).encode()
            def close(self): pass
        def request(url,key,payload):
            inline = payload['messages'][0]['content'][0]['input_audio']['data']
            self.assertLess(len(inline),10_000_000)
            with wave.open(io.BytesIO(base64.b64decode(inline.split(',')[1])),'rb') as wav:
                self.assertEqual(wav.getnframes(),960000)
            return Reply()
        with (patch.object(qwen_asr,'readiness',return_value=('unused','dummy-test-value')),
              patch.object(qwen_asr,'open_request',side_effect=request) as calls):
            rows=qwen_asr.recognize(audio,job,cfg)
            self.assertEqual(rows,qwen_asr.recognize(audio,job,cfg))
            self.assertEqual(calls.call_count,1)
        self.assertEqual([(r['start'],r['end']) for r in rows],[(0,60)])
        self.assertEqual(marker.read_bytes(),original)
        self.assertEqual(worker.read(billing.TRIAL_STATE_ROOT/(billing.TRIAL_SCOPE+'.json'))['qwen'],2)
        self.assertEqual(qwen_recovery.apply_plan(root,jid,self.cfg,path),cfg)

    def test_explicit_recovery_unknown_new_request_cannot_be_resent(self):
        root,jid,job,audio,path = self.recovery_fixture()
        cfg=qwen_recovery.apply_plan(root,jid,self.cfg,path)
        worker.save(job/'qwen/reconciled-full60-00000/request-state.json',
                    {'state':'request_in_progress_or_unknown'})
        with patch.object(qwen_asr,'open_request') as calls:
            with self.assertRaisesRegex(RuntimeError,'manual reconciliation'):
                qwen_asr.recognize(audio,job,cfg)
            calls.assert_not_called()

    def test_qwen_rejection_and_timeout_never_retry(self):
        audio=self.audio()
        class Rejected:
            status=429
            def read(self,limit): return b'{}'
            def close(self): pass
        for name, reply in [('rejected',Rejected()),('timeout',TimeoutError())]:
            job=self.root/name
            with (patch.object(qwen_asr,'readiness',return_value=('unused','dummy-test-value')),
                 patch.object(qwen_asr,'open_request',side_effect=reply if isinstance(reply,Exception) else None,return_value=reply) as request):
                with self.assertRaises((RuntimeError,TimeoutError)):
                    qwen_asr.recognize(audio,job,self.cfg)
                with self.assertRaisesRegex(RuntimeError,'manual reconciliation'):
                    qwen_asr.recognize(audio,job,self.cfg)
                self.assertEqual(request.call_count,1)

    def test_new_recognition_pipeline_without_primary_or_secondary(self):
        audio=self.audio()
        config=self.root/'config.json'; worker.save(config,self.cfg)
        args=argparse.Namespace(video=audio,config=config,execute=True,primary=None,secondary=None,
            work_root=self.root,job_id='fresh',primary_source_sha256=None)
        rows=[{'id':1,'start':0.1,'end':0.8,'text':'テストです。'}]
        original_read=worker.read
        def read(path):
            if Path(path).name == 'model-manifest.json':
                return {'revision':'mock-only','files':[]}
            return original_read(path)
        with (patch('runtime.model_ready',return_value={'ready':True}),
             patch.object(qwen_asr,'readiness',return_value=('unused','dummy-test-value')),
             patch.object(worker,'transcribe',return_value=rows) as transcribe,
             patch.object(qwen_asr,'recognize',return_value=rows) as recognize,
             patch.object(worker,'read',side_effect=read),
             patch.object(worker,'relay',side_effect=lambda rows,*args:worker.merge(rows,[{'id':1,'zh':'这是测试。'}]))):
            worker.run(args)
        transcribe.assert_called_once(); recognize.assert_called_once()
        proof=worker.read(self.root/'fresh/delivery/recognition-provenance.json')
        self.assertEqual(proof['primary_mode'],'whisper_executed_in_this_job')
        self.assertEqual(proof['secondary_mode'],'qwen3_asr_flash_executed_in_this_job')
        self.assertIn('not word',proof['secondary_timing'])
        self.assertTrue((self.root/'fresh/delivery/usage.json').exists())


if __name__=='__main__':
    unittest.main()

