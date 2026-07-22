# Debian Remote Development Toolbox

基于 `debian:bookworm-slim` 的通用远程开发镜像，包含：

- OpenSSH Server，仅允许公钥认证
- `sudo`、`git`、`curl`、`wget` 和常用编译工具
- Miniconda
- Node.js 20 和 npm
- 全局安装的 `@openai/codex`
- 运行容器时动态创建开发用户

镜像的构建者与使用者相互独立。容器用户在启动时通过环境变量确定，不在构建阶段固定。

## 项目结构

```text
.
├── Dockerfile
├── README.md
├── .dockerignore
├── .gitignore
├── docker/
│   └── entrypoint.sh
└── .github/
    └── workflows/
        └── publish.yml
```

Docker 构建上下文是仓库根目录；Dockerfile 会复制 `docker/entrypoint.sh`。本地构建和 GitHub Actions 都应从仓库根目录执行。

## 镜像名称和版本

本文统一使用：

```text
remote-dev-toolbox:1.0.0
```

版本号遵循 `MAJOR.MINOR.PATCH`：

- `PATCH`：向后兼容的问题修复
- `MINOR`：向后兼容的新功能
- `MAJOR`：存在不兼容的配置或行为变化

## 构建镜像

```bash
docker build -t remote-dev-toolbox:1.0.0 .
```

如需使用 APT 代理：

```bash
docker build -t remote-dev-toolbox:1.0.0 \
  --build-arg PROXY=<proxy-host> \
  --build-arg PROXY_PORT=<proxy-port> \
  .
```

当前构建固定使用 Miniconda Linux x86_64 安装器，因此本地和 CI 仅支持：

```text
linux/amd64
```

## 自动构建与发布

GitHub Actions 工作流位于 `.github/workflows/publish.yml`，会同时发布到：

```text
ghcr.io/FlyAlpaca/remote-dev-toolbox
haobiubiu/remote-dev-toolbox
```

触发和标签规则：

| 事件 | 行为 | 标签 |
| --- | --- | --- |
| Push tag `v1.2.3` | 构建并推送 GHCR 和 Docker Hub | `latest`、`1.2.3`、`1.2`、`1`、`sha-<commit>` |

普通分支提交和 Pull Request 不触发镜像构建。只有推送符合严格 `vMAJOR.MINOR.PATCH` 三段格式的 tag 才会构建和发布；最新版本 tag 同时更新 `latest`。

GitHub 仓库需要：

- Actions workflow 具有 `packages: write` 权限，GHCR 使用自动提供的 `GITHUB_TOKEN`。
- Repository Secrets 中配置 `DOCKERHUB_USERNAME`。
- Repository Secrets 中配置 `DOCKERHUB_TOKEN`，使用具有写权限的 Docker Hub Access Token，不要使用账户密码。
- Docker Hub 中准备名为 `remote-dev-toolbox` 的仓库或确保账号有权自动创建。

拉取 main 最新镜像：

```bash
docker pull ghcr.io/FlyAlpaca/remote-dev-toolbox:latest
docker pull haobiubiu/remote-dev-toolbox:latest
```

拉取固定版本：

```bash
docker pull ghcr.io/FlyAlpaca/remote-dev-toolbox:1.0.0
docker pull haobiubiu/remote-dev-toolbox:1.0.0
```

工作流只在受控的版本 tag 推送时登录 Registry 和读取 Docker Hub Secrets。

## 使用图形化 Docker 管理器

可以通过 Docker Desktop、Portainer、群晖 Container Manager 等工具创建容器。

### 基本配置

| 配置项       | 值                         |
| ------------ | -------------------------- |
| 镜像         | `remote-dev-toolbox:1.0.0` |
| 容器名称     | `remote-dev`               |
| 容器启动命令 | 使用镜像默认命令，不要覆盖 |
| 容器运行用户 | 保持为空或使用 `root`      |
| 重启策略     | `unless-stopped`（推荐）   |

入口脚本必须以 root 启动，以便创建用户、设置权限并启动 sshd。SSH 登录后使用的是运行时创建的非 root 用户。

### 端口映射

| 宿主机端口 | 容器端口 | 协议 | 用途                     |
| ---------- | -------- | ---- | ------------------------ |
| `2222`     | `22`     | TCP  | SSH / VS Code Remote SSH |

### 环境变量

| 变量                       | 示例值                      | 默认值           | 说明                                                              |
| -------------------------- | --------------------------- | ---------------- | ----------------------------------------------------------------- |
| `CONTAINER_USER`           | `developer`                 | `dev`            | 容器内 SSH 用户名                                                 |
| `USER_UID`                 | `1000`                      | `1000`           | 容器用户 UID，建议与宿主目录所有者一致                            |
| `USER_GID`                 | `1000`                      | `1000`           | 容器用户 GID，建议与宿主目录所有者一致                            |
| `PROJECT_ROOT`             | `/workspace`                | `/workspace`     | 容器内工作目录                                                    |
| `SSH_AUTHORIZED_KEYS_PATH` | `/run/host/authorized_keys` | `/run/host/authorized_keys` | SSH 授权文件的固定中转路径 |
| `VSCODE_SERVER_PATH`       | `/run/host/vscode-server`   | `/run/host/vscode-server`   | VS Code Server 目录的固定中转路径 |
| `CODEX_AUTH_PATH`          | `/run/host/codex-auth.json` | `/run/host/codex-auth.json` | Codex `auth.json` 的固定中转路径 |
| `HOST_SHADOW_PATH`         | `/run/host/shadow`          | `/run/host/shadow`          | 可选的宿主机 `/etc/shadow` 只读挂载路径；文件存在时 sudo 要求密码 |
| `HOST_SHADOW_USER`         | `host-user`                 | `CONTAINER_USER`            | 从外部 shadow 中读取密码哈希的用户名 |

Linux 上可通过以下命令查询当前用户的 UID 和 GID：

```bash
id -u
id -g
```

### 镜像卷声明

镜像在 Dockerfile 中声明了以下可写目录：

```text
/workspace
/run/host/vscode-server
```

图形化管理器通常会自动显示这两个卷挂载点，创建容器时可以为它们选择宿主机目录或 Docker 命名卷。如果不手动指定，Docker 会创建匿名卷。

单文件凭据没有使用 `VOLUME` 声明，仍需显式配置只读 bind mount：

```text
/run/host/authorized_keys
/run/host/codex-auth.json
/run/host/shadow
```

原因是 Dockerfile 的 `VOLUME` 只能声明容器路径，不能指定宿主机源文件，也不能表达单文件必须以只读方式挂载。将敏感文件声明为匿名卷还可能掩盖镜像路径并产生无用卷。

### 文件和目录映射

图形化管理器中请使用“卷”“存储”“文件夹映射”或“Bind mount”页面添加映射。宿主机路径应使用绝对路径；部分管理器不会展开 `~` 或 `$HOME`。

| 宿主机路径示例                           | 容器路径                    | 权限 | 用途                              |
| ---------------------------------------- | --------------------------- | ---- | --------------------------------- |
| `/home/<host-user>/projects/example`     | `/workspace`                | 读写 | 项目文件                          |
| `/home/<host-user>/.ssh/authorized_keys` | `/run/host/authorized_keys` | 只读 | SSH 登录公钥列表                  |
| `/home/<host-user>/.vscode-server`       | `/run/host/vscode-server`   | 读写 | 持久化 VS Code Server、扩展和缓存 |
| `/home/<host-user>/.codex/auth.json`     | `/run/host/codex-auth.json` | 只读 | 向容器提供 Codex 登录凭据         |
| `/etc/shadow`                            | `/run/host/shadow`          | 只读 | 可选：复用宿主机用户密码哈希      |

这些路径已经作为镜像默认环境变量声明。创建容器时只需添加对应映射，不需要重复填写路径环境变量；只有需要改变容器内中转路径时才覆盖它们。`HOST_SHADOW_USER` 未在镜像中固定，默认使用 `CONTAINER_USER`。

入口脚本会：

- 将 `authorized_keys` 复制到 `/home/<container-user>/.ssh/authorized_keys`，权限设为 `600`。
- 将 `/home/<container-user>/.vscode-server` 链接到 `VSCODE_SERVER_PATH`。
- 将 Codex `auth.json` 复制到 `/home/<container-user>/.codex/auth.json`，权限设为 `600`。
- 如果外部 shadow 文件存在，从中提取 `HOST_SHADOW_USER` 的密码哈希，设置为容器用户密码，并要求 sudo 输入密码；没有挂载该文件时保持免密码 sudo。

中转路径使同一个镜像可以支持任意运行时用户名，并避免在用户 home 尚未创建时直接挂载到目标路径。

> `auth.json` 包含敏感凭据。建议只读挂载，不要提交到 Git、公共共享目录或不受信任的备份。

### 复用宿主机用户密码

可选地将宿主机 `/etc/shadow` 只读挂载到容器中。入口脚本只读取指定用户的密码哈希，不会覆盖容器自身的 `/etc/shadow`：

```text
宿主机：/etc/shadow
容器内：/run/host/shadow
权限：只读
```

设置环境变量：

```text
HOST_SHADOW_PATH=/run/host/shadow
HOST_SHADOW_USER=<host-user>
```

如果 `HOST_SHADOW_USER` 与 `CONTAINER_USER` 相同，可以省略 `HOST_SHADOW_USER`。配置后，容器用户会使用外部 shadow 中该用户的密码，执行 `sudo` 时需要输入宿主机对应密码。SSH 仍然只允许公钥认证，密码不能用于 SSH 登录。

> `/etc/shadow` 包含宿主机所有本地用户的密码哈希，是高度敏感文件。必须只读挂载，不能将容器开放给不受信任的 root 用户或进程。更安全的方式仍是为容器单独生成密码哈希文件；这里只按复用宿主机密码的需求提供可选支持。

以下情况会导致容器启动失败并输出明确日志：

- shadow 挂载路径不是普通文件。
- `HOST_SHADOW_USER` 在文件中不存在。
- 用户密码被锁定，或其字段不是支持的 `$1$`、`$5$`、`$6$`、`$y$` crypt 哈希。

## 使用命令行创建容器

以下示例使用传统的 `-v` 映射方式：

```bash
docker run -d \
  --name remote-dev \
  --restart unless-stopped \
  -p 2222:22 \
  -e CONTAINER_USER="$(id -un)" \
  -e USER_UID="$(id -u)" \
  -e USER_GID="$(id -g)" \
  -v "$HOME/projects/example:/workspace" \
  -v "$HOME/.ssh/authorized_keys:/run/host/authorized_keys:ro" \
  -v "$HOME/.vscode-server:/run/host/vscode-server" \
  -v "$HOME/.codex/auth.json:/run/host/codex-auth.json:ro" \
  remote-dev-toolbox:1.0.0
```

使用 `-v` 时，如果宿主机源路径不存在，Docker 可能自动创建目录。创建容器前应确认单文件映射确实是普通文件：

```bash
test -f "$HOME/.ssh/authorized_keys"
test -f "$HOME/.codex/auth.json"
mkdir -p "$HOME/.vscode-server"
```

容器会使用 `unless-stopped` 重启策略。创建后可通过以下命令检查状态和日志：

```bash
docker ps -a
docker logs remote-dev
```

如果需要复用的宿主机用户名与 `CONTAINER_USER` 不同，在启动命令中追加：

```bash
-e HOST_SHADOW_USER="<host-user>" \
```

`HOST_SHADOW_PATH` 已默认为 `/run/host/shadow`，因此启用宿主机密码时只需添加只读映射：

```bash
-v /etc/shadow:/run/host/shadow:ro \
```

`/etc/shadow` 必须是普通文件，并且 Docker daemon 必须有权创建该 bind mount：

```bash
test -f /etc/shadow
```

图形化管理器中应将该映射明确设置为只读。

## SSH 连接

使用默认容器用户时：

```bash
ssh -p 2222 dev@<docker-host>
```

设置了 `CONTAINER_USER` 时，将 `dev` 替换为实际用户名。

Windows SSH config 示例：

```sshconfig
Host remote-dev
    HostName <docker-host>
    Port 2222
    User <container-user>
    IdentityFile C:/Users/<windows-user>/.ssh/id_ed25519
    IdentitiesOnly yes
```

连接：

```powershell
ssh remote-dev
```

`IdentityFile` 对应私钥的公钥必须包含在挂载的 `authorized_keys` 中。

## VS Code Remote SSH

1. 确认容器正在运行。
2. 在 SSH config 中添加上述 `remote-dev` 配置。
3. 在 VS Code 中执行 `Remote-SSH: Connect to Host...`。
4. 选择 `remote-dev`。

`.vscode-server` 使用读写映射，以便安装服务端组件和扩展。宿主机目录必须允许 `USER_UID:USER_GID` 对应用户读写。

## 检查容器

查看状态和日志：

```bash
docker ps -a
docker logs remote-dev
```

检查运行时用户：

```bash
docker exec remote-dev sh -c 'cat /etc/container_user; getent passwd "$(cat /etc/container_user)"'
```

检查 SSH 授权文件：

```bash
docker exec remote-dev sh -c '
user=$(cat /etc/container_user)
home=$(getent passwd "$user" | cut -d: -f6)
ls -ld "$home/.ssh"
ls -l "$home/.ssh/authorized_keys"
ssh-keygen -lf "$home/.ssh/authorized_keys"
'
```

检查 VS Code 和 Codex 路径：

```bash
docker exec remote-dev sh -c '
user=$(cat /etc/container_user)
home=$(getent passwd "$user" | cut -d: -f6)
ls -ld "$home/.vscode-server"
ls -l "$home/.codex/auth.json"
'
```

检查工具链：

```bash
docker exec remote-dev sh -c 'conda --version; node --version; npm --version; codex --version'
```

## 常见问题

### 容器显示 `Exited (1)`

```bash
docker logs remote-dev
```

入口脚本会在以下情况主动退出：

- 容器没有以 root 启动。
- `CONTAINER_USER` 格式无效。
- `USER_UID` 或 `USER_GID` 不是数字。
- 配置的中转路径不存在或类型错误。
- 指定的 UID 已经被其他无法重命名的用户占用。

### SSH 显示 `Permission denied (publickey)`

检查：

- SSH config 中的 `User` 是否等于 `CONTAINER_USER`。
- 客户端私钥是否对应 `authorized_keys` 中的公钥。
- 宿主机 `authorized_keys` 是否为普通文件，而不是误创建的目录。
- `SSH_AUTHORIZED_KEYS_PATH` 是否与容器映射目标一致。

### 挂载后权限不足

将 `USER_UID` 和 `USER_GID` 设置为挂载目录实际所有者的 UID/GID。远程 Docker 或 NAS 环境中，路径和权限以 Docker daemon 所在主机为准，而不是图形化管理器客户端所在电脑。

宿主机启用 SELinux 时，还需要在图形化管理器中启用等效的共享标签设置，或为命令行 volume 添加 `:z`/`:Z`。
