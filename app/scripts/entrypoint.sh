#!/bin/bash
# >>> native bootstrap (非 Docker 部署) >>>
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/ps-env.sh"
# <<< native bootstrap <<<
# Puppy Stardew Server Entrypoint Script - v1.1.0
# 小狗星谷服务器启动脚本 - v1.1.0

# DO NOT use set -e - we need manual error handling
# 不使用 set -e - 需要手动错误处理

# Color codes for pretty logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PANEL_ENV_FILE=${ENV_FILE:-${PS_HOME}/web-panel/data/runtime.env}

if [ ! -f "$PANEL_ENV_FILE" ] && [ -f "${PS_HOME}/.env" ]; then
    PANEL_ENV_FILE="${PS_HOME}/.env"
fi

load_panel_env_overrides() {
    local env_file=${1:-$PANEL_ENV_FILE}

    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac

        local key=${line%%=*}
        local value=${line#*=}

        case "$key" in
            ''|*[!A-Za-z0-9_]*)
                continue
                ;;
        esac

        export "$key=$value"
    done < "$env_file"
}

load_panel_env_overrides

# Resolution and performance environment variables with defaults
DEFAULT_RESOLUTION_WIDTH=1280
DEFAULT_RESOLUTION_HEIGHT=720
DEFAULT_REFRESH_RATE=60
LOW_PERF_DEFAULT_WIDTH=800
LOW_PERF_DEFAULT_HEIGHT=600
LOW_PERF_DEFAULT_FPS=30
LOW_PERF_DEFAULT_COLOR_DEPTH=16

LOW_PERF_MODE=${LOW_PERF_MODE:-false}
TARGET_FPS_RAW=${TARGET_FPS:-}
RESOLUTION_WIDTH=${RESOLUTION_WIDTH:-$DEFAULT_RESOLUTION_WIDTH}
RESOLUTION_HEIGHT=${RESOLUTION_HEIGHT:-$DEFAULT_RESOLUTION_HEIGHT}
REFRESH_RATE=${REFRESH_RATE:-${TARGET_FPS_RAW:-$DEFAULT_REFRESH_RATE}}
TARGET_FPS=${TARGET_FPS_RAW:-$REFRESH_RATE}
XVFB_COLOR_DEPTH=24
XVFB_FB_DIR=""
XVFB_FB_ARGS=()

# Logging functions
log_info() {
    echo -e "${GREEN}[Puppy-Stardew]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[Puppy-Stardew]${NC} $1"
}

log_error() {
    echo -e "${RED}[Puppy-Stardew]${NC} $1"
}

log_step() {
    echo -e "${BLUE}${1}${NC}"
}

log_steam() {
    echo -e "${CYAN}$1${NC}"
}

configure_audio_driver() {
    if [ -n "${SDL_AUDIODRIVER:-}" ]; then
        :
    else
        export SDL_AUDIODRIVER=dummy
        log_info "No explicit audio driver configured; defaulting SDL_AUDIODRIVER=dummy"
        log_info "未显式配置音频驱动，默认使用 SDL_AUDIODRIVER=dummy"
    fi

    if [ -z "${ALSOFT_DRIVERS:-}" ]; then
        export ALSOFT_DRIVERS=null
        log_info "No explicit OpenAL driver configured; defaulting ALSOFT_DRIVERS=null"
        log_info "未显式配置 OpenAL 驱动，默认使用 ALSOFT_DRIVERS=null"
    fi
}

configure_performance_mode() {
    if [ "$LOW_PERF_MODE" != "true" ]; then
        return 0
    fi

    RESOLUTION_WIDTH=${LOW_PERF_RESOLUTION_WIDTH:-$LOW_PERF_DEFAULT_WIDTH}
    RESOLUTION_HEIGHT=${LOW_PERF_RESOLUTION_HEIGHT:-$LOW_PERF_DEFAULT_HEIGHT}

    if [ -z "$TARGET_FPS_RAW" ]; then
        TARGET_FPS=$LOW_PERF_DEFAULT_FPS
    fi
    REFRESH_RATE=${LOW_PERF_REFRESH_RATE:-$TARGET_FPS}
    XVFB_COLOR_DEPTH=${LOW_PERF_COLOR_DEPTH:-$LOW_PERF_DEFAULT_COLOR_DEPTH}

    export SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-x11}
    export SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}
    export MONO_GC_PARAMS=${MONO_GC_PARAMS:-nursery-size=8m}
    export DOTNET_GCHeapHardLimit=${DOTNET_GCHeapHardLimit:-0x30000000}

    if [ "${USE_GPU:-false}" != "true" ]; then
        export LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-1}
    fi

    XVFB_FB_DIR=${XVFB_FB_DIR:-/dev/shm/xvfb}
    if mkdir -p "$XVFB_FB_DIR" 2>/dev/null; then
        XVFB_FB_ARGS=(-fbdir "$XVFB_FB_DIR")
    else
        XVFB_FB_DIR=""
        XVFB_FB_ARGS=()
    fi

    log_info "Low performance mode enabled"
    log_info "低性能模式已启用"
    log_info "  Render target: ${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT} @ ${REFRESH_RATE}fps"
    log_info "  Xvfb color depth: ${XVFB_COLOR_DEPTH}bit"
    log_info "  SDL_VIDEODRIVER=${SDL_VIDEODRIVER}"
    log_info "  SDL_AUDIODRIVER=${SDL_AUDIODRIVER}"
    log_info "  MONO_GC_PARAMS=${MONO_GC_PARAMS}"
    log_info "  DOTNET_GCHeapHardLimit=${DOTNET_GCHeapHardLimit}"
    if [ -n "${LIBGL_ALWAYS_SOFTWARE:-}" ]; then
        log_info "  LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE}"
    fi
    if [ -n "$XVFB_FB_DIR" ]; then
        log_info "  Xvfb framebuffer directory: $XVFB_FB_DIR"
    fi
}

apply_startup_preferences_tuning() {
    local config_file=$1

    [ -f "$config_file" ] || return 0

    if [ "$LOW_PERF_MODE" != "true" ]; then
        return 0
    fi

    perl -0pi -e "s#<fullscreenResolutionX>.*?</fullscreenResolutionX>#<fullscreenResolutionX>${RESOLUTION_WIDTH}</fullscreenResolutionX>#s;
        s#<fullscreenResolutionY>.*?</fullscreenResolutionY>#<fullscreenResolutionY>${RESOLUTION_HEIGHT}</fullscreenResolutionY>#s;
        s#<preferredResolutionX>.*?</preferredResolutionX>#<preferredResolutionX>${RESOLUTION_WIDTH}</preferredResolutionX>#s;
        s#<preferredResolutionY>.*?</preferredResolutionY>#<preferredResolutionY>${RESOLUTION_HEIGHT}</preferredResolutionY>#s;
        s#<vsyncEnabled>.*?</vsyncEnabled>#<vsyncEnabled>true</vsyncEnabled>#s;
        s#<startMuted>.*?</startMuted>#<startMuted>true</startMuted>#s;
        s#<musicVolumeLevel>.*?</musicVolumeLevel>#<musicVolumeLevel>0</musicVolumeLevel>#s;
        s#<soundVolumeLevel>.*?</soundVolumeLevel>#<soundVolumeLevel>0</soundVolumeLevel>#s;" "$config_file"
}

# Function to download game via steamcmd
# 下载游戏函数
download_game_via_steam() {
    log_info "========================================="
    log_info "  Starting Steam download process"
    log_info "  开始 Steam 下载流程"
    log_info "========================================="
    log_info ""
    log_info "If Steam Guard is required, you will see a prompt."
    log_info "如果需要 Steam Guard，您会看到提示。"
    log_info ""
    log_info "To input Steam Guard code:"
    log_info "输入 Steam Guard 验证码："
    log_info "  1. 本机环境下，请运行: ./pss attach  (或 ./pss guard <验证码>) 输入 Steam Guard 验证码"
    log_info "  1. On native host, run: ./pss attach (or ./pss guard <CODE>) to enter Steam Guard code"
    log_info "  2. Enter the code when prompted below"
    log_info "  2. 在下面提示时输入验证码"
    log_info "  3. Press ENTER"
    log_info "  3. 按回车"
    log_info ""
    log_info "After successful authentication, game will download (~708MB)"
    log_info "验证成功后，游戏将开始下载（约708MB）"
    log_info "========================================="
    log_info ""

    # Support STEAM_GUARD_CODE environment variable for easier auth
    # 支持 STEAM_GUARD_CODE 环境变量以简化验证
    STEAM_GUARD_ARGS=""
    if [ -n "$STEAM_GUARD_CODE" ]; then
        log_info "Using Steam Guard code from environment variable"
        log_info "使用环境变量中的 Steam Guard 验证码"
        STEAM_GUARD_ARGS="+set_steam_guard_code $STEAM_GUARD_CODE"
    fi

    # Run steamcmd WITHOUT pipe - this preserves stdin!
    # 运行 steamcmd 不使用管道 - 保留stdin！
    steamcmd \
        +force_install_dir ${PS_HOME}/stardewvalley \
        $STEAM_GUARD_ARGS \
        +login "$STEAM_USERNAME" "$STEAM_PASSWORD" \
        +app_update 413150 validate \
        +quit

    DOWNLOAD_EXIT_CODE=$?

    # Check result
    if [ -f "${PS_HOME}/stardewvalley/StardewValley" ]; then
        log_info "✅ Game downloaded successfully!"
        log_info "✅ 游戏下载完成！"
        return 0
    else
        log_error "❌ Game download failed (exit code: $DOWNLOAD_EXIT_CODE)"
        log_error "❌ 游戏下载失败（退出码：$DOWNLOAD_EXIT_CODE）"
        log_error ""
        log_error "Common causes / 常见原因："
        log_error "  1. Steam Guard code incorrect / Steam Guard 验证码错误"
        log_error "  2. Network timeout / 网络超时"
        log_error "  3. Insufficient disk space / 磁盘空间不足"
        log_error "  4. Steam API rate limit / Steam API 速率限制"
        return 1
    fi
}

# =============================================
# GPU-related helper function
# GPU 加速相关辅助函数
# =============================================
start_gpu_xorg() {
    local context=${1:-"unknown"}
    if [ "$USE_GPU" != "true" ]; then
        log_warn "USE_GPU != true, skipping GPU startup (context: $context)"
        log_warn "USE_GPU != true，跳过 GPU 启动逻辑（context: $context）"
        return 3
    fi

    log_info "USE_GPU=true -> Attempting to start Xorg :99 for GPU rendering (context: $context)"
    log_info "USE_GPU=true -> 在 ${context} 阶段尝试启动 Xorg :99 以使用 GPU 渲染"
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true

    if [ -e /dev/dri/renderD128 ] || ls /dev/dri 2>/dev/null | grep -q .; then
        log_info "Detected /dev/dri, starting Xorg :99 (context: $context)"
        log_info "检测到 /dev/dri，准备启动 Xorg :99 (context: $context)"

        # Ensure X socket directory exists with correct permissions
        mkdir -p /tmp/.X11-unix
        chmod 1777 /tmp/.X11-unix

        # Ensure Xorg log directory exists
        mkdir -p ${PS_HOME}/.local/share/xorg
        if [ "$(id -u)" = "0" ]; then
            chown root:root ${PS_HOME}/.local/share/xorg 2>/dev/null || true
        fi

        # Start Xorg in background
        Xorg -noreset +extension GLX +extension RANDR :99 -logfile ${PS_HOME}/.local/share/xorg/Xorg.0.log &
        sleep 2

        # Set resolution via set-resolution.sh
        DISPLAY=:99 ${PS_HOME}/scripts/set-resolution.sh "${RESOLUTION_WIDTH}" "${RESOLUTION_HEIGHT}" "${REFRESH_RATE}" || {
            log_warn "Failed to set resolution (context: $context), continuing with default"
            log_warn "设置分辨率失败（context: $context），将继续使用默认分辨率"
        }
        sleep 1

        if pgrep -x Xorg >/dev/null 2>&1; then
            export DISPLAY=${DISPLAY:-:99}
            log_info "✓ Xorg started on :99 (context: $context)"
            log_info "✓ Xorg 已在 :99 启动（context: $context）"
            if command -v glxinfo >/dev/null 2>&1; then
                log_info "OpenGL renderer:"
                glxinfo | grep -i "OpenGL renderer" | head -n 1 || true
            fi
            return 0
        else
            log_warn "Xorg failed to start (context: $context)"
            log_warn "Xorg 未能在 ${context} 阶段启动"
            return 2
        fi
    else
        log_warn "/dev/dri not detected, skipping Xorg startup (context: $context)"
        log_warn "/dev/dri 未检测到或不可访问，跳过 Xorg 启动（context: $context）"
        return 1
    fi
}

# =============================================
# 原生（非 Docker）模式
# 原容器的 root 阶段（修复目录权限 / 切换到 steam 用户 / 以 root 启动 Xorg）
# 已在本部署中移除。脚本直接以当前（普通）用户运行；目录结构与权限由
# deploy.sh 一次性创建，无需 UID 1000 或 root。
# 若 USE_GPU=true 且当前用户对 /dev/dri 有权限，仍会尝试直接启动 Xorg，
# 否则自动回退到 Xvfb（软件渲染）。
# =============================================

configure_audio_driver
configure_performance_mode

if [ "$USE_GPU" = "true" ]; then
    start_gpu_xorg "native" || {
        log_warn "GPU startup in native phase unsuccessful, will fallback to Xvfb"
    }
fi

# =============================================
# Phase 2: Steam User Operations
# 阶段2：Steam 用户操作
# =============================================

log_step "================================================"
log_step "  Puppy Stardew Server v1.1.0 Starting..."
log_step "  小狗星谷服务器 v1.1.0 启动中..."
log_step "================================================"

# Native mode: 不再强制 UID=1000（原容器专用约束）。以当前用户运行即可。
log_info "Running as user: $(id -un) (uid=$(id -u))"

# Step 1: Validate Steam credentials (supports Docker Secrets)
# 步骤 1：验证 Steam 凭证（支持 Docker Secrets）
log_step "Step 1: Validating configuration..."

# Docker Secrets support: read from /run/secrets/ if env vars are empty
# Docker Secrets 支持：如果环境变量为空，从 /run/secrets/ 读取
if [ -z "$STEAM_USERNAME" ] && [ -f "/run/secrets/steam_username" ]; then
    STEAM_USERNAME=$(cat /run/secrets/steam_username | tr -d '\n')
    log_info "Steam username loaded from Docker Secret"
fi
if [ -z "$STEAM_PASSWORD" ] && [ -f "/run/secrets/steam_password" ]; then
    STEAM_PASSWORD=$(cat /run/secrets/steam_password | tr -d '\n')
    log_info "Steam password loaded from Docker Secret"
fi

if [ -z "$STEAM_USERNAME" ] || [ -z "$STEAM_PASSWORD" ]; then
    log_error "STEAM_USERNAME or STEAM_PASSWORD not set!"
    log_error "STEAM_USERNAME 或 STEAM_PASSWORD 未设置！"
    log_error "Set via .env file or Docker Secrets."
    log_error "通过 .env 文件或 Docker Secrets 设置。"
    exit 1
fi

log_info "Steam username: $STEAM_USERNAME"

# =============================================
# 端口配置（简幻欢 AIO：容器仅暴露单一主端口 SERVER_PORT）
# - 面板(TCP) 直接绑定 SERVER_PORT
# - 游戏(UDP) 固定 24642，用 socat 把 SERVER_PORT/UDP 转发到 24642
#   这样容器唯一对外端口同时承载「TCP→面板 + UDP→游戏」
# - 指标端口 9090 仅绑定 127.0.0.1（内网），外部不可达
# =============================================
export SERVER_PORT="${SERVER_PORT:-24642}"
export GAME_PORT="${GAME_PORT:-24642}"
export PANEL_PORT="${PANEL_PORT:-$SERVER_PORT}"
export METRICS_PORT="${METRICS_PORT:-9090}"
export METRICS_BIND="${METRICS_BIND:-127.0.0.1}"

# 启动 UDP 端口转发（无需 root，纯用户态）
if [ "$SERVER_PORT" != "$GAME_PORT" ]; then
    if command -v socat >/dev/null 2>&1; then
        log_info "Forwarding UDP ${SERVER_PORT} -> ${GAME_PORT} (socat)"
        socat UDP-RECV:"$SERVER_PORT",fork UDP-SENDTO:127.0.0.1:"$GAME_PORT" >/dev/null 2>&1 &
    elif command -v python3 >/dev/null 2>&1 && [ -f "$PS_ROOT/native/lib/udp-forward.py" ]; then
        log_info "Forwarding UDP ${SERVER_PORT} -> ${GAME_PORT} (python3 兜底，socat 未安装)"
        python3 "$PS_ROOT/native/lib/udp-forward.py" "$SERVER_PORT" "$GAME_PORT" 127.0.0.1 >/dev/null 2>&1 &
    else
        log_warn "socat 与 python3 均不可用，无法把 UDP ${SERVER_PORT} 转发到游戏端口 ${GAME_PORT}；游戏将仅能通过 ${GAME_PORT} 访问"
    fi
fi

# Step 2: Download game if needed
if [ ! -f "${PS_HOME}/stardewvalley/StardewValley" ]; then
    log_step "Step 2: Downloading Stardew Valley..."
    log_warn "Game files not found. Downloading from Steam..."
    log_warn "未找到游戏文件。正在从 Steam 下载..."
    log_warn "This will take 5-10 minutes depending on your connection."
    log_warn "根据网络情况，此过程需要 5-10 分钟。"
    log_warn ""

    # Clean up any existing Steam cache
    log_info "Cleaning Steam cache..."
    rm -rf ${PS_HOME}/Steam/config/* 2>/dev/null || true
    rm -rf ${PS_HOME}/Steam/logs/* 2>/dev/null || true
    rm -rf /tmp/steam* 2>/dev/null || true

    # Download game (handles Steam Guard automatically)
    if ! download_game_via_steam; then
        log_error "Failed to download game. Container will exit."
        log_error "游戏下载失败。容器将退出。"
        exit 1
    fi
else
    log_step "Step 2: Game files found, skipping download"
    log_info "✓ Stardew Valley already downloaded"
    log_info "✓ 星露谷物语已下载"
fi

# Step 3: Install SMAPI
log_step "Step 3: Installing SMAPI mod loader..."

if [ ! -f "${PS_HOME}/stardewvalley/StardewModdingAPI" ]; then
    log_info "Installing SMAPI..."
    cd ${PS_HOME}
    echo "1" | dotnet smapi/SMAPI*/internal/linux/SMAPI.Installer.dll --install --game-path ${PS_HOME}/stardewvalley

    if [ $? -ne 0 ]; then
        log_error "Failed to install SMAPI!"
        log_error "SMAPI 安装失败！"
        exit 1
    fi

    log_info "✓ SMAPI installed successfully!"
else
    log_info "✓ SMAPI already installed"
fi

# Step 4: Install mods
log_step "Step 4: Installing mods..."

mkdir -p ${PS_HOME}/stardewvalley/Mods

if [ -d "${PS_HOME}/preinstalled-mods" ]; then
    if [ -d "${PS_HOME}/stardewvalley/Mods/AutoHideHost" ]; then
        log_info "✓ Mods already installed"
    else
        log_info "Installing mods..."
        cp -r ${PS_HOME}/preinstalled-mods/* ${PS_HOME}/stardewvalley/Mods/
        log_info "✓ Mods installed successfully!"
    fi

    log_info "Installed mods:"
    ls -1 ${PS_HOME}/stardewvalley/Mods/ | while read mod; do
        log_info "  ✓ $mod"
    done
fi

# Step 4.5: Install user-provided mods from custom-mods volume
# 步骤 4.5：从 custom-mods 卷安装用户提供的模组
CUSTOM_MODS_DIR="${PS_HOME}/custom-mods"
if [ -d "$CUSTOM_MODS_DIR" ] && [ "$(ls -A "$CUSTOM_MODS_DIR" 2>/dev/null)" ]; then
    log_step "Step 4.5: Installing custom mods..."
    log_info "Found custom mods in $CUSTOM_MODS_DIR"

    for mod_entry in "$CUSTOM_MODS_DIR"/*; do
        mod_name=$(basename "$mod_entry")

        # Skip hidden files
        [[ "$mod_name" == .* ]] && continue

        if [ -d "$mod_entry" ]; then
            # It's a mod directory - copy to Mods/
            log_info "  Installing mod: $mod_name"
            cp -r "$mod_entry" "${PS_HOME}/stardewvalley/Mods/$mod_name"
        elif [[ "$mod_entry" == *.zip ]]; then
            # It's a zip file - extract to Mods/
            log_info "  Extracting mod: $mod_name"
            unzip -q -o "$mod_entry" -d "${PS_HOME}/stardewvalley/Mods/" 2>/dev/null || {
                log_warn "  ⚠ Failed to extract: $mod_name"
            }
        fi
    done
    log_info "✓ Custom mods installed"
fi

# Step 5: Setup virtual display
log_step "Step 5: Starting virtual display..."

# Check if Xorg is already running from root phase
START_XVFB_FALLBACK=false

if pgrep -x Xorg >/dev/null 2>&1; then
    export DISPLAY=${DISPLAY:-:99}
    log_info "Detected Xorg process, using DISPLAY=${DISPLAY}"
    log_info "检测到 Xorg 进程，使用 DISPLAY=${DISPLAY}"
    if command -v glxinfo >/dev/null 2>&1; then
        log_info "OpenGL renderer:"
        glxinfo | grep -i "OpenGL renderer" | head -n 1 || true
    fi
else
    # Fallback to Xvfb if GPU not enabled or failed
    if [ "$USE_GPU" = "true" ]; then
        log_warn "Xorg not running in steam phase, falling back to Xvfb"
        log_warn "steam 阶段 Xorg 未运行，回退到 Xvfb（软件渲染）"
    fi
    START_XVFB_FALLBACK=true
fi

# Start Xvfb as fallback
if [ "$START_XVFB_FALLBACK" = "true" ]; then
    log_info "Starting Xvfb (software rendering fallback)..."
    log_info "启动 Xvfb（软件渲染后备）..."
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
    Xvfb :99 -screen 0 "${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT}x${XVFB_COLOR_DEPTH}" -ac +extension GLX +render -noreset "${XVFB_FB_ARGS[@]}" &
    export DISPLAY=${DISPLAY:-:99}
    sleep 3
    log_info "✓ Virtual display started on ${DISPLAY} (${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT}x${XVFB_COLOR_DEPTH})"
    log_info "✓ 虚拟显示已启动 ${DISPLAY} (${RESOLUTION_WIDTH}x${RESOLUTION_HEIGHT}x${XVFB_COLOR_DEPTH})"
fi

# Step 6: Start VNC server (optional)
if [ "$ENABLE_VNC" = "true" ]; then
    log_step "Step 6: Starting VNC server..."

    # Do not ship a weak well-known default. If no password is provided, generate
    # a random one at runtime and persist it to a protected file for the operator.
    VNC_PASSWORD_FILE="${PS_HOME}/web-panel/data/vnc_password.txt"
    VNC_PASSWORD_GENERATED=false
    if [ -z "$VNC_PASSWORD" ]; then
        VNC_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8)
        VNC_PASSWORD_GENERATED=true
    fi

    if [ ${#VNC_PASSWORD} -gt 8 ]; then
        log_warn "VNC password > 8 chars, truncating to 8 characters (x11vnc limit)"
        VNC_PASSWORD="${VNC_PASSWORD:0:8}"
    fi

    # Persist the effective password to a 0600 file so the monitor and operator
    # can read it without printing the secret to container logs.
    export VNC_PASSWORD
    mkdir -p "$(dirname "$VNC_PASSWORD_FILE")" 2>/dev/null || true
    if printf '%s' "$VNC_PASSWORD" > "$VNC_PASSWORD_FILE" 2>/dev/null; then
        chmod 600 "$VNC_PASSWORD_FILE" 2>/dev/null || true
    fi

    # Wait for X server to be fully ready
    sleep 2

    # Start x11vnc pointing to current DISPLAY
    log_info "Starting x11vnc on display ${DISPLAY} (port 5900)..."
    x11vnc -display "${DISPLAY}" -forever -shared -passwd "$VNC_PASSWORD" -rfbport 5900 -noxdamage -bg 2>&1 | grep -v "^$"

    # Wait for x11vnc to start
    sleep 2

    # Verify VNC is running
    if pgrep -x "x11vnc" >/dev/null; then
        log_info "✓ VNC server started successfully on port 5900"
        if [ "$VNC_PASSWORD_GENERATED" = "true" ]; then
            log_info "  A random VNC password was generated (VNC_PASSWORD was not set)."
        fi
        log_info "  Password stored at: $VNC_PASSWORD_FILE (not printed to logs)"
        log_info "  VNC 密码已保存到: $VNC_PASSWORD_FILE （用 ./pss vncpass 查看，不会打印在日志）"
        log_info "  Connect to: your-server-ip:5900"

        # Start VNC monitor to keep it alive
        # 启动 VNC 监控，保持服务存活
        if [ -f "${PS_HOME}/scripts/vnc-monitor.sh" ]; then
            log_info "Starting VNC health monitor..."
            ${PS_HOME}/scripts/vnc-monitor.sh &
            log_info "✓ VNC monitor started (30s check interval)"
        fi
    else
        log_error "✗ VNC server failed to start"
        log_error "Check logs above for errors"
    fi
else
    log_step "Step 6: VNC disabled (set ENABLE_VNC=true to enable)"
fi

# Step 7: Setup optimized game config for VNC display
log_step "Step 7: Configuring game display settings..."

CONFIG_DIR="${PS_HOME}/.config/StardewValley"
CONFIG_FILE="$CONFIG_DIR/startup_preferences"
TEMPLATE="${PS_HOME}/startup_preferences.template"

# Create config directory if not exists
mkdir -p "$CONFIG_DIR"

# Copy optimized config template if startup_preferences doesn't exist yet
# 如果startup_preferences还不存在，复制优化的配置模板
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "$TEMPLATE" ]; then
        cp "$TEMPLATE" "$CONFIG_FILE"
        log_info "✓ Applied optimized display config (fullscreen mode for VNC)"
        log_info "✓ 已应用优化的显示配置（VNC全屏模式）"
    else
        log_warn "⚠ Template not found, game will use default settings"
    fi
else
    log_info "✓ Game config already exists, keeping user settings"
fi

apply_startup_preferences_tuning "$CONFIG_FILE"
if [ "$LOW_PERF_MODE" = "true" ]; then
    log_info "✓ Applied low performance startup preferences"
    log_info "✓ 已应用低性能启动偏好设置"
fi

# Step 7.5: Select save if specified
if [ -n "$SAVE_NAME" ]; then
    log_step "Step 7.5: Selecting save file..."
    ${PS_HOME}/scripts/save-selector.sh
fi

# Step 8: Start log monitoring (optional)
if [ "$ENABLE_LOG_MONITOR" = "true" ]; then
    log_step "Step 8: Starting log monitoring..."

    if [ -f "${PS_HOME}/scripts/log-monitor.sh" ]; then
        ${PS_HOME}/scripts/log-monitor.sh &
        log_info "✓ Log monitoring started"
    fi
else
    log_step "Step 8: Log monitoring disabled"
fi

# Step 9: Start game server
log_step "Step 9: Starting game server..."
log_info "================================================"
log_info "  Server is starting!"
log_info "  服务器启动中！"
log_info "================================================"
log_info ""
log_info "Save setup options:"
log_info "存档初始化方式："
log_info "  1. Web panel: http://localhost:${PANEL_PORT} (set admin password on first visit)"
log_info "  1. Web 面板：http://localhost:${PANEL_PORT}（首次访问先设置管理密码）"
log_info "  2. Upload an existing save in the panel and set it as the default auto-load save"
log_info "  2. 在面板上传现有存档，并设为默认自动加载存档"
log_info "  3. Optional: use VNC only if you want to create a new save manually in-game"
log_info "  3. 可选：只有想手动进游戏创建新存档时才使用 VNC"
log_info ""
log_info "Players connect via:"
log_info "玩家连接方式："
log_info "  1. Open Stardew Valley → CO-OP → Join LAN Game"
log_info "  1. 打开星露谷物语 → CO-OP → 加入局域网游戏"
log_info "  2. Server will appear automatically, or enter server IP directly"
log_info "  2. 服务器会自动出现，或直接输入服务器IP"
log_info "  3. Players connect on port ${SERVER_PORT}/UDP (forwarded to 24642)"
log_info "  3. 玩家通过端口 ${SERVER_PORT}/UDP 连接（已转发到 24642）"
log_info "================================================"
log_info ""

cd ${PS_HOME}/stardewvalley

# Start unified event handler in background
log_info "Starting unified event handler..."
${PS_HOME}/scripts/event-handler.sh &

# Start auto-backup if enabled
if [ "$ENABLE_AUTO_BACKUP" = "true" ]; then
    log_info "Starting auto-backup service..."
    ${PS_HOME}/scripts/auto-backup.sh &
fi

# Start status reporter (Prometheus metrics + JSON status)
log_info "Starting status reporter (metrics port: ${METRICS_PORT:-9090}, bind: ${METRICS_BIND:-127.0.0.1})..."
${PS_HOME}/scripts/status-reporter.sh &

# Start web panel
log_info "Starting web management panel (port: ${PANEL_PORT})..."
cd ${PS_HOME}/web-panel
node server.js &
WEB_PANEL_PID=$!
log_info "✓ Web panel started (PID: $WEB_PANEL_PID)"
log_info "  Access at: http://localhost:${PANEL_PORT}"
cd ${PS_HOME}/stardewvalley

# Start player access control if configured
if [ -f "${PS_HOME}/.config/StardewValley/player-access.conf" ]; then
    log_info "Starting player access control..."
    ${PS_HOME}/scripts/player-access.sh &
fi

# Start crash monitor if enabled
if [ "$ENABLE_CRASH_RESTART" = "true" ]; then
    log_info "Starting game with crash auto-restart..."
    log_info "启动游戏（崩溃自动重启模式）..."

    # Use crash-monitor.sh which wraps game in restart loop
    exec ${PS_HOME}/scripts/crash-monitor.sh
else
    # Run game with exec (traditional, container exits on crash)
    exec ./StardewModdingAPI --server
fi
