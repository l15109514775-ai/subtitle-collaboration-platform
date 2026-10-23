"""Durable receipt ledger. A crash/unknown QQ result never auto-resends."""
import json
import os
import sqlite3
import uuid
from datetime import datetime


def validate_events(value):
    if not isinstance(value,dict) or value.get('enabled') is not True:
        raise ValueError('Notifications unavailable')
    events=value.get('events')
    if not isinstance(events,list) or len(events)>50:
        raise ValueError('Invalid events')
    previous=None
    for event in events:
        if set(event)!={'id','request_id','created_at'}:
            raise ValueError('Unexpected fields')
        for name in ('id','request_id'):
            if str(uuid.UUID(event[name]))!=event[name]:raise ValueError('Invalid UUID')
        stamp=datetime.fromisoformat(event['created_at'].replace('Z','+00:00'))
        if stamp.tzinfo is None:raise ValueError('Timezone required')
        current=(stamp,event['id'])
        if previous and current<=previous:raise ValueError('Unsorted events')
        previous=current
    return events


class Outbox:
    def __init__(self,path):
        path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        self.db=sqlite3.connect(path,timeout=5)
        os.chmod(path,0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS cursor (id INTEGER PRIMARY KEY CHECK(id=1), stamp TEXT, event_id TEXT);
        CREATE TABLE IF NOT EXISTS notices (id TEXT PRIMARY KEY, request_id TEXT NOT NULL, stamp TEXT NOT NULL,
          state TEXT NOT NULL CHECK(state IN ('queued','sending','sent','uncertain')), message_id TEXT);
        CREATE TABLE IF NOT EXISTS resolutions (id TEXT PRIMARY KEY REFERENCES notices(id), reason TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        ''')
    def cursor(self):
        row=self.db.execute('SELECT stamp,event_id FROM cursor WHERE id=1').fetchone()
        return row if row else (None,None)
    def ingest(self,value):
        events=validate_events(value)
        stamp,event_id=self.cursor()
        if stamp:
            boundary=(datetime.fromisoformat(stamp.replace('Z','+00:00')),event_id)
            events=[e for e in events if (datetime.fromisoformat(e['created_at'].replace('Z','+00:00')),e['id'])>boundary]
        with self.db:
            for e in events:self.db.execute('INSERT OR IGNORE INTO notices VALUES(?,?,?,\'queued\',NULL)',(e['id'],e['request_id'],e['created_at']))
            if events:
                e=events[-1]
                self.db.execute('INSERT OR REPLACE INTO cursor VALUES(1,?,?)',(e['created_at'],e['id']))
    def reserve(self,limit=10):
        if not isinstance(limit,int) or not 1<=limit<=10:raise ValueError('Invalid batch size')
        # BEGIN IMMEDIATE protects duplicate plugin instances; no locks held during HTTP.
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            if self.db.execute("SELECT 1 FROM notices WHERE state IN ('sending','uncertain') AND NOT EXISTS(SELECT 1 FROM resolutions r WHERE r.id=notices.id) LIMIT 1").fetchone():return []
            rows=self.db.execute("SELECT id,request_id FROM notices WHERE state='queued' ORDER BY stamp,id LIMIT ?",(limit,)).fetchall()
            self.db.executemany("UPDATE notices SET state='sending' WHERE id=?",[(r[0],) for r in rows])
        return rows
    def finish(self,rows,message_id):
        if not isinstance(message_id,str) or not message_id or len(message_id)>200:
            raise ValueError('QQ did not confirm a message ID')
        with self.db:self.db.executemany("UPDATE notices SET state='sent',message_id=? WHERE id=? AND state='sending'",[(message_id,r[0]) for r in rows])
    def uncertain(self,rows):
        with self.db:self.db.executemany("UPDATE notices SET state='uncertain' WHERE id=? AND state='sending'",[(r[0],) for r in rows])
    def status(self):
        return dict(self.db.execute("SELECT CASE WHEN r.id IS NOT NULL THEN 'resolved_without_retry' ELSE n.state END AS s,count(*) FROM notices n LEFT JOIN resolutions r ON r.id=n.id GROUP BY s").fetchall())
    def resolve_rejected_test(self,event_id):
        # Operator-only reconciliation after a withdrawn synthetic test and an
        # explicit QQ permission rejection. Never mark a failed message as sent.
        with self.db:
            if not self.db.execute("SELECT 1 FROM notices WHERE id=? AND state='uncertain'",(event_id,)).fetchone():raise ValueError('Uncertain notification required')
            self.db.execute("INSERT INTO resolutions(id,reason) VALUES(?,'withdrawn_test_owner_confirmed_no_delivery_qq_permission_denied')",(event_id,))
    def skip_ineligible(self,rows,reason='approval_no_longer_executable_no_send'):
        if reason not in ('approval_no_longer_executable_no_send','result_no_longer_current_no_send'):raise ValueError('Invalid resolution')
        with self.db:
            for row in rows:
                self.db.execute("UPDATE notices SET state='uncertain' WHERE id=? AND state='sending'",(row[0],))
                self.db.execute("INSERT OR IGNORE INTO resolutions(id,reason) VALUES(?,?)",(row[0],reason))
    def close(self):self.db.close()


def approval_events(value):
    if not isinstance(value,dict) or value.get('enabled') is not True:raise ValueError('Approval notifications disabled')
    events=value.get('events')
    if not isinstance(events,list) or len(events)>50:raise ValueError('Invalid approval events')
    converted=[]
    for event in events:
        if not isinstance(event,dict) or set(event)!={'id','job_id','created_at'}:raise ValueError('Unexpected approval fields')
        converted.append({'id':event['id'],'request_id':event['job_id'],'created_at':event['created_at']})
    # Dedicated approval ledger: its legacy request_id column stores the job UUID.
    validate_events({'enabled':True,'events':converted})
    return {'enabled':True,'events':converted}


def execution_instruction(job):
    job=str(uuid.UUID(job))
    return '请在已发布的字幕交付 Cloud 环境中仅处理网站作业 '+job+'。先按 PRODUCTION_FLOW.md 核对固定环境，再运行 .venv/bin/python platform_worker.py --job-id '+job+' --work-root /workspace/subtitle-platform-production --execute。单视频上限20分钟、文字400次、千问40次，并服从服务端更低限额。遇到未知请求结果立即停止核对，不重复发送，不修改代码、权限、有效期或账本。按正常流程自动回传九个私有字幕/报告文件后停止；保持人工听校和审核，不发放人工积分。'


def approval_text(rows):
    if not rows or len(rows)>1:raise ValueError('One instruction per private message')
    return '字幕申请已批准，等待你检查后手动启动。请先确认 Codex Cloud 环境为 subtitle-delivery-20min-active，且网站作业仍在排队。已启动、已取消或素材授权过期时不要执行；请回网站核对。\n\n以下整段可复制到新任务：\n\n'+execution_instruction(rows[0][1])


def notification_text(rows,mention=None):
    if not rows or len(rows)>10:raise ValueError('Invalid batch')
    # Mention only a group openid captured from the real binding event, never a website field.
    prefix=''
    if mention:
        if not isinstance(mention,str) or not mention.isalnum() or len(mention)>128:raise ValueError('Invalid mention')
        prefix='<qqbot-at-user id="'+mention+'" /> '
    refs='、'.join(str(uuid.UUID(r[1])) for r in rows)
    return prefix+'字幕协作台有 '+str(len(rows))+' 份新字幕申请待组长审批。\n申请编号：'+refs+'\n请登录网站 → 字幕申请与审批。尚未启动模型，也未自动批准。'
