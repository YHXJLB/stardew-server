#!/bin/bash
# =============================================================================
# install-deps.sh - 免 root 安装运行时依赖
# Puppy Stardew Server (rootless / native)
#
# 两条路径：
#   A) 有 root / 免密 sudo  -> 直接 apt-get install（最省事、最稳）
#   B) 纯普通用户（容器）    -> 拉取官方 Packages.gz，BFS 解析依赖闭包，
#                              curl 下载 .deb，dpkg-deb -x 解压到
#                              $PS_ROOT/deps（amd64）与 $PS_ROOT/deps32（i386）
#
# 关键设计：系统已安装的包一律跳过（避免把另一套 glibc 混进 LD_LIBRARY_PATH），
# 只补装缺失的部分；i386 始终单独下载（SteamCMD 需要 32 位库）。
#
# 用法： PS_ROOT=/path ./install-deps.sh [--force] [--check]
# =============================================================================
set -uo pipefail

PS_ROOT="${PS_ROOT:-$HOME/puppy-stardew}"
DEPS="$PS_ROOT/deps"
DEPS32="$PS_ROOT/deps32"
BIN="$PS_ROOT/bin"
CACHE="$PS_ROOT/.cache/debs"

log()  { echo "[deps] $*"; }
warn() { echo "[deps] [警告] $*"; }
err()  { echo "[deps] [错误] $*" >&2; }

usage() {
    cat <<'U'
用法: install-deps.sh [--force] [--check]

  --force   忽略已完成标记，强制重新安装
  --check   只检查依赖是否齐备，不安装
U
}

FORCE=0; CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --check) CHECK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------- 需要的能力
# 原生运行真正会用到的命令（对照 Dockerfile 与实际脚本调用整理）
NEED_BINS="Xvfb x11vnc xdotool xrandr unzip zip perl pgrep pkill"

check_tools() {
    local miss=0 b
    echo "---- 依赖自检 ----"
    for b in $NEED_BINS; do
        if [ -x "$BIN/$b" ]; then
            printf '  [已就绪] %-10s (本地 wrapper)\n' "$b"
        elif command -v "$b" >/dev/null 2>&1; then
            printf '  [已就绪] %-10s (系统) %s\n' "$b" "$(command -v "$b")"
        else
            printf '  [缺失]   %-10s\n' "$b"; miss=$((miss+1))
        fi
    done
    # 32 位 SteamCMD 支持
    local ld32=""
    for c in "$DEPS32/lib/i386-linux-gnu/ld-linux.so.2" \
             "$DEPS32/usr/lib/i386-linux-gnu/ld-linux.so.2" \
             "/lib/ld-linux.so.2" "/lib/i386-linux-gnu/ld-linux.so.2"; do
        [ -e "$c" ] && { ld32="$c"; break; }
    done
    if [ -n "$ld32" ]; then
        echo "  [已就绪] 32位加载器  $ld32"
    else
        echo "  [缺失]   32位加载器（SteamCMD 需要 i386 库）"; miss=$((miss+1))
    fi
    echo "------------------"
    return "$miss"
}

if [ "$CHECK" = 1 ]; then
    check_tools; exit $?
fi

if [ -f "$DEPS/.done" ] && [ "$FORCE" != 1 ]; then
    log "依赖已安装（$DEPS/.done 存在），跳过。加 --force 可强制重装。"
    check_tools; exit 0
fi

mkdir -p "$DEPS" "$DEPS32" "$BIN" "$CACHE"

# ------------------------------------------------------------ 系统信息探测
SYSARCH="$(dpkg --print-architecture 2>/dev/null || true)"
if [ -z "$SYSARCH" ]; then
    case "$(uname -m)" in
        x86_64|amd64) SYSARCH=amd64 ;;
        i?86)         SYSARCH=i386  ;;
        aarch64)      SYSARCH=arm64 ;;
        *)            SYSARCH=amd64 ;;
    esac
fi

ID=debian; SUITE=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ID="${ID:-debian}"
    SUITE="${VERSION_CODENAME:-}"
fi
[ -z "$SUITE" ] && SUITE="$(lsb_release -cs 2>/dev/null || true)"
if [ -z "$SUITE" ]; then
    if [ "$ID" = "ubuntu" ]; then SUITE=noble; else SUITE=bookworm; fi
    warn "无法探测发行版代号，假定 $ID $SUITE（可用 SUITE=xxx 覆盖）"
fi

if [ "$ID" = "ubuntu" ]; then
    MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
    COMPONENTS="main universe"
else
    MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
    COMPONENTS="main"
fi
log "系统: arch=$SYSARCH distro=$ID suite=$SUITE"
log "镜像: $MIRROR  组件: $COMPONENTS"

# ------------------------------------------------------------ 下载工具
DL=""
if command -v curl >/dev/null 2>&1; then DL=curl
elif command -v wget >/dev/null 2>&1; then DL=wget; fi

dl() { # dl <url> <dest>
    local url="$1" dest="$2"
    if [ "$DL" = curl ]; then
        curl -fsSL --retry 2 --connect-timeout 20 "$url" -o "$dest" 2>/dev/null
    elif [ "$DL" = wget ]; then
        wget -q -T 20 -O "$dest" "$url" 2>/dev/null
    else
        return 127
    fi
}

if [ -z "$DL" ]; then
    err "既没有 curl 也没有 wget，无法下载依赖。"
    err "请先安装其一： (sudo) apt-get install -y curl"
    exit 1
fi

# ------------------------------------------------------------ 种子包
# amd64：Xvfb / VNC / xdotool / xrandr / 压缩 / Mesa 软渲染 / SDL2 / xkb / 字体
SEEDS_AMD64="xvfb x11vnc xdotool x11-xserver-utils procps netcat-openbsd socat git \
unzip zip perl libsdl2-2.0-0 libgl1-mesa-dri libglx-mesa0 libegl-mesa0 \
libgl1 libglu1-mesa xkb-data x11-xkb-utils fonts-dejavu-core openbox"

# i386：SteamCMD 所需 32 位运行库（其余依赖由闭包自动补全）
SEEDS_I386="libc6 libgcc-s1 libstdc++6 libcurl4 zlib1g"

# ------------------------------------------------------------ 路径 A：apt
have_root() {
    [ "$(id -u)" = 0 ] && return 0
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then return 0; fi
    return 1
}

apt_packages="ca-certificates curl wget unzip zip procps netcat-openbsd perl \
xvfb x11vnc xdotool x11-xserver-utils openbox \
libsdl2-2.0-0 libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgl1 libglu1-mesa \
xkb-data x11-xkb-utils fonts-dejavu-core"

if have_root; then
    SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"
    log "检测到 root/免密 sudo -> 使用 apt-get 安装（路径 A）"
    if [ "$SYSARCH" = amd64 ]; then
        $SUDO dpkg --add-architecture i386 2>/dev/null || warn "无法添加 i386 架构"
    fi
    $SUDO apt-get update -qq 2>/dev/null || warn "apt-get update 失败，继续尝试安装"
    # shellcheck disable=SC2086
    $SUDO apt-get install -y --no-install-recommends $apt_packages 2>&1 | tail -5 \
        || warn "部分包安装失败，将尝试免 root 路径补齐"
    if [ "$SYSARCH" = amd64 ]; then
        # shellcheck disable=SC2086
        $SUDO apt-get install -y --no-install-recommends \
            libc6:i386 libstdc++6:i386 libgcc-s1:i386 libcurl4:i386 zlib1g:i386 2>&1 | tail -3 \
            || warn "32 位库安装失败，将由免 root 路径补齐"
    fi
    touch "$DEPS/.done"
fi

# 32 位加载器是否已就绪（root 路径已装 i386 库时无需再下载）
has_32bit_loader() {
    local c
    for c in "$DEPS32/lib/i386-linux-gnu/ld-linux.so.2" \
             "$DEPS32/usr/lib/i386-linux-gnu/ld-linux.so.2" \
             /lib/ld-linux.so.2 /lib/i386-linux-gnu/ld-linux.so.2 \
             /lib32/ld-linux.so.2 /usr/lib32/ld-linux.so.2; do
        [ -e "$c" ] && return 0
    done
    return 1
}

# ------------------------------------------------------------ 路径 B：免 root
# 索引获取
IDX_AMD64=""; IDX_I386=""
fetch_index() { # fetch_index <arch>  -> 设置全局 IDX_<ARCH>
    local arch="$1" out="$CACHE/Packages-$arch.txt" comp url gz got=0
    : > "$out"
    for comp in $COMPONENTS; do
        url="$MIRROR/dists/$SUITE/$comp/binary-$arch/Packages.gz"
        gz="$CACHE/Packages-$arch-$comp.gz"
        if dl "$url" "$gz" && gunzip -c "$gz" >> "$out" 2>/dev/null; then
            got=1
        else
            warn "索引下载失败: $url"
        fi
    done
    [ "$got" = 1 ] && [ -s "$out" ] || return 1
    case "$arch" in
        amd64) IDX_AMD64="$out" ;;
        i386)  IDX_I386="$out"  ;;
    esac
    return 0
}

# Packages -> TSV:  pkg \t filename \t depends \t provides
parse_index() { # parse_index <idx> <tsv>
    awk 'BEGIN{RS="";FS="\n"}
    {
        pkg="";fn="";dep="";pre="";prov=""
        for(i=1;i<=NF;i++){
            if($i ~ /^Package: /)      pkg=substr($i,10)
            else if($i ~ /^Filename: /)  fn=substr($i,11)
            else if($i ~ /^Depends: /)   dep=substr($i,10)
            else if($i ~ /^Pre-Depends: /) pre=substr($i,14)
            else if($i ~ /^Provides: /)  prov=substr($i,11)
        }
        if(pkg!="" && fn!=""){
            d=dep; if(pre!="") d=(d==""?"":d",")pre
            gsub(/\t/," ",d); gsub(/\t/," ",prov)
            print pkg "\t" fn "\t" d "\t" prov
        }
    }' "$1" > "$2"
}

# BFS 解析依赖闭包，输出 "pkg\tfilename"
resolve_closure() { # resolve_closure <tsv> <seed...>
    local tsv="$1"; shift
    declare -A FN DEP PROV PV seen chosen
    local p f d pr v item target
    local -a arr dl_arr queue=()

    while IFS=$'\t' read -r p f d pr; do
        [ -z "$p" ] && continue
        if [ -z "${FN[$p]:-}" ]; then
            FN[$p]="$f"; DEP[$p]="$d"; PROV[$p]="$pr"
        fi
    done < "$tsv"

    for p in "${!PROV[@]}"; do
        IFS=',' read -ra arr <<< "${PROV[$p]}"
        for v in "${arr[@]}"; do
            v="${v%%(*}"; v="${v// /}"
            [ -n "$v" ] && PV["$v"]="$p"
        done
    done

    for item in "$@"; do
        item="${item// /}"
        [ -z "$item" ] && continue
        if [ -z "${seen[$item]:-}" ]; then seen["$item"]=1; queue+=("$item"); fi
    done

    while [ ${#queue[@]} -gt 0 ]; do
        item="${queue[0]}"; queue=("${queue[@]:1}")
        target="$item"
        if [ -z "${FN[$target]:-}" ] && [ -n "${PV[$target]:-}" ]; then
            target="${PV[$target]}"
        fi
        [ -n "${FN[$target]:-}" ] || continue
        [ -n "${chosen[$target]:-}" ] && continue
        chosen["$target"]=1

        IFS=',' read -ra dl_arr <<< "${DEP[$target]}"
        for d in "${dl_arr[@]}"; do
            d="${d%%|*}"          # 只取第一个备选
            d="${d%%(*}"          # 去掉版本约束
            d="${d#"${d%%[![:space:]]*}"}"
            d="${d%"${d##*[![:space:]]}"}"
            [ -z "$d" ] && continue
            [ -n "${seen[$d]:-}" ] && continue
            seen["$d"]=1
            queue+=("$d")
        done
    done

    for p in "${!chosen[@]}"; do
        printf '%s\t%s\n' "$p" "${FN[$p]}"
    done
}

# .deb 解包（优先 dpkg-deb，回退 ar + tar）
extract_deb() { # extract_deb <deb> <dest>
    local deb="$1" dest="$2" tmp data rc
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb" "$dest" 2>/dev/null && return 0
    fi
    tmp="$(mktemp -d)"
    ( cd "$tmp" && ar x "$deb" ) 2>/dev/null || { rm -rf "$tmp"; return 1; }
    data="$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)"
    if [ -n "$data" ]; then
        tar -xf "$data" -C "$dest" 2>/dev/null; rc=$?
    else
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

install_arch() { # install_arch <arch> <dest> <seed...>
    local arch="$1" dest="$2"; shift 2
    local idx tsv closure total ok=0 fail=0 skip=0 p f deb

    if ! fetch_index "$arch"; then
        err "无法获取 $arch 软件索引，跳过该架构"
        return 1
    fi
    case "$arch" in
        amd64) idx="$IDX_AMD64" ;;
        i386)  idx="$IDX_I386"  ;;
        *)     idx="" ;;
    esac
    [ -s "$idx" ] || { err "$arch 索引为空"; return 1; }

    tsv="$CACHE/Packages-$arch.tsv"
    parse_index "$idx" "$tsv"
    log "解析 $arch 依赖闭包..."
    closure="$(resolve_closure "$tsv" "$@")"
    total="$(printf '%s\n' "$closure" | grep -c . )"
    log "  $arch 闭包共 $total 个包"

    while IFS=$'\t' read -r p f; do
        [ -z "$p" ] && continue
        # 系统架构且已安装 -> 跳过（避免混入第二套 glibc）
        if [ "$arch" = "$SYSARCH" ] && \
           dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed; then
            skip=$((skip+1)); continue
        fi
        deb="$CACHE/${p}_${arch}.deb"
        if [ ! -s "$deb" ]; then
            dl "$MIRROR/$f" "$deb" || { warn "下载失败: $p"; fail=$((fail+1)); continue; }
        fi
        if extract_deb "$deb" "$dest"; then
            ok=$((ok+1))
        else
            warn "解包失败: $p"; fail=$((fail+1))
        fi
    done <<< "$closure"

    log "  $arch 完成: 安装 $ok / 跳过(系统已有) $skip / 失败 $fail"
    [ "$fail" -eq 0 ]
}

# wrapper 生成：把本地 deps 的库路径注入，或直接透传给系统命令
gen_wrapper() { # gen_wrapper <name> <bin> [extra...]
    local name="$1" bin="$2"; shift 2
    local target="" c extra="$*"
    for c in "$DEPS/usr/bin/$bin" "$DEPS/bin/$bin" "$DEPS/usr/sbin/$bin"; do
        [ -x "$c" ] && { target="$c"; break; }
    done
    if [ -z "$target" ]; then
        if command -v "$bin" >/dev/null 2>&1; then
            target="$(command -v "$bin")"
        else
            warn "未找到 $bin，跳过 wrapper"; return 1
        fi
    fi
    cat > "$BIN/$name" <<EOF
#!/bin/bash
# 自动生成 - $name wrapper（非 Docker 部署）
export LD_LIBRARY_PATH="$DEPS/usr/lib/x86_64-linux-gnu:$DEPS/lib/x86_64-linux-gnu:$DEPS/usr/lib:$DEPS/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
if [ -d "$DEPS/usr/lib/x86_64-linux-gnu/dri" ]; then
  export LIBGL_DRIVERS_PATH="$DEPS/usr/lib/x86_64-linux-gnu/dri\${LIBGL_DRIVERS_PATH:+:\${LIBGL_DRIVERS_PATH}}"
fi
export GALLIUM_DRIVER="\${GALLIUM_DRIVER:-llvmpipe}"
exec "$target" $extra "\$@"
EOF
    chmod +x "$BIN/$name"
    log "  wrapper: $name -> $target"
}

make_wrappers() {
    log "生成命令 wrapper 到 $BIN"
    local xkb="$DEPS/usr/share/X11/xkb" extra=""
    [ -d "$xkb" ] && extra="-xkbdir $xkb"
    gen_wrapper Xvfb    Xvfb    $extra
    gen_wrapper x11vnc  x11vnc
    gen_wrapper xdotool xdotool
    gen_wrapper xrandr  xrandr

    # SteamCMD 包装器：仅当系统没有 steamcmd 时才安装本地包装器，
    # 避免覆盖简幻欢等镜像预装的 steamcmd 命令
    if command -v steamcmd >/dev/null 2>&1; then
        log "  检测到系统 steamcmd，跳过本地包装器（直接复用系统命令）"
    else
        local src="$PS_ROOT/native/lib/steamcmd-wrapper.sh"
        if [ -f "$src" ]; then
            cp -f "$src" "$BIN/steamcmd" && chmod +x "$BIN/steamcmd"
            log "  wrapper: steamcmd -> $src"
        fi
    fi
    # 其它本地二进制（若已解压到 deps）
    local b
    for b in unzip zip xdpyinfo wmctrl openbox; do
        if [ -x "$DEPS/usr/bin/$b" ] && [ ! -e "$BIN/$b" ]; then
            gen_wrapper "$b" "$b"
        fi
    done
}

# ============================== 主流程 ==============================
if [ "$SYSARCH" = amd64 ] || [ "$SYSARCH" = arm64 ]; then
    if [ -z "$(ls -A "$DEPS" 2>/dev/null)" ] || [ "$FORCE" = 1 ] || ! command -v Xvfb >/dev/null 2>&1; then
        log "安装 ${SYSARCH} 主依赖 -> $DEPS"
        install_arch "$SYSARCH" "$DEPS" $SEEDS_AMD64 || warn "主依赖未完全就绪"
    else
        log "系统已提供 Xvfb 等命令，跳过主依赖安装（--force 可强制）"
    fi
    if [ "$SYSARCH" = amd64 ]; then
        if has_32bit_loader; then
            log "32 位加载器已存在，跳过 i386 库下载"
        else
            log "安装 i386 32 位库 -> $DEPS32"
            install_arch i386 "$DEPS32" $SEEDS_I386 || warn "i386 依赖未完全就绪（SteamCMD 可能失败）"
        fi
    else
        warn "架构 $SYSARCH 无法运行 32 位 SteamCMD，需手动准备游戏文件"
    fi
else
    log "架构 $SYSARCH：仅安装同架构依赖"
    install_arch "$SYSARCH" "$DEPS" $SEEDS_AMD64 || warn "依赖未完全就绪"
fi

make_wrappers
touch "$DEPS/.done"
log "完成。运行 ./native/lib/install-deps.sh --check 复核。"
check_tools
exit 0
