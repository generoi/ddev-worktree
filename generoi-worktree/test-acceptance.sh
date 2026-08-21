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
WT_HOST=""
WT_PORT=""
WT_SUB=""

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

assert_not_contains() {
  local desc=$1 needle=$2 haystack=$3
  if echo "$haystack" | grep -qF "$needle"; then fail "$desc (unexpected '$needle')"; else pass "$desc"; fi
}

cleanup() {
  rm -f "$APPROOT/web/$MARKER" 2>/dev/null || true
  (cd "$APPROOT" && ddev wt-down >/dev/null 2>&1) || true
}
trap cleanup EXIT

echo "=== generoi-worktree acceptance ==="
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
echo "[2] wt-guard"
if bash "$APPROOT/.ddev/commands/host/wt-guard" >/dev/null 2>&1; then
  fail "wt-guard should block worktree ddev start"
else
  pass "wt-guard blocks ddev start in worktree"
fi

echo ""
echo "[3] bootstrap + composer deps"
rm -f "$APPROOT/.env" "$APPROOT/web/app/uploads" 2>/dev/null || true
if [[ -L "$APPROOT/vendor" ]]; then rm "$APPROOT/vendor"; fi
wt_bootstrap_links

if [[ ! -d "$APPROOT/vendor" ]] || [[ ! -f "$APPROOT/web/wp/wp-blog-header.php" ]] || \
   [[ ! -f "$APPROOT/web/app/plugins/wp-spot-prices/dist/manifest.json" ]]; then
  wt_install_deps
fi

for rel in .env web/app/uploads; do
  if [[ -e "$APPROOT/$rel" ]]; then pass "$rel exists"; else fail "$rel missing after bootstrap"; fi
done

if [[ -d "$APPROOT/vendor" && ! -L "$APPROOT/vendor" ]]; then
  pass "vendor is local directory (composer install)"
else
  fail "vendor missing or still symlinked"
fi

if [[ -f "$APPROOT/web/wp/wp-blog-header.php" && ! -L "$APPROOT/web/wp" ]]; then
  pass "web/wp installed locally (composer)"
else
  fail "web/wp missing or symlinked"
fi

if [[ ! -f "$APPROOT/web/app/mu-plugins/generoi-worktree-sidecar.php" ]]; then
  pass "no legacy PHP URL shim"
else
  fail "legacy mu-plugin should not exist"
fi

if [[ -f "$APPROOT/config/environments/wt.php" ]]; then
  pass "committed wt.php config exists"
else
  fail "config/environments/wt.php missing"
fi

echo ""
echo "[4] wt-up / sidecar lifecycle (shared DB + Caddy)"
ddev wt-down >/dev/null 2>&1 || true
out=$(ddev wt-up --no-deps 2>&1)
assert_contains "wt-up prints WT_URL" "WT_URL=https://" "$out"
assert_contains "wt-up starts Caddy proxy" "Caddy proxy on 127.0.0.1:" "$out"

WT_URL=$(echo "$out" | awk -F= '/^WT_URL=/{print $2}')
[[ -n "$WT_URL" ]] || fail "could not parse WT_URL from wt-up"
WT_HOST=$(echo "$WT_URL" | sed -E 's|https://([^:/]+).*|\1|')
WT_PORT=$(echo "$WT_URL" | sed -E 's|https://[^:]+:([0-9]+).*|\1|')
[[ -n "$WT_HOST" && -n "$WT_PORT" ]] || fail "could not parse host/port from WT_URL ($WT_URL)"
pass "worktree URL ${WT_HOST}:${WT_PORT}"

WT_SUB="nat.${WT_HOST}"
assert_contains "wt-up subsite example" "subsite example: https://${WT_SUB}:${WT_PORT}" "$out"

if docker ps --filter "name=$(wt_container_name)" --filter status=running --format '{{.Status}}' | grep -q healthy; then
  pass "sidecar healthy"
else
  fail "sidecar not healthy"
fi

if docker ps --filter "name=$(wt_caddy_container_name)" --filter status=running --format '{{.Names}}' | grep -qx "$(wt_caddy_container_name)"; then
  pass "caddy proxy running"
else
  fail "caddy proxy not running"
fi

port_out=$(ddev wt-port 2>&1)
assert_contains "wt-port WT_URL" "WT_URL=${WT_URL}" "$port_out"
assert_contains "wt-port WT_PORT" "WT_PORT=${WT_PORT}" "$port_out"

list_out=$(ddev wt-list 2>&1)
assert_contains "wt-list shows container" "$(wt_container_name)" "$list_out"
assert_contains "wt-list shows approot" "$APPROOT" "$list_out"

echo ""
echo "[5] HTTPS + multisite (Caddy :${WT_PORT})"
assert_https_port "main site HTTPS 200" "$WT_HOST" "$WT_PORT" "200"
assert_https_port "nat subsite HTTPS 200" "$WT_SUB" "$WT_PORT" "200"

canonical_code=$(curl -k -s -o /dev/null -w '%{http_code}' --resolve "herrfors.ddev.site:443:127.0.0.1" "https://herrfors.ddev.site/")
if [[ "$canonical_code" =~ ^(200|301|302)$ ]]; then
  pass "canonical still responds via Traefik ($canonical_code)"
else
  fail "canonical HTTPS ($canonical_code)"
fi

echo ""
echo "[6] code isolation"
echo "$MARKER_BODY" >"$APPROOT/web/$MARKER"
side=$(curl -k -s "https://${WT_HOST}:${WT_PORT}/${MARKER}")
canon=$(curl -k -s -o /dev/null -w '%{http_code}' --resolve "herrfors.ddev.site:443:127.0.0.1" "https://herrfors.ddev.site/${MARKER}")
assert_eq "marker visible on sidecar" "$MARKER_BODY" "$side"
if [[ "$canon" == "404" ]] || [[ "$canon" =~ ^30[0-9]$ ]]; then
  pass "marker not on canonical ($canon)"
else
  fail "marker not on canonical (expected 404/redirect, got '$canon')"
fi

echo ""
echo "[7] uploads (no prod redirect)"
missing="/app/uploads/generoi-wt-missing-$(date +%s).jpg"
headers=$(curl -k -sI "https://${WT_HOST}:${WT_PORT}${missing}")
assert_contains "missing upload returns 404" "404" "$headers"
assert_not_contains "missing upload does not redirect to herrfors.fi" "herrfors.fi" "$headers"

echo ""
echo "[8] shared DB via wt-wp (canonical URLs in DB)"
wp_out=$(ddev wt-wp option get home --url="https://${WT_HOST}:${WT_PORT}" 2>&1)
if echo "$wp_out" | grep -qF "https://${WT_HOST}" && ! echo "$wp_out" | grep -qF ":${WT_PORT}"; then
  pass "wt-wp home uses canonical hostname (no port in DB)"
else
  fail "wt-wp home wrong: $wp_out"
fi

nat_out=$(ddev wt-wp option get blogname --url="https://${WT_SUB}:${WT_PORT}" 2>&1)
if [[ -n "$nat_out" ]] && ! echo "$nat_out" | grep -qiE 'error|failed|does not seem'; then
  pass "wt-wp nat subsite blogname ($nat_out)"
else
  fail "wt-wp nat failed: $nat_out"
fi

echo ""
echo "[9] wt-down cleanup"
ddev wt-down >/dev/null 2>&1
if docker ps -a --format '{{.Names}}' | grep -qx "$(wt_container_name)"; then
  fail "container still exists after wt-down"
else
  pass "container removed after wt-down"
fi
if docker ps -a --format '{{.Names}}' | grep -qx "$(wt_caddy_container_name)"; then
  fail "caddy still exists after wt-down"
else
  pass "caddy removed after wt-down"
fi
if [[ -f "$WT_STATE_FILE" ]]; then fail "state file still exists"; else pass "state file removed"; fi

echo ""
echo "[10] wt-up on canonical should refuse"
set +e
canon_out=$(cd "$(wt_canonical_approot)" && bash .ddev/commands/host/wt-up --no-deps 2>&1)
canon_ec=$?
set -e
if [[ $canon_ec -ne 0 ]] && echo "$canon_out" | grep -q 'canonical checkout'; then
  pass "wt-up refused on canonical"
else
  fail "wt-up should refuse on canonical (exit=$canon_ec)"
fi

echo ""
echo "=== results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
