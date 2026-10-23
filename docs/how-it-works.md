# 工作原理

以下内容是对 Antigravity 的逆向观察,不是官方文档。初版基于 Antigravity 2.12.2(2026-09),对话库部分基于 2.25.0(2026-10)。版本升级后可能不再成立。

## 1. 入口

```
/Applications/Antigravity.app/Contents/Resources/bin/language_server agentapi <command>
```

`~/.gemini/antigravity/bin/agentapi` 是一行 exec 转发到上面的 wrapper。

```
new-conversation [--model=<flash_lite|flash|pro>] [--title=<t>] [--profile=<p>] <prompt>
send-message [--title=<t>] <recipient_id> <content>
get-conversation-metadata <conversation_id>
```

`send-message` 不接受 `--model`。`--profile` 的合法取值没有探明。

## 2. 必需的环境变量

| 变量 | 取值来源 |
|---|---|
| `ANTIGRAVITY_LS_ADDRESS` | `127.0.0.1:<gRPC 端口>` |
| `ANTIGRAVITY_CSRF_TOKEN` | language_server 进程的 `--csrf_token` 参数 |
| `ANTIGRAVITY_LS_VERSION` | 进程的 `--override_ide_version` 参数 |
| `ANTIGRAVITY_PROJECT_ID` | project 的 UUID,见第 4 节 |

端口和 token 每次 Antigravity 重启都会变,所以每次调用都从 `ps` 和 `lsof` 现场读取。

## 3. 找 gRPC 端口

language_server 同时监听两个相邻端口,一个是 HTTPS,一个是 gRPC。连错端口报 `error reading server preface: EOF`。

经验上 gRPC 是较大的那个,但只靠经验不够稳。bridge 对每个端口发一个只读探针:查询一个全零的 conversation id。

- 端口对:返回业务错误 `trajectory not found`
- 端口错:返回 `Unavailable` / `connection error` / `server preface`

找 PID 时有一个只在并发下出现的坑:`pgrep -f "language_server --standalone"` 会匹配到其它并发 pgrep 进程自己的命令行,真正的进程可能排在最后。所以要逐个检查候选进程的命令行是否带 `--csrf_token`。

## 4. project id

- `~/.gemini/projects.json` 是"路径 → 短名"映射。短名**不是** project id,传进去会报 `file does not exist`。
- 真正的 id 是 `~/.gemini/config/projects/<uuid>.json` 的文件名(也是文件里的 `id` 字段)。

这个 JSON 有两种结构:

```jsonc
// 普通目录
"projectResources": { "resources": [{ "folderUri": "file:///..." }] },
"settings": { "fileAccessPolicy": "...", "autoExecutionPolicy": "...", "artifactReviewMode": "..." }

// git 目录
"projectResources": { "resources": [{ "gitFolder": { "folderUri": "file:///...", "allowWrite": true } }] },
"permissionGrants": { "permissionGrants": { "allow": ["command(git status)", "..."] } }
```

git 目录的 `permissionGrants.allow` 是在 IDE 里逐条批准后累积的命令白名单。bridge 不改这些文件,只读。

## 5. 判断任务结束

`new-conversation` 是异步的,立即返回 conversation id。`get-conversation-metadata` 只有元数据(工作区、创建时间、配置),没有运行状态,也没有回复正文。

bridge 用两路信号:

**完成信号文件。** 每条 prompt 末尾追加一段契约,要求 Gemini 最后一步创建 `.agy/<taskId>.done`。taskId 由 bridge 预先生成,因为 prompt 要在拿到 conversation id 之前写好。契约要求文件内容非空:Antigravity 的 `write_file` 工具拒绝空内容,要求建空文件会让它先失败一次再改用 `touch`。

**对话库。** 2.25.0 把每个会话存在 `~/.gemini/antigravity/conversations/<conversation_id>.db`(SQLite,WAL 模式;更早的会话是 `.pb`)。`steps` 表每行一步:

| 列 | 观察到的值 |
|---|---|
| `step_type` | 14 用户输入,15 模型回复,17 错误,101 追发的消息,132 工具调用 |
| `status` | 3 完成,4 失败,8 生成中 |
| `step_payload` | protobuf。回复正文在字段 `20.1`,错误信息在 `24.3.2` |

据此分类:

- 有 `status=8` 的步 → 运行中
- 最后一步是错误步(17)→ agent 已终止,取出错误原文
- 最后一步是已完成的模型回复(15/3)→ agent 停下来了,在等下一条消息
- 其它(比如工具调用刚结束、下一条回复还没开始)→ 运行中

工具调用失败(132/4)不算终止,agent 通常会换个办法继续。为了避开步与步之间的空档,停下或出错要连续两次轮询读到一样的结果才算数。续接会话时只看本轮新增的步(发消息前先记下步数)。

解析 protobuf 不需要 `.proto` 定义,[`lib/agy_inspect.py`](../lib/agy_inspect.py) 用几十行标准库代码按字段号读取。以只读模式打开数据库,不会干扰 Antigravity。

## 6. 实测记录

| 场景 | 结果 |
|---|---|
| 新会话写一个文件(2.12.2) | 8 秒 |
| 用既有 skill 写一份 60 秒口播稿(2.12.2,pro) | 57 秒,skill 被真实加载执行,约束全部遵守 |
| 3 个独立任务 | 串行 51 秒,并发 21 秒 |
| 续接会话 | 比新开快约 40%,能回忆同会话早前的内容 |
| 地区不支持时(2.25.0) | 以前干等到超时;现在约 10 秒返回错误原文 |

## 7. 没做的事

- 不做物理隔离(worktree / 沙盒)。委派任务的价值往往来自真实目录的上下文:依赖、配置、状态文件。审查和回滚交给 git。
- 不封装 MCP server。Gemini 本身就是完整的 agent,Bash 调用已经受调用方的权限系统约束。
- 不改 Antigravity 的任何配置文件。
- Antigravity 二进制里有 subagent 相关的符号,但 `agentapi` 没有暴露,新建的会话 `subagentSpec` 为 null。
