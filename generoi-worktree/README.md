# generoi-worktree

Install: `ddev add-on get generoi/ddev-worktree`

Worktree sidecars for Bedrock sites: reuse the canonical DDEV web image + **shared
MariaDB**, browse on `https://<canonical-host>:808x` while PHP/DB keep canonical
hostnames.

**Caddy** (`replace-response`) rewrites `Location` headers and response bodies.
Minimal Bedrock hook: `config/environments/wt.php`.

## Usage

**Canonical:** `ddev start`

**Worktree:**

```bash
ddev wt-up
ddev wt-port
ddev wt-down
```

| Flag | Description |
|------|-------------|
| `--port=808x` | Pin host port (default: first free 8081–8099) |
| `--no-deps` | Skip composer/pnpm install |

## Bootstrap

Symlinks from canonical: `.env`, uploads, theme `public/` dirs.

Local per worktree: `composer install`, `pnpm install` (or npm/yarn from lockfile).
