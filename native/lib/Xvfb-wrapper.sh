#!/bin/bash
# =============================================================================
# Xvfb 包装器（原生 / 免 root）
#
# 无 root 解压的 xkb 数据位于非标准路径，Xvfb 默认去 /usr/share/X11/xkb 找。
# 本包装器把 -xkbdir 指到 $PS_ROOT/deps/usr/share/X11/xkb，避免键盘布局报错。
# =============================================================================
PS_ROOT="${PS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
XKB="$PS_ROOT/deps/usr/share/X11/xkb"
REAL="$PS_ROOT/deps/usr/bin/Xvfb"

if [ -x "$REAL" ]; then
  exec "$REAL" ${XKB:+-xkbdir "$XKB"} "$@"
elif [ -x /usr/bin/Xvfb ]; then
  exec /usr/bin/Xvfb "$@"
else
  exec Xvfb "$@"
fi
