#!/usr/bin/env bash
# devulinka-buildkit project onboarding generator.
#
# Usage:
#   blueprint/new-project.sh <owner>/<repo> <shortname> [--go] [--priority]
#
#   <shortname>   used for the runner label (<shortname>-ci), container name,
#                 and workdir. Keep it short and kebab-case, e.g. "voke".
#   --go          also emit a go-test job (Go + Bun repo).
#   --priority    builds use the priority lane (deploy-critical projects only).
#
# Since 2026-08-19 runner lanes are declared in devulinka-infra's
# etc/ci-lanes/manifest.json and RENDERED by scripts/gen-ci-lanes.py — never
# hand-edit the compose. This script prints:
#   1. the manifest entry to add in devulinka-infra
#   2. a .github/workflows/ci.yml starter for the new repo
#   3. the remaining manual steps
set -euo pipefail

[[ $# -ge 2 ]] || { sed -n '2,15p' "$0"; exit 2; }
SLUG="$1"; NAME="$2"; shift 2
OWNER="${SLUG%%/*}"
GO=0; PRIO=false
for a in "$@"; do
  case "$a" in
    --go) GO=1 ;;
    --priority) PRIO=true ;;
  esac
done

cat <<EOF
# ─── 1. lane manifest entry — add to devulinka-infra etc/ci-lanes/manifest.json
#        under "hot_families", then run scripts/gen-ci-lanes.py and commit the
#        manifest + both rendered files together (the ci-lanes contract check
#        enforces this). New projects start on the smallest tier — move to
#        "4vcpu"/"8vcpu"/"16vcpu" only when the lane demonstrably needs it.

  {
   "repo": "https://github.com/${SLUG}",
   "app_login": "${OWNER}",
   "lane": "${NAME}-ci",
   "legacy_label": null,
   "extra_labels": [],
   "tier": "2vcpu",
   "mem": "4g",
   "cpu_shares": 2048,
   "pids": null,
   "image": "lovinka/gh-runner:dev-vps",
   "cache_env": {
    "BUN_INSTALL_CACHE_DIR": "/home/runner/.bun/install/cache",
    "PLAYWRIGHT_BROWSERS_PATH": "/home/runner/.cache/ms-playwright"
   },
   "replicas": [
    {
     "svc": "runner-${NAME}",
     "container": "gh-runner-${NAME}",
     "runner_name": "devops-vps-${NAME}-1",
     "workdir": "/opt/apps/gh-runner/work/${NAME}-1"
    }
   ]
  }

# ─── 2. .github/workflows/ci.yml starter for ${SLUG}

name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
EOF

if [[ $GO -eq 1 ]]; then
cat <<EOF
  go-test:
    runs-on: [self-hosted, ${NAME}-ci]
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
      - run: go test ./...

EOF
fi

cat <<EOF
  test:
    uses: henderson-tech/devulinka-buildkit/.github/workflows/test-bun.yml@v1
    with:
      runs-on: '["self-hosted","${NAME}-ci"]'
      bun-version: '1.4.3'
      run: |
        bun run test
        bun run build

  build-and-push:
    needs: [test]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write
    uses: henderson-tech/devulinka-buildkit/.github/workflows/build-image.yml@v1
    with:
      runs-on: '["self-hosted","${NAME}-ci"]'
      image: ghcr.io/$(echo "$SLUG" | tr '[:upper:]' '[:lower:]')
      dockerfile: Dockerfile
      priority: ${PRIO}

# ─── 3. manual steps
#  a. Install the devulinka-runners GitHub App on ${SLUG}:
#     https://github.com/apps/devulinka-runners/installations/new
#     (owner ${OWNER}; for a NEW owner this is the only "credential" step ever)
#  b. Add block 1 to devulinka-infra etc/ci-lanes/manifest.json, run
#     scripts/gen-ci-lanes.py, commit manifest + rendered files, merge, then
#     deploy the fleet:
#     ssh root@95.216.27.220 /opt/apps/firefly-vm/scripts/deploy-firefly-fleet.sh
#  c. Drop block 2 into ${SLUG}/.github/workflows/ci.yml, adjust test/build cmds
#  d. Verify: https://github.com/${SLUG}/settings/actions/runners shows the runner
#  e. A deploy lane later? That is an ephemeral KVM entry ("ephemeral" array in
#     the same manifest, label ${NAME}-bastion) — see devulinka-infra
#     apps/ci-kvm/README.md.
EOF
