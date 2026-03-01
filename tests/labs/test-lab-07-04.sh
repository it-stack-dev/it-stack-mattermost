#!/usr/bin/env bash
# test-lab-07-04.sh — Lab 07-04: Mattermost SSO Integration
# Tests: Keycloak running, OpenID Connect settings in MM env, OIDC discovery endpoint
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.sso.yml"
KC_PORT="8085"
MM_API="http://localhost:8065/api/v4"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

section "Container health"
for c in mm-sso-db mm-sso-redis mm-sso-keycloak mm-sso-app; do
  if docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    pass "Container $c is running"
  else
    fail "Container $c is not running"
  fi
done

section "PostgreSQL connectivity"
if docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U mmuser -d mattermost 2>/dev/null | grep -q "accepting"; then
  pass "PostgreSQL accepting connections"
else
  fail "PostgreSQL not ready"
fi

section "Keycloak health"
KC_HEALTH=$(curl -sf "http://localhost:${KC_PORT}/health/ready" 2>/dev/null) || KC_HEALTH=""
if echo "$KC_HEALTH" | grep -q "UP"; then
  pass "Keycloak health/ready = UP"
else
  fail "Keycloak health/ready not UP"
fi

section "Keycloak admin API + realm"
KC_TOKEN=$(curl -sf -X POST \
  "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=Lab04Admin!&grant_type=password" 2>/dev/null \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4) || KC_TOKEN=""
if [ -n "$KC_TOKEN" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin login failed"
fi

if [ -n "$KC_TOKEN" ]; then
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true}' 2>/dev/null || true
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"clientId":"mattermost-client","enabled":true,"publicClient":false,"secret":"mattermost-secret-04","redirectUris":["http://localhost:8065/*"],"standardFlowEnabled":true}' \
    2>/dev/null || true
  CLIENTS=$(curl -sf "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=mattermost-client" \
    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null) || CLIENTS=""
  if echo "$CLIENTS" | grep -q '"clientId":"mattermost-client"'; then
    pass "Keycloak OIDC client 'mattermost-client' configured"
  else
    fail "Keycloak OIDC client 'mattermost-client' not found"
  fi
else
  fail "Skipping client check (no admin token)"
fi

section "Mattermost OIDC env vars"
MM_ENV=$(docker inspect mm-sso-app --format '{{json .Config.Env}}' 2>/dev/null) || MM_ENV="[]"
if echo "$MM_ENV" | grep -q '"MM_OPENIDSETTINGS_ENABLE=true"'; then
  pass "MM_OPENIDSETTINGS_ENABLE=true set"
else
  fail "MM_OPENIDSETTINGS_ENABLE=true not found in env"
fi
if echo "$MM_ENV" | grep -q "MM_OPENIDSETTINGS_DISCOVERYENDPOINT"; then
  pass "MM_OPENIDSETTINGS_DISCOVERYENDPOINT configured"
else
  fail "MM_OPENIDSETTINGS_DISCOVERYENDPOINT not found in env"
fi
if echo "$MM_ENV" | grep -q "MM_OPENIDSETTINGS_ID=mattermost-client"; then
  pass "MM_OPENIDSETTINGS_ID=mattermost-client set"
else
  fail "MM_OPENIDSETTINGS_ID not set to 'mattermost-client'"
fi

section "Mattermost API ping"
PING=$(curl -sf "$MM_API/system/ping" 2>/dev/null) || PING=""
if echo "$PING" | grep -q "status"; then
  pass "Mattermost API /system/ping reachable"
else
  fail "Mattermost API /system/ping failed"
fi

section "Mattermost admin login"
REGISTER=$(curl -sf -X POST "$MM_API/users" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@lab.local","username":"admin04","password":"Lab04Admin!","first_name":"Admin","last_name":"Lab04"}' \
  2>/dev/null) || REGISTER=""
if echo "$REGISTER" | grep -qE '"id"|already'; then
  pass "Admin user ready"
else
  fail "Admin user registration failed"
fi
TOKEN_RESP=$(curl -si -X POST "$MM_API/users/login" \
  -H "Content-Type: application/json" \
  -d '{"login_id":"admin04","password":"Lab04Admin!"}' 2>/dev/null) || TOKEN_RESP=""
MM_TOKEN=$(echo "$TOKEN_RESP" | grep -i "^Token:" | awk '{print $2}' | tr -d '[:space:]') || MM_TOKEN=""
if [ -n "$MM_TOKEN" ]; then
  pass "Mattermost admin login successful"
else
  fail "Mattermost admin login failed"
fi

section "Mattermost OIDC in API config"
if [ -n "$MM_TOKEN" ]; then
  CONFIG=$(curl -sf -H "Authorization: Bearer $MM_TOKEN" "$MM_API/config" 2>/dev/null) || CONFIG=""
  if echo "$CONFIG" | grep -q '"Enable":true'; then
    pass "OpenID Connect enabled in MM config API"
  else
    fail "OpenID Connect not enabled in MM config API"
  fi
else
  fail "Skipping config API check (no token)"
fi

section "Keycloak OIDC discovery endpoint"
KC_OIDC=$(curl -sf "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null) || KC_OIDC=""
if echo "$KC_OIDC" | grep -q '"issuer"'; then
  pass "Keycloak OIDC discovery endpoint reachable"
else
  fail "Keycloak OIDC discovery endpoint failed"
fi

echo
echo "====================================="
echo "  Mattermost Lab 07-04 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1