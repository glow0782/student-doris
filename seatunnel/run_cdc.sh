#!/usr/bin/env bash
# =============================================================
# 启动「学生管理系统」MySQL-CDC → Doris ODS 常驻同步作业
#
# 用法（在 Docker 宿主机执行）：
#   bash run_cdc.sh           前台运行，Ctrl+C 结束
#   bash run_cdc.sh --bg      后台常驻，日志 /tmp/student_cdc.log
#
# 前置：
#   1. seatunnel、mysql、doris-fe、doris-be 容器已启动；
#   2. student_sync.conf 与本脚本在同一目录（部署时拷到
#      /etc/docker/doris-st/seatunnel/student_sync.conf）；
#   3. MySQL 已创建 CDC 专用账号并授予 PROCESS 权限。
#
# 说明：STREAMING 作业不会自行退出，重复执行只会启动第二个实例，
#       因此脚本在启动前会检查已有进程，避免重复消费 binlog。
# =============================================================
set -u

CONTAINER=seatunnel
NET=doris-st_doris-net
HOST_CONF=/etc/docker/doris-st/seatunnel/student_sync.conf
CONF=/opt/seatunnel/jobs/student_sync.conf
LOG=/tmp/student_cdc.log

echo "===== 1. 检查依赖容器 ====="
for c in seatunnel mysql doris-fe; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
        echo "  容器 $c 未运行，停止启动"; exit 1
    fi
    echo "  $c OK"
done

echo "===== 2. 检查 SeaTunnel 是否接入 BE 网段 ====="
# FE 的 Stream Load 会 307 重定向到 BE 的 8040；容器不在同一网段时，
# 重定向地址不可达，表现为 checkpoint 超时、作业被取消。
if docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONTAINER" | grep -qw "$NET"; then
    echo "  $CONTAINER 已在 $NET"
else
    docker network connect "$NET" "$CONTAINER" && echo "  已接入 $NET" || { echo "  接入失败"; exit 1; }
fi

echo "===== 3. 同步作业配置到容器内 ====="
if [ -f "$HOST_CONF" ]; then
    docker cp "$HOST_CONF" "$CONTAINER:$CONF" >/dev/null && echo "  已拷贝 $HOST_CONF"
else
    echo "  宿主机缺少 $HOST_CONF，请先把 student_sync.conf 放到该路径"; exit 1
fi

echo "===== 4. 检查是否已有同名作业 ====="
RUNNING=$(docker exec "$CONTAINER" sh -c "ps -ef | grep '[s]tudent_sync.conf' | wc -l" 2>/dev/null | tr -d '\r')
if [ "${RUNNING:-0}" -gt 0 ]; then
    echo "  已检测到 $RUNNING 个作业进程，不重复启动"
    echo "  如需重启：docker exec $CONTAINER pkill -f student_sync.conf 后再执行本脚本"
    exit 0
fi

echo "===== 5. 启动 CDC 作业（STREAMING，常驻） ====="
CMD="cd \$SEATUNNEL_HOME && ./bin/seatunnel.sh --config $CONF -m local"

if [ "${1:-}" = "--bg" ]; then
    rm -f "$LOG"
    setsid bash -c "docker exec $CONTAINER sh -c '$CMD' > $LOG 2>&1" \
        < /dev/null > /dev/null 2>&1 &
    sleep 3
    echo "  后台已启动，日志：$LOG"
    echo "  查看进度：tail -f $LOG"
else
    echo "  前台运行，Ctrl+C 结束"
    docker exec -it "$CONTAINER" sh -c "$CMD"
fi
