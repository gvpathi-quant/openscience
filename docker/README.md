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

```bash
cd docker
docker compose up --build -d        # build + start sandbox (headless server)
docker compose exec openscience openscience --version
docker compose logs -f openscience
docker compose down                  # stop; named volume keeps sandbox state
docker compose down -v               # wipe sandbox home entirely
```

The `serve` command runs the headless server bound to the container's localhost
(`http://localhost:8080` inside the sandbox). Because the server is loopback-only
by design, the entrypoint starts a small `socat` proxy inside the same network
namespace that publishes the server on a unique host port
(`${SANDBOX_PORT:-18080}` by default) so the web UI is reachable from your browser:

```bash
open http://localhost:18080
```

Pick a free port if 18080 is taken: `SANDBOX_PORT=19090 docker compose up -d`.
Use `docker compose exec` to run commands inside the sandbox. To launch a one-off
command instead of the long-running server:

```bash
docker compose run --rm openscience --version
```

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