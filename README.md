# Docker 内定时更新 Git 代码

`AUTO_UPDATE=true` 开启 `entrypoint.sh` 内的 Bash 更新管理器，默认每 60 秒检查指定分支。
不需要给容器挂载 Docker socket，也不需要后端实现更新接口。
默认 `AUTO_UPDATE=false`，保留原来的启动方式。

## 快速使用

1. 将 `.env.example` 复制为 `.env`，填写仓库账号、仓库名称和只读 Token。
   使用 Gitee 时填写 `GITEE_USERNAME` 和 `GITEE_TOKEN`，仓库名仍填写 `GITHUB_REPO`。
2. 配置 `RUN_COMMAND`、应用需要的数据库环境变量，以及实际存在的
   `HEALTHCHECK_URL`，例如 `http://127.0.0.1:4567/health`。
3. 构建并启动（首次使用需要重新构建镜像，旧镜像没有管理器）：

```bash
docker compose -f compose.auto-update.yml up -d --build
docker compose -f compose.auto-update.yml logs -f my_admin_server
```

示例只启动后端，不包含数据库；请连接现有数据库或把服务配置合并到原来的
Compose 文件中。容器内端口假设为 4567，按实际服务修改。

现有 Compose 配置至少增加：

```yaml
init: true
restart: unless-stopped
stop_grace_period: 45s
environment:
  AUTO_UPDATE: "true"
  UPDATE_INTERVAL: "60"
  ENTRYPOINT_URL: ""
  HEALTHCHECK_URL: "http://127.0.0.1:4567/health" # 替换为实际健康接口
volumes:
  - ./runtime/config:/config
  - ./runtime/app:/app
```

保留原有仓库、数据库和启动命令配置，但请用 `.env` 或 secrets 管理凭据。
同时将 `image` 指向新构建的镜像，或增加 `build: .`；仅增加环境变量不会更新旧镜像中的启动脚本。
如果已有 `/config` 挂载，沿用它即可，不要重复挂载同一目标目录。
`stop_grace_period` 应大于 `STOP_TIMEOUT` 的两倍，留出终止更新命令和后端的时间。

## 更新流程

1. 在 `/config/auto-update` 保存独立 Git 缓存、版本代码和各版本的 Python 虚拟环境。
2. 检测远程提交 SHA；没有变化就不重启。Git 失败或超时不影响正在运行的服务。
3. 有变化时在新目录检出代码，安装仓库中的 `requirements.txt`。
   此时旧服务继续运行。每个版本使用独立虚拟环境，因此安装失败不会破坏旧版依赖。
4. 准备成功后终止旧进程及其子进程，将版本代码同步到 `/app`，从 `/app` 启动新版本。单实例切换有短暂停机。
5. 新版本通过观察期及 HTTP 健康检查后，才记录为当前版本；失败则将旧版代码恢复到 `/app`，使用旧版虚拟环境重启。
6. 保留最近版本供恢复，默认保留至少 3 个，并始终保留当前及上一个版本。

重启容器时优先启动持久化的已验证版本，再检查远程更新，因此远程暂时不可用
也能启动。首次部署没有缓存时必须能访问 Git 并成功安装依赖。

准备、启动或健康检查失败的同一个提交，在本次管理器运行期间不再尝试，避免
反复中断业务。推送修复提交即可再次更新；如需重试原提交，可重启容器。
后端在发布观察期之后意外退出时，管理器以失败状态退出，由 Docker 重启容器。

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AUTO_UPDATE` | `false` | 只接受 `true` / `false` |
| `UPDATE_INTERVAL` | `60` | 每次检查完成后等待秒数 |
| `BRANCH` | `main` | 跟踪的远程分支 |
| `RUN_COMMAND` | `python3 main.py` | 可信的 Bash 前台启动命令，支持引号；不要用 `&` 后台化 |
| `UPDATE_STATE_DIR` | `/config/auto-update` | 必须持久化；不同仓库、分支自动隔离并加锁 |
| `HEALTHCHECK_URL` | 空 | 建议使用容器内 `127.0.0.1` HTTP 健康接口；检查请求不经过代理 |
| `STARTUP_GRACE_SECONDS` | `10` | 新进程至少存活多久才接受健康结果 |
| `HEALTHCHECK_TIMEOUT` | `60` | 启动及健康检查总时限，不能小于观察期 |
| `GIT_TIMEOUT` | `60` | 单个 Git 网络命令超时秒数 |
| `BUILD_TIMEOUT` | `900` | 单个代码准备或依赖安装命令超时秒数 |
| `STOP_TIMEOUT` | `20` | 终止进程组的宽限期，超时强制终止 |
| `UPDATE_KEEP_RELEASES` | `3` | 保留的已准备版本数，最小为 2 |

所有时间及数量参数均为整数。

应用会收到 `APP_COMMIT` 环境变量，可用于版本展示或日志。
依赖安装继承代理及 `PIP_INDEX_URL` 等标准 pip 环境变量。

## 注意事项

- 自动更新后的应用始终从 `/app` 运行，代码文件也位于 `/app`；版本缓存和独立虚拟环境仍在 `/config/auto-update`。
- 本地应用配置放在 `/app/.env`，例如使用示例挂载时放在宿主机 `./runtime/app/.env`。
  它与 Compose 使用的项目 `.env` 是两份不同用途的文件；现有容器环境变量仍优先于应用 `.env`。
  更新器保留 `.env`、`.env.*`，即便 Git 中存在同名文件也不覆盖。
- 更新器只替换 Git 管理的代码，并删除旧版中已移除的受管文件；未纳入 Git 的上传、日志等文件保留。
  不要把运行数据写进受管代码文件。`.auto-update-files.json` 和 `.auto-update.lock` 是 `/app` 内的管理器保留文件。
  目标路径的父目录若是软链接，或代码替换会覆盖非空本地目录，更新会失败并尝试恢复旧版，不递归清空用户数据。
- 挂载 `/app` 可以让 `.env` 和运行数据在重建容器后继续保留；如果已有挂载，沿用原挂载，不要重复添加。
- 非空 `/data` 的原有文件同步模式与自动 Git 更新互斥，启动时会报错提示。
- 不指定健康接口只能发现进程退出，无法判断数据库连接、接口等是否真正可用。
- 回滚只覆盖代码和 Python 依赖，不会撤销数据库迁移或外部写操作。数据库变更应保持
  向后兼容；破坏性迁移请单独安排。
- 当前支持普通 Git + `requirements.txt` Python 项目；不会自动安装新系统包，
  不处理 Git submodule、LFS、Poetry/uv 锁文件或编译其他语言。此类变更需扩展构建流程或重建镜像。
- 自动更新模式始终使用镜像内的启动脚本，忽略旧配置中的 `ENTRYPOINT_URL`，避免
  在线旧脚本覆盖管理器逻辑。更新管理器本身仍需重建镜像。
- 推送到被跟踪分支的提交会自动执行，限制分支写权限，并使用最小权限的只读 Git 凭据。
  仓库中曾提交过的 Token、密码应轮换，仅移到 `.env` 不会清除历史泄露。

## 测试

```bash
bash tests/test_auto_update.sh
```

测试使用临时本地 Git 仓库和模拟的依赖安装，不访问远程仓库或 PyPI。
Linux 上还会测试真实后台进程、锁与停止信号；Git Bash 缺少 `setsid` / `flock`
时跳过这部分。更新调度及回滚逻辑不依赖任何额外 Python 文件；代码同步使用启动脚本内嵌的 Python 标准库。
