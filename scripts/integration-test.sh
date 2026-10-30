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
ZSHRC_HASH="$(shasum -a 256 < ~/.zshrc)"
AUTH_HASH="$(shasum -a 256 < ~/.ssh/authorized_keys 2>/dev/null)"
pbpaste > "$T/clipboard.orig"
trap 'pbcopy < "$T/clipboard.orig"; rm -rf "$T"' EXIT

export PURECLIPBOARD_CONFIG_PATH="$T/config.json"
# Never look at (or touch) the real hook/settings files: point every integration at nonexistent temp paths.
isolate() {
  export PURECLIPBOARD_CLAUDE_SETTINGS_PATH="$T/isolated-claude-settings.json"
  export PURECLIPBOARD_CODEX_HOOKS_PATH="$T/isolated-codex-hooks.json"
  export PURECLIPBOARD_ZSHRC_PATH="$T/isolated-zshrc"
}
isolate
pass=0; fail=0
check() { # name, condition-result
  if [[ "$2" == "ok" ]]; then pass=$((pass+1)); echo "  PASS  $1"; else fail=$((fail+1)); echo "  FAIL  $1"; fi
}
write_config() { # autoCopy claude protect [codex] [terminal] [termux]   (file: $CFG, default $T/config.json)
  python3 -I - "${CFG:-$T/config.json}" "$1" "$2" "$3" "${4:-0}" "${5:-0}" "${6:-0}" <<'EOF'
import json, sys
path, auto, claude, protect, codex, terminal, termux = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1", sys.argv[4] == "1", sys.argv[5] == "1", sys.argv[6] == "1", sys.argv[7] == "1"
modes = {"terminal": "diagnostics", "claudeCode": "finalResponse", "codex": "finalResponse", "pureRemote": "actionResults", "termux": "localClipboard"}
cfg = {"schemaVersion": 1, "futureKey": {"keep": True},
       "global": {"autoCopy": auto, "historyLimit": 20, "protectSensitiveData": protect},
       "integrations": {k: {"enabled": ((k == "claudeCode" and claude) or (k == "codex" and codex) or (k == "terminal" and terminal) or (k == "termux" and termux)), "mode": m} for k, m in modes.items()}}
open(path, "w").write(json.dumps(cfg, indent=2))
EOF
  chmod 600 "${CFG:-$T/config.json}"
}
payload() { # event message-or-empty [session]
  python3 -I -c '
import json, sys
event, message, session = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"session_id": session, "cwd": "/tmp", "hook_event_name": event, "stop_hook_active": False}
if message != "-": d["last_assistant_message"] = message
print(json.dumps(d))' "$1" "$2" "${3:-test}"
}
sentinel() { printf 'SENTINEL-%s' "$RANDOM$RANDOM" | pbcopy; pbpaste; }
run() { payload "$1" "$2" "${3:-test}" | "$HELPER" claude-stop; }
run_codex() { payload "$1" "$2" "${3:-test}" | "$HELPER" codex-stop; }
event_field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "${EVENT_FILE:-$T/last-event.json}" "$1" 2>/dev/null; }

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
rm -f "$T/clipboard-claim.json"   # the 5 s burst guard would otherwise (correctly) protect the previous copy
echo '{"hook_event_name":"Stop","last_assistant_message":"Z nainstalované kopie."}' | "$T/bin/pureclipboard-hook" claude-stop
check "installed copy copies too" "$([[ "$(pbpaste)" == 'Z nainstalované kopie.' ]] && echo ok)"
"$HELPER" uninstall-claude --settings "$S" --apply >/dev/null
check "uninstall restores original JSON" "$(python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))!=json.load(open(sys.argv[2])))' "$S" "$T/settings.orig" && echo ok)"
check "helper copy removed" "$([[ ! -e "$T/bin/pureclipboard-hook" ]] && echo ok)"

echo "== 8. Codex: own switch, own event file"
write_config 1 0 1 1; rm -f "$T"/last-event*.json "$T"/clipboard-claim.json
s="$(sentinel)"; run Stop 'Claude je vypnutý' >/dev/null
check "Claude hook is a no-op while only Codex is enabled" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
out="$(run_codex Stop 'Neškodná odpověď Codexu 456.')"; code=$?
check "codex-stop exit 0 and silent" "$([[ $code -eq 0 && -z "$out" ]] && echo ok)"
check "clipboard holds the Codex message" "$([[ "$(pbpaste)" == 'Neškodná odpověď Codexu 456.' ]] && echo ok)"
EVENT_FILE="$T/last-event-codex.json"
check "codex event recorded as copied" "$([[ "$(event_field result)" == copied && "$(event_field integration)" == codex ]] && echo ok)"
check "Claude event file untouched" "$([[ ! -e "$T/last-event.json" ]] && echo ok)"
unset EVENT_FILE

echo "== 9. Codex: switches, sensitive data, missing message"
write_config 1 1 1 0; rm -f "$T"/last-event*.json "$T"/clipboard-claim.json
s="$(sentinel)"; run_codex Stop 'Codex je vypnutý' >/dev/null
check "Codex switch off: clipboard unchanged, no trace" "$([[ "$(pbpaste)" == "$s" && ! -e "$T/last-event-codex.json" ]] && echo ok)"
write_config 0 0 1 1
s="$(sentinel)"; run_codex Stop 'Auto Copy je vypnutý' >/dev/null
check "Auto Copy off: clipboard unchanged" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
write_config 1 0 1 1; rm -f "$T"/clipboard-claim.json
s="$(sentinel)"; run_codex Stop "Tady je klíč: $fake" >/dev/null
check "sensitive content blocked" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "event never contains the secret" "$(grep -q "$fake" "$T/last-event-codex.json" || echo ok)"
run_codex Stop - >/dev/null; run_codex SubagentStop 'x' >/dev/null
check "missing message / other event ignored" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "codex-stop never prints on garbage" "$([[ -z "$(print -n 'zzz' | "$HELPER" codex-stop)" ]] && echo ok)"

echo "== 10. Concurrency: second session does not overwrite within 5 s"
write_config 1 1 1 1; rm -f "$T"/clipboard-claim.json "$T"/last-event*.json
run Stop 'První agent' A >/dev/null
run_codex Stop 'Druhý agent' B >/dev/null
check "first agent keeps the clipboard" "$([[ "$(pbpaste)" == 'První agent' ]] && echo ok)"
EVENT_FILE="$T/last-event-codex.json"
check "second agent recorded as skipped" "$([[ "$(event_field reason)" == recent-copy-by-other-session ]] && echo ok)"
unset EVENT_FILE
run Stop 'První agent, další tah' A >/dev/null
check "same session may copy again at once" "$([[ "$(pbpaste)" == 'První agent, další tah' ]] && echo ok)"
for i in 1 2 3 4 5 6; do (run_codex Stop "Souběh $i" "P$i" >/dev/null &) ; done; wait; sleep 1
check "burst of 6 parallel sessions leaves a single winner" "$([[ "$(pbpaste)" == 'První agent, další tah' ]] && echo ok)"
check "claim file is private" "$([[ "$(stat -f %Lp "$T/clipboard-claim.json")" == 600 ]] && echo ok)"

echo "== 11. Codex install / uninstall on a temporary hooks.json"
write_config 1 1 1 1
H="$T/hooks.json"
print -r -- '{"description":"moje","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}' > "$H"; chmod 600 "$H"
cp "$H" "$T/hooks.orig"
"$HELPER" install-codex --settings "$H" >/dev/null
check "dry run changes nothing" "$(cmp -s "$H" "$T/hooks.orig" && echo ok)"
"$HELPER" install-codex --settings "$H" --apply >/dev/null; code=$?
check "install-codex --apply succeeds" "$([[ $code -eq 0 ]] && echo ok)"
status_out="$("$HELPER" status-codex --settings "$H")"
check "status-codex reports installed" "$(grep -q 'hook: *nainstalován' <<< "$status_out" && echo ok)"
check "foreign hook kept" "$(grep -q '/usr/bin/true' "$H" && echo ok)"
check "codex backup equals original" "$(cmp -s "$T"/backups/codex-hooks-*.json "$T/hooks.orig" && echo ok)"
export PURECLIPBOARD_CODEX_HOOKS_PATH="$H" PURECLIPBOARD_CLAUDE_SETTINGS_PATH="$S"
"$HELPER" install-claude --apply >/dev/null
"$HELPER" uninstall-claude --apply >/dev/null
check "shared helper survives removing Claude while Codex is installed" "$([[ -x "$T/bin/pureclipboard-hook" ]] && echo ok)"
"$HELPER" uninstall-codex --apply >/dev/null
isolate
check "uninstall-codex restores original JSON" "$(python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))!=json.load(open(sys.argv[2])))' "$H" "$T/hooks.orig" && echo ok)"
check "helper removed with the last integration" "$([[ ! -e "$T/bin/pureclipboard-hook" ]] && echo ok)"

echo "== 12. Terminal: pclip in a real zsh against the real clipboard"
write_config 1 0 1 0 1; rm -f "$T"/last-event*.json "$T"/clipboard-claim.json
Z="$T/zshrc"
print -r -- 'export PATH="$PATH:/usr/local/bin"' > "$Z"; print -r -- 'source "$HOME/.pure/bin/clipboard.zsh"' >> "$Z"; chmod 644 "$Z"; cp "$Z" "$T/zshrc.orig"
"$HELPER" install-terminal --settings "$Z" >/dev/null
check "dry run changes nothing" "$(cmp -s "$Z" "$T/zshrc.orig" && echo ok)"
"$HELPER" install-terminal --settings "$Z" --apply >/dev/null; code=$?
check "install-terminal --apply succeeds" "$([[ $code -eq 0 ]] && echo ok)"
check "existing .zshrc lines kept in place" "$(head -n 2 "$Z" | cmp -s - "$T/zshrc.orig" && echo ok)"
check "backup equals original" "$(cmp -s "$T"/backups/zshrc-* "$T/zshrc.orig" && echo ok)"
status_out="$("$HELPER" status-terminal --settings "$Z")"
check "status-terminal reports the block" "$(grep -q 'blok: *přidán' <<< "$status_out" && echo ok)"
PC="$T/shell/pureclipboard.zsh"
check "snippet is valid zsh" "$(zsh -n "$PC" && echo ok)"

s="$(sentinel)"
out="$(zsh -f -c "source '$PC'; pclip sh -c 'echo Neškodný výstup příkazu; exit 0'" 2>"$T/pclip.err")"; code=$?
check "pclip passes output through and returns 0" "$([[ $code -eq 0 && "$out" == 'Neškodný výstup příkazu' ]] && echo ok)"
check "clipboard holds the command output" "$([[ "$(pbpaste)" == 'Neškodný výstup příkazu' ]] && echo ok)"
check "user told about the copy on stderr" "$(grep -q 'zkopírován' "$T/pclip.err" && echo ok)"
EVENT_FILE="$T/last-event-terminal.json"
check "terminal event recorded" "$([[ "$(event_field result)" == copied && "$(event_field integration)" == terminal ]] && echo ok)"
unset EVENT_FILE

zsh -f -c "source '$PC'; pclip sh -c 'echo chyba v buildu >&2; exit 5'" >/dev/null 2>&1; code=$?
check "failing command keeps its exit code" "$([[ $code -eq 5 ]] && echo ok)"
check "failure output gets the exit footer" "$([[ "$(pbpaste)" == $'chyba v buildu\n[exit 5]' ]] && echo ok)"

s="$(sentinel)"; zsh -f -c "source '$PC'; pclip sh -c 'echo GITHUB_TOKEN=$fake'" >/dev/null 2>"$T/pclip.err"
check "sensitive output is not copied" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
check "event never contains the secret" "$(grep -q "$fake" "$T/last-event-terminal.json" || echo ok)"

write_config 1 0 1 0 0; rm -f "$T/last-event-terminal.json"
s="$(sentinel)"; zsh -f -c "source '$PC'; pclip echo vypnuto" >/dev/null 2>&1
check "Terminal switch off: clipboard unchanged, no trace" "$([[ "$(pbpaste)" == "$s" && ! -e "$T/last-event-terminal.json" ]] && echo ok)"
write_config 0 0 1 0 1
sentinel >/dev/null; zsh -f -c "source '$PC'; pclip echo vypnuto" >/dev/null 2>&1
check "Auto Copy off: explicit pclip still copies" "$([[ "$(pbpaste)" == vypnuto ]] && echo ok)"
run Stop 'Agent nesmí přepsat ruční kopii' >/dev/null
check "Auto Copy off: Claude hook remains inactive" "$([[ "$(pbpaste)" == vypnuto ]] && echo ok)"

write_config 1 0 1 1 1; rm -f "$T"/clipboard-claim.json
zsh -f -c "source '$PC'; pclip echo moje výslovná kopie" >/dev/null 2>&1
run_codex Stop 'Agent skončil těsně po mně' B >/dev/null
check "agent right after pclip cannot overwrite it" "$([[ "$(pbpaste)" == 'moje výslovná kopie' ]] && echo ok)"

print -r -- 'echo ahoj' | zsh -f -c "source '$PC'; pclip" >/dev/null 2>&1; code=$?
check "pclip without a command exits 2" "$([[ $code -eq 2 ]] && echo ok)"

"$HELPER" uninstall-terminal --settings "$Z" --apply >/dev/null
check "uninstall-terminal restores .zshrc byte for byte" "$(cmp -s "$Z" "$T/zshrc.orig" && echo ok)"
check "snippet and helper removed" "$([[ ! -e "$PC" && ! -e "$T/bin/pureclipboard-hook" ]] && echo ok)"
check "real ~/.zshrc untouched by this run" "$([[ "$(shasum -a 256 < ~/.zshrc)" == "$ZSHRC_HASH" ]] && echo ok)"

echo "== 13. Termux: S25 <-> Mac channel (fake ssh + fake termux-api, real helper, path with spaces)"
SUP="$T/Application Support/PureClipboard"; mkdir -p "$SUP"
OLD_CFG_ENV="$PURECLIPBOARD_CONFIG_PATH"; export PURECLIPBOARD_CONFIG_PATH="$SUP/config.json"; CFG="$SUP/config.json"
TH="$SUP/bin/pureclipboard-hook"
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<'SH'
#!/bin/sh
# Test double: the last argument is the remote command line; run it here, stdin/stdout passed through.
for last; do :; done
exec /bin/sh -c "$last"
SH
cat > "$SHIM/termux-clipboard-get" <<SH
#!/bin/sh
cat "$T/phone-clipboard"
SH
cat > "$SHIM/termux-clipboard-set" <<SH
#!/bin/sh
cat > "$T/phone-clipboard-written"
SH
chmod +x "$SHIM"/*
write_config 0 0 1 0 0 1; rm -f "$SUP"/last-event*.json

"$HELPER" install-termux >/dev/null
check "dry run creates no mailbox" "$([[ ! -e "$SUP/termux" ]] && echo ok)"
"$HELPER" install-termux --apply >/dev/null; code=$?
check "install-termux --apply succeeds" "$([[ $code -eq 0 ]] && echo ok)"
check "mailbox folders are private (0700)" "$([[ "$(stat -f %Lp "$SUP/termux/inbox")" == 700 && "$(stat -f %Lp "$SUP/termux/outbox")" == 700 ]] && echo ok)"
check "helper copy is executable" "$([[ -x "$TH" ]] && echo ok)"
status_out="$("$HELPER" status-termux)"
check "status-termux reports the mailbox" "$(grep -q 'připravena' <<< "$status_out" && echo ok)"

"$TH" termux-script --host mac-test --user pavel > "$T/pcr"
check "termux-script prints valid sh" "$(sh -n "$T/pcr" && echo ok)"
check "script knows the helper path with the space" "$(grep -q 'Application Support/PureClipboard/bin/pureclipboard-hook' "$T/pcr" && echo ok)"
PCR() { env PATH="$SHIM:/usr/bin:/bin" HOME="$T/phone-home" XDG_CONFIG_HOME="$T/phone-home/cfg" sh "$T/pcr" "$@"; }
mkdir -p "$T/phone-home"

echo "-- phone -> Mac (inbox, clipboard of the Mac must stay untouched)"
s="$(sentinel)"
printf 'Neškodný text z telefonu\nřádek 2' > "$T/phone-clipboard"
PCR tomac 2> "$T/pcr.err"; code=$?
check "pcr tomac exits 0" "$([[ $code -eq 0 ]] && echo ok)"
check "Mac clipboard unchanged by an incoming text" "$([[ "$(pbpaste)" == "$s" ]] && echo ok)"
item="$(ls "$SUP/termux/inbox"/*.json 2>/dev/null | head -1)"
check "item landed in the inbox, mode 0600" "$([[ -n "$item" && "$(stat -f %Lp "$item")" == 600 ]] && echo ok)"
check "inbox item holds the text" "$(grep -q 'Neškodný text z telefonu' "$item" && echo ok)"
EVENT_FILE="$SUP/last-event-termux.json"
check "event says received, without content" "$([[ "$(event_field reason)" == received ]] && ! grep -q 'Neškodný' "$EVENT_FILE" && echo ok)"
unset EVENT_FILE

echo "-- sensitive text from the phone is refused"
printf 'klíč: %s' "$fake" > "$T/phone-clipboard"
PCR tomac 2> "$T/pcr.err"; code=$?
check "refused with exit 5" "$([[ $code -eq 5 ]] && echo ok)"
check "inbox still holds only the first item" "$([[ "$(ls "$SUP/termux/inbox" | wc -l | tr -d ' ')" == 1 ]] && echo ok)"
check "no secret in the event record" "$(grep -q "$fake" "$SUP/last-event-termux.json" || echo ok)"

echo "-- Mac -> phone (outbox, delivered exactly once)"
printf 'Text pro telefon: žluťoučký kůň' | "$TH" termux-send 2>/dev/null
rm -f "$T/phone-clipboard-written"
PCR frommac 2>/dev/null; code=$?
check "pcr frommac exits 0" "$([[ $code -eq 0 ]] && echo ok)"
check "phone clipboard received the text byte for byte" "$([[ "$(cat "$T/phone-clipboard-written")" == 'Text pro telefon: žluťoučký kůň' ]] && echo ok)"
rm -f "$T/phone-clipboard-written"
PCR frommac 2>/dev/null; code=$?
check "second fetch: exit 3 and phone clipboard untouched" "$([[ $code -eq 3 && ! -e "$T/phone-clipboard-written" ]] && echo ok)"

echo "-- switches"
write_config 0 0 1 0 0 0; rm -f "$SUP/last-event-termux.json"
printf 'nesmí projít' > "$T/phone-clipboard"
PCR tomac 2> "$T/pcr.err"; code=$?
check "Termux switch off: exit 4 and a clear message" "$([[ $code -eq 4 ]] && grep -q 'vypnutý' "$T/pcr.err" && echo ok)"
check "Termux switch off: nothing stored, no trace" "$([[ "$(ls "$SUP/termux/inbox" | wc -l | tr -d ' ')" == 1 && ! -e "$SUP/last-event-termux.json" ]] && echo ok)"
write_config 0 0 1 0 0 1
printf 'Auto Copy je vypnutý, přesto to projde do pošty' > "$T/phone-clipboard"
PCR tomac 2>/dev/null; code=$?
check "Auto Copy off does not matter for explicit commands" "$([[ $code -eq 0 && "$(ls "$SUP/termux/inbox" | wc -l | tr -d ' ')" == 2 ]] && echo ok)"
check "pcr doctor reaches the helper" "$(PCR doctor 2>&1 | grep -q 'spojení s Macem: OK' && echo ok)"

echo "-- removal"
"$HELPER" uninstall-termux --apply >/dev/null
check "uninstall deletes the mailbox and waiting texts" "$([[ ! -e "$SUP/termux" ]] && echo ok)"
check "helper removed with the last integration" "$([[ ! -e "$TH" ]] && echo ok)"
check "no real SSH config was read or changed" "$([[ "$(shasum -a 256 < ~/.ssh/authorized_keys 2>/dev/null)" == "$AUTH_HASH" ]] && echo ok)"
export PURECLIPBOARD_CONFIG_PATH="$OLD_CFG_ENV"; unset CFG

echo
echo "Passed: $pass  Failed: $fail"
[[ $fail -eq 0 ]]
