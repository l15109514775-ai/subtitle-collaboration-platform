"""Per-job server allowances; preserves the original trial ledger unchanged."""
from contextlib import contextmanager
from contextvars import ContextVar
import fcntl
from pathlib import Path
from uuid import UUID

TRIAL_STATE_ROOT = Path('/workspace/subtitle-trial-state')
TRIAL_SCOPE = 'trial-20min-20261021'
JOB_STATE_ROOT = Path('/workspace/subtitle-job-state')
_request_guard = ContextVar('platform_before_reserve', default=None)


@contextmanager
def request_guard(callback):
    token = _request_guard.set(callback)
    try:
        yield
    finally:
        _request_guard.reset(token)


@contextmanager
def exclusive(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def validate_limits(cfg):
    for name, ceiling in (('max_text_requests', 400), ('max_qwen_requests', 40)):
        value = cfg.get(name, 0)
        if type(value) is not int or not 0 <= value <= ceiling:
            raise ValueError('Each video permits at most 400 text and 40 Qwen requests')
    if type(cfg.get('max_video_seconds')) is not int or not 1 <= cfg['max_video_seconds'] <= 1200:
        raise ValueError('Each video permits 1 to 1200 seconds of source media')
    scope_for(cfg)
    if (cfg.get('device'), cfg.get('compute_type'), cfg.get('cpu_threads'), cfg.get('num_workers')) != ('cpu', 'int8', 2, 1):
        raise ValueError('This trial uses CPU/int8, 2 threads and 1 worker only')


def scope_for(cfg):
    scope = cfg.get('authorization_scope')
    if scope == TRIAL_SCOPE:
        return scope
    try:
        job_id = str(UUID(cfg['platform_job_id']))
    except (ValueError, TypeError, KeyError, AttributeError):
        raise ValueError('A server-issued exact job authorization is required') from None
    sha = cfg.get('authorized_sha256', '')
    if (scope != 'job-' + job_id or cfg.get('platform_managed') is not True or
            not isinstance(sha, str) or len(sha) != 64 or
            any(c not in '0123456789abcdef' for c in sha)):
        raise ValueError('Job scope or authorized source identity is invalid')
    return scope


def ledger_path(cfg):
    scope = scope_for(cfg)
    root = TRIAL_STATE_ROOT if scope == TRIAL_SCOPE else JOB_STATE_ROOT
    return root / (scope + '.json')


def snapshot(cfg):
    from worker import read
    ledger = ledger_path(cfg)
    with exclusive(ledger.with_suffix('.lock')):
        return read(ledger) if ledger.exists() else {'text': 0, 'qwen': 0}


def bind_source(cfg, video_sha256):
    from worker import read, save
    validate_limits(cfg)
    if scope_for(cfg) != TRIAL_SCOPE and cfg['authorized_sha256'] != video_sha256:
        raise ValueError('Source does not match server authorization')
    ledger = ledger_path(cfg)
    with exclusive(ledger.with_suffix('.lock')):
        data = read(ledger) if ledger.exists() else {'text': 0, 'qwen': 0}
        if data.get('input_sha256', video_sha256) != video_sha256:
            raise ValueError('This one-round trial is already bound to another source video')
        data['input_sha256'] = video_sha256
        save(ledger, data)


def reserve(job, cfg, provider):
    from worker import read, save
    validate_limits(cfg)
    if provider not in ('text', 'qwen'):
        raise ValueError('Unsupported provider')
    if not cfg.get('billable_execution_approved'):
        raise ValueError('Billable execution has not been approved in configuration')
    guard = _request_guard.get()
    if cfg.get('platform_managed') and guard is None:
        raise RuntimeError('Platform-managed execution requires a live lease guard')
    receipt = guard(provider) if guard is not None else None
    if scope_for(cfg) != TRIAL_SCOPE:
        if (not isinstance(receipt, dict) or receipt.get('state') != 'reserved' or
                receipt.get('authorization_scope') != cfg['authorization_scope']):
            raise RuntimeError('Atomic server request reservation was not confirmed')
        counts = receipt.get('counts', {})
        for name, limit in (('text', cfg['max_text_requests']), ('qwen', cfg['max_qwen_requests'])):
            if type(counts.get(name)) is not int or not 0 <= counts[name] <= limit:
                raise RuntimeError('Server reservation counters are invalid')
        ledger = ledger_path(cfg)
        with exclusive(ledger.with_suffix('.lock')):
            data = read(ledger) if ledger.exists() else {'text': 0, 'qwen': 0}
            if any(counts[name] < data.get(name, 0) for name in ('text', 'qwen')):
                raise RuntimeError('Server request counters moved backwards')
            data.update(counts, input_sha256=cfg['authorized_sha256'], actual_billing_verified=False)
            save(ledger, data)
        return data
    ceilings = {'text': 400, 'qwen': 40}
    scope = cfg.get('authorization_scope')
    if scope != TRIAL_SCOPE:
        raise ValueError('Missing trial authorization scope')
    root = TRIAL_STATE_ROOT
    ledger = root / (scope + '.json')
    with exclusive(root / (scope + '.lock')):
        data = read(ledger) if ledger.exists() else {'text': 0, 'qwen': 0}
        limit = min(cfg.get('max_' + ('text' if provider == 'text' else 'qwen') + '_requests', 0), ceilings[provider])
        if data[provider] >= limit:
            raise RuntimeError('Cumulative trial request allowance exhausted')
        data[provider] += 1
        data['actual_billing_verified'] = False
        save(ledger, data)
    return data

