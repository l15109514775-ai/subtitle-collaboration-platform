"""Offline/synthetic tests; never evidence of the requested livestream delivery."""
from datetime import datetime,timedelta,timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import clip_pipeline as clip
import clip_budget
import worker


class ClipTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)

    def fixture(self):
        rows=[{'id':1,'start':0.2,'end':1.2,'text':'浮気判定について。'},
              {'id':2,'start':1.3,'end':2.8,'text':'どこから浮気ですか。'}]
        worker.save(self.root/'transcript.json',rows)
        worker.save(self.root/'source-verified.json',{'sha256':'a'*64,'duration':3})
        return {'source_sha256':'a'*64,'transcript_sha256':worker.digest(self.root/'transcript.json'),
                'start':0,'end':3,'topic_confirmed':True,'complete_exchange_confirmed':True,
                'boundary_reason':'Synthetic complete exchange fixture','reviewed_by':'offline_fixture',
                'approved_chinese_title':'出轨如何判定'},rows

    def auth(self):
        return {'scope':'clip-PTL-ZkyrSPA-v1','approved':True,
                'job_id':'11111111-1111-4111-8111-111111111111',
                'lease_id':'22222222-2222-4222-8222-222222222222',
                'source_sha256':'a'*64,'clip_seconds':3,'max_text_requests':20,'max_qwen_requests':2,
                'expires_at':(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat()}

    def test_url_is_canonical_and_ssrf_auth_rejected(self):
        self.assertEqual(clip.canonical_url('https://www.youtube.com/live/PTL-ZkyrSPA?si=abc'),
                         ('PTL-ZkyrSPA','https://www.youtube.com/watch?v=PTL-ZkyrSPA'))
        for u in ('http://www.youtube.com/watch?v=PTL-ZkyrSPA',
                  'https://www.youtube.com.evil/watch?v=PTL-ZkyrSPA',
                  'https://user@www.youtube.com/watch?v=PTL-ZkyrSPA',
                  'https://www.youtube.com:8443/watch?v=PTL-ZkyrSPA',
                  'https://127.0.0.1/live/PTL-ZkyrSPA'):
            with self.assertRaises(ValueError):clip.canonical_url(u)

    def test_probe_policy_denial_is_not_video_unavailability(self):
        import urllib.error
        with patch.object(clip.urllib.request,'urlopen',side_effect=urllib.error.URLError('Tunnel connection failed: 403 Forbidden')):
            result=clip.probe('https://www.youtube.com/watch?v=PTL-ZkyrSPA',self.root,clip.Deadline(5))
        self.assertEqual(result['actually_blocked_hosts'],['www.youtube.com'])
        self.assertIsNone(result['duration'])
        self.assertEqual(result['subtitle_availability'],'unknown')

    def test_json3_rolling_duplicate_and_markup(self):
        rows=clip.caption_rows({'events':[
            {'tStartMs':0,'dDurationMs':1000,'segs':[{'utf8':'浮気'}]},
            {'tStartMs':500,'dDurationMs':1000,'segs':[{'utf8':'浮気'}]},
            {'tStartMs':1600,'dDurationMs':1000,'segs':[{'utf8':'<b>判定</b>'}]}]})
        self.assertEqual(len(rows),2);self.assertEqual(rows[0]['end'],1.5)
        self.assertEqual(rows[1]['text'],'判定')

    def test_candidates_require_topic_and_never_assert_selection(self):
        _,rows=self.fixture()
        found=clip.candidates(rows)
        self.assertTrue(found)
        self.assertIn('requires_topic_and_boundary_review',found[0]['state'])
        self.assertEqual(clip.candidates([{'id':1,'start':0,'end':3,'text':'どこから来ましたか。'}]),[])

    def test_selection_fails_closed_on_changed_source_cut_or_unreviewed_topic(self):
        selection,_=self.fixture()
        self.assertEqual(len(clip.validate_selection(self.root,selection)),2)
        for change in ({'start':.5},{'topic_confirmed':False},{'source_sha256':'b'*64},
                       {'transcript_sha256':'b'*64},{'complete_exchange_confirmed':False}):
            with self.assertRaises(ValueError):clip.validate_selection(self.root,dict(selection,**change))

    def test_full_topic_supported_over_authorized_seventy_minutes_rejected(self):
        selection,_=self.fixture()
        worker.save(self.root/'source-verified.json',{'sha256':'a'*64,'duration':5000})
        self.assertEqual(len(clip.validate_selection(self.root,dict(selection,end=3848))),2)
        with self.assertRaises(ValueError):clip.validate_selection(self.root,dict(selection,end=4201))

    def test_new_budget_cumulative_guard_and_source_binding(self):
        calls=[]
        with patch.object(clip_budget,'STATE_ROOT',self.root/'budgets'):
            b=clip_budget.ClipBudget(self.auth(),calls.append)
            self.assertEqual(b.reserve('qwen')['qwen'],1)
            again=clip_budget.ClipBudget(self.auth(),calls.append)
            self.assertEqual(again.reserve('qwen')['qwen'],2)
            with self.assertRaises(ValueError):again.reserve('qwen')
            wrong=clip_budget.ClipBudget(dict(self.auth(),source_sha256='b'*64),calls.append)
            with self.assertRaises(ValueError):wrong.reserve('text')
            self.assertEqual(worker.read(b.path)['qwen'],2)
        self.assertEqual(calls,['qwen','qwen','qwen','text'])

    def test_budget_revoked_guard_cannot_reserve_and_old_scope_rejected(self):
        def revoked(_):raise RuntimeError('revoked')
        with patch.object(clip_budget,'STATE_ROOT',self.root/'budgets'):
            b=clip_budget.ClipBudget(self.auth(),revoked)
            with self.assertRaises(RuntimeError):b.reserve('qwen')
            self.assertFalse(b.path.exists())
            with self.assertRaises(ValueError):clip_budget.ClipBudget(dict(self.auth(),scope='trial-60s-20261021'),revoked)

    def test_expired_and_higher_budget_rejected(self):
        for change in ({'max_qwen_requests':3},{'max_text_requests':21},{'clip_seconds':4201},{'approved':False}):
            with self.assertRaises(ValueError):clip_budget.ClipBudget(dict(self.auth(),**change),lambda _:None)
        expired=dict(self.auth(),expires_at='2020-01-01T00:00:00+00:00')
        with self.assertRaises(ValueError):clip_budget.ClipBudget(expired,lambda _:None).reserve('text')

    def test_real_input_duration_and_complete_topic_batch_plan(self):
        self.assertTrue(clip.source_duration_allowed(4*3600))
        self.assertTrue(clip.source_duration_allowed(6*3600))
        self.assertFalse(clip.source_duration_allowed(21601))
        self.assertFalse(clip.source_duration_allowed(float('nan')))
        rows=[{'id':i+1,'text':'浮気の価値観について話しています。'*2} for i in range(413)]
        batches=clip_budget.translation_batches(rows)
        self.assertLessEqual(2*len(batches),20)
        self.assertTrue(all(len(b)<=150 for b in batches))
        self.assertEqual([r['id'] for b in batches for r in b],list(range(1,414)))
        with self.assertRaises(ValueError):clip_budget.translation_batches(rows*10)

    def test_trial_qwen_cannot_expand_audio_bound_without_new_reservation(self):
        import qwen_asr
        with patch.object(worker,'probe',return_value=180):
            with self.assertRaises(ValueError):qwen_asr.recognize('fixture.wav',self.root,
                {'max_video_seconds':300,'qwen_chunk_seconds':300},max_chunk_seconds=300)

    def test_render_actual_synthetic_media_and_cjk_cover(self):
        if not clip.FONT.exists():self.skipTest('CJK font unavailable')
        selection,rows=self.fixture()
        deadline=clip.Deadline(90)
        deadline.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','color=c=blue:s=640x360:r=10:d=3',
                      '-f','lavfi','-i','sine=frequency=300:duration=3','-shortest',
                      '-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(self.root/'source.mp4')])
        selection['source_sha256']=worker.digest(self.root/'source.mp4')
        worker.save(self.root/'source-verified.json',{'sha256':selection['source_sha256'],'duration':3})
        worker.save(self.root/'transcript-provenance.json',{'kind':'synthetic_offline_fixture'})
        translated=[dict(r,zh='出轨如何判定',review=True) for r in rows]
        worker.save(self.root/'translated.json',translated)
        result=clip.render(self.root,selection,self.root/'translated.json','出轨如何判定',deadline)
        self.assertEqual(result['state'],'rendered_not_uploaded')
        raw=subprocess.check_output(['ffprobe','-v','error','-show_entries','stream=width,height',
                                     '-of','json',str(self.root/'render/cover.png')])
        dimensions=json.loads(raw)['streams'][0]
        self.assertEqual((dimensions['width'],dimensions['height']),(1280,720))
        manifest=worker.read(self.root/'render/manifest.json')
        self.assertTrue(manifest['human_review_required'])
        for f in manifest['files']:
            self.assertEqual(f['sha256'],worker.digest(self.root/'render'/f['name']))


if __name__=='__main__':unittest.main()

