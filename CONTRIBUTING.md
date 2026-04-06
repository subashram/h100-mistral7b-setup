# Contributing

Thanks for contributing.

## Scope

This repository is focused on production-oriented inference for `Mistral 7B` on a dedicated `8x H100` node, with emphasis on:

- serving topology
- deployment automation
- monitoring and operations
- benchmarking and tuning
- safe, reviewable infrastructure changes

## Before Opening A Change

- keep changes small and reviewable
- prefer configuration and script changes over undocumented manual steps
- update `README.md` when behavior or operator workflows change
- add or update scripts when a repeated operational task can be automated

## Local Checks

Before opening a PR, run the checks that apply to your change:

```bash
bash -n scripts/deploy.sh
bash -n scripts/smoke-test.sh
bash -n scripts/benchmark.sh
bash -n scripts/host-prereqs.sh
docker compose --env-file .env.example config >/dev/null
```

If your change affects deployment behavior, also note:

- expected rollout impact
- rollback path
- any new environment variables
- any monitoring or alerting updates

## Commit Guidance

- use clear commit messages
- keep one logical change per commit when practical
- avoid bundling unrelated refactors with deployment-critical fixes

## Documentation

Changes that affect operators should update documentation in one of:

- `README.md`
- future `docs/` content for architecture, deployment, operations, or benchmarking

## Security

- do not commit real API keys, private certs, secrets, or production `.env` files
- use placeholders in examples
- report security concerns through the process in `SECURITY.md`
