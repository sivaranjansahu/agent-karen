#!/usr/bin/env bash
# setup.sh — Bootstrap Mattermost for agent-scaffold
#
# 1. Starts Mattermost via docker-compose
# 2. Waits for it to be ready
# 3. Creates admin user, team, channels, and bot via REST API
# 4. Writes config to ../.agent/state/mattermost.env
#
# Usage: ./mattermost/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT/.agent/state/mattermost.env"
MM_URL="http://localhost:8065"

# Configurable defaults
ADMIN_USER="${MM_ADMIN_USER:-admin}"
ADMIN_PASS="${MM_ADMIN_PASS:-Admin1234!}"
ADMIN_EMAIL="${MM_ADMIN_EMAIL:-admin@scaffold.local}"
TEAM_NAME="${MM_TEAM_NAME:-agents}"
BOT_NAME="${MM_BOT_NAME:-scaffold-bot}"

echo "▸ Starting Mattermost..."
cd "$SCRIPT_DIR"
docker compose up -d

echo "▸ Waiting for Mattermost to be ready..."
for i in $(seq 1 60); do
  if curl -sf "$MM_URL/api/v4/system/ping" > /dev/null 2>&1; then
    echo "  ✓ Mattermost is up"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "  ✗ Timed out waiting for Mattermost"
    exit 1
  fi
  sleep 2
done

# --- REST API helpers ---

api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Content-Type: application/json" \
    "$@" \
    "$MM_URL/api/v4$endpoint"
}

api_auth() {
  local method="$1" endpoint="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$@" \
    "$MM_URL/api/v4$endpoint"
}

# --- 1. Create admin user ---
echo "▸ Creating admin user..."
CREATE_RESULT=$(api POST "/users" \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\",\"email\":\"$ADMIN_EMAIL\"}" 2>&1 || echo "exists")

if echo "$CREATE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'id' in d else 1)" 2>/dev/null; then
  echo "  ✓ Admin user created"
else
  echo "  (admin user already exists)"
fi

# --- 2. Log in as admin ---
echo "▸ Logging in as admin..."
LOGIN_RESPONSE=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  -D - \
  -d "{\"login_id\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  "$MM_URL/api/v4/users/login" 2>&1)

ADMIN_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -i "^token:" | tr -d '\r' | awk '{print $2}')

if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "  ✗ Login failed. Response:"
  echo "$LOGIN_RESPONSE" | tail -3
  exit 1
fi
echo "  ✓ Logged in (token acquired)"

# --- 3. Get admin user ID and promote to system admin ---
ADMIN_ID=$(api_auth GET "/users/username/$ADMIN_USER" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
api_auth PUT "/users/$ADMIN_ID/roles" -d '{"roles":"system_admin system_user"}' > /dev/null 2>&1 || true

# --- 4. Create team ---
echo "▸ Creating team: $TEAM_NAME..."
TEAM_RESULT=$(api_auth POST "/teams" \
  -d "{\"name\":\"$TEAM_NAME\",\"display_name\":\"Agent Scaffold\",\"type\":\"O\"}" 2>&1 || echo "")

TEAM_ID=$(echo "$TEAM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [[ -z "$TEAM_ID" ]]; then
  # Team exists — fetch its ID
  TEAM_ID=$(api_auth GET "/teams/name/$TEAM_NAME" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "  (team already exists)"
else
  echo "  ✓ Team created"
fi

# --- 5. Add admin to team ---
api_auth POST "/teams/$TEAM_ID/members" \
  -d "{\"team_id\":\"$TEAM_ID\",\"user_id\":\"$ADMIN_ID\"}" > /dev/null 2>&1 || true

# --- 6. Create channels ---
echo "▸ Creating channels..."
for ch in general tasks escalations; do
  DISPLAY_NAME=$(python3 -c "print('$ch'.capitalize())")
  CH_RESULT=$(api_auth POST "/channels" \
    -d "{\"team_id\":\"$TEAM_ID\",\"name\":\"$ch\",\"display_name\":\"$DISPLAY_NAME\",\"type\":\"O\"}" 2>&1 || echo "")
  if echo "$CH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'id' in d else 1)" 2>/dev/null; then
    echo "  ✓ #$ch created"
  else
    echo "  (#$ch already exists)"
  fi
done

# --- 7. Enable bot accounts ---
echo "▸ Enabling bot accounts..."
CONFIG=$(api_auth GET "/config")
UPDATED_CONFIG=$(echo "$CONFIG" | python3 -c "
import sys, json
c = json.load(sys.stdin)
c.setdefault('ServiceSettings', {})['EnableBotAccountCreation'] = True
c.setdefault('ServiceSettings', {})['EnableUserAccessTokens'] = True
json.dump(c, sys.stdout)
")
api_auth PUT "/config" -d "$UPDATED_CONFIG" > /dev/null 2>&1
echo "  ✓ Bot accounts enabled"

# --- 8. Create bot ---
echo "▸ Creating bot account: $BOT_NAME..."
BOT_RESULT=$(api_auth POST "/bots" \
  -d "{\"username\":\"$BOT_NAME\",\"display_name\":\"Scaffold Bot\",\"description\":\"Agent message relay\"}" 2>&1 || echo "")

BOT_USER_ID=$(echo "$BOT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('user_id',''))" 2>/dev/null || echo "")

if [[ -z "$BOT_USER_ID" ]]; then
  echo "  (bot already exists)"
  BOT_USER_ID=$(api_auth GET "/bots/username/$BOT_NAME" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('user_id',''))" 2>/dev/null || echo "")
  if [[ -z "$BOT_USER_ID" ]]; then
    # Try fetching as user
    BOT_USER_ID=$(api_auth GET "/users/username/$BOT_NAME" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  fi
else
  echo "  ✓ Bot created"
fi

# --- 9. Create bot token ---
echo "▸ Generating bot token..."
BOT_TOKEN=""
if [[ -n "$BOT_USER_ID" ]]; then
  TOKEN_RESULT=$(api_auth POST "/users/$BOT_USER_ID/tokens" \
    -d '{"description":"scaffold-agent-token"}' 2>&1 || echo "")
  BOT_TOKEN=$(echo "$TOKEN_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo "  ⚠ Could not generate bot token automatically."
  echo "  → Log in at $MM_URL, go to Integrations > Bot Accounts > $BOT_NAME > Create Token"
  echo "  → Then set MM_BOT_TOKEN in $ENV_FILE"
  BOT_TOKEN="PASTE_TOKEN_HERE"
else
  echo "  ✓ Bot token generated"
fi

# --- 10. Add bot to channels ---
echo "▸ Adding bot to channels..."
if [[ -n "$BOT_USER_ID" ]]; then
  for ch in general tasks escalations; do
    CH_ID=$(api_auth GET "/teams/$TEAM_ID/channels/name/$ch" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
    if [[ -n "$CH_ID" ]]; then
      api_auth POST "/channels/$CH_ID/members" \
        -d "{\"user_id\":\"$BOT_USER_ID\"}" > /dev/null 2>&1 || true
    fi
  done
  echo "  ✓ Bot added to all channels"
fi

# --- Resolve channel IDs ---
echo "▸ Resolving channel IDs..."
CH_ID_GENERAL=$(api_auth GET "/teams/$TEAM_ID/channels/name/general" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
CH_ID_TASKS=$(api_auth GET "/teams/$TEAM_ID/channels/name/tasks" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
CH_ID_ESCALATIONS=$(api_auth GET "/teams/$TEAM_ID/channels/name/escalations" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

# --- Write env file ---
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<EOF
# Mattermost config for agent-scaffold (auto-generated)
MM_URL=$MM_URL
MM_TEAM=$TEAM_NAME
MM_TEAM_ID=$TEAM_ID
MM_BOT_TOKEN=$BOT_TOKEN
MM_CHANNEL_GENERAL=general
MM_CHANNEL_TASKS=tasks
MM_CHANNEL_ESCALATIONS=escalations
MM_CHANNEL_ID_GENERAL=$CH_ID_GENERAL
MM_CHANNEL_ID_TASKS=$CH_ID_TASKS
MM_CHANNEL_ID_ESCALATIONS=$CH_ID_ESCALATIONS
MM_ADMIN_USER=$ADMIN_USER
EOF

echo ""
echo "✓ Mattermost ready at $MM_URL"
echo "  Admin: $ADMIN_USER / $ADMIN_PASS"
echo "  Config: $ENV_FILE"
if [[ "$BOT_TOKEN" == "PASTE_TOKEN_HERE" ]]; then
  echo "  ⚠ Bot token needs manual setup — see instructions above"
else
  echo "  ✓ Fully configured — chat.sh is ready to use"
fi
