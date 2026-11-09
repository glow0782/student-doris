#!/bin/bash
# =============================================================
# 学生管理系统数仓分层 一键执行 + 验收
# =============================================================
set -u
SQL="$(cd "$(dirname "$0")" && pwd)/student_layers.sql"
LOG=/tmp/student_layers.log

if [ ! -f "$SQL" ]; then
    echo "找不到 $SQL"; exit 1
fi

echo "===== 1. 执行分层脚本（DWD / DWS / ADS 共 9 张表）====="
# 核心执行逻辑：把 SQL 文件直接喂给 doris-fe 容器
docker exec -i doris-fe mysql -h 127.0.0.1 -P 9030 -uroot -p000000 -D student_sync < "$SQL" > "$LOG" 2>&1
EXIT=$?

echo "  退出码 = $EXIT"
if [ "$EXIT" -ne 0 ] || grep -qiE "ERROR [0-9]+|Unknown column|Unknown table|doesn't exist|Can't|Exception" "$LOG"; then
    echo "  发现错误，日志前 40 行："
    grep -viE "Using a password" "$LOG" | head -40
    exit 1
fi
grep -viE "Using a password" "$LOG" | head -10

echo
echo "===== 2. 分层表行数验收 ====="
docker exec -i doris-fe mysql -h 127.0.0.1 -P 9030 -uroot -p000000 -D student_sync -N <<'SQL2' 2>/dev/null
SELECT 'DWD dwd_dim_student',           COUNT(*) FROM dwd_dim_student
UNION ALL SELECT 'DWD dwd_dim_course_teacher',  COUNT(*) FROM dwd_dim_course_teacher
UNION ALL SELECT 'DWD dwd_fact_student_score',  COUNT(*) FROM dwd_fact_student_score
UNION ALL SELECT 'DWS dws_class_course_summary', COUNT(*) FROM dws_class_course_summary
UNION ALL SELECT 'DWS dws_student_score_summary',COUNT(*) FROM dws_student_score_summary
UNION ALL SELECT 'DWS dws_teacher_stat',       COUNT(*) FROM dws_teacher_stat
UNION ALL SELECT 'ADS ads_college_dashboard',  COUNT(*) FROM ads_college_dashboard
UNION ALL SELECT 'ADS ads_class_score_ranking',COUNT(*) FROM ads_class_score_ranking
UNION ALL SELECT 'ADS ads_student_warning',    COUNT(*) FROM ads_student_warning;
SQL2

echo
echo "===== 3. 抽样核对 ====="
echo "[学院画像]"
docker exec -i doris-fe mysql -h 127.0.0.1 -P 9030 -uroot -p000000 -D student_sync -N -e \
  "SELECT college_name,student_cnt,male_cnt,female_cnt,male_female_ratio,fail_cnt FROM ads_college_dashboard ORDER BY college_id;" 2>/dev/null
echo "[学生排名 TOP5]"
docker exec -i doris-fe mysql -h 127.0.0.1 -P 9030 -uroot -p000000 -D student_sync -N -e \
  "SELECT student_name,class_name,total_score,avg_score,rank_no FROM dws_student_score_summary ORDER BY rank_no LIMIT 5;" 2>/dev/null
echo "[学业预警]"
docker exec -i doris-fe mysql -h 127.0.0.1 -P 9030 -uroot -p000000 -D student_sync -N -e \
  "SELECT student_name,fail_course_cnt,fail_credit,min_score,warning_level FROM ads_student_warning;" 2>/dev/null

echo
echo "完成。完整日志：$LOG"