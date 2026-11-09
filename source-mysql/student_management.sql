-- =============================================================================
-- 学生管理系统数据库  student_management
-- 适用环境：MySQL 8.0 / InnoDB / utf8mb4
-- 表数量：10 张（学院、教师、专业、班级、学生、课程、教学班、选课、成绩、考勤）
-- 执行方式：mysql -uroot -p --default-character-set=utf8mb4 < student_management.sql
-- 说明：脚本可重复执行（先按依赖倒序删表，再建表并导入演示数据）；
--       末尾附 5 条常用查询，可直接用于答辩演示或课程作业验证。
--       演示数据均为虚构，身份证号仅用于展示字段格式，无真实个人信息。
-- =============================================================================

CREATE DATABASE IF NOT EXISTS `student_management`
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE `student_management`;
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS `attendance`;
DROP TABLE IF EXISTS `score`;
DROP TABLE IF EXISTS `enrollment`;
DROP TABLE IF EXISTS `teaching_class`;
DROP TABLE IF EXISTS `course`;
DROP TABLE IF EXISTS `student`;
DROP TABLE IF EXISTS `classes`;
DROP TABLE IF EXISTS `major`;
DROP TABLE IF EXISTS `teacher`;
DROP TABLE IF EXISTS `college`;

-- -----------------------------------------------------------------------------
-- 1. 学院表
-- -----------------------------------------------------------------------------
CREATE TABLE `college` (
  `college_id`   INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '学院ID',
  `college_code` VARCHAR(20)  NOT NULL COMMENT '学院编号',
  `college_name` VARCHAR(50)  NOT NULL COMMENT '学院名称',
  `dean_name`    VARCHAR(30)  DEFAULT NULL COMMENT '院长姓名',
  `office_phone` VARCHAR(20)  DEFAULT NULL COMMENT '办公电话',
  `create_time`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`college_id`),
  UNIQUE KEY `uk_college_code` (`college_code`),
  UNIQUE KEY `uk_college_name` (`college_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='学院表';

-- -----------------------------------------------------------------------------
-- 2. 教师表
-- -----------------------------------------------------------------------------
CREATE TABLE `teacher` (
  `teacher_id`  INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '教师ID',
  `teacher_no`  VARCHAR(20)  NOT NULL COMMENT '教师工号',
  `name`        VARCHAR(30)  NOT NULL COMMENT '姓名',
  `gender`      CHAR(1)      NOT NULL DEFAULT '男' COMMENT '性别：男/女',
  `birth_date`  DATE         DEFAULT NULL COMMENT '出生日期',
  `college_id`  INT UNSIGNED NOT NULL COMMENT '所属学院ID',
  `title`       VARCHAR(20)  DEFAULT '讲师' COMMENT '职称：教授/副教授/讲师/助教',
  `education`   VARCHAR(20)  DEFAULT NULL COMMENT '最高学历',
  `phone`       VARCHAR(20)  DEFAULT NULL COMMENT '联系电话',
  `email`       VARCHAR(60)  DEFAULT NULL COMMENT '邮箱',
  `hire_date`   DATE         DEFAULT NULL COMMENT '入职日期',
  `status`      VARCHAR(10)  NOT NULL DEFAULT '在职' COMMENT '状态：在职/退休/离职',
  `create_time` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`teacher_id`),
  UNIQUE KEY `uk_teacher_no` (`teacher_no`),
  KEY `idx_teacher_college` (`college_id`),
  KEY `idx_teacher_name` (`name`),
  CONSTRAINT `fk_teacher_college` FOREIGN KEY (`college_id`) REFERENCES `college` (`college_id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='教师表';

-- -----------------------------------------------------------------------------
-- 3. 专业表
-- -----------------------------------------------------------------------------
CREATE TABLE `major` (
  `major_id`       INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '专业ID',
  `college_id`     INT UNSIGNED NOT NULL COMMENT '所属学院ID',
  `major_code`     VARCHAR(20)  NOT NULL COMMENT '专业代码',
  `major_name`     VARCHAR(50)  NOT NULL COMMENT '专业名称',
  `duration_years` TINYINT      NOT NULL DEFAULT 4 COMMENT '学制（年）',
  `degree_type`    VARCHAR(20)  DEFAULT NULL COMMENT '授予学位类别',
  `is_active`      TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '是否招生：1是 0否',
  `create_time`    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`major_id`),
  UNIQUE KEY `uk_major_code` (`major_code`),
  UNIQUE KEY `uk_college_major` (`college_id`, `major_name`),
  CONSTRAINT `fk_major_college` FOREIGN KEY (`college_id`) REFERENCES `college` (`college_id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='专业表';

-- -----------------------------------------------------------------------------
-- 4. 班级表
-- -----------------------------------------------------------------------------
CREATE TABLE `classes` (
  `class_id`        INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '班级ID',
  `major_id`        INT UNSIGNED NOT NULL COMMENT '所属专业ID',
  `class_code`      VARCHAR(20)  NOT NULL COMMENT '班级编号',
  `class_name`      VARCHAR(50)  NOT NULL COMMENT '班级名称',
  `grade`           SMALLINT UNSIGNED NOT NULL COMMENT '入学年级',
  `head_teacher_id` INT UNSIGNED DEFAULT NULL COMMENT '班主任（教师ID）',
  `create_time`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`class_id`),
  UNIQUE KEY `uk_class_code` (`class_code`),
  KEY `idx_class_major` (`major_id`),
  KEY `idx_class_grade` (`grade`),
  CONSTRAINT `fk_class_major` FOREIGN KEY (`major_id`) REFERENCES `major` (`major_id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_class_head`  FOREIGN KEY (`head_teacher_id`) REFERENCES `teacher` (`teacher_id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='班级表';

-- -----------------------------------------------------------------------------
-- 5. 学生表
-- -----------------------------------------------------------------------------
CREATE TABLE `student` (
  `student_id`       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '学生ID',
  `student_no`       VARCHAR(20)  NOT NULL COMMENT '学号',
  `name`             VARCHAR(30)  NOT NULL COMMENT '姓名',
  `gender`           CHAR(1)      NOT NULL DEFAULT '男' COMMENT '性别：男/女',
  `birth_date`       DATE         DEFAULT NULL COMMENT '出生日期',
  `id_card`          CHAR(18)     DEFAULT NULL COMMENT '身份证号',
  `nation`           VARCHAR(20)  DEFAULT '汉族' COMMENT '民族',
  `political_status` VARCHAR(20)  DEFAULT '群众' COMMENT '政治面貌',
  `phone`            VARCHAR(20)  DEFAULT NULL COMMENT '联系电话',
  `email`            VARCHAR(60)  DEFAULT NULL COMMENT '校园邮箱',
  `home_address`     VARCHAR(200) DEFAULT NULL COMMENT '家庭住址',
  `class_id`         INT UNSIGNED NOT NULL COMMENT '所在班级ID',
  `enroll_date`      DATE         NOT NULL COMMENT '入学日期',
  `status`           VARCHAR(10)  NOT NULL DEFAULT '在读' COMMENT '学籍状态：在读/休学/退学/毕业',
  `create_time`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `update_time`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`student_id`),
  UNIQUE KEY `uk_student_no` (`student_no`),
  UNIQUE KEY `uk_id_card` (`id_card`),
  KEY `idx_student_name` (`name`),
  KEY `idx_student_class` (`class_id`),
  KEY `idx_student_status` (`status`),
  CONSTRAINT `fk_student_class` FOREIGN KEY (`class_id`) REFERENCES `classes` (`class_id`) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='学生表';

-- -----------------------------------------------------------------------------
-- 6. 课程表
-- -----------------------------------------------------------------------------
CREATE TABLE `course` (
  `course_id`    INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '课程ID',
  `course_no`    VARCHAR(20)  NOT NULL COMMENT '课程编号',
  `course_name`  VARCHAR(60)  NOT NULL COMMENT '课程名称',
  `college_id`   INT UNSIGNED DEFAULT NULL COMMENT '开课学院ID（公共课可为空）',
  `credit`       DECIMAL(3,1) NOT NULL COMMENT '学分',
  `class_hours`  SMALLINT UNSIGNED DEFAULT NULL COMMENT '总学时',
  `course_type`  VARCHAR(20)  NOT NULL DEFAULT '专业核心课' COMMENT '课程性质：公共基础课/专业基础课/专业核心课/公共选修课',
  `description`  VARCHAR(200) DEFAULT NULL COMMENT '课程简介',
  `is_active`    TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '是否开课：1是 0否',
  `create_time`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`course_id`),
  UNIQUE KEY `uk_course_no` (`course_no`),
  KEY `idx_course_name` (`course_name`),
  KEY `idx_course_college` (`college_id`),
  CONSTRAINT `fk_course_college` FOREIGN KEY (`college_id`) REFERENCES `college` (`college_id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='课程表';

-- -----------------------------------------------------------------------------
-- 7. 教学班表（某学期某课程由某教师面向某班级开设的一次课）
--    class_id 为 NULL 表示面向全校的公共选修课
-- -----------------------------------------------------------------------------
CREATE TABLE `teaching_class` (
  `teaching_id`   INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '教学班ID',
  `course_id`     INT UNSIGNED NOT NULL COMMENT '课程ID',
  `teacher_id`    INT UNSIGNED NOT NULL COMMENT '授课教师ID',
  `class_id`      INT UNSIGNED DEFAULT NULL COMMENT '授课班级ID（公选课为空）',
  `academic_year` VARCHAR(20)  NOT NULL COMMENT '学年，如 2024-2025',
  `semester`      TINYINT UNSIGNED NOT NULL COMMENT '学期：1 秋季 2 春季',
  `classroom`     VARCHAR(50)  DEFAULT NULL COMMENT '上课教室',
  `schedule_time` VARCHAR(100) DEFAULT NULL COMMENT '上课时间（周次节次）',
  `capacity`      SMALLINT UNSIGNED NOT NULL DEFAULT 60 COMMENT '容量上限',
  `status`        VARCHAR(10)  NOT NULL DEFAULT '开课' COMMENT '状态：开课/结课/停开',
  `create_time`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`teaching_id`),
  KEY `idx_teach_course` (`course_id`),
  KEY `idx_teach_teacher` (`teacher_id`),
  KEY `idx_teach_class` (`class_id`),
  KEY `idx_teach_term` (`academic_year`, `semester`),
  CONSTRAINT `fk_teach_course`  FOREIGN KEY (`course_id`)  REFERENCES `course` (`course_id`)   ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_teach_teacher` FOREIGN KEY (`teacher_id`) REFERENCES `teacher` (`teacher_id`) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT `fk_teach_class`   FOREIGN KEY (`class_id`)   REFERENCES `classes` (`class_id`)   ON DELETE SET NULL  ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='教学班（授课安排）表';

-- -----------------------------------------------------------------------------
-- 8. 选课表（学生与教学班的多对多关联，成绩与考勤都挂在这张表上）
-- -----------------------------------------------------------------------------
CREATE TABLE `enrollment` (
  `enrollment_id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '选课记录ID',
  `student_id`    BIGINT UNSIGNED NOT NULL COMMENT '学生ID',
  `teaching_id`   INT UNSIGNED NOT NULL COMMENT '教学班ID',
  `select_type`   VARCHAR(10)  NOT NULL DEFAULT '正常选课' COMMENT '选课类型：正常选课/补选/重修',
  `status`        VARCHAR(10)  NOT NULL DEFAULT '已选' COMMENT '状态：已选/已退选',
  `select_time`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '选课时间',
  PRIMARY KEY (`enrollment_id`),
  UNIQUE KEY `uk_student_teaching` (`student_id`, `teaching_id`),
  KEY `idx_enroll_teaching` (`teaching_id`),
  KEY `idx_enroll_status` (`status`),
  CONSTRAINT `fk_enroll_student`  FOREIGN KEY (`student_id`)  REFERENCES `student` (`student_id`)        ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_enroll_teaching` FOREIGN KEY (`teaching_id`) REFERENCES `teaching_class` (`teaching_id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='选课表';

-- -----------------------------------------------------------------------------
-- 9. 成绩表
--    总评 = 平时成绩 * 30% + 期末成绩 * 70%（保留 1 位小数）
--    绩点：>=90→4.0  85~89.9→3.7  82~84.9→3.3  78~81.9→3.0  75~77.9→2.7
--          72~74.9→2.3  68~71.9→2.0  64~67.9→1.5  60~63.9→1.0  <60→0
--    is_pass：总评 >= 60 记为 1
-- -----------------------------------------------------------------------------
CREATE TABLE `score` (
  `score_id`      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '成绩ID',
  `enrollment_id` BIGINT UNSIGNED NOT NULL COMMENT '选课记录ID',
  `usual_score`   DECIMAL(5,2) DEFAULT NULL COMMENT '平时成绩',
  `exam_score`    DECIMAL(5,2) DEFAULT NULL COMMENT '期末成绩',
  `total_score`   DECIMAL(5,2) DEFAULT NULL COMMENT '总评成绩',
  `grade_point`   DECIMAL(3,2) DEFAULT NULL COMMENT '课程绩点',
  `is_pass`       TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '是否通过：1是 0否',
  `exam_type`     VARCHAR(10)  NOT NULL DEFAULT '正常考试' COMMENT '考试类型：正常考试/补考/重修',
  `remark`        VARCHAR(200) DEFAULT NULL COMMENT '备注',
  `input_time`    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '录入时间',
  `update_time`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`score_id`),
  UNIQUE KEY `uk_score_enrollment` (`enrollment_id`),
  KEY `idx_score_total` (`total_score`),
  KEY `idx_score_pass` (`is_pass`),
  CONSTRAINT `fk_score_enrollment` FOREIGN KEY (`enrollment_id`) REFERENCES `enrollment` (`enrollment_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `chk_usual` CHECK (`usual_score` IS NULL OR `usual_score` BETWEEN 0 AND 100),
  CONSTRAINT `chk_exam`  CHECK (`exam_score`  IS NULL OR `exam_score`  BETWEEN 0 AND 100),
  CONSTRAINT `chk_total` CHECK (`total_score` IS NULL OR `total_score` BETWEEN 0 AND 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='成绩表';

-- -----------------------------------------------------------------------------
-- 10. 考勤表
-- -----------------------------------------------------------------------------
CREATE TABLE `attendance` (
  `attendance_id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '考勤ID',
  `enrollment_id` BIGINT UNSIGNED NOT NULL COMMENT '选课记录ID',
  `attend_date`   DATE         NOT NULL COMMENT '考勤日期',
  `period`        VARCHAR(20)  NOT NULL DEFAULT '第1-2节' COMMENT '节次',
  `status`        VARCHAR(10)  NOT NULL DEFAULT '正常' COMMENT '状态：正常/迟到/早退/请假/旷课',
  `remark`        VARCHAR(200) DEFAULT NULL COMMENT '备注',
  `record_time`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '记录时间',
  PRIMARY KEY (`attendance_id`),
  UNIQUE KEY `uk_attend_once` (`enrollment_id`, `attend_date`, `period`),
  KEY `idx_attend_date` (`attend_date`),
  KEY `idx_attend_status` (`status`),
  CONSTRAINT `fk_attend_enrollment` FOREIGN KEY (`enrollment_id`) REFERENCES `enrollment` (`enrollment_id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='考勤表';

-- =============================================================================
-- 演示数据
-- =============================================================================

INSERT INTO `college` (`college_id`, `college_code`, `college_name`, `dean_name`, `office_phone`) VALUES
(1, 'CS', '计算机学院', '张建国', '0755-26001001'),
(2, 'EM', '经济管理学院', '陈静', '0755-26001002'),
(3, 'FL', '外国语学院', '刘芳', '0755-26001003'),
(4, 'GE', '通识教育学院', '杨振华', '0755-26001004');

INSERT INTO `teacher` (`teacher_id`, `teacher_no`, `name`, `gender`, `birth_date`, `college_id`, `title`, `education`, `phone`, `email`, `hire_date`, `status`) VALUES
(1, 'T2020001', '张建国', '男', '1975-03-12', 1, '教授', '博士', '13800001001', 'zhangjg@school.edu.cn', '2000-09-01', '在职'),
(2, 'T2020002', '李晓梅', '女', '1982-07-25', 1, '副教授', '博士', '13800001002', 'lixm@school.edu.cn', '2010-03-01', '在职'),
(3, 'T2021003', '王海涛', '男', '1990-11-08', 1, '讲师', '硕士', '13800001003', 'wanght@school.edu.cn', '2021-09-01', '在职'),
(4, 'T2019004', '陈静', '女', '1978-05-16', 2, '教授', '博士', '13800001004', 'chenj@school.edu.cn', '2005-09-01', '在职'),
(5, 'T2021005', '赵明', '男', '1988-09-30', 2, '讲师', '硕士', '13800001005', 'zhaom@school.edu.cn', '2016-09-01', '在职'),
(6, 'T2020006', '刘芳', '女', '1983-01-19', 3, '副教授', '硕士', '13800001006', 'liuf@school.edu.cn', '2008-09-01', '在职'),
(7, 'T2018007', '杨振华', '男', '1972-12-03', 4, '副教授', '博士', '13800001007', 'yangzh@school.edu.cn', '1998-09-01', '在职'),
(8, 'T2022008', '郭倩', '女', '1993-04-21', 4, '讲师', '硕士', '13800001008', 'guoq@school.edu.cn', '2022-09-01', '在职');

INSERT INTO `major` (`major_id`, `college_id`, `major_code`, `major_name`, `duration_years`, `degree_type`, `is_active`) VALUES
(1, 1, '080901', '计算机科学与技术', 4, '工学学士', 1),
(2, 1, '080902', '软件工程', 4, '工学学士', 1),
(3, 1, '080910', '数据科学与大数据技术', 4, '工学学士', 1),
(4, 2, '120203', '会计学', 4, '管理学学士', 1),
(5, 3, '050201', '英语', 4, '文学学士', 1);

INSERT INTO `classes` (`class_id`, `major_id`, `class_code`, `class_name`, `grade`, `head_teacher_id`) VALUES
(1, 1, 'CS2401', '计科2401班', 2024, 1),
(2, 2, 'SE2401', '软工2401班', 2024, 2),
(3, 3, 'DS2301', '数据2301班', 2023, 3),
(4, 4, 'AC2401', '会计2401班', 2024, 4),
(5, 5, 'EN2301', '英语2301班', 2023, 6);

INSERT INTO `student` (`student_id`, `student_no`, `name`, `gender`, `birth_date`, `id_card`, `nation`, `political_status`, `phone`, `email`, `home_address`, `class_id`, `enroll_date`, `status`) VALUES
(1, '2024010101', '王磊', '男', '2006-04-18', '440301200604180011', '汉族', '共青团员', '13900001001', '2024010101@stu.school.edu.cn', '广东省深圳市南山区', 1, '2024-09-01', '在读'),
(2, '2024010102', '李思雨', '女', '2006-08-02', '440301200608020022', '汉族', '共青团员', '13900001002', '2024010102@stu.school.edu.cn', '广东省广州市天河区', 1, '2024-09-01', '在读'),
(3, '2024010103', '陈子涵', '男', '2005-12-23', '440301200512230033', '汉族', '群众', '13900001003', '2024010103@stu.school.edu.cn', '湖南省长沙市岳麓区', 1, '2024-09-01', '在读'),
(4, '2024010104', '周雅婷', '女', '2006-02-14', '440301200602140044', '壮族', '共青团员', '13900001004', '2024010104@stu.school.edu.cn', '广西南宁市青秀区', 1, '2024-09-01', '在读'),
(5, '2024020101', '吴昊', '男', '2006-06-09', '440301200606090055', '汉族', '共青团员', '13900001005', '2024020101@stu.school.edu.cn', '广东省深圳市福田区', 2, '2024-09-01', '在读'),
(6, '2024020102', '郑欣怡', '女', '2006-10-30', '440301200610300066', '汉族', '共青团员', '13900001006', '2024020102@stu.school.edu.cn', '福建省厦门市思明区', 2, '2024-09-01', '在读'),
(7, '2024020103', '孙博文', '男', '2005-07-11', '440301200507110077', '回族', '群众', '13900001007', '2024020103@stu.school.edu.cn', '河南省郑州市金水区', 2, '2024-09-01', '在读'),
(8, '2023030101', '何雨桐', '女', '2005-03-27', '440301200503270088', '汉族', '共青团员', '13900001008', '2023030101@stu.school.edu.cn', '浙江省杭州市西湖区', 3, '2023-09-01', '在读'),
(9, '2023030102', '马俊杰', '男', '2005-09-15', '440301200509150099', '汉族', '预备党员', '13900001009', '2023030102@stu.school.edu.cn', '江苏省南京市鼓楼区', 3, '2023-09-01', '在读'),
(10, '2023040101', '林晓彤', '女', '2006-01-08', '440301200601080100', '汉族', '共青团员', '13900001010', '2023040101@stu.school.edu.cn', '广东省珠海市香洲区', 4, '2024-09-01', '在读'),
(11, '2023040102', '徐泽宇', '男', '2005-11-19', '440301200511190111', '汉族', '群众', '13900001011', '2023040102@stu.school.edu.cn', '四川省成都市武侯区', 4, '2024-09-01', '休学'),
(12, '2023050101', '苏婉清', '女', '2005-05-06', '440301200505060122', '满族', '共青团员', '13900001012', '2023050101@stu.school.edu.cn', '辽宁省大连市中山区', 5, '2023-09-01', '在读');

INSERT INTO `course` (`course_id`, `course_no`, `course_name`, `college_id`, `credit`, `class_hours`, `course_type`, `description`, `is_active`) VALUES
(1, 'C1001', '高等数学A', 4, 5.0, 80, '公共基础课', '微积分与线性代数基础', 1),
(2, 'C1002', '程序设计基础', 1, 4.0, 64, '专业基础课', 'C语言与算法入门', 1),
(3, 'C1003', '数据结构', 1, 4.0, 64, '专业核心课', '线性表树图与查找排序', 1),
(4, 'C1004', '数据库系统原理', 1, 3.5, 56, '专业核心课', '关系模型SQL与事务', 1),
(5, 'C1005', '软件工程导论', 1, 3.0, 48, '专业核心课', '软件生命周期与建模', 1),
(6, 'C1006', '管理学原理', 2, 3.0, 48, '专业基础课', '管理职能与组织行为', 1),
(7, 'C1007', '会计学原理', 2, 3.0, 48, '专业核心课', '复式记账与财务报表', 1),
(8, 'C1008', '综合英语', 3, 4.0, 64, '专业核心课', '听说读写综合训练', 1),
(9, 'C1009', '大学生心理健康教育', 4, 2.0, 32, '公共选修课', '情绪管理与人际沟通', 1);

INSERT INTO `teaching_class` (`teaching_id`, `course_id`, `teacher_id`, `class_id`, `academic_year`, `semester`, `classroom`, `schedule_time`, `capacity`, `status`) VALUES
(1, 1, 7, 1, '2024-2025', 1, '教三-201', '周一1-2节/周三3-4节', 60, '结课'),
(2, 2, 1, 1, '2024-2025', 1, '实验楼-A302', '周二1-2节/周四5-6节', 60, '结课'),
(3, 2, 2, 2, '2024-2025', 1, '实验楼-A305', '周四3-4节', 60, '结课'),
(4, 3, 2, 3, '2024-2025', 2, '教三-305', '周一3-4节/周五1-2节', 60, '结课'),
(5, 4, 1, 3, '2024-2025', 2, '实验楼-B201', '周三5-6节', 60, '结课'),
(6, 5, 3, 2, '2024-2025', 2, '教三-402', '周五3-4节', 60, '结课'),
(7, 7, 4, 4, '2024-2025', 1, '经管楼-201', '周二3-4节', 60, '结课'),
(8, 8, 6, 5, '2024-2025', 1, '外语楼-105', '周一5-6节', 40, '结课'),
(9, 9, 8, NULL, '2024-2025', 1, '报告厅', '周三7-8节', 120, '开课');

INSERT INTO `enrollment` (`enrollment_id`, `student_id`, `teaching_id`, `select_type`, `status`) VALUES
(1, 1, 1, '正常选课', '已选'),
(2, 2, 1, '正常选课', '已选'),
(3, 3, 1, '正常选课', '已选'),
(4, 4, 1, '正常选课', '已选'),
(5, 1, 2, '正常选课', '已选'),
(6, 2, 2, '正常选课', '已选'),
(7, 3, 2, '正常选课', '已选'),
(8, 4, 2, '补选', '已退选'),
(9, 5, 3, '正常选课', '已选'),
(10, 6, 3, '正常选课', '已选'),
(11, 7, 3, '正常选课', '已选'),
(12, 8, 4, '正常选课', '已选'),
(13, 9, 4, '正常选课', '已选'),
(14, 8, 5, '正常选课', '已选'),
(15, 9, 5, '正常选课', '已选'),
(16, 5, 6, '正常选课', '已选'),
(17, 6, 6, '正常选课', '已选'),
(18, 7, 6, '重修', '已选'),
(19, 10, 7, '正常选课', '已选'),
(20, 11, 7, '正常选课', '已选'),
(21, 12, 8, '正常选课', '已选'),
(22, 1, 9, '正常选课', '已选'),
(23, 5, 9, '正常选课', '已选'),
(24, 10, 9, '正常选课', '已选');

INSERT INTO `score` (`enrollment_id`, `usual_score`, `exam_score`, `total_score`, `grade_point`, `is_pass`, `exam_type`, `remark`) VALUES
(1, 90.00, 85.00, 86.50, 3.70, 1, '正常考试', NULL),
(2, 85.00, 92.00, 89.90, 3.70, 1, '正常考试', NULL),
(3, 78.00, 74.00, 75.20, 2.70, 1, '正常考试', NULL),
(4, 95.00, 88.00, 90.10, 4.00, 1, '正常考试', NULL),
(5, 88.00, 91.00, 90.10, 4.00, 1, '正常考试', NULL),
(6, 72.00, 68.00, 69.20, 2.00, 1, '正常考试', NULL),
(7, 82.00, 79.00, 79.90, 3.00, 1, '正常考试', NULL),
(9, 92.00, 95.00, 94.10, 4.00, 1, '正常考试', NULL),
(10, 76.00, 81.00, 79.50, 3.00, 1, '正常考试', NULL),
(11, 58.00, 52.00, 53.80, 0.00, 0, '正常考试', '需参加补考'),
(12, 86.00, 90.00, 88.80, 3.70, 1, '正常考试', NULL),
(13, 80.00, 76.00, 77.20, 2.70, 1, '正常考试', NULL),
(14, 93.00, 89.00, 90.20, 4.00, 1, '正常考试', NULL),
(15, 68.00, 63.00, 64.50, 1.50, 1, '正常考试', NULL),
(16, 84.00, 87.00, 86.10, 3.70, 1, '正常考试', NULL),
(17, 90.00, 93.00, 92.10, 4.00, 1, '正常考试', NULL),
(18, 55.00, 61.00, 59.20, 0.00, 0, '重修', '重修仍未通过需再次重修'),
(19, 87.00, 84.00, 84.90, 3.30, 1, '正常考试', NULL),
(20, 79.00, 83.00, 81.80, 3.00, 1, '正常考试', '休学前已取得成绩'),
(21, 91.00, 88.00, 88.90, 3.70, 1, '正常考试', NULL);

INSERT INTO `attendance` (`enrollment_id`, `attend_date`, `period`, `status`, `remark`) VALUES
(1, '2024-10-08', '第1-2节', '正常', NULL),
(2, '2024-10-08', '第1-2节', '迟到', '迟到8分钟'),
(3, '2024-10-08', '第1-2节', '正常', NULL),
(4, '2024-10-08', '第1-2节', '请假', '病假有假条'),
(1, '2024-10-15', '第1-2节', '旷课', NULL),
(5, '2024-10-15', '第3-4节', '正常', NULL),
(6, '2024-10-15', '第3-4节', '早退', NULL),
(9, '2024-10-16', '第3-4节', '正常', NULL),
(10, '2024-10-16', '第3-4节', '迟到', NULL),
(11, '2024-10-23', '第3-4节', '旷课', '累计旷课预警'),
(11, '2024-10-30', '第3-4节', '旷课', '累计旷课预警'),
(12, '2025-03-04', '第3-4节', '正常', NULL),
(13, '2025-03-04', '第3-4节', '旷课', '未请假'),
(14, '2025-03-05', '第5-6节', '正常', NULL),
(15, '2025-03-05', '第5-6节', '请假', '参加学科竞赛'),
(16, '2025-03-07', '第3-4节', '正常', NULL),
(17, '2025-03-07', '第3-4节', '迟到', NULL);

SET FOREIGN_KEY_CHECKS = 1;

-- =============================================================================
-- 常用查询示例（可直接执行）
-- =============================================================================

-- 1. 学生名册：学生 → 班级 → 专业 → 学院 四级关联
SELECT s.`student_no` AS `学号`, s.`name` AS `姓名`, s.`gender` AS `性别`,
       c.`college_name` AS `学院`, m.`major_name` AS `专业`,
       cl.`class_name` AS `班级`, s.`status` AS `学籍状态`
FROM `student` s
JOIN `classes` cl ON s.`class_id` = cl.`class_id`
JOIN `major` m    ON cl.`major_id` = m.`major_id`
JOIN `college` c  ON m.`college_id` = c.`college_id`
ORDER BY s.`student_no`;

-- 2. 完整成绩单：学年学期 + 学生 + 课程 + 学分 + 各项成绩 + 绩点
SELECT t.`academic_year` AS `学年`, t.`semester` AS `学期`,
       s.`student_no` AS `学号`, s.`name` AS `姓名`,
       co.`course_name` AS `课程`, co.`credit` AS `学分`,
       sc.`usual_score` AS `平时`, sc.`exam_score` AS `期末`,
       sc.`total_score` AS `总评`, sc.`grade_point` AS `绩点`,
       CASE sc.`is_pass` WHEN 1 THEN '通过' ELSE '未通过' END AS `是否通过`
FROM `score` sc
JOIN `enrollment` e      ON sc.`enrollment_id` = e.`enrollment_id`
JOIN `student` s         ON e.`student_id` = s.`student_id`
JOIN `teaching_class` t  ON e.`teaching_id` = t.`teaching_id`
JOIN `course` co         ON t.`course_id` = co.`course_id`
ORDER BY t.`academic_year`, t.`semester`, s.`student_no`, co.`course_no`;

-- 3. 各班级平均总评与及格率（聚合 + 分组 + 排序）
SELECT cl.`class_name` AS `班级`,
       COUNT(*) AS `成绩条数`,
       ROUND(AVG(sc.`total_score`), 2) AS `平均总评`,
       ROUND(SUM(sc.`is_pass`) / COUNT(*) * 100, 2) AS `及格率百分比`
FROM `score` sc
JOIN `enrollment` e ON sc.`enrollment_id` = e.`enrollment_id`
JOIN `student` s    ON e.`student_id` = s.`student_id`
JOIN `classes` cl   ON s.`class_id` = cl.`class_id`
GROUP BY cl.`class_id`, cl.`class_name`
ORDER BY `平均总评` DESC;

-- 4. 挂科预警名单
SELECT s.`student_no` AS `学号`, s.`name` AS `姓名`,
       co.`course_name` AS `课程`, sc.`total_score` AS `总评`,
       sc.`exam_type` AS `考试类型`, sc.`remark` AS `备注`
FROM `score` sc
JOIN `enrollment` e     ON sc.`enrollment_id` = e.`enrollment_id`
JOIN `student` s        ON e.`student_id` = s.`student_id`
JOIN `teaching_class` t ON e.`teaching_id` = t.`teaching_id`
JOIN `course` co        ON t.`course_id` = co.`course_id`
WHERE sc.`is_pass` = 0
ORDER BY sc.`total_score`;

-- 5. 考勤异常统计（行转列 + HAVING 过滤）
SELECT s.`student_no` AS `学号`, s.`name` AS `姓名`,
       SUM(CASE WHEN a.`status` = '旷课' THEN 1 ELSE 0 END) AS `旷课次数`,
       SUM(CASE WHEN a.`status` = '迟到' THEN 1 ELSE 0 END) AS `迟到次数`,
       SUM(CASE WHEN a.`status` = '请假' THEN 1 ELSE 0 END) AS `请假次数`
FROM `attendance` a
JOIN `enrollment` e ON a.`enrollment_id` = e.`enrollment_id`
JOIN `student` s    ON e.`student_id` = s.`student_id`
GROUP BY s.`student_id`, s.`student_no`, s.`name`
HAVING SUM(CASE WHEN a.`status` <> '正常' THEN 1 ELSE 0 END) > 0
ORDER BY `旷课次数` DESC, `迟到次数` DESC;
