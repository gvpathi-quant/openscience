# Docker sandbox for OpenScience (secure defaults)

Sandboxed Docker deployment for the `openscience` CLI. Everything runs inside
the container as a non-root user against a read-only root filesystem, so it
never touches the host machine.

Files:

- `Dockerfile` — Debian (glibc) image with Python, Node, `uv`, git, curl, the
  scientific build toolchain, and the prebuilt OpenScience runtime baked in
- `docker-compose.yml` — sandbox with secure defaults
- `entrypoint.sh` — creates a user-writable Python venv, installs skill
  dependencies, then execs the CLI wrapper
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
docker compose down                  # stop; named volume keeps sandbox state
docker compose down -v               # wipe sandbox home entirely
```

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

- Runs as a non-root user; the container root filesystem is `read_only: true`.
  Writable state (venv, caches, `.openscience` data) lives in the named volume
  `openscience-home` mounted at `/home/openscience`.
- All Linux capabilities dropped, `no-new-privileges` enabled.
- `tini` is PID 1 to reap child processes and forward signals.
- Skills are mounted read-only at `/app/backend/cli/skills`.

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