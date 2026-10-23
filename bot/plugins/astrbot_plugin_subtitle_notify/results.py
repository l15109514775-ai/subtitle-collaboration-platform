"""Fixed metadata-only result notices. Never include server text or file URLs."""
import uuid
from .outbox import validate_events

STATES={'succeeded','failed','waiting_reconciliation'}

def result_events(value):
    if not isinstance(value,dict) or value.get('enabled') is not True:raise ValueError('Result notifications disabled')
    events=value.get('events')
    if not isinstance(events,list) or len(events)>50:raise ValueError('Invalid result feed')
    converted=[]
    for e in events:
        if not isinstance(e,dict) or set(e)!={'id','job_id','state','created_at'} or e['state'] not in STATES:raise ValueError('Unexpected result metadata')
        converted.append({'id':e['id'],'request_id':e['job_id'],'created_at':e['created_at']})
    validate_events({'enabled':True,'events':converted})
    return {'enabled':True,'events':converted}

def result_text(job,state):
    job=str(uuid.UUID(job))
    lines={
      'succeeded':'云端字幕已回传。AI初稿仍需人工听校和审核，尚未计入人工积分。',
      'failed':'云端字幕流程已停止。请在网站核对任务状态，再决定下一步。',
      'waiting_reconciliation':'云端字幕需要核对请求或回传结果。核对前请勿重复执行，避免重复调用。',
    }
    if state not in lines:raise ValueError('Unsupported result state')
    return '字幕协作台 · 云端结果提醒\n'+lines[state]+'\n作业编号：'+job+'\n请登录网站 → 任务工作台 → 云端字幕交付，按作业编号核对。'
