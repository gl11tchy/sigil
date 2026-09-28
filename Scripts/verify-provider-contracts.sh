#!/usr/bin/env bash
# Optional local contract check. Requires installed CLIs; never sends a prompt.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sigil-provider-contracts.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

for cli in claude codex grok; do
  command -v "$cli" >/dev/null || { echo "$cli is not installed" >&2; exit 1; }
  "$cli" --version
  "$cli" --help >"$ROOT/$cli.help"
done
codex resume --help >"$ROOT/codex-resume.help"

for flag in --session-id --resume --continue --settings; do
  grep -Fq -- "$flag" "$ROOT/claude.help"
done
for flag in SESSION_ID --last --model; do
  grep -Fq -- "$flag" "$ROOT/codex-resume.help"
done
for flag in --session-id --resume --continue --cwd; do
  grep -Fq -- "$flag" "$ROOT/grok.help"
done
printf '%s\n' 'Provider launch/resume contracts passed; no prompts or model calls were sent.'
