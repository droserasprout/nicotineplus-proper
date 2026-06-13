# Production base: the prebuilt brotway image (patched GTK baked in + held). The
# local GTK-compile path (build-local) overrides BASE_IMAGE=ubuntu:<ver>, keeping
# `base` fork-free so Dockerfile.local can layer a worktree-built GTK on top.
ARG UBUNTU_VERSION=26.04
ARG BASE_IMAGE=ghcr.io/droserasprout/gtk-brotway:v3.0.0
FROM ${BASE_IMAGE} AS base
ARG DEBIAN_FRONTEND=noninteractive

# Set environment variables
ENV PUID=1000 \
    PGID=1000 \
    UPNP=False \
    AUTO_CONNECT=True \
    TRAY_ICON=False \
    NOTIFY_FILE=False \
    NOTIFY_FOLDER=False \
    NOTIFY_TITLE=False \
    NOTIFY_PM=False \
    NOTIFY_CHATROOM=False \
    NOTIFY_MENTION=False \
    WEB_UI_PORT=6565 \
    GDK_BACKEND=broadway \
    BROADWAY_DISPLAY=:5 \
    NICOTINE_GTK_VERSION=4 \
    NO_AT_BRIDGE=1 \
    NICOTINE_DATA_HOME=/home/nicotine/.local/share/nicotine

# Expose port for the application
EXPOSE ${WEB_UI_PORT}

# Install runtime dependencies and necessary packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    gir1.2-gtk-4.0 \
    gir1.2-adw-1 \
    gir1.2-gspell-1 \
    libgtk-4-bin \
    librsvg2-common \
    python3-gi \
    python3-gi-cairo \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    gettext \
    dbus-x11 \
    nginx-light \
    tzdata \
    locales \
    curl \
    wget \
    apache2-utils \
# Delete default ubuntu user claiming 1000:1000, create nicotine user and group
    && userdel -r ubuntu \
    && groupadd -g ${PGID} nicotine \
    && useradd -u ${PUID} -g ${PGID} -m -s /bin/bash nicotine \
# Create directories, symobolic links, and set permissions
    && mkdir -p /home/nicotine/.config/nicotine /home/nicotine/.local/share/nicotine/plugins \
                /home/nicotine/.local/share/nicotine/downloads \
                /home/nicotine/.local/share/nicotine/incomplete \
                /home/nicotine/.local/share/nicotine/received \
    && ln -s /home/nicotine/.config/nicotine /config \
    && ln -s /home/nicotine/.local/share/nicotine /data \
    && ln -s /home/nicotine/.local/share/nicotine/plugins /data/plugins \
    && chown -R nicotine:nicotine /config /data /home/nicotine/.config /home/nicotine/.local /var/log \
# Cleanup
    && apt-get autoremove -y \
    && apt-get autoclean \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Install Nicotine+ from the fork, run straight from source (like Dockerfile.local).
# Tracks the broadway branch by default; override NICOTINE_REF to pin a tag/SHA.
# git is install+used+purged in this single layer so it never ships; the source tree
# is pruned to what runs (nicotine launcher, pynicotine, data) - po/doc/debian/build-aux
# are build/i18n-only and unused at runtime (image runs English-only, no .mo built).
ARG NICOTINE_REPO=https://github.com/droserasprout/nicotine-plus.git
ARG NICOTINE_REF=broadway
# Cache-bust: when tracking a moving branch, pass --build-arg NICOTINE_REV=<tip-sha>
# (the Makefile resolves it) so a new branch tip forces a fresh clone instead of
# reusing a stale cached layer. Empty = unpinned (fine for clean CI runners).
ARG NICOTINE_REV=
RUN set -eux; \
    echo "nicotine-plus ${NICOTINE_REF} @ ${NICOTINE_REV:-unpinned}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends git ca-certificates; \
    git clone --depth 1 --branch "${NICOTINE_REF}" "${NICOTINE_REPO}" /opt/nicotine-plus; \
    rm -rf /opt/nicotine-plus/.git /opt/nicotine-plus/po /opt/nicotine-plus/doc \
           /opt/nicotine-plus/debian /opt/nicotine-plus/build-aux /opt/nicotine-plus/.github; \
    printf '#!/bin/sh\nexec python3 /opt/nicotine-plus/nicotine "$@"\n' > /usr/bin/nicotine; \
    chmod +x /usr/bin/nicotine; \
    python3 -m py_compile /opt/nicotine-plus/nicotine; \
    python3 -m compileall -q /opt/nicotine-plus/pynicotine; \
    apt-get purge -y git; \
    apt-get autoremove -y --purge; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Import configuration files and launch scripts
COPY config-default /home/nicotine/config-default
COPY default /etc/nginx/sites-available/default
COPY favicon.ico /var/www/favicon.ico
COPY init.sh /usr/local/bin/init.sh
COPY launch.sh /usr/local/bin/launch.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

# Make healthcheck script executable
RUN chmod +x /usr/local/bin/healthcheck.sh

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

# Run Nicotine+ startup script
CMD ["init.sh"]

# Production image (`--target fork`). The patched GTK comes from the brotway BASE_IMAGE
# (already installed + held), so there's nothing to add here - this stage just names
# the build target. On the ubuntu BASE_IMAGE (build-local), Dockerfile.local supplies
# the worktree-built GTK instead.
FROM base AS fork

# Demo image (:demo tag): enable the demodata plugin and default to offline, so the
# WebUI fills with synthetic data without touching the real Soulseek server. Last
# stage, so a bare `docker build` yields this; the production image is `--target fork`.
FROM fork AS demo
ENV AUTO_CONNECT=False
RUN sed -i "s/^enabled = .*/enabled = ['core_commands', 'demodata']/" /home/nicotine/config-default
