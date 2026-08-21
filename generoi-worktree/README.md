# generoi-worktree (DDEV add-on)

Install: `ddev add-on get generoi/ddev-worktree`

Worktree sidecars for Bedrock sites: reuse the canonical DDEV web image + **shared
MariaDB**, browse on `https://<canonical-host>:808x` while PHP/DB keep canonical
hostnames.

Edge **Caddy** (custom image with `replace-response`) rewrites `Location` headers and
response bodies. No nginx `sub_filter`. Minimal Bedrock hook: `config/environments/wt.php`.

## Canonical checkout (daily dev)

```bash
ddev start
robo db:pull @production   # when needed
```

## Git worktree (agents / parallel branches)

```bash
git worktree add ../herrfors-my-branch my-branch
cd ../herrfors-my-branch

ddev wt-up                 # shared db + Caddy :808x (default)
ddev wt-port               # WT_URL, WT_PORT
ddev wt-wp plugin list
ddev wt-down
```

`ddev start` is blocked in worktrees (`wt-guard` pre-start hook).

## URLs (default: `--db=shared`)

- https://herrfors.ddev.site:8081 (first free port in 8081–8099)
- https://nat.herrfors.ddev.site:8081 (multisite subsite)

Canonical Traefik (`https://herrfors.ddev.site`) stays on the main checkout.

## Options

```bash
ddev wt-up                      # shared db + Caddy rewrite (default)
ddev wt-up --db=clone           # cloned db + Traefik wt hostnames (full isolation)
ddev wt-up --db=refresh         # re-clone db (implies clone)
ddev wt-up --port=8083          # pin host port (shared mode)
ddev wt-up --no-deps            # skip composer/npm
```

**Clone mode** (`--db=clone`): per-worktree DB, Traefik routes on
`herrfors-wt-<hash>.ddev.site`, `wp search-replace` — no Caddy, no shared DB.

## Bootstrap

**From canonical (symlinks):** `.env`, `.env.local`, `auth.json`, `web/app/uploads`,
theme `public/` dirs until you run `npm run build` in the worktree.

**Local install (default on `wt-up`):** `composer install` + JS deps in the worktree.

| Lockfile | Command | Worktree cost |
|----------|---------|---------------|
| `pnpm-lock.yaml` | `pnpm install` | Hardlinks from global store (~composer-like) |
| `package-lock.json` | `npm ci` | Full `node_modules/` copy per worktree (~1 GB here) |

## Extract to generoi/ddev-worktree

Published as [generoi/ddev-worktree](https://github.com/generoi/ddev-worktree). Install with `ddev add-on get generoi/ddev-worktree`.
