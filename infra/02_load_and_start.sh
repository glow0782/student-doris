#!/usr/bin/env bash
# =============================================================
# 02_load_and_start.sh —— 在 Docker 宿主机（root）上执行
# 作用：① 起 MySQL 源库（幂等）② 导入 Doris 镜像 + 构建/检查 SeaTunnel 本地镜像
#       ③ 按 FE 先行 / BE 后起的顺序拉起全部服务 ④ 健康检查
# 用法：cd /etc/docker/doris-st && chmod +x 02_load_and_start.sh && ./02_load_and_start.sh
#
# 说明：脚本可重复运行。若 3 个 .tar 尚未上传，会先把 MySQL 起好，
#       然后给出明确提示并正常退出；tar 到位后重跑即完成剩余步骤。
# =============================================================
set -euo pipefail

FE_IP="172.20.80.2"
BE_IP="172.20.80.3"
FE_VER="apache/doris:fe-2.1.9"

cd "$(dirname "$0")"

echo "===== 0. 环境检查 ====="
command -v docker >/dev/null || { echo "未安装 docker"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "缺少 docker compose 插件（需 v2）"; exit 1; }
free -h | head -2
df -h / | tail -1
echo "-- 网段冲突检查 --"; ip route | grep -E "172\.20\.80" || echo "  无冲突"

echo
echo "===== 1. 启动 MySQL 源库（gmall，含 3 天数据）====="
mkdir -p mysql-init /opt/seatunnel/jobs
if [ ! -s mysql-init/gmall.sql ]; then
    echo "警告：mysql-init/gmall.sql 不存在，MySQL 容器将是空库，请先上传 dump 文件。"
fi
docker compose up -d gmall-mysql

echo "-- 等待 MySQL 就绪并导入初始数据（最多 5 分钟）--"
MYSQL_READY=0
for i in $(seq 1 60); do
    if docker exec gmall-mysql mysql -uroot -p000000 -N \
        -e "SELECT COUNT(*) FROM gmall.order_info" >/tmp/gmall_rows 2>/dev/null; then
        echo "MySQL ready，order_info 行数 = $(cat /tmp/gmall_rows)（第 ${i} 次探测）"
        MYSQL_READY=1; break
    fi
    sleep 5
done
if [ "$MYSQL_READY" -ne 1 ]; then
    echo "MySQL 未就绪，查看日志：docker logs gmall-mysql"; docker logs --tail 40 gmall-mysql; exit 1
fi

echo
echo "===== 2. 检查 Doris 离线镜像 ====="
declare -A IMG=(
    [doris-fe.tar]="apache/doris:fe-2.1.9"
    [doris-be.tar]="apache/doris:be-2.1.9"
)
FILES=(doris-fe.tar doris-be.tar)
MISSING=0
for f in "${FILES[@]}"; do
    if docker image inspect "${IMG[$f]}" >/dev/null 2>&1; then
        echo "  已导入，跳过: ${IMG[$f]}"
    elif [ ! -s "$f" ]; then
        echo "  缺少: $f"; MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    echo
    echo "------------------------------------------------------------"
    echo "MySQL 源库已就绪，但 Doris 镜像 tar 还没到位，Doris 部分暂未启动。"
    echo "把 doris-fe.tar / doris-be.tar 放到本目录后重新执行本脚本。"
    echo "------------------------------------------------------------"
    docker compose ps
    exit 0
fi

echo "===== 3. 导入镜像（导入成功即删 tar，避免撑爆磁盘）====="
df -h / | tail -1
for f in "${FILES[@]}"; do
    img="${IMG[$f]}"
    if docker image inspect "$img" >/dev/null 2>&1; then
        echo ">> 已存在 $img，跳过"; [ -f "$f" ] && rm -f "$f"; continue
    fi
    if [ ! -s "$f" ]; then echo ">> 跳过 $f（文件缺失）"; continue; fi
    echo ">> docker load -i $f"
    docker load -i "$f" || { echo "LOAD_FAIL $f"; exit 1; }
    rm -f "$f" && echo "   已删除 $f 释放空间"
    df -h / | tail -1
done
docker images | grep -E "apache/doris" || { echo "镜像导入异常"; exit 1; }

echo
echo "===== 3.5 检查 / 构建 SeaTunnel 本地镜像 ====="
# 官方 apache/seatunnel:2.3.9 镜像 5.76GB 大层国内源缺失，
# 改用官方发行包 + JDK17 自建 seatunnel-local:2.3.9（见 seatunnel-image/）。
ST_IMG=seatunnel-local:2.3.9
if docker image inspect "$ST_IMG" >/dev/null 2>&1; then
    echo "  已有 $ST_IMG"
elif [ -f /opt/seatunnel/build/build_image.sh ]; then
    echo "  未找到 $ST_IMG，调用 build_image.sh 从发行包构建"
    bash /opt/seatunnel/build/build_image.sh || echo "  构建失败，SeaTunnel 容器将跳过"
else
    echo "  未找到 $ST_IMG，且无 /opt/seatunnel/build/build_image.sh，SeaTunnel 容器将跳过（不影响 Doris 主链路）"
fi

echo
echo "===== 4. 核对镜像内 DORIS_HOME（compose 挂载路径）====="
docker run --rm --entrypoint /bin/sh "$FE_VER" \
    -c 'echo DORIS_HOME=$DORIS_HOME; ls -d /opt/*/fe/doris-meta 2>/dev/null || true' 2>/dev/null || true
echo "若与 docker-compose.yaml 的 volumes 不一致，请先修改 compose。"

echo
echo "===== 5. 启动 FE，按内存收紧 JVM 后等待就绪 ====="
docker compose up -d doris-fe
# 镜像默认 -Xmx8192m，在 <8G 内存的机器上导入数据会被 OOM killer 杀掉
TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
CHANGED=0
if [ "$TOTAL_MB" -lt 8192 ]; then
    echo "检测到内存 ${TOTAL_MB}MB，将 FE 堆设为 1024m、BE mem_limit 30%"
    docker exec doris-fe sh -c "sed -i 's/-Xmx8192m/-Xmx1024m/g; s/-Xms8192m/-Xms1024m/g' /opt/apache-doris/fe/conf/fe.conf" && CHANGED=1
    docker exec doris-be sh -c "grep -q '^mem_limit' /opt/apache-doris/be/conf/be.conf || echo 'mem_limit = 30%' >> /opt/apache-doris/be/conf/be.conf" 2>/dev/null || true
else
    echo "内存 ${TOTAL_MB}MB 充足，保留镜像默认 JVM 参数"
fi
if [ "$CHANGED" -eq 1 ]; then
    docker restart doris-fe >/dev/null 2>&1 || true
fi
FE_READY=0
for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:8030/api/bootstrap" >/dev/null 2>&1; then
        echo "FE ready（第 ${i} 次探测）"; FE_READY=1; break
    fi
    sleep 5
done
if [ "$FE_READY" -ne 1 ]; then
    echo "FE 未就绪：docker logs doris-fe"; docker logs --tail 50 doris-fe; exit 1
fi

echo
echo "===== 6. 启动 BE + SeaTunnel（SeaTunnel 可选）====="
docker compose up -d doris-be
if docker image inspect "seatunnel-local:2.3.9" >/dev/null 2>&1; then
    docker compose up -d seatunnel
    echo "SeaTunnel 容器已启动（镜像 seatunnel-local:2.3.9）"
else
    echo "SeaTunnel 本地镜像未就位，跳过其容器；Doris FE/BE 不受影响"
fi

echo
echo "===== 7. 检查 / 注册 BE ====="
sleep 15
MYSQL_CMD=""
if command -v mysql >/dev/null 2>&1; then
    MYSQL_CMD="mysql -h127.0.0.1 -P9030 -uroot -N -e"
elif docker exec doris-fe sh -c 'command -v mysql' >/dev/null 2>&1; then
    MYSQL_CMD="docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -N -e"
fi
if [ -n "$MYSQL_CMD" ]; then
    $MYSQL_CMD "SHOW BACKENDS;" 2>/dev/null || true
    if [ "$($MYSQL_CMD 'SHOW BACKENDS;' 2>/dev/null | wc -l)" -eq 0 ]; then
        echo ">> BACKENDS 为空，自动注册"; $MYSQL_CMD "ALTER SYSTEM ADD BACKEND '${BE_IP}:9050';" 2>/dev/null || true
    fi
else
    echo "手动检查/注册："
    echo "  docker exec -it doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS;'"
    echo "  docker exec -it doris-fe mysql -h127.0.0.1 -P9030 -uroot -e \"ALTER SYSTEM ADD BACKEND '${BE_IP}:9050';\""
fi

echo
echo "===== 8. 容器状态 ====="
docker compose ps

echo
echo "===== 完成，验收清单 ====="
echo "1) FE Web UI  http://<host-ip>:8030   （安全组需放行 8030/9030）"
echo "2) DBeaver   <host-ip>:9030 / root / 000000"
echo "3) 确认 BE Alive=true、在 Doris 建好 gmall 库表后执行同步："
echo "     docker exec seatunnel sh -c 'cd \$SEATUNNEL_HOME && ./bin/seatunnel.sh --config /opt/seatunnel/jobs/mysql_to_ods.conf -m local'"
echo "     或一键跑完整链路：bash /opt/seatunnel/jobs/run_pipeline.sh"
