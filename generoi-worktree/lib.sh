#!/usr/bin/env bash
# #ddev-generated: If you want to edit and own this file, remove this line.
# generoi-worktree shared helpers (sourced by ddev host commands)

set -euo pipefail

WT_STATE_DIR=".ddev/wt"
WT_STATE_FILE="${WT_STATE_DIR}/state.json"
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

wt_container_name() {
  local name suffix
  name=$(wt_canonical_name)
  suffix=$(wt_suffix)
  echo "ddev-${name}-wt-${suffix}"
}

wt_caddy_container_name() {
  echo "$(wt_container_name)-caddy"
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
  if ! docker ps --format '{{.Names}}' | grep -qx "ddev-${name}-web"; then
    echo "generoi-worktree: canonical web container is not running; run 'ddev start' in ${canonical_approot}" >&2
    exit 1
  fi
}

wt_network_name() {
  echo "ddev-$(wt_canonical_name)_default"
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

wt_canonical_hosts() {
  local canonical_web=$1
  docker inspect "$canonical_web" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | awk -F= '/^DDEV_HOSTNAME=/{print $2}' | tr ',' '\n' | sed '/^$/d'
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
  local port=$1 network=$2
  local approot caddy caddyfile image
  approot=$(wt_approot)
  caddy=$(wt_caddy_container_name)
  caddyfile="${approot}/.ddev/wt/Caddyfile"
  image=$(wt_caddy_image)

  wt_ensure_caddy_image

  docker rm -f "$caddy" >/dev/null 2>&1 || true

  docker run -d \
    --name "$caddy" \
    --network "$network" \
    --label "com.generoi.worktree=true" \
    --label "com.generoi.worktree-proxy=caddy" \
    -v "${caddyfile}:/etc/caddy/Caddyfile:ro" \
    -v "ddev-global-cache:/mnt/ddev-global-cache:ro" \
    -p "127.0.0.1:${port}:443" \
    "$image" \
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

  echo "generoi-worktree: Caddy proxy on 127.0.0.1:${port} -> $(wt_container_name)"
}

wt_bootstrap_links() {
  local canonical approot theme_public theme
  canonical=$(cd "$(wt_canonical_approot)" && pwd -P)
  approot=$(wt_approot)

  if [[ "$canonical" == "$approot" ]]; then
    echo "generoi-worktree: bootstrap skipped on canonical checkout"
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

wt_sidecar_running() {
  docker ps --format '{{.Names}}' | grep -qx "$(wt_container_name)"
}

wt_sidecar_stop() {
  local container caddy
  container=$(wt_container_name)
  caddy=$(wt_caddy_container_name)
  docker rm -f "$caddy" >/dev/null 2>&1 || true
  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    docker rm -f "$container" >/dev/null
    echo "generoi-worktree: stopped ${container}"
  fi
  rm -f "$WT_STATE_FILE"
}

wt_sidecar_volume_args() {
  local approot canonical_approot theme_public theme
  approot=$(wt_approot)
  canonical_approot=$(cd "$(wt_canonical_approot)" && pwd -P)

  local -a volume_args=(
    -v "${approot}:/var/www/html:cached"
    -v "${approot}/.ddev:/mnt/ddev_config:ro"
    -v "ddev-global-cache:/mnt/ddev-global-cache"
    -v "ddev-ssh-agent_socket_dir:/home/.ssh-agent"
  )

  for rel in web/app/uploads .env .env.local auth.json; do
    if [[ -e "${canonical_approot}/${rel}" ]]; then
      volume_args+=(-v "${canonical_approot}/${rel}:/var/www/html/${rel}:ro")
    fi
  done

  for theme_public in "${canonical_approot}"/web/app/themes/*/public; do
    [[ -d "$theme_public" ]] || continue
    theme=$(basename "$(dirname "$theme_public")")
    local_rel="web/app/themes/${theme}/public"
    if [[ ! -e "${approot}/${local_rel}" ]] || [[ -L "${approot}/${local_rel}" ]]; then
      volume_args+=(-v "${theme_public}:/var/www/html/${local_rel}:ro")
    fi
  done

  printf '%s\n' "${volume_args[@]}"
}

wt_sidecar_wait_healthy() {
  local container=$1
  echo "generoi-worktree: waiting for sidecar health..."
  local ready=0 i
  for i in $(seq 1 45); do
    if docker ps --filter "name=${container}" --filter status=running --format '{{.Status}}' | grep -q healthy; then
      ready=1
      break
    fi
    sleep 2
  done
  if [[ $ready -ne 1 ]]; then
    echo "generoi-worktree: sidecar not healthy within 90s" >&2
    exit 1
  fi
}

wt_sidecar_start() {
  local requested_port=${1:-}
  local suffix canonical_web image network container approot canonical_name primary_host
  local env_file port

  suffix=$(wt_suffix)
  canonical_name=$(wt_canonical_name)
  canonical_web="ddev-${canonical_name}-web"
  image=$(docker inspect "$canonical_web" --format '{{.Config.Image}}')
  network=$(wt_network_name)
  container=$(wt_container_name)
  approot=$(wt_approot)
  port=$(wt_allocate_port "$requested_port")

  local canonical_hosts=()
  while IFS= read -r _host; do
    [[ -n "$_host" ]] && canonical_hosts+=("$_host")
  done < <(wt_canonical_hosts "$canonical_web")
  primary_host="${canonical_hosts[0]}"

  wt_sidecar_stop >/dev/null 2>&1 || true

  env_file=$(mktemp "${TMPDIR:-/tmp}/generoi-wt-env.XXXXXX")
  docker inspect "$canonical_web" --format '{{range .Config.Env}}{{println .}}{{end}}' >"$env_file"
  {
    echo "GENEROI_WT=1"
    echo "GENEROI_WT_PORT=${port}"
    echo "DDEV_APPROOT=/var/www/html"
    echo "DDEV_COMPOSER_ROOT=/var/www/html"
    echo "DDEV_PRIMARY_URL=https://${primary_host}:${port}"
    echo "DDEV_SCHEME=https"
    echo "DDEV_HOSTNAME=$(grep '^DDEV_HOSTNAME=' "$env_file" | head -1 | cut -d= -f2-)"
  } >>"$env_file"

  wt_write_caddyfile "$port" "$container" "$canonical_name" "${canonical_hosts[@]}"

  local -a volume_args=()
  while IFS= read -r vol; do
    volume_args+=("$vol")
  done < <(wt_sidecar_volume_args)

  docker run -d \
    --name "$container" \
    --network "$network" \
    --user "501:20" \
    --label "com.generoi.worktree=true" \
    --label "com.generoi.canonical=${canonical_name}" \
    --label "com.generoi.approot=${approot}" \
    --env-file "$env_file" \
    "${volume_args[@]}" \
    "$image" >/dev/null

  rm -f "$env_file"

  wt_sidecar_wait_healthy "$container"
  wt_caddy_start "$port" "$network"

  local url="https://${primary_host}:${port}"
  local host_list
  host_list=$(docker inspect "$canonical_web" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | awk -F= '/^DDEV_HOSTNAME=/{print $2; exit}')

  mkdir -p "$WT_STATE_DIR"
  jq -n \
    --arg container "$container" \
    --arg caddy "$(wt_caddy_container_name)" \
    --arg suffix "$suffix" \
    --arg canonical_name "$canonical_name" \
    --arg canonical_approot "$(wt_canonical_approot)" \
    --arg approot "$approot" \
    --arg primary "$primary_host" \
    --arg hostnames "$host_list" \
    --arg url "$url" \
    --argjson port "$port" \
    '{
      container: $container,
      caddy_container: $caddy,
      suffix: $suffix,
      db_name: "db",
      canonical_name: $canonical_name,
      canonical_approot: $canonical_approot,
      approot: $approot,
      db_mode: "shared",
      port: $port,
      primary_hostname: $primary,
      hostnames: $hostnames,
      url: $url
    }' >"$WT_STATE_FILE"

  echo "generoi-worktree: sidecar ${container} at ${url}"
  if ((${#canonical_hosts[@]} > 1)); then
    echo "generoi-worktree: subsite example: https://${canonical_hosts[1]}:${port}"
  fi
  echo "WT_URL=${url}"
}
