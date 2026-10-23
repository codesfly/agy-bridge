# Changelog

## 0.2.0 — 2026-10-24

首个公开版本。

- 读 Antigravity 对话库(`conversations/<id>.db`)判断 agent 状态:报错时约 10 秒内以退出码 7 返回并带错误原文,不再干等到超时
- 新增 `STATUS=idle`:agent 已停但没写完成信号时也能结束等待
- 新增 `REPLY=`:取回 Gemini 本轮最后一条回复
- 新增子命令 `doctor` / `projects` / `status <conversation_id>`
- 新增 `--no-wait`、`--profile`、`--prompt-file -`(stdin)、`--version`
- `AGY_BIN` / `AGY_HOME` 可覆盖默认路径;经软链调用也能找到 `lib/`
- `.agy/` 自带 `.gitignore`,不污染目标仓库
- 完成信号改为写非空内容(`write_file` 拒绝空内容);契约禁止与任务无关的探索(实测一句话任务的工具调用 15 次降到 3 次)
- 校验 `--model` 与 `--timeout`
- 测试改用 fixture,不再依赖本机特定 project;新增对话库解析与等待逻辑测试

## 0.1.0 — 2026-09-10

内部版本:环境发现、project 解析、sentinel 轮询、`--session` 会话复用。
