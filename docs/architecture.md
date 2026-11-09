# 架构设计说明

本文补充根 README 中没有展开的部分：源表真实结构、分层建模依据、指标口径，以及实施过程中踩过的坑。所有字段名都来自实际运行的业务表，不是按命名习惯推测的。

---

## 1. 源库结构

`source-mysql/student_management.sql` 建 10 张表，均为 InnoDB / utf8mb4，按依赖顺序创建：

```
college ──< major ──< classes ──< student ──< enrollment ──< score
                         │                        │
   teacher ──< teaching_class ──< course ─────────┘
                         │
                         └──< attendance
```

关键约束，写应用代码时必须遵守：

| 表 | 字段 | 约束 |
|---|---|---|
| `student` | `student_id` | bigint unsigned，自增主键 |
| | `student_no` | varchar(20)，非空且唯一（**可修改**，不是主键） |
| | `gender` | char(1)，取值只能是 `男` / `女` |
| | `class_id` | 外键 → `classes.class_id` |
| | `enroll_date` | date，**非空且无默认值** |
| | `status` | 在读 / 休学 / 毕业 / 退学，默认「在读」 |
| | `id_card` | 唯一，可空 |
| `enrollment` | `student_id` | 外键 → `student.student_id`，`ON DELETE CASCADE` |
| `classes` | `class_id` | 主键，实验数据中 38 个班 |

`enrollment` 的级联删除意味着：删除一名学生会连带删除其选课记录，并经由 CDC 同步到数仓。接口返回信息和前端确认框都对此作了明确提示。

---

## 2. ODS 层与字段映射

SeaTunnel 的 `MySQL-CDC` 以 `table-pattern = "student_management\\..*"` 监听全部 10 张表，`TableRename` 给表名统一加 `ods_` 前缀，落到 `student_sync` 库。表结构由 Sink 自动创建，与源表一致。

三处最容易写错的地方：

1. `ods_student`、`ods_teacher` 的姓名列是 `name`，不是 `student_name` / `teacher_name`；教师职称列是 `title`。
2. `ods_score` **没有** `student_id`、`course_id`、`exam_time`，只有 `enrollment_id`。成绩要顺着选课记录才能连到学生和课程：
   ```
   ods_score.enrollment_id
     → ods_enrollment(student_id, teaching_id)
       → ods_student / ods_teaching_class(course_id, teacher_id)
         → ods_course / ods_teacher
   ```
   因此 `score ← total_score`、`exam_time ← input_time`，欠学分计算所需的 `credit` 从 `ods_course.credit` 取。
3. `ods_score` 的 `is_pass` 是 1 / 0，`total_score` 无 NULL；`gender` 是「男 / 女」，不是 M / F。

实施前实测过 8 条 JOIN 链，全部零未命中，所以分层脚本可以放心用 LEFT JOIN 而不会丢数据。

---

## 3. DWD 层：三张宽表

| 表 | 主键 | 来源 | 作用 |
|---|---|---|---|
| `dwd_dim_student` | `student_id` | `ods_student` + `ods_classes` + `ods_major` + `ods_college` | 把学生属性拉平到学院，后续分析无需反复 JOIN |
| `dwd_dim_course_teacher` | **`teaching_id`** | `ods_teaching_class` + `ods_course` + `ods_teacher` | 记录每个授课班由哪位教师教哪门课 |
| `dwd_fact_student_score` | `score_id` | `ods_score` + 上面两张维表 | 最细粒度的成绩明细宽表 |

**为什么 `dwd_dim_course_teacher` 用 `teaching_id` 而不是 `course_id`**：同一门课会由多位教师、在不同学期开多个授课班。以课程 ID 作主键会把多条授课记录压成一条（实验数据中有 179 个授课班、33 门课）。

`dwd_fact_student_score` 保留了全部成绩记录，包括 `enrollment_status='已退选'` 的行，并单独带出该字段；上层如需只统计有效选课，加 `WHERE enrollment_status='已选'` 即可。

---

## 4. DWS 层：三个主题

| 表 | 维度 | 指标 |
|---|---|---|
| `dws_class_course_summary` | 班级 + 课程 | 平均分、最高分、最低分、及格率、参考人数 |
| `dws_student_score_summary` | 学生 | 总分、平均分、排名 |
| `dws_teacher_stat` | 教师 | 授课班数、学生数、所授课程平均分 |

两个实现细节：

- 排名用 `RANK() OVER (ORDER BY avg_score DESC)`，并列会跳号；如需连续名次改为 `DENSE_RANK()`。
- `dws_teacher_stat` 把「授课班数」和「学生数 / 平均分」**分别聚合再 JOIN**。两个粒度直接 JOIN 会产生笛卡尔积，把学生数和成绩放大。

---

## 5. ADS 层与图表口径

| 表 | 内容 |
|---|---|
| `ads_college_dashboard` | 学院名称、总人数、男女人数、男女比例、挂科人次 |
| `ads_class_score_ranking` | 班级、课程、平均分、全校排名 |
| `ads_student_warning` | 学号、姓名、不及格科目数、欠学分、预警等级 |

`ads_college_dashboard` 以 `ods_college` 维表驱动再左连接学生聚合结果，因此零学生的学院也会出现在结果里，保证大屏维度完整。

**应用接口的两个统计口径**：

- `/api/chart/class`（各班人数）读 `dwd_dim_student`，按 `class_name` 分组。ADS 三张表中没有「各班人数」这个口径，而项目约定不新建表，因此从已有的 DWD 明细层聚合。
- `/api/chart/gender`（性别占比）读 `ads_college_dashboard`，把各学院的 `male_cnt` / `female_cnt` 汇总上卷到全校，是真正落在 ADS 应用层的查询。

两者总数应一致，可用来交叉校验分层结果。

---

## 6. 幂等与一致性

`warehouse/student_layers.sql` 的每张表都是 `CREATE TABLE IF NOT EXISTS`，灌数前先 `TRUNCATE`，表统一用 UNIQUE KEY。`warehouse/run_layers.sh` 执行后会打印 9 张表的行数与抽样数据。

实测连跑两次行数完全一致；跨层一致性核对 7 组数字全部相等：

| 核对项 | 结果 |
|---|---|
| ODS 成绩行数 = DWD 事实行数 | 相等 |
| DWD 事实行数 = DWS 参考人数合计 | 相等 |
| DWD 学生数 = ADS 学院学生合计 | 相等 |
| ODS 挂科人次 = ADS 挂科合计 | 相等 |
| 应预警学生数 = 预警表行数 | 相等 |
| 事实表成绩合计 = DWS 总分合计 | 相等 |
| DWS 班级课程行数 = ADS 排行行数 | 相等 |

---

## 7. CDC 与调度要点

`seatunnel/student_sync.conf` 的几个关键项：

| 配置 | 作用 |
|---|---|
| `job.mode = "STREAMING"` | 常驻监听 binlog，不会自行退出 |
| `startup.mode = "initial"` | 首次全量 + 后续增量 |
| `checkpoint.interval = 5000` | 5 秒一次检查点，ODS 可见延迟约 5~10 秒 |
| `sink.enable-delete = true` | 让源端 DELETE 同步到 Doris |
| `sink.enable-2pc = true` | CDC 删除、schema 演化、`${table_name}` 占位符路由的前提 |
| `table = "${table_name}"` | 承接 `TableRename` 加上 `ods_` 前缀后的表名 |
| `schema_save_mode = CREATE_SCHEMA_WHEN_NOT_EXIST` | 自动建 ODS 表 |

同一主键在一个 checkpoint 窗口内的多次变更（例如 UPDATE 后紧接着 DELETE）会被 UNIQUE KEY 模型合并为最终状态，中间状态不会单独出现在 ODS。这是预期行为，不是丢数据。

DolphinScheduler 侧有两类任务：`STREAMING` 作业用 `ST_BACKGROUND=1` 启动一次并常驻；分层脚本适合配成定时 Shell 任务，重复执行安全。

---

## 8. 踩坑记录

| 问题 | 结论 |
|---|---|
| SeaTunnel 作业启动后立刻打印帮助退出 | 启动命令必须写 `-m local`，只写 `-m` 不够 |
| 插件名 / 参数名报错 | 用 `MySQL-CDC`、`base-url`，不是 `MySQLCdc` / `url` |
| Stream Load 挂起、checkpoint 超时 | `seatunnel` 容器未接入 `doris-st_doris-net`，FE 307 重定向到 BE 内网地址不可达 |
| Doris 建表失败 | 单 BE 必须显式 `PROPERTIES("replication_num"="1")` |
| DS standalone 换 MySQL 后启动失败 | 镜像只带 H2 驱动，需额外挂 `mysql-connector-j`；且要关掉 H2 初始化脚本 |
| DS 重建后工作流丢失 | 元数据仍在内置 H2；必须切到外部 MySQL |
| 大屏数字不随管理页变化 | 分层脚本未重跑，或 CDC checkpoint 还没到 |
