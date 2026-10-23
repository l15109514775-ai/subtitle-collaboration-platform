"""Qwen3-ASR-Flash: inline private WAV, no public upload and no automatic retry.

Protocol: https://www.alibabacloud.com/help/zh/model-studio/qwen-asr-api-reference
Verified against the documentation updated 2026-10-11. Returned text has no
word timestamps: intervals below describe source audio chunks only.
"""
import base64
import json
import math
import os
from pathlib import Path
import re
import ssl
import subprocess
from urllib.parse import urlsplit
import urllib.error
import urllib.request

from billing import reserve


def endpoint(cfg):
    base = urlsplit(cfg.get('qwen_base_url') or '')
    allowed = base.hostname in ('dashscope.aliyuncs.com', 'dashscope-intl.aliyuncs.com') or bool(re.fullmatch(
        r'[a-zA-Z0-9-]+\.(cn-beijing|ap-southeast-1)\.maas\.aliyuncs\.com', base.hostname or ''))
    if not (allowed and base.scheme == 'https' and base.path.rstrip('/') == '/compatible-mode/v1'
            and not base.query and not base.fragment and not base.username and not base.password and base.port in (None, 443)):
        raise ValueError('Configure the explicit regional Qwen compatible-mode endpoint; no provider fallback')
    if cfg.get('qwen_model') != 'qwen3-asr-flash':
        raise ValueError('Only qwen3-asr-flash is approved for this trial')
    return cfg['qwen_base_url'].rstrip('/') + '/chat/completions'


def readiness(cfg, policy_path='/etc/codex/network-policy.json'):
    from worker import read
    url = endpoint(cfg)
    variable = cfg.get('qwen_credential_env')
    if variable not in ('SUBTITLE_QWEN_TOKEN', 'DASHSCOPE_API_KEY'):
        raise ValueError('Select a Cloud-managed Qwen credential variable explicitly')
    key = os.environ.get(variable, '')
    if not key or any(c.isspace() for c in key):
        raise ValueError('Selected Qwen credential is absent from Cloud secret management')
    try:
        policy = read(policy_path)
    except (OSError, ValueError):
        raise ValueError('Current network policy snapshot is unavailable') from None
    http = policy.get('http_network_policy', {})
    hosts = {item.get('host') for item in http.get('egress_rules', [])}
    if policy.get('version') != 1 or not (http.get('type') == 'unrestricted' or
            (http.get('type') == 'restricted' and urlsplit(url).hostname in hosts)):
        raise ValueError('Qwen target domain has not been configured in Cloud network policy')
    return url, key


def open_request(url, key, payload):
    from worker import NoRelayRedirect
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), NoRelayRedirect())
    request = urllib.request.Request(url, data=json.dumps(payload).encode(),
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}, method='POST')
    try:
        return opener.open(request, timeout=180)
    except urllib.error.HTTPError as error:
        return error


def recognize(audio, job, cfg, *, reservation=None, max_chunk_seconds=60):
    from worker import digest, probe, read, save, validate_cues
    duration = probe(audio)
    # Match the worker's 1 ms decoding tolerance without turning a codec tail
    # into a third paid chunk. Never send audio beyond the authorized duration.
    limit = cfg.get('max_video_seconds', 60)
    if duration > limit + 0.001:
        raise ValueError('Decoded audio exceeds the authorized trial duration')
    duration = min(duration, limit)
    chunk_seconds = cfg.get('qwen_chunk_seconds', 30)
    if (type(max_chunk_seconds) is not int or not 1 <= max_chunk_seconds <= 300 or
            (max_chunk_seconds > 60 and reservation is None)):
        raise ValueError('Longer clip ASR requires a separate authorized reservation')
    if type(chunk_seconds) is not int or not 1 <= chunk_seconds <= max_chunk_seconds:
        raise ValueError('Qwen chunk size exceeds the explicitly authorized audio bound')
    chunks = math.ceil(duration / chunk_seconds)
    if chunks > cfg.get('max_qwen_requests', 0):
        raise ValueError('Source audio requires more Qwen requests than this job permits')
    rows = []
    reconciliation = cfg.get('qwen_reconciliation')
    if reconciliation:
        from qwen_recovery import PREFIX, validate_rejected
        validate_rejected(job, reconciliation)
        if chunk_seconds != 60 or chunks != 1:
            raise ValueError('Reconciled request must cover one full authorized audio segment')
    for index in range(chunks):
        start = index * chunk_seconds
        end = min(duration, start + chunk_seconds)
        folder = job / 'qwen' / ((PREFIX if reconciliation else '') + f'{index:05}')
        response_file = folder / 'response.json'
        marker = folder / 'request-state.json'
        if marker.exists() and not response_file.exists() and read(marker).get('state') != 'not_sent':
            raise RuntimeError('Previous Qwen request has no saved response; manual reconciliation required')
        if not response_file.exists():
            url, key = readiness(cfg)
            folder.mkdir(parents=True, exist_ok=True)
            part = folder / 'source.wav'
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', str(start), '-i', str(audio),
                '-t', str(end-start), '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(part)], check=True)
            encoded = base64.b64encode(part.read_bytes()).decode('ascii')
            if len(encoded) + len('data:audio/wav;base64,') > 10_000_000:
                raise ValueError('Inline Qwen input exceeds documented 10 MB limit')
            payload = {'model': cfg['qwen_model'], 'stream': False,
                'messages': [{'role': 'user', 'content': [{'type': 'input_audio',
                    'input_audio': {'data': 'data:audio/wav;base64,' + encoded}}]}],
                'asr_options': {'language': 'ja', 'enable_itn': False}}
            # Marker precedes reservation/network: a crash cannot cause an automatic resend.
            save(marker, {'state': 'request_in_progress_or_unknown', 'model': cfg['qwen_model'],
                'source_start': start, 'source_end': end, 'audio_sha256': digest(part),
                'timing_method': 'source_audio_chunk_interval_not_word_alignment'})
            try:
                if reservation is None:
                    reserve(job, cfg, 'qwen')
                else:
                    reservation('qwen')
            except Exception:
                save(marker, {'state':'not_sent','network_submission_started':False})
                raise
            response = None
            try:
                response = open_request(url, key, payload)
                raw = response.read(2_000_001)
                if response.status != 200:
                    save(marker, {'state': 'api_rejected', 'http_status': response.status, 'automatic_retries': 0})
                    raise RuntimeError('Qwen request rejected; reconcile before any further execution')
                if len(raw) > 2_000_000:
                    raise RuntimeError('Qwen response too large; reconcile manually')
                if key in raw.decode('utf-8'):
                    raise RuntimeError('Credential echo rejected')
                save(response_file, json.loads(raw))
            finally:
                if response is not None: response.close()
        data = read(response_file)
        choices = data.get('choices', [])
        if not choices or choices[0].get('finish_reason') != 'stop':
            raise RuntimeError('Qwen response incomplete; reconcile manually without resending')
        text = choices[0].get('message', {}).get('content')
        if not isinstance(text, str) or not text.strip():
            raise ValueError('No usable Qwen speech text; human review required')
        row = {'id': index + 1, 'start': start, 'end': end, 'text': text.strip(), 'review': True,
               'timing_method': 'source_audio_chunk_interval_not_word_alignment'}
        validate_cues([row], duration)
        rows.append(row)
        previous = read(marker) if marker.exists() else {}
        save(marker, dict(previous, state='completed', source_start=start, source_end=end,
            timing_method=row['timing_method'], usage=data.get('usage'),
            provider_request_id=data.get('id'), actual_billing_verified=False))
    return rows

