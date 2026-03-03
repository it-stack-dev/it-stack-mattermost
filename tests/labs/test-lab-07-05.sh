#!/usr/bin/env bash
# test-lab-07-05.sh -- Lab 05: Mattermost Advanced Integration (INT-03)
# Tests: LDAP seed verify, OpenLDAP bind, Keycloak realm+client+LDAP federation,
#        LDAP user sync into Mattermost, OIDC token issuance, API config, S3 env
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

section "3b. LDAP Seed Verification"
# Verify mm-int-ldap-seed successfully added FreeIPA-compatible entries
USERS_COUNT=$(docker exec mm-int-ldap ldapsearch -x -H ldap://localhost \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_PASS" \
  -b "cn=users,cn=accounts,dc=lab,dc=local" "(objectClass=inetOrgPerson)" uid \
  2>/dev/null | grep -c "^uid:" || echo "0")
[[ "${USERS_COUNT}" -ge 3 ]] \
  && pass "LDAP seed: ${USERS_COUNT} inetOrgPerson users found (≥3)" \
  || fail "LDAP seed: only ${USERS_COUNT} users found in cn=users,cn=accounts (expected ≥3)"

GROUPS_COUNT=$(docker exec mm-int-ldap ldapsearch -x -H ldap://localhost \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_PASS" \
  -b "cn=groups,cn=accounts,dc=lab,dc=local" "(objectClass=groupOfNames)" cn \
  2>/dev/null | grep -c "^cn:" || echo "0")
[[ "${GROUPS_COUNT}" -ge 2 ]] \
  && pass "LDAP seed: ${GROUPS_COUNT} groups found (≥2)" \
  || fail "LDAP seed: only ${GROUPS_COUNT} groups found in cn=groups,cn=accounts (expected ≥2)"

# Verify readonly bind (used by Keycloak federation)
docker exec mm-int-ldap ldapsearch -x -H ldap://localhost \
  -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
  -b "dc=lab,dc=local" -s base "(objectClass=*)" >/dev/null 2>&1 \
  && pass "LDAP readonly bind successful" \
  || fail "LDAP readonly bind failed"

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

# Add FreeIPA-style LDAP user federation component to realm
LDAP_COMP_PAYLOAD=$(cat <<'EOLDAP'
{
  "name": "freeipa-users",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "enabled": ["true"],
    "priority": ["0"],
    "vendor": ["rhds"],
    "connectionUrl": ["ldap://mm-int-ldap:389"],
    "bindDn": ["cn=readonly,dc=lab,dc=local"],
    "bindCredential": ["ReadOnly05!"],
    "usersDn": ["cn=users,cn=accounts,dc=lab,dc=local"],
    "userObjectClasses": ["inetOrgPerson"],
    "usernameLDAPAttribute": ["uid"],
    "uuidLDAPAttribute": ["uid"],
    "rdnLDAPAttribute": ["uid"],
    "searchScope": ["1"],
    "syncRegistrations": ["true"],
    "importEnabled": ["true"],
    "batchSizeForSync": ["100"],
    "fullSyncPeriod": ["604800"],
    "changedSyncPeriod": ["86400"],
    "editMode": ["READ_ONLY"],
    "pagination": ["true"]
  }
}
EOLDAP
)
COMP_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/components" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$LDAP_COMP_PAYLOAD")
[[ "$COMP_HTTP" =~ ^(201|409)$ ]] \
  && pass "Keycloak LDAP federation component created (HTTP $COMP_HTTP)" \
  || fail "Keycloak LDAP federation component failed (HTTP $COMP_HTTP)"

# Retrieve component ID and trigger initial sync
KC_COMP_ID=$(curl -sf \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer $KC_TOKEN" \
  | python3 -c "import sys,json; comps=json.load(sys.stdin); print(comps[0]['id'] if comps else '')" 2>/dev/null || echo "")
if [[ -n "$KC_COMP_ID" ]]; then
  SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:${KC_PORT}/admin/realms/it-stack/user-storage/${KC_COMP_ID}/sync?action=triggerFullSync" \
    -H "Authorization: Bearer $KC_TOKEN")
  [[ "$SYNC_HTTP" == "200" ]] \
    && pass "Keycloak triggered LDAP full sync (HTTP $SYNC_HTTP)" \
    || fail "Keycloak LDAP full sync failed (HTTP $SYNC_HTTP)"

  # Verify users synced into Keycloak realm
  KC_USERS=$(curl -sf "http://localhost:${KC_PORT}/admin/realms/it-stack/users" \
    -H "Authorization: Bearer $KC_TOKEN" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  [[ "${KC_USERS}" -ge 3 ]] \
    && pass "Keycloak LDAP sync: ${KC_USERS} users in realm (≥3)" \
    || fail "Keycloak LDAP sync: only ${KC_USERS} users after sync (expected ≥3)"
else
  fail "Could not retrieve Keycloak LDAP component ID for sync"
fi

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

section "8. Mattermost API Config Verification (Authenticated)"
# Obtain Mattermost admin token via REST API
MM_TOKEN=$(curl -si "http://localhost:${MM_PORT}/api/v4/users/login" \
  -H "Content-Type: application/json" \
  -d '{"login_id":"admin","password":"Admin05Password!"}' 2>/dev/null \
  | grep -i "^token:" | awk '{print $2}' | tr -d '\r' || echo "")

if [[ -n "$MM_TOKEN" ]]; then
  pass "Mattermost admin token obtained"

  MM_CONFIG_AUTH=$(curl -sf "http://localhost:${MM_PORT}/api/v4/config" \
    -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null || echo "{}")

  echo "$MM_CONFIG_AUTH" | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
oid = cfg.get('OpenIdSettings', {})
assert oid.get('Enable') == True, 'OpenIdSettings.Enable not true'
print('[assertion] OpenIdSettings.Enable = true')
" 2>/dev/null \
    && pass "Mattermost API: OpenIdSettings.Enable=true" \
    || fail "Mattermost API: OpenIdSettings.Enable check failed"

  echo "$MM_CONFIG_AUTH" | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
oid = cfg.get('OpenIdSettings', {})
ep = oid.get('DiscoveryEndpoint', '')
assert ep != '', 'DiscoveryEndpoint is empty'
assert 'it-stack' in ep, f'DiscoveryEndpoint does not reference it-stack realm: {ep}'
print(f'[assertion] DiscoveryEndpoint = {ep}')
" 2>/dev/null \
    && pass "Mattermost API: DiscoveryEndpoint references it-stack realm" \
    || fail "Mattermost API: DiscoveryEndpoint check failed"

  echo "$MM_CONFIG_AUTH" | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
ldap = cfg.get('LdapSettings', {})
assert ldap.get('Enable') == True, 'LdapSettings.Enable not true'
print('[assertion] LdapSettings.Enable = true')
" 2>/dev/null \
    && pass "Mattermost API: LdapSettings.Enable=true" \
    || fail "Mattermost API: LdapSettings.Enable check failed"
else
  fail "Mattermost admin login failed -- cannot verify API config with auth"
fi

section "9. Keycloak OIDC Discovery"
DISCOVERY=$(curl -sf \
  "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null || echo "{}")
echo "$DISCOVERY" | grep -q "authorization_endpoint" \
  && pass "Keycloak OIDC discovery: authorization_endpoint present" \
  || fail "Keycloak OIDC discovery endpoint unavailable"
echo "$DISCOVERY" | grep -q "token_endpoint" \
  && pass "Keycloak OIDC discovery: token_endpoint present" \
  || fail "Keycloak OIDC discovery: token_endpoint missing"
echo "$DISCOVERY" | grep -q "jwks_uri" \
  && pass "Keycloak OIDC discovery: jwks_uri present" \
  || fail "Keycloak OIDC discovery: jwks_uri missing"

section "10. Mattermost LDAP Sync"
if [[ -n "$MM_TOKEN" ]]; then
  SYNC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:${MM_PORT}/api/v4/ldap/sync" \
    -H "Authorization: Bearer $MM_TOKEN")
  [[ "$SYNC_HTTP" == "200" ]] \
    && pass "Mattermost LDAP sync triggered (HTTP $SYNC_HTTP)" \
    || fail "Mattermost LDAP sync failed (HTTP $SYNC_HTTP)"

  sleep 10

  # Poll for LDAP-synced users
  for i in $(seq 1 6); do
    LDAP_USERS=$(curl -sf \
      "http://localhost:${MM_PORT}/api/v4/users?auth_service=ldap&per_page=50" \
      -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [[ "${LDAP_USERS}" -ge 3 ]]; then
      pass "Mattermost LDAP users synced: ${LDAP_USERS} users (>= 3)"
      break
    fi
    [[ $i -eq 6 ]] && fail "Mattermost LDAP sync: only ${LDAP_USERS} LDAP users after 60s (expected >= 3)"
    sleep 10
  done
else
  fail "Skipping LDAP sync -- no admin token available"
fi

section "11. OIDC Token Flow (Keycloak -> Mattermost)"
# Get resource owner token for mmadmin from Keycloak
MMADMIN_TOKEN=$(curl -sf \
  "http://localhost:${KC_PORT}/realms/it-stack/protocol/openid-connect/token" \
  -d "client_id=mattermost-client&client_secret=mattermost-secret-05&grant_type=password&username=mmadmin&password=Lab05Password!" \
  2>/dev/null | python3 -c "
import sys, json
t = json.load(sys.stdin)
print(t.get('access_token', ''))
" 2>/dev/null || echo "")
if [[ -n "$MMADMIN_TOKEN" ]]; then
  pass "Keycloak issued OIDC access token for mmadmin"

  # Decode and verify token contains expected claims
  echo "$MMADMIN_TOKEN" | python3 -c "
import sys, base64, json
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
assert claims.get('preferred_username') == 'mmadmin', \
  'preferred_username mismatch: ' + str(claims.get('preferred_username'))
print('[assertion] preferred_username = ' + claims['preferred_username'])
" 2>/dev/null \
    && pass "OIDC token: preferred_username=mmadmin claim verified" \
    || fail "OIDC token: claim verification failed"

  # Introspect token at Keycloak
  INTRO_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:${KC_PORT}/realms/it-stack/protocol/openid-connect/token/introspect" \
    -d "client_id=mattermost-client&client_secret=mattermost-secret-05&token=$MMADMIN_TOKEN")
  [[ "$INTRO_HTTP" == "200" ]] \
    && pass "Keycloak token introspect returns 200" \
    || fail "Keycloak token introspect failed (HTTP $INTRO_HTTP)"
else
  fail "Keycloak did not issue OIDC token for mmadmin -- check LDAP federation sync"
fi

section "Summary"
echo "Passed: $PASS | Failed: $FAIL"
[[ $FAIL -eq 0 ]] && echo "Lab 07-05 INT-03 PASSED" || { echo "Lab 07-05 INT-03 FAILED"; exit 1; }
