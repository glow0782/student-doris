#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
学生管理系统 大批量插入数据生成器
=============================================================================
配套：student_management.sql（建库 + 10 张表 + 少量基础数据）
输出：student_bulk_data.sql（可直接导入 MySQL 的批量 INSERT 脚本）

特点
  1. 追加式：新数据使用独立的高位 ID 段，不覆盖、不删除原有基础数据；
  2. 幂等：SQL 开头按 ID 段逆序 DELETE，重复导入不会翻倍；
  3. 自适应：自动读取 student_management.sql 中已有的主键与业务编号，
     动态避开冲突（改过基础数据也不会撞学号 / 工号 / 课程号）；
  4. 真实性：中文姓名、带校验位的身份证、正态分布的分数、跨 4 个学年的
     开课与选课、按学期分布的考勤，全部由固定随机种子生成，可复现；
  5. 自校验：生成后在内存中检查外键、唯一键、成绩公式、绩点与枚举合法性。

用法
  python gen_student_data.py                          # 默认 800 名学生
  python gen_student_data.py --students 2000 --seed 7
  python gen_student_data.py --out /path/to/data.sql

导入（本地 MySQL）
  mysql -uroot -p --default-character-set=utf8mb4 < student_bulk_data.sql
导入（Docker 容器）
  docker exec -i mysql mysql -uroot -p000000 --default-character-set=utf8mb4 < student_bulk_data.sql
"""

import argparse
import os
import random
import re
import sys
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCE = os.path.join(BASE_DIR, 'student_management.sql')
DEFAULT_OUT = os.path.join(BASE_DIR, 'student_bulk_data.sql')

# 各表新数据 ID 段的下限（同时作为幂等 DELETE 的分界线）
FLOOR = {
    'college': 101, 'teacher': 101, 'major': 101, 'classes': 101,
    'course': 101, 'student': 1001, 'teaching_class': 1001,
    'enrollment': 100001, 'score': 100001, 'attendance': 100001,
}
# 删除顺序：先子表后父表
DELETE_ORDER = [
    'attendance', 'score', 'enrollment', 'teaching_class', 'student',
    'classes', 'course', 'major', 'teacher', 'college',
]
# 各表主键列
PK = {t: t + '_id' for t in FLOOR}
PK['classes'] = 'class_id'
PK['teaching_class'] = 'teaching_id'
# 需要避让的业务唯一编号列
UNIQUE_CODE_COLS = {
    'college': 'college_code', 'teacher': 'teacher_no', 'major': 'major_code',
    'classes': 'class_code', 'student': 'student_no', 'course': 'course_no',
}
INSERT_RE = re.compile(r'INSERT INTO `(\w+)` \(([^)]+)\) VALUES\s*(.*?);', re.S)

SURNAMES = list('王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾'
                '肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦')
GIVEN_M = ['子涵', '宇轩', '浩然', '博文', '俊杰', '泽宇', '昊天', '嘉诚', '思远', '明轩',
           '一鸣', '梓睿', '睿哲', '天佑', '奕辰', '致远', '建国', '海涛', '文博', '嘉豪',
           '志强', '晓峰', '晨曦', '亦凡', '锦程', '书航', '昱霖', '沐阳', '家豪', '弘毅',
           '翔宇', '启明', '正阳', '思齐', '毅然', '承泽', '楷瑞', '皓轩', '振宇', '逸凡']
GIVEN_F = ['思雨', '欣怡', '雅婷', '雨桐', '婉清', '晓彤', '诗涵', '若曦', '静怡', '梓萱',
           '语嫣', '嘉宁', '可欣', '梦瑶', '书瑶', '芷若', '晨希', '若涵', '一诺', '涵予',
           '楚妍', '沐晴', '知微', '安然', '清越', '舒窈', '锦书', '听澜', '映雪', '若楠',
           '心悦', '韵寒', '慧敏', '晓琳', '佳琪', '紫涵', '静姝', '语彤', '曼琪', '芸熙']
CITIES = [
    ('11', '110101', '北京市东城区'), ('31', '310101', '上海市黄浦区'),
    ('44', '440301', '广东省深圳市南山区'), ('44', '440106', '广东省广州市天河区'),
    ('33', '330106', '浙江省杭州市西湖区'), ('32', '320106', '江苏省南京市鼓楼区'),
    ('42', '420106', '湖北省武汉市武昌区'), ('51', '510107', '四川省成都市武侯区'),
    ('37', '370102', '山东省济南市历下区'), ('35', '350203', '福建省厦门市思明区'),
    ('43', '430104', '湖南省长沙市岳麓区'), ('41', '410105', '河南省郑州市金水区'),
    ('21', '210204', '辽宁省大连市沙河口区'), ('45', '450103', '广西南宁市青秀区'),
    ('61', '610113', '陕西省西安市雁塔区'), ('34', '340104', '安徽省合肥市蜀山区'),
]
NATIONS = ['汉族'] * 46 + ['壮族', '回族', '满族', '苗族', '土家族', '蒙古族', '彝族', '侗族']
POLITICS = ['共青团员'] * 7 + ['群众'] * 4 + ['预备党员', '中共党员']
TITLES = ['讲师'] * 5 + ['副教授'] * 3 + ['教授'] * 2 + ['助教']
DEGREES = ['硕士'] * 6 + ['博士'] * 4
COURSE_NAMES = [
    '线性代数', '概率论与数理统计', '离散数学', '大学物理', '操作系统',
    '计算机网络', '计算机组成原理', '编译原理', '算法设计与分析', 'Python数据分析',
    '机器学习导论', 'Web前端开发', '移动应用开发', '信息安全基础', '云计算技术',
    '大数据存储与计算', '数据挖掘', '宏观经济学', '微观经济学', '市场营销学',
    '财务管理', '审计学', '商务英语', '翻译理论与实践', '英美文学',
    '机械制图', '材料力学', '设计素描', '色彩构成', '大学生创新创业基础',
    'Linux系统应用', '数字图像处理', '运筹学', '电子商务概论', '组织行为学',
]
COURSE_TYPES = ['专业核心课'] * 5 + ['专业基础课'] * 3 + ['公共基础课'] * 2 + ['公共选修课']
CLASSROOM_BUILDINGS = ['教一', '教二', '教三', '实验楼', '经管楼', '外语楼', '艺术楼']
WEEK_DAYS = ['一', '二', '三', '四', '五']
PERIODS = ['1-2节', '3-4节', '5-6节', '7-8节']
ATTEND_PERIODS = ['第1-2节', '第3-4节', '第5-6节', '第7-8节']
TERMS = [
    ('2023-2024', 1, date(2023, 9, 1)), ('2023-2024', 2, date(2024, 2, 26)),
    ('2024-2025', 1, date(2024, 9, 1)), ('2024-2025', 2, date(2025, 2, 24)),
    ('2025-2026', 1, date(2025, 9, 1)), ('2025-2026', 2, date(2026, 2, 23)),
    ('2026-2027', 1, date(2026, 9, 1)),
]
CURRENT_TERM = ('2026-2027', 1)


# ----------------------------------------------------------------------------
# 基础工具
# ----------------------------------------------------------------------------
def sql_lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, bool):
        return '1' if v else '0'
    if isinstance(v, (int, float, Decimal)):
        return str(v)
    if isinstance(v, datetime):
        return "'" + v.strftime('%Y-%m-%d %H:%M:%S') + "'"
    if isinstance(v, date):
        return "'" + v.isoformat() + "'"
    s = str(v).replace('\\', '\\\\').replace("'", "''")
    return "'" + s + "'"


def clean(s):
    """去掉可能干扰 SQL 解析的半角逗号（数据本身仍可读）"""
    return str(s).replace(',', '、')


def id_check_digit(body17):
    weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    mapping = '10X98765432'
    return mapping[sum(int(c) * w for c, w in zip(body17, weights)) % 11]


def q1(x):
    return Decimal(str(x)).quantize(Decimal('0.1'), rounding=ROUND_HALF_UP)


def grade_point(total):
    t = Decimal(str(total))
    for cut, gp in [('90', '4.00'), ('85', '3.70'), ('82', '3.30'), ('78', '3.00'),
                    ('75', '2.70'), ('72', '2.30'), ('68', '2.00'), ('64', '1.50'),
                    ('60', '1.00')]:
        if t >= Decimal(cut):
            return gp
    return '0.00'


def parse_existing(path):
    """读取建库脚本中已有的主键最大值与业务唯一编号，用于避让冲突"""
    max_ids, codes = {}, {c: set() for c in UNIQUE_CODE_COLS.values()}
    if not os.path.exists(path):
        print('[warn] 未找到 %s，将使用默认 ID 段' % path)
        return max_ids, codes
    with open(path, encoding='utf-8') as f:
        text = f.read()
    for m in INSERT_RE.finditer(text):
        table = m.group(1)
        cols = [c.strip().strip('`') for c in m.group(2).split(',')]
        for line in re.finditer(r'\(([^()]*)\)', m.group(3)):
            parts = [p.strip() for p in line.group(1).split(',')]
            if len(parts) != len(cols):
                continue
            row = dict(zip(cols, parts))
            pk = PK.get(table, '')
            if pk in row and row[pk].isdigit():
                max_ids[table] = max(max_ids.get(table, 0), int(row[pk]))
            code_col = UNIQUE_CODE_COLS.get(table)
            if code_col and code_col in row:
                codes[code_col].add(row[code_col].strip("'"))
    return max_ids, codes


def render_insert(table, cols, rows, batch=400):
    if not rows:
        return '-- %s: 无新增数据\n' % table
    head = 'INSERT INTO `%s` (%s) VALUES\n' % (table, ', '.join('`%s`' % c for c in cols))
    chunks = []
    for i in range(0, len(rows), batch):
        body = ',\n'.join('(' + ', '.join(sql_lit(v) for v in r) + ')' for r in rows[i:i + batch])
        chunks.append(head + body + ';')
    return '\n\n'.join(chunks) + '\n'


# ----------------------------------------------------------------------------
# 主生成流程
# ----------------------------------------------------------------------------
def build(args):
    rnd = random.Random(args.seed)
    max_ids, exist_codes = parse_existing(args.source)
    start = {t: max(FLOOR[t], max_ids.get(t, 0) + 1) for t in FLOOR}

    old_ids = {
        'college': list(range(1, max_ids.get('college', 0) + 1)),
        'teacher': list(range(1, max_ids.get('teacher', 0) + 1)),
        'major': list(range(1, max_ids.get('major', 0) + 1)),
        'classes': list(range(1, max_ids.get('classes', 0) + 1)),
        'course': list(range(1, max_ids.get('course', 0) + 1)),
        'student': list(range(1, max_ids.get('student', 0) + 1)),
        'teaching_class': list(range(1, max_ids.get('teaching_class', 0) + 1)),
    }
    # 老数据的专业 -> 学院、班级 -> 年级，用于生成学号与教学班
    old_major_college = {1: 1, 2: 1, 3: 1, 4: 2, 5: 3}
    old_class_info = {1: (1, 2024, '计科'), 2: (2, 2024, '软工'), 3: (3, 2023, '数据'),
                      4: (4, 2024, '会计'), 5: (5, 2023, '英语')}

    def new_id(table, offset):
        return start[table] + offset

    def pick_name(gender, used):
        for _ in range(60):
            n = rnd.choice(SURNAMES) + rnd.choice(GIVEN_M if gender == '男' else GIVEN_F)
            if n not in used:
                used.add(n)
                return n
        return rnd.choice(SURNAMES) + rnd.choice(GIVEN_M if gender == '男' else GIVEN_F) + str(rnd.randint(10, 99))

    used_names = set()
    used_cards = set()
    used_student_no = set(exist_codes['student_no'])
    used_codes = {k: set(v) for k, v in exist_codes.items()}

    def unique_code(col, candidate):
        i = 0
        base = candidate
        while candidate in used_codes[col]:
            i += 1
            candidate = '%s%d' % (base, i)
        used_codes[col].add(candidate)
        return candidate

    # ---- 1. 学院 ----
    new_colleges = [('ME', '机械工程学院', '周立群'), ('AR', '艺术设计学院', '徐静怡')]
    college_rows = []
    for i, (code, name, dean) in enumerate(new_colleges):
        college_rows.append((new_id('college', i), unique_code('college_code', code),
                             name, dean, '0755-260010%02d' % (5 + i)))
    all_college_ids = old_ids['college'] + [r[0] for r in college_rows]
    new_college_ids = [r[0] for r in college_rows]

    # ---- 2. 专业 ----
    major_specs = [
        ('080903', '网络工程', 1, '工学学士', '网络'),
        ('080906', '人工智能', 1, '工学学士', '智能'),
        ('120201', '工商管理', 2, '管理学学士', '工商'),
        ('020301', '金融学', 2, '经济学学士', '金融'),
        ('050207', '日语', 3, '文学学士', '日语'),
        ('080201', '机械设计制造及其自动化', new_college_ids[0], '工学学士', '机械'),
        ('080501', '能源与动力工程', new_college_ids[0], '工学学士', '能源'),
        ('130502', '视觉传达设计', new_college_ids[1], '艺术学学士', '视传'),
    ]
    major_rows = []
    for i, (code, name, cid, degree, _) in enumerate(major_specs):
        major_rows.append((new_id('major', i), cid, unique_code('major_code', code),
                           name, 4, degree, 1))
    all_major_ids = old_ids['major'] + [r[0] for r in major_rows]
    # 老数据：major_id -> 班级简称（用于生成新班级名称）
    major_short = {v[0]: v[2] for v in old_class_info.values()}
    for (code, name, cid, degree, short), row in zip(major_specs, major_rows):
        major_short[row[0]] = short
    major_college = dict(old_major_college)
    for row in major_rows:
        major_college[row[0]] = row[1]

    # ---- 3. 教师 ----
    teacher_rows = []
    for i in range(40):
        gender = '男' if rnd.random() < 0.56 else '女'
        name = pick_name(gender, used_names)
        cid = rnd.choice(all_college_ids)
        birth = date(1968, 1, 1) + timedelta(days=rnd.randint(0, 365 * 25))
        # 入职年龄 22~33 岁，避免出现「19 岁硕士入职」这类不合常理的数据
        hire = birth + timedelta(days=365 * rnd.randint(22, 33) + rnd.randint(0, 300))
        no = unique_code('teacher_no', 'T%d%03d' % (hire.year, i + 41))
        teacher_rows.append((new_id('teacher', i), no, name, gender, birth, cid,
                             rnd.choice(TITLES), rnd.choice(DEGREES),
                             '138%08d' % rnd.randint(0, 99999999),
                             't%04d@school.edu.cn' % (i + 1), hire,
                             '在职' if rnd.random() < 0.94 else '离职'))
    all_teacher_ids = old_ids['teacher'] + [r[0] for r in teacher_rows]

    # ---- 4. 班级 ----
    class_rows = []
    class_meta = {}  # class_id -> (major_id, grade, short_name)
    for cid, (mid, grade, short) in old_class_info.items():
        class_meta[cid] = (mid, grade, short)
    seq = 0
    for mid in all_major_ids:
        short = major_short.get(mid, '综合')
        for grade in (2022, 2023, 2024, 2025):
            if rnd.random() > 0.62:
                continue
            seq += 1
            cid = new_id('classes', len(class_rows))
            code = unique_code('class_code', 'BJ%02d%02d%02d' % (grade % 100, mid % 100, seq))
            name = '%s%02d%02d班' % (short, grade % 100, seq)
            class_rows.append((cid, mid, code, name, grade, rnd.choice(all_teacher_ids)))
            class_meta[cid] = (mid, grade, short)
    if len(class_rows) < 12:  # 保证班级数量足够，避免随机导致数据过少
        for mid in all_major_ids[:8]:
            if len(class_rows) >= 12:
                break
            seq += 1
            cid = new_id('classes', len(class_rows))
            grade = 2025
            code = unique_code('class_code', 'BJ%02d%02d%02d' % (grade % 100, mid % 100, seq))
            class_rows.append((cid, mid, code, '%s%02d%02d班' % (major_short.get(mid, '综合'), grade % 100, seq),
                               grade, rnd.choice(all_teacher_ids)))
            class_meta[cid] = (mid, grade, major_short.get(mid, '综合'))
    all_class_ids = old_ids['classes'] + [r[0] for r in class_rows]

    # ---- 5. 课程 ----
    course_rows = []
    names = rnd.sample(COURSE_NAMES, min(24, len(COURSE_NAMES)))
    for i, name in enumerate(names):
        cid = rnd.choice(all_college_ids) if rnd.random() < 0.9 else None
        credit = Decimal(rnd.choice(['1.0', '1.5', '2.0', '2.5', '3.0', '3.5', '4.0', '5.0']))
        course_rows.append((new_id('course', i), unique_code('course_no', 'C2%03d' % (i + 1)),
                            name, cid, credit, int(credit * 16), rnd.choice(COURSE_TYPES),
                            clean(name + '课程简介与教学大纲'), 1))
    all_course_ids = old_ids['course'] + [r[0] for r in course_rows]

    # ---- 6. 学生 ----
    student_rows = []
    students_by_class = {cid: [] for cid in all_class_ids}
    for i in range(args.students):
        cid = all_class_ids[i % len(all_class_ids)]
        mid, grade, short = class_meta[cid]
        gender = '男' if rnd.random() < 0.55 else '女'
        name = pick_name(gender, used_names)
        birth_year = grade - 18 + rnd.choice([-1, 0, 0, 0, 1])
        birth = date(birth_year, 1, 1) + timedelta(days=rnd.randint(0, 364))
        area = rnd.choice(CITIES)
        body17 = area[1] + birth.strftime('%Y%m%d') + '%03d' % rnd.randint(1, 999)
        card = body17 + id_check_digit(body17)
        while card in used_cards:
            body17 = area[1] + birth.strftime('%Y%m%d') + '%03d' % rnd.randint(1, 999)
            card = body17 + id_check_digit(body17)
        used_cards.add(card)
        seq_in_class = len(students_by_class[cid]) + 1
        sno = '%d%03d%03d' % (grade, cid % 1000, seq_in_class)
        while sno in used_student_no:
            seq_in_class += 1
            sno = '%d%03d%03d' % (grade, cid % 1000, seq_in_class)
        used_student_no.add(sno)
        addr = clean(area[2] + rnd.choice(['科技路', '学院路', '文化街', '中山大道', '人民路'])
                     + '%d号' % rnd.randint(1, 300))
        sid = new_id('student', i)
        student_rows.append((sid, sno, name, gender, birth, card,
                             rnd.choice(NATIONS), rnd.choice(POLITICS),
                             '139%08d' % rnd.randint(0, 99999999),
                             '%s@stu.school.edu.cn' % sno, addr, cid,
                             date(grade, 9, 1),
                             rnd.choices(['在读', '休学', '退学', '毕业'], [94, 2, 1, 3])[0]))
        students_by_class[cid].append(sid)
    all_student_ids = old_ids['student'] + [r[0] for r in student_rows]

    # ---- 7. 教学班 ----
    teaching_rows = []
    teaching_meta = {}
    for course_idx, course_id in enumerate(all_course_ids):
        for _ in range(rnd.randint(4, 6)):
            year, sem, term_start = rnd.choice(TERMS)
            tid = new_id('teaching_class', len(teaching_rows))
            class_id = rnd.choice(all_class_ids) if rnd.random() < 0.9 else None
            teacher_id = rnd.choice(all_teacher_ids)
            classroom = '%s-%d%02d' % (rnd.choice(CLASSROOM_BUILDINGS), rnd.randint(1, 6), rnd.randint(1, 30))
            slots = ['周%s%s' % (rnd.choice(WEEK_DAYS), rnd.choice(PERIODS))]
            if rnd.random() < 0.4:
                slots.append('周%s%s' % (rnd.choice(WEEK_DAYS), rnd.choice(PERIODS)))
            status = '开课' if (year, sem) == CURRENT_TERM else '结课'
            teaching_rows.append((tid, course_id, teacher_id, class_id, year, sem,
                                  classroom, clean('/'.join(slots)),
                                  rnd.choice([40, 60, 60, 80, 120]), status))
            teaching_meta[tid] = (class_id, year, sem, term_start, status)

    # ---- 8. 选课 ----
    enrollment_rows = []
    enroll_meta = {}
    used_pairs = set()
    eid = start['enrollment']
    for tid, course_id, teacher_id, class_id, year, sem, room, slots, cap, tstatus in teaching_rows:
        term_start = teaching_meta[tid][3]
        if class_id is None:
            pool = rnd.sample(all_student_ids, min(rnd.randint(15, 45), len(all_student_ids)))
        else:
            pool = students_by_class.get(class_id, [])
            if not pool:
                continue
            keep = rnd.uniform(0.7, 1.0)
            pool = [s for s in pool if rnd.random() < keep]
        for sid in pool:
            if (sid, tid) in used_pairs:
                continue
            used_pairs.add((sid, tid))
            select_time = datetime.combine(term_start - timedelta(days=rnd.randint(3, 20)),
                                           datetime.min.time()) + timedelta(hours=rnd.randint(8, 22),
                                                                            minutes=rnd.randint(0, 59))
            status = '已退选' if rnd.random() < 0.03 else '已选'
            stype = rnd.choices(['正常选课', '补选', '重修'], [92, 5, 3])[0]
            enrollment_rows.append((eid, sid, tid, stype, status, select_time))
            enroll_meta[eid] = (sid, tid, status, term_start, tstatus)
            eid += 1

    # ---- 9. 成绩 ----
    score_rows = []
    sid_score = start['score']
    for eid_, (s, tid, estatus, term_start, tstatus) in enroll_meta.items():
        if estatus != '已选' or tstatus != '结课' or rnd.random() > 0.96:
            continue
        ability = rnd.gauss(76, 12)
        usual = q1(max(0, min(100, ability + rnd.gauss(4, 5))))
        exam = q1(max(0, min(100, ability + rnd.gauss(0, 8))))
        total = q1(Decimal(str(usual)) * Decimal('0.3') + Decimal(str(exam)) * Decimal('0.7'))
        passed = 1 if total >= 60 else 0
        etype = rnd.choices(['正常考试', '补考', '重修'], [95, 3, 2])[0]
        remark = None if passed else rnd.choice([None, '需参加补考', '建议重修该课程'])
        input_time = datetime.combine(term_start + timedelta(days=rnd.randint(105, 125)),
                                      datetime.min.time()) + timedelta(hours=rnd.randint(8, 20),
                                                                       minutes=rnd.randint(0, 59))
        score_rows.append((sid_score, eid_, usual, exam, total, grade_point(total),
                           passed, etype, remark, input_time))
        sid_score += 1

    # ---- 10. 考勤 ----
    attendance_rows = []
    aid = start['attendance']
    used_att = set()
    for eid_, (s, tid, estatus, term_start, tstatus) in enroll_meta.items():
        if estatus != '已选' or rnd.random() > 0.42:
            continue
        for _ in range(rnd.randint(1, 4)):
            d = term_start + timedelta(days=rnd.randint(0, 105))
            while d.weekday() >= 5:
                d += timedelta(days=1)
            period = rnd.choice(ATTEND_PERIODS)
            key = (eid_, d, period)
            if key in used_att:
                continue
            used_att.add(key)
            status = rnd.choices(['正常', '迟到', '请假', '旷课', '早退'],
                                 [84, 6, 4, 4, 2])[0]
            remark = {'迟到': '迟到%d分钟' % rnd.randint(3, 20),
                      '请假': rnd.choice(['病假有假条', '参加竞赛', '事假']),
                      '旷课': '未请假', '早退': '提前离堂', '正常': None}[status]
            record = datetime.combine(d, datetime.min.time()) + timedelta(hours=rnd.randint(8, 18),
                                                                          minutes=rnd.randint(0, 59))
            attendance_rows.append((aid, eid_, d, period, status, remark, record))
            aid += 1

    return {
        'start': start,
        'rows': {
            'college': college_rows, 'teacher': teacher_rows, 'major': major_rows,
            'classes': class_rows, 'course': course_rows, 'student': student_rows,
            'teaching_class': teaching_rows, 'enrollment': enrollment_rows,
            'score': score_rows, 'attendance': attendance_rows,
        },
        'ids': {
            'college': set(all_college_ids), 'teacher': set(all_teacher_ids),
            'major': set(all_major_ids), 'classes': set(all_class_ids),
            'course': set(all_course_ids), 'student': set(all_student_ids),
            'teaching_class': set(r[0] for r in teaching_rows),
            'enrollment': set(r[0] for r in enrollment_rows),
        },
    }


# ----------------------------------------------------------------------------
# 自校验（基于内存对象，生成前先跑，错误直接抛异常）
# ----------------------------------------------------------------------------
def verify(data):
    rows, ids = data['rows'], data['ids']
    errs = []

    def chk(table, idx, ref, nullable=False, label=''):
        bad = [r for r in rows[table] if (r[idx] is None and not nullable) or
               (r[idx] is not None and r[idx] not in ids[ref])]
        if bad:
            errs.append('%s.%s -> %s 有 %d 条无效引用，示例 %s' % (table, label or idx, ref, len(bad), bad[0][:3]))

    chk('teacher', 5, 'college', False, 'college_id')
    chk('major', 1, 'college', False, 'college_id')
    chk('classes', 1, 'major', False, 'major_id')
    chk('classes', 5, 'teacher', False, 'head_teacher_id')
    chk('student', 11, 'classes', False, 'class_id')
    chk('course', 3, 'college', True, 'college_id')
    chk('teaching_class', 1, 'course', False, 'course_id')
    chk('teaching_class', 2, 'teacher', False, 'teacher_id')
    chk('teaching_class', 3, 'classes', True, 'class_id')
    chk('enrollment', 1, 'student', False, 'student_id')
    chk('enrollment', 2, 'teaching_class', False, 'teaching_id')
    chk('score', 1, 'enrollment', False, 'enrollment_id')
    chk('attendance', 1, 'enrollment', False, 'enrollment_id')

    def uniq(table, key, label):
        vals = [key(r) for r in rows[table]]
        if len(vals) != len(set(vals)):
            errs.append('%s 唯一键 %s 重复 %d 条' % (table, label, len(vals) - len(set(vals))))

    uniq('student', lambda r: r[1], 'student_no')
    uniq('student', lambda r: r[5], 'id_card')
    uniq('teacher', lambda r: r[1], 'teacher_no')
    uniq('course', lambda r: r[1], 'course_no')
    uniq('major', lambda r: r[2], 'major_code')
    uniq('classes', lambda r: r[2], 'class_code')
    uniq('college', lambda r: r[1], 'college_code')
    uniq('enrollment', lambda r: (r[1], r[2]), 'student_id+teaching_id')
    uniq('score', lambda r: r[1], 'enrollment_id')
    uniq('attendance', lambda r: (r[1], r[2], r[3]), 'enrollment_id+date+period')
    for t in rows:
        uniq(t, lambda r, i=0: r[i], 'primary key')

    for r in rows['score']:
        expect = q1(Decimal(str(r[2])) * Decimal('0.3') + Decimal(str(r[3])) * Decimal('0.7'))
        if Decimal(str(r[4])) != expect:
            errs.append('score 总评公式错误: %s' % (r[:5],))
        if r[6] != (1 if Decimal(str(r[4])) >= 60 else 0):
            errs.append('score is_pass 错误: %s' % (r[:7],))
        if r[5] != grade_point(r[4]):
            errs.append('score 绩点错误: %s' % (r[:6],))
        if not (0 <= Decimal(str(r[2])) <= 100 and 0 <= Decimal(str(r[3])) <= 100):
            errs.append('score 分数越界: %s' % (r[:4],))

    # 业务规则：退选 / 开课中的选课不应有成绩
    enroll_status = {r[0]: (r[4], r[2]) for r in rows['enrollment']}
    teaching_status = {r[0]: r[9] for r in rows['teaching_class']}
    for r in rows['score']:
        estatus, tid = enroll_status[r[1]]
        if estatus != '已选' or teaching_status[tid] != '结课':
            errs.append('score 关联到退选或未结课的选课: %s' % (r[:2],))

    if errs:
        print('===== 自校验未通过 =====')
        for e in errs[:20]:
            print('  [X]', e)
        raise SystemExit(1)
    return True


# ----------------------------------------------------------------------------
# 输出 SQL
# ----------------------------------------------------------------------------
COLS = {
    'college': ['college_id', 'college_code', 'college_name', 'dean_name', 'office_phone'],
    'teacher': ['teacher_id', 'teacher_no', 'name', 'gender', 'birth_date', 'college_id',
                'title', 'education', 'phone', 'email', 'hire_date', 'status'],
    'major': ['major_id', 'college_id', 'major_code', 'major_name', 'duration_years',
              'degree_type', 'is_active'],
    'classes': ['class_id', 'major_id', 'class_code', 'class_name', 'grade', 'head_teacher_id'],
    'student': ['student_id', 'student_no', 'name', 'gender', 'birth_date', 'id_card',
                'nation', 'political_status', 'phone', 'email', 'home_address',
                'class_id', 'enroll_date', 'status'],
    'course': ['course_id', 'course_no', 'course_name', 'college_id', 'credit',
               'class_hours', 'course_type', 'description', 'is_active'],
    'teaching_class': ['teaching_id', 'course_id', 'teacher_id', 'class_id', 'academic_year',
                       'semester', 'classroom', 'schedule_time', 'capacity', 'status'],
    'enrollment': ['enrollment_id', 'student_id', 'teaching_id', 'select_type', 'status', 'select_time'],
    'score': ['score_id', 'enrollment_id', 'usual_score', 'exam_score', 'total_score',
              'grade_point', 'is_pass', 'exam_type', 'remark', 'input_time'],
    'attendance': ['attendance_id', 'enrollment_id', 'attend_date', 'period', 'status',
                   'remark', 'record_time'],
}


def write_sql(path, data, args):
    rows, start = data['rows'], data['start']
    total = sum(len(v) for v in rows.values())
    out = []
    out.append('-- =============================================================================')
    out.append('-- 学生管理系统 批量插入数据（由 gen_student_data.py 生成，请勿手工编辑）')
    out.append('-- 生成参数：students=%d  seed=%d  source=%s' %
               (args.students, args.seed, os.path.basename(args.source)))
    out.append('-- 新增行数：%d' % total)
    for t in DELETE_ORDER:
        out.append('--   %-16s %6d 行' % (t, len(rows[t])))
    out.append('--')
    out.append('-- 前置条件：已执行 student_management.sql（库 student_management 及 10 张表已存在）')
    out.append('-- 幂等说明：先按下方 ID 段逆序 DELETE 再插入，重复执行不会翻倍；')
    out.append('--             原有基础数据（ID 小于各段起点）不会被删除。')
    out.append('-- 导入命令：mysql -uroot -p --default-character-set=utf8mb4 < %s' % os.path.basename(path))
    out.append('-- 容器环境：docker exec -i mysql mysql -uroot -p000000 --default-character-set=utf8mb4 < %s' % os.path.basename(path))
    out.append('-- =============================================================================')
    out.append('')
    out.append('USE `student_management`;')
    out.append('SET NAMES utf8mb4;')
    out.append('')
    out.append('-- ---------- 幂等清理（逆序：先子表后父表） ----------')
    for t in DELETE_ORDER:
        out.append('DELETE FROM `%s` WHERE `%s` >= %d;' % (t, PK[t], start[t]))
    out.append('')
    out.append('-- ---------- 批量写入 ----------')
    for t in ['college', 'teacher', 'major', 'classes', 'course', 'student',
              'teaching_class', 'enrollment', 'score', 'attendance']:
        out.append('\n-- [%s] %d 行' % (t, len(rows[t])))
        out.append(render_insert(t, COLS[t], rows[t]))
    out.append('')
    out.append('-- ---------- 导入后验收：各表总行数 ----------')
    checks = []
    for t in ['college', 'major', 'classes', 'teacher', 'student', 'course',
              'teaching_class', 'enrollment', 'score', 'attendance']:
        checks.append("SELECT '%s' AS `表名`, COUNT(*) AS `总行数` FROM `%s`" % (t, t))
    out.append('\nUNION ALL\n'.join(checks) + ';')
    out.append('')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out))
    return total


def main():
    ap = argparse.ArgumentParser(description='学生管理系统批量数据生成器')
    ap.add_argument('--students', type=int, default=800, help='新增学生数（默认 800）')
    ap.add_argument('--seed', type=int, default=20261107, help='随机种子（默认 20261107）')
    ap.add_argument('--source', default=DEFAULT_SOURCE, help='建库脚本路径，用于避让已有编号')
    ap.add_argument('--out', default=DEFAULT_OUT, help='输出 SQL 路径')
    args = ap.parse_args()
    if args.students < 1 or args.students > 100000:
        ap.error('--students 需在 1..100000 之间')

    data = build(args)
    verify(data)
    total = write_sql(args.out, data, args)
    print('自校验通过：外键 / 唯一键 / 成绩公式 / 绩点 / 业务规则')
    print('输出文件：%s' % args.out)
    print('新增总行数：%d，文件大小：%.2f MB' % (total, os.path.getsize(args.out) / 1024 / 1024))
    for t in ['college', 'major', 'classes', 'teacher', 'course', 'student',
              'teaching_class', 'enrollment', 'score', 'attendance']:
        print('  %-16s %6d 行' % (t, len(data['rows'][t])))


if __name__ == '__main__':
    main()
