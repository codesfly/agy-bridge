#!/usr/bin/env python3
"""读 Antigravity 对话库(<conversation_id>.db),判断 agent 状态并取回最终回复。

只用标准库。库是 SQLite,steps 表每行一步,step_payload 是 protobuf,
这里用最小的 wire format 解析器按字段号取值,不依赖 .proto 定义。

字段含义由逆向得到(Antigravity 2.25.0 实测),见 docs/how-it-works.md:
  step_type  14=用户输入  15=模型回复  17=错误  132=工具调用
  status      3=完成      4=失败       8=生成中

用法:
  agy_inspect.py state <db> [--since N]   输出 state=running|idle|error|unknown 等 KEY=VALUE
  agy_inspect.py reply <db> [--since N]   输出 since 之后最后一条模型回复正文
  agy_inspect.py count <db>               输出当前步数
"""
import sqlite3
import sys

STEP_USER, STEP_REPLY, STEP_ERROR, STEP_TOOL = 14, 15, 17, 132
STATUS_DONE, STATUS_FAILED, STATUS_RUNNING = 3, 4, 8


def _varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def parse(buf):
    """protobuf 消息 -> {字段号: [值, ...]}。length-delimited 字段保留 bytes。"""
    fields, i = {}, 0
    while i < len(buf):
        key, i = _varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            val, i = _varint(buf, i)
        elif wt == 1:
            val, i = buf[i:i + 8], i + 8
        elif wt == 2:
            n, i = _varint(buf, i)
            val, i = buf[i:i + n], i + n
        elif wt == 5:
            val, i = buf[i:i + 4], i + 4
        else:
            raise ValueError("unsupported wire type %d" % wt)
        fields.setdefault(num, []).append(val)
    return fields


def dig(buf, *path):
    """按字段号路径取第一个 bytes 值,取不到返回 None。"""
    for num in path:
        try:
            vals = parse(buf).get(num)
        except (ValueError, IndexError):
            return None
        if not vals or not isinstance(vals[0], (bytes, bytearray)):
            return None
        buf = vals[0]
    return buf


def _text(b):
    return b.decode("utf-8", "replace") if b else ""


def reply_text(payload):
    return _text(dig(payload, 20, 1))


def error_text(payload):
    return _text(dig(payload, 24, 3, 2) or dig(payload, 24, 3, 1))


def load_steps(db, since=0):
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
    try:
        return con.execute(
            "SELECT idx, step_type, status, step_payload FROM steps"
            " WHERE idx >= ? ORDER BY idx", (since,)).fetchall()
    finally:
        con.close()


def classify(steps):
    """返回 (state, detail)。

    idle  —— 最后一步是已完成的模型回复,agent 在等下一条消息
    error —— 最后一步是错误步,agent 已终止
    其余一律 running(含工具调用之间的空档、等待 IDE 里批准命令)。
    调用方应连续两次读到同一结论再采信,以避开步与步之间的竞态。
    """
    if not steps:
        return "running", ""
    if any(s[2] == STATUS_RUNNING for s in steps):
        return "running", ""
    _, typ, status, payload = steps[-1]
    if typ == STEP_ERROR:
        return "error", error_text(payload or b"")
    if typ == STEP_REPLY and status == STATUS_DONE:
        return "idle", ""
    return "running", ""


def main(argv):
    if len(argv) < 3 or argv[1] not in ("state", "reply", "count"):
        sys.stderr.write(__doc__)
        return 1
    cmd, db = argv[1], argv[2]
    since = int(argv[4]) if len(argv) > 4 and argv[3] == "--since" else 0
    try:
        if cmd == "count":
            con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
            try:
                print(con.execute("SELECT COUNT(*) FROM steps").fetchone()[0])
            finally:
                con.close()
            return 0
        steps = load_steps(db, since)
    except sqlite3.Error as e:
        if cmd == "state":
            print("state=unknown")
            print("detail=%s" % str(e).replace("\n", " "))
            return 0
        sys.stderr.write("读取对话库失败: %s\n" % e)
        return 2

    if cmd == "state":
        state, detail = classify(steps)
        print("state=%s" % state)
        print("steps=%d" % len(steps))
        if detail:
            print("detail=%s" % detail.replace("\n", " "))
        return 0

    for _, typ, _, payload in reversed(steps):
        if typ == STEP_REPLY and payload:
            text = reply_text(payload)
            if text:
                sys.stdout.write(text.rstrip("\n") + "\n")
                return 0
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
