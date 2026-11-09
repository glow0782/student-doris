# DolphinScheduler 部署说明

本目录负责整条链路的**调度层**：定时重跑 Doris 分层脚本，以及按需触发 SeaTunnel 作业。

## 为什么是 Standalone + 外部 MySQL

Standalone 版默认把工作流定义、租户、用户、Quartz 调度状态存在内置 H2 里，容器一重建就全部丢失。把元数据源换成同机的 MySQL 后，重启容器不再丢数据，而且只需要 1 个容器、1 个 JVM。

集群版当然也能解决这个问题，但 3.2.2 需要 ZooKeeper 做注册中心、`dolphinscheduler-tools` 初始化 schema、统一 `.env`，还要给 master / worker / api / alert 四个 JVM 分别限堆。在 7 Gi 的单机上，与 Doris 抢内存极易触发 OOM，得不偿失。

## 文件说明

| 文件 | 作用 |
|---|---|
| `docker-compose.yaml` | Standalone 容器定义，含数据源环境变量、驱动与共享卷挂载 |
| `deploy.sh` | 幂等部署：准备基础镜像与驱动、空库才初始化、启动并验证登录 |
| `run_seatunnel_job.sh` | DS Shell 任务脚本，通过 `docker.sock` 在 SeaTunnel 容器内执行作业 |
| `ds_batch_demo.conf` | FakeSource → Console 的批处理冒烟作业，用于验证调度链路 |

## 两个不入库的外部依赖

`deploy.sh` 会在首次运行时自动补齐，无需手动下载，仓库里不保存它们：

1. **MySQL JDBC 驱动** `mysql-connector-j-8.0.33.jar`（约 2.4 MB）。官方 Standalone 镜像只内置 H2 驱动，从阿里云 Maven 仓库下载后挂到容器内 `/opt/dolphinscheduler/libs/ext`；`start.sh` 会自动把该子目录加入 classpath。
2. **官方建表脚本** `dolphinscheduler_mysql.sql`（约 128 KB，67 张表，含初始 admin 账号）。从镜像的 `/opt/dolphinscheduler/conf/sql/` 导出到宿主机 `sql/` 目录。

这两项都是第三方二进制或官方发行物，体积大且不属于本项目代码，因此只保留获取逻辑，不纳入版本管理。

## 部署

```bash
mkdir -p /etc/docker/dolphinscheduler
cp dolphinscheduler/* /etc/docker/dolphinscheduler/
bash /etc/docker/dolphinscheduler/deploy.sh
```

部署完成后访问 `http://<host-ip>:12345/dolphinscheduler/ui`，默认账号 `admin / dolphinscheduler123`。

## 关键环境变量

`docker-compose.yaml` 用 Spring Boot 的环境变量覆盖镜像里硬编码的 H2 数据源：

| 变量 | 值 |
|---|---|
| `DATABASE` | `mysql` |
| `SPRING_DATASOURCE_DRIVER_CLASS_NAME` | `com.mysql.cj.jdbc.Driver` |
| `SPRING_DATASOURCE_URL` | `jdbc:mysql://mysql:3306/dolphinscheduler?...` |
| `SPRING_DATASOURCE_USERNAME` / `PASSWORD` | `root` / 示例口令 |
| `SPRING_SQL_INIT_MODE` | `never`（禁止启动时的 H2 建表脚本） |

## 注意事项

- 官方 `dolphinscheduler_mysql.sql` 含 `DROP TABLE IF EXISTS`。`deploy.sh` 只在 `dolphinscheduler` 库表数为 0 时才导入，重复执行不会清空已有工作流，请勿绕过这个保护手动重跑。
- 判断是否真的连上了 MySQL，可查 `QRTZ_SCHEDULER_STATE`：DS 启动后会写入调度器实例记录，H2 模式下的 MySQL 表里不会有这行数据。
- `STREAMING` 类型的 CDC 作业用 `ST_BACKGROUND=1` 启动一次并常驻；需要定时重复执行的是分层脚本，不是 CDC 作业。
- 容器重建后工作流定义保留在 MySQL，但云平台安全组需放行 12345 才能从本机访问 UI。
