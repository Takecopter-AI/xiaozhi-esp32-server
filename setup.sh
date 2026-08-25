#!/usr/bin/env bash
set -Eeuo pipefail

PLATFORM="$(uname -s)"
RAW_BASE_URL="${XIAOZHI_RAW_BASE_URL:-https://raw.githubusercontent.com/Takecopter-AI/xiaozhi-esp32-server/main}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HTTP_PORT="${NGINX_HTTP_PORT:-8008}"
HTTPS_PORT="${NGINX_HTTPS_PORT:-8443}"
WS_PORT="${NGINX_WS_PORT:-18080}"
WSS_PORT="${NGINX_WSS_PORT:-18443}"

die() {
    echo "Error: $*" >&2
    exit 1
}

USER_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    SUDO_USER_HOME=""
    if command -v getent >/dev/null 2>&1; then
        SUDO_USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    elif [ "$PLATFORM" = "Darwin" ]; then
        SUDO_USER_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    fi
    [ -z "$SUDO_USER_HOME" ] || USER_HOME="$SUDO_USER_HOME"
fi

if [ -z "${INSTALL_DIR:-}" ]; then
    if [ "$PLATFORM" = "Darwin" ]; then
        INSTALL_DIR="$USER_HOME/.xiaozhi-server"
    else
        INSTALL_DIR=/opt/xiaozhi-server
    fi
fi
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose_all.yml"

DOMAIN=""
DOMAIN_FILE="${XZ_DOMAIN_FILE:-$USER_HOME/.xz_domain}"
if [ -f "$DOMAIN_FILE" ]; then
    DOMAIN="$(tr '[:upper:]' '[:lower:]' < "$DOMAIN_FILE" | tr -d '\r\n')"
    if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        die "Invalid domain in file: $DOMAIN_FILE"
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
    local description="$1"
    local source_url="$2"
    local target_path="$3"
    local temporary_path="${target_path}.tmp"

    echo "Downloading: $description"
    echo "  Source: $source_url"
    echo "  Destination: $target_path"
    if ! curl -fL --retry 3 "$source_url" -o "$temporary_path"; then
        rm -f "$temporary_path"
        die "Failed to download: $description ($source_url)"
    fi
    mv "$temporary_path" "$target_path"
}

install_project_file() {
    local description="$1"
    local relative_path="$2"
    local target_path="$3"
    local local_path="$SCRIPT_DIR/$relative_path"

    if [ -f "$local_path" ]; then
        echo "Installing: $description"
        echo "  Source: $local_path"
        echo "  Destination: $target_path"
        if [ ! -e "$target_path" ] || [ ! "$local_path" -ef "$target_path" ]; then
            cp "$local_path" "$target_path"
        fi
        return
    fi

    download "$description" "$RAW_BASE_URL/$relative_path" "$target_path"
}

install_docker() {
    [ "$(uname -s)" = "Linux" ] || die "Install and start Docker Desktop first"
    [ "$(id -u)" -eq 0 ] || die "Root privileges are required to install Docker"
    [ -f /etc/os-release ] || die "Unable to identify the Linux distribution"

    . /etc/os-release
    case "$ID" in
        ubuntu|debian) ;;
        *) die "Automatic Docker installation supports Debian and Ubuntu only" ;;
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

    echo "HTTPS certificate not found: ${CERTIFICATE_PATH:-not configured}"
    if [ -t 0 ]; then
        read -r -p "Enter the absolute path to fullchain.pem, or press Enter to deploy HTTP/WS only: " INPUT_CERTIFICATE_PATH
    else
        INPUT_CERTIFICATE_PATH=""
    fi

    if [ -z "$INPUT_CERTIFICATE_PATH" ]; then
        HTTPS_ENABLED=false
        NGINX_CONFIG_TEMPLATE=./nginx/http.conf.template
        return
    fi

    read -r -p "Enter the absolute path to privkey.pem: " INPUT_CERTIFICATE_KEY_PATH
    CERTIFICATE_PATH="$INPUT_CERTIFICATE_PATH"
    CERTIFICATE_KEY_PATH="$INPUT_CERTIFICATE_KEY_PATH"
    [ -f "$CERTIFICATE_PATH" ] || die "SSL certificate not found: $CERTIFICATE_PATH"
    [ -f "$CERTIFICATE_KEY_PATH" ] || die "SSL private key not found: $CERTIFICATE_KEY_PATH"
}

prepare_certificate_mounts() {
    if [ "$PLATFORM" != "Darwin" ] || [ "$HTTPS_ENABLED" = false ]; then
        return
    fi

    install -m 0600 "$CERTIFICATE_PATH" "$INSTALL_DIR/nginx/fullchain.pem"
    install -m 0600 "$CERTIFICATE_KEY_PATH" "$INSTALL_DIR/nginx/privkey.pem"
    CERTIFICATE_PATH="$INSTALL_DIR/nginx/fullchain.pem"
    CERTIFICATE_KEY_PATH="$INSTALL_DIR/nginx/privkey.pem"
}

write_env_file() {
    if [ "$HTTPS_ENABLED" = false ]; then
        CERTIFICATE_PATH="$INSTALL_DIR/nginx/empty.pem"
        CERTIFICATE_KEY_PATH="$CERTIFICATE_PATH"
        touch "$CERTIFICATE_PATH"
    fi

    (
        umask 077
        printf 'ENABLE_HTTPS=%s\nXZ_DOMAIN=%s\nNGINX_CONFIG_TEMPLATE=%s\nNGINX_SSL_CERTIFICATE=%s\nNGINX_SSL_CERTIFICATE_KEY=%s\nNGINX_HTTP_PORT=%s\nNGINX_HTTPS_PORT=%s\nNGINX_WS_PORT=%s\nNGINX_WSS_PORT=%s\n' \
            "$HTTPS_ENABLED" "$DOMAIN" "$NGINX_CONFIG_TEMPLATE" "$CERTIFICATE_PATH" "$CERTIFICATE_KEY_PATH" "$HTTP_PORT" "$HTTPS_PORT" "$WS_PORT" "$WSS_PORT" > "$ENV_FILE"
    )
}

fix_macos_permissions() {
    if [ "$PLATFORM" != "Darwin" ] || [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
        return
    fi

    local owner_group
    owner_group="$SUDO_USER:$(id -gn "$SUDO_USER")"
    chown -R "$owner_group" "$INSTALL_DIR"
    chmod 0600 "$ENV_FILE" "$INSTALL_DIR/data/.config.yaml"
    [ ! -f "$INSTALL_DIR/nginx/fullchain.pem" ] || chmod 0600 "$INSTALL_DIR/nginx/fullchain.pem"
    [ ! -f "$INSTALL_DIR/nginx/privkey.pem" ] || chmod 0600 "$INSTALL_DIR/nginx/privkey.pem"
}

configure_manager_api() {
    local secret="$1"
    local config_file="$INSTALL_DIR/data/.config.yaml"
    local temporary_file="${config_file}.tmp"

    if ! awk -v url="http://xiaozhi-esp32-server-web:8002/xiaozhi" -v secret="$secret" '
        /^manager-api:[[:space:]]*$/ { in_manager_api = 1; print; next }
        in_manager_api && /^[^[:space:]#]/ { in_manager_api = 0 }
        in_manager_api && /^[[:space:]]+url:/ { print "  url: " url; found_url = 1; next }
        in_manager_api && /^[[:space:]]+secret:/ { print "  secret: " secret; found_secret = 1; next }
        { print }
        END { if (!found_url || !found_secret) exit 1 }
    ' "$config_file" > "$temporary_file"; then
        rm -f "$temporary_file"
        die "Unable to configure manager-api in $config_file"
    fi
    mv "$temporary_file" "$config_file"
    chmod 0600 "$config_file"
}

wait_for_manager_secret() {
    local attempt
    local secret

    echo "Waiting for manager-api initialization..." >&2
    for ((attempt = 1; attempt <= 90; attempt++)); do
        secret="$(docker exec xiaozhi-esp32-server-db \
            mysql -uroot -p123456 -N -B xiaozhi_esp32_server \
            -e "SELECT param_value FROM sys_params WHERE param_code='server.secret' LIMIT 1" \
            2>/dev/null | tr -d '\r\n')" || true
        if [[ "$secret" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$secret" != "null" ]; then
            printf '%s' "$secret"
            return
        fi
        sleep 2
    done
    die "Timed out waiting for manager-api to generate server.secret"
}

self_test() {
    SETUP_TEST_DIR="$(mktemp -d)"
    trap 'rm -rf "$SETUP_TEST_DIR"' EXIT
    INSTALL_DIR="$SETUP_TEST_DIR"
    mkdir -p "$INSTALL_DIR/data"
    cp "$SCRIPT_DIR/main/xiaozhi-server/config_from_api.yaml" "$INSTALL_DIR/data/.config.yaml"
    configure_manager_api test-secret
    grep -qx '  url: http://xiaozhi-esp32-server-web:8002/xiaozhi' "$INSTALL_DIR/data/.config.yaml"
    grep -qx '  secret: test-secret' "$INSTALL_DIR/data/.config.yaml"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit
fi

configure_https

command -v curl >/dev/null 2>&1 || {
    [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -eq 0 ] || die "Install curl first"
    apt-get update
    apt-get install -y curl
}

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    install_docker
fi
docker info >/dev/null 2>&1 || die "Docker daemon is not running"

mkdir -p \
    "$INSTALL_DIR/data" \
    "$INSTALL_DIR/models/SenseVoiceSmall" \
    "$INSTALL_DIR/nginx" \
    "$INSTALL_DIR/mysql/data" \
    "$INSTALL_DIR/uploadfile"
prepare_certificate_mounts
write_env_file

install_project_file "Docker Compose configuration" "main/xiaozhi-server/docker-compose_all.yml" "$COMPOSE_FILE"
install_project_file "HTTPS Nginx configuration" "main/xiaozhi-server/nginx/default.conf.template" "$INSTALL_DIR/nginx/default.conf.template"
install_project_file "HTTP Nginx configuration" "main/xiaozhi-server/nginx/http.conf.template" "$INSTALL_DIR/nginx/http.conf.template"
install_project_file "Environment variable example" "main/xiaozhi-server/.env.example" "$INSTALL_DIR/.env.example"

if [ ! -f "$INSTALL_DIR/data/.config.yaml" ]; then
    install_project_file "Server configuration" "main/xiaozhi-server/config_from_api.yaml" "$INSTALL_DIR/data/.config.yaml"
fi

if [ ! -f "$INSTALL_DIR/models/SenseVoiceSmall/model.pt" ]; then
    download "SenseVoiceSmall speech recognition model" \
        "https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt" \
        "$INSTALL_DIR/models/SenseVoiceSmall/model.pt"
fi

fix_macos_permissions
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d \
    xiaozhi-esp32-server-db \
    xiaozhi-esp32-server-redis \
    xiaozhi-esp32-server-web
MANAGER_API_SECRET="$(wait_for_manager_secret)"
configure_manager_api "$MANAGER_API_SECRET"
unset MANAGER_API_SECRET
fix_macos_permissions
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d

if [ "$HTTPS_ENABLED" = true ]; then
    DISPLAY_HOST="${DOMAIN:-your-domain}"
    echo "Deployment started: HTTPS https://$DISPLAY_HOST:$HTTPS_PORT/, WebSocket wss://$DISPLAY_HOST:$WSS_PORT/xiaozhi/v1/"
else
    echo "Deployment started: HTTP http://<server-address>:$HTTP_PORT/, WebSocket ws://<server-address>:$WS_PORT/xiaozhi/v1/"
fi
echo "manager-api URL and server.secret were configured automatically."
