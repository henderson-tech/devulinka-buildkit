#!/usr/bin/env bash
# deployctl — buildkit v2 deploy client. Talks to the deploy-gateway on the
# Devulinka host; holds NO credentials (the gateway resolves this job's repo
# from its bastion-guest lease and enforces the target policy host-side).
#
# Usage:
#   deployctl <target> <verb> [args...] [@payload-file]
#
# A trailing @file streams that file as the payload: its byte count and
# sha256 are appended as the final two protocol args (the lovinka-ssh
# dispatcher framing) and the bytes ride the request body. @env:NAME streams
# the value of environment variable NAME instead — for secret payloads (a
# dispatcher whose `deploy` verb takes the registry token as its payload),
# so a workflow never stages a secret in a file itself.
#
# Registry credentials (GHCR_TOKEN in the environment = this run's
# GITHUB_TOKEN with packages: read):
#   deployctl <target> registry-login [actor]   token from $GHCR_TOKEN
#                                               (fallback $GITHUB_TOKEN),
#                                               actor defaults to $GITHUB_ACTOR
#   deployctl <target> pull|deploy ...          logs in first, by itself,
#                                               whenever $GHCR_TOKEN is set
# The token passes through a 0600 temp file this script owns and removes;
# a workflow never stages it. Forgetting the auth step is thereby impossible:
# any verb that makes the host pull authenticates on its own.
#
# Output: the dispatcher's combined output, live. Exit code: the remote
# verb's exit code. The status line is authenticated with a per-request
# nonce (X-Exit-Nonce), so dispatcher output cannot forge it.
#
# Exit 70 = the response ended without the gateway's status line: the deploy
# state is UNKNOWN. Never retry an unknown-state step blindly (a migrate may
# have half-run) — inspect the target first.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/deploy-gateway-curl.sh"
# shellcheck disable=SC2154
gateway=$deploy_gateway_url
sentinel='@@deploy-gateway-exit@@'

if (( $# < 2 )); then
  echo "usage: deployctl <target> <verb> [args...] [@payload-file]" >&2
  exit 2
fi

target=$1
verb=$2
shift 2

payload=''
payload_env=''
args=()
for token in "$@"; do
  if [[ $token == @env:* ]]; then
    [[ -z $payload && -z $payload_env ]] || { echo "deployctl: only one @payload allowed" >&2; exit 2; }
    payload_env=${token#@env:}
    [[ $payload_env =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "deployctl: invalid @env: name '$payload_env'" >&2; exit 2; }
  elif [[ $token == @* ]]; then
    [[ -z $payload && -z $payload_env ]] || { echo "deployctl: only one @payload allowed" >&2; exit 2; }
    payload=${token#@}
  else
    args+=("$token")
  fi
done

[[ $target =~ ^[a-z][a-z0-9-]+$ ]] || { echo "deployctl: invalid target '$target'" >&2; exit 2; }
[[ $verb =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { echo "deployctl: invalid verb '$verb'" >&2; exit 2; }

token_file=''
cleanup_token() { [[ -z $token_file ]] || rm -f "$token_file"; }
# Stage a secret value as the payload: 0600 temp file this script owns and
# removes on exit. The value never appears in argv or in a workflow-managed file.
stage_secret_payload() {
  umask 077
  token_file=$(mktemp)
  trap cleanup_token EXIT
  printf '%s' "$1" > "$token_file"
  payload=$token_file
}
if [[ -n $payload_env ]]; then
  [[ -n ${!payload_env:-} ]] || { echo "deployctl: @env:$payload_env is unset or empty" >&2; exit 2; }
  stage_secret_payload "${!payload_env}"
elif [[ $verb == registry-login && -z $payload ]]; then
  registry_token=${GHCR_TOKEN:-${GITHUB_TOKEN:-}}
  [[ -n $registry_token ]] || {
    echo "deployctl: registry-login needs GHCR_TOKEN (or GITHUB_TOKEN) in the environment, or an @token-file" >&2
    exit 2
  }
  if (( ${#args[@]} == 0 )); then
    [[ -n ${GITHUB_ACTOR:-} ]] || { echo "deployctl: registry-login needs an actor argument or GITHUB_ACTOR" >&2; exit 2; }
    args=("$GITHUB_ACTOR")
  fi
  stage_secret_payload "$registry_token"
  unset registry_token
elif [[ ($verb == pull || $verb == deploy) && -z $payload && -n ${GHCR_TOKEN:-} ]]; then
  # The host is about to pull: authenticate it first with this run's token.
  bash "$0" "$target" registry-login
fi

curl_args=(-sS -N -X POST)
if [[ -n $payload ]]; then
  [[ -f $payload && ! -L $payload ]] || {
    echo "deployctl: payload must be a regular, non-symlink file: $payload" >&2
    exit 2
  }
  bytes=$(wc -c < "$payload" | tr -d '[:space:]')
  if command -v sha256sum >/dev/null 2>&1; then
    sha256=$(sha256sum "$payload" | cut -d' ' -f1)
  else
    sha256=$(shasum -a 256 "$payload" | cut -d' ' -f1)
  fi
  args+=("$bytes" "$sha256")
  curl_args+=(--data-binary "@$payload" -H 'Content-Type: application/octet-stream')
fi

# Percent-encode one arg for the query string. The server-side charset
# excludes true metacharacters, but `+` and friends have QUERY semantics —
# an unencoded `+` arrives as a space. Encode everything non-unreserved.
urlencode() {
  local s=$1 out='' c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

query=''
for arg in ${args[@]+"${args[@]}"}; do
  [[ -z $arg ]] && continue
  [[ $arg =~ ^[A-Za-z0-9._/@:=+-]{1,128}$ ]] || { echo "deployctl: invalid arg '$arg'" >&2; exit 2; }
  query+="${query:+&}arg=$(urlencode "$arg")"
done

# Per-request nonce: the gateway echoes it on the status line, so a line the
# DISPATCHER prints can never be mistaken for the gateway's verdict.
nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
curl_args+=(-H "X-Exit-Nonce: $nonce")

url="${gateway}/v1/deploy/${target}/${verb}${query:+?${query}}"
response_file=$(mktemp)
trailer_file=$(mktemp)
oidc_header_file=''
trap 'rm -f "$response_file" "$trailer_file" ${oidc_header_file:+"$oidc_header_file"}; cleanup_token' EXIT

# GitHub Actions OIDC (vt-1491): a job with `permissions: id-token: write` proves
# its environment, ref and workflow to targets that bind them. Without that
# permission no header is sent: an observe-mode target still deploys, an
# enforcing one refuses. The token travels in a 0600 header file, never argv.
oidc_audience=${DEPLOY_GATEWAY_OIDC_AUDIENCE:-deploy-gateway}
mint_oidc_header() {
  rm -f ${oidc_header_file:+"$oidc_header_file"}
  oidc_header_file=''
  [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] || return 0
  local sep='?' json token
  [[ $ACTIONS_ID_TOKEN_REQUEST_URL != *\?* ]] || sep='&'
  if ! json=$(command curl -sS --fail --max-time 20 \
      -H @<(printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN") \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}${sep}audience=$(urlencode "$oidc_audience")"); then
    echo "deployctl: could not mint a GitHub OIDC token — calling the gateway without one" >&2
    return 0
  fi
  token=$(printf '%s' "$json" | sed -nE 's/.*"value"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
  if [[ ! $token =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    echo "deployctl: GitHub OIDC response carried no token — calling the gateway without one" >&2
    return 0
  fi
  oidc_header_file=$(umask 077 && mktemp)
  printf 'Authorization: Bearer %s\n' "$token" > "$oidc_header_file"
}

# HTTP 429 is the gateway's admission refusal (target busy or at capacity): it
# is sent BEFORE anything executes, so it is the one response safe to retry.
# Backoff doubles from the first delay up to 60 s, within the retry budget.
retry_budget=${DEPLOYCTL_RETRY_BUDGET_SECONDS:-600}
delay=${DEPLOYCTL_RETRY_FIRST_DELAY_SECONDS:-5}
# A zero or non-numeric delay would retry a busy gateway forever: refuse it.
[[ $retry_budget =~ ^[0-9]{1,5}$ && $delay =~ ^[1-9][0-9]{0,3}$ ]] || {
  echo "deployctl: DEPLOYCTL_RETRY_BUDGET_SECONDS must be 0-99999 and DEPLOYCTL_RETRY_FIRST_DELAY_SECONDS 1-9999" >&2
  exit 2
}
waited=0
while :; do
  mint_oidc_header
  attempt_args=("${curl_args[@]}")
  [[ -z $oidc_header_file ]] || attempt_args+=(-H "@$oidc_header_file")
  set +e
  http_code=$(deploy_gateway_curl "${attempt_args[@]}" -o "$response_file" -w '%{http_code}' "$url")
  curl_status=$?
  set -e

  if (( curl_status != 0 )); then
    echo "deployctl: gateway request failed (curl exit ${curl_status})" >&2
    exit 70
  fi
  [[ $http_code == 429 ]] || break
  if (( waited + delay > retry_budget )); then
    echo "deployctl: gateway still busy after ${waited}s (HTTP 429) — nothing ran on ${target}; retry later" >&2
    head -c 512 "$response_file" >&2
    exit 75
  fi
  echo "deployctl: gateway busy (HTTP 429) — nothing ran; retrying ${verb} in ${delay}s: $(head -c 200 "$response_file" | tr '\n' ' ')" >&2
  sleep "$delay"
  waited=$((waited + delay))
  delay=$((delay * 2 > 60 ? 60 : delay * 2))
done

# The gateway's authenticated verdict is an exact final frame:
#   \n@@deploy-gateway-exit@@ <nonce> <code>\n
# Parse and remove only that suffix. A line-oriented filter (awk/sed) is not
# binary-safe: it rewrites record separators and corrupted streamed tar files.
status_line=$(tail -n 1 "$response_file")
read -r got_sentinel got_nonce code extra <<< "$status_line"
if [[ $got_sentinel != "$sentinel" || $got_nonce != "$nonce" || -n ${extra:-} \
      || ! $code =~ ^[0-9]+$ || $code -gt 255 ]]; then
  echo "deployctl: gateway response ended without an authenticated exit status — deploy state UNKNOWN, do not retry blindly" >&2
  exit 70
fi

printf '\n%s\n' "$status_line" > "$trailer_file"
response_bytes=$(wc -c < "$response_file" | tr -d '[:space:]')
trailer_bytes=$(wc -c < "$trailer_file" | tr -d '[:space:]')
if (( response_bytes < trailer_bytes )) \
    || ! tail -c "$trailer_bytes" "$response_file" | cmp -s - "$trailer_file"; then
  echo "deployctl: malformed authenticated exit frame — deploy state UNKNOWN, do not retry blindly" >&2
  exit 70
fi

body_bytes=$((response_bytes - trailer_bytes))
if (( body_bytes > 0 )); then
  head -c "$body_bytes" "$response_file"
fi
exit "$code"
