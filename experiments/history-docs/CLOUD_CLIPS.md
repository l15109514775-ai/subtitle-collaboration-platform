> 归档资料：仅记录研发过程，不是当前部署指南，也不授予付费或权限操作授权。当前入口见 [从零搭建](../../docs/从零搭建.md)。

> **历史记录**：本文件包含早期试验或云端剪辑设置。现行半自动字幕流程、发布来源与统一测试入口以 [RELEASE.md](RELEASE.md) 为准；不要按旧额度或环境名新建/重配环境。

# Independent full-topic Cloud clips

The current target is the complete 浮気判定 discussion from YouTube
PTL-ZkyrSPA, approximately 02:24:33–03:28:41 (3,848 seconds). Those times and
public transcript observations were supplied by the main task; the worker has
not independently obtained the source. Validate the final boundaries in Cloud.

The separately authorized limits are 4,200 seconds of output, 20 shared text
requests (translation AND review), two Qwen requests, and zero paid images.
Qwen covers only explicitly reviewed difficult intervals, at most two 150-second
inline segments; reports must never describe the entire hour as dual recognition.
Whisper covers the whole selected input, with durable 120-second checkpoints.
Never reset or reuse the completed trial-60s-20261021 ledger, old job or old RPC.

## Current evidence and limitations

The original and subsequently refreshed managed environments received YouTube
CONNECT 403. The main task reports current enforced rules including the exact
www.youtube.com host, so this is not established as a missing-domain problem or
a YouTube login response. No workaround, repeated client switching, PC cookies,
DRM/auth bypass or proxy/CA bypass is authorized. The user currently has only
the URL. There is no real source download, verified topic timestamp, translation,
rendered livestream video, cover or publication for this new task.

Main task executed 026/027 in a real CloudBase transaction and reported successful
rollback tests, then installed 026. This worker independently checked SQL and
PL/pgSQL syntax, not production DB execution. The first explicitly authorized
zero-budget storage HTTP fixture failed its first exact-path POST with HTTP 403;
no GET/negative checks or publish followed. Request headers and INSERT metadata
context need verification. Never broaden bucket policy to make the test pass.

## Reproducible dependencies and free stages

Use the existing pinned runtime/model. requirements.clip.lock pins official
PyPI yt-dlp[default]==2026.8.19 and yt-dlp-ejs==0.8.0. The existing official Node
v24.19.0 is selected explicitly. Bundled EJS format-signature parsing is allowed;
remote script/plugin downloads remain disabled. Proxy and CA settings are inherited.

Private state is /workspace/subtitle-clips/NEW_JOB. Probe accepts metadata up to
six hours. prepare retrieves Japanese json3 captions and never downloads the
entire video. Candidate windows are proposals requiring topic and complete-exchange
review; no arbitrary fallback if the topic is missing. The full-topic selection
can exceed five minutes but never the authorized 4,200 seconds.

```sh
.venv/bin/python clip_pipeline.py probe --url https://www.youtube.com/watch?v=PTL-ZkyrSPA --root /workspace/subtitle-clips/NEW_JOB
.venv/bin/python clip_pipeline.py prepare --url https://www.youtube.com/watch?v=PTL-ZkyrSPA --root /workspace/subtitle-clips/NEW_JOB
.venv/bin/python clip_pipeline.py candidates --root /workspace/subtitle-clips/NEW_JOB
# Reviewed absolute range only, not a full livestream video download:
.venv/bin/python clip_pipeline.py capture --url https://www.youtube.com/watch?v=PTL-ZkyrSPA --selection /workspace/subtitle-clips/NEW_JOB/selection-plan.json --root /workspace/subtitle-clips/NEW_JOB
.venv/bin/python clip_pipeline.py scan --root /workspace/subtitle-clips/NEW_JOB --deadline-seconds 14400
```

When captions are unavailable, scan-audio can retrieve bounded audio only (at
most 512 MiB), then scan writes checkpoints and reports completion only after
all audio was covered. A four-hour CPU deadline may be insufficient for a six-hour
source; assess throughput and resume checkpoints, never silently truncate it.
Use the managed outer process timeout as well as per-stage Deadline objects,
particularly for external downloader or model calls.

Selected downloads are at most 720p and 1 GiB. Store full SHA of the complete
selected file and absolute livestream offsets; do not mislabel that hash as the
SHA of the whole four-hour broadcast. selection-plan binds public transcript
hash before download; final selection binds verified selected source SHA and the
chosen full Whisper transcript hash (transcript_kind=whisper). Preserve both
public caption and Whisper provenance. No speech cue may be cut in half.

## Paid and rendering interfaces

ClipBudget requires a NEW website UUID/lease, clip-* scope, verified source SHA,
duration, expiry, exact caps and a live reservation guard. ClipLease performs
synchronous heartbeat and one-time server reserve_request before every local
reservation. A timeout leaves an unknown marker and blocks new reservations.
Counts survive job restarts; rejected and unknown provider calls never auto-resend.

clip_budget.translation_batches plans ALL cues before any provider call: up to
150 cues, bounded source characters and estimated output tokens per batch,
12,000 output tokens per request, no more than ten translate/review batch pairs.
Estimates are not actual usage or guaranteed model output length. If the complete
segment cannot fit 20 requests, stop before spending, report the actual required
batches, and do not translate only the beginning. IDs/order/count/timing remain
validated. Partial/truncated provider results are preserved and not retried.

clip_budget.translate has no auto-executing CLI. Supply the real new job/lease
only after HTTP/RLS contract verification and real source/selection readiness.
Do not invoke the 60-second worker entrypoint. Use explicit Qwen intervals with
review reasons; secondary-coverage.json records exactly which audio was sent.

render exports original.mp4, subtitled.mp4, Chinese/bilingual ASS/SRT, cue,
quality, provenance, usage, selection and manifest reports. H264 maxrate 1,600k
plus AAC 128k bounds a 70-minute output below 1 GiB with a final byte-size check;
actual quality/codec/timing still require inspection. No resolution upscaling is
needed. At least 4 GiB free is required for rendering. Missing video, font,
translation, topic confirmation or title review stops rather than faking a product.
The 1280x720 cover is an actual midpoint frame plus reviewed Chinese title using
system Noto CJK, SIL OFL 1.1. Generated synthetic fixtures are never real deliverables.

## Deployed/new website contract

026_cloud_clips.sql: independent st_cloud_clip_jobs/attempts/media/packages,
leaving st_cloud_jobs and st_cloud_worker_call unchanged. Owner entry:

- st_cloud_clip_create(p_source_url,p_topic,p_max_clip_seconds=4200,p_max_text_requests=20,p_max_qwen_requests=2,p_worker=null)
- st_cloud_clip_board(), st_cloud_clip_files(p_job), st_cloud_clip_cancel(p_job)
- Dedicated worker RPC st_cloud_clip_call(p_key,p_action,p_job,p_payload)
- Actions: claim, heartbeat, record_selection, reserve_request, reserve_media,
  read_part, finish_media, publish, stop.

Exact jobs are assigned to a live existing st_cloud_workers identity. Capability
hashing matches existing key_hash; Authorization uses only the dedicated anon
Publishable Key, never a personal JWT in Cloud. Heartbeats renew a 45-minute lease.
record_selection freezes real source title/duration/SHA, times and evidence and
names the project title|timecodes|AI subtitle draft. Generation tasks are archived
to prevent human claim races, then reopened after AI delivery without human points.

reserve_media covers clean/subtitled/cover, 4 MiB ordered parts, 1 GiB per MP4,
10 MB cover, 256-bit random opaque prefix and short expiry. It is insert-only.
Scoped storage requests require x-cloud-clip-worker, x-cloud-clip-capability and
x-cloud-clip-object; RLS checks exact object, active worker/job/lease and expiry.
No broad anon SELECT/INSERT, UPDATE, DELETE or listing capability is intended.
Actual CloudBase header propagation is NOT established: first POST was 403.

finish_media validates actual storage.objects count/size/mimetype/timestamps,
including empty historical owner_id, but NEVER claims to read bytes. clip_media.py
performs ordered HTTP readback and full SHA, then attests worker_sha_verified;
server_sha_verified stays false. publish requires all three media verified and
exactly ten small reports (original nine plus selection.json), total 2 MB, per
file 500 kB, hashes and no duplicate names. It atomically registers Codex media
artifacts/deliveries and one proofreading version. Same-lease exact-payload
reconciliation cannot create extra versions. No human contributions/points.

## Classic website integration

Load existing app + media/chunked scripts, then cloud-clips.js and
cloud-clips-host.js using classic defer scripts; include cloud-clips.css.
There are no ES exports. Host adapter wraps existing load/logout, prepends to
board-view, uses data.me.owner and existing rpc/request. Loaded tasks open via
openTask/previewMedia; other accessible project media use authorized st_task_detail
and existing chunkedMediaURL. Preview is Range streaming, never a full-hash claim.

The main task maintains its deployed UI fixes, including the required progress
callback for MediaFiles.hash. This branch does not overwrite those files again.
Range preview never claims full-file SHA verification. The standalone cross-project
viewer offers a verified download; the original task-dialog downloader requires
its separately reviewed host patch to add complete-file hashing. A draft is saved
privately in work/unpublished-verified-download-ui.patch, not automatically applied.
Logout aborts transfers, clears panels/viewers and invokes media-channel cleanup.

## Optional uploaded-source fallback (not a solution for this URL-only user)

028_cloud_clip_upload_sources.sql adds waiting_source and private subtitle-inputs
uploads; 029 supplies rollback fixtures. Neither is reported as deployed. An owner
can create_upload, prepare_upload (4 MiB parts/full SHA/duration, full vs topic,
absolute livestream offset), upload and sign using their ordinary website session,
then source_ready after actual storage metadata validation. Only fully staged
sources enter queued. No anon bucket permissions are added. Cloud receives signed
source URLs without a personal JWT; clip_sources.download_upload sends no worker,
gateway or cookies on source GET and validates complete SHA, duration and disk.
Audio-only inputs permit recognition but cannot produce a video without real video.

Keep window.CLOUD_CLIP_UPLOAD_SOURCES false until 028 is deployed and HTTP tested.
The user currently has no existing source file, so do not claim this unblocks them.

## Verification and isolated HTTP test

```sh
.venv/bin/python -m unittest test_worker.py test_cloud.py test_platform_worker.py test_clip_pipeline.py test_clip_media.py
NODE_PATH=/workspace/work/clip-ui-test/node_modules node test_cloud_clips_ui.cjs
```

jsdom 26.1.0 is a test-only official npm dependency in work/. DOM tests exercise
classic loading, real click handlers, canonical dispatch, 4,200s cap, existing task
preview, repeated loads and logout. They are not live-site/browser-video tests.
SQL files parse via test-only pglast 8.7; actual DB execution is owned by main task.

clip_http_fixture.py accepts only an explicitly provided isolated job and checks
both paid caps zero. It creates no jobs, sends no models/YouTube requests, never
publishes or undeletes the fixture project, POST/GET-hashes a tiny PNG, tests
missing worker/wrong cap/cross path/upsert/list isolation, then stop failed.
It limits itself to 12 HTTP requests and a five-minute deadline. Unknown outcomes
are retained, never silently retried. Do not execute it on a production content job.

