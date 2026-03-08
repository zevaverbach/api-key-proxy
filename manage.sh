#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# manage.sh — add/remove/list proxy routes + Bitwarden secrets
#
# Requires: bws CLI, jq or python3
# Config:   BWS access token at ~/.config/bws/access-token
#           routes.json in the same directory as this script
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTES_FILE="$SCRIPT_DIR/routes.json"
BWS="${BWS:-$HOME/.local/bin/bws}"
BWS_SERVER="https://vault.bitwarden.eu"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-28cd2389-0916-49fe-b1c6-b402007595fd}"

# Load BWS access token
load_bws_token() {
  if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
    local token_file="$HOME/.config/bws/access-token"
    if [ -f "$token_file" ]; then
      BWS_ACCESS_TOKEN=$(cat "$token_file")
      export BWS_ACCESS_TOKEN
    else
      echo "Error: No BWS_ACCESS_TOKEN and $token_file not found" >&2
      exit 1
    fi
  fi
}

# JSON helper (works without jq)
py_json() {
  python3 -c "import sys,json; $1"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  add       Add a new proxied API route + Bitwarden secret
  remove    Remove a route (and optionally the Bitwarden secret)
  list      List current routes
  restart   Restart the proxy service

add options:
  --name <name>          Route label (e.g. "gemini")
  --port <port>          Local port to listen on
  --upstream <url>       Target API base URL
  --env <VAR_NAME>       Environment variable name for the key
  --value <secret>       The API key value (stored in Bitwarden)

remove options:
  --name <name>          Route to remove (by name)
  --delete-secret        Also delete the Bitwarden secret

Examples:
  $0 add --name gemini --port 18794 \\
    --upstream https://generativelanguage.googleapis.com \\
    --env GEMINI_API_KEY --value "AIzaSy..."

  $0 remove --name gemini
  $0 list
  $0 restart
EOF
}

cmd_add() {
  local name="" port="" upstream="" env_var="" value=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)     name="$2";     shift 2;;
      --port)     port="$2";     shift 2;;
      --upstream) upstream="$2"; shift 2;;
      --env)      env_var="$2";  shift 2;;
      --value)    value="$2";    shift 2;;
      *) echo "Unknown option: $1" >&2; exit 1;;
    esac
  done

  if [ -z "$name" ] || [ -z "$port" ] || [ -z "$upstream" ] || [ -z "$env_var" ] || [ -z "$value" ]; then
    echo "Error: all options required (--name, --port, --upstream, --env, --value)" >&2
    exit 1
  fi

  # Check for duplicate name or port
  local dup
  dup=$(py_json "
routes = json.load(open('$ROUTES_FILE'))
for r in routes:
    if r['name'] == '$name':
        print('name')
    if r['port'] == $port:
        print('port')
  ")
  if echo "$dup" | grep -q "name"; then
    echo "Error: route '$name' already exists" >&2; exit 1
  fi
  if echo "$dup" | grep -q "port"; then
    echo "Error: port $port already in use" >&2; exit 1
  fi

  # 1. Create secret in Bitwarden
  load_bws_token
  echo "Creating secret '$env_var' in Bitwarden..."
  local secret_out
  secret_out=$("$BWS" secret create "$env_var" "$value" "$BWS_PROJECT_ID" \
    --server-url "$BWS_SERVER" 2>&1) || {
    echo "Error creating secret: $secret_out" >&2; exit 1
  }
  local uuid
  uuid=$(echo "$secret_out" | py_json "print(json.load(sys.stdin)['id'])")
  echo "  Created: $env_var (UUID: $uuid)"

  # 2. Add route to routes.json
  py_json "
routes = json.load(open('$ROUTES_FILE'))
routes.append({
    'name': '$name',
    'port': $port,
    'upstream': '$upstream',
    'keyEnv': '$env_var'
})
json.dump(routes, open('$ROUTES_FILE', 'w'), indent=2)
print('  Added route: $name -> $upstream on :$port')
  "

  # 3. Restart
  echo "Restarting proxy..."
  systemctl --user restart api-key-proxy.service 2>/dev/null && echo "  Done." || echo "  (restart manually: systemctl --user restart api-key-proxy.service)"

  echo ""
  echo "Route '$name' added. The proxy will inject $env_var into requests to $upstream."
  echo ""
  echo "If OpenClaw was previously passing this key directly, update openclaw.json:"
  echo "  - Set the skill's apiKey to \"proxy-handled\""
  echo "  - Add env.OPENAI_BASE_URL or equivalent to point at http://127.0.0.1:$port"
  echo "  - Remove $env_var from openclaw-gateway-start.sh if present"
  echo "  - Restart: systemctl --user restart openclaw-gateway.service"
}

cmd_remove() {
  local name="" delete_secret=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)          name="$2"; shift 2;;
      --delete-secret) delete_secret=true; shift;;
      *) echo "Unknown option: $1" >&2; exit 1;;
    esac
  done

  if [ -z "$name" ]; then
    echo "Error: --name required" >&2; exit 1
  fi

  # Find and remove route
  local key_env
  key_env=$(py_json "
routes = json.load(open('$ROUTES_FILE'))
found = [r for r in routes if r['name'] == '$name']
if not found:
    print('NOT_FOUND')
else:
    print(found[0]['keyEnv'])
    routes = [r for r in routes if r['name'] != '$name']
    json.dump(routes, open('$ROUTES_FILE', 'w'), indent=2)
  ")

  if [ "$key_env" = "NOT_FOUND" ]; then
    echo "Error: route '$name' not found" >&2; exit 1
  fi

  echo "Removed route '$name' ($key_env)"

  if $delete_secret; then
    load_bws_token
    echo "Finding secret '$key_env' in Bitwarden..."
    local uuid
    uuid=$("$BWS" secret list "$BWS_PROJECT_ID" --server-url "$BWS_SERVER" 2>/dev/null \
      | py_json "
secrets = json.load(sys.stdin)
matches = [s for s in secrets if s['key'] == '$key_env']
print(matches[0]['id'] if matches else 'NOT_FOUND')
      ")
    if [ "$uuid" != "NOT_FOUND" ]; then
      "$BWS" secret delete "$uuid" --server-url "$BWS_SERVER" 2>/dev/null
      echo "  Deleted secret $key_env ($uuid)"
    else
      echo "  Secret '$key_env' not found in Bitwarden"
    fi
  fi

  echo "Restarting proxy..."
  systemctl --user restart api-key-proxy.service 2>/dev/null && echo "  Done." || echo "  (restart manually)"
}

cmd_list() {
  echo "Current routes ($ROUTES_FILE):"
  echo ""
  py_json "
routes = json.load(open('$ROUTES_FILE'))
if not routes:
    print('  (none)')
else:
    for r in routes:
        print(f\"  {r['name']:15s} :{r['port']}  ->  {r['upstream']:40s}  key: {r['keyEnv']}\")
  "
}

cmd_restart() {
  echo "Restarting api-key-proxy.service..."
  systemctl --user restart api-key-proxy.service
  echo "Done."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ $# -lt 1 ]; then
  usage; exit 1
fi

cmd="$1"; shift

case "$cmd" in
  add)     cmd_add "$@";;
  remove)  cmd_remove "$@";;
  list)    cmd_list;;
  restart) cmd_restart;;
  help|-h|--help) usage;;
  *) echo "Unknown command: $cmd" >&2; usage; exit 1;;
esac
