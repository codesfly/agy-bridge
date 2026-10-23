#!/usr/bin/env python3
"""造一个最小的 Antigravity 对话库,供 run-tests.sh 测 agy_inspect.py。

用法: make_fixture_db.py <输出.db> <步骤...>
每个步骤形如 "类型:状态[:文本]",例如 15:3:你好 、17:3:boom 、132:8
文本按真实库的位置编码:回复在 payload.20.1,错误在 payload.24.3.2。
"""
import sqlite3
import sys


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field_varint(num, val):
    return varint(num << 3) + varint(val)


def field_bytes(num, data):
    return varint(num << 3 | 2) + varint(len(data)) + data


def payload(typ, status, text):
    body = field_varint(1, typ) + field_varint(4, status)
    if text:
        t = text.encode("utf-8")
        if typ == 15:
            body += field_bytes(20, field_bytes(1, t))
        elif typ == 17:
            body += field_bytes(24, field_bytes(3, field_bytes(2, t)))
    return body


def main(argv):
    db, specs = argv[1], argv[2:]
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer,"
                " status integer, step_payload blob)")
    for idx, spec in enumerate(specs):
        parts = spec.split(":", 2)
        typ, status = int(parts[0]), int(parts[1])
        text = parts[2] if len(parts) > 2 else ""
        con.execute("INSERT INTO steps VALUES (?,?,?,?)",
                    (idx, typ, status, payload(typ, status, text)))
    con.commit()
    con.close()


if __name__ == "__main__":
    main(sys.argv)
