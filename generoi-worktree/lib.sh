#!/usr/bin/env bash
# #ddev-generated: If you want to edit and own this file, remove this line.
# generoi-worktree shared helpers (sourced by ddev host commands)

set -euo pipefail

WT_STATE_DIR=".ddev/wt"
WT_STATE_FILE="${WT_STATE_DIR}/state.json"
WT_LOCAL_CONFIG=".ddev/config.generoi-worktree.local.yaml"
WT_PORT_MIN=8081
WT_PORT_MAX=8099

wt_require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "generoi-worktree: missing required command: $1" >&2
    exit 1
  }
}

wt_approot() {
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

wt_canonical_approot() {
  wt_require git
  git worktree list --porcelain | awk '/^worktree / {print $2; exit}'
}

wt_is_canonical_checkout() {
  local canonical approot
  canonical=$(wt_canonical_approot)
  approot=$(wt_approot)
  [[ "$(cd "$canonical" && pwd -P)" == "$(cd "$approot" && pwd -P)" ]]
}

wt_ensure_ddev_project() {
  [[ -f .ddev/config.yaml ]] || {
    echo "generoi-worktree: not a DDEV project (.ddev/config.yaml missing)" >&2
    exit 1
  }
}

wt_canonical_name() {
  wt_ensure_ddev_project
  local canonical_approot name
  canonical_approot=$(wt_canonical_approot)
  name=$(awk '/^name:[[:space:]]*/ {print $2; exit}' "$canonical_approot/.ddev/config.yaml")
  [[ -n "$name" ]] || {
    echo "generoi-worktree: could not read canonical project name" >&2
    exit 1
  }
  echo "$name"
}

wt_suffix() {
  echo "$(wt_approot)" | cksum | awk '{print $1}'
}

wt_project_name() {
  echo "$(wt_canonical_name)-wt-$(wt_suffix)"
}

wt_ddev_project_name() {
  wt_require ddev
  ddev describe -j 2>/dev/null | jq -r '.raw.name // empty'
}

wt_web_container() {
  local project=${1:-}
  if [[ -z "$project" ]]; then
    project=$(wt_ddev_project_name)
  fi
  echo "ddev-${project}-web"
}

wt_caddy_container_name() {
  local project=${1:-}
  if [[ -z "$project" ]]; then
    if wt_read_state >/dev/null 2>&1; then
      project=$(wt_state_value project 2>/dev/null || true)
    fi
    project=${project:-$(wt_ddev_project_name)}
  fi
  echo "ddev-${project}-wt-caddy"
}

wt_network_name() {
  local project=${1:-}
  if [[ -z "$project" ]]; then
    project=$(wt_ddev_project_name)
  fi
  echo "ddev-${project}_default"
}

wt_port_in_use() {
  local port=$1
  if docker ps --format '{{.Ports}}' | grep -q "127.0.0.1:${port}->"; then
    return 0
  fi
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wt_allocate_port() {
  local requested=${1:-}
  if [[ -n "$requested" ]]; then
    if wt_port_in_use "$requested"; then
      echo "generoi-worktree: port ${requested} is already in use" >&2
      exit 1
    fi
    echo "$requested"
    return
  fi
  if wt_read_state >/dev/null 2>&1; then
    local saved
    saved=$(wt_state_value port 2>/dev/null || true)
    if [[ -n "$saved" ]] && ! wt_port_in_use "$saved"; then
      echo "$saved"
      return
    fi
  fi
  local port
  for port in $(seq "$WT_PORT_MIN" "$WT_PORT_MAX"); do
    if ! wt_port_in_use "$port"; then
      echo "$port"
      return
    fi
  done
  echo "generoi-worktree: no free port in ${WT_PORT_MIN}-${WT_PORT_MAX}" >&2
  exit 1
}

wt_ensure_canonical_running() {
  local name canonical_approot
  name=$(wt_canonical_name)
  canonical_approot=$(wt_canonical_approot)
  if ! docker ps --format '{{.Names}}' | grep -qx "ddev-${name}-db"; then
    echo "generoi-worktree: starting canonical DDEV project '${name}'..."
    (cd "$canonical_approot" && ddev start) || {
      echo "generoi-worktree: failed to start canonical DDEV at ${canonical_approot}" >&2
      exit 1
    }
  fi
}

wt_read_state() {
  [[ -f "$WT_STATE_FILE" ]] || return 1
  cat "$WT_STATE_FILE"
}

wt_state_value() {
  local key=$1
  wt_read_state >/dev/null 2>&1 || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$WT_STATE_FILE"
}

wt_canonical_hosts_from_config() {
  local canonical_approot=$1
  local name primary line host
  name=$(awk '/^name:[[:space:]]*/ {print $2; exit}' "$canonical_approot/.ddev/config.yaml")
  primary="${name}.ddev.site"
  echo "$primary"
  awk '
    /^additional_hostnames:/ { in_hosts=1; next }
    in_hosts && /^  - / {
      gsub(/^  - /, "", $0)
      gsub(/'\''|"/, "", $0)
      if ($0 ~ /\.ddev\.site$/) print $0; else print $0 ".ddev.site"
      next
    }
    in_hosts && /^[^ #]/ { exit }
  ' "$canonical_approot/.ddev/config.yaml"
}

wt_canonical_hosts_from_web() {
  local canonical_web=$1
  docker inspect "$canonical_web" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | awk -F= '/^DDEV_HOSTNAME=/{print $2}' | tr ',' '\n' | sed '/^$/d'
}

wt_canonical_hosts() {
  local canonical_approot canonical_name canonical_web
  canonical_approot=$(wt_canonical_approot)
  canonical_name=$(wt_canonical_name)
  canonical_web="ddev-${canonical_name}-web"
  if docker ps --format '{{.Names}}' | grep -qx "$canonical_web"; then
    wt_canonical_hosts_from_web "$canonical_web"
  else
    wt_canonical_hosts_from_config "$canonical_approot"
  fi
}

wt_caddy_image() {
  echo "generoi-wt-caddy:2.11"
}

wt_ensure_caddy_image() {
  local image approot
  image=$(wt_caddy_image)
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  approot=$(wt_approot)
  echo "generoi-worktree: building Caddy image with replace-response (one-time, ~1 min)..."
  docker build -f "${approot}/.ddev/generoi-worktree/Dockerfile.caddy" \
    -t "$image" "${approot}/.ddev/generoi-worktree"
}

wt_write_caddyfile() {
  local port=$1 web_container=$2 canonical_name=$3
  shift 3
  local -a canonical_hosts=("$@")
  local approot caddyfile cert key header_down_block replace_block host host_re

  approot=$(wt_approot)
  caddyfile="${approot}/.ddev/wt/Caddyfile"
  cert="/mnt/ddev-global-cache/traefik/certs/${canonical_name}.crt"
  key="/mnt/ddev-global-cache/traefik/certs/${canonical_name}.key"
  mkdir -p "${approot}/.ddev/wt"

  header_down_block=""
  replace_block=""
  for host in $(printf '%s\n' "${canonical_hosts[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-); do
    host_re=$(printf '%s' "$host" | sed 's/\./\\./g')
    header_down_block+="    header_down Location ^https://${host_re}(?::\\d+)?(.*)$ https://${host}:${port}\$1
    header_down Location ^http://${host_re}(?::\\d+)?(.*)$ http://${host}:${port}\$1
"
    replace_block+="    https://${host}/ https://${host}:${port}/
    https://${host}\" https://${host}:${port}\"
    http://${host}/ http://${host}:${port}/
    http://${host}\" http://${host}:${port}\"
"
  done

  cat >"$caddyfile" <<EOF
# generoi-worktree Caddy rewrite proxy (generated)
{
  auto_https off
}

:443 {
  tls ${cert} ${key}

  replace {
    stream
${replace_block}  }

  reverse_proxy ${web_container}:80 {
    header_up Accept-Encoding identity
    header_up Host {http.request.host}
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Port ${port}
${header_down_block}  }
}
EOF
  echo "generoi-worktree: wrote .ddev/wt/Caddyfile (:${port})"
}

wt_caddy_start() {
  local port=$1 network=$2 web_container=$3 project=$4
  local approot caddy caddyfile image
  approot=$(wt_approot)
  caddy=$(wt_caddy_container_name "$project")
  caddyfile="${approot}/.ddev/wt/Caddyfile"
  image=$(wt_caddy_image)

  wt_ensure_caddy_image
  docker rm -f "$caddy" >/dev/null 2>&1 || true

  docker run -d \
    --name "$caddy" \
    --network "$network" \
    --label "com.generoi.worktree=true" \
    --label "com.generoi.worktree-proxy=caddy" \
    --label "com.generoi.canonical=$(wt_canonical_name)" \
    --label "com.generoi.approot=${approot}" \
    --label "com.generoi.project=${project}" \
    -v "${caddyfile}:/etc/caddy/Caddyfile:ro" \
    -v "ddev-global-cache:/mnt/ddev-global-cache:ro" \
    -p "127.0.0.1:${port}:443" \
    "$image" \
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

  echo "generoi-worktree: Caddy proxy on 127.0.0.1:${port} -> ${web_container}"
}

wt_caddy_stop() {
  local caddy project
  if wt_read_state >/dev/null 2>&1; then
    caddy=$(wt_state_value caddy_container 2>/dev/null || true)
  fi
  if [[ -z "${caddy:-}" ]]; then
    project=$(wt_ddev_project_name 2>/dev/null || wt_project_name)
    caddy=$(wt_caddy_container_name "$project")
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$caddy"; then
    docker rm -f "$caddy" >/dev/null
    echo "generoi-worktree: stopped ${caddy}"
  fi
}

wt_bootstrap_links() {
  local canonical approot theme_public theme
  canonical=$(cd "$(wt_canonical_approot)" && pwd -P)
  approot=$(wt_approot)

  if [[ "$canonical" == "$approot" ]]; then
    return 0
  fi

  for rel in .env .env.local auth.json; do
    if [[ -e "$canonical/$rel" && ! -e "$approot/$rel" ]]; then
      ln -sf "$canonical/$rel" "$approot/$rel"
      echo "generoi-worktree: linked ${rel}"
    fi
  done

  for theme_public in "$canonical"/web/app/themes/*/public; do
    [[ -d "$theme_public" ]] || continue
    theme=$(basename "$(dirname "$theme_public")")
    local_rel="web/app/themes/${theme}/public"
    if [[ ! -e "$approot/$local_rel" ]]; then
      mkdir -p "$(dirname "$approot/$local_rel")"
      ln -sf "$theme_public" "$approot/$local_rel"
      echo "generoi-worktree: linked ${local_rel}"
    fi
  done

  local uploads="web/app/uploads"
  if [[ -d "$canonical/$uploads" && ! -e "$approot/$uploads" ]]; then
    mkdir -p "$(dirname "$approot/$uploads")"
    ln -sf "$canonical/$uploads" "$approot/$uploads"
    echo "generoi-worktree: linked ${uploads}"
  fi

  for generated in nginx_full/nginx-site.conf apache/apache-site.conf; do
    if [[ -f "$canonical/.ddev/$generated" ]]; then
      mkdir -p "$(dirname "$approot/.ddev/$generated")"
      cp -f "$canonical/.ddev/$generated" "$approot/.ddev/$generated"
      echo "generoi-worktree: copied .ddev/${generated}"
    fi
  done

  mkdir -p "$approot/.ddev/nginx"
  if [[ -f "$canonical/.ddev/nginx/redirect-uploads.conf" ]]; then
    cp -f "$canonical/.ddev/nginx/redirect-uploads.conf" "$approot/.ddev/nginx/redirect-uploads.conf"
    echo "generoi-worktree: copied .ddev/nginx/redirect-uploads.conf from canonical"
  fi
}

wt_write_local_config() {
  local name
  name=$(wt_project_name)
  mkdir -p "$(dirname "$WT_LOCAL_CONFIG")"
  cat >"$WT_LOCAL_CONFIG" <<EOF
# #ddev-generated
# generoi-worktree: unique DDEV project name for this git worktree.
name: ${name}
EOF
  echo "generoi-worktree: DDEV project name ${name} (${WT_LOCAL_CONFIG})"
}

wt_prepare() {
  wt_ensure_ddev_project
  if wt_is_canonical_checkout; then
    rm -f "$WT_LOCAL_CONFIG"
    return 0
  fi
  wt_write_local_config
  wt_bootstrap_links
}

wt_db_table_count() {
  wt_require ddev
  ddev mysql -sN -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='db'" 2>/dev/null \
    | tail -1
}

wt_db_is_empty() {
  local count
  count=$(wt_db_table_count 2>/dev/null || echo 0)
  [[ "${count:-0}" -eq 0 ]]
}

wt_seed_db_from_canonical() {
  local canonical canonical_name tmp
  wt_ensure_canonical_running
  canonical=$(wt_canonical_approot)
  canonical_name=$(wt_canonical_name)
  tmp=$(mktemp "${TMPDIR:-/tmp}/generoi-wt-db.XXXXXX.sql.gz")
  echo "generoi-worktree: cloning database from canonical '${canonical_name}' (no search-replace)..."
  (cd "$canonical" && ddev export-db --file="$tmp")
  ddev import-db --file="$tmp"
  rm -f "$tmp"
  echo "generoi-worktree: database seeded from canonical"
}

wt_seed_db_if_empty() {
  if wt_is_canonical_checkout; then
    return 0
  fi
  if ! wt_db_is_empty; then
    return 0
  fi
  wt_seed_db_from_canonical
}

wt_sync_db() {
  if wt_is_canonical_checkout; then
    echo "generoi-worktree: wt-sync-db is for worktrees only" >&2
    exit 1
  fi
  wt_seed_db_from_canonical
}

wt_post_start() {
  local project web_container network port canonical_name suffix approot
  local -a canonical_hosts=()
  local primary_host host_list url

  wt_ensure_ddev_project
  if wt_is_canonical_checkout; then
    return 0
  fi

  wt_require ddev
  wt_require jq
  wt_require docker

  project=$(wt_ddev_project_name)
  [[ -n "$project" ]] || {
    echo "generoi-worktree: could not read DDEV project name" >&2
    exit 1
  }

  web_container=$(wt_web_container "$project")
  network=$(wt_network_name "$project")
  canonical_name=$(wt_canonical_name)
  suffix=$(wt_suffix)
  approot=$(wt_approot)

  if ! docker ps --format '{{.Names}}' | grep -qx "$web_container"; then
    echo "generoi-worktree: web container ${web_container} is not running" >&2
    exit 1
  fi

  wt_seed_db_if_empty

  while IFS= read -r _host; do
    [[ -n "$_host" ]] && canonical_hosts+=("$_host")
  done < <(wt_canonical_hosts)
  primary_host="${canonical_hosts[0]}"

  port=$(wt_allocate_port "")
  wt_write_caddyfile "$port" "$web_container" "$canonical_name" "${canonical_hosts[@]}"
  wt_caddy_start "$port" "$network" "$web_container" "$project"

  url="https://${primary_host}:${port}"
  host_list=$(printf '%s,' "${canonical_hosts[@]}")
  host_list=${host_list%,}

  mkdir -p "$WT_STATE_DIR"
  jq -n \
    --arg caddy "$(wt_caddy_container_name "$project")" \
    --arg suffix "$suffix" \
    --arg canonical_name "$canonical_name" \
    --arg canonical_approot "$(wt_canonical_approot)" \
    --arg approot "$approot" \
    --arg project "$project" \
    --arg web_container "$web_container" \
    --arg primary "$primary_host" \
    --arg hostnames "$host_list" \
    --arg url "$url" \
    --argjson port "$port" \
    --argjson db_seeded true \
    '{
      caddy_container: $caddy,
      suffix: $suffix,
      canonical_name: $canonical_name,
      canonical_approot: $canonical_approot,
      approot: $approot,
      project: $project,
      web_container: $web_container,
      db_mode: "fork",
      db_seeded: $db_seeded,
      port: $port,
      primary_hostname: $primary,
      hostnames: $hostnames,
      url: $url
    }' >"$WT_STATE_FILE"

  echo "generoi-worktree: browse ${url}"
  if ((${#canonical_hosts[@]} > 1)); then
    echo "generoi-worktree: subsite example: https://${canonical_hosts[1]}:${port}"
  fi
  echo "WT_URL=${url}"
}

wt_pre_stop() {
  wt_ensure_ddev_project
  if wt_is_canonical_checkout; then
    return 0
  fi
  wt_caddy_stop
}

wt_install_js_deps() {
  local approot=$1
  [[ -f "$approot/package.json" ]] || return 0

  local pm
  if [[ -f "$approot/pnpm-lock.yaml" ]]; then
    wt_require pnpm
    pm=pnpm
    echo "generoi-worktree: pnpm install (uses global pnpm store)..."
    (cd "$approot" && pnpm install --frozen-lockfile)
  elif [[ -f "$approot/yarn.lock" ]]; then
    wt_require yarn
    pm=yarn
    echo "generoi-worktree: yarn install..."
    (cd "$approot" && yarn install --frozen-lockfile)
  elif [[ -f "$approot/package-lock.json" ]]; then
    wt_require npm
    pm=npm
    echo "generoi-worktree: npm ci..."
    (cd "$approot" && npm ci --no-audit --no-fund)
  else
    wt_require npm
    pm=npm
    echo "generoi-worktree: npm install..."
    (cd "$approot" && npm install --no-audit --no-fund)
  fi

  if grep -q '"build"' "$approot/package.json"; then
    echo "generoi-worktree: ${pm} run build..."
    (cd "$approot" && "$pm" run build)
  fi
}

wt_install_deps() {
  wt_require composer
  local approot
  approot=$(wt_approot)

  for rel in vendor web/wp; do
    if [[ -L "$approot/$rel" ]]; then
      rm "$approot/$rel"
      echo "generoi-worktree: removed symlink ${rel} (use local composer install)"
    fi
  done

  echo "generoi-worktree: composer install..."
  (cd "$approot" && composer install --no-interaction --prefer-dist)

  wt_install_js_deps "$approot"
}

# Legacy sidecar API (v0.1) — removed in v0.2; keep stubs for clearer errors.
wt_container_name() {
  wt_web_container
}

wt_sidecar_stop() {
  wt_caddy_stop
  rm -f "$WT_STATE_FILE"
}

wt_sidecar_start() {
  echo "generoi-worktree: wt-up was removed in v0.2; use 'ddev start' in this worktree." >&2
  exit 1
}
