# CLAUDE.md

@README.md

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
- **Capacity lives in `classes.conf` only.** Editing slot counts anywhere else
  is a bug. `scripts/bk-lock.sh` also carries a `BUILTIN_CLASSES` fallback for
  an unreadable config — keep it in sync when you change capacity.
- Every consuming job runs on a self-hosted host with DooD (host docker.sock)
  and a shared `/var/lock`. Treat anything that lands in a `run:` block as
  running as host root: pass workflow inputs through `env:` and quote them,
  rather than interpolating `${{ }}` into shell.
- Locks are only ever released by the process exiting — never add stale-lock
  cleanup, and never let a wrapper outlive the work it guards.
- `main` is ruleset-protected: PR + owner review, no direct push, no force-push.
  Branch as `work/<slug>`, Conventional Commits scoped to the component
  (`feat(bk-lock):`, `feat(classes):`).

## Verifying a change

There is no dependency install and no lint here. Local checks: `bash -n` /
`shellcheck` on the shell scripts, plus `scripts/test-deployctl.sh` — the
deploy-lane test suite — and `scripts/test-bk-lock.sh` (the pressure gate;
Linux only), both of which `.github/workflows/ci.yml` also runs. Anything
deeper requires an actual consumer job on a Devulinka runner. Do not invent a `bun`/`npm` command for this repo — it has no
package manifest.
