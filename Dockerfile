FROM debian:bookworm-slim

ARG PROXY=""
ARG PROXY_PORT=""
ARG PROJECT_ROOT=/workspace

ENV CONTAINER_USER=dev \
    USER_UID=1000 \
    USER_GID=1000 \
    PROJECT_ROOT=${PROJECT_ROOT} \
    SSH_AUTHORIZED_KEYS_PATH=/run/host/authorized_keys \
    VSCODE_SERVER_PATH=/run/host/vscode-server \
    CODEX_AUTH_PATH=/run/host/codex-auth.json \
    HOST_SHADOW_PATH=/run/host/shadow

# Configure apt proxy if provided
RUN if [ -n "$PROXY" ]; then \
      echo "Acquire::http::Proxy \"http://$PROXY:$PROXY_PORT\";" > /etc/apt/apt.conf.d/95proxy; \
    fi

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo git curl wget ca-certificates gnupg build-essential passwd \
 && rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/95proxy

# Configure sshd to allow only public-key authentication
RUN mkdir -p /etc/ssh/sshd_config.d && \
    printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'UsePAM yes' \
      'PermitRootLogin no' \
      'PubkeyAuthentication yes' \
      'AuthorizedKeysFile .ssh/authorized_keys' \
      > /etc/ssh/sshd_config.d/10-public-key-only.conf

# Install Miniconda
ENV CONDA_DIR=/opt/conda
RUN curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh \
 && bash /tmp/miniconda.sh -b -p "$CONDA_DIR" \
 && rm /tmp/miniconda.sh \
 && "$CONDA_DIR/bin/conda" clean --all --yes \
 && find "$CONDA_DIR" -follow -type f -name '*.a' -delete \
 && find "$CONDA_DIR" -follow -type f -name '*.pyc' -delete \
 && ln -s "$CONDA_DIR/etc/profile.d/conda.sh" /etc/profile.d/conda.sh

ENV PATH=$CONDA_DIR/bin:$PATH

# Install Node.js (includes npm)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get update && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# Install OpenAI Codex globally
RUN npm install -g @openai/codex \
 && npm cache clean --force

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22

# Persistent writable directories. Single-file credentials remain explicit read-only bind mounts.
VOLUME ["/workspace", "/run/host/vscode-server"]

WORKDIR ${PROJECT_ROOT}
CMD ["/usr/local/bin/entrypoint.sh"]
