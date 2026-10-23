# agy-bridge

[中文](README.md)

Hand a task to the **Gemini agent inside Antigravity** from the command line (or from an agent such as Claude Code or Codex), wait for it to finish, and get the result back.

Google has shut down the personal free tier of the gemini CLI (`IneligibleTierError` / `UNSUPPORTED_CLIENT`) and points users to Antigravity. Antigravity ships an undocumented `agentapi` command that can start conversations and send follow-up messages using your own Antigravity login and quota. agy-bridge wraps it in a script you can call directly:

- Discovers the running Antigravity's gRPC port, csrf token and version (they change on every restart)
- Maps a directory path to Antigravity's project id
- Starts the task, waits for it, and returns Gemini's report and final reply
- Exits immediately with the original error when the agent fails, instead of waiting for the timeout
- `--session` resumes a conversation so Gemini keeps its context

> **Unofficial.** `agentapi` is a private Antigravity interface. Everything here was reverse-engineered and may break with any Antigravity update. This project is not affiliated with Google.

## Requirements

- macOS (only tested there; elsewhere point `AGY_BIN` at `language_server`, untested)
- Antigravity installed, signed in, and **running**
- `jq`, `lsof`, `pgrep`
- `python3` (optional, standard library only). Needed for failure detection and reply extraction; without it the bridge relies on the completion file alone.

## Install

```bash
git clone https://github.com/codesfly/agy-bridge.git
cd agy-bridge
ln -s "$PWD/agy-bridge.sh" ~/.local/bin/agy-bridge   # any directory on your PATH
agy-bridge doctor
```

The target directory must be a project Antigravity knows about. Opening it once in Antigravity registers it; `agy-bridge projects` lists registered directories.

## Usage

```bash
agy-bridge --project-path ~/code/my-app "Add a dark mode toggle to the settings page and list the files you changed"
```

Output is `KEY=VALUE` lines:

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

`REPORT` is written by Gemini as instructed, `REPLY` is its last message extracted from the conversation database, and `SENTINEL` is the completion signal. Review the actual changes with `git diff`.

Options: `--model flash_lite|flash|pro` (default `pro`), `--timeout <sec>` (default 300), `--prompt-file <file|->`, `--session <name>`, `--new-session`, `--no-wait`, `--profile <name>`. See `agy-bridge --help`.

Subcommands: `doctor`, `projects`, `status <conversation_id>`.

Exit codes: 0 done, 1 usage, 2 Antigravity not running, 3 discovery failed, 4 project not registered, 5 agentapi call failed, 6 timeout, 7 agent failed (`ERROR=` holds the message).

Don't run the same `--session` concurrently; messages will interleave. Independent tasks can run in parallel.

## Use from Claude Code / Codex

The repo includes a skill, [`skills/gemini-delegate`](skills/gemini-delegate/SKILL.md) (written in Chinese). Symlink it into `~/.claude/skills/` or `~/.codex/skills/`. It calls `agy-bridge` from your PATH.

## Caveats

- **No isolation.** Gemini edits your real directory. Commit or stash first, review with `git diff`.
- **Give it context.** When information is missing, Gemini tends to make things up confidently.
- **Command approval.** If the project's policy requires approving commands in the Antigravity UI, the bridge waits until the timeout.
- **`.agy/`** stays in the target directory with its own `.gitignore`.
- **Region restrictions.** If your network exit is in a region Google doesn't support, you get `User location is not supported for the API use` and exit code 7.

How it works: [docs/how-it-works.md](docs/how-it-works.md) (Chinese).

## License

[MIT](LICENSE)
