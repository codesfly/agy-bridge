# agy-bridge

[English](README.en.md)

从命令行(或 Claude Code、Codex 这类 agent)把任务交给 **Antigravity 里的 Gemini agent** 去做,做完把结果取回来。

Google 已停掉 gemini CLI 的个人免费层(报 `IneligibleTierError` / `UNSUPPORTED_CLIENT`),官方让迁到 Antigravity。Antigravity 安装包里带了一个没有文档的 `agentapi` 命令,可以用你自己的 Antigravity 登录和额度新开会话、续发消息。agy-bridge 把它包成一个能直接调用的脚本:

- 自动找到运行中的 Antigravity 的 gRPC 端口、csrf token 和版本号(每次重启都会变)
- 把目录路径换算成 Antigravity 的 project id
- 发起任务,等它完成,取回 Gemini 写的报告和最后一条回复
- agent 中途报错时立即退出并带上错误原文,不用干等到超时
- `--session` 续接同一会话,Gemini 保留上下文

> **非官方项目。** `agentapi` 是 Antigravity 的私有接口,参数全部靠逆向得到,随时可能在升级后失效。本项目与 Google 无关。

## 环境要求

- macOS(只在 macOS 上测过;其它平台可用 `AGY_BIN` 指定 `language_server` 路径,未验证)
- Antigravity 已安装、已登录,并且**正在运行**
- `jq`、`lsof`、`pgrep`
- `python3`(可选,只用标准库。有它才能做出错检测和取回回复;没有就只靠完成信号文件判断)

## 安装

```bash
git clone https://github.com/codesfly/agy-bridge.git
cd agy-bridge
ln -s "$PWD/agy-bridge.sh" ~/.local/bin/agy-bridge   # 任一在 PATH 里的目录都行
agy-bridge doctor
```

`doctor` 全部打勾就能用了:

```
agy-bridge 0.2.0
  ✓ jq
  ✓ lsof
  ✓ pgrep
  ✓ python3(启用对话库检测:出错快速失败、取回回复)
  ✓ language_server: /Applications/Antigravity.app/Contents/Resources/bin/language_server
  ✓ Antigravity 运行中: pid=16215 版本=2.25.0 gRPC 端口=55582
  ✓ 已注册 project 11 个(agy-bridge.sh projects 查看)
```

目标目录必须是 Antigravity 认识的 project。在 Antigravity 里打开一次该目录就会注册,`agy-bridge projects` 可以列出已注册的目录。

## 用法

```bash
agy-bridge --project-path ~/code/my-app "给设置页加一个深色模式开关,写完说明改了哪些文件"
```

输出是 `KEY=VALUE` 行,方便脚本或 agent 解析:

```
TASK_ID=agy-1792782386-14927
SESSION_MODE=oneshot
CONVERSATION_ID=283e6ed6-74b6-4747-926d-e6932ba2606b
WORKSPACE=/Users/me/code/my-app
REPORT=/Users/me/code/my-app/.agy/agy-1792782386-14927.md
SENTINEL=/Users/me/code/my-app/.agy/agy-1792782386-14927.done
STATUS=completed
REPLY=/Users/me/code/my-app/.agy/agy-1792782386-14927.reply.md
```

| 文件 | 内容 |
|---|---|
| `REPORT` | 按约定由 Gemini 写的任务说明与结论 |
| `REPLY` | 从对话库里取出的 Gemini 本轮最后一条回复 |
| `SENTINEL` | 完成信号,Gemini 做完最后一步创建 |

实际改动直接看 `git diff`。

### 常用选项

| 选项 | 说明 |
|---|---|
| `--model flash_lite\|flash\|pro` | 默认 `pro` |
| `--timeout <秒>` | 等待上限,默认 300 |
| `--prompt-file <文件>` | 从文件读任务,`-` 表示 stdin |
| `--session <名字>` | 复用同名会话,首次自动新建 |
| `--new-session` | 为该 session 强制开新会话 |
| `--no-wait` | 发起后立即返回 |
| `--profile <名称>` | 透传给 agentapi |

完整说明见 `agy-bridge --help`。

### 续接会话

同一件事反复改时,加 `--session`:

```bash
agy-bridge --project-path ~/code/my-app --session dark-mode "加深色模式开关"
agy-bridge --project-path ~/code/my-app --session dark-mode "开关挪到页面右上角"
```

会话 id 存在 `<目录>/.agy/sessions/<名字>.id`。Gemini 记得前面的对话,不用每次重新读代码,比新开会话快(实测 25s → 15s)。

**同一个 session 不要并发**,消息会交错。互不相关的任务可以并发发起(实测 3 个任务串行 51s,并发 21s)。

### 子命令

```bash
agy-bridge doctor                 # 检查环境
agy-bridge projects               # 列出已注册 project
agy-bridge status <会话id>        # 查看会话状态和最后一条回复(超时后回头看)
```

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 完成(`STATUS=completed`,或 agent 已停但没写完成信号的 `idle`) |
| 1 | 用法错误 |
| 2 | Antigravity 未运行 / 找不到 language_server |
| 3 | 环境发现失败(端口 / token / 版本) |
| 4 | 目录未注册为 Antigravity project |
| 5 | agentapi 调用失败 |
| 6 | 超时 |
| 7 | agent 报错终止,`ERROR=` 行是错误原文 |

## 给 Claude Code / Codex 用

仓库里带了一个 skill:[`skills/gemini-delegate`](skills/gemini-delegate/SKILL.md)。软链进去,agent 就知道什么时候、怎么把活交给 Gemini:

```bash
ln -s "$PWD/skills/gemini-delegate" ~/.claude/skills/gemini-delegate   # Claude Code
ln -s "$PWD/skills/gemini-delegate" ~/.codex/skills/gemini-delegate    # Codex
```

skill 里调用的是 PATH 里的 `agy-bridge`,先完成上面的安装步骤。

## 使用前要知道的

- **没有隔离。** Gemini 直接改你的真实目录。调用前先 commit 或 stash,事后用 `git diff` 审。
- **给足上下文。** 缺信息时 Gemini 倾向于自信地编,不会说不知道。任务里写清事实、路径和约束。
- **命令可能需要批准。** project 的命令执行策略由 Antigravity 设置决定。如果它在等你在 Antigravity 里点批准,bridge 会一直等到超时。
- **`.agy/` 留在目标目录里。** 它自带 `.gitignore`,不会出现在 `git status` 里。
- **地区限制。** 如果网络出口所在地区不被 Google 支持,会报 `User location is not supported for the API use`,bridge 以退出码 7 返回。
- **私有接口。** Antigravity 升级可能改端口规律、环境变量或命令集,出问题时 bridge 会给出明确的退出码,不会静默降级。

原理和逆向细节见 [docs/how-it-works.md](docs/how-it-works.md)。

## 测试

```bash
./test/run-tests.sh                      # 单元测试 + fixture;Antigravity 在跑时附带集成检查
shellcheck agy-bridge.sh
(cd test && shellcheck -x run-tests.sh)
```

## License

[MIT](LICENSE)
