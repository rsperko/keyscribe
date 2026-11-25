#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/Sources/KeyScribe/Resources/CodexConnector/keyscribe-codex.sh"
WORK="$(mktemp -d /tmp/kscx.XXXXXX)"
AGENTS="$WORK/agents dir"
EXE="$WORK/keyscribe-codex"
SOCKET="$AGENTS/bridge.sock"
PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$AGENTS"
quoted="'${AGENTS//\'/\'\\\'\'}'"
sed -e "s|__AGENTS_DIR__|$quoted|" -e "s|__APP_NAME__|TestApp|g" "$TEMPLATE" > "$EXE"
chmod 755 "$EXE"

check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "ok - $1"
  else
    FAIL=$((FAIL + 1))
    echo "not ok - $1"
    echo "    expected: $3"
    echo "    actual:   $2"
  fi
}

contains() {
  case "$2" in
  *"$3"*) check "$1" yes yes ;;
  *) check "$1" "$2" "contains: $3" ;;
  esac
}

now() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

serve() {
  rm -f "$SOCKET"
  (timeout 10 /usr/bin/perl -MIO::Socket::UNIX -e '
    my ($path, $out, $reply) = @ARGV;
    my $server = IO::Socket::UNIX->new(Local => $path, Listen => 1) or exit 1;
    my $client = $server->accept or exit 1;
    my $data = "";
    while ($data !~ /\r\n\r\n/) { my $n = sysread($client, my $chunk, 65536); last unless $n; $data .= $chunk; }
    my ($length) = $data =~ /Content-Length:\s*(\d+)/i;
    my $body = length($data) - index($data, "\r\n\r\n") - 4;
    while (defined $length && $body < $length) { my $n = sysread($client, my $chunk, 65536); last unless $n; $data .= $chunk; $body += $n; }
    open(my $file, ">", $out); print $file $data; close $file;
    select(undef, undef, undef, 0.3);
    print $client "HTTP/1.1 200 OK\r\nContent-Length: " . length($reply) . "\r\nConnection: close\r\n\r\n" . $reply;
    close $client;
  ' "$SOCKET" "$WORK/request" "$1" &)
  for _ in $(seq 50); do [ -S "$SOCKET" ] && return; sleep 0.02; done
}

mcp() {
  printf '%s\n' "$@" | timeout 10 "$EXE" mcp inst-1
}

text_of() {
  printf %s "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null
}

rm -f "$SOCKET"
printf 'token-1' > "$AGENTS/token"
start=$(now)
out=$(printf '{"hook_event_name":"Stop"}' | "$EXE" hook inst-1; echo "status=$?")
elapsed=$(( $(now) - start ))
check "a hook with no bridge exits 0 and prints nothing" "$out" "status=0"
check "a hook with no bridge returns at once" "$([ "$elapsed" -lt 500 ] && echo fast || echo "$elapsed ms")" fast

oversized=$(head -c 400000 /dev/zero | tr '\0' 'a')
trace=$(printf '{"hook_event_name":"Stop","last_assistant_message":"%s"}' "$oversized" | /bin/sh -x "$EXE" hook inst-1 2>&1 > /dev/null)
check "an oversized hook with no bridge is dropped without being reshaped" "$(printf %s "$trace" | grep -c plutil)" 0

: > "$SOCKET"
out=$(printf '{}' | "$EXE" hook inst-1; echo "status=$?")
check "a hook facing a file where the socket should be exits 0" "$out" "status=0"
rm -f "$SOCKET"

mv "$AGENTS/token" "$AGENTS/token.away"
serve '{"ok":true}'
out=$(printf '{}' | "$EXE" hook inst-1; echo "status=$?")
check "a hook with no token exits 0" "$out" "status=0"
mv "$AGENTS/token.away" "$AGENTS/token"
printf 'x' | timeout 2 /usr/bin/nc -U "$SOCKET" > /dev/null 2>&1

body='{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"100% \"quoted\" ünïcode"}'
serve '{"ok":true}'
out=$(printf '%s' "$body" | "$EXE" hook "inst-1"; echo "status=$?")
sleep 0.2
request=$(cat "$WORK/request")
check "a hook prints nothing and exits 0 after reporting" "$out" "status=0"
contains "the report is a POST to the event-only path" "$request" "POST /report HTTP/1.1"
contains "the report carries the bridge token" "$request" "Authorization: Bearer token-1"
contains "the report names its agent" "$request" "X-KeyScribe-Agent: codex"
contains "the report names its installation" "$request" "X-KeyScribe-Installation: inst-1"
contains "the report carries the payload unchanged" "$request" "$body"
check "the declared length is the payload's byte count" "$(printf %s "$request" | grep -i '^Content-Length:' | tr -d '\r' | awk '{print $2}')" "$(printf %s "$body" | wc -c | tr -d ' ')"

serve '{"ok":true}'
printf '{}' | "$EXE" hook 'inst-1;rm -rf /' > /dev/null
sleep 0.2
contains "an installation is reduced to plain characters" "$(cat "$WORK/request")" "X-KeyScribe-Installation: inst-1rm-rf"

long=$(head -c 400000 /dev/zero | tr '\0' 'a')
serve '{"ok":true}'
printf '{"hook_event_name":"Stop","session_id":"019a-t1","turn_id":"019a-u1","transcript_path":"/x","last_assistant_message":"%s ünï end"}' "$long" | "$EXE" hook inst-1 > /dev/null
sleep 0.6
request=$(cat "$WORK/request")
sent=$(perl -0777 -ne 'print $1 if /\r\n\r\n(.*)/s' "$WORK/request")
check "an oversized report is cut below the bridge limit" "$([ "$(printf %s "$sent" | wc -c)" -le 262144 ] && echo under || echo over)" under
check "an oversized report keeps its event" "$(text_of "$sent" hook_event_name)" Stop
check "an oversized report keeps its conversation" "$(text_of "$sent" session_id)" 019a-t1
check "an oversized report keeps its turn" "$(text_of "$sent" turn_id)" 019a-u1
check "an oversized reply keeps its opening words" "$(text_of "$sent" last_assistant_message | head -c 5)" aaaaa
check "an oversized report drops what is not read" "$(text_of "$sent" transcript_path)" ""

serve '{"ok":true}'
printf '{"hook_event_name":"PreToolUse","session_id":"019a-t1","turn_id":"019a-u1","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Which one?","options":["%s"]}]}}' "$long" | "$EXE" hook inst-1 > /dev/null
sleep 0.6
sent=$(perl -0777 -ne 'print $1 if /\r\n\r\n(.*)/s' "$WORK/request")
check "an oversized question keeps its first question" "$(text_of "$sent" tool_input.question)" "Which one?"

rm -f "$SOCKET"
replies=$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":"a2","method":"tools/list"}' '{"jsonrpc":"2.0","id":3,"method":"nope"}')
check "the MCP server answers each request once and no notification" "$(printf '%s\n' "$replies" | wc -l | tr -d ' ')" 3
first=$(printf '%s\n' "$replies" | sed -n 1p)
second=$(printf '%s\n' "$replies" | sed -n 2p)
third=$(printf '%s\n' "$replies" | sed -n 3p)
check "initialize answers its id" "$(text_of "$first" id)" 1
check "a string id is answered as given" "$(text_of "$second" id)" a2
check "the one tool is tell_me_when_done" "$(text_of "$second" result.tools.0.name)" tell_me_when_done
contains "the tool names the app" "$(text_of "$second" result.tools.0.description)" "The user has TestApp, a voice app on this Mac."
check "an unknown method is an error" "$(text_of "$third" error.code)" -32601

call='{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"tell_me_when_done","arguments":{},"_meta":{"threadId":"019a-t1","x-codex-turn-metadata":{"turn_id":"019a-u1"}}}}'

answer=$(mcp "$call")
contains "with no bridge the tool promises nothing" "$(text_of "$answer" result.content.0.text)" "didn’t confirm the request"

serve '{"ok":true,"spoken":true}'
answer=$(mcp "$call")
sleep 0.2
contains "a confirmed request says the reply will be reported" "$(text_of "$answer" result.content.0.text)" "TestApp will report your final reply"
contains "the request asks to be told when the turn ends" "$(cat "$WORK/request")" '{"hook_event_name":"KeyScribeNotify","session_id":"019a-t1","turn_id":"019a-u1"}'

serve '{"ok":true,"spoken":false}'
answer=$(mcp "$call")
contains "read aloud turned off is said so" "$(text_of "$answer" result.content.0.text)" "Read Agent Replies Aloud is off in TestApp"

serve '{"ok":true,"quiet":true}'
answer=$(mcp "$call")
contains "a disconnected conversation is said so" "$(text_of "$answer" result.content.0.text)" "disconnected from TestApp"

rm -f "$SOCKET"
(timeout 10 /usr/bin/nc -lU "$SOCKET" > /dev/null 2>&1 < <(sleep 8) &)
for _ in $(seq 50); do [ -S "$SOCKET" ] && break; sleep 0.02; done
start=$(now)
answer=$(mcp "$call")
elapsed=$(( $(now) - start ))
contains "a bridge that never answers promises nothing" "$(text_of "$answer" result.content.0.text)" "didn’t confirm the request"
check "the one wait is bounded" "$([ "$elapsed" -lt 6000 ] && echo bounded || echo "$elapsed ms")" bounded

echo "test-codex-connector: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
