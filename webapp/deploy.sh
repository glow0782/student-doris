#!/bin/bash
# =============================================================
# 学生管理系统 一键部署（在 Docker 宿主机执行）
# 用法：bash /etc/docker/student-management/deploy.sh
#
# 重要：本项目不新建、不修改任何库表。
#   CRUD  -> MySQL  student_management.student / classes      （已有数仓源表）
#   图表  -> Doris  student_sync.dwd_dim_student             （已有 DWD 层）
#            Doris  student_sync.ads_college_dashboard        （已有 ADS 层）
# 链路：MySQL --SeaTunnel CDC--> ods_student --DS 分层--> DWD/ADS --> 大屏
#
# 幂等：只校验链路、构建并重启业务容器，重复执行不会写入任何数据。
# =============================================================
set -u
cd "$(dirname "$0")" || exit 1

MYSQL_CLI="docker exec mysql mysql -uroot -p000000 --default-character-set=utf8mb4 -N -B"
DORIS_CLI="docker exec mysql mysql -h doris-fe -P 9030 -uroot -p000000 --default-character-set=utf8mb4 -N -B"

echo "===== 1. 检查依赖容器 ====="
for c in mysql doris-fe; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
        echo "  容器 $c 未运行，停止部署"; exit 1
    fi
    echo "  $c OK"
done

echo "===== 2. 准备 dolphinscheduler 网络并接通已有数据库容器 ====="
if ! docker network inspect dolphinscheduler >/dev/null 2>&1; then
    docker network create dolphinscheduler >/dev/null && echo "  已创建网络 dolphinscheduler"
else
    echo "  网络 dolphinscheduler 已存在"
fi
for c in mysql doris-fe; do
    if docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" | grep -qw dolphinscheduler; then
        echo "  $c 已在网络中"
    else
        docker network connect dolphinscheduler "$c" 2>/dev/null && echo "  $c 已接入" || echo "  $c 接入失败（请检查）"
    fi
done

echo "===== 3. 准备 Python 基础镜像 ====="
if ! docker image inspect python:3.11-slim >/dev/null 2>&1; then
    docker pull docker.m.daocloud.io/library/python:3.11-slim >/dev/null 2>&1 \
        || { echo "  python 镜像拉取失败"; exit 1; }
    docker tag docker.m.daocloud.io/library/python:3.11-slim python:3.11-slim
    echo "  已准备 python:3.11-slim"
else
    echo "  python:3.11-slim 已存在"
fi

echo "===== 4. 校验已有链路（只读，不建库不建表）====="
M_STU=$($MYSQL_CLI -e "SELECT COUNT(*) FROM student_management.student;" 2>/dev/null | tr -d '\r')
M_CLS=$($MYSQL_CLI -e "SELECT COUNT(*) FROM student_management.classes;" 2>/dev/null | tr -d '\r')
D_DWD=$($DORIS_CLI -e "SELECT COUNT(*) FROM student_sync.dwd_dim_student;" 2>/dev/null | tr -d '\r')
D_ADS=$($DORIS_CLI -e "SELECT COUNT(*) FROM student_sync.ads_college_dashboard;" 2>/dev/null | tr -d '\r')
if [ -z "$M_STU" ] || [ -z "$M_CLS" ] || [ -z "$D_DWD" ] || [ -z "$D_ADS" ]; then
    echo "  链路校验失败：缺少已有库表，停止部署。请确认 student_management / student_sync 存在。"
    exit 1
fi
echo "  MySQL  student_management.student = $M_STU 人，classes = $M_CLS 个班"
echo "  Doris  student_sync.dwd_dim_student = $D_DWD，ads_college_dashboard = $D_ADS 行"
LEGACY_M=$($MYSQL_CLI -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='student_db';" 2>/dev/null | tr -d '\r')
LEGACY_D=$($DORIS_CLI -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='doris_test';" 2>/dev/null | tr -d '\r')
if [ "$LEGACY_M" != "0" ] || [ "$LEGACY_D" != "0" ]; then
    echo "  提示：检测到本链路未使用的历史库 student_db / doris_test，可按需清理"
fi
CDC=$(docker exec seatunnel sh -c "ps -ef | grep '[s]eatunnel' | wc -l" 2>/dev/null | tr -d '\r')
echo "  SeaTunnel CDC 进程数 = ${CDC:-0}（>0 表示 binlog 同步在跑）"

echo "===== 5. 构建并启动 Flask + Vue 容器 ====="
docker compose up -d --build || { echo "  启动失败"; exit 1; }

echo "===== 6. 等待服务就绪 ====="
CODE=000
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null --max-time 5 -w "%{http_code}" http://127.0.0.1:8000/api/health 2>/dev/null)
    [ -z "$CODE" ] && CODE=000
    [ "$CODE" = "200" ] && { echo "  Flask 就绪（第 $i 次探测）"; break; }
    sleep 4
done
echo "  Flask /api/health -> $CODE"
VUE=000
for i in $(seq 1 20); do
    VUE=$(curl -s -o /dev/null --max-time 5 -w "%{http_code}" http://127.0.0.1:8081/ 2>/dev/null)
    [ -z "$VUE" ] && VUE=000
    [ "$VUE" = "200" ] && { echo "  Vue 就绪（第 $i 次探测）"; break; }
    sleep 3
done
echo "  Vue 首页 -> $VUE"

echo "===== 7. 接口冒烟 ====="
echo "  [健康检查]"; curl -s --max-time 10 http://127.0.0.1:8000/api/health | head -c 260; echo
echo "  [班级维表]"; curl -s --max-time 10 http://127.0.0.1:8000/api/student/classes | head -c 160; echo
echo "  [学生列表]"; curl -s --max-time 10 "http://127.0.0.1:8000/api/student/list?size=1" | head -c 230; echo
echo "  [各班人数]"; curl -s --max-time 10 http://127.0.0.1:8000/api/chart/class | head -c 200; echo
echo "  [性别分布]"; curl -s --max-time 10 http://127.0.0.1:8000/api/chart/gender | head -c 200; echo

echo
echo "============================================================="
echo "访问：学生管理  http://<host-ip>:8081/            "
echo "      数据大屏  http://<host-ip>:8081/dashboard.html"
echo "      后端接口  http://<host-ip>:8000/api/health   "
echo "（云平台安全组需放行 8081、8000）"
echo "============================================================="
