#!/usr/bin/env bash
# agy-bridge —— 经 Antigravity agentapi 把任务委派给 Gemini agent。
# 目标 shell: bash 3.2(macOS 自带)。禁用 bash 4+ 特性。
set -uo pipefail

AGY_BRIDGE_VERSION="0.2.0"

# ---------- 路径 ----------

# 解析脚本真实位置(可能经软链装进 PATH),以找到同仓库的 lib/。
# macOS 自带 readlink 不保证有 -f,手动逐级解析。
script_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" && pwd
}

AGY_BIN="${AGY_BIN:-/Applications/Antigravity.app/Contents/Resources/bin/language_server}"
AGY_HOME="${AGY_HOME:-$HOME/.gemini}"
PROJECTS_DIR="$AGY_HOME/config/projects"
CONVERSATIONS_DIR="$AGY_HOME/antigravity/conversations"
INSPECT="$(script_dir)/lib/agy_inspect.py"
POLL_INTERVAL="${AGY_POLL_INTERVAL:-3}"

# ---------- 纯解析函数(可单测) ----------

# 从 ps 命令行中提取旗标值。兼容 "--flag value" 与 "--flag=value"。
parse_flag_value() {
  local ps_line="$1" flag="$2" v
  v=$(printf '%s' "$ps_line" | grep -oE -- "--${flag}=[^ ]+" | head -1 | cut -d= -f2-)
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  v=$(printf '%s' "$ps_line" | grep -oE -- "--${flag} [^ ]+" | head -1 | awk '{print $2}')
  printf '%s' "$v"
}

# 从 project json 提取 folderUri,兼容两种结构。
extract_folder_uri() {
  printf '%s' "$1" | jq -r '.projectResources.resources[0] // {} | (.folderUri // .gitFolder.folderUri // "")' 2>/dev/null
}

# file:///a/b -> /a/b
uri_to_path() {
  printf '%s' "${1#file://}"
}

# ---------- 环境发现 ----------

# 找 language_server 的 PID。
# 注意:不能直接取 pgrep 的第一个结果 —— 并发调用时,各 pgrep 进程自己的命令行
# 也含有搜索串,会互相匹配,真身可能排在末位。必须逐个验证候选是否带 --csrf_token。
discover_ls_pid() {
  local pid
  for pid in $(pgrep -f "language_server --standalone" 2>/dev/null); do
    if ps -ww -p "$pid" -o command= 2>/dev/null | grep -q -- "--csrf_token"; then
      printf '%s' "$pid"
      return 0
    fi
  done
  return 1
}

# 列出该 PID 所有 LISTEN 端口,降序(gRPC 经验上是较大者)
discover_ls_ports() {
  lsof -nP -iTCP -sTCP:LISTEN -a -p "$1" 2>/dev/null \
    | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2 | sort -rn | uniq
}

# 以发现到的环境调用 agentapi。第一个参数是 project_id,其余透传。
agentapi() {
  local project_id="$1"
  shift
  ANTIGRAVITY_LS_ADDRESS="127.0.0.1:$AGY_PORT" \
  ANTIGRAVITY_CSRF_TOKEN="$AGY_CSRF" \
  ANTIGRAVITY_LS_VERSION="$AGY_VER" \
  ANTIGRAVITY_PROJECT_ID="$project_id" \
    "$AGY_BIN" agentapi "$@" </dev/null 2>&1
}

# 只读探针:查一个必然不存在的 conversation,无副作用。
# 实测两种返回:
#   端口对: "code = Unknown desc = trajectory not found: 000..."   <- 业务错误
#   端口错: "code = Unavailable desc = connection error: ... server preface: EOF"
# 故判据为:命中 Unavailable/connection error/server preface 即非 gRPC 口。
probe_grpc_port() {
  local out zero="00000000-0000-0000-0000-000000000000"
  out=$(AGY_PORT="$1" agentapi "$zero" get-conversation-metadata "$zero")
  case "$out" in
    *"server preface"*|*"connection error"*|*"Unavailable"*) return 1 ;;
  esac
  return 0
}

discover_env() {
  AGY_PID=$(discover_ls_pid) || return 2
  local ps_line
  ps_line=$(ps -ww -p "$AGY_PID" -o command= 2>/dev/null)
  AGY_CSRF=$(parse_flag_value "$ps_line" csrf_token)
  AGY_VER=$(parse_flag_value "$ps_line" override_ide_version)
  [ -n "$AGY_CSRF" ] && [ -n "$AGY_VER" ] || return 3

  local p
  AGY_PORT=""
  for p in $(discover_ls_ports "$AGY_PID"); do
    if probe_grpc_port "$p"; then
      AGY_PORT="$p"
      break
    fi
  done
  [ -n "$AGY_PORT" ] || return 3
  return 0
}

# 统一的前置检查,失败时打印原因并返回对应退出码。
require_env() {
  if [ ! -x "$AGY_BIN" ]; then
    printf '找不到 language_server: %s\n可用 AGY_BIN 环境变量指定路径。\n' "$AGY_BIN" >&2
    return 2
  fi
  if ! discover_ls_pid >/dev/null; then
    printf 'Antigravity 未运行。请先启动 Antigravity 再重试。\n' >&2
    return 2
  fi
  if ! discover_env; then
    printf '环境发现失败:无法确定 csrf_token / 版本 / gRPC 端口。\n' >&2
    printf 'Antigravity 可能刚启动尚未就绪,或版本变更导致参数不兼容。\n' >&2
    return 3
  fi
}

# ---------- project 解析 ----------

# 输出 "<uuid>\t<name>\t<path>",每个已注册 project 一行。
list_projects() {
  local f uri
  for f in "$PROJECTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    uri=$(extract_folder_uri "$(cat "$f")")
    [ -n "$uri" ] || continue
    printf '%s\t%s\t%s\n' "$(jq -r '.id' < "$f")" "$(jq -r '.name // ""' < "$f")" "$(uri_to_path "$uri")"
  done
}

# 由绝对路径反查 project UUID。
resolve_project_id() {
  local target id name path
  target=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while IFS="$(printf '\t')" read -r id name path; do
    if [ -n "$path" ] && [ "$path" = "$target" ]; then
      printf '%s' "$id"
      return 0
    fi
  done <<EOF
$(list_projects)
EOF
  return 1
}

# ---------- 对话库 ----------
# 对话正文存于 $CONVERSATIONS_DIR/<conversation_id>.db(SQLite)。
# 读它可以判断 agent 是否已停止、是否出错,并取回最终回复。
# 读不到(无 python3、老版本只有 .pb)时退化为只看 sentinel。

conversation_db() {
  printf '%s/%s.db' "$CONVERSATIONS_DIR" "$1"
}

have_inspect() {
  [ -f "$INSPECT" ] && command -v python3 >/dev/null 2>&1
}

inspect() {
  have_inspect || return 1
  python3 -I "$INSPECT" "$@" 2>/dev/null
}

# 当前步数;库不存在时为 0。
step_count() {
  local n
  n=$(inspect count "$(conversation_db "$1")") || n=0
  printf '%s' "${n:-0}"
}

# ---------- 执行层 ----------

make_task_id() {
  printf 'agy-%s-%s' "$(date -u +%s)" "$RANDOM"
}

# 在用户 prompt 后追加契约段落(sentinel / 报告 / 边界)。
# sentinel 要求写入非空内容:Antigravity 的 write_file 拒绝空内容,
# 让它建空文件会先失败一次再改用 touch。
build_prompt() {
  local user_prompt="$1" task_id="$2" workspace="$3"
  cat <<PROMPT_END
$user_prompt

---
【执行契约 —— 必须遵守】
1. 工作目录严格限定在 $workspace 内,不得离开。
2. 任务说明与结论写入 .agy/$task_id.md
3. 全部完成后,最后一步创建文件 .agy/$task_id.done,内容写一行 done,作为完成信号。
   该文件必须最后创建,它一出现就代表你已完成全部工作。
4. 不要执行 git commit 或 git add。
5. 不做与任务无关的探索:不读 .agy/ 下其它任务的文件,不查看进程或系统信息。
PROMPT_END
}

# .agy/ 放进目标目录;自带 .gitignore,不污染目标仓库的 git status。
prepare_agy_dir() {
  mkdir -p "$1/.agy"
  [ -f "$1/.agy/.gitignore" ] || printf '*\n' > "$1/.agy/.gitignore"
}

# 发起会话,输出 conversationId。
start_conversation() {
  local project_id="$1" model="$2" title="$3" profile="$4" prompt="$5" out err cid
  if [ -n "$profile" ]; then
    out=$(agentapi "$project_id" new-conversation \
          --model="$model" --title="$title" --profile="$profile" "$prompt")
  else
    out=$(agentapi "$project_id" new-conversation \
          --model="$model" --title="$title" "$prompt")
  fi
  err=$(printf '%s' "$out" | jq -r '.error // ""' 2>/dev/null)
  if [ -n "$err" ]; then
    printf 'agentapi 返回错误: %s\n' "$err" >&2
    return 1
  fi
  cid=$(printf '%s' "$out" | jq -r '.response.newConversation.conversationId // ""' 2>/dev/null)
  if [ -z "$cid" ]; then
    printf '无法解析 conversationId,原始输出: %s\n' "$out" >&2
    return 1
  fi
  printf '%s' "$cid"
}

# ---------- 会话复用 ----------
# 会话 id 按 <workspace>/.agy/sessions/<名字>.id 存放,使同一任务可持续追加消息,
# Gemini 保留上下文(实测能回忆同会话早前创建的文件),且比新开会话更快。

session_file() {
  printf '%s/.agy/sessions/%s.id' "$1" "$2"
}

load_session_id() {
  local f
  f=$(session_file "$1" "$2")
  [ -f "$f" ] && cat "$f"
}

save_session_id() {
  local f
  f=$(session_file "$1" "$2")
  mkdir -p "$(dirname "$f")"
  printf '%s' "$3" > "$f"
}

# 向已有会话追发消息。
send_message() {
  local cid="$1" content="$2" project_id="$3" out err
  out=$(agentapi "$project_id" send-message "$cid" "$content")
  err=$(printf '%s' "$out" | jq -r '.error // ""' 2>/dev/null)
  if [ -n "$err" ]; then
    printf 'send-message 失败: %s\n' "$err" >&2
    return 1
  fi
}

# ---------- 等待 ----------

# 等待任务结束。设置 WAIT_STATUS 与 WAIT_DETAIL:
#   completed —— sentinel 出现
#   idle      —— agent 已停止但没写 sentinel(连续两次读到)
#   error     —— agent 因错误终止(连续两次读到)
#   timeout   —— 超时
# since 是本轮消息之前的步数,只看本轮新增的步。
wait_done() {
  local sentinel="$1" timeout="$2" db="$3" since="$4"
  local waited=0 out state last="" detail
  WAIT_STATUS="timeout"
  WAIT_DETAIL=""
  while [ "$waited" -lt "$timeout" ]; do
    if [ -f "$sentinel" ]; then
      WAIT_STATUS="completed"
      return 0
    fi
    if out=$(inspect state "$db" --since "$since"); then
      state=$(printf '%s\n' "$out" | sed -n 's/^state=//p')
      detail=$(printf '%s\n' "$out" | sed -n 's/^detail=//p')
      case "$state" in
        idle|error)
          if [ "$state" = "$last" ]; then
            # 再看一眼 sentinel:它可能恰好在两次轮询之间落盘
            if [ -f "$sentinel" ]; then
              WAIT_STATUS="completed"
              return 0
            fi
            WAIT_STATUS="$state"
            WAIT_DETAIL="$detail"
            return 0
          fi
          ;;
      esac
      last="$state"
    fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  return 1
}

# sentinel 出现时 agent 往往还差一条收尾回复没写完。最多再等 max 秒让它进入 idle,
# 以便取回完整的最后回复。
settle() {
  local db="$1" since="$2" max="$3" waited=0
  have_inspect || return 0
  while [ "$waited" -lt "$max" ]; do
    inspect state "$db" --since "$since" | grep -qx 'state=idle' && return 0
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
}

# 把本轮最后一条模型回复写入文件,成功则输出路径。
save_reply() {
  local db="$1" since="$2" out="$3" text
  text=$(inspect reply "$db" --since "$since") || return 1
  [ -n "$text" ] || return 1
  printf '%s\n' "$text" > "$out"
  printf '%s' "$out"
}

# ---------- 子命令 ----------

cmd_doctor() {
  local ok=0 dep n
  printf 'agy-bridge %s\n' "$AGY_BRIDGE_VERSION"
  for dep in jq lsof pgrep; do
    if command -v "$dep" >/dev/null 2>&1; then
      printf '  ✓ %s\n' "$dep"
    else
      printf '  ✗ 缺少 %s\n' "$dep"
      ok=1
    fi
  done
  if have_inspect; then
    printf '  ✓ python3(启用对话库检测:出错快速失败、取回回复)\n'
  else
    printf '  ⊘ 无 python3,只靠 sentinel 判断完成\n'
  fi
  if [ ! -x "$AGY_BIN" ]; then
    printf '  ✗ 找不到 language_server: %s(可设 AGY_BIN)\n' "$AGY_BIN"
    return 2
  fi
  printf '  ✓ language_server: %s\n' "$AGY_BIN"
  require_env || return $?
  printf '  ✓ Antigravity 运行中: pid=%s 版本=%s gRPC 端口=%s\n' "$AGY_PID" "$AGY_VER" "$AGY_PORT"
  n=$(list_projects | grep -c . || true)
  printf '  ✓ 已注册 project %s 个(agy-bridge.sh projects 查看)\n' "$n"
  return "$ok"
}

cmd_projects() {
  if [ ! -d "$PROJECTS_DIR" ]; then
    printf '未找到 %s\n' "$PROJECTS_DIR" >&2
    return 4
  fi
  list_projects | while IFS="$(printf '\t')" read -r _ name path; do
    printf '%-28s %s\n' "$name" "$path"
  done
}

# 查看某个会话现在的状态和最后一条回复(用于超时后回头看)。
cmd_status() {
  local cid="${1:-}" db out
  [ -n "$cid" ] || { printf '用法: agy-bridge.sh status <conversation_id>\n' >&2; return 1; }
  db=$(conversation_db "$cid")
  [ -f "$db" ] || { printf '找不到对话库: %s\n' "$db" >&2; return 5; }
  have_inspect || { printf '需要 python3 才能读取对话库。\n' >&2; return 1; }
  out=$(inspect state "$db") || return 5
  printf '%s\n' "$out" | sed 's/^state=/STATE=/; s/^steps=/STEPS=/; s/^detail=/DETAIL=/'
  printf -- '--- 最后一条回复 ---\n'
  inspect reply "$db" || printf '(暂无)\n'
}

usage() {
  cat <<'USAGE'
用法:
  agy-bridge.sh --project-path <目录> [选项] <prompt>   委派任务
  agy-bridge.sh doctor                                   检查环境
  agy-bridge.sh projects                                 列出已注册 project
  agy-bridge.sh status <conversation_id>                 查看会话状态与最后回复

委派选项:
  --project-path <目录>   目标 project 目录(须已在 Antigravity 中注册)
  --model <名称>          flash_lite | flash | pro   (默认 pro)
  --timeout <秒>          等待完成的上限            (默认 300)
  --title <标题>          会话标题                  (默认 "agy-bridge")
  --profile <名称>        透传 agentapi 的 --profile
  --prompt-file <文件>    从文件读取 prompt,"-" 表示 stdin(与位置参数二选一)
  --session <名字>        复用同名会话(Gemini 保留上下文，更快)。
                          首次自动新建，之后自动续接。
  --new-session           强制为该 session 重开一个新会话
  --no-wait               发起后立即返回,不等待
  -h, --help              显示本帮助
  -V, --version           显示版本

输出(stdout,KEY=VALUE):
  TASK_ID / SESSION_MODE / CONVERSATION_ID / WORKSPACE / REPORT / SENTINEL
  STATUS=completed|idle|error|timeout|started
  REPLY=<文件>    Gemini 本轮最后一条回复(读得到对话库时)
  ERROR=<信息>    STATUS=error 时的错误原文

退出码:
  0 完成(completed 或 idle)   1 用法错误   2 Antigravity 未运行
  3 环境发现失败   4 project 未注册   5 调用失败   6 超时   7 agent 报错终止

环境变量:
  AGY_BIN   language_server 路径(默认 macOS 安装位置)
  AGY_HOME  Antigravity 配置目录(默认 ~/.gemini)
USAGE
}

cmd_run() {
  local project_path="" model="pro" timeout=300 title="agy-bridge" profile=""
  local prompt="" prompt_file="" session="" new_session=0 no_wait=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --project-path) project_path="${2:-}"; shift 2 ;;
      --model)        model="${2:-}";        shift 2 ;;
      --timeout)      timeout="${2:-}";      shift 2 ;;
      --title)        title="${2:-}";        shift 2 ;;
      --profile)      profile="${2:-}";      shift 2 ;;
      --prompt-file)  prompt_file="${2:-}";  shift 2 ;;
      --session)      session="${2:-}";      shift 2 ;;
      --new-session)  new_session=1;         shift ;;
      --no-wait)      no_wait=1;             shift ;;
      -h|--help)      usage; return 0 ;;
      -V|--version)   printf 'agy-bridge %s\n' "$AGY_BRIDGE_VERSION"; return 0 ;;
      -*)             printf '未知选项: %s\n' "$1" >&2; usage >&2; return 1 ;;
      *)              prompt="$1"; shift ;;
    esac
  done

  if [ "$prompt_file" = "-" ]; then
    prompt=$(cat)
  elif [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] || { printf 'prompt 文件不存在: %s\n' "$prompt_file" >&2; return 1; }
    prompt=$(cat "$prompt_file")
  fi
  if [ -z "$project_path" ] || [ -z "$prompt" ]; then
    usage >&2
    return 1
  fi
  case "$timeout" in
    ''|*[!0-9]*) printf '%s\n' "--timeout 须为正整数秒: $timeout" >&2; return 1 ;;
  esac
  case "$model" in
    flash_lite|flash|pro) ;;
    *) printf '未知模型: %s(可选 flash_lite|flash|pro)\n' "$model" >&2; return 1 ;;
  esac
  [ -d "$project_path" ] || { printf '目录不存在: %s\n' "$project_path" >&2; return 1; }

  require_env || return $?

  local project_id workspace
  project_id=$(resolve_project_id "$project_path")
  if [ -z "$project_id" ]; then
    printf '目录未注册为 Antigravity project: %s\n' "$project_path" >&2
    printf '请在 Antigravity 中打开该目录一次以完成注册,然后重试。\n' >&2
    return 4
  fi
  workspace=$(cd "$project_path" && pwd -P)

  local task_id sentinel report full_prompt cid=""
  task_id=$(make_task_id)
  sentinel="$workspace/.agy/$task_id.done"
  report="$workspace/.agy/$task_id.md"
  prepare_agy_dir "$workspace"
  full_prompt=$(build_prompt "$prompt" "$task_id" "$workspace")

  local mode="oneshot" since=0
  if [ -n "$session" ]; then
    [ "$new_session" -eq 1 ] || cid=$(load_session_id "$workspace" "$session")
    if [ -n "$cid" ]; then
      since=$(step_count "$cid")
      if send_message "$cid" "$full_prompt" "$project_id"; then
        mode="resumed"
      else
        printf '会话 %s 已失效,改开新会话。\n' "$cid" >&2
        cid=""
        since=0
      fi
    fi
    if [ -z "$cid" ]; then
      cid=$(start_conversation "$project_id" "$model" "$title" "$profile" "$full_prompt") || return 5
      save_session_id "$workspace" "$session" "$cid"
      mode="new"
    fi
  else
    cid=$(start_conversation "$project_id" "$model" "$title" "$profile" "$full_prompt") || return 5
  fi

  printf 'TASK_ID=%s\n' "$task_id"
  printf 'SESSION_MODE=%s\n' "$mode"
  printf 'CONVERSATION_ID=%s\n' "$cid"
  printf 'WORKSPACE=%s\n' "$workspace"
  printf 'REPORT=%s\n' "$report"
  printf 'SENTINEL=%s\n' "$sentinel"

  if [ "$no_wait" -eq 1 ]; then
    printf 'STATUS=started\n'
    return 0
  fi

  local db reply
  db=$(conversation_db "$cid")
  wait_done "$sentinel" "$timeout" "$db" "$since"
  [ "$WAIT_STATUS" = "completed" ] && settle "$db" "$since" 15
  printf 'STATUS=%s\n' "$WAIT_STATUS"
  if reply=$(save_reply "$db" "$since" "$workspace/.agy/$task_id.reply.md"); then
    printf 'REPLY=%s\n' "$reply"
  fi

  case "$WAIT_STATUS" in
    completed)
      return 0 ;;
    idle)
      printf 'agent 已停止但未写完成信号,请核对 REPORT / REPLY 与实际改动。\n' >&2
      return 0 ;;
    error)
      printf 'ERROR=%s\n' "$WAIT_DETAIL"
      printf 'agent 报错终止: %s\n' "$WAIT_DETAIL" >&2
      case "$WAIT_DETAIL" in
        *"location is not supported"*)
          printf 'Google 按网络出口所在地区拒绝了请求。检查 Antigravity 走的代理出口后重试。\n' >&2 ;;
      esac
      return 7 ;;
  esac
  printf '等待 %s 秒后仍未完成。agent 可能仍在运行,或在等你在 Antigravity 里批准命令。\n' "$timeout" >&2
  printf '稍后可用: agy-bridge.sh status %s\n' "$cid" >&2
  return 6
}

main() {
  case "${1:-}" in
    doctor)   shift; cmd_doctor "$@" ;;
    projects) shift; cmd_projects "$@" ;;
    status)   shift; cmd_status "$@" ;;
    *)        cmd_run "$@" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
