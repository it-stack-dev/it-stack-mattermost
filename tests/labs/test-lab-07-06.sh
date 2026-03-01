#!/usr/bin/env bash
# test-lab-07-06.sh — Mattermost Lab 06: Production Deployment
# Module 07 | Lab 06 | Tests: resource limits, restart=always, volumes, metrics
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.production.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

MM_PORT=8205
KC_PORT=8206
LDAP_PORT=3896
KC_ADMIN_PASS="Prod06Admin!"
LDAP_ADMIN_PASS="LdapProd06!"
MINIO_USER="minio-prod-06"
MINIO_PASS="MinioProd06Secret!"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 06 Production Deployment"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."

section "Health Checks"
for i in $(seq 1 60); do
  status=$(docker inspect mm-prod-keycloak --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect mm-prod-keycloak --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Keycloak healthy" || fail "Keycloak not healthy"

for i in $(seq 1 30); do
  status=$(docker inspect mm-prod-ldap --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 3
done
[[ "$(docker inspect mm-prod-ldap --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "LDAP healthy" || fail "LDAP not healthy"

for i in $(seq 1 30); do
  status=$(docker inspect mm-prod-minio --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 3
done
[[ "$(docker inspect mm-prod-minio --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "MinIO healthy" || fail "MinIO not healthy"

for i in $(seq 1 60); do
  status=$(docker inspect mm-prod-app --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect mm-prod-app --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Mattermost app healthy" || fail "Mattermost app not healthy"

section "Production Configuration Checks"
# Restart policy
rp=$(docker inspect mm-prod-app --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$rp" == "always" ]] && pass "Mattermost restart=always" || fail "Restart policy is '$rp'"

# Resource limits
mem=$(docker inspect mm-prod-app --format '{{.HostConfig.Memory}}')
[[ "$mem" -gt 0 ]] && pass "Mattermost memory limit set ($mem bytes)" || fail "Mattermost memory limit not set"
mem_kc=$(docker inspect mm-prod-keycloak --format '{{.HostConfig.Memory}}')
[[ "$mem_kc" -gt 0 ]] && pass "Keycloak memory limit set" || fail "Keycloak memory limit not set"
mem_minio=$(docker inspect mm-prod-minio --format '{{.HostConfig.Memory}}')
[[ "$mem_minio" -gt 0 ]] && pass "MinIO memory limit set" || fail "MinIO memory limit not set"

# Named volumes
docker volume ls | grep -q "mm-prod-ldap-data" && pass "Volume mm-prod-ldap-data exists" || fail "Volume mm-prod-ldap-data missing"
docker volume ls | grep -q "mm-prod-ldap-config" && pass "Volume mm-prod-ldap-config exists" || fail "Volume mm-prod-ldap-config missing"
docker volume ls | grep -q "mm-prod-minio-data" && pass "Volume mm-prod-minio-data exists" || fail "Volume mm-prod-minio-data missing"
docker volume ls | grep -q "mm-prod-config" && pass "Volume mm-prod-config exists" || fail "Volume mm-prod-config missing"

section "LDAP Verification"
ldap_bind=$(docker exec mm-prod-ldap ldapsearch -x -H ldap://localhost -b "dc=lab,dc=local" -D "cn=admin,dc=lab,dc=local" -w "$LDAP_ADMIN_PASS" "(objectClass=organizationalUnit)" dn 2>&1)
echo "$ldap_bind" | grep -q "dn:" && pass "LDAP bind and search OK" || fail "LDAP bind failed"

section "Keycloak API & Metrics"
TOKEN=$(curl -sf -X POST "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_ADMIN_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$TOKEN" ]] && pass "Keycloak admin token obtained" || fail "Keycloak admin token failed"

REALM_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms" | grep -o '"realm":"it-stack"' | wc -l || echo 0)
if [[ "$REALM_EXISTS" -gt 0 ]]; then
  pass "Realm it-stack exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Production"}'
  pass "Realm it-stack created"
fi

CLIENT_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=mattermost-client" | grep -o '"clientId":"mattermost-client"' | wc -l || echo 0)
if [[ "$CLIENT_EXISTS" -gt 0 ]]; then
  pass "OIDC client mattermost-client exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"clientId":"mattermost-client","enabled":true,"protocol":"openid-connect","secret":"mattermost-prod-06","redirectUris":["http://localhost:'"${MM_PORT}"'/*"]}'
  pass "OIDC client mattermost-client created"
fi

curl -sf "http://localhost:${KC_PORT}/metrics" | grep -q "keycloak" && pass "Keycloak /metrics endpoint returns data" || fail "Keycloak /metrics not responding"

section "Mattermost API"
curl -sf "http://localhost:${MM_PORT}/api/v4/system/ping" | grep -q '"status":"OK"' && pass "Mattermost API ping OK" || fail "Mattermost API ping failed"

section "Mattermost Metrics"
curl -sf "http://localhost:8067/metrics" | grep -q "mattermost" && pass "Mattermost Prometheus metrics endpoint OK" || fail "Mattermost metrics endpoint not responding"

section "MinIO S3 Check"
curl -sf "http://localhost:9110/minio/health/live" && pass "MinIO health endpoint OK" || fail "MinIO health check failed"

section "Log Rotation Configuration"
log_driver=$(docker inspect mm-prod-app --format '{{.HostConfig.LogConfig.Type}}')
[[ "$log_driver" == "json-file" ]] && pass "Log driver is json-file" || fail "Log driver is '$log_driver'"

echo ""
echo "================================================"
echo "Lab 06 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1