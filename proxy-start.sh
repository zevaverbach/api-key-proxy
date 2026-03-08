#!/bin/sh
# Proxy startup wrapper — fetches ALL project secrets via bws run,
# then proxy.js reads only the keys listed in routes.json and scrubs the rest.
set -e

BWS="${BWS:-$HOME/.local/bin/bws}"
BWS_SERVER="${BWS_SERVER:-https://vault.bitwarden.eu}"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-28cd2389-0916-49fe-b1c6-b402007595fd}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export BWS_ACCESS_TOKEN=$(cat "$HOME/.config/bws/access-token")

exec "$BWS" run \
  --no-inherit-env \
  --project-id "$BWS_PROJECT_ID" \
  --server-url "$BWS_SERVER" \
  -- /usr/bin/node "$SCRIPT_DIR/proxy.js" "$SCRIPT_DIR/routes.json"
