#!/usr/bin/env bash
# agy-bridge 测试。纯 shell + python3 标准库;集成部分在 Antigravity 未运行时自动跳过。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$HERE/../agy-bridge.sh"
# shellcheck source=../agy-bridge.sh
source "$BRIDGE"

FAILED=0
PASSED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agy-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ✓ %s\n' "$name"
    PASSED=$((PASSED + 1))
  else
    printf '  ✗ %s\n    期望: [%s]\n    实际: [%s]\n' "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

ok() { "$@" >/dev/null 2>&1 && echo 0 || echo 1; }

echo "== parse_flag_value =="
PS_SAMPLE='/path/language_server --standalone --override_ide_version 2.12.2 --csrf_token abc123XYZ --host_bridge_url=http://127.0.0.1:63378 --enable_sidecars'
assert_eq "abc123XYZ" "$(parse_flag_value "$PS_SAMPLE" csrf_token)" "空格形式"
assert_eq "2.12.2" "$(parse_flag_value "$PS_SAMPLE" override_ide_version)" "空格形式(版本号)"
assert_eq "http://127.0.0.1:63378" "$(parse_flag_value "$PS_SAMPLE" host_bridge_url)" "等号形式"
assert_eq "" "$(parse_flag_value "$PS_SAMPLE" nonexistent_flag)" "无匹配返回空"

echo "== extract_folder_uri =="
JSON_PLAIN='{"id":"u1","projectResources":{"resources":[{"folderUri":"file:///Users/x/test"}]}}'
JSON_GIT='{"id":"u2","projectResources":{"resources":[{"gitFolder":{"folderUri":"file:///Users/x/repo","allowWrite":true}}]}}'
JSON_EMPTY='{"id":"u3","projectResources":{"resources":[]}}'
assert_eq "file:///Users/x/test" "$(extract_folder_uri "$JSON_PLAIN")" "普通 folderUri"
assert_eq "file:///Users/x/repo" "$(extract_folder_uri "$JSON_GIT")" "gitFolder 结构"
assert_eq "" "$(extract_folder_uri "$JSON_EMPTY")" "空 resources 返回空"

echo "== uri_to_path =="
assert_eq "/Users/x/repo" "$(uri_to_path "file:///Users/x/repo")" "去 file:// 前缀"
assert_eq "/Users/x/a b" "$(uri_to_path "file:///Users/x/a b")" "含空格路径"

echo "== discover_ls_ports 排序 =="
_ports_sorted() { printf '%s\n' "$@" | sort -rn | tr '\n' ' '; }
assert_eq "63385 63384 " "$(_ports_sorted 63384 63385)" "端口降序"

echo "== list_projects / resolve_project_id(fixture) =="
REAL_TMP=$(cd "$TMP" && pwd -P)
mkdir -p "$TMP/projects" "$TMP/plain" "$TMP/git repo"
printf '{"id":"p-plain","name":"plain","projectResources":{"resources":[{"folderUri":"file://%s/plain"}]}}' "$REAL_TMP" > "$TMP/projects/p-plain.json"
printf '{"id":"p-git","name":"gitrepo","projectResources":{"resources":[{"gitFolder":{"folderUri":"file://%s/git repo","allowWrite":true}}]}}' "$REAL_TMP" > "$TMP/projects/p-git.json"
printf '{"id":"p-empty","projectResources":{"resources":[]}}' > "$TMP/projects/p-empty.json"
SAVED_PROJECTS_DIR="$PROJECTS_DIR"
PROJECTS_DIR="$TMP/projects"
assert_eq "2" "$(list_projects | grep -c .)" "跳过无目录的 project"
assert_eq "p-plain" "$(resolve_project_id "$TMP/plain")" "普通结构"
assert_eq "p-git" "$(resolve_project_id "$TMP/git repo")" "gitFolder 结构 + 含空格路径"
assert_eq "" "$(resolve_project_id "$TMP")" "未注册路径返回空"
assert_eq "" "$(resolve_project_id /nonexistent/path/xyz)" "不存在路径返回空"
PROJECTS_DIR="$SAVED_PROJECTS_DIR"

echo "== make_task_id =="
TID=$(make_task_id)
assert_eq "0" "$(printf '%s' "$TID" | grep -qE '^agy-[0-9]+-[0-9]+$' && echo 0 || echo 1)" "taskId 格式"
assert_eq "0" "$([ "$(make_task_id)" != "$(make_task_id)" ] && echo 0 || echo 1)" "两次调用不重复"

echo "== build_prompt =="
BP=$(build_prompt "写一条稿子" "agy-123-456" "/Users/x/repo")
assert_eq "0" "$(printf '%s' "$BP" | grep -q "写一条稿子" && echo 0 || echo 1)" "保留原 prompt"
assert_eq "0" "$(printf '%s' "$BP" | grep -q ".agy/agy-123-456.done" && echo 0 || echo 1)" "含 sentinel 路径"
assert_eq "0" "$(printf '%s' "$BP" | grep -q ".agy/agy-123-456.md" && echo 0 || echo 1)" "含报告路径"
assert_eq "0" "$(printf '%s' "$BP" | grep -q "/Users/x/repo" && echo 0 || echo 1)" "含 workspace 边界"
assert_eq "0" "$(printf '%s' "$BP" | grep -q "内容写一行 done" && echo 0 || echo 1)" "sentinel 要求非空内容"

echo "== prepare_agy_dir =="
mkdir -p "$TMP/ws"
prepare_agy_dir "$TMP/ws"
assert_eq "*" "$(cat "$TMP/ws/.agy/.gitignore")" ".agy/ 自带 .gitignore"
printf 'keep\n' > "$TMP/ws/.agy/.gitignore"
prepare_agy_dir "$TMP/ws"
assert_eq "keep" "$(cat "$TMP/ws/.agy/.gitignore")" "不覆盖已有 .gitignore"

echo "== session 会话复用 =="
assert_eq "$TMP/ws/.agy/sessions/ep04.id" "$(session_file "$TMP/ws" ep04)" "session 文件路径"
assert_eq "" "$(load_session_id "$TMP/ws" nope)" "不存在的 session 返回空"
save_session_id "$TMP/ws" ep04 "abc-123-def"
assert_eq "abc-123-def" "$(load_session_id "$TMP/ws" ep04)" "存后可读回"
save_session_id "$TMP/ws" ep04 "xyz-999"
assert_eq "xyz-999" "$(load_session_id "$TMP/ws" ep04)" "可覆盖"

if have_inspect; then
  FIX="python3 -I $HERE/make_fixture_db.py"
  INS="python3 -I $INSPECT"

  echo "== agy_inspect.py =="
  $FIX "$TMP/idle.db" "14:3:问" "15:3:中途想法" "132:3" "15:3:最终回复 ✓"
  $FIX "$TMP/running.db" "14:3:问" "15:8"
  $FIX "$TMP/tool.db" "14:3:问" "15:3" "132:3"
  $FIX "$TMP/error.db" "14:3:问" "17:3:User location is not supported"
  $FIX "$TMP/failedtool.db" "14:3:问" "132:4" "15:3:换个办法完成了"
  assert_eq "state=idle" "$($INS state "$TMP/idle.db" | head -1)" "最后一步是已完成回复 → idle"
  assert_eq "state=running" "$($INS state "$TMP/running.db" | head -1)" "有生成中的步 → running"
  assert_eq "state=running" "$($INS state "$TMP/tool.db" | head -1)" "工具调用之后的空档 → running"
  assert_eq "state=error" "$($INS state "$TMP/error.db" | head -1)" "错误步 → error"
  assert_eq "detail=User location is not supported" "$($INS state "$TMP/error.db" | grep '^detail=')" "取出错误原文"
  assert_eq "state=idle" "$($INS state "$TMP/failedtool.db" | head -1)" "中途工具失败不算终止"
  assert_eq "最终回复 ✓" "$($INS reply "$TMP/idle.db")" "reply 取最后一条回复(含 UTF-8)"
  assert_eq "state=running" "$($INS state "$TMP/idle.db" --since 4 | head -1)" "--since 之后无新步 → running"
  assert_eq "4" "$($INS count "$TMP/idle.db")" "count"
  assert_eq "state=unknown" "$($INS state "$TMP/missing.db" | head -1)" "库不存在 → unknown"

  echo "== wait_done =="
  POLL_INTERVAL=1
  wait_done "$TMP/never.done" 10 "$TMP/idle.db" 0
  assert_eq "idle" "$WAIT_STATUS" "无 sentinel 但 agent 已停 → idle"
  wait_done "$TMP/never.done" 10 "$TMP/error.db" 0
  assert_eq "error|User location is not supported" "$WAIT_STATUS|$WAIT_DETAIL" "agent 报错 → 快速失败"
  touch "$TMP/ok.done"
  wait_done "$TMP/ok.done" 10 "$TMP/running.db" 0
  assert_eq "completed" "$WAIT_STATUS" "sentinel 优先"
  wait_done "$TMP/never.done" 2 "$TMP/running.db" 0
  assert_eq "timeout" "$WAIT_STATUS" "一直 running → 超时"
  wait_done "$TMP/never.done" 2 "$TMP/missing.db" 0
  assert_eq "timeout" "$WAIT_STATUS" "库不存在时只靠 sentinel"
  assert_eq "$TMP/r.md" "$(save_reply "$TMP/idle.db" 0 "$TMP/r.md")" "save_reply 返回路径"
  assert_eq "最终回复 ✓" "$(cat "$TMP/r.md")" "save_reply 写入内容"
  POLL_INTERVAL=3
else
  printf '  ⊘ 跳过 agy_inspect / wait_done:无 python3\n'
fi

echo "== CLI 参数校验 =="
mkdir -p "$TMP/cli"
assert_eq "1" "$(bash "$BRIDGE" >/dev/null 2>&1; echo $?)" "无参数 → 1"
assert_eq "1" "$(bash "$BRIDGE" --project-path "$TMP/cli" --model gpt "x" >/dev/null 2>&1; echo $?)" "未知模型 → 1"
assert_eq "1" "$(bash "$BRIDGE" --project-path "$TMP/cli" --timeout 3m "x" >/dev/null 2>&1; echo $?)" "非法超时 → 1"
assert_eq "1" "$(bash "$BRIDGE" --project-path "$TMP/nope" "x" >/dev/null 2>&1; echo $?)" "目录不存在 → 1"
assert_eq "0" "$(ok bash "$BRIDGE" --help)" "--help → 0"
assert_eq "agy-bridge $AGY_BRIDGE_VERSION" "$(bash "$BRIDGE" --version)" "--version"
ln -s "$BRIDGE" "$TMP/agy-bridge"
assert_eq "$(cd "$HERE/.." && pwd -P)/lib/agy_inspect.py" "$(bash -c "source '$TMP/agy-bridge'; printf '%s' \"\$INSPECT\"")" "经软链调用仍能找到 lib/"

echo "== 集成(需 Antigravity 运行) =="
if discover_ls_pid >/dev/null 2>&1; then
  if discover_env; then
    assert_eq "0" "$([ -n "${AGY_PORT:-}" ] && echo 0 || echo 1)" "发现 gRPC 端口"
    assert_eq "0" "$([ -n "${AGY_VER:-}" ] && echo 0 || echo 1)" "发现版本号"
    assert_eq "0" "$([ ${#AGY_CSRF} -gt 8 ] && echo 0 || echo 1)" "csrf_token 长度合理"
  else
    printf '  ✗ discover_env 返回失败\n'
    FAILED=$((FAILED + 1))
  fi
  for i in 1 2 3 4 5; do
    ( bash -c "source '$BRIDGE'; discover_ls_pid" > "$TMP/pid-$i.txt" 2>&1 ) &
  done
  wait
  BAD=0
  for i in 1 2 3 4 5; do
    P=$(cat "$TMP/pid-$i.txt" 2>/dev/null)
    if [ -z "$P" ] || ! ps -ww -p "$P" -o command= 2>/dev/null | grep -q -- "--csrf_token"; then
      BAD=$((BAD + 1))
    fi
  done
  assert_eq "0" "$BAD" "并发 5 次都拿到真正的 language_server PID"
  assert_eq "0" "$(ok bash "$BRIDGE" doctor)" "doctor 通过"
else
  printf '  ⊘ 跳过:Antigravity 未运行\n'
fi

printf '\n通过 %d,失败 %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
