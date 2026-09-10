#!/bin/bash
# =============================================================================
# install-dotnet.sh - 免 root 安装 .NET 运行时到 $PS_ROOT/dotnet
# SMAPI 需要 dotnet 6.0 运行时；可选安装 8.0（供 DepotDownloader 使用）。
# 用法：PS_ROOT=/path CHANNEL=6.0 . ./install-dotnet.sh
# =============================================================================
set -euo pipefail

PS_ROOT="${PS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
DOTNET_DIR="$PS_ROOT/dotnet"
CHANNEL="${CHANNEL:-6.0}"

if [ -x "$DOTNET_DIR/dotnet" ]; then
  echo "[dotnet] 已存在：$("$DOTNET_DIR/dotnet" --version 2>/dev/null || echo present)"
  # 若要求 8.0 且已有 8，跳过
  exit 0
fi

INSTALLER_URL="https://dot.net/v1/dotnet-install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[dotnet] 下载 dotnet-install.sh"
curl -fsSL "$INSTALLER_URL" -o "$TMP/dotnet-install.sh"
chmod +x "$TMP/dotnet-install.sh"

mkdir -p "$DOTNET_DIR"
echo "[dotnet] 安装 channel=$CHANNEL 运行时到 $DOTNET_DIR"
"$TMP/dotnet-install.sh" --install-dir "$DOTNET_DIR" --channel "$CHANNEL" --runtime dotnet

echo "[dotnet] 安装完成：$("$DOTNET_DIR/dotnet" --version)"
