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

What quickhost knows about a site (where it came from, whether it's private, whether it
auto-updates) is stored as Docker labels on the site's container, so there is no state file to
keep in sync between machines.

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

quickhost deploy --private             # ask visitors for a password (see "Private sites")
quickhost deploy owner/repo --auto     # redeploy by itself on new commits (see "Auto-updates")

quickhost list                         # every site: URL, version, age, state, access, auto-updates
quickhost status ball-game             # everything about one site, plus a live check
quickhost open ball-game               # open it in your browser
quickhost logs ball-game -f            # nginx access log (--tail N for more history)
quickhost rollback ball-game           # back to the previous version
quickhost rollback ball-game --to 20261110143000-5af19fc
quickhost remove ball-game             # take it offline and delete images
quickhost hub                          # link page of every site → sites.whittleadams.com
```

### Looking at what's running

```
$ quickhost list
NAME       URL                                 VERSION                 DEPLOYED  STATE    ACCESS   AUTO
ball-game  https://ball-game.whittleadams.com  20261110143000-5af19fc  6d ago    running  private  on
notes      https://notes.whittleadams.com      20261115090000          2d ago    running  public   -

$ quickhost status ball-game
ball-game
  URL          https://ball-game.whittleadams.com
  State        running (qh-ball-game-20261110143000-5af19fc)
  Responds     401 — asks for a password, as it should
  Version      20261110143000-5af19fc — deployed 10 Nov 2026 14:30 UTC, 6d ago
  Source       https://github.com/NiceWorkLad/Ball-Game.git @ 5af19fc
  Access       private (user: louis)
  Auto-update  on — updater checks every 5m
  Route        qh-ball-game → running
  Versions     20261110143000-5af19fc  ← live
               20261101120000-aaa1111
```

`status` fetches the site the way a visitor would, so it also tells you if a private site is
answering without a password. `Versions` are what `rollback --to` accepts. Both commands take
`--json` for scripts. In the `AUTO` column, `-` means the site wasn't deployed from a git remote,
so there is nothing to follow.

### Private sites

A private site asks every visitor for a username and password (HTTP basic auth, over HTTPS)
before it serves anything.

```bash
quickhost deploy --private                      # generates a password and prints it once
quickhost deploy --private --password hunter22 --user louis
quickhost private notes                         # make a live site private, no rebuild
quickhost private notes --password hunter22     # …or change its password
quickhost public notes                          # open it up again
```

- The setting sticks. Later deploys, rollbacks and auto-updates keep the site private with the
  same login until you run `quickhost public` or deploy with `--public`.
- Only a salted hash of the password is stored, on the server. A generated password can't be
  shown again; `quickhost private NAME` sets a new one. To keep a password out of your shell
  history, put it in `QUICKHOST_PASSWORD` instead of `--password`.
- The default username is `quickhost` (`private_user` in the config).
- Private sites are left off the hub page.
- Before switching traffic, quickhost checks that the new container really is asking for a
  password, and stops if it isn't. Sites deployed with quickhost 0.2 or older need one redeploy
  before `quickhost private` works on them.

### Auto-updates

With auto-updates on, a site redeploys by itself when its branch gets new commits, like GitHub
Pages. It is off unless you turn it on, per site.

```bash
quickhost auto start                   # once: install the updater on the server
quickhost deploy NiceWorkLad/Ball-Game --auto
quickhost auto on ball-game            # or turn it on for a site that's already live
quickhost auto off ball-game

quickhost auto                         # is it on? updater state, and what each site follows
quickhost auto logs -f                 # what the updater has been doing
quickhost update                       # check now instead of waiting (every site with auto on)
quickhost update ball-game --force     # redeploy one site from its repo, new commits or not
quickhost auto stop                    # remove the updater; sites stay as they are
```

```
$ quickhost auto
Updater: ON — running on louislab.duckdns.org, checks every 5m
  [2026-11-16 21:00:00Z] checked 2 sites: 2 current

SITE       AUTO  FOLLOWS
ball-game  on    https://github.com/NiceWorkLad/Ball-Game.git @ 5af19fc
blog       off   https://github.com/NiceWorkLad/blog.git (main) @ 1234567
notes      -     no git source recorded
```

How it works: the updater is a small container (`qh-updater`) on the server holding a copy of
quickhost. Every 5 minutes (`quickhost auto start --interval 2m` to change it) it asks each
followed repo for its newest commit and, if that differs from what is live, clones and deploys it
with the same name, host, build flags and privacy as before. A commit that fails to build leaves
the live site alone and isn't retried until you push another.

Things to know:

- A site can only follow a git remote. Deploying `owner/repo` or a git URL records it. Deploying
  a local repo records its `origin` and current branch, and then **what is pushed wins**: local
  changes you deployed but didn't push are replaced at the next check.
- The updater clones over https without credentials, so it can follow public repos only.
- `quickhost rollback` turns auto-updates off for that site, otherwise the updater would put the
  newer commit straight back. Turn it on again with `quickhost auto on NAME`.
- The updater has access to the server's Docker (it mounts the Docker socket), which it needs to
  build and start sites.
- After upgrading quickhost, run `quickhost auto start` again to give the updater the new version.
  `quickhost auto` tells you when they differ.

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
# private: true              # password protected (the password itself is never stored in the repo)
# auto: true                 # follow new commits
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
private_user: quickhost      # default username for private sites
auto_interval: 300           # seconds between the updater's checks
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
