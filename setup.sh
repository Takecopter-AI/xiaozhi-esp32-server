#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/xiaozhi-server}"
RAW_BASE_URL="${XIAOZHI_RAW_BASE_URL:-https://raw.githubusercontent.com/Takecopter-AI/xiaozhi-esp32-server/main}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose_all.yml"
HTTP_PORT="${NGINX_HTTP_PORT:-8080}"
HTTPS_PORT="${NGINX_HTTPS_PORT:-8443}"
WS_PORT="${NGINX_WS_PORT:-18080}"
WSS_PORT="${NGINX_WSS_PORT:-18443}"

die() {
    echo "错误: $*" >&2
    exit 1
}

USER_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && command -v getent >/dev/null 2>&1; then
    SUDO_USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -z "$SUDO_USER_HOME" ] || USER_HOME="$SUDO_USER_HOME"
fi

DOMAIN=""
DOMAIN_FILE="${XZ_DOMAIN_FILE:-$USER_HOME/.xz_domain}"
if [ -f "$DOMAIN_FILE" ]; then
    DOMAIN="$(tr '[:upper:]' '[:lower:]' < "$DOMAIN_FILE" | tr -d '\r\n')"
    if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        die "域名文件内容无效: $DOMAIN_FILE"
    fi
fi

CERTIFICATE_PATH="${NGINX_SSL_CERTIFICATE:-}"
CERTIFICATE_KEY_PATH="${NGINX_SSL_CERTIFICATE_KEY:-}"
if [ -n "$DOMAIN" ]; then
    CERTIFICATE_PATH="${CERTIFICATE_PATH:-/etc/letsencrypt/live/$DOMAIN/fullchain.pem}"
    CERTIFICATE_KEY_PATH="${CERTIFICATE_KEY_PATH:-/etc/letsencrypt/live/$DOMAIN/privkey.pem}"
fi
HTTPS_ENABLED=true
NGINX_CONFIG_TEMPLATE=./nginx/default.conf.template

download() {
    local source_url="$1"
    local target_path="$2"
    local temporary_path="${target_path}.tmp"

    curl -fL --retry 3 "$source_url" -o "$temporary_path"
    mv "$temporary_path" "$target_path"
}

install_docker() {
    [ "$(uname -s)" = "Linux" ] || die "请先安装并启动 Docker Desktop"
    [ "$(id -u)" -eq 0 ] || die "安装 Docker 需要 root 权限"
    [ -f /etc/os-release ] || die "无法识别 Linux 发行版"

    . /etc/os-release
    case "$ID" in
        ubuntu|debian) ;;
        *) die "自动安装 Docker 仅支持 Debian/Ubuntu" ;;
    esac

    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

configure_https() {
    case "${ENABLE_HTTPS:-}" in
        0|false|FALSE|no|NO)
            HTTPS_ENABLED=false
            NGINX_CONFIG_TEMPLATE=./nginx/http.conf.template
            return
            ;;
    esac

    if [ -f "$CERTIFICATE_PATH" ] && [ -f "$CERTIFICATE_KEY_PATH" ]; then
        return
    fi

    echo "未找到 HTTPS 证书: ${CERTIFICATE_PATH:-未配置}"
    if [ -t 0 ]; then
        read -r -p "请输入 fullchain.pem 的绝对路径，直接回车则仅部署 HTTP/WS: " INPUT_CERTIFICATE_PATH
    else
        INPUT_CERTIFICATE_PATH=""
    fi

    if [ -z "$INPUT_CERTIFICATE_PATH" ]; then
        HTTPS_ENABLED=false
        NGINX_CONFIG_TEMPLATE=./nginx/http.conf.template
        return
    fi

    read -r -p "请输入 privkey.pem 的绝对路径: " INPUT_CERTIFICATE_KEY_PATH
    CERTIFICATE_PATH="$INPUT_CERTIFICATE_PATH"
    CERTIFICATE_KEY_PATH="$INPUT_CERTIFICATE_KEY_PATH"
    [ -f "$CERTIFICATE_PATH" ] || die "SSL 证书不存在: $CERTIFICATE_PATH"
    [ -f "$CERTIFICATE_KEY_PATH" ] || die "SSL 私钥不存在: $CERTIFICATE_KEY_PATH"
}

write_env_file() {
    if [ "$HTTPS_ENABLED" = false ]; then
        CERTIFICATE_PATH="$INSTALL_DIR/nginx/empty.pem"
        CERTIFICATE_KEY_PATH="$CERTIFICATE_PATH"
        touch "$CERTIFICATE_PATH"
    fi

    umask 077
    printf 'ENABLE_HTTPS=%s\nXZ_DOMAIN=%s\nNGINX_CONFIG_TEMPLATE=%s\nNGINX_SSL_CERTIFICATE=%s\nNGINX_SSL_CERTIFICATE_KEY=%s\nNGINX_HTTP_PORT=%s\nNGINX_HTTPS_PORT=%s\nNGINX_WS_PORT=%s\nNGINX_WSS_PORT=%s\n' \
        "$HTTPS_ENABLED" "$DOMAIN" "$NGINX_CONFIG_TEMPLATE" "$CERTIFICATE_PATH" "$CERTIFICATE_KEY_PATH" "$HTTP_PORT" "$HTTPS_PORT" "$WS_PORT" "$WSS_PORT" > "$ENV_FILE"
}

configure_https

command -v curl >/dev/null 2>&1 || {
    [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -eq 0 ] || die "请先安装 curl"
    apt-get update
    apt-get install -y curl
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    install_docker
fi
docker info >/dev/null 2>&1 || die "Docker daemon 未运行"

mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/models/SenseVoiceSmall" "$INSTALL_DIR/nginx"
write_env_file

download "$RAW_BASE_URL/main/xiaozhi-server/docker-compose_all.yml" "$COMPOSE_FILE"
download "$RAW_BASE_URL/main/xiaozhi-server/nginx/default.conf.template" "$INSTALL_DIR/nginx/default.conf.template"
download "$RAW_BASE_URL/main/xiaozhi-server/nginx/http.conf.template" "$INSTALL_DIR/nginx/http.conf.template"
download "$RAW_BASE_URL/main/xiaozhi-server/.env.example" "$INSTALL_DIR/.env.example"

if [ ! -f "$INSTALL_DIR/data/.config.yaml" ]; then
    download "$RAW_BASE_URL/main/xiaozhi-server/config_from_api.yaml" "$INSTALL_DIR/data/.config.yaml"
fi

if [ ! -f "$INSTALL_DIR/models/SenseVoiceSmall/model.pt" ]; then
    download "https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt" \
        "$INSTALL_DIR/models/SenseVoiceSmall/model.pt"
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

if [ "$HTTPS_ENABLED" = true ]; then
    DISPLAY_HOST="${DOMAIN:-你的域名}"
    echo "部署已启动：HTTPS https://$DISPLAY_HOST:$HTTPS_PORT/，WebSocket wss://$DISPLAY_HOST:$WSS_PORT/xiaozhi/v1/"
else
    echo "部署已启动：HTTP http://<服务器地址>:$HTTP_PORT/，WebSocket ws://<服务器地址>:$WS_PORT/xiaozhi/v1/"
fi
echo "首次部署后仍需在 $INSTALL_DIR/data/.config.yaml 中配置 manager-api.secret。"
