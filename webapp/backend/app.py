# -*- coding: utf-8 -*-
"""
学生管理系统后端（Flask）—— 直接接入已有数仓链路，不新建任何库表

数据流：
  Vue 管理页 --CRUD--> Flask --写--> MySQL mysql:3306 / student_management.student
                                       |
                                       |  SeaTunnel CDC (student_sync.conf) 捕获 binlog
                                       v
                                   Doris doris-fe:9030 / student_sync.ods_student
                                       |
                                       |  DolphinScheduler 定时执行分层脚本
                                       v
                        dwd_dim_student / dws_* / ads_college_dashboard
                                       |
  Vue 大屏 --图表--> Flask --查--------+

  /api/chart/class   各班人数  <- student_sync.dwd_dim_student      （已有 DWD 明细层）
  /api/chart/gender  性别分布  <- student_sync.ads_college_dashboard （已有 ADS 应用层）

本项目不创建、不修改 student_management / student_sync 中任何库表；
也不自建 MySQL/Doris 数据库容器，所有读写都落在链路中已有的库表上。

接口：
  /api/health                健康检查（含当前连接的库名）
  /api/student/classes       班级下拉（classes 维表）
  /api/student/list          学生列表（分页 + keyword 模糊搜索）
  /api/student/add           新增学生
  /api/student/update/<id>   修改学生
  /api/student/delete/<id>   删除学生（enrollment 外键 CASCADE，会连带删选课记录）
  /api/chart/class           班级人数统计（Doris DWD）
  /api/chart/gender          性别分布统计（Doris ADS）
"""
import os
import re
from datetime import date

from flask import Flask, jsonify, request
from flask_cors import CORS
import pymysql
from pymysql.cursors import DictCursor

app = Flask(__name__)
# 允许前端跨域直连 8000；默认前端走 nginx 同源反代，两种用法都支持
CORS(app, resources={r"/api/*": {"origins": "*"}})

MYSQL_CONF = {
    "host": os.getenv("MYSQL_HOST", "mysql"),
    "port": int(os.getenv("MYSQL_PORT", "3306")),
    "user": os.getenv("MYSQL_USER", "root"),
    "password": os.getenv("MYSQL_PASSWORD", "000000"),
    "database": os.getenv("MYSQL_DB", "student_management"),
}
DORIS_CONF = {
    "host": os.getenv("DORIS_HOST", "doris-fe"),
    "port": int(os.getenv("DORIS_PORT", "9030")),
    "user": os.getenv("DORIS_USER", "root"),
    "password": os.getenv("DORIS_PASSWORD", "000000"),
    "database": os.getenv("DORIS_DB", "student_sync"),
}

# 允许写入 student_management.student 的字段白名单（防止拼 SQL 时越权/注入）
EDITABLE_FIELDS = (
    "student_no", "name", "gender", "birth_date", "id_card", "nation",
    "political_status", "phone", "email", "home_address", "class_id",
    "enroll_date", "status",
)
DATE_FIELDS = ("birth_date", "enroll_date")
GENDERS = ("男", "女")
STATUSES = ("在读", "休学", "毕业", "退学")

SELECT_SQL = (
    "SELECT s.student_id AS id, s.student_no, s.name, s.gender, "
    "       s.birth_date, s.phone, s.email, s.class_id, cl.class_name, "
    "       s.enroll_date, s.status, s.create_time, s.update_time "
    "FROM student s LEFT JOIN classes cl ON cl.class_id = s.class_id "
)


def connect(conf):
    """每次请求新建连接，避免长连接被 Doris FE / MySQL 断开"""
    return pymysql.connect(
        host=conf["host"], port=conf["port"],
        user=conf["user"], password=conf["password"],
        database=conf["database"], charset="utf8mb4",
        cursorclass=DictCursor, connect_timeout=8,
        read_timeout=20, write_timeout=20, autocommit=True,
    )


def ok(data=None, msg="ok"):
    return jsonify({"code": 0, "msg": msg, "data": data})


def fail(msg, status=500):
    return jsonify({"code": 1, "msg": str(msg), "data": None}), status


def serialize(row):
    """date / datetime / Decimal 统一转成 JSON 可序列化类型"""
    out = {}
    for k, v in row.items():
        if hasattr(v, "isoformat"):
            out[k] = v.isoformat(sep=" ") if hasattr(v, "hour") else v.isoformat()
        elif hasattr(v, "__float__") and not isinstance(v, (int, float, bool)):
            out[k] = float(v)
        else:
            out[k] = v
    return out


def validate_student(payload, require_all=True):
    """校验并规范化字段；require_all=False 用于增量修改"""
    data = {}
    for f in EDITABLE_FIELDS:
        if f in payload:
            v = payload[f]
            data[f] = v.strip() if isinstance(v, str) else v

    if require_all:
        for f in ("student_no", "name", "gender", "class_id"):
            if data.get(f) in (None, ""):
                raise ValueError("缺少必填字段: " + f)
        # enroll_date 在源表是 NOT NULL 且无默认值，新增时默认今天
        if not data.get("enroll_date"):
            data["enroll_date"] = date.today().isoformat()
        data.setdefault("status", "在读")

    if "gender" in data and data["gender"] not in GENDERS:
        raise ValueError("gender 只能是 男 / 女")
    if "status" in data and data["status"] not in STATUSES:
        raise ValueError("status 只能是 " + " / ".join(STATUSES))
    if "class_id" in data:
        if data["class_id"] in (None, ""):
            if require_all:
                raise ValueError("缺少必填字段: class_id")
            data.pop("class_id")
        else:
            try:
                data["class_id"] = int(data["class_id"])
            except (TypeError, ValueError):
                raise ValueError("class_id 必须是整数")
    for f in DATE_FIELDS:
        if f in data:
            v = data[f]
            if v in (None, ""):
                if f == "enroll_date":
                    raise ValueError("enroll_date 不能为空")
                data.pop(f)
            elif not re.match(r"^\d{4}-\d{2}-\d{2}$", str(v)):
                raise ValueError(f + " 格式应为 YYYY-MM-DD")
    return data


# ---------------------------------------------------------------- 健康检查
@app.get("/api/health")
def health():
    result = {
        "mysql": "unknown", "doris": "unknown",
        "mysql_db": MYSQL_CONF["database"],
        "doris_db": DORIS_CONF["database"],
        "chart_source": "student_sync.dwd_dim_student + student_sync.ads_college_dashboard",
    }
    for name, conf in (("mysql", MYSQL_CONF), ("doris", DORIS_CONF)):
        try:
            with connect(conf).cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
            result[name] = "ok"
        except Exception as e:
            result[name] = f"error: {e}"
    return ok(result)


# ---------------------------------------------------------------- 班级维表（MySQL）
@app.get("/api/student/classes")
def student_classes():
    try:
        conn = connect(MYSQL_CONF)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT class_id, class_name, class_code, grade "
                "FROM classes ORDER BY grade DESC, class_id"
            )
            rows = [serialize(r) for r in cur.fetchall()]
        conn.close()
        return ok({"list": rows, "total": len(rows)})
    except Exception as e:
        return fail(e)


# ---------------------------------------------------------------- 学生 CRUD（MySQL）
@app.get("/api/student/list")
def student_list():
    keyword = (request.args.get("keyword") or "").strip()
    try:
        page = max(1, int(request.args.get("page", 1)))
        size = min(200, max(1, int(request.args.get("size", 50))))
    except ValueError:
        return fail("page / size 必须是整数", 400)
    where, args = "", []
    if keyword:
        where = ("WHERE s.student_no LIKE %s OR s.name LIKE %s "
                 "OR cl.class_name LIKE %s OR cl.class_code LIKE %s")
        like = "%" + keyword + "%"
        args = [like, like, like, like]
    try:
        conn = connect(MYSQL_CONF)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM student s "
                "LEFT JOIN classes cl ON cl.class_id = s.class_id " + where, args
            )
            total = int(cur.fetchone()["cnt"])
            cur.execute(
                SELECT_SQL + where + " ORDER BY s.student_id LIMIT %s OFFSET %s",
                (*args, size, (page - 1) * size),
            )
            rows = [serialize(r) for r in cur.fetchall()]
        conn.close()
        return ok({"list": rows, "total": total, "page": page, "size": size})
    except Exception as e:
        return fail(e)


@app.post("/api/student/add")
def student_add():
    try:
        payload = request.get_json(force=True, silent=True) or {}
        d = validate_student(payload, require_all=True)
        conn = connect(MYSQL_CONF)
        with conn.cursor() as cur:
            # class_id 有外键约束，先确认班级存在，给出可读的报错
            cur.execute("SELECT class_name FROM classes WHERE class_id=%s", (d["class_id"],))
            cl = cur.fetchone()
            if not cl:
                conn.close()
                return fail("班级不存在: class_id=" + str(d["class_id"]), 400)
            cols = ", ".join(d.keys())
            marks = ", ".join(["%s"] * len(d))
            cur.execute(
                "INSERT INTO student (" + cols + ") VALUES (" + marks + ")",
                tuple(d.values()),
            )
            new_id = cur.lastrowid
            class_name = cl["class_name"]
        conn.close()
        return ok({"id": new_id, "class_name": class_name},
                  "已写入 student_management.student，CDC 将自动同步到 Doris")
    except pymysql.err.IntegrityError as e:
        return fail(f"学号/身份证号重复，或班级外键冲突: {e}", 400)
    except ValueError as e:
        return fail(e, 400)
    except Exception as e:
        return fail(e)


@app.put("/api/student/update/<int:sid>")
def student_update(sid):
    try:
        payload = request.get_json(force=True, silent=True) or {}
        d = validate_student(payload, require_all=False)
        if not d:
            return fail("没有可更新的字段", 400)
        conn = connect(MYSQL_CONF)
        with conn.cursor() as cur:
            if "class_id" in d:
                cur.execute("SELECT 1 FROM classes WHERE class_id=%s", (d["class_id"],))
                if not cur.fetchone():
                    conn.close()
                    return fail("班级不存在: class_id=" + str(d["class_id"]), 400)
            sets = ", ".join(f"{k}=%s" for k in d)
            cur.execute(
                "UPDATE student SET " + sets + " WHERE student_id=%s",
                (*d.values(), sid),
            )
            affected = cur.rowcount
        conn.close()
        return ok({"affected": affected}, "已修改，CDC 将把变更同步到 Doris")
    except pymysql.err.IntegrityError as e:
        return fail(f"学号/身份证号重复，或班级外键冲突: {e}", 400)
    except ValueError as e:
        return fail(e, 400)
    except Exception as e:
        return fail(e)


@app.delete("/api/student/delete/<int:sid>")
def student_delete(sid):
    try:
        conn = connect(MYSQL_CONF)
        with conn.cursor() as cur:
            cur.execute("DELETE FROM student WHERE student_id=%s", (sid,))
            affected = cur.rowcount
        conn.close()
        return ok({"affected": affected},
                  "已删除（enrollment 外键 CASCADE，该生选课记录会一并删除并由 CDC 同步）")
    except Exception as e:
        return fail(e)


# ---------------------------------------------------------------- 统计接口（Doris，已有表）
def chart_query(sql):
    conn = connect(DORIS_CONF)
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        items = [{"name": str(r["name"]), "value": int(r["value"])} for r in rows]
        return {
            "items": items,
            "categories": [i["name"] for i in items],
            "values": [i["value"] for i in items],
            "total": sum(i["value"] for i in items),
        }
    finally:
        conn.close()


@app.get("/api/chart/class")
def chart_class():
    """各班人数：读已有 DWD 明细宽表 dwd_dim_student（班级名已维度退化）"""
    try:
        return ok(chart_query(
            "SELECT class_name AS name, COUNT(*) AS value "
            "FROM student_sync.dwd_dim_student "
            "WHERE class_name IS NOT NULL AND class_name <> '' "
            "GROUP BY class_name ORDER BY value DESC, name"
        ))
    except Exception as e:
        return fail(e)


@app.get("/api/chart/gender")
def chart_gender():
    """性别分布：读已有 ADS 应用层 ads_college_dashboard，按学院汇总上卷到全校"""
    conn = connect(DORIS_CONF)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COALESCE(SUM(male_cnt),0)   AS m, "
                "       COALESCE(SUM(female_cnt),0) AS f, "
                "       COALESCE(SUM(student_cnt),0) AS t "
                "FROM student_sync.ads_college_dashboard"
            )
            r = cur.fetchone()
        items = [
            {"name": "男", "value": int(r["m"])},
            {"name": "女", "value": int(r["f"])},
        ]
        return ok({
            "items": items,
            "categories": [i["name"] for i in items],
            "values": [i["value"] for i in items],
            "total": sum(i["value"] for i in items),
        })
    except Exception as e:
        return fail(e)
    finally:
        conn.close()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=False, threaded=True)
