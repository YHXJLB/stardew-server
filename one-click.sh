#!/bin/bash
# =============================================================================
# one-click.sh - 小狗星谷服务器 一键部署并启动（原生 / 免 root）
# Puppy Stardew Server - one-click native deploy & start
#
# 设计目标：一个脚本搞定全部。
#   - 从零开始（目录为空）：自动克隆源码到当前目录，再部署并启动。
#   - 已解包 / 已部署：直接复用本地文件，幂等部署后启动。
#   - 适合反复运行：首次完整部署并在 PS_ROOT/.deployed 打标记；
#     之后启动只跑 start.sh（用 --update 强制重新部署）。
#
# 用法：
#   bash one-click.sh            # 部署（仅首次）+ 启动，前台运行（容器保活靠它）
#   bash one-click.sh --update   # 重新拉取依赖/SMAPI 并部署（不覆盖 .env），再启动
#   bash one-click.sh --force    # 等同 --update，强制重部署
#   PS_ROOT=/x/y bash one-click.sh   # 指定部署根目录
#   REPO_BRANCH=main bash one-click.sh # 改用其它分支（默认 nodocker）
#
# 空目录也能一行启动（脚本来自管道时自动以当前目录为部署根）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/YHXJLB/stardew-server/nodocker/one-click.sh)
#
# 平台接入（简幻欢自定义镜像）：把启动命令设为
#   bash /home/container/one-click.sh
# 即可：首次开机自动部署，之后每次开机直接启动。
# =============================================================================
set -uo pipefail

# ---- 颜色 ----
G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[0;34m'; N=$'\033[0m'
log()  { echo -e "${G}[一键]${N} $*"; }
warn() { echo -e "${Y}[一键]${N} ⚠ $*"; }

# ---- 路径：脚本所在目录即部署根目录 ----
# 兼容两种运行方式：
#   1) bash ./one-click.sh            -> BASH_SOURCE 是普通文件路径，取其所在目录
#   2) bash <(curl ... one-click.sh)  -> BASH_SOURCE 是 /dev/fd/xx 管道，无法 cd，
#      此时改以当前工作目录($PWD) 作为部署根目录（需是可写目录，如 /home/container）
_SRC="${BASH_SOURCE[0]:-$0}"
case "$_SRC" in
  /dev/*|/proc/*|/dev/fd/*)
    SELF_DIR="$PWD"
    ;;
  *)
    SELF_DIR="$(cd "$(dirname "$_SRC")" 2>/dev/null && pwd)" || SELF_DIR="$PWD"
    ;;
esac
PS_ROOT="${PS_ROOT:-$SELF_DIR}"
export PS_ROOT
mkdir -p "$PS_ROOT"

# ---- 参数 ----
FORCE=0
for a in "$@"; do
  case "$a" in
    --update|--force|-f) FORCE=1 ;;
  esac
done

# =============================================================================
# 第 0 步：若当前目录还不是项目（没有 app/scripts/entrypoint.sh），自动克隆
# =============================================================================
if [ -f "$PS_ROOT/app/scripts/entrypoint.sh" ]; then
  log "检测到项目文件已存在，跳过克隆"
elif [ -f "$PS_ROOT/deploy.sh" ] && [ -f "$PS_ROOT/start.sh" ]; then
  log "检测到已解包的部署文件，跳过克隆"
else
  log "未检测到项目源码，开始自动克隆（默认分支 nodocker）..."
  REPO_URL="${REPO_URL:-https://github.com/YHXJLB/stardew-server.git}"
  REPO_BRANCH="${REPO_BRANCH:-nodocker}"
  GIT_PROXY="${GIT_PROXY:-https://30006000.xyz/}"
  USE_PROXY="${USE_PROXY:-1}"
  [ "${GIT_PROXY:-}" = "none" ] && USE_PROXY=0
  [ "$USE_PROXY" = "0" ] && GIT_PROXY=""

  if ! command -v git >/dev/null 2>&1; then
    warn "未找到 git，无法自动克隆。请先安装 git，或手动 clone 到 $PS_ROOT 后重跑。"
    exit 1
  fi

  urls=()
  [ -n "$GIT_PROXY" ] && urls+=("${GIT_PROXY}${REPO_URL}")
  urls+=("$REPO_URL")
  tmp="$(mktemp -d)"
  ok=0
  for u in "${urls[@]}"; do
    log "尝试克隆: $u  (分支 $REPO_BRANCH)"
    if git clone --depth 1 -b "$REPO_BRANCH" "$u" "$tmp/repo" 2>/dev/null; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then
    warn "自动克隆失败（代理与直连均失败）。请检查 git / 网络，或手动 clone 到 $PS_ROOT 后重跑。"
    rm -rf "$tmp"
    exit 1
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
  log "源码已克隆到 $PS_ROOT"
fi

# =============================================================================
# 第 1 步：部署（幂等；非首次且非 --force 时跳过，加快开机）
# =============================================================================
DEPLOY=1
if [ -f "$PS_ROOT/.deployed" ] && [ "$FORCE" != "1" ]; then
  DEPLOY=0
  log "已部署过（存在 .deployed），跳过部署，直接启动（用 --update 强制重部署）"
fi

if [ "$DEPLOY" = "1" ] && [ -f "$PS_ROOT/deploy.sh" ]; then
  if PS_ROOT="$PS_ROOT" bash "$PS_ROOT/deploy.sh" "$@"; then
    : # deploy 成功
  else
    warn "部署步骤返回非零，请查看上方日志；仍尝试启动..."
  fi
  # 无论 deploy 告警与否，只要脚本没硬退出就打标记，避免每次开机重复拉取
  touch "$PS_ROOT/.deployed"
elif [ "$DEPLOY" = "1" ]; then
  warn "未找到 deploy.sh，跳过部署步骤"
fi

# =============================================================================
# 第 2 步：启动（前台运行，作为容器主进程；游戏在跑=容器存活）
# =============================================================================
if [ -f "$PS_ROOT/start.sh" ]; then
  exec env PS_ROOT="$PS_ROOT" bash "$PS_ROOT/start.sh"
else
  warn "未找到 start.sh，无法启动。请检查部署结果。"
  exit 1
fi
