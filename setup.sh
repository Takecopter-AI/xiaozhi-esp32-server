#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/xiaozhi-server}"
RAW_BASE_URL="${XIAOZHI_RAW_BASE_URL:-https://raw.githubusercontent.com/Takecopter-AI/xiaozhi-esp32-server/main}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose_all.yml"
CERTIFICATE_PATH="${NGINX_SSL_CERTIFICATE:-/etc/letsencrypt/live/xz.takecopter.cn/fullchain.pem}"
CERTIFICATE_KEY_PATH="${NGINX_SSL_CERTIFICATE_KEY:-/etc/letsencrypt/live/xz.takecopter.cn/privkey.pem}"
HTTP_PORT="${NGINX_HTTP_PORT:-8080}"
HTTPS_PORT="${NGINX_HTTPS_PORT:-8443}"
WS_PORT="${NGINX_WS_PORT:-18080}"
WSS_PORT="${NGINX_WSS_PORT:-18443}"

die() {
    echo "错误: $*" >&2
    exit 1
}

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

write_env_file() {
    [ -f "$CERTIFICATE_PATH" ] || die "SSL 证书不存在: $CERTIFICATE_PATH"
    [ -f "$CERTIFICATE_KEY_PATH" ] || die "SSL 私钥不存在: $CERTIFICATE_KEY_PATH"

    umask 077
    printf 'NGINX_SSL_CERTIFICATE=%s\nNGINX_SSL_CERTIFICATE_KEY=%s\nNGINX_HTTP_PORT=%s\nNGINX_HTTPS_PORT=%s\nNGINX_WS_PORT=%s\nNGINX_WSS_PORT=%s\n' \
        "$CERTIFICATE_PATH" "$CERTIFICATE_KEY_PATH" "$HTTP_PORT" "$HTTPS_PORT" "$WS_PORT" "$WSS_PORT" > "$ENV_FILE"
}

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

download "$RAW_BASE_URL/main/xiaozhi-server/docker-compose_all.yml" "$COMPOSE_FILE"
download "$RAW_BASE_URL/main/xiaozhi-server/nginx/default.conf.template" "$INSTALL_DIR/nginx/default.conf.template"
download "$RAW_BASE_URL/main/xiaozhi-server/.env.example" "$INSTALL_DIR/.env.example"

if [ ! -f "$INSTALL_DIR/data/.config.yaml" ]; then
    download "$RAW_BASE_URL/main/xiaozhi-server/config_from_api.yaml" "$INSTALL_DIR/data/.config.yaml"
fi

if [ ! -f "$INSTALL_DIR/models/SenseVoiceSmall/model.pt" ]; then
    download "https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt" \
        "$INSTALL_DIR/models/SenseVoiceSmall/model.pt"
fi

if [ -n "${NGINX_SSL_CERTIFICATE:-}" ] || [ -n "${NGINX_SSL_CERTIFICATE_KEY:-}" ] || [ ! -f "$ENV_FILE" ]; then
    write_env_file
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

echo "部署已启动：HTTPS https://xz.takecopter.cn:$HTTPS_PORT/，WebSocket wss://xz.takecopter.cn:$WSS_PORT/xiaozhi/v1/"
echo "首次部署后仍需在 $INSTALL_DIR/data/.config.yaml 中配置 manager-api.secret。"
