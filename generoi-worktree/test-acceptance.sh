#!/usr/bin/env bash
# #ddev-generated: If you want to edit and own this file, remove this line.
# generoi-worktree acceptance tests (run from a git worktree checkout)
set -euo pipefail

APPROOT=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
source "$APPROOT/.ddev/generoi-worktree/lib.sh"

PASS=0
FAIL=0
MARKER="wt-acceptance-$(date +%s).txt"
MARKER_BODY="generoi-worktree-acceptance-marker"
DB_MARKER="wt-db-isolation-$(date +%s)"
WT_HOST=""
WT_PORT=""
WT_SUB=""
WT_PROJECT=""

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail "$desc (expected '$expected', got '$actual')"; fi
}

assert_contains() {
  local desc=$1 needle=$2 haystack=$3
  if echo "$haystack" | grep -qF "$needle"; then pass "$desc"; else fail "$desc (missing '$needle')"; fi
}

assert_https_port() {
  local desc=$1 host=$2 port=$3 want_code=$4
  local code
  code=$(curl -k -s -o /dev/null -w '%{http_code}' -L --max-redirs 5 "https://${host}:${port}/")
  assert_eq "$desc" "$want_code" "$code"
}

cleanup() {
  rm -f "$APPROOT/web/$MARKER" 2>/dev/null || true
  (cd "$APPROOT" && ddev stop >/dev/null 2>&1) || true
}
trap cleanup EXIT

echo "=== generoi-worktree acceptance (v0.2) ==="
echo "approot: $APPROOT"
echo ""

echo "[1] worktree detection"
if wt_is_canonical_checkout; then
  fail "should not be canonical checkout"
else
  pass "detected as worktree"
fi
assert_eq "canonical approot exists" "$(wt_canonical_approot)" "$(git worktree list --porcelain | awk '/^worktree / {print $2; exit}')"

echo ""
echo "[2] wt-prepare (unique DDEV name + bootstrap)"
rm -f "$APPROOT/.ddev/config.generoi-worktree.local.yaml" 2>/dev/null || true
rm -f "$APPROOT/.env" "$APPROOT/web/app/uploads" 2>/dev/null || true
if [[ -L "$APPROOT/vendor" ]]; then rm "$APPROOT/vendor"; fi
bash "$APPROOT/.ddev/commands/host/wt-prepare"

if [[ -f "$APPROOT/.ddev/config.generoi-worktree.local.yaml" ]] \
  && grep -q "^name: $(wt_project_name)" "$APPROOT/.ddev/config.generoi-worktree.local.yaml"; then
  pass "local config sets unique project name"
else
  fail "missing .ddev/config.generoi-worktree.local.yaml with expected name"
fi

if [[ ! -d "$APPROOT/vendor" ]] || [[ ! -f "$APPROOT/web/wp/wp-blog-header.php" ]] || \
   [[ ! -f "$APPROOT/web/app/plugins/wp-spot-prices/dist/manifest.json" ]]; then
  wt_install_deps
fi

for rel in .env web/app/uploads; do
  if [[ -e "$APPROOT/$rel" ]]; then pass "$rel exists"; else fail "$rel missing after bootstrap"; fi
done

echo ""
echo "[3] ddev start (forked DB + Caddy on first start)"
(cd "$APPROOT" && ddev stop >/dev/null 2>&1) || true
out=$(cd "$APPROOT" && ddev start 2>&1)
assert_contains "ddev start prints WT_URL" "WT_URL=https://" "$out"
assert_contains "ddev start starts Caddy" "Caddy proxy on 127.0.0.1:" "$out"

WT_URL=$(echo "$out" | awk -F= '/^WT_URL=/{print $2}')
[[ -n "$WT_URL" ]] || WT_URL=$(ddev wt-port 2>&1 | awk -F= '/^WT_URL=/{print $2}')
[[ -n "$WT_URL" ]] || fail "could not parse WT_URL"
WT_HOST=$(echo "$WT_URL" | sed -E 's|https://([^:/]+).*|\1|')
WT_PORT=$(echo "$WT_URL" | sed -E 's|https://[^:]+:([0-9]+).*|\1|')
[[ -n "$WT_HOST" && -n "$WT_PORT" ]] || fail "could not parse host/port from WT_URL ($WT_URL)"
pass "worktree URL ${WT_HOST}:${WT_PORT}"

WT_SUB="nat.${WT_HOST}"
assert_contains "subsite example" "subsite example: https://${WT_SUB}:${WT_PORT}" "$out"

WT_PROJECT=$(wt_ddev_project_name)
web_container=$(wt_web_container "$WT_PROJECT")
if docker ps --filter "name=${web_container}" --filter status=running --format '{{.Status}}' | grep -q healthy; then
  pass "worktree web healthy (${web_container})"
else
  fail "worktree web not healthy"
fi

if docker ps --filter "name=$(wt_caddy_container_name "$WT_PROJECT")" --filter status=running --format '{{.Names}}' | grep -qx "$(wt_caddy_container_name "$WT_PROJECT")"; then
  pass "caddy proxy running"
else
  fail "caddy proxy not running"
fi

if grep -q 'header_up Host {http.request.host}' "$APPROOT/.ddev/wt/Caddyfile" 2>/dev/null; then
  pass "Caddy sends canonical Host to PHP"
else
  fail "Caddyfile missing header_up Host {http.request.host}"
fi

http_host=$(ddev wp eval 'echo $_SERVER["HTTP_HOST"];' 2>/dev/null | tail -1)
if [[ "$http_host" == "$WT_HOST" ]] && [[ "$http_host" != *:* ]]; then
  pass "PHP HTTP_HOST is ${http_host} (no port)"
else
  fail "PHP HTTP_HOST should be ${WT_HOST} without port (got: ${http_host})"
fi

port_out=$(ddev wt-port 2>&1)
assert_contains "wt-port WT_URL" "WT_URL=${WT_URL}" "$port_out"

list_out=$(ddev wt-list 2>&1)
assert_contains "wt-list shows caddy" "$(wt_caddy_container_name "$WT_PROJECT")" "$list_out"

echo ""
echo "[4] HTTPS + multisite (Caddy :${WT_PORT})"
assert_https_port "main site HTTPS 200" "$WT_HOST" "$WT_PORT" "200"
assert_https_port "nat subsite HTTPS 200" "$WT_SUB" "$WT_PORT" "200"

html=$(curl -k -s "https://${WT_HOST}:${WT_PORT}/")
if echo "$html" | grep -qE ":${WT_PORT}:${WT_PORT}"; then
  fail "HTML contains double :${WT_PORT} port"
else
  pass "no double :${WT_PORT} in HTML URLs"
fi

echo ""
echo "[5] code isolation"
echo "$MARKER_BODY" >"$APPROOT/web/$MARKER"
side=$(curl -k -s "https://${WT_HOST}:${WT_PORT}/${MARKER}")
canon=$(curl -k -s -o /dev/null -w '%{http_code}' --resolve "herrfors.ddev.site:443:127.0.0.1" "https://herrfors.ddev.site/${MARKER}")
assert_eq "marker visible on worktree" "$MARKER_BODY" "$side"
if [[ "$canon" == "404" ]] || [[ "$canon" =~ ^30[0-9]$ ]]; then
  pass "marker not on canonical ($canon)"
else
  fail "marker not on canonical (expected 404/redirect, got '$canon')"
fi

echo ""
echo "[6] DB isolation (forked MariaDB)"
ddev wp option update "generoi_wt_${DB_MARKER}" "worktree-only" --quiet 2>/dev/null
wt_val=$(ddev wp option get "generoi_wt_${DB_MARKER}" 2>/dev/null | tail -1)
assert_eq "option set in worktree DB" "worktree-only" "$wt_val"

canon_val=$(cd "$(wt_canonical_approot)" && ddev wp option get "generoi_wt_${DB_MARKER}" 2>/dev/null || true)
if [[ -z "$canon_val" ]] || echo "$canon_val" | grep -qiE 'error|not found|does not exist'; then
  pass "option absent from canonical DB"
else
  fail "option leaked to canonical DB: $canon_val"
fi
ddev wp option delete "generoi_wt_${DB_MARKER}" --quiet 2>/dev/null || true

echo ""
echo "[7] uploads (shared from canonical host path)"
missing="/app/uploads/generoi-wt-missing-$(date +%s).jpg"
headers=$(curl -k -sI "https://${WT_HOST}:${WT_PORT}${missing}")
if echo "$headers" | grep -qiE '^HTTP/.* (302|301|307|308) '; then
  pass "missing upload redirects (like canonical DDEV)"
else
  fail "missing upload should redirect, got: $(echo "$headers" | head -1)"
fi

echo ""
echo "[8] ddev stop (Caddy cleanup, state kept for port)"
ddev stop >/dev/null 2>&1
if docker ps -a --format '{{.Names}}' | grep -qx "$(wt_caddy_container_name "$WT_PROJECT")"; then
  fail "caddy still exists after ddev stop"
else
  pass "caddy removed after ddev stop"
fi
if [[ -f "$WT_STATE_FILE" ]]; then
  pass "state file kept (port reuse)"
else
  fail "state file should remain after ddev stop"
fi

echo ""
echo "[9] wt-up deprecated"
set +e
deprecated=$(ddev wt-up 2>&1)
dep_ec=$?
set -e
if [[ $dep_ec -ne 0 ]] && echo "$deprecated" | grep -qi 'ddev start'; then
  pass "wt-up points to ddev start"
else
  fail "wt-up should refuse with ddev start hint (exit=$dep_ec)"
fi

echo ""
echo "=== results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
