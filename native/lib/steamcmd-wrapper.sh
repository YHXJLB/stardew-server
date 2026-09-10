#!/bin/bash
# =============================================================================
# steamcmd 包装器（原生 / 免 root 32 位兼容）
# Puppy Stardew Server (rootless / native)
#
# 解析顺序：
#   1) 若系统已存在 steamcmd 命令（如简幻欢镜像预装）直接用，尊重其自带 32 位支持；
#   2) 否则用本仓库解压到 $PS_HOME/steamcmd 的 SteamCMD，借助 $PS_ROOT/deps32
#      里的 32 位加载器（ld-linux.so.2）直接运行 linux32/steamcmd，无需系统 i386 架构。
# =============================================================================
PS_ROOT="${PS_ROOT:-$HOME/puppy-stardew}"
PS_HOME="${PS_HOME:-$PS_ROOT/home/steam}"
SC_DIR="$PS_HOME/steamcmd"

# 1) 系统预装的 steamcmd（排除我们自己的包装器，避免自调用）
_sys=""
if command -v steamcmd >/dev/null 2>&1; then
  _c="$(command -v steamcmd)"
  case "$_c" in
    "$PS_ROOT/bin/steamcmd"|"$PS_ROOT"/*) _sys="" ;;
    *) _sys="$_c" ;;
  esac
fi
if [ -n "$_sys" ]; then
  exec "$_sys" "$@"
fi

# 2) 本地解压的 SteamCMD
if [ ! -x "$SC_DIR/steamcmd.sh" ]; then
  echo "[steamcmd] 未找到 SteamCMD：请先运行 ./deploy.sh 下载，或确认系统已安装 steamcmd。" >&2
  exit 1
fi

# 定位 32 位动态加载器
LOADER=""
for cand in \
  "$PS_ROOT/deps32/usr/lib/i386-linux-gnu/ld-linux.so.2" \
  "$PS_ROOT/deps32/lib/i386-linux-gnu/ld-linux.so.2" \
  "$PS_ROOT/deps32/lib/ld-linux.so.2" \
  /lib/ld-linux.so.2 /lib/i386-linux-gnu/ld-linux.so.2 ; do
  [ -x "$cand" ] && { LOADER="$cand"; break; }
done

LD32="$PS_ROOT/deps32/usr/lib/i386-linux-gnu:$PS_ROOT/deps32/lib/i386-linux-gnu:$PS_ROOT/deps32/usr/lib:$PS_ROOT/deps32/lib"

if [ -n "$LOADER" ] && [ -x "$SC_DIR/linux32/steamcmd" ]; then
  export LD_LIBRARY_PATH="$LD32:${LD_LIBRARY_PATH:-}"
  exec "$LOADER" --library-path "$LD32:$SC_DIR/linux32" \
       "$SC_DIR/linux32/steamcmd" "$@"
else
  # 系统已具备 32 位支持（或 steamcmd.sh 自带处理）
  exec "$SC_DIR/steamcmd.sh" "$@"
fi
