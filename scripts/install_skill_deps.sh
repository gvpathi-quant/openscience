#!/usr/bin/env bash
set -euo pipefail

# Installs dependencies declared by skills in the provided skills directory.
#
# Skills declare their dependencies in the YAML frontmatter of SKILL.md, e.g.:
#   dependencies: ["scikit-learn>=1.5.0", "numpy"]
# The OpenScience skills are docs that guide agents to run Python/Node code, so
# their deps must be installed into the sandbox's writable Python/Node env.
#
# Behavior:
#   - Scans every skill subdirectory for SKILL.md frontmatter dependencies.
#   - Installs them into the Python virtualenv passed as the 2nd argument using uv.
#   - Falls back to legacy heuristics (requirements.txt / pyproject.toml / package.json).
#   - Set OPENSCIENCE_INSTALL_SKILL_DEPS=1 to pre-install all declared deps at
#     container start. It defaults to off because the declared set includes very
#     heavy packages (torch, transformers, vllm, ...); install them on demand once
#     you know which skills you actually run.
#   - Every install is best-effort; failures never abort the container startup.

SKILLS_DIR=${1:-/app/backend/cli/skills}
VENV_DIR=${2:-${HOME}/.venv}
INSTALL=${OPENSCIENCE_INSTALL_SKILL_DEPS:-0}

export PATH="${VENV_DIR}/bin:${HOME}/.local/bin:${PATH}"

if [ ! -d "${SKILLS_DIR}" ]; then
  echo "[install_skill_deps] no skills directory found at ${SKILLS_DIR}, skipping"
  exit 0
fi

# Extract frontmatter dependencies from a SKILL.md (handles quoted and unquoted
# entries). Prints one dependency per line. YAML-free on purpose.
extract_deps() {
  python3 - "$1" <<'PY'
import re, sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    sys.exit(0)

# Only look inside the YAML frontmatter (first two --- delimiters)
parts = text.split("---", 2)
if len(parts) < 3:
    sys.exit(0)
front = parts[1]
m = re.search(r"dependencies:\s*\[(.*?)\]", front, re.S)
if not m:
    sys.exit(0)
body = m.group(1)
entries = [e.strip().strip("\"'") for e in body.split(",")]
for entry in entries:
    if entry:
        print(entry)
PY
}

install_declared() {
  local skill_dir="${1%/}"
  local deps_file
  deps_file="$(mktemp)"
  extract_deps "${skill_dir}/SKILL.md" > "${deps_file}" || true
  if [ ! -s "${deps_file}" ]; then
    rm -f "${deps_file}"
    return 0
  fi
  count=$(wc -l < "${deps_file}")

  if [ "${INSTALL}" = "1" ]; then
    echo "[install_skill_deps] installing ${count} python deps for ${skill_dir}"
    uv pip install --python "${VENV_DIR}/bin/python" -r "${deps_file}" \
      || echo "[install_skill_deps] uv install failed for ${skill_dir} (continuing)"
  else
    echo "[install_skill_deps] ${skill_dir} declares ${count} deps: $(tr '\n' ' ' < "${deps_file}")"
  fi
  rm -f "${deps_file}"
}

# Skills live one level under category dirs (skills/<category>/<skill>/SKILL.md),
# so discover them recursively rather than assuming a flat layout.
found=0
while IFS= read -r skill_file; do
  found=1
  install_declared "$(dirname "${skill_file}")"
done < <(find "${SKILLS_DIR}" -maxdepth 3 -name SKILL.md -print 2>/dev/null)

if [ "${found}" = "0" ]; then
  echo "[install_skill_deps] no skill directories found under ${SKILLS_DIR}"
fi

echo "[install_skill_deps] done"