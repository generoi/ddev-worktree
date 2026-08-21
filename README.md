# generoi/ddev-worktree

DDEV add-on for parallel [git worktree](https://git-scm.com/docs/git-worktree) development on Genero Bedrock sites.

Shared MariaDB by default; Caddy (`replace-response`) rewrites browser URLs to `:808x` while PHP/DB keep canonical DDEV hostnames.

## Install

```bash
ddev add-on get generoi/ddev-worktree --version v0.1.1
```

If the add-on registry lookup fails, use the release tarball directly:

```bash
ddev add-on get https://github.com/generoi/ddev-worktree/tarball/v0.1.1
```

Or from a local checkout while developing the add-on:

```bash
ddev add-on get /path/to/ddev-worktree
```

## Project setup (Bedrock)

1. **`.ddev/config.yaml`** — block `ddev start` in worktrees:

```yaml
hooks:
  pre-start:
    - exec-host: "bash .ddev/commands/host/wt-guard"
```

2. **`config/application.php`** — before URL constants, normalize proxy host headers:

```php
if (! empty($_SERVER['HTTP_HOST'])) {
    $_SERVER['HTTP_HOST'] = preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']);
}
if (! empty($_SERVER['HTTP_X_FORWARDED_PORT'])) {
    $_SERVER['SERVER_PORT'] = $_SERVER['HTTP_X_FORWARDED_PORT'];
}
```

3. **`.gitignore`** — `.ddev/wt/` (generated Caddyfile + state).

5. **Multisite** — list subsite hostnames in `additional_hostnames` (e.g. `nat.herrfors`).

## Usage

**Canonical checkout:** `ddev start`

**Git worktree:**

```bash
git worktree add ../myproject-feature feature-branch
cd ../myproject-feature
ddev wt-up
ddev wt-port
ddev wt-down
```

| Command | Description |
|---------|-------------|
| `ddev wt-up` | Shared DB + Caddy on `:808x` |
| `ddev wt-up --port=8083` | Pin host port |
| `ddev wt-up --no-deps` | Skip composer/pnpm |
| `ddev wt-port` | Print `WT_URL` / `WT_PORT` |
| `ddev wt-wp …` | WP-CLI in sidecar |
| `ddev wt-list` | Running sidecars |
| `ddev wt-down` | Stop sidecar + Caddy |

See [generoi-worktree/README.md](generoi-worktree/README.md) for architecture details.

## Acceptance tests

From a git worktree checkout (canonical DDEV running):

```bash
bash .ddev/generoi-worktree/test-acceptance.sh
```
