import asyncio
from datetime import datetime,timezone
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch,AsyncMock
import test_notify as fixture
from astrbot_plugin_subtitle_notify import schedule

class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=fixture.ROOT/'tests');self.path=Path(self.temp.name)/'slots.sqlite3'
    def tearDown(self):self.temp.cleanup()
    def time(self,h,m=0,s=0,day=22):return datetime(2026,10,day,h,m,s,tzinfo=schedule.BEIJING)
    def test_four_daily_slots(self):
        for hour in (0,7,12,16):self.assertTrue(schedule.claim_slot(self.path,self.time(hour)))
    def test_no_other_hours_or_minutes(self):
        for h in range(24):
            if h not in (0,7,12,16):self.assertFalse(schedule.claim_slot(self.path,self.time(h)))
        for h in (0,7,12,16):self.assertFalse(schedule.claim_slot(self.path,self.time(h,1)))
        self.assertFalse(self.path.exists())
    def test_restart_does_not_reclaim_slot(self):
        self.assertTrue(schedule.claim_slot(self.path,self.time(7)))
        self.assertFalse(schedule.claim_slot(self.path,self.time(7,0,45)))
    def test_midnight_next_day_is_new_slot(self):
        self.assertTrue(schedule.claim_slot(self.path,self.time(0)))
        self.assertTrue(schedule.claim_slot(self.path,self.time(0,day=23)))
    def test_server_utc_converts_to_beijing(self):
        self.assertTrue(schedule.claim_slot(self.path,datetime(2026,10,21,23,tzinfo=timezone.utc)))
        self.assertFalse(schedule.claim_slot(self.path,self.time(7)))
    def test_naive_time_rejected(self):
        with self.assertRaises(ValueError):schedule.claim_slot(self.path,datetime(2026,10,22,7))

class RunnerTests(unittest.IsolatedAsyncioTestCase):
    async def test_outside_slot_never_queries_cloud(self):
        bot=fixture.m.SubtitleNotify(None);bot.base=fixture.ROOT/'tests'
        bot.tick=AsyncMock();bot.approval_tick=AsyncMock()
        with patch.object(fixture.m,'claim_slot',return_value=False),patch.object(fixture.m.asyncio,'sleep',side_effect=asyncio.CancelledError()):
            with self.assertRaises(asyncio.CancelledError):await bot.run()
        bot.tick.assert_not_called();bot.approval_tick.assert_not_called()
    async def test_slot_drains_multiple_pending_instructions(self):
        bot=fixture.m.SubtitleNotify(None);bot.base=fixture.ROOT/'tests'
        bot.tick=AsyncMock(return_value=False);bot.approval_tick=AsyncMock(side_effect=[True,True,False])
        async def sleep(seconds):
            if seconds==15:raise asyncio.CancelledError()
        with patch.object(fixture.m,'claim_slot',return_value=True),patch.object(fixture.m.asyncio,'sleep',side_effect=sleep):
            with self.assertRaises(asyncio.CancelledError):await bot.run()
        self.assertEqual(bot.approval_tick.await_count,3)

if __name__=='__main__':unittest.main()
