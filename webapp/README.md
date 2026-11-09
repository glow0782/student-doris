# 应用子系统：Vue3 + ECharts + Flask

> 本文是仓库 `webapp/` 目录的说明。完整的项目架构、部署顺序与分层设计见 [根 README](../README.md)，数仓建表与灌数见 [`warehouse/`](../warehouse/)，实时同步配置见 [`seatunnel/`](../seatunnel/)。

> **本子系统不新建、不修改任何数据库与数据表。** 管理页直接读写已有的业务源表 `student_management.student`，大屏直接读取已有的分层表 `student_sync.dwd_dim_student` 与 `student_sync.ads_college_dashboard`。部署脚本只做只读链路校验，不写入业务数据。

## 一、架构与完整数据链路

```
浏览器  Vue3 管理页 / ECharts 大屏（8081，同源 /api 由 nginx 反代）
   │                                    ▲
   │ /api/student/*                     │ /api/chart/*
   ▼                                    │
Flask 容器 student-flask:8000 ──────────┘
   │ 写                                  │ 读
   ▼                                    │
MySQL mysql:3306                        │
  student_management.student            │
  student_management.classes            │
   │                                    │
   │ binlog：SeaTunnel CDC 作业          │
   │ /opt/seatunnel/jobs/student_sync.conf（STREAMING）
   ▼                                    │
Doris doris-fe:9030                     │
  student_sync.ods_student              │
   │                                    │
   │ DolphinScheduler 定时执行分层脚本     │
   │ /etc/docker/doris-st/student-warehouse/run_layers.sh
   ▼                                    │
  student_sync.dwd_dim_student ─────────┘  /api/chart/class  各班人数
  student_sync.ads_college_dashboard ───┘  /api/chart/gender 性别分布
```

| 环节 | 使用的库表 | 来源 |
|---|---|---|
| 学生 CRUD | `student_management.student` | 已有数仓源表，812 人 |
| 班级下拉 | `student_management.classes` | 已有维表，38 个班 |
| CDC 贴源 | `student_sync.ods_student` | SeaTunnel 实时同步 |
| 班级人数图 | `student_sync.dwd_dim_student` | 已有 DWD 明细宽表（班级名已维度退化） |
| 性别占比图 | `student_sync.ads_college_dashboard` | **已有 ADS 应用层**，按学院 male_cnt / female_cnt 上卷到全校 |

**关于 ADS 层**：原有三张 ADS 表是「学院画像 / 班级成绩排行 / 学生预警」，没有「各班人数」这个口径，且本项目不新建表，因此班级图从已有的 DWD 明细层聚合；性别图则真正落在 ADS 层。两张表的统计总数应一致（均为 `dwd_dim_student` 的学生数），可交叉校验。

链路是自动的：管理页新增学生 → binlog 被 CDC 捕获 → `ods_student` 增加 → DS 定时重跑分层 → DWD/ADS 更新 → 大屏点「刷新数据」看到变化。无需手工导数据。

## 二、目录结构

```
student-management/
├── docker-compose.yml          # Flask + Vue 两个服务；无数据库服务
├── deploy.sh                  # 一键部署：只校验链路 + 构建重启，不建库表
├── backend/
│   ├── app.py                 # /api/student/* CRUD + /api/chart/* Doris 统计
│   ├── requirements.txt       # flask / flask-cors / pymysql
│   └── Dockerfile             # python:3.11-slim + 清华 PyPI 源
└── frontend/
    ├── index.html             # 学生管理页（分页表格 / 班级下拉 / 新增 / 编辑 / 删除）
    ├── dashboard.html         # 数据大屏（柱状图 + 饼图 + 刷新按钮 + 30 秒自动刷新）
    ├── css/style.css
    ├── js/api.js              # axios 统一封装（拦截器拆 data 外壳）
    ├── js/manage.js           # 管理页 Vue3 逻辑
    ├── js/dashboard.js        # 大屏 Vue3 + ECharts 逻辑（38 个班用 dataZoom 滑块）
    ├── nginx.conf             # /api/ 反代到 flask:8000
    ├── Dockerfile             # nginx:latest 托管静态资源
    └── vendor/                # 本地 UMD 依赖，离线可用，无需 npm 构建
        ├── vue.global.prod.js # Vue 3.4.38
        ├── axios.min.js       # axios 1.7.7
        └── echarts.min.js     # ECharts 5.5.1
```

依赖版本：Python 3.11 / Flask 3.0.3 / flask-cors 4.0.1 / PyMySQL 1.1.1 / Vue 3.4.38 / axios 1.7.7 / ECharts 5.5.1 / nginx:latest。

## 三、端口规划

| 服务 | 容器 | 宿主机端口 | 说明 |
|---|---|---|---|
| Flask | `student-flask` | **8000** | REST API，开启 CORS |
| Vue | `student-vue` | **8081** → 容器 80 | 静态页面 + `/api` 反代 |

浏览器只需访问 8081（页面内 `/api` 由 nginx 转发）；8000 供直接调试接口。**云平台安全组或防火墙需放行 8081 与 8000。**

## 四、启动命令

示例部署目录为 `/etc/docker/student-management/`：

```bash
# 一键部署（幂等，可重复执行；不写入任何业务数据）
bash /etc/docker/student-management/deploy.sh

# 或手动分步
cd /etc/docker/student-management
docker network create dolphinscheduler                 # 若不存在
docker network connect dolphinscheduler mysql
docker network connect dolphinscheduler doris-fe
docker compose up -d --build

# 查看 / 停止
docker compose ps
docker compose logs -f flask
docker compose down
```

`deploy.sh` 会：检查 `mysql`/`doris-fe` 容器、准备并接通网络、准备 `python:3.11-slim` 基础镜像、**只读校验**已有库表行数与 CDC 进程、构建启动容器、等待就绪、打印接口冒烟结果。

前置条件（均由既有环境提供，本项目不负责创建）：

```bash
# MySQL 源库与 Doris 分层库应已存在
docker exec mysql mysql -uroot -p000000 -e "SELECT COUNT(*) FROM student_management.student;"
docker exec mysql mysql -h doris-fe -P 9030 -uroot -p000000 -e "SELECT COUNT(*) FROM student_sync.ods_student;"

# SeaTunnel CDC 作业应在运行
docker exec seatunnel sh -c "ps -ef | grep '[s]eatunnel'"

# 分层脚本（由 DolphinScheduler 定时调度，也可手动重跑）
bash /etc/docker/doris-st/student-warehouse/run_layers.sh
```

## 五、源表字段与适配说明

`student_management.student` 是已有业务表，共 17 个字段。后端只使用其中的白名单字段，不改表结构：

| 字段 | 类型 | 约束 | 管理页 |
|---|---|---|---|
| `student_id` | bigint unsigned | 主键、自增 | 隐藏，作记录 id |
| `student_no` | varchar(20) | 非空、唯一 | 必填，新增/编辑均可修改（改成已存在的学号会报唯一键冲突） |
| `name` | varchar(30) | 非空 | 必填 |
| `gender` | char(1) | 非空 | 男 / 女 下拉 |
| `class_id` | int unsigned | 非空、外键→`classes.class_id` | 班级下拉（38 个班） |
| `enroll_date` | date | **非空、无默认值** | 必填，新增默认今天 |
| `status` | varchar(10) | 非空，默认「在读」 | 在读 / 休学 / 毕业 / 退学 |
| `phone` / `email` | varchar | 可空 | 选填 |
| `birth_date` / `id_card` 等 | — | 可空 | 后端白名单支持，页面未展开 |

要点：

- `class_id` 有外键，新增/修改前后端会先校验班级存在，避免报 1452 外键错；页面用下拉而非自由输入。
- `enrollment.student_id` 外键规则是 **CASCADE**：删除学生会连带删除其选课记录，并经由 CDC 同步到 Doris。前端确认框已明确提示，删除接口返回值也带说明。
- 列表用 `LEFT JOIN classes` 带出 `class_name`，支持学号 / 姓名 / 班级名 / 班级代码模糊搜索；812 条数据按 50 条一页分页。

## 六、接口清单

| 方法 | 路径 | 数据源 | 说明 |
|---|---|---|---|
| GET | `/api/health` | MySQL + Doris | 健康检查，返回当前连接的库名与图表来源 |
| GET | `/api/student/classes` | MySQL | 班级下拉列表 |
| GET | `/api/student/list?keyword=&page=1&size=50` | MySQL | 分页学生列表，返回 `list / total / page / size` |
| POST | `/api/student/add` | MySQL | 新增，见下方 JSON |
| PUT | `/api/student/update/<student_id>` | MySQL | 修改，可只传部分字段 |
| DELETE | `/api/student/delete/<student_id>` | MySQL | 删除（级联选课记录） |
| GET | `/api/chart/class` | **Doris DWD** | 各班人数，返回 `items / categories / values / total` |
| GET | `/api/chart/gender` | **Doris ADS** | 性别分布，同上 |

新增/修改请求体（字段均可省略，按白名单过滤）：

```json
{
  "student_no": "2026010101",
  "name": "测试同学",
  "gender": "男",
  "class_id": 1,
  "enroll_date": "2026-09-01",
  "status": "在读",
  "phone": "13900000000",
  "email": "test@stu.school.edu.cn"
}
```

统一响应：`{"code":0,"msg":"ok","data":{...}}`；失败为 `{"code":1,"msg":"..."}`。

## 七、测试步骤

```bash
# 1) 健康检查：应显示 mysql_db=student_management、doris_db=student_sync
curl http://127.0.0.1:8000/api/health

# 2) 班级维表与学生列表（分页）
curl http://127.0.0.1:8000/api/student/classes
curl "http://127.0.0.1:8000/api/student/list?size=3"

# 3) 新增（class_id 取上面返回的真实班级 ID）
curl -X POST http://127.0.0.1:8000/api/student/add \
  -H 'Content-Type: application/json' \
  -d '{"student_no":"TEST9999","name":"链路测试","gender":"男","class_id":1,"enroll_date":"2026-09-01","status":"在读","phone":"13900000000"}'

# 4) 修改（把上一步返回的 id 代入）
curl -X PUT http://127.0.0.1:8000/api/student/update/813 \
  -H 'Content-Type: application/json' -d '{"status":"休学","phone":"13800000000"}'

# 5) 两个统计接口（应显示真实 812 人量级）
curl http://127.0.0.1:8000/api/chart/class
curl http://127.0.0.1:8000/api/chart/gender

# 6) 删除测试学生
curl -X DELETE http://127.0.0.1:8000/api/student/delete/813

# 7) 页面
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/dashboard.html
```

浏览器验证：

1. 打开 `http://<host-ip>:8081/` → 学生管理页，列表显示当前学生总数（示例约 800+ 人，分页每页 50 条）；
2. 点「+ 新增学生」，班级为下拉选择，保存后列表出现新记录；
3. 点「编辑」改学籍状态、点「删除」并阅读级联提示 → 列表同步变化；
4. 搜索框输入学号 / 姓名 / 班级名 → 过滤生效；
5. 打开 `http://<host-ip>:8081/dashboard.html` → 柱状图显示各班人数（拖动底部滑块查看 38 个班）、饼图显示全校男女比例；
6. 点「刷新数据」→ 更新时间变化、图表重新拉取；勾选「自动刷新（30 秒）」→ 定时重拉。

**全链路联动验证**（这一步才能证明「管理页改数据 → 大屏跟着变」）：

```bash
# a. 记录当前基线
curl -s http://127.0.0.1:8000/api/chart/gender

# b. 通过管理页或接口新增/删除一个学生
curl -X POST http://127.0.0.1:8000/api/student/add -H 'Content-Type: application/json' \
  -d '{"student_no":"TEST9999","name":"链路测试","gender":"男","class_id":1,"enroll_date":"2026-09-01"}'

# c. 等 CDC 同步到 ODS（几秒）
docker exec mysql mysql -h doris-fe -P 9030 -uroot -p000000 -N -e \
  "SELECT COUNT(*) FROM student_sync.ods_student;"

# d. 等 DS 定时重跑分层，或手动触发
bash /etc/docker/doris-st/student-warehouse/run_layers.sh

# e. 大屏点「刷新数据」，或直接看接口
curl -s http://127.0.0.1:8000/api/chart/gender
```

删除测试学生后，重跑分层，数字应回到基线。

## 八、常见问题

| 现象 | 原因与处理 |
|---|---|
| 管理页改了数据、大屏没变 | 分层脚本尚未重跑。检查 DS 定时任务或手动执行 `run_layers.sh`，再点大屏「刷新数据」 |
| 接口报 `Unknown database 'student_management'` | 源库不存在，需先恢复数仓源库；本项目不负责建库 |
| 接口报 `Unknown database` | 检查 `docker-compose.yml` 的 `MYSQL_DB` / `DORIS_DB`，并确认对应库已创建 |
| 新增报外键错 / 班级不存在 | `class_id` 必须是 `classes` 表中存在的 ID，页面已改为下拉，不要手填班级名 |
| 新增报 `enroll_date` 不能为空 | 源表该字段非空且无默认值，页面已默认今天，接口调用时也要传 |
| 删除后选课记录消失 | 设计如此：`enrollment.student_id` 外键 CASCADE，且变更会由 CDC 同步到数仓 |
| 页面 404 或接口 502 | 检查 `docker compose ps`，以及 `nginx.conf` 中 `proxy_pass http://flask:8000` 的容器名 |
| 想直连后端跨域调试 | 在引入 `api.js` 前设置 `window.APP_CONFIG = { API_BASE: 'http://<host-ip>:8000' }`，Flask 已开启 CORS |
| 编辑时能改学号吗 | 可以。`student_no` 可修改（须唯一），UPDATE 会由 CDC 同步到 `ods_student`，分层重跑后 DWD 同步更新 |
| 改完学号，大屏没立刻变 | CDC `checkpoint.interval=5000`，约 5~10 秒后 ODS 才更新；同一主键在一个 checkpoint 内的多次变更会被合并为最终状态。之后还要等分层作业重跑，再点大屏「刷新数据」 |
