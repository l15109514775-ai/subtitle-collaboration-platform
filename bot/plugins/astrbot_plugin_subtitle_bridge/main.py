import asyncio
import json
from pathlib import Path
import aiohttp
from astrbot.api.event import filter, AstrMessageEvent
from astrbot.api.star import Context, Star, register
from .bridge import GATEWAY, HELP, MENU, parse, identity, render

@register('subtitle_bridge', 'Subtitle Workspace', '字幕组账号绑定与受限任务查询', '1.0.0')
class SubtitleBridge(Star):
    def __init__(self, context: Context):
        super().__init__(context)
        self.path=Path('/AstrBot/data/subtitle_bridge.json')
        self.busy=set()

    @filter.event_message_type(filter.EventMessageType.ALL, priority=100)
    async def message(self, event: AstrMessageEvent):
        parsed=parse(event.get_message_str())
        if parsed is None or event.get_platform_name()!='qq_official':
            return
        # Stop before reply: binding codes and backend failures never reach LLM.
        event.stop_event()
        action,arg=parsed
        if action=='menu':
            yield event.plain_result(MENU)
            return
        if event.get_group_id() or not event.is_private_chat():
            yield event.plain_result('字幕组账号绑定和个人任务查询请私聊本机器人，发送「字幕帮助」。')
            return
        if action=='help':
            yield event.plain_result(HELP)
            return
        if action=='unlink' and arg!='确认':
            yield event.plain_result('解除后此 QQ 将无法查询网站任务。如确定，请发送「字幕解绑 确认」。')
            return
        try:
            conf=json.loads(self.path.read_text(encoding='utf-8'))
            if event.get_platform_id()!=conf['platform_id']:
                return
            if not event.get_sender_id():
                yield event.plain_result('无法确认 QQ 身份，请重新打开机器人私聊。')
                return
            sender=identity(conf['platform_id'],event.get_sender_id())
            if sender in self.busy:
                yield event.plain_result('上一次查询还在处理中，请稍候。')
                return
            self.busy.add(sender)
            try:
                async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=20)) as client:
                    async with client.post(GATEWAY+'/v1/rdb/rest/rpc/st_qq_dispatch',
                        headers={'Authorization':'Bearer '+conf['publishable_key']},
                        json={'p_key':conf['gateway_key'],'p_sender':sender,'p_action':action,'p_arg':arg},
                        allow_redirects=False) as response:
                        if response.status!=200:
                            yield event.plain_result('网站连接暂不可用，请稍后重试或登录网站查看。')
                            return
                        value=await response.json()
                text=render(action,value)
                if len(text)>1800:
                    text=text[:1650]+'\n其余任务请登录字幕组网站查看。'
                yield event.plain_result(text)
            finally:
                self.busy.discard(sender)
        except (OSError,ValueError,KeyError,aiohttp.ClientError,asyncio.TimeoutError):
            # Never log request payloads, keys, binding codes, sender IDs or rows.
            yield event.plain_result('网站查询尚未就绪或连接暂时中断，请稍后重试。')

