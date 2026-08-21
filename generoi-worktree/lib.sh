#!/usr/bin/env bash
# generoi-worktree shared helpers (sourced by ddev host commands)

set -euo pipefail

WT_STATE_DIR=".ddev/wt"
WT_STATE_FILE="${WT_STATE_DIR}/state.json"
WT_PORT_MIN=8081
WT_PORT_MAX=8099
DDEV_GLOBAL_CACHE_VOLUME=ddev-global-cache

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

wt_project_name() {
  awk '/^name:[[:space:]]*/ {print $2; exit}' .ddev/config.yaml
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

wt_db_container() {
  echo "ddev-$(wt_canonical_name)-db"
}

wt_db_clone_name() {
  echo "db_wt_$(wt_suffix)"
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
  if ! docker ps --format '{{.Names}}' | grep -qx "ddev-router"; then
    echo "generoi-worktree: ddev-router is not running; run 'ddev start' in the canonical checkout" >&2
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

wt_write_state() {
  mkdir -p "$WT_STATE_DIR"
  cat >"$WT_STATE_FILE"
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

wt_map_host() {
  local host=$1 primary=$2 suffix=$3
  local project="${primary%%.ddev.site}"
  local wt_network="${project}-wt-${suffix}.ddev.site"

  if [[ "$host" == "$primary" ]]; then
    echo "$wt_network"
    return
  fi
  if [[ "$host" == *".${primary}" ]]; then
    local sub="${host%.${primary}}"
    echo "${sub}.${wt_network}"
    return
  fi
  echo "$host"
}

wt_global_cache() {
  local script=$1
  docker run --rm -i -v "${DDEV_GLOBAL_CACHE_VOLUME}:/cache" alpine:3 sh -s <<EOF
$script
EOF
}

wt_traefik_config_path() {
  local suffix=$1
  echo "/cache/traefik/config/generoi-wt-${suffix}.yaml"
}

wt_traefik_write() {
  local suffix=$1 container=$2
  shift 2
  local -a wt_hosts=("$@")
  local host_rules=""
  local host

  for host in "${wt_hosts[@]}"; do
    if [[ -n "$host_rules" ]]; then
      host_rules+=" || "
    fi
    host_rules+="Host(\`${host}\`)"
  done

  local tmp_yaml
  tmp_yaml=$(mktemp "${TMPDIR:-/tmp}/generoi-wt-traefik.XXXXXX.yaml")
  cat >"$tmp_yaml" <<EOF
# generoi-worktree sidecar (generated; do not edit)
http:
  routers:
    generoi-wt-${suffix}-https:
      entrypoints:
        - http-443
      rule: ${host_rules}
      service: generoi-wt-${suffix}-web
      tls: true
  services:
    generoi-wt-${suffix}-web:
      loadbalancer:
        servers:
          - url: http://${container}:80

tls:
  certificates:
    - certFile: /cache/traefik/certs/generoi-wt-${suffix}.crt
      keyFile: /cache/traefik/certs/generoi-wt-${suffix}.key
EOF

  docker run --rm \
    -v "${DDEV_GLOBAL_CACHE_VOLUME}:/cache" \
    -v "${tmp_yaml}:/tmp/wt.yaml:ro" \
    alpine:3 cp /tmp/wt.yaml "/cache/traefik/config/generoi-wt-${suffix}.yaml"
  rm -f "$tmp_yaml"
  echo "generoi-worktree: registered Traefik route for ${wt_hosts[*]}"
}

wt_traefik_remove() {
  local suffix=$1
  wt_global_cache "rm -f /cache/traefik/config/generoi-wt-${suffix}.yaml /cache/traefik/certs/generoi-wt-${suffix}.crt /cache/traefik/certs/generoi-wt-${suffix}.key"
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
    header_down_block+="    header_down Location ^https://${host_re}(.*)$ https://${host}:${port}\$1
    header_down Location ^http://${host_re}(.*)$ http://${host}:${port}\$1
"
    replace_block+="    https://${host}/ https://${host}:${port}/
    https://${host}\" https://${host}:${port}\"
    https://${host} https://${host}:${port}
    http://${host}/ http://${host}:${port}/
    http://${host}\" http://${host}:${port}\"
    http://${host} http://${host}:${port}
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
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Port ${port}
${header_down_block}  }
}
EOF
  echo "generoi-worktree: wrote .ddev/wt/Caddyfile (shared DB, :${port})"
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

wt_ensure_tls_certs() {
  local suffix=$1 wt_primary=$2 canonical_name=$3
  local web cert key
  web="ddev-${canonical_name}-web"
  cert="/mnt/ddev-global-cache/traefik/certs/generoi-wt-${suffix}.crt"
  key="/mnt/ddev-global-cache/traefik/certs/generoi-wt-${suffix}.key"

  if docker exec "$web" test -f "$cert" 2>/dev/null; then
    echo "generoi-worktree: reusing DDEV mkcert cert for ${wt_primary}"
    return 0
  fi

  echo "generoi-worktree: mkcert via DDEV CA: ${wt_primary} + *.${wt_primary}"
  docker exec "$web" mkcert -cert-file "$cert" -key-file "$key" \
    "${wt_primary}" "*.${wt_primary}"
}

wt_db_clone() {
  local refresh=${1:-false}
  local clone_db db_container
  clone_db=$(wt_db_clone_name)
  db_container=$(wt_db_container)

  local exists
  exists=$(docker exec "$db_container" mysql -uroot -proot -N -e \
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${clone_db}'" 2>/dev/null || true)

  if [[ -n "$exists" && "$refresh" != true ]]; then
    echo "generoi-worktree: reusing cloned database ${clone_db}"
    return 0
  fi

  if [[ -n "$exists" && "$refresh" == true ]]; then
    echo "generoi-worktree: refreshing cloned database ${clone_db}..."
    docker exec "$db_container" mysql -uroot -proot -e "DROP DATABASE \`${clone_db}\`;"
  else
    echo "generoi-worktree: cloning canonical db -> ${clone_db}..."
  fi

  docker exec "$db_container" mysql -uroot -proot -e "CREATE DATABASE \`${clone_db}\`;"
  docker exec "$db_container" mysqldump -uroot -proot --single-transaction db \
    | docker exec -i "$db_container" mysql -uroot -proot "$clone_db"
}

wt_db_urls_replaced() {
  local clone_db wt_primary
  clone_db=$(wt_db_clone_name)
  wt_primary=$(wt_state_value primary_hostname 2>/dev/null || true)
  [[ -n "$wt_primary" ]] || return 1

  local home
  home=$(docker exec "$(wt_db_container)" mysql -uroot -proot -N -e \
    "SELECT option_value FROM \`${clone_db}\`.wp_options WHERE option_name='home' LIMIT 1" 2>/dev/null || true)
  [[ "$home" == *"${wt_primary}"* ]]
}

wt_db_url_replace() {
  local suffix=$1 primary=$2
  shift 2
  local -a canonical_hosts=("$@")
  local container host from to

  container=$(wt_container_name)

  for host in $(printf '%s\n' "${canonical_hosts[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-); do
    to=$(wt_map_host "$host" "$primary" "$suffix")
    for scheme in https http; do
      from="${scheme}://${host}"
      to_url="${scheme}://${to}"
      echo "generoi-worktree: wp search-replace ${from} -> ${to_url}"
      docker exec "$container" bash -lc "cd /var/www/html && wp --path=web/wp search-replace '${from}' '${to_url}' --all-tables --precise --report-changed-only" \
        || true
    done
    to=$(wt_map_host "$host" "$primary" "$suffix")
    echo "generoi-worktree: wp search-replace domain ${host} -> ${to}"
    docker exec "$container" bash -lc "cd /var/www/html && wp --path=web/wp search-replace '${host}' '${to}' --all-tables --precise --report-changed-only" \
      || true
  done
}

wt_bootstrap_links() {
  local canonical approot
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

  local theme
  for theme in gds herrforsnat; do
    local theme_public="web/app/themes/${theme}/public"
    if [[ -d "$canonical/$theme_public" && ! -e "$approot/$theme_public" ]]; then
      mkdir -p "$(dirname "$approot/$theme_public")"
      ln -sf "$canonical/$theme_public" "$approot/$theme_public"
      echo "generoi-worktree: linked ${theme_public}"
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
  cat >"$approot/.ddev/nginx/redirect-uploads.conf" <<'EOF'
# generoi-worktree: local 404 for missing uploads (no prod redirect)
location ^~ /app/uploads/ {
    absolute_redirect off;
    try_files $uri =404;
}
EOF
  echo "generoi-worktree: wrote .ddev/nginx/redirect-uploads.conf (local 404)"

  rm -f "$approot/web/app/sunrise.php" \
    "$approot/web/app/mu-plugins/generoi-worktree-sidecar.php" \
    "$approot/config/worktree-sidecar.php" 2>/dev/null || true
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
    echo "generoi-worktree: yarn install (uses global yarn cache)..."
    (cd "$approot" && yarn install --frozen-lockfile)
  elif [[ -f "$approot/package-lock.json" ]]; then
    wt_require npm
    pm=npm
    echo "generoi-worktree: npm ci (uses global npm cache; full node_modules per worktree)..."
    (cd "$approot" && npm ci --no-audit --no-fund)
  else
    wt_require npm
    pm=npm
    echo "generoi-worktree: npm install..."
    (cd "$approot" && npm install --no-audit --no-fund)
  fi

  if grep -q '"build"' "$approot/package.json"; then
    echo "generoi-worktree: ${pm} run build (workspace assets)..."
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

  echo "generoi-worktree: composer install (uses global Composer cache)..."
  (cd "$approot" && composer install --no-interaction --prefer-dist)

  wt_install_js_deps "$approot"
}

wt_sidecar_running() {
  docker ps --format '{{.Names}}' | grep -qx "$(wt_container_name)"
}

wt_sidecar_stop() {
  local container caddy suffix
  container=$(wt_container_name)
  caddy=$(wt_caddy_container_name)
  suffix=$(wt_suffix)
  docker rm -f "$caddy" >/dev/null 2>&1 || true
  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    docker rm -f "$container" >/dev/null
    echo "generoi-worktree: stopped ${container}"
  fi
  wt_traefik_remove "$suffix" 2>/dev/null || true
  rm -f "$(wt_approot)/.ddev/nginx/generoi-wt-rewrite.conf" 2>/dev/null || true
  rm -f "$WT_STATE_FILE"
}

wt_sidecar_volume_args() {
  local approot canonical_approot
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

  local theme
  for theme in gds herrforsnat; do
    local theme_public="web/app/themes/${theme}/public"
    if [[ -d "${canonical_approot}/${theme_public}" ]]; then
      if [[ ! -e "${approot}/${theme_public}" ]] || [[ -L "${approot}/${theme_public}" ]]; then
        volume_args+=(-v "${canonical_approot}/${theme_public}:/var/www/html/${theme_public}:ro")
      fi
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

wt_sidecar_start_shared() {
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

  echo "generoi-worktree: sidecar ${container} (shared db) at ${url}"
  if ((${#canonical_hosts[@]} > 1)); then
    echo "generoi-worktree: subsite example: https://${canonical_hosts[1]}:${port}"
  fi
  echo "WT_URL=${url}"
}

wt_sidecar_start_clone() {
  local db_refresh=${1:-false}
  local suffix canonical_web image network container approot canonical_name
  local primary_host clone_db wt_primary wt_hosts=()

  suffix=$(wt_suffix)
  canonical_name=$(wt_canonical_name)
  canonical_web="ddev-${canonical_name}-web"
  image=$(docker inspect "$canonical_web" --format '{{.Config.Image}}')
  network=$(wt_network_name)
  container=$(wt_container_name)
  approot=$(wt_approot)
  clone_db=$(wt_db_clone_name)

  local env_file
  env_file=$(mktemp "${TMPDIR:-/tmp}/generoi-wt-env.XXXXXX")
  docker inspect "$canonical_web" --format '{{range .Config.Env}}{{println .}}{{end}}' >"$env_file"
  primary_host=$(grep '^DDEV_HOSTNAME=' "$env_file" | head -1 | cut -d= -f2 | cut -d, -f1)

  local canonical_hosts=()
  while IFS= read -r _host; do
    [[ -n "$_host" ]] && canonical_hosts+=("$_host")
  done < <(wt_canonical_hosts "$canonical_web")
  wt_primary=$(wt_map_host "$primary_host" "$primary_host" "$suffix")
  for host in "${canonical_hosts[@]}"; do
    wt_hosts+=("$(wt_map_host "$host" "$primary_host" "$suffix")")
  done
  local wt_host_list
  wt_host_list=$(IFS=,; echo "${wt_hosts[*]}")

  wt_sidecar_stop >/dev/null 2>&1 || true

  wt_db_clone "$db_refresh"

  {
    echo "DDEV_APPROOT=/var/www/html"
    echo "DDEV_COMPOSER_ROOT=/var/www/html"
    echo "DDEV_PRIMARY_URL=https://${wt_primary}"
    echo "DDEV_SCHEME=https"
    echo "DDEV_HOSTNAME=${wt_host_list}"
    echo "WP_HOME=https://${wt_primary}"
    echo "WP_SITEURL=https://${wt_primary}/wp"
    echo "DOMAIN_CURRENT_SITE=${wt_primary}"
    echo "DB_NAME=${clone_db}"
  } >>"$env_file"

  wt_ensure_tls_certs "$suffix" "$wt_primary" "$canonical_name"
  wt_traefik_write "$suffix" "$container" "${wt_hosts[@]}"

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

  docker network connect ddev_default "$container" 2>/dev/null || {
    echo "generoi-worktree: failed to attach sidecar to ddev_default (is ddev-router running?)" >&2
    exit 1
  }

  rm -f "$env_file"

  jq -n \
    --arg container "$container" \
    --arg suffix "$suffix" \
    --arg clone_db "$clone_db" \
    --arg canonical_name "$canonical_name" \
    --arg canonical_approot "$(wt_canonical_approot)" \
    --arg approot "$approot" \
    --arg wt_primary "$wt_primary" \
    --arg hostnames "$wt_host_list" \
    --arg url "https://${wt_primary}" \
    '{
      container: $container,
      suffix: $suffix,
      db_name: $clone_db,
      canonical_name: $canonical_name,
      canonical_approot: $canonical_approot,
      approot: $approot,
      db_mode: "clone",
      primary_hostname: $wt_primary,
      hostnames: $hostnames,
      url: $url
    }' >"$WT_STATE_FILE"

  wt_sidecar_wait_healthy "$container"

  if ! wt_db_urls_replaced; then
    wt_db_url_replace "$suffix" "$primary_host" "${canonical_hosts[@]}"
  else
    echo "generoi-worktree: cloned DB URLs already point at worktree hostnames"
  fi

  echo "generoi-worktree: sidecar ${container} on https://${wt_primary}"
  echo "generoi-worktree: hostnames: ${wt_host_list}"
  if ((${#wt_hosts[@]} > 1)); then
    echo "generoi-worktree: subsite example: https://${wt_hosts[1]}"
  fi
  echo "WT_URL=https://${wt_primary}"
}

wt_sidecar_start() {
  local db_mode=${1:-shared}
  local db_refresh=${2:-false}
  local port=${3:-}

  case "$db_mode" in
    shared)
      wt_sidecar_start_shared "$port"
      ;;
    clone)
      wt_sidecar_start_clone "$db_refresh"
      ;;
    *)
      echo "generoi-worktree: unknown db mode: ${db_mode} (use shared or clone)" >&2
      exit 1
      ;;
  esac
}
