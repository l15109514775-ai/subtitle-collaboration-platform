> 归档资料：仅记录研发过程，不是当前部署指南，也不授予付费或权限操作授权。当前入口见 [从零搭建](../../docs/从零搭建.md)。

> **历史记录**：本文件包含早期试验或云端剪辑设置。现行半自动字幕流程、发布来源与统一测试入口以 [RELEASE.md](RELEASE.md) 为准；不要按旧额度或环境名新建/重配环境。

See [20MIN_ENVIRONMENT.md](20MIN_ENVIRONMENT.md) for the new environment and acceptance gate. Historical 60-second evidence below is not 20-minute validation.

# Subtitle worker in Codex Cloud

The compute target is Codex Cloud. No PC process, local model server, local key
file, GPU, or purchased cloud resource is required. This repository supplies the
worker, not a continuously running service. The existing website and private
artifact storage are separate from subtitle compute.

## Current authorization

The current acceptance is **one up-to-20-minute real sample with fresh
recognition**, cumulatively at most **400 GPT text requests and 40 Qwen ASR
requests**. This is a one-round authorization, not ongoing consumption. The code
rejects higher limits and uses CPU/int8, two threads, one worker. Historical ASR
reuse remains supported but does not demonstrate fresh recognition.

Environment preparation sends no billable request. Do not execute acceptance
until the real media and the main task's restricted website interfaces are ready.
`config.example.json` intentionally keeps execution disabled and both allowances
zero. Only the task's private configuration may enable the authorized acceptance.

## Provision the runtime

Python 3.11+ and `ffmpeg`/`ffprobe` on PATH are required. Dependencies are fully
version-pinned in `requirements.lock` (installed/tested on Python 3.12 Linux).

```sh
./setup_runtime.sh
.venv/bin/python runtime.py check --load-model
.venv/bin/python runtime.py gpt-models
.venv/bin/python -m unittest -v test_worker.py test_cloud.py
```

`setup_runtime.sh` creates `.venv`, installs the lock, and downloads only the
selected CTranslate2 large-v3-turbo files to `/workspace/subtitle-models/large-v3-turbo`. The model
repository was renamed from mobiuslabsgmbh to dropbox-dash. `model.lock.json`
pins revision `0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf`. Downloads verify
the pinned revision, declared sizes, and LFS SHA256 / Git blob identity, then
record actual SHA256 values and total size in `model-manifest.json` beside the
model. Expected download is about 1.62 GB; the lock's upper-bound estimate is
1.8 GB. Actual installed size is reported only after verification.

Setup requires at least 4 GiB free initially and retains at least 1 GiB free
throughout model downloads. The installer creates
`/workspace/subtitle-models/large-v3-turbo` using the existing worker account.
The model and `.venv` both live on the Cloud filesystem, outside any PC dependency.
There is no sudo, mirror, alternate-model, or direct-network fallback. Interrupted public model downloads can be rerun; an invalid final
file is rejected and must be removed before downloading again.

All HTTP uses inherited platform proxies and default CA trust; no TLS disabling
or network-policy bypass. Required model domains are `huggingface.co` and the
actual redirected download host (currently `us.aws.cdn.hf.co`; Hugging Face can
also use `cas-bridge.xethub.hf.co`). The installer uses ordinary HTTPS downloads,
not the Xet client. Any additional denied host must be configured through the
platform's network configuration workflow, never worked around with a mirror.

`runtime.py check` is local-only, prints dependency versions and credential
presence, verifies model files, and exits nonzero if local readiness is missing.
`--load-model` additionally loads the CPU/int8 model with two threads and one
worker, without transcribing. `gpt-models` is a non-inference GET to the existing
relay; it prints only HTTP status and whether `gpt-6-luna` exists. Models response
bodies, credentials, placeholders, headers, and environment dumps are not logged.

## Providers and credentials

Text translation/review uses only `https://text-provider.example.invalid/v1` with `gpt-6-luna` and
Cloud secret `SUBTITLE_GPT_TOKEN`. Official OpenAI text and Claude remain disabled.
The free GET proves models-list connectivity only; it does not prove a paid
Responses request or end-to-end delivery.

Qwen uses `qwen3-asr-flash` with inline Base64 WAV, never a public upload URL.
Default endpoint is the existing Beijing domain
`https://dashscope.aliyuncs.com/compatible-mode/v1`. Configure
`SUBTITLE_QWEN_TOKEN` in Cloud secret management scoped to that domain. To use
an existing `DASHSCOPE_API_KEY`, explicitly set `qwen_credential_env` to that name.
The worker does not search local key files or automatically switch credentials,
regions, or providers. If the supplied key belongs to another region, explicitly
configure the corresponding official endpoint and secret/domain binding before
execution. Workspace endpoints for Beijing and Singapore are also supported.

Protocol source, checked against the page updated October 11, 2026:
https://www.alibabacloud.com/help/zh/model-studio/qwen-asr-api-reference

Requests use `/chat/completions`, `input_audio.data` as a
`data:audio/wav;base64,...` value, `stream=false`, and
`asr_options={language:ja,enable_itn:false}`. The encoded audio is capped at
10 MB. Default chunks are 30 seconds, so a 60-second input needs two requests.
Returned text has no word timestamps: recorded absolute intervals are **source
audio chunk intervals, not word timing or forced alignment**. GPT uses this text
as secondary evidence; final subtitle timing comes from primary Whisper cues.

Both a configured credential and an allowed exact destination domain are checked
before a new Qwen request. Platform status must also show the secret ready. No
real Qwen call occurs during setup.

## Inputs and execution

Privately provide the exact original sample with a valid audio track, at most
60 seconds / 1 GiB. Job state and outputs must stay outside this source checkout.
Source language is Japanese; output is Simplified Chinese plus bilingual files.

Preflight (no ASR or paid API):

```sh
.venv/bin/python worker.py --video /workspace/private-input/sample.mp4
```

After media, website integration and private task configuration are ready, the
fresh-recognition invocation needs neither `--primary` nor `--secondary`:

```sh
.venv/bin/python worker.py \
  --video /workspace/private-input/sample.mp4 \
  --config /workspace/private-input/trial-config.json \
  --work-root /workspace/subtitle-jobs --job-id acceptance-60s --execute
```

The private config is copied from the example, then explicitly sets
`billable_execution_approved=true`, `max_text_requests=20`,
`max_qwen_requests=2` and the approved Qwen region/credential selection. Never
commit it. Execution is currently deferred; this documented command is not a
claim that acceptance has run.

Reuse mode additionally accepts `--primary /private/primary.json`,
`--primary-source-sha256 SHA256_OF_EXACT_VIDEO`, and
`--secondary /private/secondary.json`. Both cue JSON files are arrays of unique
integer `id`, numeric `start`/`end` in seconds, and nonempty `text`. Reusing only
one recognition source is also supported. Provenance records distinguish reuse
from newly executed recognition.

## Request accounting and recovery

The stable scope is `trial-60s-20261021`. The shared cumulative allowance is stored
outside Git at `/workspace/subtitle-trial-state/trial-60s-20261021.json`, regardless
of job ID or work-root. Never delete/reset it to obtain another allowance. Preserve
the same source-video SHA256 throughout the trial; switching to another source is
rejected. Preserve
it with private checkpoints if the Cloud filesystem is replaced. Setup does not
create a billable reservation. Offline tests isolate their mock ledgers in temp
directories and do not spend this allowance.

Processes serialize each job; reservations also have a shared filesystem lock.
Request-state checkpoints are durable before network submission. Any attempt,
including rejection or an ambiguous timeout, consumes allowance conservatively.
Responses and provider-reported usage are saved privately, without claiming that
provider billing has been reconciled. Existing responses/checkpoints are reused.
A missing response after a request marker stops execution: reconcile with the
provider before further action; no automatic retry or alternate provider.

Text is translated and reviewed in batches of 20 cues (two requests per batch).
The code checks that the configured allowance can cover all batches. Interrupted
jobs can resume with identical media/config/reference hashes and the same job ID;
changed inputs or settings require review rather than checkpoint reuse.

## Delivery and verification boundaries

Outputs: Chinese and bilingual ASS/SRT, cues, quality checks, recognition
provenance (including model revision/checksums), usage checkpoints and manifest.
Quality flags do not mean human listening or semantic accuracy has been verified.
Final approval remains with members; keep AI submissions distinct from human work.

Standalone `worker.py` ends at `ready_for_upload_not_uploaded`. The new
`platform_worker.py` adapter handles website claim, private input, heartbeats,
stop and nine-file publish. The main task reports migration 021 deployed and
database-tested; this Cloud task has not yet called it. See
[PLATFORM_WORKER.md](PLATFORM_WORKER.md) for commands and recovery rules.
No website code is changed here. Live integration remains unverified.

The main task supplied the following integration contract: `POST
https://example-env.api.tcloudbasegateway.com/v1/rdb/rest/rpc/st_cloud_worker_call`.
Use the Cloud variable `SUBTITLE_PLATFORM_TOKEN` as JSON `p_key` (no business
account). RPC Authorization uses only the dedicated anon Publishable Key in
`SUBTITLE_PLATFORM_GATEWAY_KEY`; source downloads never use it. Use
`p_action=claim`, optional UUID `p_job`, and `p_payload={}`. Claim returns
`job_id`, `lease_id`, file metadata and full SHA256, same-domain private source
URLs (valid about 23 hours), and job-specific request/duration limits. Download
only from that exact CloudBase domain and verify complete file SHA256. Subsequent
`heartbeat`, `stop`, and `publish` require `p_job` and `p_payload.lease_id`.
The local trial ceilings still apply even if the server returns higher limits.
The connector is implemented and offline-tested. No endpoint calls have been
made by this Cloud task; wait for refreshed credentials and input readiness.

Tests use synthetic local audio and mocked providers. They verify structure,
budgeting, inline protocol, refusal to resend unknown/rejected requests, and
checkpoint reuse. They are not real ASR acceptance or subtitle delivery.

Never commit media, transcripts, subtitles, model files, credentials, private task
configs, usage ledgers, or job checkpoints.

