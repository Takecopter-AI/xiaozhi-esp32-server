#!/bin/sh
# 小智服务端启停脚本：up/start/run | down/stop | restart
# 指定部署目录：COMPOSE_FILE=/path/to/docker-compose_all.yml ./xz.sh up

if [ -z "$COMPOSE_FILE" ]; then
    for d in "$HOME/.xiaozhi-server" /opt/xiaozhi-server; do
        if [ -f "$d/docker-compose_all.yml" ]; then
            COMPOSE_FILE="$d/docker-compose_all.yml"
            break
        fi
    done
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "未找到已部署的 docker-compose_all.yml，请用 COMPOSE_FILE 指定" >&2
    exit 1
fi

echo "使用配置：$COMPOSE_FILE"
case "$1" in
    up|start|run) docker compose -f "$COMPOSE_FILE" up -d ;;
    down|stop)    docker compose -f "$COMPOSE_FILE" down ;;
    restart)      docker compose -f "$COMPOSE_FILE" restart ;;
    *)
        echo "用法: $0 {up|start|run | down|stop | restart}" >&2
        exit 1
        ;;
esac
