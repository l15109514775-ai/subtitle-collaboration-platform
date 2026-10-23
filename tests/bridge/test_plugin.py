"""Adapter contract tests; mocked SDK/network, no QQ messages or live data."""
import asyncio
import importlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'bot/plugins'))
def module(name,**attrs):
    m=types.ModuleType(name);m.__dict__.update(attrs);sys.modules[name]=m;return m
class Star:
    def __init__(self,context):pass
class Event:
    def __init__(self,text,group='',platform='default_YOUR_QQ_APP_ID',sender='synthetic-user'):
        self.text=text;self.group=group;self.platform=platform;self.sender=sender;self.stopped=False
    def get_message_str(self):return self.text
    def get_platform_name(self):return 'qq_official'
    def get_platform_id(self):return self.platform
    def get_group_id(self):return self.group
    def get_sender_id(self):return self.sender
    def is_private_chat(self):return not self.group
    def stop_event(self):self.stopped=True
    def plain_result(self,text):return text
calls=[]
class Response:
    status=200
    async def __aenter__(self):return self
    async def __aexit__(self,*args):pass
    async def json(self):return {'state':'bound','name':'synthetic-member'}
class Client:
    def __init__(self,**kwargs):pass
    async def __aenter__(self):return self
    async def __aexit__(self,*args):pass
    def post(self,url,**kwargs):calls.append((url,kwargs));return Response()
module('aiohttp',ClientSession=Client,ClientTimeout=lambda **kwargs:None,ClientError=ConnectionError)
module('astrbot');module('astrbot.api')
module('astrbot.api.event',AstrMessageEvent=Event,filter=types.SimpleNamespace(event_message_type=lambda *a,**k:lambda f:f,EventMessageType=types.SimpleNamespace(ALL=1)))
module('astrbot.api.star',Context=object,Star=Star,register=lambda *args:lambda c:c)
plugin=importlib.import_module('astrbot_plugin_subtitle_bridge.main')
logic=importlib.import_module('astrbot_plugin_subtitle_bridge.bridge')
class Tests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        calls.clear();self.temp=tempfile.TemporaryDirectory(dir=ROOT/'tests');self.bot=plugin.SubtitleBridge(None)
        self.bot.path=Path(self.temp.name)/'config.json'
        self.bot.path.write_text(json.dumps({'platform_id':'default_YOUR_QQ_APP_ID','gateway_key':'1'*64,'publishable_key':'fixture-anon'}))
    def tearDown(self):self.temp.cleanup()
    async def invoke(self,event):return [x async for x in self.bot.message(event)]
    async def test_group_cannot_send_identity_or_retrieve_binding_code(self):
        e=Event('字幕绑定',group='synthetic-group');r=await self.invoke(e)
        self.assertTrue(e.stopped);self.assertIn('私聊',r[0]);self.assertEqual(calls,[])
    async def test_free_chat_is_untouched(self):
        e=Event('你好');self.assertEqual(await self.invoke(e),[]);self.assertFalse(e.stopped)
    async def test_group_menu_matches_features_without_backend_or_llm(self):
        e=Event('/help',group='synthetic-group');r=await self.invoke(e)
        self.assertTrue(e.stopped);self.assertIn('功能菜单',r[0]);self.assertIn('私聊发送',r[0]);self.assertIn('我的任务',r[0]);self.assertEqual(calls,[])
    async def test_other_bot_and_missing_sender_never_call_gateway(self):
        await self.invoke(Event('我的任务',platform='other-bot'));await self.invoke(Event('我的任务',sender=''));self.assertEqual(calls,[])
    async def test_sender_is_from_event_not_command_and_command_stops_llm(self):
        e=Event('我的任务 pretend-owner');r=await self.invoke(e)
        self.assertTrue(e.stopped);self.assertIn('synthetic-member',r[0]);self.assertEqual(len(calls),1)
        _,args=calls[0];self.assertEqual(args['json']['p_sender'],logic.identity(e.platform,e.sender));self.assertFalse(args['allow_redirects'])
    async def test_unlink_requires_explicit_confirmation(self):
        await self.invoke(Event('字幕解绑'));self.assertEqual(calls,[])
    async def test_failure_never_leaks_secret_or_exception(self):
        self.bot.path.unlink();r=await self.invoke(Event('我的任务'));self.assertIn('未就绪',r[0]);self.assertNotIn('fixture-anon',r[0])
    def test_command_parsing_and_user_namespace(self):
        self.assertEqual(logic.parse('/任务详情 abc'),('detail','abc'));self.assertIsNone(logic.parse('请帮我查询任务'))
        self.assertNotEqual(logic.identity('a','same'),logic.identity('b','same'))
    def test_output_strips_controls_and_keeps_real_status(self):
        v={'tasks':[{'id':'fixture','title':'demo\nname','state':'submitted','project_title':'project','description':'safe'}]}
        result=logic.render('detail',v);self.assertIn('待审核',result);self.assertIn('demo name',result)
if __name__=='__main__':unittest.main()
