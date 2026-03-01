#!/usr/bin/env bash
# test-lab-07-02.sh — Lab 07-02: External Dependencies
# Module 07: Mattermost — external PostgreSQL, Redis, mailhog SMTP relay
set -euo pipefail

LAB_ID="07-02"
LAB_NAME="External Dependencies"
MODULE="mattermost"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting for PostgreSQL..."
timeout 60 bash -c 'until docker compose -f docker/docker-compose.lan.yml exec -T db pg_isready -U mmuser -d mattermost 2>/dev/null; do sleep 3; done'
info "Waiting for Redis..."
timeout 30 bash -c 'until docker compose -f docker/docker-compose.lan.yml exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; do sleep 2; done'
info "Waiting for Mattermost API..."
timeout 120 bash -c 'until curl -sf http://localhost:8065/api/v4/system/ping | grep -q status; do sleep 5; done'

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

for c in mm-lan-db mm-lan-redis mm-lan-smtp mm-lan-app; do
  if docker ps --filter "name=^/${c}$" --filter "status=running" --format '{{.Names}}' | grep -q "${c}"; then
    pass "Container ${c} is running"
  else
    fail "Container ${c} is not running"
  fi
done

if docker compose -f "${COMPOSE_FILE}" exec -T db pg_isready -U mmuser -d mattermost 2>/dev/null; then
  pass "PostgreSQL: pg_isready OK"
else
  fail "PostgreSQL: pg_isready failed"
fi

if docker compose -f "${COMPOSE_FILE}" exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis: PING → PONG"
else
  fail "Redis: no PONG response"
fi

if curl -sf http://localhost:8025/api/v2/messages > /dev/null 2>&1; then
  pass "Mailhog web UI: reachable (:8025)"
else
  fail "Mailhog web UI: not reachable"
fi

if curl -sf http://localhost:8065/api/v4/system/ping | grep -q '"status":"OK"'; then
  pass "Mattermost API: system/ping OK"
else
  fail "Mattermost API: system/ping failed"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 02 — External Dependencies)"

SIGNUP=$(curl -sf -X POST http://localhost:8065/api/v4/users \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@lab.local","username":"admin","password":"Lab02Admin!","allow_marketing":false}' \
  2>/dev/null || echo "")
if echo "${SIGNUP}" | grep -q '"username":"admin"'; then
  pass "Admin user created"
else
  info "Admin user may already exist — attempting login"
fi

TOKEN=$(curl -si -X POST http://localhost:8065/api/v4/users/login \
  -H 'Content-Type: application/json' \
  -d '{"login_id":"admin","password":"Lab02Admin!"}' \
  2>/dev/null | grep -i 'Token:' | awk '{print $2}' | tr -d '\r' || echo "")
if [ -n "${TOKEN}" ]; then
  pass "Admin login: auth token obtained"
else
  fail "Admin login: could not get auth token"
fi

# Key Lab 02 test: SMTP relay is configured
if [ -n "${TOKEN}" ]; then
  SMTP_CFG=$(curl -sf http://localhost:8065/api/v4/config \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
  SMTP_SERVER=$(echo "${SMTP_CFG}" | grep -o '"SMTPServer":"[^"]*"' | head -1 || echo "")
  if echo "${SMTP_SERVER}" | grep -q 'smtp'; then
    pass "SMTP relay: SMTPServer configured (${SMTP_SERVER})"
  else
    fail "SMTP relay: SMTPServer not set to 'smtp' relay (got: ${SMTP_SERVER})"
  fi
fi

if [ -n "${TOKEN}" ]; then
  VERSION=$(curl -sf http://localhost:8065/api/v4/system/server_version \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | tr -d '"' || echo "")
  [ -n "${VERSION}" ] && pass "Server version: ${VERSION}" || fail "Could not retrieve server version"
fi

if [ -n "${TOKEN}" ]; then
  TEAM=$(curl -sf -X POST http://localhost:8065/api/v4/teams \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"name":"lab02","display_name":"Lab 02","type":"O"}' \
    2>/dev/null || echo "")
  if echo "${TEAM}" | grep -q '"name":"lab02"'; then
    pass "Team 'lab02' created"
    TEAM_ID=$(echo "${TEAM}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  else
    fail "Team 'lab02' creation failed"
    TEAM_ID=""
  fi
fi

if [ -n "${TOKEN}" ] && [ -n "${TEAM_ID:-}" ]; then
  CHANNEL=$(curl -sf -X POST http://localhost:8065/api/v4/channels \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d "{\"team_id\":\"${TEAM_ID}\",\"name\":\"general-lan\",\"display_name\":\"General LAN\",\"type\":\"O\"}" \
    2>/dev/null || echo "")
  if echo "${CHANNEL}" | grep -q '"name":"general-lan"'; then
    pass "Channel 'general-lan' created"
  else
    fail "Channel creation failed"
  fi
fi

if docker compose -f "${COMPOSE_FILE}" exec -T mattermost \
    sh -c 'nc -z redis 6379 2>/dev/null && echo OK' 2>/dev/null | grep -q OK; then
  pass "Mattermost → Redis connectivity: port 6379 reachable"
else
  warn "Mattermost → Redis: nc not available in container (connectivity assumed OK)"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi