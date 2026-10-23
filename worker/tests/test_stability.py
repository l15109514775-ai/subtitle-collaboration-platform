"""Synthetic acceptance fixtures: no real media, credentials or paid requests."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import delivery_contract as contract
import platform_worker as platform
import worker


def cue(ident=1, start=0, end=2, text='テスト', zh='测试', **extra):
    return dict(id=ident, start=start, end=end, text=text, zh=zh, review=False, **extra)


class StabilityTests(unittest.TestCase):
    def test_20_minute_word_rich_bundle_preserves_subtitles_and_fits(self):
        rows=[cue(i+1,i*3,i*3+2,text='今日はテストです。',zh='今天是测试。',
                  words=[dict(word='テスト',start=i*3+j*.1,end=i*3+j*.1+.1,probability=.99) for j in range(10)]) for i in range(400)]
        original=json.dumps(rows,ensure_ascii=False,indent=2).encode()
        self.assertGreater(len(original),contract.MAX_FILE_BYTES)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); delivery=root/'delivery'
            worker.save(root/'primary-cues.json',rows)
            raw=(root/'primary-cues.json').read_bytes()
            worker.export(rows,delivery)
            worker.save(delivery/'cues.json',contract.compact_cues(rows))
            worker.save(delivery/'quality.json',worker.quality(rows,1200))
            for name in ('recognition-provenance.json','manifest.json','usage.json'):
                worker.save(delivery/name,{'synthetic':True})
            self.assertLess(contract.check_delivery(delivery),contract.MAX_DELIVERY_BYTES)
            self.assertEqual(len(platform.bundle(delivery)),9)
            published=worker.read(delivery/'cues.json')
            self.assertNotIn('words',published[0])
            self.assertEqual([(r['id'],r['start'],r['end'],r['text'],r['zh']) for r in published],
                             [(r['id'],r['start'],r['end'],r['text'],r['zh']) for r in rows])
            self.assertEqual((root/'primary-cues.json').read_bytes(),raw)

    def test_preflight_rejects_known_impossible_source(self):
        with self.assertRaisesRegex(ValueError,'no further model calls'):
            contract.preflight_delivery([cue(text='字'*170000)])

    def test_impossible_delivery_stops_pipeline_before_qwen_and_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);video=root/'source.mp4';video.write_bytes(b'synthetic')
            primary=root/'primary.json';worker.save(primary,[cue(text='字'*170000)])
            args=SimpleNamespace(primary=primary,primary_source_sha256=worker.digest(video),secondary=None,job_id='test')
            cfg=dict(worker.read(Path(worker.__file__).with_name('config.example.json')),max_qwen_requests=1)
            with patch.object(worker,'text_readiness'),patch('qwen_asr.readiness'),patch.object(worker,'bind_source'),patch.object(worker,'prepare_audio'),patch('qwen_asr.recognize',side_effect=AssertionError('no Qwen billing')) as qwen,patch.object(worker,'relay',side_effect=AssertionError('no text billing')) as text:
                with self.assertRaisesRegex(ValueError,'no further model calls'):
                    worker.execute_job(args,cfg,video,2,root/'job')
            qwen.assert_not_called();text.assert_not_called()

    def test_preflight_does_not_claim_future_size_guarantee(self):
        self.assertFalse(contract.preflight_delivery([cue()])['final_size_guaranteed'])

    def test_exact_size_failure_keeps_all_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in contract.REQUIRED_FILES:(root/name).write_bytes(b'{}')
            (root/'usage.json').write_bytes(b'x'*500001)
            with self.assertRaisesRegex(ValueError,'usage.json'):
                contract.check_delivery(root)
            self.assertEqual(len(list(root.iterdir())),9)

    def test_total_size_is_independently_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in contract.REQUIRED_FILES:(root/name).write_bytes(b'x'*250000)
            with self.assertRaisesRegex(ValueError,'total size'):
                contract.check_delivery(root)

    def test_unsorted_cues_receive_all_in_window_secondary_evidence(self):
        rows=[cue(2,10,12),cue(1,0,2)]
        reply={'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':json.dumps([{'id':r['id'],'zh':'测试'} for r in rows])}]}]}
        class Response:
            status=200
            def read(self,limit):return json.dumps(reply).encode()
            def close(self):pass
        cfg=dict(worker.read(Path(worker.__file__).with_name('config.example.json')),max_text_requests=2)
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ,{'SUBTITLE_GPT_TOKEN':'synthetic-only'}), patch.object(worker,'reserve'), patch.object(worker,'open_relay_request',return_value=Response()) as request:
            result=worker.relay(rows,Path(tmp)/'job/text/batch',cfg,'translate',
                                [cue(3,1,2,text='前半'),cue(4,11,12,text='後半'),cue(5,20,22,text='外側')])
            payload=json.loads(request.call_args.args[2]['input'][0]['content'][0]['text'])
            self.assertEqual(payload['secondary_text'],['前半','後半'])
            self.assertEqual([r['id'] for r in result],[2,1])

    def test_export_sorts_without_renumbering_source_ids_or_mutating_input(self):
        rows=[cue(9,10,12,text='後半',zh='后半'),cue(7,0,2,text='前半',zh='前半')]
        with tempfile.TemporaryDirectory() as tmp:
            worker.export(rows,Path(tmp))
            text=(Path(tmp)/'Bilingual.ass').read_text(encoding='utf-8-sig')
            self.assertLess(text.index('前半'),text.index('後半'))
        self.assertEqual([r['id'] for r in contract.compact_cues(rows)],[7,9])
        self.assertEqual([r['id'] for r in rows],[9,7])

    def test_nested_nonadjacent_overlaps_are_reported(self):
        report=worker.quality([cue(1,0,10),cue(2,1,2),cue(3,3,4)],10)
        warnings={r['id']:r for r in report['warnings'] if 'overlap' in r['reason']}
        self.assertEqual(set(warnings),{2,3})
        self.assertEqual(warnings[3]['overlaps_with'],1)

    def test_overlap_grace_and_disjoint_intervals(self):
        report=worker.quality([cue(1,0,2),cue(2,1.96,3),cue(3,3,4)],4)
        self.assertFalse(any('overlap' in r['reason'] for r in report['warnings']))

    def test_dense_overlaps_have_linear_bounded_report(self):
        report=worker.quality([cue(i+1,0,10) for i in range(2000)],10)
        self.assertEqual(sum('overlap' in r['reason'] for r in report['warnings']),1999)

    def test_unchanged_numeric_subtitles_are_valid(self):
        for source,zh in [('2026','2026'),('２：１','2:1'),('99.5%','99.5%'),('￥1,000','¥1,000'),('-3.5','-3.5')]:
            with self.subTest(source=source):
                result=worker.merge([cue(text=source)],[{'id':1,'zh':zh}])
                self.assertEqual(result[0]['zh'],zh)

    def test_numeric_exception_cannot_change_values_or_drop_prose(self):
        for source,zh in [('2026','2027'),('2:1','1:2'),('2026年です','2026'),('日本語','123'),('abc','abc'),('','123'),('2026','2026<script>')]:
            with self.subTest(source=source,zh=zh),self.assertRaises(ValueError):
                worker.merge([cue(text=source)],[{'id':1,'zh':zh}])

    def test_saved_numeric_response_recovers_without_billing(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)/'job/text/batch'
            worker.save(folder/'response.json',{'status':'completed','output':[{'type':'message','content':[{'type':'output_text','text':'[{"id":1,"zh":"2026"}]'}]}]})
            with patch.object(worker,'open_relay_request',side_effect=AssertionError('no network')),patch.object(worker,'reserve',side_effect=AssertionError('no charge')):
                result=worker.relay([cue(text='2026')],folder,worker.read(Path(worker.__file__).with_name('config.example.json')),'translate',[])
            self.assertEqual(result[0]['zh'],'2026')
