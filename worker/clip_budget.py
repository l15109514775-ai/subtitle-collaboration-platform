"""Separate durable clip allowance. Never opens or changes the completed trial.

The caller must supply the new contract's synchronous heartbeat callback.
No CLI execution is enabled until a real new website job/lease is available.
"""
from datetime import datetime, timezone
import re
import math
from pathlib import Path
from uuid import UUID

import billing
import worker

STATE_ROOT=Path('/workspace/subtitle-clip-budgets')


class ClipBudget:
    def __init__(self,authorization,before_reserve):
        a=dict(authorization)
        self.scope=a.get('scope','')
        if not re.fullmatch(r'clip-[a-zA-Z0-9_-]{8,100}',self.scope):
            raise ValueError('new_clip_scope_required')
        if a.get('approved') is not True or not callable(before_reserve):
            raise ValueError('explicit_clip_authorization_and_live_guard_required')
        UUID(a['job_id']);UUID(a['lease_id'])
        if not re.fullmatch('[0-9a-f]{64}',a.get('source_sha256','')):
            raise ValueError('verified_source_binding_required')
        for key,maximum in (('max_text_requests',20),('max_qwen_requests',2)):
            if type(a.get(key)) is not int or not 0<=a[key]<=maximum:
                raise ValueError('clip_allowance_exceeds_authorized_ceiling')
        if not 0<a.get('clip_seconds',0)<=4200:raise ValueError('clip_duration_over_limit')
        expiry=datetime.fromisoformat(a['expires_at'])
        if expiry.tzinfo is None:raise ValueError('authorization_needs_timezone')
        self.expiry=expiry;self.authorization=a;self.guard=before_reserve
        self.path=STATE_ROOT/(self.scope+'.json')

    def reserve(self,provider):
        if provider not in ('text','qwen'):raise ValueError('unsupported_provider')
        if datetime.now(timezone.utc)>=self.expiry:raise ValueError('clip_authorization_expired')
        # Contract callback must fail on cancellation/revocation/lost lease.
        self.guard(provider)
        with billing.exclusive(STATE_ROOT/(self.scope+'.lock')):
            a=self.authorization
            identity={k:a[k] for k in ('scope','job_id','source_sha256','clip_seconds',
                                      'max_text_requests','max_qwen_requests')}
            if self.path.exists():
                data=worker.read(self.path)
                if data['identity']!=identity:raise ValueError('clip_budget_identity_changed')
            else:data={'identity':identity,'text':0,'qwen':0,'actual_billing_verified':False}
            count=data[provider]
            if type(count) is not int or count<0:raise ValueError('invalid_persistent_count')
            if count>=a['max_'+provider+'_requests']:raise ValueError('clip_budget_exhausted')
            data[provider]+=1
            worker.save(self.path,data)
            return data


def translation_batches(rows,max_requests=20):
    """Plan the ENTIRE translation+review before spending any allowance.

    Output estimate is a planning bound, not provider usage. Truncation remains
    non-retryable. Max 150 cues / 12k source chars / estimated 10k output tokens.
    """
    batches=[];batch=[];chars=0;estimate=0
    for row in rows:
        n=len(row['text']); estimated=math.ceil(n*1.5)+48
        if estimated>10000 or n>12000:raise ValueError('single_cue_requires_resegmentation_before_paid_work')
        if batch and (len(batch)>=150 or chars+n>12000 or estimate+estimated>10000):
            batches.append(batch);batch=[];chars=0;estimate=0
        batch.append(row);chars+=n;estimate+=estimated
    if batch:batches.append(batch)
    if 2*len(batches)>max_requests:
        raise ValueError('whole_segment_translation_and_review_exceed_request_budget_before_execution')
    return batches


def translate(root,selection,budget,deadline,use_qwen=False,qwen_intervals=None):
    """Real provider work only when supplied a separately authorized live budget."""
    from clip_pipeline import validate_selection
    root=Path(root);rows=validate_selection(root,selection)
    if worker.digest(root/'source.mp4')!=selection['source_sha256']:
        raise ValueError('source_checksum_mismatch_before_paid_request')
    if (budget.authorization['source_sha256']!=selection['source_sha256'] or
            abs(budget.authorization['clip_seconds']-(selection['end']-selection['start']))>.001):
        raise ValueError('budget_selection_mismatch')
    batches=translation_batches(rows,budget.authorization['max_text_requests'])
    intervals=qwen_intervals or []
    if use_qwen and (not intervals or len(intervals)>budget.authorization['max_qwen_requests']):
        raise ValueError('explicit_bounded_difficult_audio_intervals_required')
    for interval in intervals:
        if (not 0<=interval['start']<interval['end']<=budget.authorization['clip_seconds'] or
                interval['end']-interval['start']>150 or not interval.get('reason')):
            raise ValueError('invalid_difficult_audio_interval')
    paid=root/'paid'
    identity={'source_sha256':selection['source_sha256'],
              'transcript_sha256':selection['transcript_sha256'],
              'start':selection['start'],'end':selection['end'],
              'scope':budget.scope,'use_qwen':use_qwen,'qwen_intervals':intervals}
    with billing.exclusive(root/'.clip.lock'):
        if (paid/'identity.json').exists() and worker.read(paid/'identity.json')!=identity:
            raise ValueError('paid_clip_identity_changed')
        worker.save(paid/'identity.json',identity)
        cfg=worker.read(Path(__file__).with_name('config.example.json'))
        cfg.update(max_text_requests=budget.authorization['max_text_requests'],
                   max_qwen_requests=budget.authorization['max_qwen_requests'],
                   max_video_seconds=budget.authorization['clip_seconds'],qwen_chunk_seconds=150,
                   max_output_tokens=12000)
        worker.save(paid/'batch-plan.json',{'cue_count':len(rows),'batches':len(batches),
                    'planned_text_requests':2*len(batches),'max_output_tokens':12000,
                    'covers_all_cue_ids':[r['id'] for b in batches for r in b],
                    'output_size_is_estimate':True})
        worker.text_readiness(cfg)
        evidence=[]
        def guarded(provider):
            deadline.remaining()
            return budget.reserve(provider)
        if use_qwen:
            from qwen_asr import recognize
            source=worker.read(root/'source-verified.json')
            offset=selection['start']-source.get('origin_start',0)
            for i,interval in enumerate(intervals):
                audio=paid/f'difficult-{i}.wav'
                length=interval['end']-interval['start']
                if not audio.exists():
                    deadline.run(['ffmpeg','-v','error','-y','-ss',str(offset+interval['start']),
                                  '-i',str(root/'source.mp4'),'-t',str(length),
                                  '-vn','-ac','1','-ar','16000',str(audio)])
                cfg_part=dict(cfg,max_video_seconds=length)
                result=recognize(audio,paid/'secondary'/f'{i:02}',cfg_part,
                                 reservation=guarded,max_chunk_seconds=300)
                evidence.extend(dict(r,start=r['start']+interval['start'],end=r['end']+interval['start']) for r in result)
            worker.save(paid/'secondary-coverage.json',{'intervals':intervals,
                        'full_segment_dual_asr':False,'timing':'source_audio_chunk_not_forced_alignment'})
        translated=[]
        for index,batch in enumerate(batches):
            deadline.remaining()
            first=worker.relay(batch,paid/'text'/f'{index:06}-translate',
                               cfg,'translate',evidence,reservation=guarded)
            translated.extend(worker.relay(first,paid/'text'/f'{index:06}-review',
                               cfg,'review',evidence,reservation=guarded))
        worker.save(root/'translated.json',translated)
        records=[{'checkpoint':str(p.relative_to(paid)),**worker.read(p)}
                 for p in sorted(paid.rglob('request-state.json'))]
        worker.save(paid/'usage.json',{'requests':records,'scope':budget.scope,
                                     'actual_billing_verified':False})
        return translated

