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
# dispatcher framing) and the bytes ride the request body.
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
args=()
for token in "$@"; do
  if [[ $token == @* ]]; then
    [[ -z $payload ]] || { echo "deployctl: only one @payload-file allowed" >&2; exit 2; }
    payload=${token#@}
  else
    args+=("$token")
  fi
done

[[ $target =~ ^[a-z][a-z0-9-]+$ ]] || { echo "deployctl: invalid target '$target'" >&2; exit 2; }
[[ $verb =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { echo "deployctl: invalid verb '$verb'" >&2; exit 2; }

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
trap 'rm -f "$response_file" "$trailer_file"' EXIT

set +e
deploy_gateway_curl "${curl_args[@]}" "$url" > "$response_file"
curl_status=$?
set -e

if (( curl_status != 0 )); then
  echo "deployctl: gateway request failed (curl exit ${curl_status})" >&2
  exit 70
fi

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
