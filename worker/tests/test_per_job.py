"""Synthetic per-job tests. Windows adapters do not prove POSIX locking."""
import json,sys,tempfile,types,unittest
from pathlib import Path
from unittest.mock import Mock,patch
ROOT=Path(__file__).resolve().parents[1]
WORKER=ROOT if (ROOT/'billing.py').exists() else ROOT/'worker'
sys.path.insert(0,str(WORKER))
if sys.platform=='win32':sys.modules['fcntl']=types.SimpleNamespace(LOCK_EX=2,LOCK_UN=8,flock=lambda *args:None)
import billing,worker,platform_worker as platform
JOB='810f48af-ddaa-4305-a9b3-353c697ddfcc'
OTHER='b7a19616-6641-4b9d-b398-0e91ad644443'
class PerJobTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir=ROOT/'tests');self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  def save(path,value):
   path=Path(path);path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value),encoding='utf-8')
  for context in (patch.object(worker,'save',save),patch.object(billing,'JOB_STATE_ROOT',self.root/'jobs'),patch.object(billing,'TRIAL_STATE_ROOT',self.root/'trial')):
   context.start();self.addCleanup(context.stop)
  self.cfg=dict(worker.read(WORKER/'config.example.json'),billable_execution_approved=True,platform_managed=True,
   platform_job_id=JOB,authorization_scope='job-'+JOB,authorized_sha256='a'*64,max_text_requests=2,max_qwen_requests=1)
 def receipt(self,text=1,qwen=0,scope=None):return {'state':'reserved','authorization_scope':scope or self.cfg['authorization_scope'],'counts':{'text':text,'qwen':qwen}}
 def test_different_videos_have_independent_scopes_and_trial_is_untouched(self):
  trial=self.root/'trial'/(billing.TRIAL_SCOPE+'.json');worker.save(trial,{'text':34,'qwen':40,'input_sha256':'c'*64})
  second=dict(self.cfg,platform_job_id=OTHER,authorization_scope='job-'+OTHER,authorized_sha256='b'*64)
  for cfg,sha in ((self.cfg,'a'*64),(second,'b'*64)):
   billing.bind_source(cfg,sha)
   with billing.request_guard(lambda p:self.receipt(scope=cfg['authorization_scope'])):billing.reserve(self.root,cfg,'text')
   self.assertEqual(billing.snapshot(cfg)['text'],1)
  self.assertEqual(worker.read(trial)['text'],34)
 def test_job_cannot_change_source(self):
  with self.assertRaises(ValueError):billing.bind_source(self.cfg,'b'*64)
 def test_changed_scope_or_non_platform_config_cannot_spend(self):
  for change in ({'authorization_scope':'job-'+OTHER},{'platform_managed':False},{'authorized_sha256':'../bad'}):
   with self.subTest(change=change),self.assertRaises(ValueError):billing.validate_limits(dict(self.cfg,**change))
 def test_fresh_local_filesystem_uses_server_counts_not_zero(self):
  with billing.request_guard(lambda p:self.receipt(text=2)):billing.reserve(self.root,self.cfg,'text')
  self.assertEqual(billing.snapshot(self.cfg)['text'],2)
  billing.ledger_path(self.cfg).unlink()
  with billing.request_guard(lambda p:(_ for _ in ()).throw(RuntimeError('server quota exhausted'))),self.assertRaises(RuntimeError):billing.reserve(self.root,self.cfg,'text')
 def test_missing_wrong_or_out_of_range_server_receipt_rejected(self):
  for receipt in (None,{},self.receipt(scope='job-'+OTHER),self.receipt(text=3),self.receipt(text=True)):
   with self.subTest(receipt=receipt),billing.request_guard(lambda p:receipt),self.assertRaises(RuntimeError):billing.reserve(self.root,self.cfg,'text')
 def test_receipt_counters_never_move_backwards(self):
  with billing.request_guard(lambda p:self.receipt(text=2)):billing.reserve(self.root,self.cfg,'text')
  with billing.request_guard(lambda p:self.receipt(text=1)),self.assertRaises(RuntimeError):billing.reserve(self.root,self.cfg,'text')
 def test_caps_cannot_exceed_20_minutes_400_text_40_qwen(self):
  for change in ({'max_video_seconds':1201},{'max_text_requests':401},{'max_qwen_requests':41}):
   with self.assertRaises(ValueError):billing.validate_limits(dict(self.cfg,**change))
 def test_claim_derives_scope_and_source_only_from_server_claim(self):
  cfg=platform.limited_config({'job_id':JOB,'sha256':'a'*64,'authorization_scope':'job-'+JOB,'max_video_seconds':1200,'max_text_requests':400,'max_secondary_requests':40})
  self.assertEqual(cfg['platform_job_id'],JOB);self.assertEqual(cfg['authorized_sha256'],'a'*64)
 def test_live_guard_reserves_server_side_and_checks_scope(self):
  claim={'job_id':JOB,'lease_id':OTHER,'authorization_scope':'job-'+JOB}
  client=Mock();client.call.return_value=self.receipt()
  lease=platform.Lease(client,claim)
  with patch.object(lease,'pulse'):
   self.assertEqual(lease.before_reserve('text')['state'],'reserved')
  self.assertEqual(client.call.call_args.args[:2],('reserve',JOB))
  self.assertEqual(client.call.call_args.args[2]['lease_id'],OTHER)
 def test_queue_wide_execution_is_disabled(self):
  with self.assertRaises(platform.ConfigurationMissing):platform.execute(types.SimpleNamespace(job_id=None))
if __name__=='__main__':unittest.main(verbosity=2)

