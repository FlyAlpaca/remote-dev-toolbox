FROM debian:bookworm-slim

ARG PROXY=""
ARG PROXY_PORT=""
ARG PROJECT_ROOT=/workspace

ENV CONTAINER_USER=dev \
    USER_UID=1000 \
    USER_GID=1000 \
    PROJECT_ROOT=${PROJECT_ROOT} \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SSH_AUTHORIZED_KEYS_PATH=/run/host/authorized_keys \
    SSH_HOST_KEYS_PATH=/run/host/ssh-host-keys \
    SSH_USER_DATA_PATH=/run/host/user-ssh \
    VSCODE_SERVER_PATH=/run/host/vscode-server \
    CODEX_DATA_PATH=/run/host/codex \
    PROJECT_STARTUP_SCRIPT= \
    HOST_SHADOW_PATH=/run/host/shadow

# Configure apt proxy if provided
RUN if [ -n "$PROXY" ]; then \
      echo "Acquire::http::Proxy \"http://$PROXY:$PROXY_PORT\";" > /etc/apt/apt.conf.d/95proxy; \
    fi

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo git bash-completion curl wget ca-certificates gnupg build-essential passwd locales libglib2.0-0 ripgrep util-linux tzdata \
 && sed -i '/^[# ]*en_US.UTF-8 UTF-8$/s/^# //' /etc/locale.gen \
 && locale-gen en_US.UTF-8 \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/95proxy \
 && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# Display UTF-8 paths (including Chinese filenames) directly in Git output.
RUN git config --system core.quotePath false

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

# Persistent writable directories. Host-managed state is mounted explicitly by the container manager.
VOLUME ["/workspace", "/run/host/vscode-server"]

WORKDIR ${PROJECT_ROOT}
CMD ["/usr/local/bin/entrypoint.sh"]
