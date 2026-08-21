# generoi/ddev-worktree

DDEV add-on for parallel [git worktree](https://git-scm.com/docs/git-worktree) development on Genero Bedrock sites.

**v0.2:** `ddev start` in worktrees — own MariaDB (cloned from canonical on first start, no search-replace), shared uploads via symlinks, Caddy on `:808x` for canonical browser URLs.

## Install

```bash
ddev add-on get generoi/ddev-worktree
```

Or from a local checkout while developing the add-on:

```bash
ddev add-on get /path/to/ddev-worktree
```

## Project setup (Bedrock)

Add to `.gitignore`:

```
.ddev/wt/
.ddev/config.generoi-worktree.local.yaml
.ddev/generoi-worktree/
.ddev/commands/host/wt-*
.ddev/addon-metadata/generoi-worktree/
```

Multisite: list subsite hostnames in `additional_hostnames` (e.g. `nat.herrfors`).

No Bedrock changes — Caddy sends `{http.request.host}` to PHP and rewrites `:808x` into browser responses.

## Usage

**Canonical checkout:**

```bash
ddev start
# https://herrfors.ddev.site
```

**Git worktree:**

```bash
git worktree add ../myproject-feature feature-branch
cd ../myproject-feature
ddev start
# https://herrfors.ddev.site:808x (Caddy proxy; own DB forked from canonical on first start)
ddev wt-port
ddev stop
```

| Command | Description |
|---------|-------------|
| `ddev start` | Worktree: full DDEV + Caddy `:808x` + DB seed (first time) |
| `ddev wt-port` | Print `WT_URL` / `WT_PORT` |
| `ddev wt-sync-db` | Re-clone DB from canonical (manual) |
| `ddev wt-list` | Running Caddy proxies |
| `ddev wt-down` | Stop Caddy only (web/db keep running) |

Removed in v0.2: `wt-up`, `wt-guard`, `wt-wp` — use `ddev start` and `ddev wp`.

## Acceptance tests

From a git worktree checkout (canonical DDEV running):

```bash
bash .ddev/generoi-worktree/test-acceptance.sh
```

See [generoi-worktree/README.md](generoi-worktree/README.md) for architecture details.
