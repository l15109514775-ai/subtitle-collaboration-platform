import asyncio
import importlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock

ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'bot/plugins'))
def module(name,**values):
    m=types.ModuleType(name);m.__dict__.update(values);sys.modules[name]=m
class Star:
    def __init__(self,context):pass
module('aiohttp',ClientError=ConnectionError)
module('astrbot');module('astrbot.api',logger=types.SimpleNamespace(warning=lambda *args:None))
module('astrbot.api.event',filter=types.SimpleNamespace(event_message_type=lambda *a,**k:lambda f:f,EventMessageType=types.SimpleNamespace(ALL=1)),AstrMessageEvent=object)
module('astrbot.api.star',Context=object,Star=Star,register=lambda *a:lambda cls:cls)
m=importlib.import_module('astrbot_plugin_subtitle_notify.main')
logic=importlib.import_module('astrbot_plugin_subtitle_notify.outbox')
E={'id':'10000000-0000-4000-8000-000000000001','request_id':'20000000-0000-4000-8000-000000000001','created_at':'2026-10-22T12:00:00+00:00'}
FEED={'enabled':True,'events':[E]}
class Event:
    def __init__(self,text,group='',sender='OWNER',platform='fixture-platform'):
        self.text=text;self.group=group;self.sender=sender;self.platform=platform;self.stopped=False
    def get_message_str(self):return self.text
    def get_platform_name(self):return 'qq_official'
    def get_platform_id(self):return self.platform
    def get_sender_id(self):return self.sender
    def get_group_id(self):return self.group
    def is_private_chat(self):return not self.group
    def stop_event(self):self.stopped=True
    def plain_result(self,text):return text
class Tests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=ROOT/'tests');self.root=Path(self.temp.name)
        self.bot=m.SubtitleNotify(None);self.bot.base=self.root
        (self.root/'subtitle_bridge.json').write_text(json.dumps({'platform_id':'fixture-platform','gateway_key':'synthetic','publishable_key':'synthetic'}))
        self.bot.feed=AsyncMock(return_value=FEED);self.bot.send=AsyncMock(return_value='qq-confirmed')
    def tearDown(self):self.temp.cleanup()
    async def invoke(self,event):return [r async for r in self.bot.message(event)]
    async def enable(self):await self.invoke(Event('字幕通知设置 私聊'))
    async def test_no_target_no_network(self):
        await self.bot.tick();self.bot.feed.assert_not_called();self.bot.send.assert_not_called()
    async def test_one_submission_one_confirmed_send_after_restart(self):
        await self.enable();await self.bot.tick();await self.bot.tick()
        self.assertEqual(self.bot.send.await_count,1)
        box=logic.Outbox(self.root/'subtitle_notifications.sqlite3');self.assertEqual(box.status(),{'sent':1});box.close()
    async def test_unknown_response_pauses_without_retry(self):
        await self.enable();self.bot.send.side_effect=TimeoutError()
        with self.assertRaises(TimeoutError):await self.bot.tick()
        await self.bot.tick();self.assertEqual(self.bot.send.await_count,1)
        box=logic.Outbox(self.root/'subtitle_notifications.sqlite3');self.assertEqual(box.status(),{'uncertain':1});box.close()
    async def test_inflight_crash_blocks_second_process(self):
        box=logic.Outbox(self.root/'ledger');box.ingest(FEED);self.assertEqual(len(box.reserve()),1);box.close()
        box=logic.Outbox(self.root/'ledger');self.assertEqual(box.reserve(),[]);box.close()
    async def test_no_backend_owner_access_no_send(self):
        await self.enable();self.bot.feed.side_effect=ValueError('denied')
        with self.assertRaises(ValueError):await self.bot.tick()
        self.bot.send.assert_not_called()
    async def test_config_commands_in_group_do_not_query_or_go_to_llm(self):
        e=Event('字幕通知设置 私聊','GROUP');await self.invoke(e)
        self.assertTrue(e.stopped);self.bot.feed.assert_not_called()
    async def test_pair_code_single_use_exact_group_and_real_sender(self):
        reply=await self.invoke(Event('字幕通知设置 群聊'))
        code=reply[0].split('字幕通知绑定 ')[1]
        self.assertNotIn(code,self.bot.state_path.read_text())
        await self.invoke(Event('字幕通知绑定 '+code,'GROUP','GROUPMEMBER'))
        state=m.read_state(self.bot.state_path)
        self.assertEqual(state['target'],{'mode':'group','openid':'GROUP','mention':'GROUPMEMBER'})
        await self.invoke(Event('字幕通知绑定 '+code,'OTHER','ATTACKER'))
        self.assertEqual(m.read_state(self.bot.state_path)['target'],state['target'])
    async def test_unrecognized_chat_untouched(self):
        e=Event('hello');self.assertEqual(await self.invoke(e),[]);self.assertFalse(e.stopped)
    async def test_bare_pair_code_binds_without_model(self):
        reply=await self.invoke(Event('字幕通知设置 群聊'));code=reply[0].split('字幕通知绑定 ')[1]
        e=Event(code,'GROUP','GROUPMEMBER');await self.invoke(e)
        self.assertTrue(e.stopped);self.assertTrue(m.read_state(self.bot.state_path)['enabled'])
    async def test_invalid_bare_code_never_reaches_model(self):
        e=Event('f'*32,'GROUP','ATTACKER');reply=await self.invoke(e)
        self.assertTrue(e.stopped);self.assertIn('无效',reply[0]);self.bot.send.assert_not_called()
    async def test_shutdown_retains_history(self):
        await self.enable();await self.bot.tick();await self.invoke(Event('字幕通知关闭'));await self.bot.tick()
        self.assertEqual(self.bot.send.await_count,1);self.assertTrue((self.root/'subtitle_notifications.sqlite3').exists())
    async def test_missing_qq_receipt_not_marked_sent(self):
        box=logic.Outbox(self.root/'ledger');box.ingest(FEED);rows=box.reserve()
        with self.assertRaises(ValueError):box.finish(rows,None)
        self.assertEqual(box.status(),{'sending':1});box.close()
    async def test_feed_rejects_extra_private_fields_and_limits(self):
        for value in ({'enabled':True,'events':[{**E,'url':'private'}]},{'enabled':True,'events':[E]*51},{'enabled':False,'events':[]}):
            with self.assertRaises(ValueError):logic.validate_events(value)
    async def test_notification_contains_only_refs_and_no_model_or_file(self):
        text=logic.notification_text([(E['id'],E['request_id'])],'GROUPMEMBER')
        self.assertIn('<qqbot-at-user id="GROUPMEMBER" />',text);self.assertIn(E['request_id'],text)
        for forbidden in ('http','synthetic','gateway_key','publishable_key','--execute'):self.assertNotIn(forbidden,text)
        with self.assertRaises(ValueError):logic.notification_text([(E['id'],E['request_id'])],'<@all>')
    async def test_parallel_ticks_send_once(self):
        await self.enable();await asyncio.gather(self.bot.tick(),self.bot.tick());self.assertEqual(self.bot.send.await_count,1)
    async def test_missing_ledger_never_silently_resets(self):
        await self.enable();(self.root/'subtitle_notifications.sqlite3').unlink()
        with self.assertRaises(ValueError):await self.bot.tick()
        self.bot.send.assert_not_called()
        reply=await self.invoke(Event('字幕通知设置 私聊'))
        self.assertIn('暂不可用',reply[0]);self.assertFalse((self.root/'subtitle_notifications.sqlite3').exists())
    async def test_direct_api_confirmation_and_no_msg_id(self):
        api=types.SimpleNamespace(post_group_message=AsyncMock(return_value={'id':'confirmed'}))
        platform=types.SimpleNamespace(meta=lambda:types.SimpleNamespace(name='qq_official'),client=types.SimpleNamespace(api=api))
        bot=m.SubtitleNotify(types.SimpleNamespace(get_platform_inst=lambda pid:platform))
        self.assertEqual(await bot.send({'platform_id':'fixture'},{'mode':'group','openid':'GROUP'},'test'),'confirmed')
        self.assertNotIn('msg_id',api.post_group_message.call_args.kwargs)
        self.assertEqual(api.post_group_message.call_args.kwargs['msg_type'],2)
        self.assertEqual(api.post_group_message.call_args.kwargs['markdown'],{'content':'test'})
        self.assertNotIn('content',api.post_group_message.call_args.kwargs)
    async def test_explicit_test_resolution_preserves_failed_receipt_without_retry(self):
        box=logic.Outbox(self.root/'ledger');box.ingest(FEED);rows=box.reserve();box.uncertain(rows)
        box.resolve_rejected_test(E['id']);self.assertEqual(box.status(),{'resolved_without_retry':1});self.assertEqual(box.reserve(),[])
        self.assertEqual(box.db.execute('SELECT state,message_id FROM notices').fetchone(),('uncertain',None));box.close()
    async def dual(self):
        reply=await self.invoke(Event('字幕通知设置 群聊'));code=reply[0].split('字幕通知绑定 ')[1]
        await self.invoke(Event(code,'GROUP','GROUPMEMBER'))
        await self.invoke(Event('字幕通知设置 双通道'))
        newer={**E,'id':'10000000-0000-4000-8000-000000000002','created_at':'2026-10-22T12:01:00+00:00'}
        self.bot.feed.return_value={'enabled':True,'events':[newer]}
    async def test_dual_sends_once_per_destination(self):
        await self.dual();await self.bot.tick();await self.bot.tick()
        self.assertEqual(self.bot.send.await_count,2)
        self.assertEqual([x.args[1]['mode'] for x in self.bot.send.await_args_list],['group','private'])
    async def test_dual_group_failure_does_not_block_private(self):
        await self.dual();self.bot.send.side_effect=[TimeoutError(),'private-confirmed']
        with self.assertRaises(TimeoutError):await self.bot.tick()
        await self.bot.tick();self.assertEqual(self.bot.send.await_count,2)
        box=logic.Outbox(self.root/'subtitle_notifications_private.sqlite3');self.assertEqual(box.status(),{'sent':1});box.close()
    async def test_dual_does_not_replay_old_notices(self):
        await self.dual();self.bot.feed.return_value=FEED;await self.bot.tick()
        self.assertEqual(self.bot.send.await_count,1)
        self.assertEqual(self.bot.send.await_args.args[1]['mode'],'group')
    async def test_dual_requires_existing_same_owner_group(self):
        reply=await self.invoke(Event('字幕通知设置 双通道'))
        self.assertIn('先由同一组长',reply[0]);self.assertFalse(m.read_state(self.bot.state_path).get('dual',False))
    async def test_dual_private_failure_never_resends_group(self):
        await self.dual();self.bot.send.side_effect=['group-confirmed',TimeoutError()]
        with self.assertRaises(TimeoutError):await self.bot.tick()
        await self.bot.tick();self.assertEqual(self.bot.send.await_count,2)
        box=logic.Outbox(self.root/'subtitle_notifications.sqlite3');self.assertEqual(box.status(),{'sent':1});box.close()
    async def test_dual_reenable_preserves_private_history(self):
        await self.dual();await self.bot.tick()
        await self.invoke(Event('字幕通知设置 双通道'));await self.bot.tick()
        self.assertEqual(self.bot.send.await_count,2)
if __name__=='__main__':unittest.main()
