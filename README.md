# quickhost

GitHub-Pages-style hosting on your own server. Point it at a repo and it comes up at
`https://<repo-name>.whittleadams.com`, with HTTPS, zero-downtime redeploys, and rollback.

```
$ quickhost deploy NiceWorkLad/Ball-Game
→ Fetching https://github.com/NiceWorkLad/Ball-Game.git
→ Checking louislab.duckdns.org
→ Building quickhost/ball-game:20261110143000-5af19fc on louislab.duckdns.org (static)
→ Starting qh-ball-game-20261110143000-5af19fc
→ Routing https://ball-game.whittleadams.com → qh-ball-game-20261110143000-5af19fc

✓ Live at https://ball-game.whittleadams.com
```

## How it works

It reuses the **kamal-proxy** that Kamal already runs on srv-01 for TaskTrackFlow, so it sits
alongside your Kamal apps without touching them.

1. Copies the repo into a temporary build folder with a generated `Dockerfile` and `nginx.conf`.
2. Streams that folder over SSH and runs `docker build` **on the server**, so there's no registry
   and you don't need Docker on your laptop. It needs only `ruby`, `ssh`, `tar` and `git`.
3. Starts a small nginx container on the `kamal` Docker network.
4. Runs `kamal-proxy deploy qh-<name> --host <name>.whittleadams.com --tls`. kamal-proxy waits
   for the new container's `/up` health check, switches traffic, and gets a Let's Encrypt cert.
5. Removes the old container and keeps the last 3 images so you can roll back.

If the build or health check fails, the new container is thrown away and the current site
keeps serving.

## One-time setup

**1. DNS (Namecheap).** Add a wildcard record so every subdomain reaches your home IP:

| Type | Host | Value |
|------|------|-------|
| A    | `*`  | your public IP (the same one tasktrackflow.com points at) |

Ports 80 and 443 are already forwarded to srv-01 for TaskTrackFlow, so certificates work
straight away.

**2. Install the CLI** on whatever machine you deploy from:

```bash
git clone <this repo> ~/code/quickhost
ln -s ~/code/quickhost/bin/quickhost ~/.local/bin/quickhost   # anywhere on your PATH
quickhost init --server louislab.duckdns.org --base-domain whittleadams.com
quickhost doctor
```

`doctor` checks SSH, Docker, kamal-proxy, the `kamal` network, and wildcard DNS.

SSH must work without a password prompt (key auth, which srv-01 already uses). If `srv-01`
doesn't resolve from your laptop, use its LAN IP or an alias in `~/.ssh/config`.

## Usage

```bash
quickhost deploy                       # current folder → <folder-name>.whittleadams.com
quickhost deploy ~/code/my-site        # any local folder
quickhost deploy NiceWorkLad/Ball-Game # GitHub shorthand (cloned fresh)
quickhost deploy https://github.com/NiceWorkLad/Ball-Game.git --branch gh-pages
quickhost deploy --branch dev          # another branch of the local repo, without checking it out
quickhost deploy --branch dev --name ball-game-dev   # …as a separate preview site

quickhost deploy --name keepup         # → keepup.whittleadams.com
quickhost deploy --domain games.example.com   # any hostname you own; point its DNS at your IP first
quickhost deploy --dry-run             # show the server commands, change nothing

quickhost list                         # every site, URL, version, status
quickhost logs ball-game -f            # nginx access log
quickhost rollback ball-game           # back to the previous version
quickhost rollback ball-game --to 20261110143000-5af19fc
quickhost remove ball-game             # take it offline and delete images
quickhost hub                          # link page of every site → sites.whittleadams.com
```

### The hub page

`quickhost hub` builds a link-tree page of everything kamal-proxy is routing: quickhost sites
and Kamal apps alike. Each card uses the site's own `<title>` and meta description, and shows
whether it answered when the page was built. Rerun it after deploying or removing a site.

```bash
quickhost hub                  # deploy to sites.whittleadams.com
quickhost hub --name links     # → links.whittleadams.com (or set hub_name in the config)
quickhost hub --out hub.html   # just write the page locally to preview it
```

Leave sites off with `hub_hide` in `~/.config/quickhost/config.yml` (site name, host or subdomain):

```yaml
hub_hide: [diary, deadlock-meta]
```

Change a card's wording with `hub_sites`, keyed the same way. `description: ""` removes the
site's own description.

```yaml
hub_sites:
  map:
    title: Minecraft Map
    description: Live 3D map of our server
```

### What gets served

Detected automatically, in this order:

| Repo has | What happens |
|---|---|
| `--build "<cmd>"` | Runs the command in `node:22-alpine`, then serves `--dir` or the first of `dist/ build/ out/ _site/ public/` that has an `index.html` |
| `package.json` with a `build` script | Installs with npm / pnpm / yarn / bun (picked from the lockfile), runs the build, then serves the output as above |
| `index.html` in the root | Serves the repo as-is |
| `docs/index.html` | Serves `docs/` (like GitHub Pages' docs folder option) |

Every site gets clean URLs (`/about` serves `about.html`) and your `404.html` if you have one.
Dotfiles are never served. `--spa` sends unknown paths to `index.html` for React/Vue routers.

### Per-repo settings: `.quickhost.yml`

Commit this to a repo so you don't have to repeat flags. Command-line flags still win.

```yaml
name: keepup                 # → keepup.whittleadams.com
# domain: keepup.games       # or an exact hostname
build: npm ci && npm run build
dir: dist
spa: true
# node_image: node:20-alpine
```

## Global config

`~/.config/quickhost/config.yml` (written by `quickhost init`):

```yaml
server: louislab.duckdns.org
base_domain: whittleadams.com
network: kamal
proxy_container: kamal-proxy
tls: true
keep_images: 3
```

Any key can be overridden for one run with `QUICKHOST_<KEY>`, e.g.
`QUICKHOST_BASE_DOMAIN=tasktrackflow.com quickhost deploy`.

## Notes

- Service names are prefixed `qh-` so they can't collide with Kamal apps. If a hostname is already
  used by another app (e.g. `tasktrackflow.com`), kamal-proxy refuses and nothing changes.
- `whittleadams.com` itself (no subdomain) works with `--domain whittleadams.com`.
  `www.` needs its own deploy or a redirect, because kamal-proxy routes one service per host.
- Containers use `--restart unless-stopped`, so sites come back after srv-01 wakes from `rtcwake`
  or reboots.

## Tests

```bash
ruby -Ilib test/quickhost_test.rb
```
