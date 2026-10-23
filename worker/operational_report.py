"""Bounded operational evidence. Never expose provider bodies or local paths."""
import json
from pathlib import Path


def safe_json(path, limit=500_000):
    try:
        path=Path(path)
        if path.is_symlink() or not path.is_file() or path.stat().st_size>limit:
            return None
        value=json.loads(path.read_text(encoding='utf-8-sig'))
        return value if isinstance(value,dict) else None
    except (OSError,ValueError,UnicodeError):
        return None


def counter(value):
    return value if type(value) is int and 0<=value<=10**12 else None


def usage_summary(paths):
    result={name:{'reported_requests':0,'input_tokens':0,'output_tokens':0,'total_tokens':0}
            for name in ('text','qwen')}
    states={'completed':0,'not_sent':0,'rejected':0,'unknown':0}
    completed={'translate':0,'review':0,'qwen':0}
    for provider,path in paths:
        data=safe_json(path)
        state=data.get('state') if data else None
        category='completed' if state=='completed' else 'not_sent' if state=='not_sent' else 'rejected' if state=='api_rejected' else 'unknown'
        states[category]+=1
        if category=='completed':
            phase='qwen' if provider=='qwen' else data.get('phase')
            if phase in completed:completed[phase]+=1
        usage=data.get('usage') if data else None
        if not isinstance(usage,dict):continue
        # Absence of a metric is not zero usage. Keep coverage per field.
        accepted={key:counter(usage.get(key)) for key in ('input_tokens','output_tokens','total_tokens')}
        if any(v is not None for v in accepted.values()):
            result[provider]['reported_requests']+=1
        for key,value in accepted.items():
            if value is not None:
                result[provider][key]+=value
                coverage=key+'_reports'
                result[provider][coverage]=result[provider].get(coverage,0)+1
    for usage in result.values():
        for key in ('input_tokens','output_tokens','total_tokens'):
            if not usage.get(key+'_reports'):usage[key]=None
    return result,states,completed


def snapshot(job, control):
    job,control=Path(job),Path(control)
    paths=[('text',p) for p in sorted(job.glob('text/*/request-state.json'))[:400]]
    paths += [('qwen',p) for p in sorted(job.glob('qwen/*/request-state.json'))[:40]]
    usage,states,completed=usage_summary(paths)
    delivery=job/'delivery'
    files=sum((delivery/name).is_file() and not (delivery/name).is_symlink()
              for name in ('Chinese.ass','Bilingual.ass','Chinese.srt','Bilingual.srt',
                           'cues.json','quality.json','recognition-provenance.json','usage.json','manifest.json'))
    published=safe_json(control/'publish-state.json') or {}
    payload=control/'publish-payload.json'
    payload_saved=payload.is_file() and not payload.is_symlink() and 0<payload.stat().st_size<=4_100_000
    quality=safe_json(delivery/'quality.json') or {}
    mode=('published_confirmed' if published.get('state')=='published' else
          'same_lease_publish_only' if payload_saved else
          'manual_reconciliation' if states['unknown'] or states['rejected'] else 'checkpoints_only')
    return {'version':1,'usage':usage,'request_states':states,
            'completed':{**completed,'primary_checkpoint':(job/'primary-cues.json').is_file(),
                         'secondary_checkpoint':(job/'secondary-cues.json').is_file(),
                         'delivery_files':files},
            'recovery':{'mode':mode,'publish_payload_saved':payload_saved,
                        'workspace_bound':True,'permanent_backup':False},
            'quality':{key:quality[key] for key in ('cue_count','warning_count','affected_cue_count','warnings_truncated')
                       if key in quality and type(quality[key]) in (bool,int)},
            'actual_billing_verified':False}


def compact_quality(report):
    """Deliver a bounded report; retain every diagnostic in quality-full.json."""
    result=dict(report)
    result['warning_count']=len(report['warnings'])
    selected=[];size=0
    for warning in report['warnings']:
        cost=len(json.dumps(warning,ensure_ascii=False,separators=(',',':')).encode('utf-8'))+1
        if len(selected)>=800 or size+cost>250_000:break
        selected.append(warning);size+=cost
    result['warnings']=selected
    result['warnings_truncated']=len(selected)<result['warning_count']
    result['full_diagnostics_checkpoint']='quality-full.json'
    return result
