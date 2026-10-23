> 归档资料：仅记录研发过程，不是当前部署指南，也不授予付费或权限操作授权。当前入口见 [从零搭建](../../docs/从零搭建.md)。

> **历史记录**：本文件包含早期试验或云端剪辑设置。现行半自动字幕流程、发布来源与统一测试入口以 [RELEASE.md](RELEASE.md) 为准；不要按旧额度或环境名新建/重配环境。

# Cloud setup observation — 2026-10-21 (Asia/Shanghai)

This is a point-in-time preparation report, not a successful ASR acceptance.
No billable provider requests or real-media recognition were executed.

## Installed and verified

- Python 3.12.14, ffmpeg/ffprobe 7.1.5.
- `.venv`: faster-whisper 1.2.1, CTranslate2 4.8.3, PyAV 19.0.1,
  ONNX Runtime 1.31.0. Full installed versions are pinned in `requirements.lock`.
- Importing faster-whisper succeeds; CTranslate2 reports CPU int8 support.
- Container cgroup: 8 GiB memory ceiling and 2 CPU quota. About 29 GiB disk
  remains after dependency installation. GPU availability was not assumed.
- Existing GPT relay GET `/v1/models`: HTTP 200; `gpt-6-luna` listed.
  Response body was not persisted. This was not a Responses inference request.
- `SUBTITLE_GPT_TOKEN`: present, platform readiness observed as ready.
- 48 offline tests pass, using synthetic audio and mocked provider results only.
  `pip check`, shell syntax and Git whitespace checks also pass.

## Blockers observed

- The earlier root-directory permission blocker is resolved by selecting
  `/workspace/subtitle-models/large-v3-turbo`. Directory creation and a temporary
  write check succeeded with the existing worker account. The ignored `.venv`
  and model directory are both on the Cloud filesystem; no PC process is used.
- Restricted platform network policy currently includes `text-provider.example.invalid` but not
  `huggingface.co`, model CDN destinations, or `dashscope.aliyuncs.com`.
  A normal HTTPS Hugging Face metadata request failed with `URLError`.
  No alternate mirror, proxy bypass, or disabled certificate verification was used.
- `SUBTITLE_QWEN_TOKEN`: absent. `DASHSCOPE_API_KEY`: absent.
- Real 60-second source media, refreshed environment credentials and live website
  integration are still pending. The main task reports migration 021 deployed
  and database-tested; this task has not called the endpoint.

## Model installation status

**Not downloaded and not load-tested.** No actual model size or model ASR
performance is claimed. The target directory is writable. The reproducible installer awaits approved
network configuration from the main task. Selected real model:

- Repository: `dropbox-dash/faster-whisper-large-v3-turbo` (renamed upstream).
- Revision: `0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf`.
- Upstream advertised size: approximately 1.62 GB; download reservation: 1.8 GB.
- Target: `/workspace/subtitle-models/large-v3-turbo`.
- Runtime: CPU/int8, two threads, one worker; keep at least 1 GiB free.

## Platform configuration to apply

1. The writable model directory has been created at
   `/workspace/subtitle-models/large-v3-turbo`; no root permissions are needed.
2. Allow `huggingface.co`, its actual redirected download destination
   (`us.aws.cdn.hf.co` observed in upstream links; potentially
   `cas-bridge.xethub.hf.co`), and `dashscope.aliyuncs.com`.
3. Configure `SUBTITLE_QWEN_TOKEN` in Cloud secret management, scoped to the
   Beijing endpoint `dashscope.aliyuncs.com`. If the supplied key is for another
   region, explicitly adjust the endpoint and secret binding rather than retrying
   other providers. Do not put the key in chat, code or a committed config.
4. Run `./setup_runtime.sh`, then the local model check and free GPT models check.
5. Wait for actual media and refreshed runtime configuration before enabling the
   private acceptance config. Source defaults remain disabled, with zero requests.

## Queue adapter added

`platform_worker.py` now provides private same-domain input download with size
and SHA256 checks, 40-second heartbeats plus mandatory heartbeats before every
new billable reservation, sanitized stop reports, and nine-file private publish.
Publish payloads and ambiguous results survive restart; same-lease idempotent
reconciliation takes precedence over recognition/model work. The shared global
trial allowance remains in force. See `PLATFORM_WORKER.md` for invocation details.
RPC gateway auth uses a separate `SUBTITLE_PLATFORM_GATEWAY_KEY` anon Publishable
Key; the task capability stays in `SUBTITLE_PLATFORM_TOKEN`. Source GETs carry
neither credential. Gateway and source isolation are covered by offline tests.
All adapter validation so far uses mocked HTTP; it is not real acceptance.

The main task supplied the exact migration 021 JSONB response contract. The
adapter now handles direct response objects, normal `no_job`, heartbeat
`state:running/lease_seconds:2700` (without `ok`), matching stop state, and
publish `state:succeeded/delivery_id` with optional repeat-review flag. Server
source expiration takes precedence over the local 23-hour ceiling. HTTP 400/401
errors block fees without matching Chinese reason text. Contract regression
tests cover these cases. Future missing runtime configuration or contract
questions are recorded here for the main task, not delegated to the user.

The available environment-management tool in this chat is status-only. These
platform policy/secret changes cannot be applied by editing repository files. No local-PC keys or Codex secret files were read.

