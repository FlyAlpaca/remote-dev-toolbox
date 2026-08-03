#!/bin/bash
set -euo pipefail

: "${CONTAINER_USER:=dev}"
: "${USER_UID:=1000}"
: "${USER_GID:=1000}"
: "${PROJECT_ROOT:=/workspace}"
: "${PROXY:=}"
: "${PROXY_PORT:=}"
: "${NO_PROXY:=localhost,127.0.0.1,::1}"

if [ "$(id -u)" -ne 0 ]; then
  echo "entrypoint must run as root so it can configure the SSH user" >&2
  exit 1
fi

configure_proxy() {
  local proxy_url environment_no_proxy shell_no_proxy

  if [ -z "${PROXY}" ] && [ -z "${PROXY_PORT}" ]; then
    return
  fi
  if [ -z "${PROXY}" ] || [ -z "${PROXY_PORT}" ]; then
    echo "PROXY and PROXY_PORT must be provided together" >&2
    exit 1
  fi
  if ! [[ "${PROXY}" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)$ ]]; then
    echo "PROXY must be a hostname or IP address without a URL scheme" >&2
    exit 1
  fi
  if ! [[ "${PROXY_PORT}" =~ ^[0-9]+$ ]] || \
     [ "${PROXY_PORT}" -lt 1 ] || [ "${PROXY_PORT}" -gt 65535 ]; then
    echo "PROXY_PORT must be an integer between 1 and 65535" >&2
    exit 1
  fi
  if [[ "${NO_PROXY}" =~ [[:cntrl:]] ]]; then
    echo "NO_PROXY must not contain control characters" >&2
    exit 1
  fi

  proxy_url="http://${PROXY}:${PROXY_PORT}"
  environment_no_proxy=${NO_PROXY//\\/\\\\}
  environment_no_proxy=${environment_no_proxy//\"/\\\"}
  printf -v shell_no_proxy '%q' "${NO_PROXY}"

  export HTTP_PROXY="${proxy_url}" HTTPS_PROXY="${proxy_url}" ALL_PROXY="${proxy_url}"
  export http_proxy="${proxy_url}" https_proxy="${proxy_url}" all_proxy="${proxy_url}"
  export NO_PROXY no_proxy="${NO_PROXY}"

  touch /etc/environment
  sed -i -E \
    '/^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)=/d' \
    /etc/environment
  printf '%s\n' \
    "HTTP_PROXY=\"${proxy_url}\"" \
    "HTTPS_PROXY=\"${proxy_url}\"" \
    "ALL_PROXY=\"${proxy_url}\"" \
    "NO_PROXY=\"${environment_no_proxy}\"" \
    "http_proxy=\"${proxy_url}\"" \
    "https_proxy=\"${proxy_url}\"" \
    "all_proxy=\"${proxy_url}\"" \
    "no_proxy=\"${environment_no_proxy}\"" \
    >> /etc/environment

  printf '%s\n' \
    "export HTTP_PROXY=\"${proxy_url}\"" \
    "export HTTPS_PROXY=\"${proxy_url}\"" \
    "export ALL_PROXY=\"${proxy_url}\"" \
    "export NO_PROXY=${shell_no_proxy}" \
    'export http_proxy="$HTTP_PROXY"' \
    'export https_proxy="$HTTPS_PROXY"' \
    'export all_proxy="$ALL_PROXY"' \
    'export no_proxy="$NO_PROXY"' \
    > /etc/profile.d/10-proxy.sh
  chmod 0644 /etc/profile.d/10-proxy.sh

  printf '%s\n' \
    "Acquire::http::Proxy \"${proxy_url}\";" \
    "Acquire::https::Proxy \"${proxy_url}\";" \
    > /etc/apt/apt.conf.d/95proxy

  printf '%s\n' \
    'Defaults env_keep += "HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY"' \
    'Defaults env_keep += "http_proxy https_proxy all_proxy no_proxy"' \
    > /etc/sudoers.d/10-proxy-env
  chmod 0440 /etc/sudoers.d/10-proxy-env

  echo "configured global proxy at ${PROXY}:${PROXY_PORT}"
}

configure_proxy

if ! [[ "${CONTAINER_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "invalid CONTAINER_USER: ${CONTAINER_USER}" >&2
  exit 1
fi

if ! [[ "${USER_UID}" =~ ^[0-9]+$ ]] || ! [[ "${USER_GID}" =~ ^[0-9]+$ ]]; then
  echo "USER_UID and USER_GID must be numeric" >&2
  exit 1
fi

# Resolve or create a group for the requested runtime GID.
GID_GROUP=$(getent group "${USER_GID}" | cut -d: -f1 || true)
NAME_GROUP=$(getent group "${CONTAINER_USER}" | cut -d: -f1 || true)
if [ -n "${GID_GROUP}" ]; then
  TARGET_GROUP=${GID_GROUP}
elif [ -n "${NAME_GROUP}" ]; then
  groupmod --gid "${USER_GID}" "${NAME_GROUP}"
  TARGET_GROUP=${NAME_GROUP}
else
  groupadd --gid "${USER_GID}" "${CONTAINER_USER}"
  TARGET_GROUP=${CONTAINER_USER}
fi

# Reuse an account with the requested UID when possible, otherwise create one.
NAME_USER=$(getent passwd "${CONTAINER_USER}" | cut -d: -f1 || true)
UID_USER=$(getent passwd "${USER_UID}" | cut -d: -f1 || true)
if [ -n "${NAME_USER}" ]; then
  CURRENT_UID=$(id -u "${CONTAINER_USER}")
  if [ "${CURRENT_UID}" != "${USER_UID}" ]; then
    if [ -n "${UID_USER}" ] && [ "${UID_USER}" != "${CONTAINER_USER}" ]; then
      echo "cannot assign UID ${USER_UID} to ${CONTAINER_USER}: already used by ${UID_USER}" >&2
      exit 1
    fi
    usermod --uid "${USER_UID}" "${CONTAINER_USER}"
  fi
  usermod --gid "${USER_GID}" --home "/home/${CONTAINER_USER}" --move-home --shell /bin/bash "${CONTAINER_USER}"
elif [ -n "${UID_USER}" ]; then
  usermod --login "${CONTAINER_USER}" --gid "${USER_GID}" \
    --home "/home/${CONTAINER_USER}" --move-home --shell /bin/bash "${UID_USER}"
else
  useradd --uid "${USER_UID}" --gid "${TARGET_GROUP}" --create-home \
    --home-dir "/home/${CONTAINER_USER}" --shell /bin/bash "${CONTAINER_USER}"
fi

HOME_DIR=$(getent passwd "${CONTAINER_USER}" | cut -d: -f6)
echo "${CONTAINER_USER}" > /etc/container_user

if [ -e "${HOST_SHADOW_PATH:-}" ]; then
  if [ ! -f "${HOST_SHADOW_PATH}" ]; then
    echo "HOST_SHADOW_PATH does not point to a file: ${HOST_SHADOW_PATH}" >&2
    exit 1
  fi

  HOST_USER=${HOST_SHADOW_USER:-${CONTAINER_USER}}
  HOST_PASSWORD_HASH=$(awk -F: -v user="${HOST_USER}" '$1 == user { print $2; exit }' "${HOST_SHADOW_PATH}")
  if [ -z "${HOST_PASSWORD_HASH}" ]; then
    echo "user ${HOST_USER} was not found in HOST_SHADOW_PATH" >&2
    exit 1
  fi
  if [[ ! "${HOST_PASSWORD_HASH}" =~ ^\$[156y]\$ ]]; then
    echo "user ${HOST_USER} does not have a supported password hash in HOST_SHADOW_PATH" >&2
    exit 1
  fi

  usermod --password "${HOST_PASSWORD_HASH}" "${CONTAINER_USER}"
  echo "${CONTAINER_USER} ALL=(ALL) ALL" > "/etc/sudoers.d/${CONTAINER_USER}"
else
  echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${CONTAINER_USER}"
fi
chmod 0440 "/etc/sudoers.d/${CONTAINER_USER}"

mkdir -p "${HOME_DIR}/.codex" "${PROJECT_ROOT}" /var/run/sshd
chown "${USER_UID}:${USER_GID}" "${HOME_DIR}" "${HOME_DIR}/.codex" "${PROJECT_ROOT}"
chmod 700 "${HOME_DIR}/.codex"

# Persist the runtime user's SSH keys and config when a data directory is mounted.
if [ -e "${SSH_USER_DATA_PATH:-}" ]; then
  if [ ! -d "${SSH_USER_DATA_PATH}" ]; then
    echo "SSH_USER_DATA_PATH does not point to a directory: ${SSH_USER_DATA_PATH}" >&2
    exit 1
  fi
  chown -R "${USER_UID}:${USER_GID}" "${SSH_USER_DATA_PATH}"
  chmod 700 "${SSH_USER_DATA_PATH}"
  rm -rf "${HOME_DIR}/.ssh"
  ln -s "${SSH_USER_DATA_PATH}" "${HOME_DIR}/.ssh"
else
  mkdir -p "${HOME_DIR}/.ssh"
  chown "${USER_UID}:${USER_GID}" "${HOME_DIR}/.ssh"
  chmod 700 "${HOME_DIR}/.ssh"
fi

install_private_file() {
  local source_path=$1
  local target_path=$2
  local variable_name=$3

  if [ ! -f "${source_path}" ]; then
    echo "${variable_name} does not point to a file: ${source_path}" >&2
    exit 1
  fi

  if [ ! -f "${target_path}" ] || ! cmp -s "${source_path}" "${target_path}"; then
    cp "${source_path}" "${target_path}"
  fi
  chown "${USER_UID}:${USER_GID}" "${target_path}"
  chmod 600 "${target_path}"
}

configure_ssh_host_keys() {
  local keys_path=${SSH_HOST_KEYS_PATH:-}
  local key_type key_bits private_key public_key

  # Without a mounted key directory, keep the keys in the container layer.
  if [ ! -e "${keys_path}" ]; then
    ssh-keygen -A
    return
  fi
  if [ ! -d "${keys_path}" ]; then
    echo "SSH_HOST_KEYS_PATH does not point to a directory: ${keys_path}" >&2
    exit 1
  fi

  for key_type in rsa ecdsa ed25519; do
    private_key="${keys_path}/ssh_host_${key_type}_key"
    public_key="${private_key}.pub"

    if [ -e "${private_key}" ] && [ ! -f "${private_key}" ]; then
      echo "SSH host key is not a regular file: ${private_key}" >&2
      exit 1
    fi
    if [ ! -e "${private_key}" ]; then
      if [ -e "${public_key}" ]; then
        echo "SSH host public key exists without its private key: ${public_key}" >&2
        exit 1
      fi
      key_bits=()
      if [ "${key_type}" = rsa ]; then
        key_bits=(-b 3072)
      elif [ "${key_type}" = ecdsa ]; then
        key_bits=(-b 256)
      fi
      ssh-keygen -q -t "${key_type}" "${key_bits[@]}" -N '' -f "${private_key}"
      echo "generated persistent SSH ${key_type} host key in ${keys_path}"
    elif [ ! -f "${public_key}" ]; then
      ssh-keygen -y -f "${private_key}" > "${public_key}"
    fi

    install -o root -g root -m 0600 "${private_key}" "/etc/ssh/ssh_host_${key_type}_key"
    install -o root -g root -m 0644 "${public_key}" "/etc/ssh/ssh_host_${key_type}_key.pub"
  done
}

# Install authorized_keys from a file mounted through the container manager.
if [ -e "${SSH_AUTHORIZED_KEYS_PATH:-}" ]; then
  install_private_file \
    "${SSH_AUTHORIZED_KEYS_PATH}" \
    "${HOME_DIR}/.ssh/authorized_keys" \
    SSH_AUTHORIZED_KEYS_PATH
fi

# Link a mounted VS Code Server data directory into the runtime user's home.
if [ -e "${VSCODE_SERVER_PATH:-}" ]; then
  if [ ! -d "${VSCODE_SERVER_PATH}" ]; then
    echo "VSCODE_SERVER_PATH does not point to a directory: ${VSCODE_SERVER_PATH}" >&2
    exit 1
  fi
  if [ ! -L "${HOME_DIR}/.vscode-server" ] || \
     [ "$(readlink "${HOME_DIR}/.vscode-server" 2>/dev/null || true)" != "${VSCODE_SERVER_PATH}" ]; then
    rm -rf "${HOME_DIR}/.vscode-server"
    ln -s "${VSCODE_SERVER_PATH}" "${HOME_DIR}/.vscode-server"
  fi
fi

# Link the complete Codex data directory when mounted. This preserves auth,
# config, sessions, history, and other Codex state across container recreation.
if [ -e "${CODEX_DATA_PATH:-}" ]; then
  if [ ! -d "${CODEX_DATA_PATH}" ]; then
    echo "CODEX_DATA_PATH does not point to a directory: ${CODEX_DATA_PATH}" >&2
    exit 1
  fi
  chown -R "${USER_UID}:${USER_GID}" "${CODEX_DATA_PATH}"
  chmod 700 "${CODEX_DATA_PATH}"
  rm -rf "${HOME_DIR}/.codex"
  ln -s "${CODEX_DATA_PATH}" "${HOME_DIR}/.codex"
fi

configure_ssh_host_keys
exec /usr/sbin/sshd -D -e
