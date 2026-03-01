#!/usr/bin/env bash
# test-lab-07-05.sh -- Lab 05: Mattermost Advanced Integration
# Tests: OpenLDAP bind, Keycloak realm+client, LDAP+OIDC+MinIO S3 env, API config
#
# Usage: bash tests/labs/test-lab-07-05.sh [--no-cleanup]
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.integration.yml"
KC_PORT=8106
MM_PORT=8105
LDAP_PORT=3891
MINIO_PORT=9100
KC_ADMIN=admin
KC_PASS="Lab05Admin!"
LDAP_ADMIN_DN="cn=admin,dc=lab,dc=local"
LDAP_PASS="LdapAdmin05!"
CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }
section() { echo ""; echo "=== $1 ==="; }
cleanup() { $CLEANUP && docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true; }
trap cleanup EXIT

section "Lab 07-05: Mattermost Advanced Integration"
echo "Compose file: $COMPOSE_FILE"

section "1. Start Containers"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."
sleep 30

section "2. Keycloak Health"
for i in $(seq 1 24); do
  if curl -sf "http://localhost:${KC_PORT}/health/ready" | grep -q "UP"; then
    pass "Keycloak health/ready UP"
    break
  fi
  [[ $i -eq 24 ]] && fail "Keycloak did not become healthy" && exit 1
  sleep 10
done

section "3. OpenLDAP Connectivity"
for i in $(seq 1 12); do
  if docker exec mm-int-ldap ldapsearch -x -H ldap://localhost \
     -b "dc=lab,dc=local" -D "$LDAP_ADMIN_DN" -w "$LDAP_PASS" \
     -s base "(objectClass=*)" >/dev/null 2>&1; then
    pass "LDAP admin bind successful"
    break
  fi
  [[ $i -eq 12 ]] && fail "LDAP bind failed after 120s"
  sleep 10
done

section "4. MinIO Health"
for i in $(seq 1 12); do
  if curl -sf "http://localhost:${MINIO_PORT}/minio/health/live" >/dev/null 2>&1; then
    pass "MinIO health/live responds"
    break
  fi
  [[ $i -eq 12 ]] && fail "MinIO did not become healthy"
  sleep 10
done

section "5. Keycloak Realm + Client"
KC_TOKEN=$(curl -sf "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=${KC_ADMIN}&password=${KC_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$KC_TOKEN" ]] && pass "Keycloak admin token obtained" || { fail "Keycloak admin token failed"; exit 1; }

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm":"it-stack","enabled":true}')
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "Realm it-stack created (HTTP $HTTP)" || fail "Realm creation failed (HTTP $HTTP)"

CLIENT_PAYLOAD='{"clientId":"mattermost-client","enabled":true,"protocol":"openid-connect","publicClient":false,"redirectUris":["http://localhost:'"${MM_PORT}"'/*"],"secret":"mattermost-secret-05"}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$CLIENT_PAYLOAD")
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "OIDC client mattermost-client created (HTTP $HTTP)" || fail "Client creation failed (HTTP $HTTP)"

section "6. Mattermost Health"
for i in $(seq 1 18); do
  if curl -sf "http://localhost:${MM_PORT}/api/v4/system/ping" | grep -q '"status":"OK"'; then
    pass "Mattermost /api/v4/system/ping OK"
    break
  fi
  [[ $i -eq 18 ]] && fail "Mattermost did not become ready"
  sleep 15
done

section "7. Integration Environment Variables"
MM_ENV=$(docker inspect mm-int-app --format '{{range .Config.Env}}{{.}} {{end}}')

echo "$MM_ENV" | grep -q "MM_LDAPSETTINGS_ENABLE=true" \
  && pass "MM_LDAPSETTINGS_ENABLE=true" \
  || fail "MM_LDAPSETTINGS_ENABLE missing"

echo "$MM_ENV" | grep -q "MM_LDAPSETTINGS_LDAPSERVER=mm-int-ldap" \
  && pass "MM_LDAPSETTINGS_LDAPSERVER=mm-int-ldap" \
  || fail "MM_LDAPSETTINGS_LDAPSERVER missing"

echo "$MM_ENV" | grep -q "MM_OPENIDSETTINGS_ENABLE=true" \
  && pass "MM_OPENIDSETTINGS_ENABLE=true" \
  || fail "MM_OPENIDSETTINGS_ENABLE missing"

echo "$MM_ENV" | grep -q "MM_OPENIDSETTINGS_ID=mattermost-client" \
  && pass "MM_OPENIDSETTINGS_ID=mattermost-client" \
  || fail "MM_OPENIDSETTINGS_ID missing"

echo "$MM_ENV" | grep -q "MM_FILESETTINGS_DRIVERNAME=amazons3" \
  && pass "MM_FILESETTINGS_DRIVERNAME=amazons3" \
  || fail "MM_FILESETTINGS_DRIVERNAME missing"

echo "$MM_ENV" | grep -q "MM_FILESETTINGS_AMAZONS3ENDPOINT=mm-int-minio:9000" \
  && pass "MM_FILESETTINGS_AMAZONS3ENDPOINT=mm-int-minio:9000" \
  || fail "MM_FILESETTINGS_AMAZONS3ENDPOINT missing"

section "8. Mattermost API Config Verification"
MM_CONFIG=$(curl -sf "http://localhost:${MM_PORT}/api/v4/config" 2>/dev/null || echo "{}")
echo "$MM_CONFIG" | grep -q '"Enable":true' \
  && pass "Mattermost API config shows Enable=true" \
  || fail "Mattermost API config Enable check inconclusive"

section "9. Keycloak OIDC Discovery"
if curl -sf "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" \
   | grep -q "authorization_endpoint"; then
  pass "Keycloak OIDC discovery endpoint responds"
else
  fail "Keycloak OIDC discovery endpoint unavailable"
fi

section "Summary"
echo "Passed: $PASS | Failed: $FAIL"
[[ $FAIL -eq 0 ]] && echo "Lab 07-05 PASSED" || { echo "Lab 07-05 FAILED"; exit 1; }