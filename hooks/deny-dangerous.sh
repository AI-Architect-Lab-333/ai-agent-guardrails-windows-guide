#!/usr/bin/env bash
# ~/.agents/hooks/deny-dangerous.sh - shared dangerous-command guard.
# Protocol: hook JSON on stdin; exit 2 blocks (Claude Code / Codex / Devin),
# stderr is shown to the agent. Pass "cursor" as $1 for Cursor's deny-JSON.
# Command field fallback chain: .tool_input.command (Claude/Codex/Devin),
# .toolInput.command (Grok), .command (Cursor). Keep all three.
# Fail-open by design: breakage here must never brick every shell command.

# Agent hosts may spawn this with a bare Windows PATH; make sure MSYS
# coreutils (dirname, grep, sed, head) are always reachable.
PATH="/usr/bin:$PATH"

# Resolve the patterns file next to this script — do NOT rely on $HOME:
# agent hosts may spawn hooks without HOME set (fail-open would silently
# disable the guard).
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PATTERNS="${AGENT_GUARD_PATTERNS:-${SCRIPT_DIR:-$HOME/.agents/hooks}/dangerous-patterns.txt}"
MODE="${1:-exitcode}"

[ -r "$PATTERNS" ] || exit 0
INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

extract_command() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '.tool_input.command // .toolInput.command // .command // ""' 2>/dev/null
    return
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$INPUT" | node -e '
      let s = "";
      process.stdin.on("data", (d) => (s += d));
      process.stdin.on("end", () => {
        try {
          const j = JSON.parse(s);
          const c =
            (j.tool_input && j.tool_input.command) ||
            (j.toolInput && j.toolInput.command) ||
            j.command || "";
          process.stdout.write(String(c));
        } catch (e) {}
      });
    ' 2>/dev/null
    return
  fi
  # Last resort: PCRE-extract the first "command" JSON string and unescape it.
  printf '%s' "$INPUT" |
    grep -oP '"command"\s*:\s*"(\\.|[^"\\])*"' 2>/dev/null |
    head -n 1 |
    sed -e 's/^"command"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' \
        -e 's/\\\\/\x01/g' -e 's/\\"/"/g' -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\x01/\\/g'
}

CMD="$(extract_command)"
[ -n "$CMD" ] || exit 0

while IFS= read -r pat || [ -n "$pat" ]; do
  pat="${pat%$'\r'}"
  case "$pat" in '' | '#'*) continue ;; esac
  if printf '%s\n' "$CMD" | grep -Eq -- "$pat" 2>/dev/null; then
    if [ "$MODE" = "cursor" ]; then
      printf '{"permission":"deny","userMessage":"Blocked by global-agent-guardrails (catastrophic command pattern)","agentMessage":"Command blocked by ~/.agents/hooks/dangerous-patterns.txt. If this is a false positive, tune the pattern and re-run test-guard.sh."}'
      exit 0
    fi
    # Dual block protocol: stdout deny-JSON (exit-0 protocol) is honored by
    # Claude Code even when a Windows shell wrapper (PowerShell) swallows the
    # native exit code; stderr + exit 2 covers direct spawns (Codex, Devin).
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED by global-agent-guardrails: the command matches a catastrophic pattern in ~/.agents/hooks/dangerous-patterns.txt. This guard blocks irreversible actions (disk wipe, root/home deletion, force-push, repo deletion). False positive (the text merely MENTIONS a dangerous command)? Put the text in a file instead, or tune the pattern and re-run ~/.agents/hooks/test-guard.sh."}}'
    {
      echo "BLOCKED by global-agent-guardrails: the command matches a catastrophic pattern in ~/.agents/hooks/dangerous-patterns.txt:"
      echo "  pattern: $pat"
      echo "This guard blocks irreversible actions (disk wipe, root/home deletion, force-push, repo deletion)."
      echo "False positive (the text merely MENTIONS a dangerous command)? Put the text in a file instead, or tune the pattern and re-run ~/.agents/hooks/test-guard.sh."
    } >&2
    exit 2
  fi
done <"$PATTERNS"

exit 0
