#!/usr/bin/env bash
set -euo pipefail

# Set up a user-writable Python virtualenv for skill dependencies, then launch
# the openscience wrapper. Home (and the venv) live on a writable volume so the
# container's root filesystem can stay read-only.
PORTABLE_PYTHON=$(command -v python3 || true)
PY_HOME=${PY_HOME:-${HOME}/.venv}

echo "[entrypoint] Preparing Python environment (${PY_HOME})"
if [ ! -x "${PY_HOME}/bin/python" ]; then
  uv venv --python "${PORTABLE_PYTHON}" --clear "${PY_HOME}"
fi

export PATH="${PY_HOME}/bin:${PATH}"
export VIRTUAL_ENV="${PY_HOME}"

SKILLS_PATH=${SKILLS_PATH:-/app/backend/cli/skills}
if [ -x /usr/local/bin/install_skill_deps.sh ]; then
  echo "[entrypoint] Installing skill dependencies (skills path: ${SKILLS_PATH})"
  /usr/local/bin/install_skill_deps.sh "${SKILLS_PATH}" "${PY_HOME}" || \
    echo "[entrypoint] skill dependency install finished with non-zero status (best-effort)"
else
  echo "[entrypoint] install_skill_deps.sh not found or not executable"
fi

# The openscience server only listens on 127.0.0.1 inside this namespace. When a
# host port is requested, proxy it with socat so the web UI is reachable from the
# host while the server itself stays loopback-only. SOCAT_PORT mirrors the
# published compose port (SANDBOX_PORT in docker-compose.yml); it forwards to the
# server port used by the `serve` command (8080).
SOCAT_PORT=${SOCAT_PORT:-}
if [ -n "${SOCAT_PORT}" ]; then
  echo "[entrypoint] starting host proxy 0.0.0.0:${SOCAT_PORT} -> 127.0.0.1:8080"
  socat TCP-LISTEN:${SOCAT_PORT},fork,reuseaddr TCP:127.0.0.1:8080 &
fi

echo "[entrypoint] Executing openscience with args: $*"
exec /usr/local/bin/openscience "$@"