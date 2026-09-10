#!/bin/bash
# =============================================================================
# deploy.sh - 小狗星谷服务器 一键非 Docker 部署（原生 / 免 root）
# Puppy Stardew Server - one-click native deploy
#
# 适用环境：
#   - 简幻欢 / 任意 Debian/Ubuntu 容器（无需管理员）
#   - 普通 Linux 主机
# 行为：
#   1. 建立 home/steam 目录结构与符号链接（让原 /home/steam 引用无需改动）
#   2. 下载 SMAPI 安装包（4.3.2）
#   3. 准备 steamcmd（系统已有则复用，否则免 root 下载）
#   4. 准备运行时：node、dotnet、Xvfb/x11vnc/xdotool 等（缺啥补啥，可免 root）
#   5. 安装 Web 面板依赖（npm ci）
#   6. 生成 .env（从 .env.example）
#
# 用法：
#   ./deploy.sh           常规部署
#   ./deploy.sh --update  更新模式（重新拉取依赖与 SMAPI，不覆盖 .env）
#   PS_ROOT=/custom/path ./deploy.sh   指定安装根目录
# =============================================================================
set -uo pipefail

# ---- 路径 ----
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PS_ROOT="${PS_ROOT:-$SELF_DIR}"
PS_HOME="$PS_ROOT/home/steam"
export PS_ROOT PS_HOME

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

# ---- Git 拉取（部署 / 更新直接拉取源码）----
# 默认走代理镜像 https://30006000.xyz/ ，失败时自动回退直连。
# 设 USE_PROXY=0 或 GIT_PROXY=none 可强制直连。
REPO_URL="${REPO_URL:-https://github.com/YHXJLB/stardew-server.git}"
GIT_PROXY="${GIT_PROXY:-https://30006000.xyz/}"
USE_PROXY="${USE_PROXY:-1}"
[ "${GIT_PROXY:-}" = "none" ] && USE_PROXY=0
[ "${USE_PROXY}" = "0" ] && GIT_PROXY=""

fetch_repo() {
  # 已是 git 仓库 -> 拉取最新
  if [ -d "$PS_ROOT/.git" ] && git -C "$PS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    say "检测到 git 仓库，拉取最新 (--ff-only)..."
    if [ -n "$GIT_PROXY" ]; then
      git -c "url.${GIT_PROXY}.insteadOf=https://github.com/" -C "$PS_ROOT" pull --ff-only 2>&1 | tail -3 \
        || warn "git pull 失败（可手动在 $PS_ROOT 执行 git pull）"
    else
      git -C "$PS_ROOT" pull --ff-only 2>&1 | tail -3 \
        || warn "git pull 失败（可手动在 $PS_ROOT 执行 git pull）"
    fi
    return 0
  fi
  # 项目文件已存在（如手动放置）-> 跳过克隆
  if [ -f "$PS_ROOT/app/scripts/entrypoint.sh" ]; then
    say "项目文件已存在，跳过 git 克隆"
    return 0
  fi
  # 否则克隆（代理优先，失败回退直连）
  say "从 $REPO_URL 克隆项目源码..."
  local urls=()
  [ -n "$GIT_PROXY" ] && urls+=( "${GIT_PROXY}${REPO_URL}" )
  urls+=( "$REPO_URL" )
  local tmp; tmp="$(mktemp -d)"
  local ok=0
  for u in "${urls[@]}"; do
    say "尝试: $u"
    if git clone --depth 1 "$u" "$tmp/repo" 2>/dev/null; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then
    err "git 克隆失败（代理与直连均失败）。请手动 clone 到 $PS_ROOT 后重跑，或先安装 git。"
    return 1
  fi
  # 把克隆内容（含 .git）移动到 PS_ROOT，保留已有 .env
  [ -e "$PS_ROOT/.env" ] && cp -a "$PS_ROOT/.env" "$tmp/.env.bak" 2>/dev/null
  [ -d "$tmp/repo/.git" ] && mv "$tmp/repo/.git" "$PS_ROOT/.git"
  for item in "$tmp/repo"/* "$tmp/repo"/.[!.]*; do
    [ -e "$item" ] || continue
    mv "$item" "$PS_ROOT/" 2>/dev/null || cp -r "$item" "$PS_ROOT/" 2>/dev/null
  done
  [ -e "$tmp/.env.bak" ] && mv "$tmp/.env.bak" "$PS_ROOT/.env" 2>/dev/null
  rm -rf "$tmp"
  say "克隆完成"
}
fetch_repo

# git 可用性兜底检查（fetch_repo 内克隆需要）
if ! command -v git >/dev/null 2>&1; then
  err "未找到 git，无法拉取源码。请先安装 git（apt-get install -y git）或手动 clone 仓库到 $PS_ROOT 后重跑。"
  exit 1
fi

# ---- 颜色 ----
G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[0;34m'; N=$'\033[0m'
say()  { echo -e "${G}[deploy]${N} $*"; }
warn() { echo -e "${Y}[deploy]${N} ⚠ $*"; }
err()  { echo -e "${R}[deploy]${N} ✗ $*" >&2; }
step() { echo -e "${B}== $* ==${N}"; }

# 探测下载工具
DL=""
command -v curl >/dev/null 2>&1 && DL=curl
command -v wget >/dev/null 2>&1 || true
dl() { # dl <url> <dest>
  if [ "$DL" = curl ]; then curl -fsSL --retry 3 --connect-timeout 20 "$1" -o "$2" 2>/dev/null
  else wget -q -T 20 -O "$2" "$1" 2>/dev/null; fi
}

# 探测系统 steamcmd / node / dotnet
have_steamcmd() { command -v steamcmd >/dev/null 2>&1; }
have_node()     { command -v node >/dev/null 2>&1 && [ "$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)" -ge 18 ] 2>/dev/null; }
have_dotnet()   { command -v dotnet >/dev/null 2>&1; }
have_xvfb()     { command -v Xvfb >/dev/null 2>&1; }

# 建符号链接（绝对目标，最稳）
link_to() { # link_to <home/steam下链接名> <目标绝对路径>
  ln -sfn "$2" "$PS_HOME/$1"
}

# =============================================================================
step "1/6 建立目录结构与符号链接"
mkdir -p "$PS_ROOT/app" "$PS_ROOT/native/lib" "$PS_ROOT/native/steamcmd" \
         "$PS_ROOT/bin" "$PS_ROOT/.cache" "$PS_ROOT/.run"

# home/steam：真实目录 + 指向 app/native 的符号链接
mkdir -p "$PS_HOME"
link_to scripts        "$PS_ROOT/app/scripts"
link_to web-panel      "$PS_ROOT/app/web-panel"
link_to preinstalled-mods "$PS_ROOT/app/mods"
link_to startup_preferences.template "$PS_ROOT/app/config/startup_preferences"
link_to steamcmd       "$PS_ROOT/native/steamcmd"
link_to smapi          "$PS_ROOT/native/smapi"

# 运行时数据目录（真实目录，持久化）
mkdir -p "$PS_HOME/stardewvalley" \
         "$PS_HOME/.local/share/puppy-stardew/logs" \
         "$PS_HOME/.local/share/puppy-stardew/backups" \
         "$PS_HOME/.config/StardewValley/Saves" \
         "$PS_HOME/.config/StardewValley/ErrorLogs" \
         "$PS_HOME/Steam/config" "$PS_HOME/Steam/logs" \
         "$PS_HOME/custom-mods" \
         "$PS_ROOT/app/web-panel/data"

# web-panel 数据目录符号链接（让 entrypoint 找到 vnc_password.txt / runtime.env）
[ -e "$PS_HOME/web-panel/data" ] || ln -sfn ../../app/web-panel/data "$PS_HOME/web-panel/data" 2>/dev/null || true

# .env 链接（让 web-panel 能读取）
if [ -f "$PS_ROOT/.env" ] && [ ! -e "$PS_HOME/.env" ]; then
  ln -sfn ../.env "$PS_HOME/.env" 2>/dev/null || true
fi

# 脚本可执行
chmod +x "$PS_ROOT/app/scripts/"*.sh 2>/dev/null || true
chmod +x "$PS_ROOT/native/lib/"*.sh 2>/dev/null || true
say "目录结构就绪：$PS_HOME"

# =============================================================================
step "1b 写入服务器主端口 (server.properties)"
# 平台注入 SERVER_PORT；缺省回退 24642。
# 注：星露谷游戏端口硬编码 24642，运行时由 entrypoint 用 socat 把
# SERVER_PORT/UDP 转发到 24642；server.properties 供平台/运维参考。
SERVER_PORT="${SERVER_PORT:-24642}"
if [ ! -f "$PS_ROOT/server.properties" ]; then
  printf '# Stardew Valley server port (SERVER_PORT)\n' > "$PS_ROOT/server.properties"
fi
sed -i "s/^server-port=.*/server-port=$SERVER_PORT/; t; a server-port=$SERVER_PORT" "$PS_ROOT/server.properties"
say "server.properties -> server-port=$SERVER_PORT"

# =============================================================================
step "2/6 下载 SMAPI 安装包 (${SMAPI_VERSION:-4.3.2})"
SMAPI_VERSION="${SMAPI_VERSION:-4.3.2}"
SMAPI_URL="https://github.com/Pathoschild/SMAPI/releases/download/${SMAPI_VERSION}/SMAPI-${SMAPI_VERSION}-installer.zip"
if [ -d "$PS_ROOT/native/smapi" ] && ls "$PS_ROOT/native/smapi"/SMAPI-*/internal/linux/SMAPI.Installer.dll >/dev/null 2>&1; then
  say "SMAPI 已存在，跳过下载"
else
  say "下载 $SMAPI_URL"
  TMP="$(mktemp -d)"
  if dl "$SMAPI_URL" "$TMP/smapi.zip" && [ -s "$TMP/smapi.zip" ]; then
    rm -rf "$PS_ROOT/native/smapi"
    ( cd "$TMP" && unzip -q smapi.zip -d smapi >/dev/null 2>&1 ) || { err "SMAPI 解压失败"; rm -rf "$TMP"; exit 1; }
    mv "$TMP/smapi" "$PS_ROOT/native/smapi"
    say "SMAPI 已下载到 $PS_ROOT/native/smapi"
  else
    err "SMAPI 下载失败（网络问题？）。可手动下载并解压到 $PS_ROOT/native/smapi"
    err "地址：$SMAPI_URL"
  fi
  rm -rf "$TMP"
fi

# =============================================================================
step "3/6 准备 SteamCMD"
if have_steamcmd; then
  say "检测到系统 steamcmd：$(command -v steamcmd)，直接使用"
else
  if [ -x "$PS_ROOT/native/steamcmd/steamcmd.sh" ]; then
    say "本地 steamcmd 已存在，跳过下载"
  else
    say "免 root 下载 SteamCMD..."
    TMP="$(mktemp -d)"
    if dl "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" "$TMP/sc.tar.gz" && [ -s "$TMP/sc.tar.gz" ]; then
      tar -xzf "$TMP/sc.tar.gz" -C "$PS_ROOT/native/steamcmd"
      chmod +x "$PS_ROOT/native/steamcmd/steamcmd.sh"
      say "SteamCMD 已下载到 $PS_ROOT/native/steamcmd"
    else
      err "SteamCMD 下载失败。请手动下载解压到 $PS_ROOT/native/steamcmd"
    fi
    rm -rf "$TMP"
  fi
fi

# =============================================================================
step "4/6 准备运行时：node / dotnet / 显示依赖"
# node
if have_node; then
  say "node 已就绪：$(node -v)"
else
  say "未检测到 node(≥18)，启动免 root 安装..."
  PS_ROOT="$PS_ROOT" bash "$PS_ROOT/native/lib/install-node.sh" || warn "node 安装失败，请手动安装 Node.js ≥ 18"
fi
# dotnet
if have_dotnet; then
  say "dotnet 已就绪：$("$(command -v dotnet)" --version 2>/dev/null)"
else
  say "未检测到 dotnet，启动免 root 安装（channel 6.0）..."
  PS_ROOT="$PS_ROOT" CHANNEL=6.0 bash "$PS_ROOT/native/lib/install-dotnet.sh" || warn "dotnet 安装失败，SMAPI 安装步骤将无法执行"
fi

# 显示依赖（Xvfb/x11vnc/xdotool + 32 位库）
# 始终运行：install-deps.sh 内部幂等（已装的会跳过），
# 同时保证 steamcmd 的 32 位库与本地 wrapper 在无系统 steamcmd 时也能补齐。
if have_xvfb; then
  say "Xvfb 已就绪（系统提供），仍运行依赖安装器以补齐 32 位库/steamcmd wrapper..."
else
  say "未检测到 Xvfb，运行依赖安装器（支持免 root）..."
fi
PS_ROOT="$PS_ROOT" bash "$PS_ROOT/native/lib/install-deps.sh" || warn "部分显示依赖未就绪"

# =============================================================================
step "5/6 安装 Web 面板依赖"
if [ -f "$PS_ROOT/app/web-panel/package.json" ]; then
  cd "$PS_ROOT/app/web-panel"
  if [ -d node_modules ] && [ -f package-lock.json ]; then
    say "面板依赖已存在，跳过 npm ci（--update 时强制重装）"
    [ "$UPDATE" = 1 ] && { npm ci --omit=dev >/dev/null 2>&1 && say "面板依赖已重装" || warn "面板依赖重装失败"; }
  else
    say "运行 npm ci --omit=dev ..."
    npm ci --omit=dev >/dev/null 2>&1 && say "面板依赖安装完成" || warn "npm ci 失败，请检查 node/npm 与网络"
  fi
  cd "$PS_ROOT"
fi

# =============================================================================
step "6/6 生成配置文件 .env"
if [ -f "$PS_ROOT/.env" ]; then
  say ".env 已存在，保留原有配置（可手动编辑 $PS_ROOT/.env）"
else
  cp "$PS_ROOT/.env.example" "$PS_ROOT/.env"
  # 重新建 .env 链接
  ln -sfn ../.env "$PS_HOME/.env" 2>/dev/null || true
  say "已从 .env.example 生成 $PS_ROOT/.env"
  warn "请编辑 $PS_ROOT/.env，至少设置 STEAM_USERNAME / STEAM_PASSWORD"
fi

# 链接 .env 到 home/steam（确保 web-panel 读取）
ln -sfn ../.env "$PS_HOME/.env" 2>/dev/null || true

# =============================================================================
step "部署完成 ✅"
echo
echo -e "${G}部署目录：${N}$PS_ROOT"
echo -e "${G}游戏数据：${N}$PS_HOME/stardewvalley （首次启动会从 Steam 下载，约 700MB）"
echo
echo -e "${B}启动方式："
echo -e "  ${N}容器环境（简幻欢自定义镜像）：把 start.sh 作为启动脚本运行"
echo -e "  ${N}   -> 直接执行：  bash $PS_ROOT/start.sh"
echo -e "  ${N}普通主机后台运行：  ./pss start   （./pss status / logs / stop）"
echo
echo -e "${B}首次启动前请确认："
echo -e "  1. 编辑 .env 填入 STEAM_USERNAME / STEAM_PASSWORD"
echo -e "  2. 若账号开启 Steam Guard，首次运行设置 STEAM_GUARD_CODE=<验证码>"
echo -e "     （或在启动后用 ./pss guard <验证码> 输入）"
echo -e "  3. 端口：容器唯一主端口 SERVER_PORT 同时承载「面板 TCP + 游戏 UDP(转发24642)」；VNC 已关闭；指标 9090 仅内网(127.0.0.1)"
echo
if ! have_dotnet && [ ! -x "$PS_ROOT/dotnet/dotnet" ]; then
  warn "dotnet 未就绪，SMAPI 安装会失败。请安装 .NET 6 运行时或重跑本脚本。"
fi
