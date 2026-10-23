---
name: gemini-delegate
description: Use when 需要把任务委派给本机 Antigravity 里的 Gemini agent 执行——前端开发、用既有 skill 写文稿、或要一份跨模型的第二意见。触发词:"让 gemini 做X"/"交给 gemini"/"委派给 gemini"/"gemini 帮我写"/"gemini 帮我改"/"用 gemini 跑一下"。不用于 Claude 自己直接做更快的小任务。
argument-hint: "<任务描述 + 目标项目目录>"
allowed-tools: Bash, Read
---

# gemini-delegate — 把任务交给 Antigravity 的 Gemini

Google 已停掉 gemini CLI 的个人免费层(报 `UNSUPPORTED_CLIENT`)。可用的 Gemini agent 通道是 Antigravity 内置的 agentapi,由 [agy-bridge](https://github.com/codesfly/agy-bridge) 封装成 `agy-bridge` 命令。它是真 agent:会读写文件、执行命令、加载 skill。

## 调用

先跑一次 `agy-bridge doctor` 确认环境,然后:

```bash
agy-bridge --project-path <目标目录> [--model pro] [--timeout 300] "<任务>"
```

长任务用 `--prompt-file <文件>` 或 `--prompt-file -`(stdin),免得引号转义出错。

输出是 `KEY=VALUE` 行,重点看这几个:

| 键 | 含义 |
|---|---|
| `STATUS` | `completed` / `idle`(已停但没写完成信号)/ `error` / `timeout` |
| `REPORT` | Gemini 按约定写的说明与结论 |
| `REPLY` | Gemini 本轮最后一条回复 |
| `ERROR` | `STATUS=error` 时的错误原文 |
| `CONVERSATION_ID` | 超时后可用 `agy-bridge status <id>` 回头看 |

完整参数与退出码见 `agy-bridge --help`。

## 同一任务反复改 → 用 `--session`

```bash
agy-bridge --project-path ~/code/site --session landing "修复右下角越界"
agy-bridge --project-path ~/code/site --session landing "再把签名右移 40px"
```

Gemini 保留上下文,不必每次重读文件,实测续会话比新开快约 40%。`SESSION_MODE` 显示 `new` 还是 `resumed`。会话过长质量下降时用 `--new-session` 重开。

## 多个独立任务 → 并发发起

任务互不依赖时后台并行,实测 3 个任务串行 51s → 并发 21s。**同一 `--session` 不要并发**,消息会交错。

## 三条铁律

**1. 必须给足素材。** 缺上下文时 Gemini 会自信地编造,不会说"我不知道"。实测:带素材的任务事实零错误;只说"用一句话说明 X 是做什么的"那次,它编出了完全不存在的架构。任务里要带上事实、文件路径、约束条件。

**2. 调用前先 commit 或 stash。** 没有物理隔离,Gemini 直接改真实目录。工作区若有未提交改动,它的改动会和你的混在同一个 diff 里。

**3. 依赖 hook 强制的 skill 不要委派。** 有些 skill 的约束(例如"某段写完即不可改")是靠 Claude Code 的 hook 保证的。Antigravity 侧没有这套 hook,约束会静默失效。纯生成类 skill 不受影响,是合适的委派对象。

## 拿回结果

```bash
cat "$REPORT" "$REPLY"     # Gemini 写的说明、最后回复
git -C <目标目录> diff      # 实际改动
```

**改动必须由用户确认后才能合并或继续。** 没有隔离,唯一的护栏就是人工审 diff,不要代替用户判断。

## 常见错误

| 症状 | 原因与处理 |
|---|---|
| 退出码 2 | Antigravity 没开,启动它 |
| 退出码 4 | 目录未注册,在 Antigravity 里打开一次;`agy-bridge projects` 看已注册的 |
| 退出码 6 | 超时。agent 可能仍在跑,或在等 Antigravity 里批准命令;用 `agy-bridge status <id>` 查看 |
| 退出码 7 | agent 报错终止,看 `ERROR`。`User location is not supported` 是网络出口地区问题,换出口后重试 |
| `STATUS=idle` | agent 停了但没写完成信号,核对 `REPLY` 和 diff 再下结论 |
| 产出内容离谱 | 素材给少了,见铁律 1 |
| diff 里混着别人的改动 | 调用前没 commit/stash,见铁律 2 |
