#!/bin/bash
# =============================================================================
# probe-runtime.sh - 把版本管理器（Mise/nvm/sdkman/fnm）管理的运行时加入 PATH
#
# 容器镜像（如简幻欢 SFE）通过 Mise 预装 Node/.NET/Python，但非交互 bash
# 不会加载 Mise 注入的 PATH，导致脚本里 `command -v node` 找不到系统已装的
# Node，进而又下载一份本地 Node。
#
# 简幻欢官方文档（customer-aio-path-list）给出的 Mise 绝对路径：
#   Node 22.14.0  -> /mise/installs/node/22/bin/node
#   .NET 6/8/9    -> /mise/installs/dotnet/6|8|9/dotnet
#   Python 3.13   -> /mise/installs/python/3.13/bin/python
# 另 Mise 会导出形如 ${node22} ${dotnet6} ${python3_13} 的环境变量指向二进制。
#
# 本脚本把上述真实二进制目录加进 PATH，让系统预装版本被优先识别
# （配合 env.sh / deploy.sh 的"系统优先"策略，本地安装仅作 fallback）。
#
# 用法：直接 source 本文件即可（. ./probe-runtime.sh），无需参数。
# =============================================================================

probe_runtime() {
  local d

  # ---- Mise（简幻欢 / SFE 默认；官方路径基址是 /mise）----
  local mise_base
  for mise_base in \
      "${MISE_DATA_DIR:-}" \
      "/mise" \
      "$HOME/.local/share/mise" \
      "/usr/local/share/mise" \
      "/opt/mise" \
      "/root/.local/share/mise" ; do
    [ -z "$mise_base" ] && continue
    [ -d "$mise_base" ] || continue

    # Node：/mise/installs/node/<版本>/bin
    if [ -d "$mise_base/installs/node" ]; then
      for d in "$mise_base/installs/node"/*/bin; do
        [ -x "$d/node" ] && export PATH="$d:$PATH"
      done
    fi
    # .NET：/mise/installs/dotnet/<版本>/dotnet（版本目录本身即 bin 目录）
    if [ -d "$mise_base/installs/dotnet" ]; then
      for d in "$mise_base/installs/dotnet"/*; do
        [ -x "$d/dotnet" ] && export PATH="$d:$PATH"
      done
    fi
    # Python：/mise/installs/python/<版本>/bin
    if [ -d "$mise_base/installs/python" ]; then
      for d in "$mise_base/installs/python"/*/bin; do
        [ -x "$d/python" ] && export PATH="$d:$PATH"
      done
    fi
    # Mise shims（符号链接集合，含 node/dotnet/python 等）
    [ -d "$mise_base/shims" ] && export PATH="$mise_base/shims:$PATH"
  done

  # ---- nvm ----
  if [ -d "$HOME/.nvm/versions/node" ]; then
    for d in "$HOME/.nvm/versions/node"/*/bin; do
      [ -x "$d/node" ] && export PATH="$d:$PATH"
    done
  fi

  # ---- fnm ----
  [ -d "$HOME/.local/share/fnm" ] && export PATH="$HOME/.local/share/fnm:$PATH"

  # ---- sdkman (java) ----
  [ -d "$HOME/.sdkman/candidates/java/current/bin" ] && \
    export PATH="$HOME/.sdkman/candidates/java/current/bin:$PATH"

  # ---- Mise 导出的环境变量（如 ${node22} ${dotnet6} ${python3_13}）----
  # 这些变量直接指向二进制绝对路径，作为最后兜底加入 PATH。
  local mv
  for mv in node22 node20 node18 dotnet6 dotnet8 dotnet9 python3_13 python3_12 python3_10 python3_9; do
    if [ -n "${!mv:-}" ] && [ -x "${!mv}" ]; then
      export PATH="$(dirname "${!mv}"):$PATH"
    fi
  done
}

probe_runtime
