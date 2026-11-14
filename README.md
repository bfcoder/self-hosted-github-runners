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
  - **Fine-grained** (resource owner = the org or user): *Self-hosted runners*
    → Read and write for an org, *Administration* → Read and write for a repo
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
| `Dockerfile` | Runner image: Ubuntu 26.04, `actions/runner`, Docker CLI, hosted-style layout |
| `entrypoint.sh` | Registers the runner, waits for its daemon, drops root, deregisters on exit |
| `docker-compose.yml` | Five `runner-N` + `dind-N` pairs, plus the weekly prune |
| `cleanup.sh` | Age-based prune of tool caches and each daemon's image store |
| `.env` | Your configuration (gitignored — it holds the PAT) |
| `.env.example` | Template |

## Configuration (`.env`)

| Variable | Default | Notes |
|---|---|---|
| `GITHUB_URL` | — | `https://github.com/ORG` or `https://github.com/ORG/REPO` |
| `GITHUB_PAT` | — | Used to mint a fresh registration token on every container start |
| `GITHUB_URL_N` / `GITHUB_PAT_N` | *(unset)* | Per-runner target for `runner-N`; see *Serving an org and a personal repo* |
| `RUNNER_NAME_PREFIX` | `docker-runner` | Runners are named `<prefix>-1`, `<prefix>-2`, … |
| `RUNNER_LABELS` | `self-hosted,linux,x64,docker` | Must match `runs-on:` |
| `RUNNER_GROUP` | `Default` | Org runner groups only; not passed for repo targets |
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

## Serving an org and a personal repo

A runner registers to exactly one org or one repo. Org runners can't pick up
jobs from a repo under your personal account, and personal accounts have no
account-wide runners, so a private personal repo needs runners registered to
that repo. Split the five runners between targets with per-runner overrides:

```bash
# .env
GITHUB_URL=https://github.com/my-org        # runners 1-3 (the default)
GITHUB_PAT=github_pat_org...

GITHUB_URL_4=https://github.com/me/my-repo  # runners 4-5
GITHUB_PAT_4=github_pat_me...
GITHUB_URL_5=https://github.com/me/my-repo
GITHUB_PAT_5=github_pat_me...
```

Then `docker compose up -d`. Any `runner-N` without a `GITHUB_URL_N` uses
`GITHUB_URL`.

- **PATs.** A fine-grained PAT belongs to one resource owner, so the org and
  your personal repo need one each (*Self-hosted runners* R/W for the org,
  *Administration* R/W on the repo). A classic PAT with `admin:org` and `repo`
  works for both and can go in `GITHUB_PAT` alone.
- **Runner names** only need to be unique within a target, so both sides keep
  the `docker-runner-N` names.
- **Labels and `runs-on:`** are unchanged: each repo only ever sees the runners
  registered to it (or its org).
- **Isolation.** Each runner has its own daemon and volumes, so org jobs and
  personal jobs never share a work tree, tool cache or image store.
- **Moving a runner** to a different target: change `.env` and run
  `docker compose up -d`. The recreate sends `SIGTERM`, which deregisters it
  from the old target before it registers with the new one.
- **More runners for one side.** To keep all five on the org and add more for
  the repo, add a `runner-6` (see *Add another runner*) and set
  `GITHUB_URL_6` / `GITHUB_PAT_6`. Mind `RUNNER_MEMORY` × runner count.

## How a runner starts

1. **Root phase** — chowns the shared volumes (they arrive root-owned), syncs
   `externals` into the shared volume if the runner version changed, exports
   `HOME=/home/runner`, then drops to uid 1001 via `setpriv`.
2. Wipes the work tree if `FRESH_WORKSPACE=true`.
3. Waits for `dind-N` to answer (up to 60s), so the first job cannot race the
   daemon on an image pull.
4. Clears any stale registration (see below), drops a leftover GitHub
   registration of the same name, then mints a registration token and
   registers with `--ephemeral --replace`.
5. On job completion or `SIGTERM`, deregisters so no offline runners linger.

### Surviving an unclean shutdown

`/actions-runner` is in the container layer, so a `.runner` written at
registration outlives a host reboot or a `SIGKILL` - any stop where the
deregistration trap does not run. On the next start `config.sh` refuses
**before it contacts GitHub at all**:

```
Cannot configure the runner because it is already configured.
To reconfigure the runner, run './config.sh remove' first.
```

`--replace` never gets a chance, and the container restart-loops. The
entrypoint now runs `config.sh remove --local` first, which clears the local
files without needing a token or network, and then deletes any registration of
the same name through the API before registering. Deregistration uses a token
from the `remove-token` endpoint - a registration token is a *different*
endpoint and `config.sh remove` rejects it.

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

**Add another runner** (the stack ships with five, `runner-1` … `runner-5`)

1. Copy the `dind-5` and `runner-5` service blocks, bumping every `5` to `6` -
   including `network_mode: "service:dind-6"`, `RUNNER_NAME`, and the
   `GITHUB_URL_6` / `GITHUB_PAT_6` overrides.
2. Add `work-6`, `tools-6`, `externals-6`, `dind-data-6` to the `volumes:` block.
3. In `cache-cleanup`: add `tools-6:/caches/6` to its volumes and `/caches/6` to
   `TOOL_CACHE_DIRS`.
4. Append `tcp://dind-6:2375` to `DIND_HOSTS` in `.env`.
5. `docker compose up -d`

Each runner costs roughly 600 MB of externals plus its own image store, so plan
disk before scaling much further.

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

## Resource limits

Each runner is capped at `RUNNER_CPUS` / `RUNNER_MEMORY` (default 4 vCPU / 16
GB, matching a GitHub-hosted runner). Without a cap a container sees the whole
host, so build tools size their parallelism to the entire machine in every
runner at once - on a 32-core box that is `cargo -j32` five times over, which
exhausts RAM and gets build processes killed.

Memory is a **hard cap per runner**: `runner count x RUNNER_MEMORY` should fit
in host RAM with headroom, or the kernel kills build processes under load. Five
runners at the 16 GB default wants 80 GB if they are all busy. Size the limits
to the host, or run fewer runners.

**Cargo follows the CPU limit automatically** - Rust's `available_parallelism`
honours the cgroup quota. But `nproc` does **not**: it reports host cores
regardless. A step that runs `make -j$(nproc)` or `cargo test -j $(nproc)` will
still fan out to the whole machine, so set `CARGO_BUILD_JOBS` or pass an
explicit `-j` in those workflows.

## Diagnosing a build that dies with no error

A process killed by the kernel for using too much memory prints nothing. Worse,
`sccache` turns the `SIGKILL` into a bare **exit code 2**, so cargo reports
`process didn't exit successfully ... (exit status: 2)` with no diagnostic at
all and the failure looks like a compiler bug.

Each runner therefore samples its own cgroup for the life of every job
(`MEM_SAMPLE=true`, every `MEM_SAMPLE_INTERVAL` seconds) and logs to
`docker compose logs runner-N`:

```
[mem] 12:33:58Z usage 13GB = 81% of limit
[mem]          11GB   rustc
[mem] 12:34:03Z OOM KILL  1 process(es) killed by the kernel; current=2.1GB
[mem] 12:34:03Z        largest processes at the previous sample:
[mem]          14GB   rustc
[mem] 12:34:08Z SUMMARY peak=16GB (100% of limit) oom_kills=1
```

The decisive field is `oom_kills` in the SUMMARY line, read from the cgroup's
`memory.events`. Non-zero means the kernel killed something in that container,
and a build step that failed without a diagnostic was almost certainly it.
Usage lines appear only when a new band is crossed, so a job that stays well
under its limit prints two lines total.

The OOM victim is gone by the time the sampler polls, so the kill report shows
the *previous* sample - that is the one that names what was actually large.

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
| `HTTP 403`/`404` only on runners pointed at your personal repo | That runner is using the org's fine-grained PAT; set `GITHUB_PAT_N` to one owned by your account with *Administration* R/W on the repo |
| Containers restart in a loop with no logs | Something is failing in the root phase — trace it with `docker compose run --rm --entrypoint bash runner-1 -x /usr/local/bin/entrypoint.sh` |
| `EACCES … '/root/.gitconfig'` | `HOME` is not being exported before the privilege drop |
| A job's `-v "$GITHUB_WORKSPACE:/src"` sees an empty directory | The path is not shared with the daemon at the same path. Green checks here are *false passes* — a scanner reports zero findings on zero files |
| `no Docker daemon at tcp://localhost:2375 after 60s` | `dind-N` unhealthy: `docker compose logs dind-N`. Usually the host disallows `privileged` |
| `Connection refused (os error 111)` reaching a service container on `localhost:<port>` | The runner is not sharing its daemon's netns - check `network_mode: "service:dind-N"` |
| `openssl-sys` / `pkg-config` build failure | A missing `-dev` package; see *Preinstalled build dependencies* |
| `psql: command not found` (or any tool, exit 127) | The image lacks a CLI the workflow assumes; hosted images ship far more |
| A compiler exits non-zero with **no error diagnostic** (`exit status: 2` through sccache) | Check the `[mem]` SUMMARY line in `docker compose logs runner-N`: a non-zero `oom_kills` means the kernel killed it. See *Diagnosing a build that dies with no error* |
| `git worktree` / `index.lock`: `Read-only file system` | A job mounts the workspace `:ro` but the tool needs to write to `.git` (e.g. semgrep `--baseline-commit`) |
| After a host reboot, runners restart-loop until you delete them in the GitHub web UI | A stale `.runner` from the unclean shutdown; see *Surviving an unclean shutdown* |
| `docker compose down` hangs | A container is ignoring `SIGTERM` and waiting out `stop_grace_period` (5m for runners, 30s elsewhere) |

## Preinstalled build dependencies

Hosted runner images ship a large set of `-dev` packages that native extensions
assume are present. This image carries the common ones, because `-sys` crates
and native gems fail at *build* time without them:

`build-essential` `pkg-config` `cmake` `clang` `llvm` `libclang-dev`
`libssl-dev` `libsqlite3-dev` `libpq-dev` `zlib1g-dev` `libxml2-dev`
`libxmlsec1-dev` `libxmlsec1-openssl1` `libxslt1-dev`

`libclang-dev` is there for `bindgen`, which needs `libclang.so` at build time,
and `libxmlsec1-openssl1` because `pkg-config --libs xmlsec1` emits
`-lxmlsec1-openssl` - the headers alone do not link.

Database clients for talking to `services:` containers:

`postgresql-client` (psql 18) `redis-tools` (redis-cli 8)

Scripting:

`python3` (3.14) `python3-pip` `python3-venv` `python-is-python3`

Everything in the hosted image's "Installed apt packages" table, because
workflows assume these without declaring them:

`7zip` `7zip-rar` `acl` `aria2` `autoconf` `automake` `bind9-dnsutils`
`binutils` `bison` `brotli` `bzip2` `coreutils` `curl` `dbus` `dpkg` `dpkg-dev`
`fakeroot` `file` `findutils` `flex` `fonts-noto-color-emoji` `ftp` `g++` `gcc`
`gnupg2` `iproute2` `iputils-ping` `jq` `libicu-dev` `libnss3-tools`
`libsqlite3-dev` `libssl-dev` `libtool` `libyaml-dev` `locales` `lz4` `m4`
`make` `net-tools` `netcat-openbsd` `openssh-client` `parallel` `patchelf`
`pigz` `pkg-config` `python-is-python3` `rpm` `rsync` `shellcheck` `sqlite3`
`ssh` `sshpass` `sudo` `swig` `tar` `telnet` `texinfo` `time` `tk` `tree`
`tzdata` `unzip` `upx-ucl` `wget` `xvfb` `xz-utils` `zip` `zsync`, plus `zstd`
and `git-lfs`, which the hosted image installs from upstream.

The hosted readme names some packages by what they provide: its `netcat` is
`netcat-openbsd` and its `upx` is `upx-ucl`. Two entries are left out because
they do nothing in a container: `pollinate` seeds entropy at VM boot, and
`systemd-coredump` needs systemd as PID 1.

`zstd` matters most: `actions/cache` and `Swatinem/rust-cache` compress with it
when present and silently fall back to gzip when absent. `git-lfs` is the other
silent one - without it checkout produces pointer files, not content. The
network tools are there so a job that cannot reach a service container can be
debugged from inside the runner.

To re-sync after a runner-image release, diff the "Installed apt packages" table
in `actions/runner-images` `images/ubuntu/Ubuntu2604-Readme.md` against
`dpkg-query -W -f='${Package}\n'` in this image. Only `pollinate` and
`systemd-coredump` should be missing.

Ubuntu marks the system interpreter externally managed, so a bare
`pip3 install X` fails with `error: externally-managed-environment`. Use a
virtualenv, `pip install --user`, or `setup-python`, which brings its own
interpreter into `/opt/hostedtoolcache`.

`psql` comes from Ubuntu 26.04, so it is version 18. Talking to a newer server
is fine for `psql` itself, but `pg_dump` refuses a server newer than itself. If
your `services:` Postgres is 19+ and you dump from it, add the PGDG apt repo to
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
- **Only the hosted apt packages, not the rest of the hosted image.** The
  hosted image also carries language runtimes (Java, .NET, Go, Rust, PHP,
  Haskell, Kotlin), cloud CLIs (`gh`, `aws`, `az`, `gcloud`), Kubernetes tools,
  browsers and the Android SDK. Workflows that assume one of those need a
  `setup-*` action or an addition to the `Dockerfile`.
- **Distro versions, not the hosted image's.** Where the hosted image installs
  a tool from upstream, this image gets Ubuntu's build: git 2.53 and CMake 4.2
  instead of the hosted 2.55 and 4.4, for example.
- **uutils coreutils.** Ubuntu 26.04 replaces GNU coreutils with the Rust
  rewrite. The hosted image does too, but a script that worked on 24.04 can
  still trip over a flag uutils does not implement.
- **`ubuntu-latest` moves to Ubuntu 26.04 in November 2026.** This image is
  already on 26.04, so until then it matches `ubuntu-26.04`, not
  `ubuntu-latest`.
- **`cargo install` compiles from source every time it runs.** `~/.cargo` lives
  in the container layer, so it survives a restart but not a rebuild. Prefer a
  prebuilt binary (`taiki-e/install-action`, `cargo-binstall`) or bake the tool
  into the image.
- **Layer cache is per runner**, not shared, so the same base image is pulled
  once per runner rather than once per host.
- **`dind-data-N` persists** across restarts. Strict fidelity would discard it,
  but every job would re-pull every image; the prune ages it out instead.
