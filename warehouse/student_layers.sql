-- =============================================================
-- 学生管理系统数仓分层脚本（Doris 2.1.x / 库 student_sync）
--
-- 分层：ODS(已由 SeaTunnel CDC 建成) -> DWD(3 张) -> DWS(3 张) -> ADS(3 张)
-- 特性：
--   1. 幂等：CREATE TABLE IF NOT EXISTS + 灌数前 TRUNCATE，重复执行不会翻倍；
--   2. 单 BE 环境，所有表显式 PROPERTIES("replication_num"="1")；
--   3. 分层表统一用 UNIQUE KEY（业务主键），配合 DolphinScheduler 定时重跑按主键覆盖；
--   4. 所有 JOIN 用 LEFT JOIN 并统一 CAST ID，避免 decimalv3(20,0) 与 BIGINT 隐式转换差异。
--
-- 源表真实结构要点（据此做的字段映射，勿凭字段名想当然）：
--   ods_student    : 姓名字段是 name（不是 student_name）；
--   ods_teacher    : 姓名字段是 name，职称是 title；
--   ods_score      : 没有 student_id / course_id / exam_time，只有 enrollment_id，
--                   成绩列是 total_score，考试时间用 input_time，及格标志 is_pass(1/0)；
--   ods_enrollment : 由 enrollment_id -> student_id + teaching_id 连到学生与授课班；
--   ods_teaching_class: teaching_id -> course_id + teacher_id，课程学分在 ods_course.credit。
--
-- 执行（宿主机）：bash /etc/docker/doris-st/student-warehouse/run_layers.sh
-- 或在 DataGrip / DBeaver 里整份执行本文件。
-- =============================================================

USE student_sync;

-- #############################################################
-- 一、建表：DWD 明细层
-- #############################################################

-- 1. 学生维度表：把班级 / 专业 / 学院属性拉平到学生粒度
CREATE TABLE IF NOT EXISTS student_sync.dwd_dim_student (
    student_id      BIGINT          NOT NULL COMMENT '学生ID',
    student_no      VARCHAR(80)             COMMENT '学号',
    student_name    VARCHAR(120)            COMMENT '姓名',
    gender          VARCHAR(16)             COMMENT '性别（男/女）',
    class_id        BIGINT                  COMMENT '班级ID',
    class_name      VARCHAR(200)            COMMENT '班级名称',
    major_id        BIGINT                  COMMENT '专业ID',
    major_name      VARCHAR(200)            COMMENT '专业名称',
    college_id      BIGINT                  COMMENT '学院ID',
    college_name    VARCHAR(200)            COMMENT '学院名称',
    student_status  VARCHAR(40)             COMMENT '学籍状态',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(student_id)
DISTRIBUTED BY HASH(student_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- 2. 课程与教师维度表：粒度是「授课班 teaching_id」，不是课程
--    （同一门课可能由多位教师、在多个学期开课，用 course_id 作主键会丢记录）
CREATE TABLE IF NOT EXISTS student_sync.dwd_dim_course_teacher (
    teaching_id     BIGINT          NOT NULL COMMENT '授课班ID（主键）',
    course_id       BIGINT                  COMMENT '课程ID',
    course_no       VARCHAR(80)             COMMENT '课程编号',
    course_name     VARCHAR(240)            COMMENT '课程名称',
    credit          DECIMAL(3,1)            COMMENT '学分（欠学分计算用）',
    teacher_id      BIGINT                  COMMENT '教师ID',
    teacher_name    VARCHAR(120)            COMMENT '教师姓名',
    teacher_title   VARCHAR(80)             COMMENT '职称',
    class_id        BIGINT                  COMMENT '授课班级ID',
    class_name      VARCHAR(200)            COMMENT '授课班级名称',
    academic_year   VARCHAR(80)             COMMENT '学年',
    semester        INT                     COMMENT '学期',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(teaching_id)
DISTRIBUTED BY HASH(teaching_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- 3. 学生成绩事实表：数仓核心明细宽表
--    关联路径 ods_score -> ods_enrollment -> (ods_student / ods_teaching_class)
CREATE TABLE IF NOT EXISTS student_sync.dwd_fact_student_score (
    score_id           BIGINT          NOT NULL COMMENT '成绩ID（主键）',
    enrollment_id      BIGINT                  COMMENT '选课ID',
    student_id         BIGINT                  COMMENT '学生ID',
    student_no         VARCHAR(80)             COMMENT '学号',
    student_name       VARCHAR(120)            COMMENT '学生姓名',
    gender             VARCHAR(16)             COMMENT '性别',
    class_id           BIGINT                  COMMENT '学生所属班级ID',
    class_name         VARCHAR(200)            COMMENT '班级名称',
    major_name         VARCHAR(200)            COMMENT '专业名称',
    college_id         BIGINT                  COMMENT '学院ID',
    college_name       VARCHAR(200)            COMMENT '学院名称',
    teaching_id        BIGINT                  COMMENT '授课班ID',
    course_id          BIGINT                  COMMENT '课程ID',
    course_name        VARCHAR(240)            COMMENT '课程名称',
    credit             DECIMAL(3,1)            COMMENT '课程学分',
    teacher_id         BIGINT                  COMMENT '教师ID',
    teacher_name       VARCHAR(120)            COMMENT '教师姓名',
    score              DECIMAL(5,2)            COMMENT '总评成绩（源 total_score）',
    is_pass            TINYINT                 COMMENT '是否及格（1/0）',
    exam_type          VARCHAR(40)             COMMENT '考试类型',
    exam_time          DATETIME                COMMENT '成绩录入时间（源 input_time）',
    enrollment_status  VARCHAR(40)             COMMENT '选课状态',
    etl_time           DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(score_id)
DISTRIBUTED BY HASH(score_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- #############################################################
-- 二、建表：DWS 汇总层
-- #############################################################

-- 1. 班级 + 课程成绩汇总
CREATE TABLE IF NOT EXISTS student_sync.dws_class_course_summary (
    class_id        BIGINT          NOT NULL COMMENT '班级ID',
    course_id       BIGINT          NOT NULL COMMENT '课程ID',
    class_name     VARCHAR(200)            COMMENT '班级名称',
    course_name     VARCHAR(240)            COMMENT '课程名称',
    student_cnt     BIGINT                  COMMENT '参考人数',
    avg_score       DECIMAL(8,2)            COMMENT '平均分',
    max_score       DECIMAL(5,2)            COMMENT '最高分',
    min_score       DECIMAL(5,2)            COMMENT '最低分',
    pass_cnt        BIGINT                  COMMENT '及格人数',
    pass_rate       DOUBLE                  COMMENT '及格率',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(class_id, course_id)
DISTRIBUTED BY HASH(class_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- 2. 学生成绩汇总（含全校平均分排名）
CREATE TABLE IF NOT EXISTS student_sync.dws_student_score_summary (
    student_id      BIGINT          NOT NULL COMMENT '学生ID',
    student_name    VARCHAR(120)            COMMENT '姓名',
    class_name      VARCHAR(200)            COMMENT '班级名称',
    course_cnt      BIGINT                  COMMENT '参考课程数',
    total_score     DECIMAL(10,2)           COMMENT '总分',
    avg_score       DECIMAL(8,2)            COMMENT '平均分',
    rank_no         INT                     COMMENT '全校平均分排名',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(student_id)
DISTRIBUTED BY HASH(student_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- 3. 教师授课统计
CREATE TABLE IF NOT EXISTS student_sync.dws_teacher_stat (
    teacher_id      BIGINT          NOT NULL COMMENT '教师ID',
    teacher_name    VARCHAR(120)            COMMENT '教师姓名',
    teacher_title   VARCHAR(80)             COMMENT '职称',
    teaching_cnt    BIGINT                  COMMENT '授课班数量',
    student_cnt     BIGINT                  COMMENT '所教学生数（去重）',
    score_cnt       BIGINT                  COMMENT '成绩记录数',
    avg_score       DECIMAL(8,2)            COMMENT '所教课程平均分',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(teacher_id)
DISTRIBUTED BY HASH(teacher_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- #############################################################
-- 三、建表：ADS 应用层
-- #############################################################

-- 1. 学院学生画像大屏
CREATE TABLE IF NOT EXISTS student_sync.ads_college_dashboard (
    college_id          BIGINT          NOT NULL COMMENT '学院ID',
    college_name        VARCHAR(200)            COMMENT '学院名称',
    student_cnt         BIGINT                  COMMENT '学生总数',
    male_cnt            BIGINT                  COMMENT '男生数',
    female_cnt          BIGINT                  COMMENT '女生数',
    male_female_ratio   DOUBLE                  COMMENT '男女比例（男/女）',
    fail_cnt            BIGINT                  COMMENT '挂科总人次',
    etl_time            DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(college_id)
DISTRIBUTED BY HASH(college_id) BUCKETS 2
PROPERTIES("replication_num"="1");

-- 2. 班级成绩排行（全校排名）
CREATE TABLE IF NOT EXISTS student_sync.ads_class_score_ranking (
    class_id        BIGINT          NOT NULL COMMENT '班级ID',
    course_id       BIGINT          NOT NULL COMMENT '课程ID',
    class_name      VARCHAR(200)            COMMENT '班级名称',
    course_name      VARCHAR(240)            COMMENT '课程名称',
    avg_score       DECIMAL(8,2)            COMMENT '平均分',
    school_rank     INT                     COMMENT '全校排名（按平均分降序）',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(class_id, course_id)
DISTRIBUTED BY HASH(class_id) BUCKETS 4
PROPERTIES("replication_num"="1");

-- 3. 学生学业预警（只保留有不及格记录的学生）
CREATE TABLE IF NOT EXISTS student_sync.ads_student_warning (
    student_id      BIGINT          NOT NULL COMMENT '学生ID',
    student_name    VARCHAR(120)            COMMENT '姓名',
    class_name      VARCHAR(200)            COMMENT '班级名称',
    fail_course_cnt BIGINT                  COMMENT '不及格科目数',
    fail_credit     DECIMAL(8,1)            COMMENT '总欠学分',
    min_score       DECIMAL(5,2)            COMMENT '最低分',
    warning_level   VARCHAR(20)             COMMENT '预警等级',
    etl_time        DATETIME                COMMENT 'ETL 时间'
)
UNIQUE KEY(student_id)
DISTRIBUTED BY HASH(student_id) BUCKETS 2
PROPERTIES("replication_num"="1");

-- #############################################################
-- 四、清空分层表（幂等：重复执行不会翻倍）
-- #############################################################
TRUNCATE TABLE student_sync.dwd_dim_student;
TRUNCATE TABLE student_sync.dwd_dim_course_teacher;
TRUNCATE TABLE student_sync.dwd_fact_student_score;
TRUNCATE TABLE student_sync.dws_class_course_summary;
TRUNCATE TABLE student_sync.dws_student_score_summary;
TRUNCATE TABLE student_sync.dws_teacher_stat;
TRUNCATE TABLE student_sync.ads_college_dashboard;
TRUNCATE TABLE student_sync.ads_class_score_ranking;
TRUNCATE TABLE student_sync.ads_student_warning;

-- #############################################################
-- 五、灌数：DWD 层（严格按依赖顺序）
-- #############################################################

-- DWD-1 学生维度：ods_student + ods_classes + ods_major + ods_college
INSERT INTO student_sync.dwd_dim_student
SELECT
    CAST(st.student_id AS BIGINT)                       AS student_id,
    st.student_no,
    st.name                                             AS student_name,
    st.gender,
    CAST(st.class_id AS BIGINT)                         AS class_id,
    c.class_name,
    CAST(c.major_id AS BIGINT)                         AS major_id,
    m.major_name,
    CAST(m.college_id AS BIGINT)                       AS college_id,
    co.college_name,
    st.status                                          AS student_status,
    NOW()                                               AS etl_time
FROM student_sync.ods_student st
LEFT JOIN student_sync.ods_classes  c  ON c.class_id  = st.class_id
LEFT JOIN student_sync.ods_major   m  ON m.major_id  = c.major_id
LEFT JOIN student_sync.ods_college co ON co.college_id = m.college_id
WHERE st.student_id IS NOT NULL;

-- DWD-2 课程教师维度：ods_teaching_class + ods_course + ods_teacher + ods_classes
INSERT INTO student_sync.dwd_dim_course_teacher
SELECT
    CAST(tc.teaching_id AS BIGINT)                     AS teaching_id,
    CAST(tc.course_id AS BIGINT)                       AS course_id,
    cr.course_no,
    cr.course_name,
    cr.credit,
    CAST(tc.teacher_id AS BIGINT)                      AS teacher_id,
    t.name                                              AS teacher_name,
    t.title                                             AS teacher_title,
    CAST(tc.class_id AS BIGINT)                        AS class_id,
    c.class_name,
    tc.academic_year,
    CAST(tc.semester AS INT)                           AS semester,
    NOW()                                              AS etl_time
FROM student_sync.ods_teaching_class tc
LEFT JOIN student_sync.ods_course  cr ON cr.course_id  = tc.course_id
LEFT JOIN student_sync.ods_teacher t  ON t.teacher_id   = tc.teacher_id
LEFT JOIN student_sync.ods_classes c ON c.class_id     = tc.class_id
WHERE tc.teaching_id IS NOT NULL;

-- DWD-3 学生成绩事实：成绩 -> 选课 -> 学生/授课班 -> 课程/教师/班级/学院
INSERT INTO student_sync.dwd_fact_student_score
SELECT
    CAST(s.score_id AS BIGINT)                         AS score_id,
    CAST(s.enrollment_id AS BIGINT)                    AS enrollment_id,
    CAST(e.student_id AS BIGINT)                       AS student_id,
    st.student_no,
    st.name                                             AS student_name,
    st.gender,
    CAST(st.class_id AS BIGINT)                        AS class_id,
    c.class_name,
    m.major_name,
    CAST(m.college_id AS BIGINT)                       AS college_id,
    co.college_name,
    CAST(e.teaching_id AS BIGINT)                      AS teaching_id,
    CAST(tc.course_id AS BIGINT)                       AS course_id,
    cr.course_name,
    cr.credit,
    CAST(tc.teacher_id AS BIGINT)                      AS teacher_id,
    t.name                                              AS teacher_name,
    s.total_score                                       AS score,
    s.is_pass,
    s.exam_type,
    s.input_time                                        AS exam_time,
    e.status                                           AS enrollment_status,
    NOW()                                               AS etl_time
FROM student_sync.ods_score s
LEFT JOIN student_sync.ods_enrollment      e  ON e.enrollment_id = s.enrollment_id
LEFT JOIN student_sync.ods_student         st ON st.student_id  = e.student_id
LEFT JOIN student_sync.ods_classes         c  ON c.class_id     = st.class_id
LEFT JOIN student_sync.ods_major          m  ON m.major_id     = c.major_id
LEFT JOIN student_sync.ods_college         co ON co.college_id  = m.college_id
LEFT JOIN student_sync.ods_teaching_class  tc ON tc.teaching_id  = e.teaching_id
LEFT JOIN student_sync.ods_course          cr ON cr.course_id   = tc.course_id
LEFT JOIN student_sync.ods_teacher         t  ON t.teacher_id   = tc.teacher_id
WHERE s.score_id IS NOT NULL;

-- #############################################################
-- 六、灌数：DWS 层
-- #############################################################

-- DWS-1 班级 + 课程成绩汇总
INSERT INTO student_sync.dws_class_course_summary
SELECT
    f.class_id,
    f.course_id,
    MAX(f.class_name)                                   AS class_name,
    MAX(f.course_name)                                  AS course_name,
    COUNT(DISTINCT f.student_id)                        AS student_cnt,
    ROUND(AVG(f.score), 2)                             AS avg_score,
    MAX(f.score)                                        AS max_score,
    MIN(f.score)                                        AS min_score,
    SUM(CASE WHEN f.is_pass = 1 THEN 1 ELSE 0 END)     AS pass_cnt,
    ROUND(CAST(SUM(CASE WHEN f.is_pass = 1 THEN 1 ELSE 0 END) AS DOUBLE) / COUNT(*), 4) AS pass_rate,
    NOW()                                               AS etl_time
FROM student_sync.dwd_fact_student_score f
WHERE f.class_id IS NOT NULL AND f.course_id IS NOT NULL
GROUP BY f.class_id, f.course_id;

-- DWS-2 学生成绩汇总 + 全校排名（窗口函数）
INSERT INTO student_sync.dws_student_score_summary
SELECT
    t.student_id,
    t.student_name,
    t.class_name,
    t.course_cnt,
    t.total_score,
    t.avg_score,
    CAST(RANK() OVER (ORDER BY t.avg_score DESC) AS INT) AS rank_no,
    NOW()                                               AS etl_time
FROM (
    SELECT
        f.student_id,
        MAX(f.student_name)          AS student_name,
        MAX(f.class_name)            AS class_name,
        COUNT(DISTINCT f.course_id)  AS course_cnt,
        SUM(f.score)                 AS total_score,
        ROUND(AVG(f.score), 2)        AS avg_score
    FROM student_sync.dwd_fact_student_score f
    WHERE f.student_id IS NOT NULL
    GROUP BY f.student_id
) t;

-- DWS-3 教师授课统计（两个不同粒度分别聚合后再 JOIN，避免笛卡尔积放大指标）
INSERT INTO student_sync.dws_teacher_stat
SELECT
    t.teacher_id,
    t.teacher_name,
    t.teacher_title,
    COALESCE(tc.teaching_cnt, 0)   AS teaching_cnt,
    COALESCE(s.student_cnt, 0)     AS student_cnt,
    COALESCE(s.score_cnt, 0)        AS score_cnt,
    COALESCE(s.avg_score, 0)       AS avg_score,
    NOW()                           AS etl_time
FROM (
    SELECT teacher_id,
           MAX(teacher_name)  AS teacher_name,
           MAX(teacher_title) AS teacher_title
    FROM student_sync.dwd_dim_course_teacher
    WHERE teacher_id IS NOT NULL
    GROUP BY teacher_id
) t
LEFT JOIN (
    SELECT teacher_id, COUNT(DISTINCT teaching_id) AS teaching_cnt
    FROM student_sync.dwd_dim_course_teacher
    WHERE teacher_id IS NOT NULL
    GROUP BY teacher_id
) tc ON tc.teacher_id = t.teacher_id
LEFT JOIN (
    SELECT teacher_id,
           COUNT(DISTINCT student_id) AS student_cnt,
           COUNT(*)                   AS score_cnt,
           ROUND(AVG(score), 2)        AS avg_score
    FROM student_sync.dwd_fact_student_score
    WHERE teacher_id IS NOT NULL
    GROUP BY teacher_id
) s ON s.teacher_id = t.teacher_id;

-- #############################################################
-- 七、灌数：ADS 层
-- #############################################################

-- ADS-1 学院学生画像大屏：以学院维表驱动，保证大屏展示所有学院（含零学生学院）
--      学生画像与挂科人次分别聚合后再 JOIN，避免两粒度直接 JOIN 造成指标翻倍
INSERT INTO student_sync.ads_college_dashboard
SELECT
    co.college_id,
    co.college_name,
    COALESCE(d.student_cnt, 0)      AS student_cnt,
    COALESCE(d.male_cnt, 0)         AS male_cnt,
    COALESCE(d.female_cnt, 0)       AS female_cnt,
    CASE WHEN COALESCE(d.female_cnt, 0) = 0 THEN 0
         ELSE ROUND(CAST(d.male_cnt AS DOUBLE) / d.female_cnt, 2)
    END                             AS male_female_ratio,
    COALESCE(f.fail_cnt, 0)        AS fail_cnt,
    NOW()                           AS etl_time
FROM student_sync.ods_college co
LEFT JOIN (
    SELECT college_id,
           COUNT(DISTINCT student_id)                       AS student_cnt,
           SUM(CASE WHEN gender = '男' THEN 1 ELSE 0 END)   AS male_cnt,
           SUM(CASE WHEN gender = '女' THEN 1 ELSE 0 END)   AS female_cnt
    FROM student_sync.dwd_dim_student
    WHERE college_id IS NOT NULL
    GROUP BY college_id
) d ON d.college_id = co.college_id
LEFT JOIN (
    SELECT college_id,
           SUM(CASE WHEN is_pass = 0 THEN 1 ELSE 0 END) AS fail_cnt
    FROM student_sync.dwd_fact_student_score
    WHERE college_id IS NOT NULL
    GROUP BY college_id
) f ON f.college_id = co.college_id
WHERE co.college_id IS NOT NULL;

-- ADS-2 班级成绩排行（全校按平均分排名）
INSERT INTO student_sync.ads_class_score_ranking
SELECT
    s.class_id,
    s.course_id,
    s.class_name,
    s.course_name,
    s.avg_score,
    CAST(RANK() OVER (ORDER BY s.avg_score DESC) AS INT) AS school_rank,
    NOW()                                                AS etl_time
FROM student_sync.dws_class_course_summary s;

-- ADS-3 学生学业预警：先按 (学生, 课程) 去重算欠学分，再按学生汇总
INSERT INTO student_sync.ads_student_warning
SELECT
    f.student_id,
    f.student_name,
    f.class_name,
    COUNT(*)                        AS fail_course_cnt,
    SUM(f.credit)                   AS fail_credit,
    MIN(f.min_score)                AS min_score,
    CASE WHEN COUNT(*) >= 3 THEN '严重预警'
         WHEN COUNT(*) >= 2 THEN '重点预警'
         ELSE '一般预警'
    END                             AS warning_level,
    NOW()                           AS etl_time
FROM (
    SELECT student_id,
           MAX(student_name)  AS student_name,
           MAX(class_name)    AS class_name,
           course_id,
           MAX(credit)        AS credit,
           MIN(score)         AS min_score
    FROM student_sync.dwd_fact_student_score
    WHERE is_pass = 0 AND student_id IS NOT NULL AND course_id IS NOT NULL
    GROUP BY student_id, course_id
) f
GROUP BY f.student_id, f.student_name, f.class_name;
