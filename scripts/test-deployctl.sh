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
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        nonce = self.headers.get("X-Exit-Nonce", "")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        w = self.wfile
        if "binary" in self.path:
            w.write(b"\x00\xfftar-ish\n@@deploy-gateway-exit@@ deadbeef 0\nend\x00")
            w.write(f"\n@@deploy-gateway-exit@@ {nonce} 0\n".encode())
            return
        w.write(f"path={self.path}\n".encode())
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

if (( fails > 0 )); then
  echo "$fails test(s) FAILED"
  exit 1
fi
echo "all deployctl tests passed"
