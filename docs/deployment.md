# 部署与运维手册

本文是根 README「快速开始」的详细版：从一台装好 Docker 的 Linux 主机开始，按顺序把整条链路跑起来，并给出调度配置与排错命令。示例目录布局沿用示例的 `/etc/docker/`，换成自己的路径时，同步修改脚本里的常量即可。

---

## 0. 环境约定

| 项 | 值 |
|---|---|
| 主机 | 单机，约 7 Gi 内存，Docker + Docker Compose v2 |
| 容器名 | `mysql`、`doris-fe`、`doris-be`、`seatunnel`、`dolphinscheduler`、`student-flask`、`student-vue` |
| 网络 | `doris-st`（业务与数据库）、`doris-st_doris-net`（FE/BE 内网）、`dolphinscheduler`（前后端接入） |
| 部署目录 | `/etc/docker/doris-st/`、`/etc/docker/dolphinscheduler/`、`/etc/docker/student-management/` |
| 示例口令 | MySQL root `000000`、Doris root `000000`、CDC 账号 `st_user_source / mysqlpw` |

> 口令均为单机实验环境示例值。正式部署请改用环境变量或密钥管理，并限制数据库账号权限。

---

## 1. 启动基础设施

```bash
mkdir -p /etc/docker/doris-st
cp infra/docker-compose.yaml /etc/docker/doris-st/
cp infra/02_load_and_start.sh /etc/docker/doris-st/
cd /etc/docker/doris-st && bash 02_load_and_start.sh
```

`infra/docker-compose.yaml` 定义 Doris FE、BE 与 SeaTunnel。FE 固定内网 IP `172.20.80.2`、BE 固定 `172.20.80.3`，FE 的 Stream Load 会 307 重定向到 BE，因此 SeaTunnel 必须能访问该网段。

健康检查：

```bash
docker ps --format '{{.Names}} | {{.Status}}'
docker exec mysql mysql -h doris-fe -P 9030 -uroot -p000000 -e "SHOW BACKENDS\G" | grep -E 'Alive|Host'
```

MySQL 容器若已存在则直接复用，不要新建；本项目与之共用实例，额外创建 `dolphinscheduler` 元数据库。

---

## 2. 初始化业务源库

```bash
docker exec -i mysql mysql -uroot -p000000 --default-character-set=utf8mb4 \
  < source-mysql/student_management.sql
docker exec -i mysql mysql -uroot -p000000 --default-character-set=utf8mb4 \
  < source-mysql/student_bulk_data.sql
```

- `student_management.sql` 建库、建 10 张表并导入少量基础数据，脚本可重复执行（按依赖倒序删表后重建）。
- `student_bulk_data.sql` 是 `gen_student_data.py` 生成的约 1 万行批量插入，采用高位 ID 段且开头按段逆序 DELETE，重复导入不会翻倍。
- 需要重新造数时修改 `gen_student_data.py` 顶部的 `CONFIG` 区后运行，它会读取基础 SQL 里已有的主键和业务编号自动避开冲突。

结果核对：

```bash
docker exec mysql mysql -uroot -p000000 -N \
  -e "SELECT COUNT(*) FROM student_management.student;"
```

---

## 3. 配置并启动 CDC

```bash
# 3.1 目标库
docker exec mysql mysql -h doris-fe -P 9030 -uroot -p000000 \
  -e "CREATE DATABASE IF NOT EXISTS student_sync;"

# 3.2 CDC 专用账号与权限
docker exec mysql mysql -uroot -p000000 -e "
  CREATE USER IF NOT EXISTS 'st_user_source'@'%' IDENTIFIED BY 'mysqlpw';
  GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT,
        PROCESS ON *.* TO 'st_user_source'@'%';
  GRANT PROCESS ON *.* TO 'st_user_source'@'%';
  FLUSH PRIVILEGES;"

# 3.3 放置作业配置并启动
mkdir -p /etc/docker/doris-st/seatunnel /etc/docker/doris-st/student-warehouse
cp seatunnel/* /etc/docker/doris-st/seatunnel/
cp warehouse/* /etc/docker/doris-st/student-warehouse/
bash /etc/docker/doris-st/seatunnel/run_cdc.sh --bg
```

`run_cdc.sh` 会自动完成四件事：检查依赖容器、把 SeaTunnel 接入 `doris-st_doris-net`、把配置拷进容器、检查是否已有同名作业，避免重复消费 binlog。

观察同步状态：

```bash
tail -f /tmp/student_cdc.log
docker exec mysql mysql -h doris-fe -P 9030 -uroot -p000000 -N \
  -e "SELECT COUNT(*) FROM student_sync.ods_student;"
```

首次启动为 `initial` 模式，会先做一次全量快照再转入增量。等 `ods_student` 与源表行数一致后再往下走。

---

## 4. 首次分层

```bash
bash /etc/docker/doris-st/student-warehouse/run_layers.sh
```

脚本会建 DWD / DWS / ADS 共 9 张表、逐层 `TRUNCATE` 后灌数，最后打印行数验收与抽样数据。单 BE 环境下所有表都显式声明 `PROPERTIES("replication_num"="1")`。

预期输出中应能看到 9 张表行数，以及学院画像、班级排行、预警名单的抽样结果。指标口径见 [`architecture.md`](architecture.md)。

---

## 5. 部署 DolphinScheduler

```bash
mkdir -p /etc/docker/dolphinscheduler
cp dolphinscheduler/* /etc/docker/dolphinscheduler/
bash /etc/docker/dolphinscheduler/deploy.sh
```

`deploy.sh` 会自动下载 MySQL JDBC 驱动、从镜像导出官方建表 SQL，并且**只在元数据库为空时**执行初始化。UI 地址与账号：

```
http://<host-ip>:12345/dolphinscheduler/ui
admin / dolphinscheduler123
```

在 UI 里建两个 Shell 工作流：

| 工作流 | Shell 任务内容 | 建议调度 |
|---|---|---|
| 分层重跑 | `bash /etc/docker/doris-st/student-warehouse/run_layers.sh` | 每 5 分钟，或按需手动触发 |
| CDC 常驻检查 | `ST_BACKGROUND=1 /opt/dolphinscheduler/bin/run_seatunnel_job.sh student_sync.conf` | 只执行一次，让作业常驻 |

`run_seatunnel_job.sh` 利用 DS 容器挂载的 `docker.sock` 与静态 docker CLI，在 DS 任务里 `docker exec` 进 SeaTunnel 容器执行作业，DS 侧无需安装 SeaTunnel。`ds_batch_demo.conf` 是一个 FakeSource → Console 的批处理冒烟作业，适合先验证调度链路是否打通。

> `STREAMING` 作业不该被定时反复触发，它启动一次后常驻即可；需要定时重跑的是分层脚本。

---

## 6. 部署前后端应用

```bash
mkdir -p /etc/docker/student-management
cp -r webapp/* /etc/docker/student-management/
bash /etc/docker/student-management/deploy.sh
```

`deploy.sh` 不建库、不建表，只做只读链路校验（4 张已有表的行数、CDC 进程数）、重建网络、构建镜像、等待就绪并打印接口冒烟结果，重复执行安全。

验证：

```bash
curl http://127.0.0.1:8000/api/health
curl http://127.0.0.1:8000/api/chart/gender
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/
```

健康检查应显示 `mysql_db=student_management`、`doris_db=student_sync`。

---

## 7. 排错清单

| 检查点 | 命令 |
|---|---|
| 容器状态 | `docker ps -a --format '{{.Names}} \| {{.Status}}'` |
| 容器网络归属 | `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' seatunnel` |
| CDC 作业日志 | `tail -n 100 /tmp/student_cdc.log` |
| SeaTunnel 旧日志 | `docker exec seatunnel tail -n 100 /tmp/seatunnel_ds.log` |
| Doris BE 存活 | `mysql -h doris-fe -P 9030 -uroot -p000000 -e "SHOW BACKENDS\G"` |
| 分层表行数 | `bash /etc/docker/doris-st/student-warehouse/run_layers.sh`（会重跑，幂等） |
| DS 启动日志 | `docker logs --tail 100 dolphinscheduler` |
| 前后端日志 | `docker compose -f /etc/docker/student-management/docker-compose.yml logs -f` |
| 安全组 | 云主机控制台放行 8081 / 8000 / 12345 / 9030 |

常见故障与原因见根 README 的「常见问题」，以及 [`architecture.md`](architecture.md) 的踩坑记录。

---

## 8. 重建与清理

- 重建前后端容器：`bash /etc/docker/student-management/deploy.sh`，不会清空任何业务数据。
- 重建 DS 容器：元数据在外部 MySQL，工作流定义不会丢；**不要**手动重跑 `dolphinscheduler_mysql.sql`，该脚本含 `DROP TABLE IF EXISTS`。
- 需要重置演示数据时，按第 2 步重新导入两个 SQL；随后 CDC 会把变更同步到 ODS，再跑一次分层即可。
- 重新生成批量数据：修改 `source-mysql/gen_student_data.py` 的 `CONFIG` 后运行，覆盖 `student_bulk_data.sql`。
