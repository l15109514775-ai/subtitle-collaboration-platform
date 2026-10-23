> 归档资料：仅记录研发过程，不是当前部署指南，也不授予付费或权限操作授权。当前入口见 [从零搭建](../../docs/从零搭建.md)。

> **历史记录**：本文件包含早期试验或云端剪辑设置。现行半自动字幕流程、发布来源与统一测试入口以 [RELEASE.md](RELEASE.md) 为准；不要按旧额度或环境名新建/重配环境。

# 20-minute subtitle acceptance environment

Status: source prepared; a new native Codex Cloud environment must still be
created, published and tested. A GitHub branch is not a provisioned environment.

Use branch `cloud/subtitle-20min` in the private `subtitle-cloud-worker`
repository. Suggested environment name: `subtitle-delivery-20min`.

## Exact limits

- Source media: 1 to 1200 seconds, at most 1 GiB. This is media duration, not
  a 20-minute wall-clock timeout for CPU recognition.
- Cumulative ceiling for this acceptance: 400 GPT text requests and 40 Qwen
  requests. These are ceilings, not target consumption. With the unchanged
  30-second Qwen chunks, 1200 seconds needs 40 requests.
- Scope `trial-20min-20261021` is independent from the old 60-second scope and
  stays bound to one source SHA256. Do not reset counters or transfer the old
  ledger into this scope. Failures and unknown outcomes retain reservations.
- Per-job limits from the website further reduce these ceilings. A fresh
  valid lease heartbeat is required before each new request reservation.
- Keep CPU/int8, two threads, one worker; pinned Whisper model and dependencies.
- `config.example.json` remains disabled with zero request allowances. Only a
  scoped platform claim enables execution. Never spend requests just to use quota.

## Provision without exposing credentials

Use the existing native Codex Cloud setup and the same restricted recipients,
network-secret host bindings and platform capability. Prefer a supported clone
that preserves secrets. If a clone does not preserve secrets, the user must enter
them in the secure environment form. Never recover secrets from browser state,
display them, commit them, or copy a local credential directory.

Keep the GPT relay text route and Qwen ASR route already approved by the user.
Do not switch text processing to an official OpenAI API key. Do not add public
storage, public media links, Tencent compute, a broad service role or GPU.
Preserve existing expiration, project restrictions and claim quota of the worker.

Setup: `./setup_runtime.sh`. Publish the environment after setup. Start a new
native Codex Cloud task from this branch; do not rely on an old task snapshot.

## Validation before removing old environments

1. Run the existing offline tests plus `python -m unittest -v test_20min` in
   Linux. Windows local checks do not prove Linux fsync/flock or model loading.
2. Verify pinned model download/hash/load and network-secret bindings without
   issuing billable inference probes.
3. Publish the website assets and migration 033. Confirm no cloud-clipping panel
   mounts, subtitle upload/claim/download remains usable, and server limits match.
4. Use one new authorized website job, freshly prepared 20-minute source and the
   scoped worker. Run `platform_worker.py --job-id <UUID> --work-root
   /workspace/subtitle-platform-20min --execute` once in native Codex Cloud.
5. Verify fresh Whisper and full-length Qwen provenance, translation/review,
   all nine returned files with byte lengths/SHA256, and human-review pending.
   Confirm no human contribution or points were credited. Record actual usage;
   provider usage is not a reconciled currency bill.
6. An offline check, environment publish, or short sample does not count as
   passing the real 20-minute acceptance. If blocked, preserve the old environment.
7. Inventory the exact obsolete native Codex Cloud environment names and delete
   only after acceptance and the required action-time confirmation. Never delete
   CloudBase `subtitledev`, project data, delivered files, API credentials or
   historical usage ledgers as part of environment cleanup.

No website-to-Codex automatic scheduler is introduced by this change. A Cloud
task still needs to be started to claim a website job.

