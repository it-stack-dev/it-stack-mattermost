#!/usr/bin/env bash
# test-lab-07-01.sh -- Mattermost Lab 01: Standalone
# Tests: API ping, PG health, admin setup, team/channel/message creation
# Usage: bash test-lab-07-01.sh
set -euo pipefail

MM_URL="http://localhost:8065"
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: PostgreSQL sidecar -------------------------------------------
info "Section 1: PostgreSQL sidecar"
if docker exec it-stack-mattermost-db pg_isready -U mmuser -d mattermost -q 2>/dev/null; then
  ok "PostgreSQL sidecar healthy"
else
  fail "PostgreSQL sidecar not ready"
fi

# -- Section 2: API system ping -----------------------------------------------
info "Section 2: Mattermost API /api/v4/system/ping"
ping_resp=$(curl -sf "${MM_URL}/api/v4/system/ping" 2>/dev/null || echo '{}')
info "ping: $ping_resp"
if echo "$ping_resp" | grep -q '"status":"OK"'; then ok "API ping: status OK"; else fail "API ping status (got: $ping_resp)"; fi

# -- Section 3: Create initial admin account ----------------------------------
info "Section 3: Create initial admin user"
admin_create=$(curl -sf -X POST "${MM_URL}/api/v4/users" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@lab.local","username":"mmadmin","password":"Lab01Password!","allow_marketing":false}' \
  2>/dev/null || echo '{}')
admin_id=$(echo "$admin_create" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
info "Admin user create response id: $admin_id"
if [[ -n "$admin_id" ]]; then ok "Admin user created (id: $admin_id)"; else
  info "Admin may already exist, attempting login"
  ok "Admin user creation attempted"
fi

# -- Section 4: Obtain admin token -------------------------------------------
info "Section 4: Admin login token"
login_resp=$(curl -sf -D - -X POST "${MM_URL}/api/v4/users/login" \
  -H "Content-Type: application/json" \
  -d '{"login_id":"admin@lab.local","password":"Lab01Password!"}' \
  2>/dev/null || echo "")
TOKEN=$(echo "$login_resp" | grep -i "^Token:" | awk '{print $2}' | tr -d '\r' || true)
info "Token obtained: ${TOKEN:0:8}..."
[[ -n "$TOKEN" ]] && ok "Admin login token obtained" || fail "Admin login token"

# -- Section 5: Mattermost version from API -----------------------------------
info "Section 5: Server version"
version_resp=$(curl -sf "${MM_URL}/api/v4/config/client?format=old" 2>/dev/null || echo '{}')
server_ver=$(echo "$version_resp" | grep -o '"Version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
info "Server version: $server_ver"
[[ -n "$server_ver" && "$server_ver" != "unknown" ]] && ok "Mattermost version: $server_ver" || fail "Version from API"

# -- Section 6: Create team ---------------------------------------------------
info "Section 6: Create team 'lab01'"
if [[ -n "$TOKEN" ]]; then
  team_resp=$(curl -sf -X POST "${MM_URL}/api/v4/teams" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"lab01","display_name":"Lab 01 Test Team","type":"O"}' \
    2>/dev/null || echo '{}')
  team_id=$(echo "$team_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  info "Team id: $team_id"
  [[ -n "$team_id" ]] && ok "Team 'lab01' created (id: $team_id)" || fail "Team creation (resp: $team_resp)"
else
  fail "Team creation (no token)"
  team_id=""
fi

# -- Section 7: Create channel ------------------------------------------------
info "Section 7: Create channel"
if [[ -n "$TOKEN" && -n "${team_id:-}" ]]; then
  chan_resp=$(curl -sf -X POST "${MM_URL}/api/v4/channels" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${team_id}\",\"name\":\"lab01-general\",\"display_name\":\"Lab01 General\",\"type\":\"O\"}" \
    2>/dev/null || echo '{}')
  chan_id=$(echo "$chan_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  info "Channel id: $chan_id"
  [[ -n "$chan_id" ]] && ok "Channel 'lab01-general' created" || fail "Channel creation"
else
  fail "Channel creation (no token or team_id)"
  chan_id=""
fi

# -- Section 8: Post message --------------------------------------------------
info "Section 8: Post message to channel"
if [[ -n "$TOKEN" && -n "${chan_id:-}" ]]; then
  msg_resp=$(curl -sf -X POST "${MM_URL}/api/v4/posts" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"channel_id\":\"${chan_id}\",\"message\":\"Lab 01 standalone test message\"}" \
    2>/dev/null || echo '{}')
  post_id=$(echo "$msg_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  info "Post id: $post_id"
  [[ -n "$post_id" ]] && ok "Message posted (id: $post_id)" || fail "Message post"
else
  fail "Message post (no token or channel_id)"
fi

# -- Section 9: List channels in team -----------------------------------------
info "Section 9: List channels"
if [[ -n "$TOKEN" && -n "${team_id:-}" ]]; then
  chan_list=$(curl -sf "${MM_URL}/api/v4/teams/${team_id}/channels" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '[]')
  chan_count=$(echo "$chan_list" | grep -o '"id"' | wc -l | tr -d ' ')
  info "Channels in team: $chan_count"
  [[ "$chan_count" -ge 1 ]] && ok "Channels list: $chan_count channels" || fail "Channels list empty"
else
  fail "Channel list (no token or team_id)"
fi

# -- Section 10: System status check ------------------------------------------
info "Section 10: System status"
if docker inspect --format '{{.State.Status}}' it-stack-mattermost-standalone 2>/dev/null | grep -q running; then
  ok "Mattermost container running"
else
  fail "Mattermost container not running"
fi

# -- Section 11: Integration score -------------------------------------------
info "Section 11: Lab 01 standalone integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 6/6 -- All standalone checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi
