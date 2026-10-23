"""Private Codex Cloud queue worker. Default is local configuration checks only."""
import argparse
import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import sys
import threading
import time
from urllib.parse import urlsplit
import urllib.error
import urllib.request
from uuid import UUID, uuid4

import billing
import worker
from operational_report import snapshot as operation_snapshot
from delivery_contract import REQUIRED_FILES, MAX_FILE_BYTES, MAX_DELIVERY_BYTES

HOST = 'example-env.api.tcloudbasegateway.com'
API = 'https://' + HOST + '/v1/rdb/rest/rpc/st_cloud_worker_call'
RESERVE_BYTES = 1024**3
SOURCE_TTL = 23 * 3600


class PlatformError(RuntimeError):
    """Messages contain fixed diagnostic codes only, never response bodies."""


class PlatformUnavailable(PlatformError): pass
class LeaseLost(PlatformError): pass
class InputExpired(PlatformError): pass
class InvalidInput(PlatformError): pass
class ConfigurationMissing(PlatformError): pass
class ReconciliationRequired(PlatformError): pass


def private_root(path):
    root = Path(path).resolve()
    if root.is_relative_to(Path(__file__).resolve().parent):
        raise ConfigurationMissing('private_work_root_must_be_outside_repository')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    return root


def valid_uuid(value):
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise InvalidInput('invalid_job_uuid') from None


def safe_source_url(url):
    try:
        parsed = urlsplit(url)
        valid = (parsed.scheme == 'https' and parsed.hostname == HOST and
                 parsed.port in (None, 443) and not parsed.username and
                 not parsed.password and not parsed.fragment and
                 not any(c.isspace() or ord(c) < 32 for c in url))
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise InvalidInput('source_url_domain_or_scheme_rejected')
    return url


def source_expiration(claim):
    try:
        expiration=datetime.fromisoformat(claim['source_expires_at'].replace('Z','+00:00'))
        if expiration.tzinfo is None:
            raise ValueError()
        return expiration.timestamp()
    except (KeyError,ValueError,TypeError,AttributeError,OverflowError):
        raise InvalidInput('source_expiration_invalid') from None


def heartbeat_confirmed(data):
    return (data.get('state') == 'running' and
            type(data.get('lease_seconds')) is int and data['lease_seconds'] == 2700)


def published_confirmed(data):
    if data.get('state') != 'succeeded' or data.get('human_review_required', True) is not True:
        return False
    try:
        valid_uuid(data.get('delivery_id'))
        return True
    except InvalidInput:
        return False


def opener():
    # No cookie jar or HTTP auth handler. Default inherited proxies and CA trust.
    return urllib.request.build_opener(urllib.request.ProxyHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), worker.NoRelayRedirect())


def gateway_key():
    key=os.environ.get('SUBTITLE_PLATFORM_GATEWAY_KEY')
    if not key or any(c.isspace() for c in key):
        raise ConfigurationMissing('platform_publishable_gateway_key_absent_or_invalid')
    # Negative check only; CloudBase still validates signatures/permissions.
    # Never accept a known personal or administrator JWT in this anon-only slot.
    if key.count('.') == 2:
        try:
            middle=key.split('.')[1]
            claims=json.loads(base64.urlsafe_b64decode(middle+'='*((-len(middle))%4)))
        except (ValueError,UnicodeError):
            raise ConfigurationMissing('platform_gateway_jwt_invalid') from None
        if not isinstance(claims,dict) or claims.get('role') not in (None,'anon'):
            raise ConfigurationMissing('platform_gateway_requires_anon_publishable_key')
    return key


class Client:
    def __init__(self):
        if not os.environ.get('SUBTITLE_PLATFORM_TOKEN'):
            raise ConfigurationMissing('platform_identity_absent')
        gateway_key()
        self.http = opener()

    def call(self, action, job=None, payload=None):
        if action not in ('claim', 'heartbeat', 'stop', 'publish', 'reserve'):
            raise PlatformError('invalid_action')
        key = os.environ.get('SUBTITLE_PLATFORM_TOKEN')
        if not key:
            raise ConfigurationMissing('platform_identity_absent')
        gateway = gateway_key()
        payload = dict(payload or {})
        if action == 'claim':
            payload['workflow_version'] = 'per-job-v1'
        body = {'p_key': key, 'p_action': action, 'p_job': job, 'p_payload': payload}
        request = urllib.request.Request(API, data=json.dumps(body).encode('utf-8'),
            headers={'Content-Type': 'application/json',
                     'Authorization': 'Bearer '+gateway}, method='POST')
        try:
            with self.http.open(request, timeout=30) as response:
                if response.status != 200:
                    raise PlatformUnavailable('platform_http_non_success')
                raw = response.read(2_000_001)
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            if status in (401, 403, 404, 409, 410):
                raise LeaseLost('platform_identity_task_or_lease_rejected') from None
            raise PlatformUnavailable('platform_http_unavailable') from None
        except (OSError, TimeoutError, urllib.error.URLError):
            raise PlatformUnavailable('platform_network_unavailable') from None
        if len(raw) > 2_000_000 or key.encode() in raw or gateway.encode() in raw:
            raise PlatformUnavailable('platform_response_rejected')
        try:
            data = json.loads(raw)
        except (ValueError, UnicodeError):
            raise PlatformUnavailable('platform_response_invalid') from None
        if not isinstance(data, dict):
            raise PlatformUnavailable('platform_response_shape_invalid')
        if data.get('code') or data.get('error') or data.get('state') in ('cancelled', 'revoked', 'expired'):
            raise LeaseLost('platform_task_or_identity_inactive')
        if action == 'heartbeat' and not heartbeat_confirmed(data):
            raise PlatformUnavailable('heartbeat_success_not_confirmed')
        if action == 'claim' and data.get('state') not in ('running','no_job'):
            raise PlatformUnavailable('claim_success_not_confirmed')
        if action == 'stop' and (data.get('state') not in
                ('waiting_configuration','waiting_reconciliation','failed') or
                data.get('state') != body['p_payload'].get('state')):
            raise PlatformUnavailable('stop_success_not_confirmed')
        if action == 'publish' and not published_confirmed(data):
            raise PlatformUnavailable('publish_success_not_confirmed')
        if action == 'reserve' and data.get('state') != 'reserved':
            raise PlatformUnavailable('request_reservation_not_confirmed')
        return data


def validate_claim(data, expected_job=None):
    if not isinstance(data, dict):
        raise InvalidInput('claim_shape_invalid')
    job_id = valid_uuid(data.get('job_id'))
    if data.get('state') != 'running':
        raise InvalidInput('claim_state_invalid')
    if expected_job and job_id != valid_uuid(expected_job):
        raise InvalidInput('claim_job_mismatch')
    valid_uuid(data.get('lease_id'))
    source_expiration(data)
    for name in ('byte_size', 'max_video_seconds', 'max_text_requests', 'max_secondary_requests'):
        if type(data.get(name)) is not int or data[name] <= 0:
            raise InvalidInput('claim_limits_invalid')
    if data['byte_size'] > 1024**3:
        raise InvalidInput('source_size_exceeds_trial_limit')
    sha = data.get('sha256')
    if not isinstance(sha, str) or len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha):
        raise InvalidInput('source_sha256_invalid')
    if data.get('workflow_version') == 'per-job-v1' or 'authorization_scope' in data:
        if (data.get('workflow_version') != 'per-job-v1' or
                data.get('authorization_scope') != 'job-' + job_id or
                data['max_video_seconds'] > 1200 or data['max_text_requests'] > 400 or
                data['max_secondary_requests'] > 40):
            raise InvalidInput('server_job_authorization_invalid')
    sources = data.get('sources')
    if not isinstance(sources, list) or not 1 <= len(sources) <= 10_000:
        raise InvalidInput('source_list_invalid')
    total = 0
    for source in sources:
        if not isinstance(source, dict) or type(source.get('byte_size')) is not int or source['byte_size'] <= 0:
            raise InvalidInput('source_chunk_size_invalid')
        safe_source_url(source.get('url'))
        total += source['byte_size']
    if total != data['byte_size']:
        raise InvalidInput('source_chunk_total_mismatch')
    return job_id


def download(claim, destination, claimed_at, check_active):
    """Stream source chunks in server order, then verify complete file identity."""
    validate_claim(claim)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.exists():
        if destination.stat().st_size == claim['byte_size'] and worker.digest(destination) == claim['sha256']:
            return destination
        raise InvalidInput('cached_source_corrupted')
    expires_at=min(claimed_at+SOURCE_TTL,source_expiration(claim))
    if time.time() >= expires_at:
        raise InputExpired('source_urls_expired_no_local_refresh')
    if shutil.disk_usage(destination.parent).free < claim['byte_size'] + RESERVE_BYTES:
        raise ConfigurationMissing('insufficient_private_disk_reserve')
    pending = destination.with_suffix('.pending')
    digest = hashlib.sha256()
    total = 0
    http = opener()  # Deliberately separate from the API client and its JSON identity.
    try:
        with pending.open('wb') as output:
            for source in claim['sources']:
                check_active()
                if time.time() >= expires_at:
                    raise InputExpired('source_urls_expired_no_local_refresh')
                request = urllib.request.Request(safe_source_url(source['url']),
                    headers={'Accept-Encoding': 'identity'}, method='GET')
                try:
                    response = http.open(request, timeout=30)
                except urllib.error.HTTPError as error:
                    status = error.code
                    error.close()
                    if status in (401, 403, 410):
                        raise InputExpired('source_url_expired_or_access_revoked') from None
                    raise InvalidInput('source_http_rejected_no_redirect') from None
                except (OSError, TimeoutError, urllib.error.URLError):
                    raise PlatformUnavailable('source_download_unavailable') from None
                count = 0
                with response:
                    if response.status != 200:
                        raise InvalidInput('source_http_non_success')
                    declared = response.headers.get('Content-Length')
                    if declared is not None and declared != str(source['byte_size']):
                        raise InvalidInput('source_content_length_mismatch')
                    while block := response.read(1024**2):
                        check_active()
                        count += len(block); total += len(block)
                        if count > source['byte_size'] or total > claim['byte_size']:
                            raise InvalidInput('source_stream_size_exceeded')
                        if shutil.disk_usage(destination.parent).free < RESERVE_BYTES + len(block):
                            raise ConfigurationMissing('private_disk_reserve_reached')
                        output.write(block); digest.update(block)
                if count != source['byte_size']:
                    raise InvalidInput('source_chunk_truncated')
            if total != claim['byte_size'] or digest.hexdigest() != claim['sha256']:
                raise InvalidInput('source_complete_size_or_sha256_mismatch')
            output.flush(); os.fsync(output.fileno())
        pending.replace(destination)
        worker.save(destination.parent/'input-verified.json', {'bytes':total,'sha256':claim['sha256']})
        return destination
    except BaseException:
        pending.unlink(missing_ok=True)
        raise


class Lease:
    def __init__(self, client, claim, interval=40):
        if not 30 <= interval <= 60:
            raise ValueError('heartbeat_interval_must_be_30_to_60_seconds')
        self.client, self.claim, self.interval = client, claim, interval
        self.stage = 'preparing'
        self.progress = {'text_requests':0,'secondary_requests':0}
        self.job_root = None
        self.control_root = None
        self.failure = None
        self.lock = threading.Lock()
        self.ended = threading.Event()
        self.thread = None

    def check_active(self):
        if self.failure is not None:
            raise self.failure

    def pulse(self, stage=None):
        with self.lock:
            self.check_active()
            if stage: self.stage = stage
            try:
                counts = billing.snapshot(limited_config(self.claim))
                self.progress={'text_requests':counts.get('text',0),
                               'secondary_requests':counts.get('qwen',0)}
                if self.job_root is not None and self.control_root is not None:
                    self.progress['operations_v1']=operation_snapshot(self.job_root,self.control_root)
                data = self.client.call('heartbeat',self.claim['job_id'],{
                    'lease_id':self.claim['lease_id'], 'stage':self.stage,
                    'progress':dict(self.progress)})
                # Fail closed on an unrecognized success envelope.
                if not heartbeat_confirmed(data):
                    raise PlatformUnavailable('heartbeat_success_not_confirmed')
            except Exception as error:
                self.failure = error if isinstance(error,PlatformError) else PlatformUnavailable('heartbeat_unavailable')
                raise self.failure

    def before_reserve(self, provider):
        self.pulse('text_request' if provider == 'text' else 'secondary_request')
        if self.claim.get('authorization_scope', '').startswith('job-'):
            result = self.client.call('reserve', self.claim['job_id'], {
                'lease_id': self.claim['lease_id'], 'provider': provider,
                'request_id': str(uuid4())})
            if result.get('authorization_scope') != self.claim['authorization_scope']:
                raise PlatformUnavailable('request_reservation_scope_mismatch')
            return result

    def _loop(self):
        next_due = time.monotonic() + self.interval
        while not self.ended.wait(max(0,next_due-time.monotonic())):
            try: self.pulse()
            except Exception: return
            next_due += self.interval

    def __enter__(self):
        self.pulse()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *unused):
        self.ended.set()
        if self.thread: self.thread.join(timeout=35)


def bundle(delivery):
    delivery = Path(delivery).resolve()
    files, total = [], 0
    for name in REQUIRED_FILES:
        path = delivery/name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
            raise InvalidInput('delivery_file_missing_or_oversized')
        raw = path.read_bytes()
        total += len(raw)
        if len(raw) > MAX_FILE_BYTES or total > MAX_DELIVERY_BYTES:
            raise InvalidInput('delivery_total_size_exceeded')
        files.append({'name':name,'base64':base64.b64encode(raw).decode('ascii'),
                      'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)})
    return files


def publish(client, claim, control, delivery=None, progress=None):
    """Same-lease idempotent publish is the only permitted ambiguous RPC replay."""
    payload_file = control/'publish-payload.json'
    state_file = control/'publish-state.json'
    if state_file.exists() and worker.read(state_file).get('state') == 'published':
        return worker.read(state_file)
    if payload_file.exists():
        payload = worker.read(payload_file)
        if payload.get('lease_id') != claim['lease_id']:
            raise ReconciliationRequired('publish_lease_changed')
    else:
        payload = {'lease_id':claim['lease_id'], 'model':'gpt-6-luna',
                   'files':bundle(delivery), 'progress':progress or {}}
        worker.save(payload_file,payload)
    worker.save(state_file,{'state':'submitted_or_unknown','lease_id':claim['lease_id']})
    try:
        result = client.call('publish',claim['job_id'],payload)
        delivery_id = result.get('delivery_id')
        if not published_confirmed(result):
            raise PlatformUnavailable('publish_delivery_id_not_confirmed')
        state = {'state':'published','job_id':claim['job_id'],'delivery_id':delivery_id}
        worker.save(state_file,state)
    except Exception:
        raise ReconciliationRequired('publish_result_unknown_recheck_same_lease_without_models') from None
    return state


def limited_config(claim):
    cfg = worker.read(Path(__file__).with_name('config.example.json'))
    cfg.update(billable_execution_approved=True, platform_managed=True,
        max_video_seconds=min(1200,claim['max_video_seconds']),
        max_text_requests=min(400,claim['max_text_requests']),
        max_qwen_requests=min(40,claim['max_secondary_requests']))
    if claim.get('authorization_scope', '').startswith('job-'):
        cfg.update(authorization_scope=claim['authorization_scope'],
                   platform_job_id=valid_uuid(claim['job_id']), authorized_sha256=claim['sha256'])
    billing.validate_limits(cfg)
    return cfg


def config_ready():
    from qwen_asr import readiness
    from runtime import model_ready
    cfg=worker.read(Path(__file__).with_name('config.example.json'))
    try:
        worker.text_readiness(cfg)
        readiness(cfg)
        if not model_ready(load=True)['ready']:
            raise ConfigurationMissing('pinned_whisper_model_not_ready')
    except Exception:
        raise ConfigurationMissing('recognition_configuration_not_ready') from None


def stop(client, claim, control, state, stage, progress):
    # The last heartbeat precedes reservation, so its counters can be stale
    # when a provider rejects or returns an unknown result.
    progress = dict(progress)
    counts = billing.snapshot(limited_config(claim))
    for target, source in (('text_requests','text'),('secondary_requests','qwen')):
        value = counts[source]
        if type(value) is not int or value < 0:
            raise ValueError('invalid_persistent_request_count')
        progress[target] = max(progress.get(target,0), value)
    payload={'lease_id':claim['lease_id'],'state':state,'stage':stage,'progress':progress}
    worker.save(control/'stop-state.json', {'state':state,'stage':stage,'progress':progress,'reported':False})
    try:
        result=client.call('stop',claim['job_id'],payload)
        if result.get('state') != state:
            return
    except Exception:
        return
    worker.save(control/'stop-state.json', {'state':state,'stage':stage,'progress':progress,'reported':True})


def execute(args):
    if not args.job_id:
        raise ConfigurationMissing('exact_website_job_id_required_no_implicit_queue_claim')
    if getattr(args, 'qwen_recovery_plan', None) and not args.job_id:
        raise ConfigurationMissing('explicit_recovery_requires_exact_existing_job_id')
    root=private_root(args.work_root)
    selector=valid_uuid(args.job_id) if args.job_id else 'queue'
    control=root/'control'/selector
    with billing.exclusive(control/'.adapter.lock'):
        client=Client()
        session_file=control/'session.json'
        if getattr(args,'publish_only',False):
            # No fresh claim, recognition, model call or payload reconstruction.
            # Only the original saved identity/lease and exact saved bytes qualify.
            if not session_file.is_file() or session_file.is_symlink():
                raise ReconciliationRequired('publish_only_requires_original_workspace_session')
            session=worker.read(session_file)
            claim=session['claim'];validate_claim(claim,args.job_id)
            state=worker.read(control/'publish-state.json') if (control/'publish-state.json').is_file() else {}
            if state.get('state')!='published' and (not (control/'publish-payload.json').is_file() or (control/'publish-payload.json').is_symlink()):
                raise ReconciliationRequired('publish_only_requires_saved_payload_no_model_fallback')
            return publish(client,claim,control)
        if session_file.exists():
            session=worker.read(session_file)
            claim=session['claim']; validate_claim(claim,args.job_id)
        else:
            marker=control/'claim-state.json'
            if marker.exists() and worker.read(marker).get('state') != 'no_job':
                raise ReconciliationRequired('claim_result_unknown_do_not_reclaim')
            worker.save(marker,{'state':'submitted_or_unknown'})
            claim=client.call('claim',args.job_id,{})
            if claim.get('state') == 'no_job':
                worker.save(marker,{'state':'no_job'})
                return {'state':'no_job'}
            # Retain raw claim privately before validation so an active lease is not lost.
            session={'claim':claim,'claimed_at':time.time()}
            worker.save(session_file,session)
            validate_claim(claim,args.job_id)
        # Resolve ambiguous publish first. Never rerun recognition/translation here.
        if (control/'publish-state.json').exists() or (control/'publish-payload.json').exists():
            return publish(client,claim,control)
        cfg=limited_config(claim)
        lease=Lease(client,claim)
        lease.job_root=root/'jobs'/claim['job_id']
        lease.control_root=control
        try:
            with lease:
                lease.stage='checking_configuration'
                config_ready()
                lease.stage='downloading'
                video=download(claim,root/'inputs'/claim['job_id']/'source.media',
                               session['claimed_at'],lease.check_active)
                if getattr(args, 'qwen_recovery_plan', None):
                    from qwen_recovery import apply_plan
                    cfg = apply_plan(root, claim['job_id'], cfg, args.qwen_recovery_plan)
                config=root/'configs'/(claim['job_id']+'.json')
                worker.save(config,cfg)
                worker_args=argparse.Namespace(video=video,config=config,execute=True,
                    primary=None,secondary=None,primary_source_sha256=None,
                    work_root=root/'jobs',job_id=claim['job_id'])
                lease.stage='recognition_and_text'
                with billing.request_guard(lease.before_reserve):
                    worker.run(worker_args)
                lease.pulse('publishing')
                return publish(client,claim,control,root/'jobs'/claim['job_id']/'delivery',lease.progress)
        except ReconciliationRequired:
            # Unknown publish must retain its lease/payload for idempotent reconciliation.
            try:
                lease.pulse('publish_result_needs_reconciliation')
            except Exception:
                pass  # Reporting failure never causes a publish or model retry.
            raise
        except Exception as error:
            model_markers=list((root/'jobs'/claim['job_id']).glob('text/*/request-state.json'))+list((root/'jobs'/claim['job_id']).glob('qwen/*/request-state.json'))
            unknown=any(worker.read(p).get('state') not in ('completed','not_sent') for p in model_markers)
            if unknown:
                state,stage='waiting_reconciliation','model_request_needs_reconciliation'
            elif isinstance(error,(ConfigurationMissing,PlatformUnavailable,LeaseLost,InputExpired)):
                state,stage='waiting_configuration','platform_or_configuration_unavailable'
            else:
                state,stage='failed','input_or_processing_failed'
            if not unknown and (isinstance(error,InvalidInput) and str(error).startswith('delivery_') or isinstance(error,ValueError) and str(error).startswith('Delivery ')):
                state,stage='failed','delivery_validation_failed'
            elif not unknown and isinstance(error,InputExpired):
                stage='source_authorization_expired'
            lease.progress['operations_v1']=operation_snapshot(lease.job_root,control)
            stop(client,claim,control,state,stage,dict(lease.progress))
            raise PlatformError(stage) from None


def main(argv=None):
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job-id',help='Optional exact website job UUID')
    parser.add_argument('--work-root',default='/workspace/subtitle-platform')
    parser.add_argument('--execute',action='store_true',help='Claim the exact authorized job, process and publish within server limits')
    parser.add_argument('--publish-only',action='store_true',help='Explicit same-workspace saved-payload publication only; never claim or invoke models')
    parser.add_argument('--qwen-recovery-plan', help='Explicitly reviewed same-job recovery plan; never selects a new job')
    args=parser.parse_args(argv)
    try:
        if not args.execute:
            print(json.dumps({'state':'checked_not_claimed','request_sent':False,
                'platform_identity_present':bool(os.environ.get('SUBTITLE_PLATFORM_TOKEN')),
                'platform_gateway_key_present':bool(os.environ.get('SUBTITLE_PLATFORM_GATEWAY_KEY')),
                'work_root_outside_repository':not Path(args.work_root).resolve().is_relative_to(Path(__file__).resolve().parent)}))
            return 0
        result=execute(args)
        print(json.dumps(result))
        return 0
    except Exception as error:
        # Never serialize arbitrary exception text, source URLs, API bodies or identity values.
        print(json.dumps({'state':'stopped','error_type':type(error).__name__,
                          'paid_requests_retried':False,'details':'inspect_private_state_checkpoints'}))
        return 1


if __name__=='__main__':
    sys.exit(main())

