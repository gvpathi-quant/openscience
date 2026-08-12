# Docker sandbox for OpenScience

Sandboxed Docker deployment for the `openscience` CLI. Everything runs in an
isolated container against a read-only root filesystem with dropped
capabilities, so it never touches the host machine.

Files:

- `Dockerfile` — Debian (glibc) image with Python, Node, `uv`, git, curl, the
  scientific build toolchain, `bubblewrap`, and the prebuilt OpenScience runtime
  baked in
- `docker-compose.yml` — sandbox with secure defaults
- `entrypoint.sh` — creates a writable Python venv, installs skill dependencies,
  starts the host port proxy, then execs the CLI wrapper
- `../scripts/install_skill_deps.sh` — reads each skill's `SKILL.md` frontmatter
  `dependencies:` and installs them into the venv with `uv`
- `../.dockerignore` — keeps the build context small
- `.env.example` — example environment variables

Usage

> Run every `docker compose` command from the `docker/` directory (that is where
> this project's compose file lives).

```bash
cd docker
docker compose up --build -d        # build + start sandbox (headless server)
docker compose logs -f openscience
docker compose down                  # stop; named volumes keep sandbox state
docker compose down -v               # wipe sandbox state (home + workspace)
```

Persisting your work (volumes)

Two named volumes back the sandbox and survive restarts (`down`/`up`):

| Volume | Mount | What lives there |
| --- | --- | --- |
| `<project>_openscience-home` | `/home/openscience` | venv (skill deps), caches, `.openscience` config/logs |
| `<project>_workspace` | `/home/openscience/workspace` | your working files, projects, and outputs |

The workspace is also the container's working directory, so anything the server
or an `exec` shell saves lands there. Find/list the volumes and copy files out:

```bash
docker volume ls | grep openscience
docker compose cp openscience:/home/openscience/workspace/. ./my-workspace-copy
```

To use a host directory directly instead of the named workspace volume, replace
the `- workspace:/home/openscience/workspace` line in `docker-compose.yml` with:

```yaml
      - /absolute/path/on/host:/home/openscience/workspace
```

(resolve `<project>` from `docker compose ls`; it defaults to the folder name of
the compose file, i.e. `docker`.)

Accessing the web UI

The server binds to `127.0.0.1:8080` *inside* the container and is loopback-only
by design, so it is **not** reachable on your host's port 8080. The entrypoint
starts a `socat` proxy in the same network namespace that publishes it on the
host port `${SANDBOX_PORT:-18080}` instead:

```bash
open http://localhost:18080        # <- host URL (not :8080)
```

Pick a different host port if 18080 is taken (the proxy and the published port
must match):

```bash
SANDBOX_PORT=19090 docker compose up -d
open http://localhost:19090
```

Accessing the CLI

The openscience CLI runs inside the sandbox. Interact with it without disturbing
the running server via `exec` (you get an interactive shell per default):

```bash
docker compose exec openscience openscience --version
docker compose exec openscience openscience agent list
docker compose exec openscience openscience tools list
```

Drop into a shell inside the sandbox (venv with installed skill deps is already
on `PATH`):

```bash
docker compose exec openscience bash
```

For a one-off command instead of the long-running server (starts a throwaway
container for just that invocation):

```bash
docker compose run --rm openscience --version
```

Any `docker compose exec`/`run` starts with writes confined to the sandbox — the
host machine is never touched.

Why Debian and not Alpine

The OpenScience runtime and the scientific-python stack the skills use
(numpy, scipy, scikit-learn, torch, biopython, rdkit, ...) are shipped as
glibc/manylinux wheels. A musl base (Alpine) forces compiling those from source
and most have no musl wheels - so skill execution would fail. Debian slim keeps
the image small while staying libc-compatible, so `uv` installs wheels instead
of building.

How skill dependencies work

Skills declare their Python dependencies in the YAML frontmatter of their
`SKILL.md`:

```yaml
dependencies: ["scikit-learn>=1.5.0", "pandas"]
```

At container start `install_skill_deps.sh` scans all skills and, by default,
reports the declared deps. Set `OPENSCIENCE_INSTALL_SKILL_DEPS=1` to pre-install
every skill's deps into the venv (slow - the declared set includes torch,
transformers, vllm, etc.; if you only run a few skills, install what you need
from inside the sandbox instead):

```bash
docker compose exec openscience uv pip install scikit-learn pandas
```

Sandbox design

- Root filesystem is `read_only: true`; only `/tmp` (tmpfs) and the two named
  volumes above are writable.
- All Linux capabilities are dropped; only `SYS_ADMIN` (namespace/mount ops for
  bubblewrap) and `DAC_OVERRIDE`/`DAC_READ_SEARCH` (access shared volume files)
  are re-added.
- The container runs as root (`user: "0:0"`). This is required for the bubblewrap
  backend on this Docker daemon: it clears ALL capabilities for non-root users at
  exec, and unprivileged user namespaces are restricted on the host. `seccomp`
  and `apparmor` must also be `unconfined` or the nested-namespace syscalls are
  blocked. The actual OS boundary is the container itself.
- `tini` is PID 1 to reap child processes and forward signals.
- Skills are mounted read-only at `/app/backend/cli/skills`.

The OpenScience execution sandbox (bubblewrap)

`openscience sandbox` confines agent shell commands to the workspace with
`bubblewrap` mount/PID namespaces (and can deny network egress). It is enabled by
default; verify with:

```bash
docker compose exec openscience openscience sandbox status
#   backend:   bubblewrap (bwrap)
docker compose exec openscience openscience sandbox test   # containment self-test
```

Self-test asserts writes stay inside the workspace, writes outside are blocked,
and (in deny mode) no network egress — all pass in this image.

Runtime notes

- The image downloads the official prebuilt OpenScience CLI binary
  (`openscience-linux-x64`, v2.0.23 by default) at build time. To use a
  different version or target, rebuild with build args:

  ```bash
  docker build -f docker/Dockerfile \
    --build-arg OPENSCIENCE_VERSION=v2.0.23 \
    --build-arg OPENSCIENCE_TARGET=openscience-linux-x64 \
    -t openscience:latest .
  ```

- The kernel inside the container is the host kernel; the runtime requires
  kernel >= 5.1 (and 4 KB pages on ARM64).