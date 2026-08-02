# Debian Remote Development Toolbox

基于 `debian:bookworm-slim` 的 SSH 远程开发镜像，内置 Git、编译工具、Miniconda、Node.js/npm 和 `@openai/codex`。容器启动时创建指定的开发用户，SSH 仅允许公钥认证。

## 快速开始

在仓库根目录准备挂载源：

```bash
mkdir -p workspace .vscode-server
test -f authorized_keys
test -f auth.json
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
| `PROXY` / `PROXY_PORT` | 空 | HTTP(S) 代理主机和端口 |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | 不经过代理的地址 |

默认 Compose 挂载：

| 宿主机路径 | 容器路径 | 权限 |
| --- | --- | --- |
| `./workspace` | `/workspace` | 读写 |
| `./authorized_keys` | `/run/host/authorized_keys` | 只读 |
| `./.vscode-server` | `/run/host/vscode-server` | 读写 |
| `./auth.json` | `/run/host/codex-auth.json` | 只读 |

图形化 Docker 管理器使用相同的环境变量和映射即可；容器保持以 root 启动，入口脚本会创建实际开发用户。不要覆盖镜像默认命令。

可选复用宿主机密码时，将 `/etc/shadow` 只读挂载到 `/run/host/shadow`，并设置 `HOST_SHADOW_USER`。该文件高度敏感；未挂载时容器用户使用免密码 sudo。

## 直接运行

```bash
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
  -v "$HOME/.vscode-server:/run/host/vscode-server" \
  -v "$HOME/.codex/auth.json:/run/host/codex-auth.json:ro" \
  remote-dev-toolbox:1.0.0
```

如果不需要代理，删除两行 `PROXY` 参数即可。

## 构建与发布

```bash
docker build -t remote-dev-toolbox:1.0.0 .
```

构建阶段需要 APT 代理时：

```bash
docker build -t remote-dev-toolbox:1.0.0 \
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
