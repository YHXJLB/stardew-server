#!/bin/bash
# =============================================================================
# ps-env.sh - 非 Docker 部署的路径引导
# Puppy Stardew Server (native / rootless)
#
# 所有原容器内的 /home/steam 绝对路径，在此统一解析为 ${PS_HOME}。
# 用法：在每个脚本开头 source 本文件。
# =============================================================================

_ps_guess="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"

# 依次尝试：外部指定 PS_ROOT -> 脚本相对位置推断 -> 默认 $HOME/puppy-stardew
for _ps_candidate in "${PS_ROOT:-}" "$_ps_guess" "$HOME/puppy-stardew"; do
    [ -n "$_ps_candidate" ] || continue
    if [ -f "$_ps_candidate/native/env.sh" ]; then
        PS_ROOT="$_ps_candidate"
        # shellcheck disable=SC1091
        . "$_ps_candidate/native/env.sh"
        break
    fi
done

: "${PS_ROOT:=${_ps_guess:-$HOME/puppy-stardew}}"
PS_HOME="${PS_HOME:-$PS_ROOT/home/steam}"

export PS_ROOT PS_HOME
unset _ps_guess _ps_candidate
