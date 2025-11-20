#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="$SCRIPT_DIR/config/application-sonic-agent.yml"
CONFIGED_FLAG_FILE="$SCRIPT_DIR/.configed_flag"

prompt_value() {
  local prompt default_value input
  prompt="$1"
  default_value="$2"
  if [ -n "$default_value" ]; then
    read -rp "$prompt [$default_value]: " input
    if [ -z "$input" ]; then
      input="$default_value"
    fi
  else
    while true; do
      read -rp "$prompt: " input
      if [ -n "$input" ]; then
        break
      fi
      echo "输入不能为空，请重新输入。" >&2
    done
  fi
  printf '%s' "$input"
}

read_agent_value() {
  local field
  field="$1"
  awk -v target="$field" '
    /^  agent:/ { section="agent"; next }
    /^  [^ ]/ { section="" }
    section=="agent" && $0 ~ target ":" {
      gsub(/.*: /, "")
      print
      exit
    }
  ' "$CONFIG_FILE"
}

update_agent_config() {
  local host="$1" port="$2" key="$3"
  python3 - "$CONFIG_FILE" "$host" "$port" "$key" <<'PY'
from pathlib import Path
import sys

path, host, port, key = sys.argv[1:]
lines = Path(path).read_text(encoding="utf-8").splitlines()

def in_agent_block(idx: int, content: str, state: dict):
    line = content
    if line.startswith("  agent:"):
        state["agent"] = True
    elif line.startswith("  ") and not line.startswith("    "):
        state["agent"] = False
    elif not line.startswith(" "):
        state["agent"] = False
    return state.get("agent", False)

state = {"agent": False}
for i, line in enumerate(lines):
    if in_agent_block(i, line, state):
        stripped = line.lstrip()
        if stripped.startswith("host:"):
            indent = line.split("host:", 1)[0] + "host: "
            lines[i] = f"{indent}{host}"
        elif stripped.startswith("port:"):
            indent = line.split("port:", 1)[0] + "port: "
            lines[i] = f"{indent}{port}"
        elif stripped.startswith("key:"):
            indent = line.split("key:", 1)[0] + "key: "
            lines[i] = f"{indent}{key}"

Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

detect_ipv4() {
  python3 <<'PY'
import socket

def get_local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        pass
    try:
        hostname = socket.gethostname()
        ip = socket.gethostbyname(hostname)
        if not ip.startswith("127."):
            return ip
    except OSError:
        pass
    return ""

ip = get_local_ip()
print(ip)
PY
}

if [ ! -f "$CONFIGED_FLAG_FILE" ]; then
  echo "首次运行，请配置 Sonic Agent："
  current_host="$(detect_ipv4)"
  current_port="$(read_agent_value 'port')"

  agent_host="$(read_agent_value 'host')"
  if [ -z "$current_host" ]; then
    echo "自动获取 IPv4 失败，请手动输入。"
    agent_host="$(prompt_value "请输入 Agent 主机 IPv4" "$agent_host")"
  else
    agent_host="$current_host"
    echo "检测到本机 IPv4：$agent_host"
  fi
  agent_port="$current_port"
  agent_key="$(prompt_value "请输入 Agent Key (联系管理员获取)" "")"

  update_agent_config "$agent_host" "$agent_port" "$agent_key"
  touch "$CONFIGED_FLAG_FILE"
  echo "配置已更新：$CONFIG_FILE"
fi

java -Dfile.encoding=utf-8 -jar sonic-agent-macosx-arm64.jar