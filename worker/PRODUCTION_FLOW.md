> Current semiautomatic workflow and deployment provenance: [RELEASE.md](RELEASE.md). Any earlier automated-launch proposal below remains inactive.

# Authorized per-video subtitle workflow

Use the prepared Python runtime and exact website job UUID. A source video must
be at most 1200 seconds and 1 GiB. Text requests <=400 and Qwen requests <=40,
also bounded by the server's lower per-job limits. CPU/int8, two threads, one
worker. Existing GPT text route and Qwen recognition route only.

Default execution performs local configuration checks and claims nothing:

```
.venv/bin/python platform_worker.py --work-root /workspace/subtitle-platform-production
```

Only after the user explicitly authorizes a specific website job:

```
.venv/bin/python platform_worker.py --job-id EXACT_WEBSITE_JOB_UUID --work-root /workspace/subtitle-platform-production --execute
```

The claim must be received from the fixed CloudBase endpoint. New jobs use
`per-job-v1` and `job-<UUID>`; never supply a client-invented scope, a transcript
from another video, or a reused old trial ledger. Source SHA must match.

Each provider request requires a valid live lease and an atomic server quota
reservation. Changing runtime directories/VMs does not restore server allowance.
Failed and ambiguous reservations are not refunded. Do not change scopes, caps,
deadlines, quotas or ledgers to resume. Never automatically resend a model
request with unknown outcome; retain checkpoints and report reconciliation needed.

The website receives nine private ASS/SRT/JSON files after normal publication.
Human listening/review is still required. AI output creates no human points or
contribution entries. Do not approve or award points on behalf of the user.

Do not start another queued job implicitly, create background workers, change
permissions, copy credentials, print source URLs or print subtitle content.
Existing worker expiry and total job allowance remain unchanged.

Website-to-Cloud automatic dispatch is disabled pending compatibility checks
and separate approval for hosting/authentication. Do not use the Agents API or
an undocumented browser API as a substitute. Do not run paid provider calls for
environment preparation or offline tests.

