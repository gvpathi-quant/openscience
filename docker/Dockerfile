# syntax=docker/dockerfile:1
#
# OpenScience sandbox image (glibc).
#
# Uses Debian (glibc) rather than Alpine (musl): the OpenScience runtime and the
# scientific-python stack the skills rely on (numpy, scipy, scikit-learn, torch,
# biopython, ...) are distributed as manylinux/glibc wheels. Keeping libc binary
# compatible lets `uv` install most skill dependencies as prebuilt wheels instead
# of compiling from source.
#
# The image embeds the official prebuilt OpenScience CLI binary so the runtime
# works out of the box. Override the version/arch with build args if needed.

ARG OPENSCIENCE_VERSION=v2.0.23
ARG OPENSCIENCE_TARGET=openscience-linux-x64

FROM debian:bookworm-slim AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        tini \
        procps \
        libgomp1 \
        build-essential \
        socat \
    && rm -rf /var/lib/apt/lists/*

# uv - fast, correct Python package manager used by the skills themselves
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /root/.local/bin/uvx /usr/local/bin/

# OpenScience runtime (prebuilt native binary, glibc build)
ARG OPENSCIENCE_VERSION
ARG OPENSCIENCE_TARGET
RUN curl -fsSL -o /tmp/openscience.tar.gz \
        "https://github.com/synthetic-sciences/OpenScience/releases/download/${OPENSCIENCE_VERSION}/${OPENSCIENCE_TARGET}.tar.gz" \
    && tar -xzf /tmp/openscience.tar.gz -C /usr/local/bin openscience \
    && mv /usr/local/bin/openscience /usr/local/bin/openscience-native \
    && rm -f /tmp/openscience.tar.gz \
    && test -x /usr/local/bin/openscience-native

# Non-root sandbox user (fixed uid/gid so named volumes and compose's
# user: "1000:1000" align — otherwise fresh volumes are owned by a different uid)
RUN addgroup --system --gid 1000 openscience \
    && adduser --system --uid 1000 --ingroup openscience --home /home/openscience --shell /bin/bash openscience \
    && mkdir -p /app/backend/cli/skills \
    && chown -R 1000:1000 /home/openscience /app

ENV HOME=/home/openscience \
    LANG=C.UTF-8 \
    OPENSCIENCE_BIN_PATH=/usr/local/bin/openscience-native

# Node wrapper (falls back to OPENSCIENCE_BIN_PATH) + entrypoint/dep-install scripts
COPY backend/cli/bin/openscience /usr/local/bin/openscience
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/install_skill_deps.sh /usr/local/bin/install_skill_deps.sh
RUN chmod +x /usr/local/bin/openscience /usr/local/bin/entrypoint.sh /usr/local/bin/install_skill_deps.sh

USER openscience
WORKDIR /home/openscience

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["--help"]