# Guide: a global guardrail against catastrophic commands, for AI agents on Windows (Claude Code + Git Bash)

**The problem this guide solves**: you let an AI agent (Claude Code or another) run shell commands on your Windows machine, sometimes autonomously. One day, by accident — a misread instruction, a badly built path, a hallucination — it will attempt something irreversible: `rm -rf /`, a `git push --force`, a `Remove-Item -Recurse` on the drive root. This guide installs a **global guardrail**: a list of catastrophic command patterns, checked by a hook *before every execution*, which blocks the command and tells the agent why.

**Verified working** configuration (Windows 11, Claude Code 2.1.x, Git for Windows, July 2026), including the end-to-end test: a real agent session asked to run `git push --force` gets blocked by the hook before git even starts.

**This guide exists because the Unix recipe does not work as-is on Windows.** The concept (a shared denylist plus a PreToolUse hook that exits with code 2) comes from [David Ondrej's `global-agent-guardrails` skill](https://github.com/davidondrej/skills/tree/main/skills/ops-and-setup/global-agent-guardrails) (MIT), designed for macOS/Linux. Installed naively on Windows, the guardrail **looks like it is in place but blocks nothing** — the worst possible failure mode for a safety tool. The scripts in this guide are an original reimplementation that fixes two very real Windows pitfalls, documented below.

**What this guardrail is — and is not.** It is a seatbelt against *accidents*. It is **not** a sandbox against a malicious agent: trivial obfuscation (`python -c "shutil.rmtree(...)"`) sails past a regex. If your threat model is a hostile agent, you need isolation (VM, container, dedicated account), not a denylist.

**For AI agents reading this document**: every step below was executed successfully in this order. The two Windows pitfalls in section 5 are not theoretical — each of them silently disabled blocking during development. The end-to-end test in section 6 is not optional: it is the only way to prove that a block actually travels through the whole execution chain.

---

## 1. Architecture

```
~/.agents/hooks/dangerous-patterns.txt   THE denylist: one POSIX-ERE regex per line
~/.agents/hooks/deny-dangerous.sh        the guard: hook JSON on stdin -> block
~/.agents/hooks/test-guard.sh            test suite: rerun after ANY change
~/.claude/settings.json                  wiring: PreToolUse hook, matcher "Bash|PowerShell"
```

A single patterns file is the source of truth. The guard script re-reads it on every command: editing a pattern takes effect immediately, with nothing to restart. The three files are designed to be shared by several agents (Claude Code, Cursor, Codex…) — this guide wires up Claude Code; the script already accepts a `cursor` argument for Cursor's protocol.

A design principle to keep in mind for every addition: **block only the irreversible** (wiping the root or home directory, writing to a raw disk, destroying git history, deleting a repository). Destructive-but-recoverable commands (`git clean -fdx`, `rm -rf node_modules`) stay allowed — an over-blocking guardrail ends up disabled, and the safer `git push --force-with-lease` stays allowed while `--force` is blocked.

## 2. The denylist

Full file in [`hooks/dangerous-patterns.txt`](hooks/dangerous-patterns.txt). What it covers:

| Category | Blocked examples | Still allowed |
|---|---|---|
| Recursive `rm` on root/home | `rm -rf /`, `rm -rf ~`, `rm -rf /c`, `rm -rf C:\` | `rm -rf node_modules`, `rm -rf ~/projects/old` |
| Recursive `sudo rm` | `sudo rm -rf /var/www` (even via ssh) | `sudo rm /etc/nginx/sites-enabled/old.conf` |
| Raw disk writes | `dd ... of=/dev/sda`, `of=\\.\PhysicalDrive0` | `dd ... of=/tmp/test.img` |
| Formatting | `mkfs.ext4 ...`, `Format-Volume`, `format c:` | — |
| Fork bomb | `:(){ :\|:& };:` | — |
| Download piped into a shell | `curl ... \| bash`, `iwr ... \| iex` | `curl ... -o file.txt` |
| Git history destruction | `git push --force`, `git push -f` | `git push --force-with-lease` |
| GitHub repo deletion | `gh repo delete` | `gh repo view` |
| Recursive PowerShell on a drive root | `Remove-Item -Recurse -Force C:\` | `Remove-Item C:\Temp\x -Recurse` |

Three writing rules for patterns:

1. **POSIX ERE** (`grep -E`), one regex per line, `#` comments.
2. **`[[:space:]]`, never `\s`** — if a JS/Python adapter ever consumes the same file, the `[:space:]` → `\s` conversion is mechanical.
3. Every "target" alternative (`/`, `~`, `$HOME`, `C:\`…) must be **bounded** (whitespace or end of string), otherwise `rm -rf /tmp/foo` would be blocked by the `rm -rf /` pattern. Edge cases of exactly this kind are what the test suite catches.

## 3. The guard script

Full file in [`hooks/deny-dangerous.sh`](hooks/deny-dangerous.sh). Its contract: the hook JSON arrives on stdin, the script extracts the command (fallback chain `.tool_input.command` → `.toolInput.command` → `.command`, to stay compatible with other agents), checks it against every pattern, and **blocks through two channels at once**:

```bash
# Excerpt — the heart of the block:
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}'
echo "BLOCKED by global-agent-guardrails: ... pattern: $pat" >&2
exit 2
```

Why both? That is pitfall #1 in section 5. Other design choices that matter:

- **Fail-open**: if the patterns file is unreadable or the JSON invalid, the script lets the command through. A broken guardrail that blocks *every* command would be disabled within the hour; a broken guardrail that lets things through gets caught by the test suite.
- **Cascading JSON extraction**: `jq` if present, else `node` (always there on a machine running Claude Code), else `grep -oP` plus `sed` unescaping. No dependencies to install.
- The error message tells the agent **what to do about a false positive** (put the text in a file, or tune the pattern and rerun the tests) — otherwise the agent keeps retrying variants of the same command.

## 4. Installation and Claude Code wiring

```bash
# From Git Bash:
mkdir -p ~/.agents/hooks
cp hooks/* ~/.agents/hooks/
chmod +x ~/.agents/hooks/deny-dangerous.sh ~/.agents/hooks/test-guard.sh
~/.agents/hooks/test-guard.sh    # must end with: passed: 52, failed: 0
```

Find the Windows path of your Git bash:

```powershell
(Get-Command bash).Source
# e.g. C:\Users\<you>\AppData\Local\Programs\Git\usr\bin\bash.exe
# or   C:\Program Files\Git\usr\bin\bash.exe
```

Then, in `~/.claude/settings.json`, add the `hooks` block (merge if the file exists — do not overwrite your other settings):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "C:/Users/<you>/AppData/Local/Programs/Git/usr/bin/bash.exe C:/Users/<you>/.agents/hooks/deny-dangerous.sh"
          }
        ]
      }
    ]
  }
}
```

Three details, each of which matters:

- **Matcher `Bash|PowerShell`**: on Windows, Claude Code exposes *two* shell tools. The original guide's wiring table only mentions `Bash` — a guardrail that ignores the PowerShell tool misses half the commands.
- **Absolute paths, `/` separators**: `~` expansion is not reliable across agents, and forward slashes avoid the backslash-escaping hell of JSON.
- **Spaces in the path**: if your Git lives in `C:\Program Files\Git`, the path contains a space and the `command` value will need quoting (`"\"C:/Program Files/Git/usr/bin/bash.exe\" C:/Users/..."`). The per-user install (`AppData\Local\Programs\Git`) gives a space-free path — more robust across the cmd/PowerShell layers.

Hooks are loaded **at session start**: already-open sessions are not protected, restart them.

## 5. The two Windows pitfalls (each silently disables the guardrail)

### Pitfall #1: exit code 2 is swallowed by the PowerShell wrapper

The Unix recipe rests on "the hook exits with code 2 ⇒ the command is blocked". On Windows, Claude Code launches the hook command through a shell layer that **does not propagate the native exit code** (notorious PowerShell behavior: without an explicit `exit $LASTEXITCODE`, the child process's code is lost). Observed during development: the guard decided to block, exited with code 2… and `git push --force` ran anyway.

The diagnosis that proved it: a temporary decision log in the script (`echo "DECISION: BLOCK pattern=..." >> guard-debug.log`) showed `BLOCK` while the agent session reported git's own error — so the command had run *after* the decision to block it.

The fix: Claude Code accepts a **second blocking protocol**, independent of the exit code — a `permissionDecision: "deny"` JSON on stdout with exit code 0. Stdout crosses the wrappers intact. The script emits **both**: the JSON to survive wrappers, stderr + exit 2 for agents that spawn the script directly (Codex, Devin).

### Pitfall #2: never depend on `$HOME` or `PATH` inside the script

When an agent host spawns `bash.exe` with a minimal Windows environment, two things are missing: `$HOME` (the script can no longer find the denylist) and MSYS's `/usr/bin` in `PATH` (`dirname`, `grep`, `sed` not found). Combined with fail-open, each case yields a guardrail that lets everything through without a word: `[ -r "$PATTERNS" ] || exit 0` on one side, a `grep` failing inside a silent `if` on the other.

The fix, in the first lines of the script:

```bash
PATH="/usr/bin:$PATH"                                  # MSYS coreutils always reachable
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PATTERNS="${AGENT_GUARD_PATTERNS:-${SCRIPT_DIR:-$HOME/.agents/hooks}/dangerous-patterns.txt}"
```

The denylist is resolved **relative to the script itself**, not to the home directory. Test this case explicitly:

```bash
echo '{"tool_input":{"command":"rm -rf /"}}' | env -u HOME \
  "C:/Users/<you>/AppData/Local/Programs/Git/usr/bin/bash.exe" \
  "C:/Users/<you>/.agents/hooks/deny-dangerous.sh"; echo "exit=$?"   # expected: exit=2
```

One last detail of the same kind: if you edit the files with a Windows tool, check the line endings. A `\r` at the end of a pattern breaks the `grep` with no visible error (`sed -i 's/\r$//' ~/.agents/hooks/*` settles the question; the script also strips `\r` defensively).

## 6. End-to-end verification

The direct test (section 5) only proves the script. You must also prove the **wiring**: the original guide's safe probe is to ask the agent to run `git push --force` from a directory that is **not** a git repository. Two possible outcomes, neither dangerous:

```bash
cd "$(mktemp -d)"
claude -p 'Run exactly: git push --force. Report the result in one line.' --permission-mode bypassPermissions
```

- ✅ Answer says "blocked by the hook": the guardrail works through the whole chain.
- ❌ Answer says "fatal: not a git repository": **git ran**, blocking failed somewhere (reread section 5) — but no harm done.

Counter-check, to verify you have not blocked everything:

```bash
claude -p 'Run exactly this shell command: echo guard-ok. Report the output in one line.' --permission-mode bypassPermissions
```

## 7. Evolving the patterns

1. Edit `~/.agents/hooks/dangerous-patterns.txt`.
2. Add **one blocked case and one allowed case** to `test-guard.sh` — the allowed case is the more important one: it is what protects you from over-blocking.
3. Rerun `test-guard.sh`. `failed: 0` or the pattern does not stay.

**The classic false positive**: a harmless command whose *argument* contains the text of a dangerous command (passing along an instruction that mentions `git push --force`, writing this guide…). This is inherent to the regex approach. Workaround: put the text in a file and pass the path.

## 8. Known limitations

- A regex only sees the surface: obfuscation, downloaded-then-executed scripts, destructive `python -c` all get through. Seatbelt, not sandbox.
- Agents running in the cloud (remote tasks) do not go through your local hooks.
- Sessions opened before the wiring are not protected.
- The probe in section 6 verifies Claude Code; if you wire other agents onto the same three files, redo it for each one.

## Credits

Concept and the `~/.agents/hooks/` convention: [David Ondrej's `global-agent-guardrails` skill](https://github.com/davidondrej/skills/tree/main/skills/ops-and-setup/global-agent-guardrails) (MIT license). The scripts in this repository are an original reimplementation for Windows, written and verified on a real machine; the two pitfalls in section 5 were discovered (and proven) during that work, in July 2026.
