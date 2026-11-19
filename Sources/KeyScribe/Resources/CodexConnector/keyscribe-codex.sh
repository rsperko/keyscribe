#!/bin/sh
agents=__AGENTS_DIR__
app=__APP_NAME__
socket="$agents/bridge.sock"
limit=250000

post() {
  [ -S "$socket" ] || return 1
  token=$(cat "$agents/token" 2>/dev/null) || return 1
  printf %s "$2" | /usr/bin/curl -s --max-time "$3" --unix-socket "$socket" -H "Authorization: Bearer $token" \
    -H "X-KeyScribe-Agent: codex" -H "X-KeyScribe-Installation: $1" -H "Content-Type: application/json" -H "Expect:" \
    --data-binary @- http://localhost/report 2>/dev/null
}

field() {
  printf %s "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null
}

plain() {
  printf %s "$1" | tr -cd 'A-Za-z0-9_.:-'
}

clip() {
  head -c "$1" | iconv -c -f UTF-8 -t UTF-8
}

slim() {
  source= built=
  trap 'rm -f "$source" "$built"' EXIT
  trap 'exit 1' HUP INT TERM
  source=$(mktemp "${TMPDIR:-/tmp}/ksc.XXXXXX") || return 1
  built=$(mktemp "${TMPDIR:-/tmp}/ksc.XXXXXX") || return 1
  printf %s "$1" > "$source"
  rm -f "$built"
  /usr/bin/plutil -create xml1 "$built" || return 1
  for key in hook_event_name session_id turn_id tool_name; do
    value=$(/usr/bin/plutil -extract "$key" raw -o - "$source" 2>/dev/null | clip 1000) && [ -n "$value" ] && /usr/bin/plutil -insert "$key" -string "$value" "$built"
  done
  for key in prompt last_assistant_message; do
    value=$(/usr/bin/plutil -extract "$key" raw -o - "$source" 2>/dev/null | clip 200000) && [ -n "$value" ] && /usr/bin/plutil -insert "$key" -string "$value" "$built"
  done
  /usr/bin/plutil -insert tool_input -dictionary "$built"
  value=$(/usr/bin/plutil -extract tool_input.command raw -o - "$source" 2>/dev/null | clip 4000) && [ -n "$value" ] && /usr/bin/plutil -insert tool_input.command -string "$value" "$built"
  case "$(/usr/bin/plutil -type tool_input.questions.0 "$source" 2>/dev/null)" in
  dictionary) path=tool_input.questions.0.question ;;
  string) path=tool_input.questions.0 ;;
  *) path=tool_input.question ;;
  esac
  value=$(/usr/bin/plutil -extract "$path" raw -o - "$source" 2>/dev/null | clip 4000) && [ -n "$value" ] && /usr/bin/plutil -insert tool_input.question -string "$value" "$built"
  /usr/bin/plutil -convert json -o - "$built"
}

reply() {
  printf '%s\n' "$1"
}

case "$1" in
hook)
  body=$(cat)
  if [ "$(printf %s "$body" | wc -c)" -gt "$limit" ]; then
    body=$(slim "$body") || exit 0
  fi
  post "$(plain "$2")" "$body" 0.5 >/dev/null
  exit 0
  ;;
mcp)
  installation=$(plain "$2")
  while IFS= read -r line; do
    method=$(field "$line" method)
    id=$(field "$line" id)
    case "$id" in
    '') id=null ;;
    *[!0-9]*) id="\"$(plain "$id")\"" ;;
    esac
    case "$method" in
    initialize)
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"read-aloud\",\"version\":\"1\"}}}"
      ;;
    tools/list)
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"tell_me_when_done\",\"description\":\"The user has ${app}, a voice app on this Mac. Call this only when the user explicitly asks ${app}, or asks to hear it out loud, to report when the current work is done. Call it once, then keep working. When this turn ends, ${app} reports your final reply. If the work is already finished, answer instead of calling it. Not for a plain \\\"let me know\\\".\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}]}}"
      ;;
    tools/call)
      thread=$(plain "$(field "$line" params._meta.threadId)")
      turn=$(plain "$(field "$line" params._meta.x-codex-turn-metadata.turn_id)")
      answer=""
      if [ -n "$thread" ] && [ -n "$turn" ]; then
        answer=$(post "$installation" "{\"hook_event_name\":\"KeyScribeNotify\",\"session_id\":\"$thread\",\"turn_id\":\"$turn\"}" 4)
      fi
      case "$answer" in
      *'"quiet":true'*) text="This conversation is disconnected from ${app}. Tell the user to reconnect it in ${app}’s Agent settings. Nothing will be reported." ;;
      *'"spoken":true'*) text="${app} will report your final reply when this turn ends. Say so in one short sentence and continue." ;;
      *'"spoken":false'*) text="Read Agent Replies Aloud is off in ${app}. Tell the user to turn on Read Agent Replies Aloud in ${app}’s Agent settings and ask again. Nothing will be reported." ;;
      *) text="${app} didn’t confirm the request, so the reply may not be reported. Tell the user." ;;
      esac
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"$text\"}]}}"
      ;;
    ping)
      reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
      ;;
    *)
      [ "$id" = null ] || reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"unknown method\"}}"
      ;;
    esac
  done
  ;;
esac
exit 0
