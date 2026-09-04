# Debian Remote Development Toolbox

基于 `debian:bookworm-slim` 的 SSH 远程开发镜像，内置 Git、编译工具、Vim、tmux、网络调试工具、Miniconda、Node.js/npm、`@openai/codex` 和 `@loongphy/codex-auth`。镜像构建时准备开发用户，容器启动时再按宿主机 UID/GID 调整实际开发用户，SSH 仅允许公钥认证。

## 快速开始

在仓库根目录准备挂载源：

```bash
mkdir -p workspace .vscode-server ssh-host-keys user-ssh .codex
cp "$HOME/.ssh/id_ed25519.pub" authorized_keys
chmod 600 authorized_keys
```

如果使用的不是 `~/.ssh/id_ed25519.pub`，请替换为实际用于登录的 SSH 公钥文件。

构建并启动：

```bash
CONTAINER_USER="$(id -un)" USER_UID="$(id -u)" USER_GID="$(id -g)" \
  docker compose up -d --build
docker compose logs -f remote-dev
```

连接 SSH：

```bash
ssh -p 2222 "$(id -un)@<docker-host>"
```

在 VS Code 中将同一 SSH 主机添加到 `Remote-SSH` 即可连接。

## tmux 会话

镜像内置 tmux，并加载 `/etc/tmux.conf`。容器启动时会自动以开发用户身份创建 `codex` 一个 detached 会话，登录容器后直接连接：

```bash
tmux attach -t codex
```

查看会话：

```bash
tmux ls
```

镜像中的 `tmux` 命令会强制启用 UTF-8。这样即使 SSH 客户端或外层 Bash 转发了非 UTF-8 locale，Codex 输出中的中文也不会被 tmux 替换为下划线。

## 代理

代理作为启动参数传入，不使用 `.env`。`PROXY` 填主机名或 IP，不包含 `http://`：

```bash
CONTAINER_USER="$(id -un)" USER_UID="$(id -u)" USER_GID="$(id -g)" \
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
| `CONTAINER_PROMPT` | `remote-dev` | 交互式 Shell 提示符前缀 |
| `PROJECT_ROOT` | `/workspace` | 容器工作目录 |
| `PROJECT_STARTUP_SCRIPT` | 空 | 可选的项目启动脚本路径，脚本以开发用户身份运行 |
| `SSH_HOST_KEYS_PATH` | `/run/host/ssh-host-keys` | 持久化 SSH 服务端身份的密钥目录 |
| `SSH_USER_DATA_PATH` | `/run/host/user-ssh` | 持久化开发用户的 `~/.ssh` 目录 |
| `VSCODE_SERVER_PATH` | `/run/host/vscode-server` | 持久化开发用户的 `~/.vscode-server` |
| `CODEX_DATA_PATH` | `/run/host/codex` | 持久化开发用户的 `~/.codex`，包括配置、会话和凭据 |
| `NPM_CONFIG_PREFIX` | `/opt/npm-global` | 普通用户可写的全局 npm 包目录 |
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

全局 npm 包安装在 `/opt/npm-global`，启动时会将该目录交给实际开发用户。因此容器内执行 `npm install -g <package>` 或更新 Codex 不需要管理员权限；Node.js/npm 的系统安装本身仍属于镜像构建内容，需要重新构建镜像才能更新。

首次启动时，入口脚本会在挂载的 `ssh-host-keys` 目录生成 SSH 主机密钥；以后重建容器会继续使用同一套密钥，客户端的 `known_hosts` 不会再因重建而失效。该目录包含服务端私钥，不要提交到 Git、共享给其他服务器或以只读方式挂载。若未挂载 `SSH_HOST_KEYS_PATH`，主机密钥会在容器启动时生成并只保存在容器文件系统中，重建容器后会改变。镜像本身不包含主机私钥，避免多个新容器意外共享同一身份。

挂载 `user-ssh` 后，开发用户的 `~/.ssh` 会链接到该目录，`ssh-keygen` 生成的 `id_rsa`、`id_ed25519`、对应公钥、`known_hosts` 和 `config` 都会跨容器重建保留。这里保存的是开发用户对外连接使用的客户端密钥，不要与 `ssh-host-keys` 中的服务端身份密钥混用。

挂载 `.vscode-server` 后，开发用户的 `~/.vscode-server` 会链接到对应目录，远程扩展与服务器二进制会跨容器重建保留。

挂载 `.codex` 后，开发用户的 `~/.codex` 会链接到该目录，Codex 的配置、会话、历史记录、登录凭据和其他运行状态都会跨容器重建保留。该目录包含敏感信息，建议仅当前用户可访问（例如 `chmod 700 "$HOME/.codex"`），不要提交到 Git 或共享给其他用户。

可选复用宿主机密码时，将 `/etc/shadow` 只读挂载到 `/run/host/shadow`，并设置 `HOST_SHADOW_USER`。该文件高度敏感；未挂载时容器用户使用免密码 sudo。

## 直接运行

```bash
mkdir -p "$HOME/.remote-dev/ssh-host-keys" "$HOME/.remote-dev/user-ssh" \
  "$HOME/.vscode-server" "$HOME/.codex"
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
  remote-dev-toolbox:local
```

如果不需要代理，删除两行 `PROXY` 参数即可。

## Compose 配置

仓库已提供可直接使用的 `compose.yaml`，默认把仓库内的 `workspace` 和各持久化目录挂载到容器。可通过环境变量调整 SSH 端口、用户和代理：

```bash
CONTAINER_USER="$(id -un)" \
USER_UID="$(id -u)" \
USER_GID="$(id -g)" \
SSH_PORT=2222 \
PROXY=host.docker.internal PROXY_PORT=7890 \
  docker compose up -d --build
```

如果不需要代理，删除 `PROXY` 和 `PROXY_PORT` 两个命令行变量即可。Compose 会把代理同时用于镜像构建与容器运行。默认 SSH 端口会监听宿主机全部网卡；只允许本机连接时，将 `compose.yaml` 中的端口映射改为 `127.0.0.1:${SSH_PORT:-2222}:22`。

## 项目启动脚本

镜像不固化具体项目的启动命令。需要自动启动项目服务时，在 Compose 配置中挂载项目自己的脚本，并设置 `PROJECT_STARTUP_SCRIPT`：

```yaml
services:
  remote-dev:
    # 调整为不短于项目完成优雅停机所需的最长时间。
    stop_grace_period: 2m
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

启动脚本由入口脚本以 `CONTAINER_USER` 指定的开发用户运行，输出会进入容器日志。入口脚本保持为容器 PID 1，并在收到 `TERM`、`INT` 或 `HUP` 时将信号转发给项目和 SSH 服务的独立进程组，等待它们退出。项目脚本或 `sshd` 任意一方提前退出时，入口脚本也会终止并等待另一方。未设置 `PROJECT_STARTUP_SCRIPT` 时，容器只监管 SSH 服务。

`stop_grace_period` 应覆盖项目停止接收请求、排空调度任务以及注销外部服务所需的最长时间，并留出余量；超时后 Docker 仍会发送 `SIGKILL`。

## 构建与发布

```bash
docker build -t remote-dev-toolbox:local .
```

构建阶段需要 APT 代理时：

```bash
docker build -t remote-dev-toolbox:local \
  --build-arg PROXY=<proxy-host> \
  --build-arg PROXY_PORT=<proxy-port> .
```

镜像仅支持 `linux/amd64`。推送 `vMAJOR.MINOR.PATCH` 标签会通过 GitHub Actions 发布到 GHCR 和 Docker Hub。

## 排查

```bash
docker ps -a
docker logs remote-dev
docker inspect --format '{{.State.Health.Status}}' remote-dev
docker exec remote-dev sh -lc 'cat /etc/container_user; conda --version; node --version; codex --version'
```

- `Exited (1)`：先查看日志；常见原因是容器没有以 root 启动、用户 UID/GID 无效，或挂载路径类型错误。
- `Permission denied (publickey)`：确认 SSH 用户等于 `CONTAINER_USER`，且私钥对应的公钥位于 `authorized_keys`。
- 挂载目录无权限：将 `USER_UID` 和 `USER_GID` 设为该目录所有者；远程 Docker/NAS 以 Docker daemon 所在主机的权限为准。
