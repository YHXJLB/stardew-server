#!/bin/bash
# =============================================================================
# env.sh - 原生（非 Docker）运行时环境
# Puppy Stardew Server (rootless / native)
#
# 由 app/scripts/ps-env.sh 或 native/run-service.sh / pss 调用，
# 把无 root 安装到 $PS_ROOT 的依赖（.deb 解压树、独立 node、dotnet、包装脚本）
# 注入到 PATH / LD_LIBRARY_PATH / DOTNET_ROOT。
# =============================================================================

: "${PS_ROOT:=${HOME}/puppy-stardew}"
: "${PS_HOME:=$PS_ROOT/home/steam}"
export PS_ROOT PS_HOME

# 项目脚本目录
export PATH="$PS_ROOT/app/scripts:$PATH"

# 独立安装的 Node.js（若 deploy.sh 下载了）
if [ -x "$PS_ROOT/node/bin/node" ]; then
  export PATH="$PS_ROOT/node/bin:$PATH"
fi

# .NET 运行时（SMAPI 需要）
if [ -x "$PS_ROOT/dotnet/dotnet" ]; then
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
