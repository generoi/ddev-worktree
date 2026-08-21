# generoi-worktree

Install: `ddev add-on get generoi/ddev-worktree`

## v0.2 architecture

**Canonical:** normal `ddev start` — one MariaDB, Traefik URL.

**Git worktree:** `ddev start` — full DDEV project with a unique name (`herrfors-wt-<suffix>`), own MariaDB, Caddy on `:808x`.

```
Browser ──► Caddy (:808x) ──► ddev-<wt-project>-web:80
                                    │
                                    └── ddev-<wt-project>-db (forked from canonical)
```

**Caddy** strips `:port` from `Host` before PHP (`header_up Host {http.request.host}`), then `replace-response` adds `:808x` back in browser URLs.

**Database:** first `ddev start` in a worktree exports canonical `db` and imports into the worktree DB (no search-replace). Refresh manually with `ddev wt-sync-db`.

**Uploads / .env:** symlinked from canonical checkout on `wt-prepare` (shared on host).

## Hooks

| Hook | Action |
|------|--------|
| `pre-start` | `wt-prepare` — unique project name, bootstrap symlinks |
| `post-start` | `wt-post-start` — seed DB if empty, start Caddy |
| `pre-stop` | `wt-pre-stop` — stop Caddy |

## Usage

**Canonical:** `ddev start`

**Worktree:**

```bash
ddev start
ddev wt-port
ddev wt-sync-db   # optional: refresh DB from canonical
ddev stop
```
