#!/usr/bin/env bash
# test-lab-07-03.sh — Lab 07-03: Mattermost Advanced Features
# Tests: resource limits, MaxFileSize, S3 storage, perf settings, MinIO
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }
MM_API="http://localhost:8065/api/v4"

section "Container health"
for c in mm-adv-db mm-adv-redis mm-adv-minio mm-adv-smtp mm-adv-app; do
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

section "MinIO S3 health"
MINIO_STATUS=$(curl -sf http://localhost:9000/minio/health/live 2>/dev/null; echo $?) || MINIO_STATUS=1
if [ "$MINIO_STATUS" = "0" ]; then
  pass "MinIO S3 health endpoint reachable"
else
  HTTP_MINIO=$(curl -sw '%{http_code}' -o /dev/null http://localhost:9000/minio/health/live 2>/dev/null) || HTTP_MINIO="000"
  if [ "$HTTP_MINIO" = "200" ]; then
    pass "MinIO S3 health endpoint HTTP 200"
  else
    fail "MinIO S3 health endpoint returned $HTTP_MINIO"
  fi
fi

section "Mattermost API ping"
PING=$(curl -sf "$MM_API/system/ping" 2>/dev/null) || PING=""
if echo "$PING" | grep -q "status"; then
  pass "Mattermost API /system/ping reachable"
else
  fail "Mattermost API /system/ping failed"
fi

section "Admin user creation"
REGISTER=$(curl -sf -X POST "$MM_API/users" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@lab.local","username":"admin03","password":"Lab03Admin!","first_name":"Admin","last_name":"Lab03"}' 2>/dev/null) || REGISTER=""
if echo "$REGISTER" | grep -q '"id"'; then
  pass "Admin user created"
elif echo "$REGISTER" | grep -q "already"; then
  pass "Admin user already exists"
else
  fail "Admin user registration failed: $REGISTER"
fi

section "Admin login"
TOKEN_RESP=$(curl -si -X POST "$MM_API/users/login" \
  -H "Content-Type: application/json" \
  -d '{"login_id":"admin03","password":"Lab03Admin!"}' 2>/dev/null) || TOKEN_RESP=""
MM_TOKEN=$(echo "$TOKEN_RESP" | grep -i "^Token:" | awk '{print $2}' | tr -d '[:space:]') || MM_TOKEN=""
if [ -n "$MM_TOKEN" ]; then
  pass "Admin login successful, token obtained"
else
  fail "Admin login failed"
fi

section "MaxFileSize in container env"
MM_ENV=$(docker inspect mm-adv-app --format '{{json .Config.Env}}' 2>/dev/null) || MM_ENV="[]"
if echo "$MM_ENV" | grep -q "MM_FILESETTINGS_MAXFILESIZE=524288000"; then
  pass "MM_FILESETTINGS_MAXFILESIZE=524288000 set in container"
else
  fail "MM_FILESETTINGS_MAXFILESIZE=524288000 not found in container env"
fi

section "Performance settings in container env"
if echo "$MM_ENV" | grep -q "MM_SERVICESETTINGS_READTIMEOUT=300"; then
  pass "MM_SERVICESETTINGS_READTIMEOUT=300 set"
else
  fail "MM_SERVICESETTINGS_READTIMEOUT=300 not found"
fi
if echo "$MM_ENV" | grep -q "MM_SERVICESETTINGS_MAXLOGINRETRIES=3"; then
  pass "MM_SERVICESETTINGS_MAXLOGINRETRIES=3 set"
else
  fail "MM_SERVICESETTINGS_MAXLOGINRETRIES=3 not found"
fi

section "Resource limits check"
MM_MEM=$(docker inspect mm-adv-app --format '{{.HostConfig.Memory}}' 2>/dev/null) || MM_MEM="0"
if [ "$MM_MEM" = "1073741824" ]; then
  pass "mm-adv-app memory limit = 1G (1073741824 bytes)"
else
  fail "mm-adv-app memory limit: expected 1073741824, got $MM_MEM"
fi

section "MaxFileSize via API config"
if [ -n "$MM_TOKEN" ]; then
  CONFIG=$(curl -sf -H "Authorization: Bearer $MM_TOKEN" "$MM_API/config" 2>/dev/null) || CONFIG=""
  if echo "$CONFIG" | grep -q '"MaxFileSize":524288000'; then
    pass "API config MaxFileSize = 524288000"
  else
    fail "API config MaxFileSize not 524288000"
  fi
else
  fail "Skipping API config check (no token)"
fi

section "S3 file settings via API"
if [ -n "$MM_TOKEN" ] && [ -n "$CONFIG" ]; then
  if echo "$CONFIG" | grep -q '"DriverName":"amazons3"'; then
    pass "FileSettings DriverName = amazons3"
  else
    fail "FileSettings DriverName not amazons3"
  fi
else
  fail "Skipping S3 API check (no token or config)"
fi

section "Redis connectivity"
REDIS_PONG=$(docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli PING 2>/dev/null | tr -d '[:space:]') || REDIS_PONG=""
if [ "$REDIS_PONG" = "PONG" ]; then
  pass "Redis PING responded"
else
  fail "Redis PING failed"
fi

echo
echo "====================================="
echo "  Mattermost Lab 07-03 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1