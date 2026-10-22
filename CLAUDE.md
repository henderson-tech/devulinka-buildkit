# CLAUDE.md

Reusable GitHub Actions workflows, composite actions and Bash scripts for jobs
on Devulinka self-hosted runners: the host-global admission queue
(`classes.conf` + `scripts/bk-lock.sh`), the shared BuildKit builder, the Bun
test lane and the v2 deploy lane (`scripts/deployctl.sh`). README.md is the
consumer manual (purpose, inputs, outputs, exit codes, runbooks): read it before
changing anything a consumer calls.

## Constraints that are not visible in the code

- **This repo is PUBLIC and consumed cross-owner.** Never add a secret, an
  internal hostname, a WireGuard/mesh address, or an SSH endpoint — not even in
  a comment or an example. Credentials belong in the consuming repo's Actions
  secrets.
- **A merge is not a release.** Consumers pin `@v1`, so nothing you merge
  reaches them until the tag moves: `git tag -f v1 && git push -f origin v1`.
  That force-push is sanctioned for the MAJOR TAG only (the standard moving-tag
  release for actions) — never for branches — and only from a green `main`.
  Say so when you finish a change; do not move the tag without being asked.
- README.md, verbatim: "**Versioning:** consumers pin `@v1`, a moving major
  tag. Breaking changes bump to `@v2`; everything else moves `v1`."
- **Capacity lives in `classes.conf` only.** Slot names and counts live ONLY
  there; editing them anywhere else is a bug (README describes semantics, not
  numbers). `scripts/bk-lock.sh` also carries a `BUILTIN_CLASSES` fallback for
  an unreadable config — keep it in sync when you change capacity.
- Every consuming job runs on a self-hosted host with DooD (host docker.sock)
  and a shared `/var/lock`. Treat anything that lands in a `run:` block as
  running as host root: pass workflow inputs through `env:` and quote them,
  rather than interpolating `${{ }}` into shell.
- Locks are only ever released by the process exiting — never add stale-lock
  cleanup, and never let a wrapper outlive the work it guards.
- `main` is ruleset-protected: PR + owner review, no direct push, no force-push.
  The ruleset also forbids deleting `main`, requires one approving review from
  the code owner (`.github/CODEOWNERS`) and dismisses stale reviews on push.
  Repo settings allow only merge commits (squash and rebase are disabled).
  Branch as `work/<slug>`, Conventional Commits scoped to the component
  (`feat(bk-lock):`, `feat(classes):`).

## Consumer contracts to keep (detail in README.md)

- Admission: `priority: true` / `--priority` is for deploy-critical builds
  only. Waiting past `--timeout` exits 75; queue telemetry is best-effort and
  never fails a build. The Bun lane takes no slot: consumers wrap the expensive
  part themselves. The pressure gate reads the host's `/proc/loadavg` and
  `/proc/meminfo` on purpose (they are not namespaced).
- `test-bun.yml`: `clean: false` applies to branch/tag jobs only; PR jobs ALWAYS
  clean (the input is deliberately ignored there for isolation). `bun-version`
  is kept in sync with the consuming repo's `packageManager` field.
- Deploy lane: no SSH keys in GitHub, ever. Repo identity comes from the
  runner's guest lease, not from anything the job claims; targets are logical
  names, and where they point is estate configuration, not workflow text.
- Deploy exit 70 = state UNKNOWN: never blindly retry an unknown-state step,
  inspect the target first. The status line is authenticated with a
  per-request nonce, so dispatcher output cannot forge a verdict. A gateway
  HTTP 429 is refused before anything runs; `deployctl` retries it within
  `DEPLOYCTL_RETRY_BUDGET_SECONDS`, then exits 75 (nothing ran; safe to re-run).
- The reusable `deploy.yml` does not request `id-token: write` yet: a called
  workflow asking for a permission its caller did not grant fails to start, so
  it opts in together with its callers.
- A workflow never stages the registry token: `deployctl` owns the 0600 temp
  file and removes it (`GHCR_TOKEN` in the env, or `@env:GHCR_TOKEN` via
  `deploy-step`'s `payload-env`).
- Every non-loopback gateway request uses TLS with the public-key hash pinned in
  `scripts/deploy-gateway-curl.sh`; cleartext only for loopback test stubs.
  `scripts/deploy-whoami.sh` shares that transport, so identity probes cannot
  silently downgrade.
- `.github/workflows/external-watchdog.yml` is this repo's own cron, not part
  of the kit, and must stay on `ubuntu-latest`: a self-hosted runner would die
  with the box it watches.
- `blueprint/new-project.sh`: the runner lane is an entry in the private infra
  repo's `etc/ci-lanes/manifest.json`, rendered by its `scripts/gen-ci-lanes.py`
  (never hand-edit the compose); runner auth is the GitHub App, no PAT. Review
  the generated `ci.yml` before committing it, and decide deliberately whether
  its `pull_request` lanes should run on the shared self-hosted box for a
  public repo.

## Verifying a change

There is no dependency install and no package-manager lint target here. Local
checks: `bash -n` / `shellcheck` on the shell scripts, plus
`scripts/test-deployctl.sh` — the deploy-lane test suite — and
`scripts/test-bk-lock.sh` (the pressure gate; Linux only), both of which
`.github/workflows/ci.yml` also runs. That job skips fork PRs (push the branch
here to test) and PRs labelled `skip-ci`; a skipped job is not a pass. Anything
deeper requires an actual consumer job on a Devulinka runner: keep changes small
and watch the first consuming run. Do not invent a `bun`/`npm` command for this
repo — it has no package manifest.
