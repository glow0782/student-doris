#!/bin/bash
# =============================================================
# DolphinScheduler Shell 任务脚本：调度 SeaTunnel 作业
#
# 原理：DS 容器挂了宿主机 /var/run/docker.sock + 静态 docker CLI，
#       因此可以在 DS 的 Shell 任务里 docker exec 进 seatunnel 容器执行作业。
#       作业配置和 connector 都在 seatunnel 容器内，DS 侧不需要安装 SeaTunnel。
#
# 用法（在 DolphinScheduler 的 Shell 任务中直接写）：
#   run_seatunnel_job.sh ds_batch_demo.conf                # 自动选模式，前台运行
#   run_seatunnel_job.sh ds_batch_demo.conf cluster 180    # 显式指定模式 + 超时
#   ST_CHECK=1 run_seatunnel_job.sh mysql2doris.conf       # 只校验配置，不真正跑
#   ST_BACKGROUND=1 run_seatunnel_job.sh mysql2doris.conf  # 后台启动，DS 任务立即返回
#
# 参数：
#   $1 配置名（相对 /opt/seatunnel/jobs/）或容器内绝对路径
#   $2 运行模式 local / cluster；不填则自动判断：
#      seatunnel 容器内 5801 已有常驻 SeaTunnelServer 时用 cluster 复用它，
#      否则用 local 自己起一个。避免两个 server 抢 8080 导致 Address already in use。
#   $3 超时秒数，0 表示不限时（也可用环境变量 ST_TIMEOUT）
#
# 注意 1：seatunnel 容器的 /opt/seatunnel/jobs 是匿名卷，宿主机同名目录并未挂进去。
#         作业配置由 deploy.sh 用 docker cp 同步进容器；容器重建后需重跑 deploy.sh。
# 注意 2：STREAMING（CDC）作业常驻不退出，会让 DS 任务一直挂着，
#         这类作业请用 ST_BACKGROUND=1，或给 $3 设一个超时。
# =============================================================
set -u

CONF="${1:-}"
MODE="${2:-${ST_MODE:-}}"
TIMEOUT="${3:-${ST_TIMEOUT:-0}}"
CONTAINER="${ST_CONTAINER:-seatunnel}"
JOBS_DIR="${ST_JOBS_DIR:-/opt/seatunnel/jobs}"

if [ -z "$CONF" ]; then
    echo "[DS] 用法: run_seatunnel_job.sh <conf> [local|cluster] [timeout_seconds]"
    exit 2
fi

if [ -z "$MODE" ]; then
    if docker exec "$CONTAINER" bash -c \
        'timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/5801"' >/dev/null 2>&1; then
        MODE=cluster
        echo "[DS] 检测到已有 SeaTunnelServer(5801)，自动使用 cluster 模式"
    else
        MODE=local
        echo "[DS] 未检测到 SeaTunnelServer，自动使用 local 模式"
    fi
fi

case "$CONF" in
    /*) CFG="$CONF" ;;
    *)  CFG="$JOBS_DIR/$CONF" ;;
esac

CHECK_FLAG=""
[ "${ST_CHECK:-0}" = "1" ] && CHECK_FLAG=" --check"

# 在 seatunnel 容器内展开 $SEATUNNEL_HOME
CMD="cd \$SEATUNNEL_HOME && ./bin/seatunnel.sh --config \"$CFG\" -m $MODE$CHECK_FLAG"

echo "[DS] container=$CONTAINER config=$CFG mode=$MODE check=${ST_CHECK:-0} timeout=$TIMEOUT"

if [ "${ST_BACKGROUND:-0}" = "1" ]; then
    # 常驻作业：后台启动，日志写到容器内 /tmp/seatunnel_ds.log
    docker exec -d "$CONTAINER" sh -c "$CMD > /tmp/seatunnel_ds.log 2>&1" \
        || { echo "[DS] 后台启动失败"; exit 1; }
    echo "[DS] 已后台启动，日志: $CONTAINER:/tmp/seatunnel_ds.log"
    exit 0
fi

if [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
    exec timeout "$TIMEOUT" docker exec "$CONTAINER" sh -c "$CMD"
else
    exec docker exec "$CONTAINER" sh -c "$CMD"
fi
