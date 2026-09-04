# check=error=true

FROM debian:bookworm-slim

ARG PROXY=""
ARG PROXY_PORT=""
ARG PROJECT_ROOT=/workspace

ENV CONTAINER_USER=dev \
    USER_UID=1000 \
    USER_GID=1000 \
    PROJECT_ROOT=${PROJECT_ROOT} \
    CONTAINER_PROMPT=DOCKER \
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

# Configure the build-time APT proxy when both arguments are provided.
RUN if [ -n "${PROXY}${PROXY_PORT}" ]; then \
      test -n "${PROXY}" && test -n "${PROXY_PORT}"; \
      printf '%s' "${PROXY}" | grep -Eq '^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)$'; \
      printf '%s' "${PROXY_PORT}" | grep -Eq '^[0-9]+$'; \
      test "${PROXY_PORT}" -ge 1 && test "${PROXY_PORT}" -le 65535; \
      printf 'Acquire::http::Proxy "http://%s:%s";\nAcquire::https::Proxy "http://%s:%s";\n' \
        "${PROXY}" "${PROXY_PORT}" "${PROXY}" "${PROXY_PORT}" \
        > /etc/apt/apt.conf.d/95proxy; \
    fi

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
 && apt-get install -y --no-install-recommends \
      bash-completion \
      build-essential \
      ca-certificates \
      chromium \
      curl \
      dnsutils \
      git \
      gnupg \
      iproute2 \
      iputils-ping \
      libglib2.0-0 \
      locales \
      net-tools \
      netcat-openbsd \
      openssh-server \
      passwd \
      ripgrep \
      sudo \
      tmux \
      traceroute \
      tzdata \
      util-linux \
      vim \
      wget \
 && sed -i '/^[# ]*en_US.UTF-8 UTF-8$/s/^# //' /etc/locale.gen \
 && locale-gen en_US.UTF-8 \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/95proxy \
 && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# Display UTF-8 paths (including Chinese filenames) directly in Git output.
RUN git config --system core.quotePath false

RUN printf '%s\n' \
    '' \
    '# Container prompt' \
    'if [[ $- == *i* ]]; then' \
    '    PS1="\[\e[1;31m\]${CONTAINER_PROMPT}\[\e[0m\] \u@\h:\w\$ "' \
    'fi' \
    >> /etc/bash.bashrc

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

# Install Node.js (includes npm) from the signed NodeSource repository without
# executing a downloaded setup script.
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
 && chmod 0644 /usr/share/keyrings/nodesource.gpg \
 && printf '%s\n' \
      'Types: deb' \
      'URIs: https://deb.nodesource.com/node_24.x' \
      'Suites: nodistro' \
      'Components: main' \
      'Architectures: amd64' \
      'Signed-By: /usr/share/keyrings/nodesource.gpg' \
      > /etc/apt/sources.list.d/nodesource.sources \
 && DEBIAN_FRONTEND=noninteractive apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# Prepare a user-writable global npm prefix. The entrypoint keeps the image
# running as root long enough to map the runtime user to the host UID/GID.
# This bootstrap user only owns the packages installed during the image build.
RUN groupadd --gid "${USER_GID}" "${CONTAINER_USER}" \
 && useradd --uid "${USER_UID}" --gid "${USER_GID}" \
      --create-home --home-dir "/home/${CONTAINER_USER}" \
      --shell /bin/bash "${CONTAINER_USER}" \
 && mkdir -p /opt/npm-global \
 && chown -R "${USER_UID}:${USER_GID}" /opt/npm-global

ENV NPM_CONFIG_PREFIX=/opt/npm-global
ENV PATH=/opt/npm-global/bin:$CONDA_DIR/bin:$PATH

# Keep npm-installed CLI tools available in SSH, VS Code Remote SSH, and tmux
# login shells, which may initialize PATH independently of the image ENV.
RUN printf '%s\n' \
      'export PATH="/opt/npm-global/bin:$PATH"' \
      'export NPM_CONFIG_PREFIX="/opt/npm-global"' \
      > /etc/profile.d/20-codex.sh \
 && chmod 0644 /etc/profile.d/20-codex.sh

# Install OpenAI Codex globally as the non-root bootstrap user.
USER ${CONTAINER_USER}
RUN HOME="/home/${CONTAINER_USER}" npm install -g @openai/codex \
 && HOME="/home/${CONTAINER_USER}" npm cache clean --force
USER root

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Apply the tmux defaults to every runtime user, including dynamically mapped users.
COPY docker/tmux.conf /etc/tmux.conf

EXPOSE 22
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["bash", "-c", "/usr/sbin/sshd -t && nc -z 127.0.0.1 22"]

# Persistent writable directories. Host-managed state is mounted explicitly by the container manager.
VOLUME ["/workspace", "/run/host/vscode-server"]

WORKDIR ${PROJECT_ROOT}
CMD ["/usr/local/bin/entrypoint.sh"]
