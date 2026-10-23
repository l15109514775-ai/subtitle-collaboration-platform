> **历史记录**：本文件包含早期试验或云端剪辑设置。现行半自动字幕流程、发布来源与统一测试入口以 [RELEASE.md](RELEASE.md) 为准；不要按旧额度或环境名新建/重配环境。

See [20MIN_ENVIRONMENT.md](20MIN_ENVIRONMENT.md) for this branch. Limits are now 1200 seconds / 400 text / 40 Qwen with a separate scope. Historical deployment notes below describe earlier acceptance stages.

# Cloud queue adapter

`platform_worker.py` connects the existing subtitle worker to the restricted
CloudBase RPC. The main task reports migration 021 deployed and database tests
passed. This adapter has only been tested with simulated HTTP so far; no claim,
download, publish, or paid inference has been performed against that deployment.

## Commands

Default invocation performs local checks only: no task claim or HTTP request.

```sh
.venv/bin/python platform_worker.py --work-root /workspace/subtitle-platform
```

After the refreshed environment, source media, and deployment are confirmed,
execution can target one exact website task. Replace `WEBSITE_JOB_UUID` with
the actual task UUID; it is not a credential.

```sh
.venv/bin/python platform_worker.py \
  --job-id WEBSITE_JOB_UUID \
  --work-root /workspace/subtitle-platform --execute
```

Omitting `--job-id` lets the server select the queued task. The adapter processes
one task per invocation, not a permanent daemon. Reusing the same command resumes
its private session. It does not silently claim another task after completion.
`--execute` enables only this authorized trial: server allowances are capped at
60 seconds, 20 text requests and 2 secondary requests. The server's
`max_secondary_requests` maps to `max_qwen_requests`. The shared trial ledger and
source-video SHA256 binding in `billing.py` remain effective across all jobs.

## Identity and input

The API URL is fixed:

`https://example-env.api.tcloudbasegateway.com/v1/rdb/rest/rpc/st_cloud_worker_call`

RPC POST JSON contains `p_key`, `p_action`, `p_job`, `p_payload`. The independent
task capability is read directly from Cloud variable `SUBTITLE_PLATFORM_TOKEN`
into `p_key`. The RPC-only `Authorization: Bearer ...` header comes from
`SUBTITLE_PLATFORM_GATEWAY_KEY`, a dedicated **Publishable Key with anon
permissions**. Neither value nor complete headers are printed or saved in
configuration/checkpoints. Both variables are required; there is no fallback to
personal login, group-leader access tokens, or service-role/admin API keys.
Known non-anon JWT roles are rejected locally; CloudBase remains responsible
for validating the key and signature. The platform configuration must supply the
dedicated Publishable Key, not an opaque administrator key. All post-claim calls
include `p_payload.lease_id`.

CloudBase documents the gateway JWT requirement and Publishable Key's anon
access in [PostgreSQL initialization](https://docs.cloudbase.net/database/postgresql/initialization)
and [API Key configuration](https://docs.cloudbase.net/api-reference/webv2/api-key).
The main task keeps all business tables and unrelated RPCs denied to anon;
only the restricted worker RPC is granted. This adapter does not change grants.

The claim and signed source URLs are saved only under the private work root.
Source paths and file names supplied by the server are never used as filesystem
paths. Sources must use HTTPS, the exact fixed CloudBase host, and port 443 (or
the default). User-info, fragments and redirects are refused. Source requests
use a separate opener with no API JSON body, gateway authorization header,
task capability or cookies.
Inherited platform proxies and CA trust are preserved.

Download streams chunks in server order, checking each chunk's declared/actual
size and the concatenated size and SHA256. A partial/corrupt input is removed;
recognition cannot begin before complete verification. At least 1 GiB disk stays
reserved. The source deadline is the earlier of server `source_expires_at`
(a timezone-aware timestamp) and 23 hours after claim. HTTP 401/403/410 on a source also
stops as expired/revoked. No local-PC refresh or signing operation is attempted.
A fully verified cached cloud input can resume without expired URL access.

## Lease and billing safety

A background heartbeat runs every 40 seconds during configuration checks,
download, recognition, text calls and publishing. Before **every new billable
reservation**, a separate synchronous heartbeat must succeed. An unavailable
console/network, cancellation, revocation, or unrecognized success response
latches the session as failed and prevents new reservations. Successful heartbeat
is exactly a direct object with `state:running` and `lease_seconds:2700`; it has
no `ok` field, `data` wrapper or array envelope. Any incompatible response stops
before a new provider request.

The direct JSONB response contract supplied by the main task is:

| Action | Successful response |
| --- | --- |
| claim | `state:running`, job/lease UUIDs, file metadata, sources, `source_expires_at`, limits |
| claim with no task | `state:no_job`; normal completion, no lease or processing |
| heartbeat | `state:running`, `lease_seconds:2700` |
| stop | `state` matches the requested waiting/failed state |
| publish, including repeat | `state:succeeded`, delivery UUID; `human_review_required:true` may be omitted on repeat |

HTTP 400 `DATABASE_P0001`, HTTP 401 `DATABASE_42501`, gateway
`MISSING_CREDENTIALS`, other non-success statuses, network failures and malformed
objects all prevent further billable reservations. Provider/server message text
is not matched or printed. A no-task result is checkpointed as `no_job`, so a
later explicit invocation can check the queue again without being mistaken for
an ambiguous claim.

The guard is installed in `billing.request_guard`. A generated private config
marked `platform_managed` cannot be used by standalone `worker.py` without that
live guard. Heartbeat progress contains only shared trial request counts.

If a guard refuses before a provider submission, its local model marker is
`not_sent`, not an ambiguous paid attempt. If submission began and its result is
unknown, existing worker checkpoint rules still stop rather than retry.

Failures report `stop` with the lease, a fixed short stage, and small counters:
`waiting_configuration`, `waiting_reconciliation`, or `failed`. If that RPC is
also unavailable, the unsent report remains in the private checkpoint. An
unknown claim is not automatically claimed again. Recovery requiring a new
lease or fresh source URLs stays with the website/main task, not the PC.

## Delivery and ambiguous publish recovery

Exactly nine files are required: `Chinese.ass`, `Bilingual.ass`, `Chinese.srt`,
`Bilingual.srt`, `cues.json`, `quality.json`, `recognition-provenance.json`,
`manifest.json`, `usage.json`. Each must be at most 500,000 raw bytes and the
total at most 2,000,000. Missing files, symlinks and oversized bundles are refused.
Names have no directory components. Base64 encodes original bytes unchanged;
each file includes its byte size and SHA256. `model` is `gpt-6-luna`.

The exact publish payload is durable in the private directory before submission.
On timeout the adapter leaves `submitted_or_unknown` and preserves its lease.
The next identical invocation first replays that same lease/payload as an
idempotent **publish reconciliation**, without invoking recognition or models.
The server must return the same `delivery_id` for a repeated lease. Once that ID
is saved locally, further invocations reuse it without another RPC. Unknown
publish is not followed by `stop`, which could disrupt reconciliation.

Server-side publication creates a Codex version and keeps the task open for
member review; it does not claim the task as human work or award human points.
Only the cloud-private directories and website private storage/DB hold media,
transcripts, subtitles and reports. Git contains source and offline tests only.

## Offline validation

### Explicit recovery after a known Qwen HTTP 401

`qwen_recovery.py --work-root ROOT --job-id UUID --output PRIVATE_PLAN.json`
is offline planning only. It requires the same source SHA256, exactly one
preserved `api_rejected` HTTP 401 marker, zero text attempts, and the shared
ledger at Qwen 1/2. It neither resets usage nor changes the old marker or lease.

After the main task confirms the replacement Cloud secret is published and
explicitly coordinates the known rejection, the website must restore the same
job. Preserve/archive its failed control directory before a new exact-job claim.
Only then add `--qwen-recovery-plan PRIVATE_PLAN.json` to the normal adapter
execution. This flag is explicit authorization to activate that reviewed plan;
it must never be used merely to test authentication. The adapter requires an
exact job ID and a successful live heartbeat before migrating the configuration.

The recovery retains an audit copy of the original identity and uses one new
`qwen/reconciled-full60-00000` request for [0,60], inline private PCM WAV. The
original `qwen/00000` 401 checkpoint remains unchanged and included in usage.
The shared total can increase only from 1 to 2. Unknown/rejected new requests
remain non-retryable; successful saved results may resume without another call.
Both attempts and the successful request count appear separately in provenance.

Official Qwen3-ASR-Flash documentation permits audio up to 5 minutes / 10 MB:
https://www.alibabacloud.com/help/zh/model-studio/non-realtime-speech-recognition-user-guide
The compatible API accepts inline WAV Base64 (encoded input at most 10 MB):
https://www.alibabacloud.com/help/zh/model-studio/qwen-asr-api-reference
The existing Beijing endpoint and model remain unchanged.

For a replacement runtime, transfer private state only through approved private
cloud storage: preserve the complete work root, shared trial ledger and lock
directory, recovery plan, and verified model manifest/files. Restore exact paths,
restrict access, verify hashes/counts before execution, and preserve every old
lease/request marker. Never create a new trial allowance or transfer through PC.
Do not assume an environment status observation proves provider authentication.

```sh
.venv/bin/python -m unittest -v test_worker.py test_cloud.py test_platform_worker.py
```

HTTP simulations cover identity separation, host/redirect rejection, corrupt
and expired sources, cancellation, billing guards, unknown model responses,
nine-file byte preservation and limits, and same-lease publish recovery. They
do not establish real Cloud network access, actual ASR quality or live delivery.

