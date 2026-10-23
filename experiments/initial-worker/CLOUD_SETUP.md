# Subtitle worker in Codex Cloud

This private repository contains portable workflow scripts, not a running service.
The execution target is Codex's built-in Cloud. Tencent Cloud hosts the existing
website and private artifacts, not subtitle-processing compute.

## Prepare the environment

- Python 3.11 or newer; `ffmpeg` and `ffprobe` on PATH.
- `python -m unittest -v test_worker.py` performs offline checks only. Mock
  translations in tests must never be reported as a real subtitle delivery.
- For the authorized ten-minute trial, real historical primary and secondary
  recognition results will be supplied with the source video. The worker's
  `--primary` option reuses primary recognition, bound to the video SHA256.
- A fresh Whisper run additionally needs faster-whisper and a real model directory;
  do not download large models or infer GPU availability during environment setup.
- A setup report must distinguish installed dependencies, tests actually run,
  missing inputs, missing credentials, and unimplemented website endpoints.

## External services

Translation and text review use the user's existing GPT Responses relay only.
Claude and official OpenAI text API usage remain disabled. `SUBTITLE_GPT_TOKEN`
must come from Cloud secret management; never write it into source or prompts.
The HTTP client uses urllib's default proxy discovery and configured CA trust;
credential-bearing redirects are refused. It has not yet been verified with
Cloud's managed proxy and network-secret replacement. Do not claim end-to-end
network compatibility before testing it in the real Cloud environment.

No billable request during environment setup. Once inputs and approved task
configuration are present, reconcile any request with an unknown result before
retrying. Keep checkpoints and actual usage records.

## Delivery status

The worker exports ASS/SRT, cue JSON, checks, recognition provenance and a file
manifest. Its final state is `ready_for_upload_not_uploaded`, not website delivery.
Website queue/claim/publish endpoints and scoped worker identity are still pending.
Keep AI submissions distinct from human work and leave final approval to members.

Never commit source videos, transcripts, generated subtitles, credentials or job
checkpoints to this repository. Transfer trial inputs privately to the actual
Cloud task after the environment is ready.

