import importlib.util,json,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('configure',ROOT/'tools/configure.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ConfigureTests(unittest.TestCase):
 def cfg(self):return dict(environment_id='fixture-community',website_url='https://fixture.tcloudbaseapp.com/',cloud_environment_name='subtitle-test',text_api_url='https://fixture-provider.test/v1',text_model='synthetic-model',owner_auth_subject='fixture-owner')
 def test_rejects_injection_and_wrong_protocol(self):
  for key,value in [('environment_id',"x';DROP TABLE x;--"),('website_url','javascript:alert(1)'),('text_api_url','https://evil.test/v1?key=x'),('owner_auth_subject',"x';--"),('cloud_environment_name','$(bad)'),('text_model','bad\nmodel')]:
   c=self.cfg();c[key]=value
   with self.assertRaises(ValueError):m.validate(c)
 def test_official_text_route_not_silently_enabled(self):
  c=self.cfg();c['text_api_url']='https://api.openai.com/v1'
  with self.assertRaises(ValueError):m.validate(c)
 def test_generation_has_no_real_secrets_and_no_unconfigured_backend(self):
  with tempfile.TemporaryDirectory() as t:
   out=Path(t)/'deployment';m.render(self.cfg(),out)
   self.assertIn('fixture-community.api.tcloudbasegateway.com',(out/'site/app.js').read_text(encoding='utf8'))
   sql=(out/'database/INSTALL_ALL.sql').read_text(encoding='utf8')
   self.assertTrue(sql.startswith('BEGIN;'));self.assertTrue(sql.endswith('COMMIT;\n'))
   self.assertIn('Only install into an empty environment',sql)
   self.assertIn('fixture-owner',(out/'database/SET_FIRST_OWNER.sql').read_text(encoding='utf8'))
   self.assertNotIn('administrator',(out/'database/SET_FIRST_OWNER.sql').read_text(encoding='utf8'))
   self.assertFalse((out/'bot/subtitle_bridge.json').exists())
   with self.assertRaises(ValueError):m.render(self.cfg(),out)
 def test_website_only_can_leave_provider_inert(self):
  c=self.cfg();c['text_api_url']='https://text-provider.example.invalid/v1';m.validate(c)
if __name__=='__main__':unittest.main()
