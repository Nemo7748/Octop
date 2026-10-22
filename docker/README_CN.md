# Octop Docker 部署

---

本目录包含 Octop 的 Docker 构建与部署相关文件。

### 文件说明

| 文件 | 说明 |
|------|------|
| `Dockerfile` | 多阶段镜像定义（构建上下文为仓库根目录） |
| `../.dockerignore` | 构建上下文忽略规则（Podman 与 BuildKit 均适用） |
| `docker_build.sh` | 从源码构建镜像（默认开启 BuildKit 缓存） |
| `docker-compose.yml` | 本地开发 / 自托管一键启动 |
| `docker-entrypoint.sh` | 容器入口：首次初始化数据库并启动服务 |

### 快速开始

**方式一：一键启动（推荐）**

在仓库根目录执行：

```bash
make docker-up
```

等价于 `docker compose -f docker/docker-compose.yml up -d --build`，但会先构建镜像再启动。停止用 `make docker-down`，看日志用 `make docker-logs`。

访问 `http://localhost:8088`，默认账号 `admin` / `octop`（仅首次初始化生效）。

> **安全提醒**：默认密码 `octop` 只能用于本机试跑。任何共享环境、演示环境、内网部署都必须先改：
>
> ```bash
> OCTOP_DEFAULT_PASSWORD='换成强密码' make docker-up
> ```
>
> 已经初始化过的实例改密码要走 `docker exec -it octop octop user passwd --username admin`，改环境变量不会覆盖已有账号。

**方式二：构建脚本**

```bash
bash docker/docker_build.sh
docker run -d \
  --name octop \
  -p 8088:8088 \
  -v octop-data:/data/.octop \
  -e HOME=/data \
  octop:latest
```

### 国内镜像加速

构建时可通过环境变量加速依赖下载：

```bash
PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple \
PIP_TRUSTED_HOST=mirrors.aliyun.com \
NPM_REGISTRY=https://registry.npmmirror.com \
APT_MIRROR=mirrors.aliyun.com \
bash docker/docker_build.sh
```

### 常用环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `HOME` | `/data` | 必须为 `/data`，数据目录映射到 `~/.octop` |
| `OCTOP_PORT` | `8088` | HTTP 服务端口 |
| `OCTOP_DEFAULT_PASSWORD` | `octop` | 首次管理员密码 |
| `OCTOP_ADMIN_USERNAME` | `admin` | 首次管理员用户名 |
| `OPENAI_API_KEY` | — | OpenAI 兼容 API Key |
| `DASHSCOPE_API_KEY` | — | 阿里云通义千问 API Key |

Compose 可在 `docker/.env` 中配置上述变量。

### 数据持久化

- Compose 默认使用**命名卷** `octop-data`，挂在容器 `/data/.octop`
- 换成宿主机目录时，把 `docker-compose.yml` 里 `- octop-data:/data/.octop` 改成绝对路径：
  `- /srv/octop-data:/data/.octop`（Windows 上写 `D:/octop-data`）
- 不要用 `~/.octop` 这种写法：Windows 的 Compose 不展开 `~`，会生成一个名字就叫 `~` 的目录
- 首次启动会自动执行 `octop init`，凭据写入容器内 `/data/.octop/credential.txt`

备份与恢复（命名卷）：

```bash
docker run --rm -v octop-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/octop-data.tar.gz -C /data .
```

### 健康检查

镜像内置 `HEALTHCHECK`，探测 `GET /api/health`：

```bash
curl http://localhost:8088/api/health
```

### 离线部署（内网 / 无外网环境）

公安内网无法访问 Docker Hub 与 npm/PyPI，镜像必须在有外网的机器上构建后导入。

**在有外网的机器上：**

```bash
git clone https://github.com/Nemo7748/Octop.git
cd Octop
make docker-up            # 或 docker compose -f docker/docker-compose.yml build
docker save octop:latest | gzip > octop-image.tar.gz
sha256sum octop-image.tar.gz > octop-image.tar.gz.sha256
```

**把 `octop-image.tar.gz` 和 `.sha256` 拷到内网机器后：**

```bash
sha256sum -c octop-image.tar.gz.sha256     # 先校验，再导入
docker load < octop-image.tar.gz
docker compose -f docker/docker-compose.yml up -d --no-build
```

注意：`--no-build` 很关键，否则 Compose 会尝试重新构建并因拉不到基础镜像而失败。

### 常用运维命令

```bash
make docker-logs                              # 跟踪日志
make docker-down                              # 停止并删除容器（数据卷保留）
make docker-shell                             # 进容器排查
docker exec -it octop octop --version         # 版本
docker compose -f docker/docker-compose.yml ps
```
