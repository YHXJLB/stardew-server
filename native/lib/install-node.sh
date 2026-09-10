#!/bin/bash
# =============================================================================
# install-node.sh - 免 root 安装 Node.js 到 $PS_ROOT/node
# 适用于 Debian/Ubuntu 容器（无需 apt / 无需 root）
# 用法：PS_ROOT=/path . ./install-node.sh
# =============================================================================
set -euo pipefail

PS_ROOT="${PS_ROOT:-$HOME/puppy-stardew}"
NODE_DIR="$PS_ROOT/node"

if [ -x "$NODE_DIR/bin/node" ]; then
  echo "[node] 已存在：$("$NODE_DIR/bin/node" --version)"
  exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  NODE_ARCH=x64   ;;
  aarch64) NODE_ARCH=arm64 ;;
  armv7l)  NODE_ARCH=armv7l ;;
  *) echo "[node] 不支持的架构：$ARCH"; exit 1 ;;
esac

# 默认取 Node 20 LTS；可用 NODE_VERSION 覆盖（如 18.20.4）
VER="${NODE_VERSION:-20.18.1}"
URL="https://nodejs.org/dist/v${VER}/node-v${VER}-linux-${NODE_ARCH}.tar.xz"

echo "[node] 下载 $URL"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/node.tar.xz"

mkdir -p "$NODE_DIR"
tar -xJf "$TMP/node.tar.xz" -C "$TMP"
cp -a "$TMP/node-v${VER}-linux-${NODE_ARCH}/." "$NODE_DIR/"

echo "[node] 安装完成：$("$NODE_DIR/bin/node" --version)"
