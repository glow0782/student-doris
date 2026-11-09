#!/bin/bash
# =============================================================
# 部署 / 重启 DolphinScheduler 3.2.2 Standalone（元数据存外部 MySQL）
#
# 用法：bash /etc/docker/dolphinscheduler/deploy.sh
#
# 本脚本幂等：
#   - MySQL 驱动、建表 SQL 缺失时自动补齐；
#   - 仅当 dolphinscheduler 库表数为 0 时才执行初始化 SQL（该 SQL 含
#     DROP TABLE IF EXISTS，重复执行会清空工作流，务必保留此保护）；
#   - 容器重建不会丢失工作流定义、租户、用户等元数据（都在 MySQL 里）。
# =============================================================
set -u
cd /etc/docker/dolphinscheduler || exit 1

D=/etc/docker/dolphinscheduler
BIN=/opt/dolphinscheduler/bin
IMAGE=apache/dolphinscheduler-standalone-server:3.2.2
DRIVER_DIR=$D/drivers
DRIVER=$DRIVER_DIR/mysql-connector-j-8.0.33.jar
SQL_DIR=$D/sql
SQL=$SQL_DIR/dolphinscheduler_mysql.sql

echo "===== 0. 准备 MySQL JDBC 驱动 ====="
mkdir -p "$DRIVER_DIR" "$SQL_DIR" "$BIN"
if [ ! -s "$DRIVER" ]; then
    URL=https://maven.aliyun.com/repository/public/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar
    curl -fsSL --max-time 150 -o "$DRIVER" "$URL" || { echo "  驱动下载失败"; exit 1; }
fi
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); sys.exit(0 if z.testzip() is None else 1)" "$DRIVER" \
    || { echo "  驱动 jar 校验失败"; exit 1; }
echo "  驱动 OK: $(stat -c %s "$DRIVER") bytes"

echo "===== 0.2 准备官方建表 SQL ====="
if [ ! -s "$SQL" ]; then
    docker run --rm -v "$SQL_DIR:/out" --entrypoint sh "$IMAGE" \
        -c "cp /opt/dolphinscheduler/conf/sql/dolphinscheduler_mysql.sql /out/" \
        || { echo "  从镜像导出 SQL 失败"; exit 1; }
fi
echo "  SQL OK: $(stat -c %s "$SQL") bytes"

echo "===== 0.3 初始化元数据表（仅空库时执行）====="
if ! docker ps --format '{{.Names}}' | grep -qx mysql; then
    echo "  mysql 容器未运行"; exit 1
fi
# 库不存在则先建
docker exec mysql mysql -uroot -p000000 -e \
    "CREATE DATABASE IF NOT EXISTS dolphinscheduler DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
CNT=$(docker exec mysql mysql -uroot -p000000 -N -B -e \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='dolphinscheduler'" 2>/dev/null | tr -d '\r')
echo "  当前表数: $CNT"
if [ "$CNT" = "0" ]; then
    cat "$SQL" | docker exec -i mysql mysql -uroot -p000000 \
        --default-character-set=utf8mb4 dolphinscheduler > /tmp/ds_schema.log 2>&1
    RC=$?
    [ "$RC" -ne 0 ] && { echo "  建表失败，日志："; head -20 /tmp/ds_schema.log; exit 1; }
    echo "  建表完成"
else
    echo "  库已有表，跳过（保护已有工作流数据）"
fi
docker exec mysql mysql -uroot -p000000 -N -B -e \
    "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='dolphinscheduler';" 2>/dev/null | sed 's/^/  表数: /'

echo "===== 1. 启动容器 ====="
docker compose up -d

echo "===== 2. 等待 Web UI 就绪（最多 3 分钟）====="
CODE=000
for i in $(seq 1 36); do
    CODE=$(curl -s -o /dev/null --max-time 5 -w "%{http_code}" \
        http://127.0.0.1:12345/dolphinscheduler/ui 2>/dev/null)
    [ -z "$CODE" ] && CODE=000
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "  第 $i 次探测：HTTP $CODE，已就绪"
        break
    fi
    sleep 5
done
echo "  最终 HTTP=$CODE"

echo "===== 3. 容器状态 / 是否误用 H2 ====="
docker compose ps
echo "  [启动日志中的数据源线索]"
docker logs dolphinscheduler 2>&1 | grep -iE "mysql|h2|jdbc|datasource|Started StandaloneServer" | tail -6 \
    || echo "  (无匹配)"

echo "===== 4. 登录验证 ====="
curl -s --max-time 10 -X POST "http://127.0.0.1:12345/dolphinscheduler/login" \
    -d "userName=admin&userPassword=dolphinscheduler123" 2>/dev/null | head -c 160; echo

echo "===== 5. 网络连通（调度链路）====="
docker exec dolphinscheduler bash -c '
    for hp in mysql:3306 doris-fe:9030 doris-fe:8030 doris-be:8040 172.20.80.3:8040; do
        h=${hp%%:*}; p=${hp##*:}
        timeout 2 bash -c "cat < /dev/null > /dev/tcp/$h/$p" 2>/dev/null \
            && echo "  $hp OK" || echo "  $hp (不可达)"
    done'

echo "===== 6. 调度 SeaTunnel 能力验证 ====="
if docker exec dolphinscheduler docker ps --format '  {{.Names}} {{.Status}}' 2>/dev/null | head -6; then
    echo "  docker CLI 可访问宿主机引擎"
else
    echo "  docker CLI 调用失败，检查 /var/run/docker.sock 挂载"
fi

echo
echo "Web UI : http://<host-ip>:12345/dolphinscheduler/ui"
echo "账号   : admin / dolphinscheduler123"
echo "元数据 : mysql 容器 / dolphinscheduler 库（重启容器不会丢失）"
echo "Shell  : run_seatunnel_job.sh ds_batch_demo.conf"
