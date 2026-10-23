"""Offline budget tests. Windows adapters do not verify Linux fsync/flock."""
import contextlib,importlib, json, pathlib, sys, tempfile, types, unittest
from unittest.mock import patch

ROOT=pathlib.Path(__file__).parent
sys.path.insert(0,str(ROOT))
if sys.platform=='win32':
    sys.modules['fcntl']=types.SimpleNamespace(LOCK_EX=2,LOCK_UN=8,flock=lambda *args:None)
import billing,worker,platform_worker

class LimitsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=ROOT);self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)
        self.cfg=dict(worker.read(ROOT/'config.example.json'),billable_execution_approved=True,max_text_requests=400,max_qwen_requests=40)
        # Exercise production accounting with local persistence. The Windows
        # adapter only replaces POSIX directory-fsync; no HTTP/provider called.
        def save(path,value):
            path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True)
            tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(value),encoding='utf-8');tmp.replace(path)
        for p in [patch.object(billing,'TRIAL_STATE_ROOT',self.root),patch.object(worker,'save',save)]:
            p.start();self.addCleanup(p.stop)

    def test_exact_twenty_minute_profile(self):
        billing.validate_limits(self.cfg)
        self.assertEqual(self.cfg['max_video_seconds'],1200)
        self.assertEqual(self.cfg['qwen_chunk_seconds'],30)
        self.assertEqual(1200//30,self.cfg['max_qwen_requests'])

    def test_reject_bad_duration_request_caps_and_runtime(self):
        for key,values in [('max_video_seconds',[0,-1,1201,1200.0,True]),('max_text_requests',[-1,401,400.0,True]),('max_qwen_requests',[-1,41,40.0,True])]:
            for value in values:
                with self.subTest(key=key,value=value),self.assertRaises(ValueError):billing.validate_limits(dict(self.cfg,**{key:value}))
        with self.assertRaises(ValueError):billing.validate_limits(dict(self.cfg,device='cuda'))

    def test_shared_400_text_40_qwen_caps_across_work_directories(self):
        for provider,cap in [('text',400),('qwen',40)]:
            for i in range(cap):billing.reserve(self.root/str(i),self.cfg,provider)
            with self.assertRaises(RuntimeError):billing.reserve(self.root/'different-directory',self.cfg,provider)
        ledger=worker.read(self.root/(billing.TRIAL_SCOPE+'.json'))
        self.assertEqual((ledger['text'],ledger['qwen']),(400,40))

    def test_lower_per_job_ceiling_is_respected(self):
        cfg=dict(self.cfg,max_text_requests=1)
        billing.reserve(self.root,cfg,'text')
        with self.assertRaises(RuntimeError):billing.reserve(self.root,cfg,'text')

    def test_old_scope_rejected_and_old_ledger_unchanged(self):
        old=self.root/'trial-60s-20261021.json';old.write_text('{"text":2,"qwen":2}')
        with self.assertRaises(ValueError):billing.reserve(self.root,dict(self.cfg,authorization_scope='trial-60s-20261021'),'text')
        billing.reserve(self.root,self.cfg,'text')
        self.assertEqual(old.read_text(),'{"text":2,"qwen":2}')

    def test_new_scope_remains_bound_to_one_video(self):
        billing.bind_source(self.cfg,'a'*64)
        with self.assertRaises(ValueError):billing.bind_source(self.cfg,'b'*64)

    def test_disabled_example_and_missing_lease_guard_cannot_spend(self):
        with self.assertRaises(ValueError):billing.reserve(self.root,worker.read(ROOT/'config.example.json'),'text')
        with self.assertRaises(RuntimeError):billing.reserve(self.root,dict(self.cfg,platform_managed=True),'text')
        self.assertFalse((self.root/(billing.TRIAL_SCOPE+'.json')).exists())

    def test_provider_guard_runs_before_reservation(self):
        def denied(provider):raise RuntimeError('lease denied')
        with billing.request_guard(denied),self.assertRaises(RuntimeError):billing.reserve(self.root,dict(self.cfg,platform_managed=True),'text')
        self.assertFalse((self.root/(billing.TRIAL_SCOPE+'.json')).exists())

    def test_claim_limits_are_intersected_with_environment_caps(self):
        cfg=platform_worker.limited_config({'max_video_seconds':9999,'max_text_requests':9999,'max_secondary_requests':9999})
        self.assertEqual((cfg['max_video_seconds'],cfg['max_text_requests'],cfg['max_qwen_requests']),(1200,400,40))
        cfg=platform_worker.limited_config({'max_video_seconds':60,'max_text_requests':4,'max_secondary_requests':1})
        self.assertEqual((cfg['max_video_seconds'],cfg['max_text_requests'],cfg['max_qwen_requests']),(60,4,1))

    def test_unknown_provider_does_not_consume_a_slot(self):
        with self.assertRaises(ValueError):billing.reserve(self.root,self.cfg,'unknown')

if __name__=='__main__':unittest.main(verbosity=2)

