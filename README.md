# Debian Remote Development Toolbox

基于 `debian:bookworm-slim` 的 SSH 远程开发镜像，内置 Git、编译工具、Miniconda、Node.js/npm 和 `@openai/codex`。容器启动时创建指定的开发用户，SSH 仅允许公钥认证。

## 快速开始

在仓库根目录准备挂载源：

```bash
mkdir -p workspace .vscode-server ssh-host-keys user-ssh .codex
test -f authorized_keys
test -d .codex
```

构建并启动：

```bash
docker compose up -d --build
docker compose logs -f remote-dev
```

连接 SSH：

```bash
ssh -p 2222 dev@<docker-host>
```

在 VS Code 中将同一 SSH 主机添加到 `Remote-SSH` 即可连接。

## 代理

代理作为启动参数传入，不使用 `.env`。`PROXY` 填主机名或 IP，不包含 `http://`：

```bash
PROXY=host.docker.internal PROXY_PORT=7890 \
  docker compose up -d --build --force-recreate
```

启动脚本会配置 HTTP(S) 代理环境变量、APT、SSH 登录 Shell 与 sudo。验证：

```bash
docker compose exec remote-dev bash -lc 'env | grep -i _proxy; curl -v https://www.google.com'
```

容器内不能用 `127.0.0.1` 访问宿主机代理；Docker Desktop 通常使用 `host.docker.internal`，Linux Docker Engine 请填写宿主机可达地址。

## 配置与挂载

常用环境变量：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `CONTAINER_USER` | `dev` | SSH 开发用户 |
| `USER_UID` / `USER_GID` | `1000` | 建议设为项目目录所有者的 UID/GID |
| `PROJECT_ROOT` | `/workspace` | 容器工作目录 |
| `PROJECT_STARTUP_SCRIPT` | 空 | 可选的项目启动脚本路径，脚本以开发用户身份运行 |
| `SSH_HOST_KEYS_PATH` | `/run/host/ssh-host-keys` | 持久化 SSH 服务端身份的密钥目录 |
| `SSH_USER_DATA_PATH` | `/run/host/user-ssh` | 持久化开发用户的 `~/.ssh` 目录 |
| `CODEX_DATA_PATH` | `/run/host/codex` | 持久化开发用户的 `~/.codex`，包括配置、会话和凭据 |
| `PROXY` / `PROXY_PORT` | 空 | HTTP(S) 代理主机和端口 |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | 不经过代理的地址 |

默认 Compose 挂载：

| 宿主机路径 | 容器路径 | 权限 |
| --- | --- | --- |
| `./workspace` | `/workspace` | 读写 |
| `./authorized_keys` | `/run/host/authorized_keys` | 只读 |
| `./ssh-host-keys` | `/run/host/ssh-host-keys` | 读写，仅宿主机管理员可访问 |
| `./user-ssh` | `/run/host/user-ssh` | 读写，开发用户的密钥与 SSH 配置 |
| `./.vscode-server` | `/run/host/vscode-server` | 读写 |
| `./.codex` | `/run/host/codex` | 读写，Codex 配置、会话和凭据 |

图形化 Docker 管理器使用相同的环境变量和映射即可；容器保持以 root 启动，入口脚本会创建实际开发用户。不要覆盖镜像默认命令。

首次启动时，入口脚本会在挂载的 `ssh-host-keys` 目录生成 SSH 主机密钥；以后重建容器会继续使用同一套密钥，客户端的 `known_hosts` 不会再因重建而失效。该目录包含服务端私钥，不要提交到 Git、共享给其他服务器或以只读方式挂载。若未挂载 `SSH_HOST_KEYS_PATH`，主机密钥会在容器启动时生成并只保存在容器文件系统中，重建容器后会改变。镜像本身不包含主机私钥，避免多个新容器意外共享同一身份。

挂载 `user-ssh` 后，开发用户的 `~/.ssh` 会链接到该目录，`ssh-keygen` 生成的 `id_rsa`、`id_ed25519`、对应公钥、`known_hosts` 和 `config` 都会跨容器重建保留。这里保存的是开发用户对外连接使用的客户端密钥，不要与 `ssh-host-keys` 中的服务端身份密钥混用。

挂载 `.codex` 后，开发用户的 `~/.codex` 会链接到该目录，Codex 的配置、会话、历史记录、登录凭据和其他运行状态都会跨容器重建保留。该目录包含敏感信息，建议仅当前用户可访问（例如 `chmod 700 "$HOME/.codex"`），不要提交到 Git 或共享给其他用户。

可选复用宿主机密码时，将 `/etc/shadow` 只读挂载到 `/run/host/shadow`，并设置 `HOST_SHADOW_USER`。该文件高度敏感；未挂载时容器用户使用免密码 sudo。

## 直接运行

```bash
mkdir -p "$HOME/.remote-dev/ssh-host-keys" "$HOME/.remote-dev/user-ssh" "$HOME/.codex"
docker run -d \
  --name remote-dev \
  --restart unless-stopped \
  -p 2222:22 \
  -e CONTAINER_USER="$(id -un)" \
  -e USER_UID="$(id -u)" \
  -e USER_GID="$(id -g)" \
  -e PROXY=host.docker.internal \
  -e PROXY_PORT=7890 \
  -v "$HOME/projects/example:/workspace" \
  -v "$HOME/.ssh/authorized_keys:/run/host/authorized_keys:ro" \
  -v "$HOME/.remote-dev/ssh-host-keys:/run/host/ssh-host-keys" \
  -v "$HOME/.remote-dev/user-ssh:/run/host/user-ssh" \
  -v "$HOME/.vscode-server:/run/host/vscode-server" \
  -v "$HOME/.codex:/run/host/codex" \
  remote-dev-toolbox:1.0.18
```

如果不需要代理，删除两行 `PROXY` 参数即可。

## Compose 配置

将以下内容保存为 `compose.yaml`：

```yaml
services:
  remote-dev:
    build: .
    image: remote-dev-toolbox:1.0.18
    container_name: remote-dev
    restart: unless-stopped
    ports:
      - "2222:22"
    environment:
      CONTAINER_USER: ${CONTAINER_USER:-dev}
      USER_UID: ${USER_UID:-1000}
      USER_GID: ${USER_GID:-1000}
      PROXY: ${PROXY:-host.docker.internal}
      PROXY_PORT: ${PROXY_PORT:-7890}
    volumes:
      - ${HOME}/projects/example:/workspace
      - ${HOME}/.ssh/authorized_keys:/run/host/authorized_keys:ro
      - ${HOME}/.remote-dev/ssh-host-keys:/run/host/ssh-host-keys
      - ${HOME}/.remote-dev/user-ssh:/run/host/user-ssh
      - ${HOME}/.vscode-server:/run/host/vscode-server
      - ${HOME}/.codex:/run/host/codex
    security_opt:
      - no-new-privileges:false
```

准备目录后启动。使用命令行传入的变量可以确保容器用户与当前宿主机用户一致：

```bash
mkdir -p "$HOME/.remote-dev/ssh-host-keys" "$HOME/.remote-dev/user-ssh" "$HOME/.codex"
CONTAINER_USER="$(id -un)" \
USER_UID="$(id -u)" \
USER_GID="$(id -g)" \
PROXY=host.docker.internal PROXY_PORT=7890 \
  docker compose up -d
```

如果不需要代理，可删除 `PROXY` 和 `PROXY_PORT` 两个环境变量，并从配置中删除对应的 `environment` 项。

## 项目启动脚本

镜像不固化具体项目的启动命令。需要自动启动项目服务时，在 Compose 配置中挂载项目自己的脚本，并设置 `PROJECT_STARTUP_SCRIPT`：

```yaml
services:
  remote-dev:
    environment:
      PROJECT_STARTUP_SCRIPT: /run/host/project-start.sh
    volumes:
      - ./project-start.sh:/run/host/project-start.sh:ro
```

例如 `Stock` 项目的 `project-start.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

(
  cd /workspace/Stock
  exec .conda/bin/python -m stock_decision.cli serve
) &
backend_pid=$!

(
  cd /workspace/Stock/frontend
  npm install
  exec npm run dev
) &
frontend_pid=$!

trap 'kill "${backend_pid}" "${frontend_pid}" 2>/dev/null || true' EXIT TERM INT
wait -n "${backend_pid}" "${frontend_pid}"
```

启动脚本由入口脚本以 `CONTAINER_USER` 指定的开发用户运行，输出会进入容器日志。未设置 `PROJECT_STARTUP_SCRIPT` 时，容器只启动 SSH 服务。

## 构建与发布

```bash
docker build -t remote-dev-toolbox:1.0.18 .
```

构建阶段需要 APT 代理时：

```bash
docker build -t remote-dev-toolbox:1.0.18 \
  --build-arg PROXY=<proxy-host> \
  --build-arg PROXY_PORT=<proxy-port> .
```

镜像仅支持 `linux/amd64`。推送 `vMAJOR.MINOR.PATCH` 标签会通过 GitHub Actions 发布到 GHCR 和 Docker Hub。

## 排查

```bash
docker ps -a
docker logs remote-dev
docker exec remote-dev sh -lc 'cat /etc/container_user; conda --version; node --version; codex --version'
```

- `Exited (1)`：先查看日志；常见原因是容器没有以 root 启动、用户 UID/GID 无效，或挂载路径类型错误。
- `Permission denied (publickey)`：确认 SSH 用户等于 `CONTAINER_USER`，且私钥对应的公钥位于 `authorized_keys`。
- 挂载目录无权限：将 `USER_UID` 和 `USER_GID` 设为该目录所有者；远程 Docker/NAS 以 Docker daemon 所在主机的权限为准。
