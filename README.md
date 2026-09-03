# Self-hosted GitHub Actions runners (Docker Compose)

Several GitHub Actions runners in containers, each paired with its own Docker
daemon so jobs behave the way they do on GitHub-hosted runners.

Runners are **ephemeral**: each container takes exactly one job, deregisters,
and restarts with a clean work tree.

## Parity with hosted runners

| | GitHub-hosted | This stack |
|---|---|---|
| `HOME` | `/home/runner` | `/home/runner` |
| Work tree | `/home/runner/work` | `/home/runner/work` |
| Tool cache | `/opt/hostedtoolcache` | `/opt/hostedtoolcache` |
| Runner user | `runner`, uid 1001 | `runner`, uid 1001 |
| Docker | private daemon per VM | private `dind-N` per runner |
| Per job | fresh VM | work tree wiped at container start |
| Service containers | `localhost:<port>` | same (runner shares its daemon's netns) |
| `actions/cache` | GitHub cache service | same (network service, unchanged) |

Because each runner has its own daemon, `docker run -v "$GITHUB_WORKSPACE:/src"`
inside a job resolves to real files, and `container:` jobs and Docker container
actions work.

## Requirements

- Docker Engine with the Compose v2 plugin (`docker compose version`)
- A GitHub PAT that can register runners:
  - **Classic:** `admin:org` for org-level runners, `repo` for repo-level
  - **Fine-grained:** *Self-hosted runners* → Read and write
- The host must allow `privileged` containers (required by Docker-in-Docker)
- Roughly 1.5–2 GB of disk per runner once caches warm up

## Quick start

```bash
cp .env.example .env
# edit .env: set GITHUB_URL and GITHUB_PAT
docker compose build
docker compose up -d
docker compose logs -f runner-1
```

The runners appear under **Settings → Actions → Runners** in the org or repo.
Target them from a workflow with the labels from `RUNNER_LABELS`:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, docker]
```

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Runner image: Ubuntu 24.04, `actions/runner`, Docker CLI, hosted-style layout |
| `entrypoint.sh` | Registers the runner, waits for its daemon, drops root, deregisters on exit |
| `docker-compose.yml` | Three `runner-N` + `dind-N` pairs, plus the weekly prune |
| `cleanup.sh` | Age-based prune of tool caches and each daemon's image store |
| `.env` | Your configuration (gitignored — it holds the PAT) |
| `.env.example` | Template |

## Configuration (`.env`)

| Variable | Default | Notes |
|---|---|---|
| `GITHUB_URL` | — | `https://github.com/ORG` or `https://github.com/ORG/REPO` |
| `GITHUB_PAT` | — | Used to mint a fresh registration token on every container start |
| `RUNNER_NAME_PREFIX` | `docker-runner` | Runners are named `<prefix>-1`, `<prefix>-2`, … |
| `RUNNER_LABELS` | `self-hosted,linux,x64,docker` | Must match `runs-on:` |
| `RUNNER_GROUP` | `Default` | Org runner groups only |
| `RUNNER_EPHEMERAL` | `true` | One job per container. `false` = long-lived runner |
| `FRESH_WORKSPACE` | `true` | Wipe the work tree each start. `false` = incremental checkout, faster but less faithful |
| `DIND_IMAGE` | `docker:28-dind` | Pinned deliberately; dind major versions change defaults |
| `RUNNER_VERSION` | *(empty)* | Empty resolves the latest `actions/runner` release at build time |
| `CACHE_MAX_AGE_DAYS` | `14` | Prune threshold |
| `CACHE_PRUNE_INTERVAL_SECONDS` | `604800` | 7 days; the timer starts when the container starts |
| `CACHE_PRUNE_DRY_RUN` | `false` | Log what would be deleted, delete nothing |
| `CACHE_PRUNE_DOCKER` | `true` | Also prune each daemon's image/layer store |
| `DIND_HOSTS` | `tcp://dind-1..3:2375` | Endpoints the prune talks to |

`GITHUB_PAT` mints a registration token at each start rather than using a
static one, because registration tokens expire after about an hour and would
not survive a restart.

## How a runner starts

1. **Root phase** — chowns the shared volumes (they arrive root-owned), syncs
   `externals` into the shared volume if the runner version changed, exports
   `HOME=/home/runner`, then drops to uid 1001 via `setpriv`.
2. Wipes the work tree if `FRESH_WORKSPACE=true`.
3. Waits for `dind-N` to answer (up to 60s), so the first job cannot race the
   daemon on an image pull.
4. Mints a registration token, registers with `--ephemeral --replace`, runs.
5. On job completion or `SIGTERM`, deregisters so no offline runners linger.

### Why `externals` is mounted twice

A `container:` job makes the runner mount `/actions-runner/externals` (~600 MB
of Node runtimes) into the job container. The *daemon* resolves that path, so
`dind-N` needs the same content there. A named volume mounted straight over it
in the runner would mask the image's copy and go stale on every runner upgrade.
Instead the volume is mounted at `/mnt/externals` in the runner, at
`/actions-runner/externals` in dind, and the entrypoint syncs image → volume
whenever `.runner-version` differs.

### Why each runner shares its daemon's network namespace

A job's `services:` containers are created by the daemon and their ports are
published into *its* network namespace. If the runner had its own namespace,
`DATABASE_URL=postgres://...@localhost:32768/...` would be refused, because
nothing is listening on the runner's own localhost. `network_mode:
"service:dind-N"` puts the runner in its daemon's namespace, which is the
arrangement a hosted runner (and an ARC pod) has.

Two consequences:

- The runner inherits dind's hostname, so `RUNNER_NAME` is set explicitly per
  service (`docker-runner-1`, `-2`, `-3`) instead of being derived from
  `$(hostname)`.
- **Recreating a `dind-N` requires recreating its `runner-N`**, since the
  namespace it joined disappears. `docker compose up -d` handles this; a bare
  `docker compose restart dind-1` does not.

## Operations

**Logs**

```bash
docker compose logs -f runner-1          # one runner
docker compose logs -f cache-cleanup     # prune activity
```

**Add a fourth runner**

1. Copy the `dind-3` and `runner-3` service blocks, bumping every `3` to `4` -
   including `network_mode: "service:dind-4"` and `RUNNER_NAME`.
2. Add `work-4`, `tools-4`, `externals-4`, `dind-data-4` to the `volumes:` block.
3. In `cache-cleanup`: add `tools-4:/caches/4` to its volumes and `/caches/4` to
   `TOOL_CACHE_DIRS`.
4. Append `tcp://dind-4:2375` to `DIND_HOSTS` in `.env`.
5. `docker compose up -d`

**Upgrade the runner** — `docker compose build --no-cache && docker compose up -d`.
The externals volume re-seeds automatically on the version change.

**Drain before restarting** — `docker compose up -d` recreates containers
immediately and kills in-flight jobs. Wait for idle, or `docker compose stop`
first (deregistration happens on `SIGTERM`).

**Tear down**

```bash
docker compose down              # keep caches
docker compose down -v           # also delete caches and image stores
```

**Run the prune now**

```bash
docker compose restart cache-cleanup     # it prunes once at startup
```

## Maintenance

`cache-cleanup` runs at startup and then every `CACHE_PRUNE_INTERVAL_SECONDS`.
Everything is age-based, so a running job's working set is never a candidate.

- **Tool caches** — pruned a whole `tool/version` directory at a time; deleting
  individual files leaves a half-installed toolchain that fails obscurely later.
- **Image stores** — `docker image prune` / `builder prune` with
  `--filter until=`, per daemon.
- It uses `mtime`, not `atime`: hosts mounted `noatime`/`relatime` never age
  `atime`, so an `atime` filter can match nothing and let the disk fill.

Do a `CACHE_PRUNE_DRY_RUN=true` pass before trusting the threshold, and keep an
eye on `docker system df -v`.

## Security

- **Each `dind-N` is `privileged`.** Docker-in-Docker cannot create its
  namespaces otherwise. Anyone who can merge a workflow file gets root inside
  that runner's daemon — fine for repos whose write access you control, not for
  public fork PRs.
- **dind serves plain TCP on 2375 with no TLS.** The port is unpublished and
  reachable only on the compose network, but anything on that network gets
  unauthenticated root on that daemon. Add TLS if you put unrelated services in
  this project.
- **Jobs cannot see the host daemon.** Unlike a shared-socket setup, a job
  cannot list or kill the host's other containers.
- `.env` holds a PAT and is gitignored. Keep it `chmod 600`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `HTTP 401 … Bad credentials` | `GITHUB_PAT` wrong or missing the scope above |
| `HTTP 404` on registration | `GITHUB_URL` points at an org that doesn't exist, or a repo PAT against an org URL |
| Containers restart in a loop with no logs | Something is failing in the root phase — trace it with `docker compose run --rm --entrypoint bash runner-1 -x /usr/local/bin/entrypoint.sh` |
| `EACCES … '/root/.gitconfig'` | `HOME` is not being exported before the privilege drop |
| A job's `-v "$GITHUB_WORKSPACE:/src"` sees an empty directory | The path is not shared with the daemon at the same path. Green checks here are *false passes* — a scanner reports zero findings on zero files |
| `no Docker daemon at tcp://localhost:2375 after 60s` | `dind-N` unhealthy: `docker compose logs dind-N`. Usually the host disallows `privileged` |
| `Connection refused (os error 111)` reaching a service container on `localhost:<port>` | The runner is not sharing its daemon's netns - check `network_mode: "service:dind-N"` |
| `openssl-sys` / `pkg-config` build failure | A missing `-dev` package; see *Preinstalled build dependencies* |
| `psql: command not found` (or any tool, exit 127) | The image lacks a CLI the workflow assumes; hosted images ship far more |
| `git worktree` / `index.lock`: `Read-only file system` | A job mounts the workspace `:ro` but the tool needs to write to `.git` (e.g. semgrep `--baseline-commit`) |
| `docker compose down` hangs | A container is ignoring `SIGTERM` and waiting out `stop_grace_period` (5m for runners, 30s elsewhere) |

## Preinstalled build dependencies

Hosted runner images ship a large set of `-dev` packages that native extensions
assume are present. This image carries the common ones, because `-sys` crates
and native gems fail at *build* time without them:

`build-essential` `pkg-config` `cmake` `clang` `llvm` `libclang-dev`
`libssl-dev` `libsqlite3-dev` `libpq-dev` `zlib1g-dev` `libxml2-dev`
`libxmlsec1-dev` `libxmlsec1-openssl` `libxslt1-dev`

`libclang-dev` is there for `bindgen`, which needs `libclang.so` at build time,
and `libxmlsec1-openssl` because `pkg-config --libs xmlsec1` emits
`-lxmlsec1-openssl` - the headers alone do not link.

Database clients for talking to `services:` containers:

`postgresql-client` (psql 16) `redis-tools` (redis-cli 7)

`psql` comes from Ubuntu 24.04, so it is version 16. Talking to a newer server
is fine for `psql` itself, but `pg_dump` refuses a server newer than itself. If
your `services:` Postgres is 17+ and you dump from it, add the PGDG apt repo to
the `Dockerfile` and install the matching `postgresql-client-NN`.

A cheap way to fail fast with a clear message, rather than deep inside a cargo
build, is a preflight step:

```yaml
- run: |
    for lib in libxml-2.0 xmlsec1 openssl; do
      pkg-config --exists "$lib" || {
        echo "::error::runner image missing pkg-config module $lib"; exit 1; }
    done
```

If a build fails with "could not find directory of OpenSSL installation", "The
pkg-config command could not be found", or a missing header, the fix is another
`-dev` package in the `Dockerfile` rather than anything in the runner config.

## Known deviations from hosted runners

- **No preinstalled toolchains.** Hosted images ship dozens of language
  versions; here `setup-node`, `setup-python` and friends download on first use
  and are then cached in `/opt/hostedtoolcache`, which persists.
- **Fewer preinstalled system packages** than a hosted image, despite the list
  above. Expect to add a `-dev` package now and then.
- **`cargo install` compiles from source every time it runs.** `~/.cargo` lives
  in the container layer, so it survives a restart but not a rebuild. Prefer a
  prebuilt binary (`taiki-e/install-action`, `cargo-binstall`) or bake the tool
  into the image.
- **Layer cache is per runner**, not shared, so the same base image is pulled
  once per runner rather than once per host.
- **`dind-data-N` persists** across restarts. Strict fidelity would discard it,
  but every job would re-pull every image; the prune ages it out instead.
