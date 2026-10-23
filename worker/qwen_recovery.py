"""Offline planning and explicit same-job reconciliation of one rejected request.

This module never sends HTTP, changes a lease, deletes a marker, or resets usage.
The adapter may apply a reviewed plan only with its explicit CLI option and a
fresh live lease. A planned recovery is not authorization to execute it.
"""
import argparse
import hashlib
import json
from pathlib import Path

import billing
import worker

PREFIX = 'reconciled-full60-'


def config_hash(cfg):
    return hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()


def validate_rejected(job, record):
    marker = Path(job) / 'qwen/00000/request-state.json'
    if worker.digest(marker) != record['rejected_marker_sha256']:
        raise ValueError('Reviewed rejected request changed')
    data = worker.read(marker)
    if data.get('state') != 'api_rejected' or data.get('http_status') != 401:
        raise ValueError('Only a known HTTP 401 rejection can be reconciled')
    if (marker.parent / 'response.json').exists():
        raise ValueError('Rejected request unexpectedly has a response checkpoint')


def plan(root, job_id):
    root = Path(root)
    job = root / 'jobs' / job_id
    cfg = worker.read(root / 'configs' / (job_id + '.json'))
    identity = worker.read(job / 'identity.json')
    ledger = worker.read(billing.TRIAL_STATE_ROOT / (billing.TRIAL_SCOPE + '.json'))
    if ledger.get('qwen') != 1 or ledger.get('text') != 0:
        raise ValueError('Planning requires exactly one Qwen attempt and zero text attempts')
    if identity['input_sha256'] != ledger['input_sha256'] or worker.digest(root/'inputs'/job_id/'source.media') != ledger['input_sha256']:
        raise ValueError('Recovery source does not match the shared trial')
    if identity['config_sha256'] != config_hash(cfg):
        raise ValueError('Original job configuration changed')
    markers = list(job.glob('qwen/*/request-state.json')) + list(job.glob('text/*/request-state.json'))
    if markers != [job/'qwen/00000/request-state.json']:
        raise ValueError('Recovery requires exactly the original rejected request')
    if (job/'secondary-cues.json').exists() or (job/'delivery').exists():
        raise ValueError('Recovery cannot replace existing recognition or delivery')
    result = {'version': 1, 'state': 'planned_not_activated', 'job_id': job_id,
        'input_sha256': ledger['input_sha256'], 'original_config_sha256': config_hash(cfg),
        'rejected_marker_sha256': worker.digest(markers[0]),
        'qwen_chunk_seconds': 60, 'new_request_prefix': PREFIX,
        'prior_attempts': 1, 'new_attempts_maximum': 1,
        'official_audio_limit_seconds': 300, 'inline_limit_bytes': 10_000_000}
    validate_rejected(job, result)
    return result


def apply_plan(root, job_id, cfg, plan_path):
    """Called only after explicit CLI selection and a successful live heartbeat."""
    root = Path(root); job = root/'jobs'/job_id
    record = worker.read(plan_path)
    if (record.get('version'), record.get('state'), record.get('job_id'),
            record.get('qwen_chunk_seconds'), record.get('new_request_prefix'),
            record.get('prior_attempts'), record.get('new_attempts_maximum')) != (
            1, 'planned_not_activated', job_id, 60, PREFIX, 1, 1):
        raise ValueError('Invalid explicit recovery plan')
    validate_rejected(job, record)
    if config_hash(cfg) != record['original_config_sha256']:
        raise ValueError('New lease configuration differs from reviewed plan')
    ledger = worker.read(billing.TRIAL_STATE_ROOT/(billing.TRIAL_SCOPE+'.json'))
    if ledger.get('input_sha256') != record['input_sha256'] or ledger.get('qwen') not in (1,2):
        raise ValueError('Recovery ledger/source mismatch')
    if worker.digest(root/'inputs'/job_id/'source.media') != record['input_sha256']:
        raise ValueError('Recovery source checksum mismatch')
    cfg = dict(cfg, qwen_chunk_seconds=60, qwen_reconciliation=record)
    with billing.exclusive(job/'.worker.lock'):
        identity = worker.read(job/'identity.json')
        if identity['input_sha256'] != record['input_sha256']:
            raise ValueError('Recovery identity source mismatch')
        audit = job/'reconciliation/original-identity.json'
        if audit.exists():
            if worker.read(audit)['config_sha256'] != record['original_config_sha256']:
                raise ValueError('Recovery audit mismatch')
        else:
            if ledger['qwen'] != 1 or ledger.get('text') != 0 or identity['config_sha256'] != record['original_config_sha256']:
                raise ValueError('Recovery activation requires original zero-text checkpoints')
            markers = list(job.glob('qwen/*/request-state.json')) + list(job.glob('text/*/request-state.json'))
            if markers != [job/'qwen/00000/request-state.json']:
                raise ValueError('Additional request checkpoints require reconciliation')
            worker.save(audit, identity)
        if identity['config_sha256'] not in (record['original_config_sha256'], config_hash(cfg)):
            raise ValueError('Recovery identity configuration changed')
        worker.save(job/'reconciliation/plan.json', record)
        worker.save(job/'identity.json', dict(identity, config_sha256=config_hash(cfg)))
    return cfg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', required=True)
    parser.add_argument('--job-id', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    from platform_worker import valid_uuid
    job_id = valid_uuid(args.job_id)
    with billing.exclusive(Path(args.work_root)/'control'/job_id/'.adapter.lock'):
        with billing.exclusive(Path(args.work_root)/'jobs'/job_id/'.worker.lock'):
            result = plan(args.work_root, job_id)
            output = Path(args.output)
            if output.exists():
                if worker.read(output) != result:
                    raise ValueError('Refuse to overwrite a different recovery plan')
            else:
                worker.save(output, result)
    print(json.dumps({'state':'planned_not_activated','paid_request_sent':False}))


if __name__ == '__main__':
    main()

