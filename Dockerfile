ARG PYTHON_VERSION=3.14

# Throwaway stage that fetches the accelerator add-on from its GitHub release.
# The repo is private, so the token comes in as a build secret and never lands in a layer.
# With ACCELERATOR=0 it only produces an empty folder.
FROM debian:bookworm-slim AS accelerator
ARG ACCELERATOR=0
ARG ACCEL_SLUG=linux-x86_64
ARG ACCEL_CUDA=0
ARG ACCEL_TAG=latest
RUN mkdir -p /plugins
RUN --mount=type=secret,id=accel_token \
    if [ "${ACCELERATOR}" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends curl ca-certificates unzip jq \
        && token=$(cat /run/secrets/accel_token) \
        && repo=https://api.github.com/repos/FLIMKit/FLIMKit-accelerator-plugin/releases \
        && if [ "${ACCEL_TAG}" = "latest" ]; then url=${repo}/latest; else url=${repo}/tags/${ACCEL_TAG}; fi \
        && id=$(curl -fsS -H "Authorization: Bearer ${token}" "${url}" \
               | jq -r ".assets[] | select(.name == \"flimkit-accelerator-${ACCEL_SLUG}.zip\") | .id") \
        && test -n "${id}" \
        && curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: application/octet-stream" \
               -o /tmp/accel.zip "${repo}/assets/${id}" \
        && unzip -q /tmp/accel.zip 'flimkit_accelerator_plugin/*' -d /plugins \
        && if [ "${ACCEL_CUDA}" != "1" ]; then rm -f /plugins/flimkit_accelerator_plugin/*cuda*; fi \
        && rm -f /plugins/flimkit_accelerator_plugin/kernels.c /plugins/flimkit_accelerator_plugin/kernels.cu \
        && chmod -R a+rX /plugins; \
    fi

# Throwaway stage that installs the Python packages into a venv and trims it.
FROM python:${PYTHON_VERSION}-slim-bookworm AS build
ARG FLAVOUR=web
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:${PATH}

# Empty TORCH_INDEX leaves torch out, which is most of the image size.
ARG TORCH_INDEX=
RUN if [ -n "${TORCH_INDEX}" ]; then \
        pip install --no-cache-dir torch torchvision --index-url "${TORCH_INDEX}"; \
    fi

ARG FLIMKIT_VERSION
ARG FLIMKIT_EXTRAS=gui
RUN pip install --no-cache-dir "flimkit[${FLIMKIT_EXTRAS}]==${FLIMKIT_VERSION}"

# Switch the default to flimkit-web-ui==<version> once it is published on PyPI
ARG FLIMKIT_WEB_UI=https://github.com/FLIMKit/flimkit-web-ui/archive/refs/heads/main.zip
ARG FLIMKIT_BRIDGE=flimkit-bridge
RUN if [ "${FLAVOUR}" = "web" ]; then \
        pip install --no-cache-dir "${FLIMKIT_WEB_UI}"; \
    else \
        pip install --no-cache-dir "${FLIMKIT_BRIDGE}"; \
    fi

# Drop what a running install never reads: the packages' own test suites and type
# stubs. __pycache__ stays, since a non-root user cannot write it back and every
# start would pay to recompile scipy and friends.
RUN find /opt/venv -type d -name tests -prune -exec rm -rf {} + \
    && find /opt/venv -name '*.pyi' -delete

FROM python:${PYTHON_VERSION}-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        tzdata \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# web serves the browser UI and needs Tk, so it needs an X server to draw on.
# bridge serves the HTTP API that QuPath and Fiji speak, and needs neither.
ARG FLAVOUR=web
RUN if [ "${FLAVOUR}" = "web" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            xvfb x11-utils python3-tk \
            libx11-6 libxext6 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
            fonts-dejavu-core \
        && rm -rf /var/lib/apt/lists/*; \
    fi

ENV TZ=Etc/UTC \
    MPLCONFIGDIR=/tmp/mpl-cache

# Everything pip installs is built in the stage above and copied across as one venv,
# so pip's own scratch space and the strip step below never reach this image.
COPY --from=build /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:${PATH}

RUN mkdir -p /tmp/mpl-cache && chmod 777 /tmp/mpl-cache

# TrueNAS and other hosts run containers as an arbitrary non-root user. Xvfb
# refuses to create /tmp/.X11-unix when euid is not 0, and FLIMKit writes its
# config under HOME, which is not /root for such a user.
ENV HOME=/config
RUN mkdir -p /tmp/.X11-unix /config \
    && chmod 1777 /tmp/.X11-unix \
    && chmod 777 /config

# The noVNC desktop view is off by default: its dependency tree (node, ghostscript,
# perl, a second system numpy) adds about 300 MB, and the web UI covers the work.
ARG INCLUDE_DESKTOP=0
RUN if [ "${INCLUDE_DESKTOP}" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            x11vnc fluxbox novnc websockify \
        && rm -rf /var/lib/apt/lists/* \
        && printf '<!doctype html>\n<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=scale&reconnect=true">\n' > /usr/share/novnc/index.html \
        && icon=$(python -c "import flimkit, os; print(os.path.join(os.path.dirname(flimkit.__file__), 'UI', 'icon.png'))") \
        && for ic in /usr/share/novnc/app/images/icons/novnc-*.png; do [ -e "$ic" ] && cp -f "$icon" "$ic"; done; \
    fi

# Empty unless ACCELERATOR=1. Folders named in FLIMKIT_PLUGIN_PATH load without the
# "Load from ~/.flimkit/plugins" switch, which nobody can tick inside a container.
COPY --from=accelerator /plugins /opt/flimkit-plugins
ENV FLIMKIT_PLUGIN_PATH=/opt/flimkit-plugins

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENV FLIMKIT_FLAVOUR=${FLAVOUR} \
    FLIMKIT_WEB_HOST=0.0.0.0 \
    FLIMKIT_WEB_PORT=14500 \
    FLIMKIT_WEB_HEADLESS=1 \
    FLIMKIT_BRIDGE_HOST=0.0.0.0 \
    FLIMKIT_BRIDGE_PORT=8765

EXPOSE 14500 14501 8765

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD python -c "import os, urllib.request; \
url = 'http://127.0.0.1:' + os.environ['FLIMKIT_BRIDGE_PORT'] + '/v1/status' if os.environ.get('FLIMKIT_FLAVOUR') == 'bridge' else 'http://127.0.0.1:' + os.environ['FLIMKIT_WEB_PORT'] + '/healthz'; \
urllib.request.urlopen(url, timeout=4)"

ARG FLIMKIT_VERSION
LABEL org.opencontainers.image.title="FLIMKit" \
      org.opencontainers.image.description="FLIMKit with its web UI, served on port 14500" \
      org.opencontainers.image.source="https://github.com/FLIMKit/flimkit-docker" \
      org.opencontainers.image.version="${FLIMKIT_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/docker-entrypoint.sh"]
