#!/bin/zsh
# Process-level test of the built helper against the REAL macOS clipboard, using only harmless text.
# Uses a temporary config/settings directory; your real config.json and ~/.claude are never touched.
# The text currently on your clipboard is saved first and restored at the end.
set -uo pipefail

# pbcopy/pbpaste encode text according to the locale; pin UTF-8 so Czech characters round-trip.
export LC_ALL=en_US.UTF-8

ROOT="${0:A:h:h}"
HELPER="${1:-$ROOT/build/PureClipboard.app/Contents/MacOS/pureclipboard-hook}"
[[ -x "$HELPER" ]] || { echo "Helper not found: $HELPER (run scripts/build-app.sh)" >&2; exit 2; }

T="$(mktemp -d)"
pbpaste > "$T/clipboard.orig"
trap 'pbcopy < "$T/clipboard.orig"; rm -rf "$T"' EXIT

export PURECLIPBOARD_CONFIG_PATH="$T/config.json"
pass=0; fail=0
check() { # name, condition-result
  if [[ "$2" == "ok" ]]; then pass=$((pass+1)); echo "  PASS  $1"; else fail=$((fail+1)); echo "  FAIL  $1"; fi
}
write_config() { # autoCopy claude protect
  python3 -I - "$T/config.json" "$1" "$2" "$3" <<'EOF'
import json, sys
path, auto, claude, protect = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1", sys.argv[4] == "1"
modes = {"terminal": "diagnostics", "claudeCode": "finalResponse", "codex": "finalResponse", "pureRemote": "actionResults", "termux": "localClipboard"}
cfg = {"schemaVersion": 1, "futureKey": {"keep": True},
       "global": {"autoCopy": auto, "historyLimit": 20, "protectSensitiveData": protect},
       "integrations": {k: {"enabled": (k == "claudeCode" and claude), "mode": m} for k, m in modes.items()}}
open(path, "w").write(json.dumps(cfg, indent=2))
EOF
  chmod 600 "$T/config.json"
}
payload() { # event message-or-empty
  python3 -I -c '
import json, sys
event, message = sys.argv[1], sys.argv[2]
d = {"session_id": "test", "cwd": "/tmp", "hook_event_name": event, "stop_hook_active": False}
if message != "-": d["last_assistant_message"] = message
print(json.dumps(d))' "$1" "$2"
}
sentinel() { printf 'SENTINEL-%s' "$RANDOM$RANDOM" | pbcopy; pbpaste; }
run() { payload "$1" "$2" | "$HELPER" claude-stop; }
event_field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$T/last-event.json" "$1" 2>/dev/null; }

echo "== 1. Enabled, harmless text is copied"
write_config 1 1 1
sentinel >/dev/null
out="$(run Stop 'Neškodný testovací text PureClipboard 123.')"; code=$?
check "exit code 0" "$([[ $code -eq 0 ]] && echo ok)"
check "stdout empty" "$([[ -z "$out" ]] && echo ok)"
check "clipboard holds the final message" "$([[ "$(pbpaste)" == 'Neškodný testovací text PureClipboard 123.' ]] && echo ok)"
check "event recorded as copied" "$([[ "$(event_field result)" == copied ]] && echo ok)"
check "event file mode 0600" "$([[ "$(stat -f %Lp "$T/last-event.json")" == 600 ]] && echo ok)"
check "event file holds no message text" "$(grep -q 'Neškodný' "$T/last-event.json" || echo ok)"

echo "== 2. Auto Copy off: clipboard unchanged, no trace"
write_config 0 1 1; rm -f "$T/last-event.json"
s="$(sentinel)"; run Stop 'nesmí se zkopírovat' >/dev/null
check "clipboard unchanged" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "no event file" "$([[ ! -e "$T/last-event.json" ]] && echo ok)"

echo "== 3. Claude Code integration off: clipboard unchanged, no trace"
write_config 1 0 1
s="$(sentinel)"; run Stop 'nesmí se zkopírovat' >/dev/null
check "clipboard unchanged" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "no event file" "$([[ ! -e "$T/last-event.json" ]] && echo ok)"

echo "== 4. Sensitive content is blocked"
write_config 1 1 1
fake="ghp_$(printf 'Zq7%.0s' {1..12})"
s="$(sentinel)"; run Stop "Tady je klíč: $fake" >/dev/null
check "clipboard unchanged" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "event says sensitive-content" "$([[ "$(event_field reason)" == sensitive-content ]] && echo ok)"
check "event never contains the secret" "$(grep -q "$fake" "$T/last-event.json" || echo ok)"

echo "== 5. Wrong event / missing message / garbage input"
s="$(sentinel)"
run SubagentStop 'text' >/dev/null
check "SubagentStop ignored" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
run Stop - >/dev/null
check "missing message ignored" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
print -n 'not json at all' | "$HELPER" claude-stop; code=$?
check "garbage input: exit 0, clipboard unchanged" "$([[ $code -eq 0 && "$(pbpaste)" == "$s" ]] && echo ok)"
"$HELPER" claude-stop < /dev/null; code=$?
check "empty stdin: exit 0" "$([[ $code -eq 0 ]] && echo ok)"

echo "== 6. Broken or missing config fails closed and is never rewritten"
print -n '{ broken' > "$T/config.json"; chmod 600 "$T/config.json"
s="$(sentinel)"; run Stop 'text' >/dev/null
check "clipboard unchanged" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "config byte-identical" "$([[ "$(cat "$T/config.json")" == '{ broken' ]] && echo ok)"
rm -f "$T/config.json"; run Stop 'text' >/dev/null
check "missing config: clipboard unchanged, file not created" "$([[ "$(pbpaste)" == "$s" && ! -e "$T/config.json" ]] && echo ok)"

echo "== 7. Install / uninstall on a temporary settings file"
write_config 1 1 1
S="$T/settings.json"
print -r -- '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}' > "$S"; chmod 600 "$S"
cp "$S" "$T/settings.orig"
"$HELPER" install-claude --settings "$S" >/dev/null
check "dry run changes nothing" "$(cmp -s "$S" "$T/settings.orig" && echo ok)"
"$HELPER" install-claude --settings "$S" --apply >/dev/null; code=$?
check "install --apply succeeds" "$([[ $code -eq 0 ]] && echo ok)"
status_out="$("$HELPER" status-claude --settings "$S")"
check "status reports installed" "$(grep -q 'hook: *nainstalován' <<< "$status_out" && echo ok)"
check "backup equals original" "$(cmp -s "$T"/backups/claude-settings-*.json "$T/settings.orig" && echo ok)"
check "settings keeps the foreign hook" "$(grep -q '/usr/bin/true' "$S" && echo ok)"
check "helper copy is executable" "$([[ -x "$T/bin/pureclipboard-hook" ]] && echo ok)"
echo '{"hook_event_name":"Stop","last_assistant_message":"Z nainstalované kopie."}' | "$T/bin/pureclipboard-hook" claude-stop
check "installed copy copies too" "$([[ "$(pbpaste)" == 'Z nainstalované kopie.' ]] && echo ok)"
"$HELPER" uninstall-claude --settings "$S" --apply >/dev/null
check "uninstall restores original JSON" "$(python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))!=json.load(open(sys.argv[2])))' "$S" "$T/settings.orig" && echo ok)"
check "helper copy removed" "$([[ ! -e "$T/bin/pureclipboard-hook" ]] && echo ok)"

echo
echo "Passed: $pass  Failed: $fail"
[[ $fail -eq 0 ]]
