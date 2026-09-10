#!/bin/bash
# =============================================================================
# start.sh - 容器启动入口（简幻欢自定义镜像 / 任意 Debian 容器）
# Puppy Stardew Server - container entrypoint (PID 1)
#
# 设计：前台运行 entrypoint.sh（其末尾 exec ./StardewModdingAPI --server），
#       因此只要游戏在跑，容器就一直存活。无需 systemd / 无需 root。
#
# 前提：先运行 ./deploy.sh 完成部署。
# 首次启动：务必在 .env 中填好 STEAM_USERNAME / STEAM_PASSWORD，
#           若开启 Steam Guard，同时设置 STEAM_GUARD_CODE=<验证码>。
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export PS_ROOT="${PS_ROOT:-$SELF_DIR}"
export PS_HOME="${PS_HOME:-$PS_ROOT/home/steam}"

# 服务器主端口（简幻欢平台注入 SERVER_PORT；缺省回退 24642）
export SERVER_PORT="${SERVER_PORT:-24642}"
export GAME_PORT="${GAME_PORT:-24642}"
export PANEL_PORT="${PANEL_PORT:-$SERVER_PORT}"
export METRICS_BIND="${METRICS_BIND:-127.0.0.1}"

# 注入运行时环境（PATH / LD_LIBRARY_PATH / dotnet / node / wrappers）
# shellcheck disable=SC1091
[ -f "$PS_ROOT/native/env.sh" ] && . "$PS_ROOT/native/env.sh"

# 加载 .env 并导出（entrypoint 与 SMAPI 安装步骤都依赖这些变量）
if [ -f "$PS_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PS_ROOT/.env"
  set +a
  export ENV_FILE="$PS_ROOT/.env"
fi

# 确保日志目录
mkdir -p "$PS_HOME/.local/share/puppy-stardew/logs"

echo "========================================================"
echo " 小狗星谷服务器 启动中 (原生 / 非 Docker)"
echo " PS_ROOT = $PS_ROOT"
echo " STEAM   = ${STEAM_USERNAME:-<未设置! 请编辑 .env>}"
echo "========================================================"

if [ -z "${STEAM_USERNAME:-}" ] || [ -z "${STEAM_PASSWORD:-}" ]; then
  echo "错误：STEAM_USERNAME / STEAM_PASSWORD 未设置，请先编辑 $PS_ROOT/.env" >&2
  exit 1
fi

# 前台运行入口脚本（容器保活靠它）
exec bash "$PS_ROOT/app/scripts/entrypoint.sh"
