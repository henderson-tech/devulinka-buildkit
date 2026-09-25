# devulinka-buildkit

Reusable GitHub Actions workflows and composite actions for projects that build
on **Devulinka**, the self-hosted CI box behind the FixIt / lovinka products.
Consumers get a shared persistent BuildKit daemon (so base layers are cached
once for every project, with no `cache-from`/`cache-to` choreography), warm Bun
installs from a shared runner volume, and — the part GitHub cannot give you — a
**host-global admission queue** that caps how much work runs on the box at once,
across repos owned by different accounts.

This repo is **public on purpose**: a cross-owner `uses:` reference requires a
public workflow repo. It contains no secrets and never will — every credential
lives in the consuming repo's own Actions secrets.

## Quickstart (consuming the kit)

Nothing to install. Pin the moving major tag `@v1` and call a workflow. Jobs
must land on a Devulinka self-hosted runner — see [Runner requirements](#runner-requirements).

**Build and push an image**, queued on the host's `build` slots:

```yaml
jobs:
  build:
    permissions:
      contents: read
      packages: write
    uses: henderson-tech/devulinka-buildkit/.github/workflows/build-image.yml@v1
    with:
      runs-on: '["self-hosted","deployik-ci"]'   # your repo's runner labels
      image: ghcr.io/<owner>/<name>              # no tag; defaults to latest + short SHA
      dockerfile: docker/Dockerfile
      priority: true          # deploy-critical builds only
      size-limit-mb: 1536     # optional: fail if the pushed image is bigger
```

Other inputs: `context` (default `.`), `ref`, `tags` (newline-separated),
`build-args` (newline-separated `KEY=VALUE`), `push` (default true), `builder`,
`lock-timeout` (default 2700s). It outputs `image-ref` — the first
fully-qualified image ref, which is computed (and populated) even with
`push: false`; it has actually been pushed only when `push` is true.
Registry login defaults to `github.actor` + `github.token`; pass the optional
`registry-username` / `registry-password` secrets when the target GHCR package
does not grant the calling repo's token write access.

**Bun test lane:**

```yaml
jobs:
  test:
    uses: henderson-tech/devulinka-buildkit/.github/workflows/test-bun.yml@v1
    with:
      runs-on: '["self-hosted","deployik-ci"]'
      working-directory: web
      bun-version: '1.3.9'    # keep in sync with your packageManager field
      clean: false            # keep node_modules / .next/cache / *.tsbuildinfo warm
                              # (branch/tag jobs only — PR jobs ALWAYS clean, the
                              # input is deliberately ignored there for isolation)
      run: |
        bunx tsc --noEmit
        bun run test
        bun run build
```

Also takes `ref`, `install` (default true), `frozen-lockfile` (default true) and
`timeout-minutes` (default 30). Note this lane does **not** take a slot — wrap
the expensive part yourself if it deserves one.

**Take a slot around your own steps.** Single command:

```yaml
- uses: henderson-tech/devulinka-buildkit/actions/build-lock@v1
  with:
    class: small
    run: |
      bunx tsc --noEmit
      bun run lint
```

Multi-step phase (compose stack + browser E2E), acquire/release:

```yaml
- uses: henderson-tech/devulinka-buildkit/actions/build-lock-acquire@v1
  with:
    class: e2e
# ... compose up, run the suite ...
- uses: henderson-tech/devulinka-buildkit/actions/build-lock-release@v1
  if: always()
```

`actions/attach-builder@v1` attaches a job to the shared BuildKit daemon when
you need custom build steps instead of `build-image.yml`.

## The admission queue

Slot classes live in **`classes.conf`** at the repo root — one line per class,
`name|slots|priority_slots|pressure_gate`. That file is the only place host
capacity is defined; `scripts/bk-lock.sh` reads it at job time.

| Class | Priority slot | Pressure-gated | For |
|-------|---------------|----------------|-----|
| `build` | yes | yes | heavy image builds |
| `small` | — | no | cheap checks: typecheck, lint, quick tests |
| `e2e` | — | yes | full compose stacks + browser suites |

Slot names and counts live ONLY in `classes.conf` — read it for the current
capacity; this table describes semantics, not numbers.

- A `--priority` request tries the general slots first and falls back to the
  reserved one, so a deploy-critical build is never queued behind more than one
  running build. A class with no reserved slot gains no extra capacity from the
  flag — but for pressure-gated classes (build, e2e) `--priority` still
  bypasses the pressure gate; only the ungated `small` ignores it entirely.
- Pressure-gated classes additionally postpone admission (within their timeout)
  while the host is loaded: 1-minute loadavg ≥ `BK_LOAD_MAX` (default 85% of
  `nproc`) or `MemAvailable` < `BK_MEM_MIN_GB` (default 12 GiB). `--priority`
  bypasses the gate. `/proc/loadavg` and `/proc/meminfo` are not namespaced, so
  a runner container reads the *host's* numbers — which is the point.
- Locks are plain `flock(2)` files at `/var/lock/devulinka/build-<slot>.lock`.
  Every Devulinka runner bind-mounts the host `/var/lock`, so the same inodes
  are contended across all repos and owners. The fd is held for exactly the
  lifetime of the wrapped process and the kernel drops it on any exit — clean,
  killed or OOM — so there is no stale-lock cleanup.
- Waiting past `--timeout` exits **75**. Queue events (`wait`, `defer`,
  `acquire`, `release`, `timeout`) are appended as JSONL to
  `/var/lock/devulinka/events.jsonl`, best-effort — telemetry never fails a build.

## Runner size tiers

Independently of the queue, each runner container carries a size label
`devulinka-<N>vcpu-ubuntu-2604`, enforced on the container as a soft CPU weight
(`cpu_shares: N*1024` — bursts on an idle host, yields under contention) plus a
hard memory cap on a 1:2 ladder: 2 vCPU/4 GB for lint and typecheck, 4/8 for
unit suites, 8/16 for browser E2E, 16/32 for image builds. Lane labels keep
their warm workdirs, so a workflow can target its lane label for cache affinity
or a size label alone. Sizes bound one container; slot classes bound the host.

Tier definitions live in the private infra repo
(`lovinka-devops-infra/apps/gh-runner/docker-compose.yml`).

## Deploying (v2)

v2 adds the deploy lane: **no SSH keys in GitHub, ever.** A deploy job runs
on your repo's bastion runner and talks to the deploy-gateway on the host,
which knows which repo you are (from the runner's guest lease — not from
anything the job claims), checks whether that repo may deploy the requested
target, and runs the verb over SSH with a host-held key against the target
server's forced-command dispatcher. Targets are logical names (`fixit-prod`,
`eve-prod`) — where they point is estate configuration, not workflow text.

```yaml
jobs:
  deploy:
    uses: henderson-tech/devulinka-buildkit/.github/workflows/deploy.yml@v2
    secrets: inherit
    with:
      runs-on: '["self-hosted","fixit-bastion"]'
      target: fixit-dev
      environment: development   # binds GitHub environment protection + scoped secrets
      prepare: |
        bash scripts/deploy/render-env.sh dev-api > /tmp/payloads/env.development
      plan: |
        env-put development @/tmp/payloads/env.development
        pull 111
        migrate
        roll-api
```

**Failure semantics** (read before wiring `migrate`-class verbs): a step
exits with the *remote* verb's exit code — non-zero aborts the plan. Exit
**70** means the gateway's nonce-authenticated status line never arrived:
the deploy state is **UNKNOWN** (the verb may have half-run on the target).
Never blindly retry an unknown-state step — inspect the target first
(`version`/`probe` verbs, container state), then decide. The status line is
authenticated with a per-request nonce, so dispatcher output cannot forge a
verdict. Tests: `scripts/test-deployctl.sh`.

A gateway **HTTP 429** (target busy or gateway at capacity) is refused before
anything runs, so `deployctl` retries it by itself: 5 s doubling to 60 s, within
`DEPLOYCTL_RETRY_BUDGET_SECONDS` (default 600). Past the budget it exits **75**
(nothing ran; safe to re-run).

**OIDC.** A deploy job granted `permissions: id-token: write` sends its GitHub
Actions OIDC token (audience `deploy-gateway`) on every request. A target
whose gateway policy binds claims (environment, ref, workflow) verifies it:
observe mode only audits it, enforce mode refuses a job without a matching
token. Without the permission no token is sent.

Registry credentials never touch a workflow: put this run's job token in
`GHCR_TOKEN` (`${{ secrets.GITHUB_TOKEN }}`, `packages: read`) and any verb
that makes the host pull (`pull`, `deploy`) authenticates first by itself —
`deployctl <target> registry-login [actor]` is the explicit form (actor
defaults to `GITHUB_ACTOR`; an `@token-file` is still accepted). The token
passes through a 0600 temp file deployctl owns and removes. Dispatchers whose
`deploy` verb takes the token as its payload (Voke, Deployik) get the same
hygiene from `@env:GHCR_TOKEN` — `deploy-step`'s `payload-env` input.

À la carte: `actions/deploy-step@v2` (single verb) or
`scripts/deployctl.sh` directly. Every non-loopback request uses TLS with the
gateway's public-key hash pinned in `scripts/deploy-gateway-curl.sh`; cleartext
is accepted only for loopback test stubs. `scripts/deploy-whoami.sh` shares the
same transport contract, so identity probes cannot silently downgrade.
Decision log:
`docs/specs/2026-08-14-buildkit-v2-security-decisions.md`. Server side:
`lovinka-devops-infra/apps/deploy-gateway/` (gateway) +
`lovinka-infra/scripts/lovinka-ssh/` (dispatcher framework).

## Runner requirements

- A Devulinka self-hosted runner: DooD (host `/var/run/docker.sock` mounted) and
  `/var/lock` bind-mounted read-write.
- The shared builder must exist on the host — created idempotently by
  `lovinka-devops-infra/scripts/create-devulinka-builder.sh`. `attach-builder`
  only re-creates the client-side handle (buildx metadata does not survive a
  runner restart); the daemon container and its cache live on the host.
- Linux only: `bk-lock.sh` needs `flock(1)` and exits 2 with a clear message
  anywhere else.

## Repository map

| Path | What |
|---|---|
| `.github/workflows/build-image.yml` | reusable image build (login → attach builder → locked `buildx build` → optional size guard) |
| `.github/workflows/test-bun.yml` | reusable Bun install + run lane |
| `.github/workflows/deploy.yml` | reusable v2 deploy lane — prepare + plan of verbs through the host deploy-gateway (no SSH keys in GitHub) |
| `.github/workflows/ci.yml` | this repo's own checks |
| `.github/workflows/external-watchdog.yml` | this repo's own cron job, not part of the kit — a GitHub-hosted dead-man's switch that probes the fleet from outside and pages via Telegram. Must stay on `ubuntu-latest`: a self-hosted runner would die with the box it watches. |
| `actions/build-lock/` | run one command holding a slot |
| `actions/build-lock-acquire/`, `actions/build-lock-release/` | hold a slot across steps (background holder, 6 h failsafe) |
| `actions/attach-builder/` | attach the job to the shared BuildKit daemon |
| `actions/deploy-step/` | single deploy verb through the gateway (à la carte v2) |
| `scripts/bk-lock.sh` | the semaphore itself — everything above is a wrapper |
| `scripts/deployctl.sh`, `scripts/test-deployctl.sh` | the deploy-gateway client and its test suite |
| `classes.conf` | slot capacity, the single source of truth |
| `blueprint/new-project.sh` | onboarding generator (below) |

## Development

There is no build and no dependency install here — the repo is YAML plus a
handful of Bash scripts (`scripts/bk-lock.sh`, `scripts/deployctl.sh` with
`scripts/test-deployctl.sh` as its test suite, `blueprint/new-project.sh`).
Everything else is validated by the consumers that call it, so keep changes
small and watch the first consuming run.

**Changing capacity or adding a class:** edit `classes.conf`, merge, then move
the major tag:

```bash
git tag -f v1 && git push -f origin v1
```

Consumers pick it up on their next job — the action checkout ships the file. No
host deploy, no runner restart. Note that `bk-lock.sh` carries a `BUILTIN_CLASSES`
fallback for the case where `classes.conf` is unreadable; re-sync it when you
change capacity.

**Onboarding a new project:**

```bash
blueprint/new-project.sh <owner>/<repo> <shortname> [--go] [--priority]
```

Prints three blocks to stdout: the runner service for the private infra repo's
`gh-runner` compose (GitHub App auth, no PAT), a starter `ci.yml` wired to this
kit, and the manual steps that remain (install the runner GitHub App on the
repo, deploy the runner stack). Review the generated `ci.yml` before committing
it — in particular, decide deliberately whether its `pull_request` lanes should
run on the shared self-hosted box for a public repo.

**Versioning:** consumers pin `@v1`, a moving major tag. Breaking changes bump
to `@v2`; everything else moves `v1`.

## Repository etiquette

- `main` is protected by a ruleset: pull requests only, no force-push, no
  deletion, one approving review **from the code owner** (`.github/CODEOWNERS`),
  and stale reviews are dismissed on push. Merge, squash and rebase are all
  allowed.
- Branch naming follows `work/<slug>` (e.g. `work/ci-speed`). (Some older
  branches used `feat/<slug>`; new work sticks to `work/`.)
- Conventional Commits, scoped to the piece you touched: `feat(classes):`,
  `feat(bk-lock):`, `docs+blueprint:`.
- This is public and consumed cross-owner. Never add a secret, an internal
  hostname, or a private mesh address; keep credentials in the consuming repo.
