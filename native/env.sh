#!/bin/bash
# =============================================================================
# env.sh - 原生（非 Docker）运行时环境
# Puppy Stardew Server (rootless / native)
#
# 由 app/scripts/ps-env.sh 或 native/run-service.sh / pss 调用，
# 把无 root 安装到 $PS_ROOT 的依赖（.deb 解压树、独立 node、dotnet、包装脚本）
# 注入到 PATH / LD_LIBRARY_PATH / DOTNET_ROOT。
# =============================================================================

: "${PS_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
: "${PS_HOME:=$PS_ROOT/home/steam}"
export PS_ROOT PS_HOME

# 平台注入的环境变量（简幻欢 AIO，见 customer-aio-path-list）
# SERVER_PORT 由 entrypoint 读取；TZ / SERVER_MEMORY 在此兜底，确保
# 游戏 / 面板 / steam 进程使用正确时区（默认 Asia/Shanghai）。
export TZ="${TZ:-Asia/Shanghai}"
[ -n "${SERVER_MEMORY:-}" ] && export SERVER_MEMORY

# 探测版本管理器（Mise/nvm 等）预装的 node/dotnet 并加入 PATH，
# 否则非交互 bash 找不到镜像里 Mise 装的 Node 22 / .NET。
# shellcheck disable=SC1091
. "$PS_ROOT/native/lib/probe-runtime.sh"

# 项目脚本目录
export PATH="$PS_ROOT/app/scripts:$PATH"

# 系统 Node.js 优先（简幻欢镜像已预装 Node 22 LTS）。
# 仅当系统未提供 node 时，才把本地独立安装的 node 作为 fallback 加入 PATH。
if command -v node >/dev/null 2>&1; then
  : # 使用系统 node
elif [ -x "$PS_ROOT/node/bin/node" ]; then
  export PATH="$PS_ROOT/node/bin:$PATH"
fi

# 系统 .NET 优先（简幻欢镜像已预装 .NET 6/8/9）。
# 仅当系统未提供 dotnet 时，才启用本地独立安装的 dotnet。
if command -v dotnet >/dev/null 2>&1; then
  : # 使用系统 dotnet
elif [ -x "$PS_ROOT/dotnet/dotnet" ]; then
  export DOTNET_ROOT="$PS_ROOT/dotnet"
  export PATH="$PS_ROOT/dotnet:$PATH"
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
  export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
  export DOTNET_NOLOGO=1
fi

# 无 root 时解压的 .deb 根文件系统（amd64）
if [ -d "$PS_ROOT/deps" ]; then
  _d="$PS_ROOT/deps"
  export PATH="$_d/usr/bin:$_d/bin:$PATH"
  export LD_LIBRARY_PATH="$_d/usr/lib/x86_64-linux-gnu:$_d/usr/lib:$_d/lib/x86_64-linux-gnu:$_d/lib:${LD_LIBRARY_PATH}"
  # Mesa 软件渲染驱动目录
  if [ -d "$_d/usr/lib/x86_64-linux-gnu/dri" ]; then
    export LIBGL_DRIVERS_PATH="$_d/usr/lib/x86_64-linux-gnu/dri:${LIBGL_DRIVERS_PATH}"
  fi
  export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
fi

# 自定义包装脚本（steamcmd / Xvfb）
if [ -d "$PS_ROOT/bin" ]; then
  export PATH="$PS_ROOT/bin:$PATH"
fi

# SDL / 显示默认
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"
