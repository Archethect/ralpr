FROM node:20-slim

# Install system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    xvfb \
    git \
    curl \
    jq \
    tmux \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# Install noVNC
RUN git clone --depth 1 https://github.com/novnc/noVNC.git /opt/novnc \
    && git clone --depth 1 https://github.com/novnc/websockify.git /opt/novnc/utils/websockify

# Install Playwright browsers
RUN npx playwright install --with-deps chromium

# Hardened: non-root user
RUN useradd -m -s /bin/bash ralpr
USER ralpr

WORKDIR /workspace

# Environment
ENV DISPLAY=:99
ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# Entrypoint starts Xvfb + noVNC + claude
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
