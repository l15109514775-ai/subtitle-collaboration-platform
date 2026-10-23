import importlib
import json
import unittest
from unittest.mock import AsyncMock
import test_notify as fixture

m=importlib.import_module('astrbot_plugin_subtitle_notify.main')
logic=importlib.import_module('astrbot_plugin_subtitle_notify.outbox')
A={'id':fixture.E['id'],'job_id':fixture.E['request_id'],'created_at':fixture.E['created_at']}
FEED={'enabled':True,'events':[A]}

class ApprovalTests(fixture.Tests):
    def setUp(self):
        super().setUp()
        self.bot=m.SubtitleNotify(None);self.bot.base=self.root
        self.bot.feed=AsyncMock(return_value=fixture.FEED);self.bot.send=AsyncMock(return_value='confirmed')
    async def approvals(self):
        await self.dual()
        state=m.read_state(self.bot.state_path);state['approval_enabled']=True;m.save_state(self.bot.state_path,state)
        self.bot.feed=AsyncMock(return_value=FEED)
        self.bot.send.reset_mock()
    async def test_approval_private_only_once_across_ticks(self):
        await self.approvals();await self.bot.approval_tick();await self.bot.approval_tick()
        self.assertEqual(self.bot.send.await_count,1)
        call=self.bot.send.await_args
        self.assertEqual(call.args[1],{'mode':'private','openid':'OWNER'})
        self.assertIn('--job-id '+A['job_id'],call.args[2]);self.assertNotIn('<qqbot-at-user',call.args[2])
    async def test_approval_unknown_send_does_not_retry(self):
        await self.approvals();self.bot.send.side_effect=TimeoutError()
        with self.assertRaises(TimeoutError):await self.bot.approval_tick()
        await self.bot.approval_tick();self.assertEqual(self.bot.send.await_count,1)
    async def test_approval_cancelled_before_send_is_skipped(self):
        await self.approvals()
        self.bot.feed.side_effect=[FEED,FEED,{'enabled':True,'events':[]}]
        await self.bot.approval_tick();self.bot.send.assert_not_called()
        box=logic.Outbox(self.root/'subtitle_approval_notifications.sqlite3')
        self.assertEqual(box.status(),{'resolved_without_retry':1});box.close()
    async def test_approval_changed_job_identity_fails_closed(self):
        await self.approvals()
        self.bot.feed.side_effect=[FEED,FEED,{'enabled':True,'events':[{**A,'job_id':'30000000-0000-4000-8000-000000000001'}]}]
        await self.bot.approval_tick();self.bot.send.assert_not_called()
    async def test_approval_missing_ledger_cannot_reset(self):
        await self.approvals();await self.bot.approval_tick()
        (self.root/'subtitle_approval_notifications.sqlite3').unlink()
        with self.assertRaises(ValueError):await self.bot.approval_tick()
        self.assertEqual(self.bot.send.await_count,1)
    async def test_approval_without_scope_or_private_binding_no_fetch(self):
        await self.dual();self.bot.feed.reset_mock();await self.bot.approval_tick();self.bot.feed.assert_not_called()
    async def test_approval_extra_fields_rejected(self):
        with self.assertRaises(ValueError):logic.approval_events({'enabled':True,'events':[{**A,'source_url':'private'}]})
    async def test_approval_instruction_matches_existing_website(self):
        source=fixture.ROOT/'site/cloud-launch.prod-20261022-1.js'
        # Compare the fixed template verbatim without running website code.
        template=source.read_text(encoding='utf-8').split('return `',1)[1].split('`;',1)[0]
        self.assertEqual(logic.execution_instruction(A['job_id']),template.replace('${job}',A['job_id']))

if __name__=='__main__':unittest.main()
