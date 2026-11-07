#!/bin/zsh
# Diagnoses one Switchboard chat by ID (switchboard-chat:<UUID>, chat, agent session or turn UUID): chat record,
# agent session and transcript path, latest turns, app events, refused requests and the latest transcript events.
# Usage: zsh scripts/chat-lookup.sh <ID> [--events N] [--before K]
# Reads the app's data read-only; SWITCHBOARD_DATA_ROOT points it at another data folder.
set -eu
if [[ $# -lt 1 ]]; then
  print -u2 "usage: zsh scripts/chat-lookup.sh <chat ID or switchboard-chat:ID> [--events N] [--before K]"
  exit 2
fi
id=$1; shift
server=${0:A:h:h}/ChatDirectoryRuntime/server.py
cd /tmp
exec /usr/bin/python3 -I "$server" --inspect "$id" "$@"
