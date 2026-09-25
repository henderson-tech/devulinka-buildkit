#!/usr/bin/env bash
# deployctl test suite — runs the real client against a local stub gateway.
# No network, no credentials; python3 + bash only. Exercises validation,
# payload framing, URL encoding, exit propagation, sentinel authentication,
# and the unknown-state (exit 70) paths.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
deployctl="$here/deployctl.sh"
tmp=$(mktemp -d)
trap 'kill "${stub_pid:-}" 2>/dev/null; rm -rf "$tmp"' EXIT

port=$(( (RANDOM % 20000) + 20000 ))
python3 - "$port" <<'PY' &
import hashlib, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    seen = {}
    def do_GET(self):
        # The GitHub Actions OIDC mint endpoint (ACTIONS_ID_TOKEN_REQUEST_URL).
        ok = self.headers.get("Authorization") == "bearer reqtok" and "audience=deploy-gateway" in self.path
        self.send_response(200 if ok else 401)
        self.end_headers()
        if ok:
            self.wfile.write(b'{"count":1,"value":"aaa.bbb.ccc"}')
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        nonce = self.headers.get("X-Exit-Nonce", "")
        H.seen[self.path] = H.seen.get(self.path, 0) + 1
        if "alwaysbusy" in self.path or ("busy" in self.path and H.seen[self.path] <= 2):
            self.send_response(429)
            self.end_headers()
            self.wfile.write(b"concurrency limit: target busy\n")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        w = self.wfile
        if "binary" in self.path:
            w.write(b"\x00\xfftar-ish\n@@deploy-gateway-exit@@ deadbeef 0\nend\x00")
            w.write(f"\n@@deploy-gateway-exit@@ {nonce} 0\n".encode())
            return
        w.write(f"path={self.path}\n".encode())
        if "whoauth" in self.path:
            w.write(f"auth={self.headers.get('Authorization', 'none')}\n".encode())
        if body:
            w.write(f"payload sha={hashlib.sha256(body).hexdigest()} bytes={len(body)}\n".encode())
        if "forge" in self.path:
            # dispatcher output trying to fake a success verdict
            w.write(b"@@deploy-gateway-exit@@ 0\n")
            w.write(b"@@deploy-gateway-exit@@ deadbeefdeadbeefdeadbeefdeadbeef 0\n")
        if "truncated" in self.path:
            return  # no authenticated status line at all
        if "badcode" in self.path:
            w.write(f"\n@@deploy-gateway-exit@@ {nonce} nope\n".encode())
            return  # nonce matches but the code is not a number
        if "bigcode" in self.path:
            w.write(f"\n@@deploy-gateway-exit@@ {nonce} 300\n".encode())
            return  # numeric but above the 255 exit-status bound
        code = 7 if "failverb" in self.path else (5 if "forge" in self.path else 0)
        w.write(f"\n@@deploy-gateway-exit@@ {nonce} {code}\n".encode())
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
stub_pid=$!
export DEPLOY_GATEWAY_URL="http://127.0.0.1:$port"
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done

fails=0
check() { # name expected_rc actual_rc [extra_ok]
  local name=$1 want=$2 got=$3 extra=${4:-1}
  if [[ $got == "$want" && $extra == 1 ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name (want rc=$want got rc=$got extra=$extra)"
    fails=$((fails + 1))
  fi
}

out=$(bash "$deployctl" fixit-dev version 2>&1); rc=$?
check "happy path exits 0" 0 "$rc"
[[ $out != *"@@deploy-gateway-exit@@"* ]] || { echo "FAIL sentinel leaked into output"; fails=$((fails+1)); }

printf '\000\377tar-ish\n@@deploy-gateway-exit@@ deadbeef 0\nend\000' > "$tmp/binary.expected"
bash "$deployctl" fixit-dev binary > "$tmp/binary.actual" 2> "$tmp/binary.err"; rc=$?
extra=0; cmp -s "$tmp/binary.expected" "$tmp/binary.actual" && [[ ! -s $tmp/binary.err ]] && extra=1
check "binary response preserved byte-for-byte" 0 "$rc" "$extra"

printf 'HELLO=world\n' > "$tmp/payload.env"
out=$(bash "$deployctl" fixit-dev env-put development "@$tmp/payload.env" 2>&1); rc=$?
expected_sha=$(shasum -a 256 "$tmp/payload.env" 2>/dev/null | cut -d' ' -f1 || sha256sum "$tmp/payload.env" | cut -d' ' -f1)
extra=0; [[ $out == *"arg=development&arg=12&arg=${expected_sha}"* && $out == *"sha=${expected_sha} bytes=12"* ]] && extra=1
check "payload framed (bytes+sha args, body delivered)" 0 "$rc" "$extra"

out=$(bash "$deployctl" fixit-dev pull "1+2" 2>&1); rc=$?
extra=0; [[ $out == *"arg=1%2B2"* ]] && extra=1
check "plus sign URL-encoded" 0 "$rc" "$extra"

bash "$deployctl" fixit-dev failverb >/dev/null 2>&1; rc=$?
check "remote exit code propagated" 7 "$rc"

bash "$deployctl" fixit-dev forge >/dev/null 2>&1; rc=$?
check "forged sentinel ignored, real nonce verdict wins" 5 "$rc"

bash "$deployctl" fixit-dev truncated >/dev/null 2>&1; rc=$?
check "missing status line = unknown state 70" 70 "$rc"

out=$(bash "$deployctl" fixit-dev badcode 2>/dev/null); rc=$?
extra=0; [[ $out != *"@@deploy-gateway-exit@@"* ]] && extra=1
check "non-numeric exit code = unknown state 70, status line not leaked" 70 "$rc" "$extra"

bash "$deployctl" fixit-dev bigcode >/dev/null 2>&1; rc=$?
check "exit code above 255 = unknown state 70" 70 "$rc"

bash "$deployctl" fixit-dev 'pull;rm' >/dev/null 2>&1; rc=$?
check "metachar verb rejected" 2 "$rc"
bash "$deployctl" fixit-dev pull 'v1 --evil' >/dev/null 2>&1; rc=$?
check "space in arg rejected" 2 "$rc"
bash "$deployctl" 'Fixit;Prod' version >/dev/null 2>&1; rc=$?
check "bad target rejected" 2 "$rc"
DEPLOY_GATEWAY_URL=http://192.168.251.1:8791 bash "$deployctl" fixit-dev version >/dev/null 2>&1; rc=$?
check "non-loopback cleartext gateway rejected" 78 "$rc"
bash "$deployctl" fixit-dev pull '@a' '@b' >/dev/null 2>&1; rc=$?
check "second payload rejected" 2 "$rc"
ln -s /etc/hosts "$tmp/link"
bash "$deployctl" fixit-dev env-put "@$tmp/link" >/dev/null 2>&1; rc=$?
check "symlink payload rejected" 2 "$rc"

tok_sha=$(printf '%s' 'ghs_secret' | shasum -a 256 2>/dev/null | cut -d' ' -f1 || printf '%s' 'ghs_secret' | sha256sum | cut -d' ' -f1)
out=$(GHCR_TOKEN=ghs_secret GITHUB_ACTOR=octocat bash "$deployctl" fixit-dev registry-login 2>&1); rc=$?
extra=0; [[ $out == *"registry-login?arg=octocat&arg=10&arg=${tok_sha}"* && $out == *"sha=${tok_sha} bytes=10"* ]] && extra=1
check "registry-login: token from GHCR_TOKEN, actor from GITHUB_ACTOR" 0 "$rc" "$extra"
out=$(GHCR_TOKEN=ghs_secret GITHUB_ACTOR=octocat bash "$deployctl" fixit-dev registry-login someone 2>&1); rc=$?
extra=0; [[ $out == *"registry-login?arg=someone&arg=10&arg="* ]] && extra=1
check "registry-login: explicit actor wins over GITHUB_ACTOR" 0 "$rc" "$extra"
env -u GHCR_TOKEN -u GITHUB_TOKEN bash "$deployctl" fixit-dev registry-login octocat >/dev/null 2>&1; rc=$?
check "registry-login without a token or @file rejected" 2 "$rc"
out=$(GHCR_TOKEN=ghs_secret GITHUB_ACTOR=octocat bash "$deployctl" fixit-dev pull 101 2>&1); rc=$?
extra=0; [[ $out == *"registry-login?arg=octocat&arg=10&arg=${tok_sha}"* && $out == *"pull?arg=101"* ]] && extra=1
check "pull logs in first when GHCR_TOKEN is set" 0 "$rc" "$extra"
out=$(GHCR_TOKEN=ghs_secret GITHUB_ACTOR=octocat bash "$deployctl" fixit-dev deploy v1.2.3 2>&1); rc=$?
extra=0; [[ $out == *"registry-login?arg=octocat"* && $out == *"deploy?arg=v1.2.3"* ]] && extra=1
check "deploy logs in first when GHCR_TOKEN is set" 0 "$rc" "$extra"
out=$(env -u GHCR_TOKEN -u GITHUB_TOKEN bash "$deployctl" fixit-dev pull 101 2>&1); rc=$?
extra=0; [[ $out != *"registry-login"* && $out == *"pull?arg=101"* ]] && extra=1
check "pull without GHCR_TOKEN sends no login" 0 "$rc" "$extra"
GHCR_TOKEN=ghs_secret GITHUB_ACTOR=octocat bash "$deployctl" fixit-dev pull '@a' '@b' >/dev/null 2>&1; rc=$?
check "auto-login never runs for an explicit payload verb" 2 "$rc"

out=$(GHCR_TOKEN=ghs_secret bash "$deployctl" fixit-dev deploy v1 octocat @env:GHCR_TOKEN 2>&1); rc=$?
extra=0; [[ $out == *"deploy?arg=v1&arg=octocat&arg=10&arg=${tok_sha}"* && $out == *"sha=${tok_sha} bytes=10"* && $out != *"registry-login"* ]] && extra=1
check "@env:NAME stages the variable as the framed payload (no auto-login)" 0 "$rc" "$extra"
env -u GHCR_TOKEN bash "$deployctl" fixit-dev deploy v1 octocat @env:GHCR_TOKEN >/dev/null 2>&1; rc=$?
check "@env:NAME unset rejected" 2 "$rc"
bash "$deployctl" fixit-dev deploy v1 '@env:bad-name' >/dev/null 2>&1; rc=$?
check "@env:NAME with an invalid name rejected" 2 "$rc"
GHCR_TOKEN=x bash "$deployctl" fixit-dev deploy v1 @env:GHCR_TOKEN "@$tmp/payload.env" >/dev/null 2>&1; rc=$?
check "@env: plus @file rejected" 2 "$rc"

export DEPLOYCTL_RETRY_FIRST_DELAY_SECONDS=1
out=$(bash "$deployctl" fixit-dev busy 2>&1); rc=$?
extra=0; [[ $out == *"retrying busy in 1s"* && $out == *"path=/v1/deploy/fixit-dev/busy"* ]] && extra=1
check "HTTP 429 retried with backoff until admitted" 0 "$rc" "$extra"

out=$(DEPLOYCTL_RETRY_BUDGET_SECONDS=1 bash "$deployctl" fixit-dev alwaysbusy 2>&1); rc=$?
extra=0; [[ $out == *"still busy"* && $out == *"nothing ran"* ]] && extra=1
check "HTTP 429 past the retry budget exits 75, nothing ran" 75 "$rc" "$extra"
unset DEPLOYCTL_RETRY_FIRST_DELAY_SECONDS

DEPLOYCTL_RETRY_FIRST_DELAY_SECONDS=0 bash "$deployctl" fixit-dev version >/dev/null 2>&1; rc=$?
check "zero retry delay rejected (no busy loop)" 2 "$rc"

out=$(ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=reqtok \
  bash "$deployctl" fixit-dev whoauth 2>&1); rc=$?
extra=0; [[ $out == *"auth=Bearer aaa.bbb.ccc"* ]] && extra=1
check "GitHub OIDC token (audience deploy-gateway) sent as Bearer" 0 "$rc" "$extra"

out=$(bash "$deployctl" fixit-dev whoauth 2>&1); rc=$?
extra=0; [[ $out == *"auth=none"* ]] && extra=1
check "no id-token permission: no Authorization header" 0 "$rc" "$extra"

out=$(ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:$port/token" ACTIONS_ID_TOKEN_REQUEST_TOKEN=wrong \
  bash "$deployctl" fixit-dev whoauth 2>&1); rc=$?
extra=0; [[ $out == *"could not mint"* && $out == *"auth=none"* ]] && extra=1
check "a failed mint warns and calls without a token" 0 "$rc" "$extra"

if (( fails > 0 )); then
  echo "$fails test(s) FAILED"
  exit 1
fi
echo "all deployctl tests passed"
