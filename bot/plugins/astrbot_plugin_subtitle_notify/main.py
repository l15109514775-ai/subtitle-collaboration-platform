"""One fixed, owner-bound notification destination. No LLM or business writes."""
import asyncio
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import time
import aiohttp
from astrbot.api import logger
from astrbot.api.event import filter, AstrMessageEvent
from astrbot.api.star import Context, Star, register
from .outbox import Outbox, notification_text, approval_events, approval_text
from .schedule import claim_slot, LABEL
from .cleanup_worker import cleanup_pass
from .results import result_events, result_text

BASE=Path('/AstrBot/data')
GATEWAY='https://example-env.api.tcloudbasegateway.com/v1/rdb/rest/rpc/st_qq_notification_feed'
COMMANDS={'字幕通知设置','字幕通知绑定','字幕通知状态','字幕通知关闭'}

def sender_hash(platform,sender):
    return hashlib.sha256(('qq-c2c\0'+platform+'\0'+sender).encode()).hexdigest()

def read_state(path):
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}

def save_state(path,state):
    temp=path.with_suffix('.tmp')
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(state,f);f.flush();os.fsync(f.fileno())
    os.replace(temp,path)

@register('subtitle_notify','Subtitle Workspace','组长绑定的新字幕申请提醒（固定接口，无模型）','1.4.0')
class SubtitleNotify(Star):
    def __init__(self,context:Context):
        super().__init__(context)
        self.context=context;self.base=BASE;self.task=None;self.lock=asyncio.Lock()
    async def initialize(self):
        try:
            conf=self.config();platform=self.context.get_platform_inst(conf['platform_id'])
            client=getattr(platform,'client',None);api=getattr(client,'api',None)
            save_state(self.base/'subtitle_notify_diagnostic.json',{'platform_found':platform is not None,
                'client_present':client is not None,'api_present':api is not None,
                'group_send_available':callable(getattr(api,'post_group_message',None)),
                'client_type':type(client).__name__,'platform_type':type(platform).__name__})
        except Exception as exc:
            save_state(self.base/'subtitle_notify_diagnostic.json',{'initialization_error_type':type(exc).__name__})
        self.task=asyncio.create_task(self.run())
    async def terminate(self):
        if self.task:
            self.task.cancel()
            try:await self.task
            except asyncio.CancelledError:pass
    def config(self):
        return json.loads((self.base/'subtitle_bridge.json').read_text(encoding='utf-8'))
    @property
    def state_path(self):return self.base/'subtitle_notifications.json'
    def ensure_ledger(self,state):
        path=self.base/'subtitle_notifications.sqlite3'
        if state.get('ledger_initialized') and not path.is_file():
            raise ValueError('Receipt ledger missing; manual recovery required')
        box=Outbox(path);box.close();state['ledger_initialized']=True
    async def feed(self,conf,sender,after=None,after_id=None,approval=False,ids=None,result=False):
        url=GATEWAY if not approval else GATEWAY.replace('st_qq_notification_feed','st_qq_approval_feed')
        if result:
            if approval:raise ValueError('Conflicting feed')
            url=GATEWAY.replace('st_qq_notification_feed','st_qq_result_feed')
        body={'p_key':conf['gateway_key'],'p_sender':sender,'p_after':after,'p_after_id':after_id}
        if approval or result:body['p_ids']=ids
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=20)) as client:
            async with client.post(url,headers={'Authorization':'Bearer '+conf['publishable_key']},
                json=body,allow_redirects=False) as response:
                if response.status!=200:raise ValueError('Notification access unavailable')
                raw=await response.content.read(65537)
                if len(raw)>65536:raise ValueError('Oversized feed')
                value=json.loads(raw)
                if not isinstance(value,dict) or value.get('enabled') is not True:raise ValueError('Notification disabled')
                return value
    async def send(self,conf,target,text):
        platform=self.context.get_platform_inst(conf['platform_id'])
        if platform is None or platform.meta().name!='qq_official':raise ValueError('Wrong adapter')
        # Await the official API receipt directly: Context.send_message may return
        # successfully even if an adapter skips delivery. No stale msg_id fallback.
        args={'content':text,'msg_type':0}
        if target['mode']=='group':
            # Native qqbot-at-user markup is parsed by QQ's Markdown renderer,
            # not by its plain-text message mode. No passive msg_id fallback.
            value=await platform.client.api.post_group_message(group_openid=target['openid'],msg_type=2,markdown={'content':text})
        elif target['mode']=='private':
            value=await platform.client.api.post_c2c_message(openid=target['openid'],**args)
        else:raise ValueError('Unsupported destination')
        mid=value.get('id') if isinstance(value,dict) else getattr(value,'id',None)
        if not mid:raise ValueError('Unconfirmed QQ response')
        return str(mid)
    async def tick(self):
        async with self.lock:
            state=read_state(self.state_path)
            if not state.get('enabled') or not state.get('target'):return
            if not (self.base/'subtitle_notifications.sqlite3').is_file():
                raise ValueError('Receipt ledger missing; refusing automatic reset')
            conf=self.config()
            if state.get('platform_id')!=conf['platform_id']:return
            channels=[(state['target'],'subtitle_notifications.sqlite3')]
            if state.get('dual'):
                if not state.get('private_target'):raise ValueError('Private destination missing')
                channels.append((state['private_target'],'subtitle_notifications_private.sqlite3'))
            errors=[]
            delivered=False
            for target,filename in channels:
                if not (self.base/filename).is_file():raise ValueError('Receipt ledger missing')
                box=Outbox(self.base/filename)
                try:
                    after,aid=box.cursor()
                    value=await self.feed(conf,state['owner_sender'],after,aid)
                    box.ingest(value)
                    rows=box.reserve()
                    if not rows:continue
                    try:
                        mid=await self.send(conf,target,notification_text(rows,target.get('mention')))
                        box.finish(rows,mid)
                        delivered=True
                    except BaseException:
                        box.uncertain(rows)
                        raise
                except Exception as exc:errors.append(exc)
                finally:box.close()
            if errors:raise errors[0]
            return delivered
    async def approval_tick(self):
        async with self.lock:
            state=read_state(self.state_path)
            if not (state.get('enabled') and state.get('dual') and state.get('approval_enabled')):return
            target=state.get('private_target',{})
            if target.get('mode')!='private':raise ValueError('Private owner destination required')
            conf=self.config()
            if state.get('platform_id')!=conf['platform_id']:raise ValueError('Wrong platform')
            path=self.base/'subtitle_approval_notifications.sqlite3'
            if state.get('approval_ledger_initialized') and not path.is_file():raise ValueError('Approval ledger missing')
            # Live owner authorization is checked before creating or touching any ledger.
            value=await self.feed(conf,state['owner_sender'],approval=True)
            approval_events(value)
            box=Outbox(path)
            try:
                state['approval_ledger_initialized']=True;save_state(self.state_path,state)
                after,aid=box.cursor()
                value=await self.feed(conf,state['owner_sender'],after,aid,approval=True)
                box.ingest(approval_events(value))
                rows=box.reserve(1)
                if not rows:return
                try:
                    # Revalidate persisted queued work immediately before transmission.
                    live=approval_events(await self.feed(conf,state['owner_sender'],approval=True,ids=[r[0] for r in rows]))
                    eligible={(e['id'],e['request_id']) for e in live['events']}
                    if any(tuple(r) not in eligible for r in rows):
                        box.skip_ineligible(rows);return
                    mid=await self.send(conf,target,approval_text(rows))
                    box.finish(rows,mid)
                    return True
                except BaseException:
                    box.uncertain(rows);raise
            finally:box.close()
    async def result_tick(self):
        async with self.lock:
            state=read_state(self.state_path)
            if not (state.get('enabled') and state.get('result_enabled')):return
            target=state.get('private_target',{})
            if target.get('mode')!='private':raise ValueError('Private owner destination required')
            conf=self.config()
            if state.get('platform_id')!=conf['platform_id']:raise ValueError('Wrong platform')
            if sender_hash(conf['platform_id'],target.get('openid',''))!=state.get('owner_sender'):
                raise ValueError('Private recipient does not match authorized owner')
            path=self.base/'subtitle_result_notifications.sqlite3'
            if state.get('result_ledger_initialized') and not path.is_file():raise ValueError('Result ledger missing')
            result_events(await self.feed(conf,state['owner_sender'],result=True))
            box=Outbox(path)
            try:
                state['result_ledger_initialized']=True;save_state(self.state_path,state)
                after,aid=box.cursor()
                box.ingest(result_events(await self.feed(conf,state['owner_sender'],after,aid,result=True)))
                rows=box.reserve(1)
                if not rows:return
                try:
                    live=await self.feed(conf,state['owner_sender'],result=True,ids=[r[0] for r in rows])
                    result_events(live)
                    current={(e['id'],e['job_id']):e['state'] for e in live['events']}
                    if any(tuple(r) not in current for r in rows):
                        box.skip_ineligible(rows,'result_no_longer_current_no_send');return True
                    row=rows[0]
                    mid=await self.send(conf,target,result_text(row[1],current[tuple(row)]))
                    box.finish(rows,mid);return True
                except BaseException:
                    box.uncertain(rows);raise
            finally:box.close()
    async def run(self):
        while True:
            if not claim_slot(self.base/'subtitle_notification_schedule.sqlite3'):
                await asyncio.sleep(15);continue
            deadline=asyncio.get_running_loop().time()+240
            try:
                for _ in range(50):
                    if not await self.tick():break
                    if asyncio.get_running_loop().time()>=deadline:break
                    await asyncio.sleep(1)
            except asyncio.CancelledError:raise
            except Exception as exc:
                result={'error_type':type(exc).__name__}
                if type(exc).__name__=='ServerError':
                    safe=re.sub(r'https?://\S+','[url]',str(exc))
                    result['api_error_message']=re.sub(r'[0-9a-fA-F]{24,}','[redacted]',safe)[:200]
                    if str(exc)=='主动消息失败，无权限':
                        async with self.lock:
                            state=read_state(self.state_path)
                            state['blocked_reason']='qq_active_send_permission_denied'
                            save_state(self.state_path,state)
                save_state(self.base/'subtitle_notify_last_error.json',result)
                logger.warning('Subtitle notification check unavailable; inspect fixed-command status. No automatic resend of uncertain deliveries.')
            try:
                for _ in range(50):
                    if asyncio.get_running_loop().time()>=deadline:break
                    if not await self.approval_tick():break
                    await asyncio.sleep(1)
            except asyncio.CancelledError:raise
            except Exception as exc:
                save_state(self.base/'subtitle_approval_last_error.json',{'error_type':type(exc).__name__})
                logger.warning('Subtitle approval instruction notification unavailable; no automatic resend of uncertain deliveries.')
            try:
                for _ in range(50):
                    if asyncio.get_running_loop().time()>=deadline:break
                    if not await self.result_tick():break
                    await asyncio.sleep(1)
            except asyncio.CancelledError:raise
            except Exception as exc:
                save_state(self.base/'subtitle_result_last_error.json',{'error_type':type(exc).__name__})
                logger.warning('Subtitle result notification unavailable; no automatic resend of uncertain deliveries.')
            try:
                state=read_state(self.state_path)
                if state.get('cleanup_enabled') and state.get('owner_sender'):
                    await cleanup_pass(self.config(),state['owner_sender'],deadline)
            except asyncio.CancelledError:raise
            except Exception as exc:
                save_state(self.base/'subtitle_cleanup_last_error.json',{'error_type':type(exc).__name__})
                logger.warning('Subtitle retention cleanup incomplete; reconcile exact objects next scheduled check.')
            await asyncio.sleep(15)
    @filter.event_message_type(filter.EventMessageType.ALL,priority=110)
    async def message(self,event:AstrMessageEvent):
        parts=event.get_message_str().strip().removeprefix('/').split(maxsplit=1)
        # People often copy just the code. Intercept it before the model, even
        # when invalid/expired, and use the exact same one-time binding checks.
        if len(parts)==1 and re.fullmatch(r'[0-9a-fA-F]{32}',parts[0]):
            parts=['字幕通知绑定',parts[0].lower()]
        if not parts or parts[0] not in COMMANDS or event.get_platform_name()!='qq_official':return
        event.stop_event()
        command=parts[0];arg=parts[1] if len(parts)>1 else ''
        try:
            async with self.lock:
                conf=self.config()
                if event.get_platform_id()!=conf['platform_id'] or not event.get_sender_id():return
                state=read_state(self.state_path)
                if command=='字幕通知绑定':
                    if not event.get_group_id() or event.is_private_chat():
                        yield event.plain_result('请在目标群 @本机器人发送绑定指令。');return
                    pending=state.get('pair',{})
                    if not secrets.compare_digest(hashlib.sha256(arg.encode()).hexdigest(),pending.get('hash','')) or pending.get('until',0)<time.time():
                        yield event.plain_result('绑定码无效或已过期，请组长在私聊重新设置。');return
                    await self.feed(conf,state['owner_sender'])
                    state['target']={'mode':'group','openid':event.get_group_id(),'mention':event.get_sender_id()}
                    # Validate mention syntax before enabling; no message is sent yet.
                    notification_text([('00000000-0000-4000-8000-000000000000','00000000-0000-4000-8000-000000000000')],state['target']['mention'])
                    state.pop('pair',None);state.pop('blocked_reason',None);state['enabled']=True;save_state(self.state_path,state)
                    yield event.plain_result('已将当前群设为字幕申请提醒群，并在提醒中提及本次绑定人。仅通知新提交的申请；审批和启动仍需组长人工操作。');return
                if event.get_group_id() or not event.is_private_chat():
                    yield event.plain_result('通知设置和状态请由组长私聊本机器人操作。');return
                sender=sender_hash(conf['platform_id'],event.get_sender_id())
                await self.feed(conf,sender) # Live owner role + binding + enabled scope, every command.
                if command=='字幕通知关闭':
                    state['enabled']=False;state.pop('pair',None);save_state(self.state_path,state)
                    yield event.plain_result('已停止自动提醒，历史发送记录保留。');return
                if command=='字幕通知状态':
                    if state.get('ledger_initialized') and not (self.base/'subtitle_notifications.sqlite3').is_file():
                        yield event.plain_result('通知回执账本缺失，已暂停自动发送；请管理员恢复原账本，不能清零重发。');return
                    box=Outbox(self.base/'subtitle_notifications.sqlite3')
                    try:counts=box.status()
                    finally:box.close()
                    summary='字幕提醒：'+('已启用' if state.get('enabled') else '未启用')+'；目标：'+('群聊+私聊' if state.get('dual') else state.get('target',{}).get('mode','未绑定'))+'；主通道已确认 '+str(counts.get('sent',0))+'；待发 '+str(counts.get('queued',0))+'；结果待核对 '+str(counts.get('sending',0)+counts.get('uncertain',0))
                    if state.get('dual'):
                        path=self.base/'subtitle_notifications_private.sqlite3'
                        if not path.is_file():summary+='；私聊账本缺失，暂停'
                        else:
                            box=Outbox(path)
                            try:private=box.status()
                            finally:box.close()
                            summary+='；私聊已确认 '+str(private.get('sent',0))+'；待发 '+str(private.get('queued',0))+'；结果待核对 '+str(private.get('sending',0)+private.get('uncertain',0))
                    if state.get('approval_enabled'):
                        path=self.base/'subtitle_approval_notifications.sqlite3'
                        if path.is_file():
                            box=Outbox(path)
                            try:approvals=box.status()
                            finally:box.close()
                            summary+='；审批指令私聊已确认 '+str(approvals.get('sent',0))+'；待发 '+str(approvals.get('queued',0))+'；待核对 '+str(approvals.get('sending',0)+approvals.get('uncertain',0))
                        else:summary+='；审批指令私聊等待首次检查'
                    if state.get('result_enabled'):
                        path=self.base/'subtitle_result_notifications.sqlite3'
                        if path.is_file():
                            box=Outbox(path)
                            try:results=box.status()
                            finally:box.close()
                            summary+='；云端结果私聊已确认 '+str(results.get('sent',0))+'；待发 '+str(results.get('queued',0))+'；待核对 '+str(results.get('sending',0)+results.get('uncertain',0))
                        else:summary+='；云端结果私聊等待首次检查'
                    yield event.plain_result(summary+'；自动检查：'+LABEL+'。结果待核对时仅暂停对应通道，避免重复。');return
                if arg not in ('群聊','私聊','双通道'):
                    yield event.plain_result('请发送「字幕通知设置 群聊」「字幕通知设置 私聊」或「字幕通知设置 双通道」。');return
                if arg=='双通道':
                    if state.get('target',{}).get('mode')!='group' or state.get('owner_sender')!=sender:
                        yield event.plain_result('请先由同一组长完成群聊绑定，再设置双通道。');return
                    self.ensure_ledger(state)
                    private_path=self.base/'subtitle_notifications_private.sqlite3'
                    if state.get('private_ledger_initialized') and not private_path.is_file():raise ValueError('Private ledger missing')
                    if not private_path.is_file():
                        # Start at the server feed's current end, never replay old group notices.
                        box=Outbox(self.base/'subtitle_notifications.sqlite3')
                        try:after,aid=box.cursor()
                        finally:box.close()
                        while True:
                            events=(await self.feed(conf,sender,after,aid))
                            from .outbox import validate_events
                            events=validate_events(events)
                            if events:after,aid=events[-1]['created_at'],events[-1]['id']
                            if len(events)<50:break
                        box=Outbox(private_path)
                        try:
                            with box.db:box.db.execute('INSERT OR REPLACE INTO cursor VALUES(1,?,?)',(after,aid))
                        finally:box.close()
                    state.update(dual=True,enabled=True,private_ledger_initialized=True,
                        private_target={'mode':'private','openid':event.get_sender_id()})
                    state.pop('blocked_reason',None);save_state(self.state_path,state)
                    yield event.plain_result('已开启群聊+私聊双通道：'+LABEL+'检查新申请，群内@绑定人，同时私聊你。两路分别记录回执；不会重发历史申请或自动审批。');return
                state.update(platform_id=conf['platform_id'],owner_sender=sender)
                state['dual']=False
                if arg=='私聊':
                    self.ensure_ledger(state)
                    state.update(enabled=True,target={'mode':'private','openid':event.get_sender_id()});state.pop('pair',None);state.pop('blocked_reason',None)
                    save_state(self.state_path,state)
                    yield event.plain_result('新申请将私聊提醒你；'+LABEL+'检查。不会自动审批或启动模型。');return
                code=secrets.token_hex(16)
                self.ensure_ledger(state)
                state['pair']={'hash':hashlib.sha256(code.encode()).hexdigest(),'until':time.time()+600}
                save_state(self.state_path,state)
                yield event.plain_result('十分钟内，在目标群 @本机器人发送以下一次性绑定指令，请勿转发到其他群：\n字幕通知绑定 '+code)
        except (OSError,ValueError,KeyError,aiohttp.ClientError,asyncio.TimeoutError):
            yield event.plain_result('通知配置暂不可用：需网站启用受限通知权限，且当前QQ仍绑定有效组长身份。未更改任务或审批。')
