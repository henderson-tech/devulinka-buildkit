# Buildkit v2 — CI/CD Security Reorganization — Decisions [!date](2026-08-14)

Board: https://vitrinka.in/w/fixit/boards/devulinka-buildkit-brainstorm-v2-security

## Summary

Buildkit v2 reorganizes CI/CD deploy security across the 3-server estate
(**Devulinka** = dev/CI, plus a production server and a websites server,
post-rebuild). Deploy SSH keys leave GitHub entirely; workflows declare a
logical deploy **target** (e.g. `eve-prod`) instead of hardcoding hosts/relays;
a root-owned **deploy gateway** on Devulinka is the single audited chokepoint
that holds keys, resolves targets, and enforces which repo may deploy where.
FixIt is the pilot (deploy-dev first, deploy-production last).

Trigger: the Reservine incident (personal SSH key with unrestricted root in CI),
the 2026-08-09 GHA secret-exfil incident, and the 2026-08-14 finding that FixIt
prod deploys still point at the retired standby box.

## Decisions

:::table
| # | Decision | Call | Why |
|---|----------|------|-----|
| D1 | Deploy-control architecture | [!status green](Deploy Gateway) [#E12](board) | Root-owned broker on the Devulinka host holds ALL deploy keys + policy; CI jobs request `deploy <target> <verb>` over a local endpoint and can never read a key; one audit log. |
| D2 | Target registry location | [!status green](Host-side on Devulinka) | `targets.yml` in the private infra repo, deployed to the host. Workflows pass only a NAME — a malicious PR cannot redirect a deploy; public buildkit repo never learns topology. |
| D3 | Target naming vocabulary | [!status green](`<project>-<env>` logical names) | `fixit-prod`, `eve-prod`… Name says WHAT, registry says WHERE; server moves = one registry line. **Note (Lukáš):** add an admin-only mini app UI for this (Go + mjs SPA, vitrinka-style deploy), VPN-gated, admin (Lukáš) access only. |
| D4 | Repo→target authorization | [!status green](Runner identity + policy map) | Bastion guests are leased per-repo by the ci-kvm controller → caller identity comes from the controller's lease (guest IP), not from spoofable env vars; gateway checks `target → allowed repos`. |
| D5 | Dispatcher standardization | [!status green](One shared dispatch framework) | Single versioned dispatcher, root-installed on all 3 servers, reading per-project verb config. Audit once, reuse everywhere; replaces bespoke fixit-prod-deploy / fixit-dev-release-dispatch / deployik-ci-deploy. |
| D6 | Buildkit v2 consumer API | [!status green](Reusable `deploy.yml` workflow) | `uses: …/deploy.yml@v2 with: target:` — the safe path is the paved path; repos cannot skip policy steps. Composite action stays for exotic flows. |
| D7 | App-secrets scope | [!status green](Keys now, app secrets phase 3) | v2 moves access keys only; `.env` still renders from GitHub environment secrets. Host-side secret store is the next program once v2 is proven. |
| D8 | Interim FixIt prod deploys | [!status green](Manual runbook until v2) | No throwaway v1 lane; documented manual-ssh runbook covers the rare prod deploy until v2 reaches deploy-production. |
:::

## Assumptions (not asked — one sane answer)

- FixIt is the pilot repo; `deploy-dev` migrates first, `deploy-production`
  only after deploy-dev is proven (user's explicit call).
- The websites server onboards to v2 only after its OS rebuild; the registry design
  accounts for it from day 1.
- The eve-ai-layer physical move to the production server is its own later project —
  v2 makes it a registry edit, not a workflow rewrite.
- v1 runner/queue mechanics carry over unchanged: `classes.conf` slot classes,
  host `flock` queue, runner size tiers, Firefly hot VM + bastion KVM guests.
- The WG zone model (wg-admin / wg-employee / wg-p2p, 2026-08-09 redesign) is
  the network substrate; v2 builds on it, never bypasses it.
- Forced-command + `from=` + `restrict` stays the floor for ANY authorized key
  on any server — the gateway's own keys included.

## Architecture notes

```
GitHub (no keys) ──job──▶ bastion guest (per-repo lease, ci-kvm controller)
                              │  deployctl <target> <verb>   (bastion bridge → host)
                              ▼
                  deploy-gateway  (root, Devulinka host)
                  ├─ targets.yml   name → server/endpoint/dispatcher project
                  ├─ policy        target → allowed repos (from controller lease)
                  ├─ keys          per-target ed25519, generated on-host, 0600 root
                  ├─ audit log     append-only JSONL (who/target/verb/result)
                  └─ admin UI      Go + mjs SPA, wg-admin only (phase 2 of v2)
                              │  ssh (wg-p2p / wg zone), forced command
                              ▼
                  dispatch (shared framework, root-installed on each server)
                  └─ /etc/<dispatch>/<project>.yml — verb whitelist → commands
```

- Caller identity: the ci-kvm controller writes a lease file
  (`guest IP → repo`) the gateway reads; guests are per-repo scale sets, so
  IP = repo without trusting anything the job says.
- Code custody: gateway + dispatcher code lives in the **infra repo**
  (private); the public buildkit repo carries only the reusable `deploy.yml`
  + a thin `deploy-step` action calling `deployctl` (no secrets, no topology).
- Rollout: infra first (gateway + dispatch on Devulinka and the production server) → FixIt
  `deploy-dev` on v2 → other repos → `deploy-production` last.

## Open questions

- Admin UI (D3 note) scope & design — its own mini-brainstorm once the
  gateway core is live (phase 2 of v2).
- Exact verb sets per project for the dispatch configs (ported from the
  existing bespoke dispatchers during migration).
