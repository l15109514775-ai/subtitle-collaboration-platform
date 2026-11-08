# Subtitle API worker

Current workflow: member video request → owner approval → API worker claims the exact job with its worker token → automatic private subtitle delivery.

The worker is provider-agnostic: it uses the site's job-claim RPC and the configured model/ASR API credentials. It no longer depends on Codex Cloud or a Codex environment.

See [current task operations and recovery](OPERATIONS.md), [release history](RELEASE.md), [production flow](PRODUCTION_FLOW.md), and run all Python offline tests with `.venv/bin/python run_offline_tests.py`.
