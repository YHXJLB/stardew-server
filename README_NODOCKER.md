# 小狗星谷服务器 · 非 Docker 部署（原生 / 免 root）

本目录是 [AmigaMeow/puppy-stardew-server](https://github.com/AmigaMeow/puppy-stardew-server) 的 **非容器化改造版**，去掉了 Docker / docker-compose 依赖，可直接在 **Debian / Ubuntu 容器（无需管理员权限）或普通 Linux 主机** 上运行。

> 核心差异：原版所有路径硬编码 `/home/steam`，且依赖 Docker 镜像装好的环境与 `docker attach` 交互。
> 本版把路径统一参数化为 `PS_HOME`，新增 `native/`（免 root 依赖安装、`steamcmd` 32 位包装器），并配套 `deploy.sh`（一键部署）、`start.sh`（容器入口）、`pss`（服务控制）三个脚本。

---

## 一、环境要求

- 系统：Debian 12 / Ubuntu 22.04+（容器或主机均可）
- 网络：能访问 Steam / GitHub（下载游戏 ≈700MB、SMAPI、依赖）
- 权限：**不需要 root**。若当前用户是 root 或拥有免密 sudo，部署会更快（直接 `apt` 安装）；非 root 时自动改用「下载 .deb 解包到本地」的免 root 方案
- 已验证可运行的预置环境：简幻欢自定义镜像（Debian 12 AIO，自带 .NET 6/8/9、Node、SteamCMD、Wine/Mono）

---

## 二、一键部署

```bash
cd puppy-stardew-server-nodocker
./deploy.sh            # 常规部署（自动从 git 拉取最新源码）
./deploy.sh --update   # 更新模式（重新 git pull + 重拉依赖/SMAPI，保留 .env）
```

> **网络代理**：默认通过镜像 `https://30006000.xyz/` 拉取 git（直连 GitHub 易失败）。
> 如需直连：`USE_PROXY=0 ./deploy.sh`，或 `GIT_PROXY=none ./deploy.sh`。

`deploy.sh` 会依次完成：

1. 从 git 拉取源码（已是仓库则 `git pull --ff-only`；否则克隆到本目录）
2. 建立 `home/steam` 目录结构与符号链接（让原 `/home/steam/...` 引用无需改动）
3. 下载 SMAPI 安装包（默认 4.3.2）
4. 准备 `steamcmd`（系统已有则复用，否则免 root 下载）
5. 准备运行时：Node（≥18）、.NET 6 运行时、Xvfb / xdotool / socat 等（缺啥补啥，支持免 root）
6. 安装 Web 面板依赖（`npm ci --omit=dev`）
7. 从 `.env.example` 生成 `.env`，并把 `SERVER_PORT` 写入 `server.properties`

> 部署全程不修改系统目录（`/usr` 等），所有内容都在本目录内（脚本所在文件夹）。

---

## 三、配置 .env（务必先做）

编辑 `.env`，至少填写：

```ini
STEAM_USERNAME=你的Steam用户名
STEAM_PASSWORD=你的Steam密码
# 开启两步验证且首次登录时填；不填则首次启动会在日志提示，用 ./pss guard 输入
STEAM_GUARD_CODE=
```

常用可选项（见 `.env.example`）：`SERVER_PORT`（主端口，平台注入）、`ENABLE_VNC`（默认关闭）、`VNC_PASSWORD`、`SERVER_NAME`、`METRICS_PORT` / `METRICS_BIND`（指标，默认仅内网）。

---

## 四、启动

### 容器环境（简幻欢自定义镜像等）
把实例的启动脚本设为：
```bash
bash /你的路径/puppy-stardew-server-nodocker/start.sh
```
`start.sh` 会**前台**运行入口脚本（游戏进程即主进程），因此容器会一直存活，无需 systemd。

### 普通主机（后台运行）
```bash
./pss start      # 启动（优先 tmux；无 tmux 时回退 FIFO）
./pss status     # 查看状态
./pss logs       # 实时日志
./pss stop       # 停止
./pss restart    # 重启
```

---

## 五、Steam Guard 验证码怎么输入

首次用开启了两步验证的账号登录，SteamCMD 会要验证码：

- **推荐**：在 `.env` 设 `STEAM_GUARD_CODE=xxxxxx`，重启即可
- 后台运行时：`/pss guard <验证码>`
- 有 tmux 时：`/pss attach` 进入交互终端直接输入
- Web 面板里的「终端」也可直接输入（已适配原生 tmux 模式）

---

## 六、端口

简幻欢容器**只暴露一个对外端口 `SERVER_PORT`**（由平台注入，数值随实例规格）。本部署让这个唯一端口同时承载「面板 + 游戏」：

| 用途 | 端口 | 协议 | 对外 |
|------|------|------|------|
| 服务器主端口 SERVER_PORT | `SERVER_PORT`（默认 24642） | 同时承载下方两项 | ✅ 对外 |
| ├─ Web 管理面板 | = SERVER_PORT | TCP | ✅ |
| └─ 游戏（星露谷，硬编码 24642） | SERVER_PORT 经 socat 转发到 24642 | UDP | ✅ |
| 指标（Prometheus） | 9090 | TCP | ❌ 仅 127.0.0.1（内网） |
| VNC | 5900 | TCP | ❌ 已关闭（默认 `ENABLE_VNC=false`） |

- 游戏端口 24642 是星露谷硬编码值，不在 `server.properties` 里；运行时由 `entrypoint.sh` 用 `socat` 把 `SERVER_PORT/UDP` 转发到 24642（纯用户态、无需 root），因此**玩家连 `SERVER_PORT` 即可进游戏**。
- 面板与游戏共用 `SERVER_PORT` 之所以可行，是因为 TCP（面板）和 UDP（游戏）端口空间相互独立。
- 9090 指标端口只绑定 `127.0.0.1`，面板从内网读取，外部无法访问。
- 想改主端口：在容器/环境变量设 `SERVER_PORT`（平台自动注入即可），无需改其它配置。

---

## 七、目录结构

```
puppy-stardew-server-nodocker/
├── deploy.sh            # 一键部署
├── start.sh             # 容器入口（前台保活）
├── pss                  # 服务控制（start/stop/guard/attach...）
├── .env.example         # 配置样例
├── .env                 # 你的配置（deploy 生成）
├── app/                 # 原 docker/ 内容（已路径参数化）
│   ├── scripts/         # entrypoint.sh 及子脚本
│   ├── web-panel/       # Node 面板
│   ├── mods/            # 预装 mods
│   └── config/          # startup_preferences 等
├── native/              # 原生部署辅助
│   ├── env.sh           # 注入 PATH/LD_LIBRARY_PATH/dotnet
│   └── lib/             # install-deps / install-node / install-dotnet / steamcmd-wrapper / Xvfb-wrapper
├── home/steam/          # = PS_HOME：符号链接 + 运行时数据（游戏/存档在此）
├── bin/                 # 本地命令包装器（Xvfb/steamcmd...）
├── deps/  deps32/       # 免 root 解压的依赖（amd64 / i386）
└── node/  dotnet/       # 免 root 安装的运行时（按需）
```

---

## 八、故障排查

- **`dotnet` 未就绪**：SMAPI 安装会失败。确保系统有 .NET 6 运行时，或重跑 `./deploy.sh`（自动免 root 下载）。
- **`steamcmd` 报 32 位库缺失**：非 root 场景下 `deps32/` 未生成，重跑 `./deploy.sh` 让它下载 i386 库。
- **`Xvfb` 缺失**：重跑 `./deploy.sh`（root 走 apt，非 root 走 .deb 解包）。
- **游戏下载卡住/很慢**：首次需从 Steam 拉取 ≈700MB，耐心等待；下载完会持久化在 `home/steam/stardewvalley`，重启不再下载。
- **端口被占用**：在 `.env` 修改对应端口后 `./pss restart`。

---

## 九、简幻欢自定义镜像特别说明

参考你提供的容器环境文档：自定义镜像基于 Debian 12，启动方式为「根目录下 `start.sh` 作为主进程」。
本版的 `start.sh` 正是为此设计——**前台运行游戏进程使得容器保持存活**，且镜像已预置的 .NET / Node / SteamCMD 会被自动复用，几乎零额外安装。
把你仓库里的 `start.sh` 设为实例启动脚本即可。
