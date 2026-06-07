#!/bin/bash
# bootstrap.sh — Programmatically create a test user in Keycloak and generate
# an offline token for use by the smoke-test suite.
#
# This script eliminates the need for a human to manually authenticate via
# browser-based GitHub OAuth, enabling fully automated integration testing.
#
# Prerequisites:
#   - Keycloak is running and healthy
#   - Minder server is running (or will be shortly)
#   - curl, jq, and minder CLI are available on PATH
#
# Usage:
#   ./scripts/bootstrap.sh
#
# Environment variables (all have sensible defaults for run-docker):
#   KEYCLOAK_URL              — Keycloak base URL       (default: http://localhost:8081)
#   KC_REALM                  — Keycloak realm           (default: stacklok)
#   KC_ADMIN_USER             — Keycloak admin username  (default: admin)
#   KC_ADMIN_PASS             — Keycloak admin password  (default: admin)
#   TEST_USER                 — Test user to create      (default: smoke-test-user)
#   TEST_PASS                 — Test user password       (default: smoke-test-password)
#   CLIENT_ID                 — OIDC client ID           (default: smoke-test-client)
#   MINDER_API_URL            — Minder HTTP API URL      (default: http://localhost:8080)
#   OFFLINE_TOKEN_OUTPUT_PATH — Where to write token     (default: ./offline.token)
#   MINDER_BINARY             — Path to minder binary    (default: minder)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8081}"
KC_REALM="${KC_REALM:-stacklok}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
TEST_USER="${TEST_USER:-smoke-test-user}"
TEST_PASS="${TEST_PASS:-smoke-test-password}"
CLIENT_ID="${CLIENT_ID:-smoke-test-client}"
MINDER_API_URL="${MINDER_API_URL:-http://localhost:8080}"
OFFLINE_TOKEN_OUTPUT_PATH="${OFFLINE_TOKEN_OUTPUT_PATH:-./offline.token}"
MINDER_BINARY="${MINDER_BINARY:-minder}"

MAX_RETRIES=30
RETRY_INTERVAL=5

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()   { echo "==> $*"; }
warn()  { echo "==> [WARN] $*" >&2; }
fatal() { echo "==> [FATAL] $*" >&2; exit 1; }

wait_for_url() {
    local url="$1"
    local label="$2"
    local retries=0

    log "Waiting for ${label} at ${url}..."
    until curl -sf "${url}" > /dev/null 2>&1; do
        retries=$((retries + 1))
        if [ "${retries}" -ge "${MAX_RETRIES}" ]; then
            fatal "${label} did not become ready after ${MAX_RETRIES} attempts"
        fi
        sleep "${RETRY_INTERVAL}"
    done
    log "${label} is ready."
}

# ---------------------------------------------------------------------------
# Step 1: Wait for Keycloak
# ---------------------------------------------------------------------------

wait_for_url "${KEYCLOAK_URL}/health/ready" "Keycloak"

# ---------------------------------------------------------------------------
# Step 2: Obtain Keycloak admin access token
# ---------------------------------------------------------------------------

log "Obtaining Keycloak admin access token..."
ADMIN_TOKEN_RESPONSE=$(curl -sf -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" \
    -d "client_id=admin-cli") \
    || fatal "Failed to obtain admin token from Keycloak"

ADMIN_TOKEN=$(echo "${ADMIN_TOKEN_RESPONSE}" | jq -r '.access_token')
if [ -z "${ADMIN_TOKEN}" ] || [ "${ADMIN_TOKEN}" = "null" ]; then
    fatal "Admin access token is empty or null"
fi
log "Admin token obtained successfully."

# ---------------------------------------------------------------------------
# Step 3: Create test user in Keycloak
# ---------------------------------------------------------------------------

log "Creating test user '${TEST_USER}' in realm '${KC_REALM}'..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"username\": \"${TEST_USER}\",
        \"enabled\": true,
        \"emailVerified\": true,
        \"email\": \"${TEST_USER}@test.local\",
        \"firstName\": \"Smoke\",
        \"lastName\": \"Test\",
        \"credentials\": [{
            \"type\": \"password\",
            \"value\": \"${TEST_PASS}\",
            \"temporary\": false
        }]
    }")

case "${HTTP_STATUS}" in
    201) log "User '${TEST_USER}' created successfully." ;;
    409) log "User '${TEST_USER}' already exists — skipping creation." ;;
    *)   fatal "Unexpected status ${HTTP_STATUS} creating user. Check Keycloak logs." ;;
esac

# ---------------------------------------------------------------------------
# Step 4: Request offline token via Resource Owner Password Credentials
# ---------------------------------------------------------------------------

log "Requesting offline token for '${TEST_USER}' via ROPC grant..."
TOKEN_RESPONSE=$(curl -sf -X POST \
    "${KEYCLOAK_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=${CLIENT_ID}" \
    -d "username=${TEST_USER}" \
    -d "password=${TEST_PASS}" \
    -d "scope=openid offline_access") \
    || fatal "Failed to obtain offline token. Is the '${CLIENT_ID}' Keycloak client configured with Direct Access Grants (ROPC) enabled and the 'offline_access' scope? Create a 'smoke-test-client' in the Keycloak realm config with directAccessGrantsEnabled=true."

OFFLINE_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.refresh_token')
if [ -z "${OFFLINE_TOKEN}" ] || [ "${OFFLINE_TOKEN}" = "null" ]; then
    echo "Token response:" >&2
    echo "${TOKEN_RESPONSE}" | jq '.' >&2
    fatal "Offline token (refresh_token) is empty or null. The '${CLIENT_ID}' client may not have offline_access scope or ROPC enabled."
fi

echo "${OFFLINE_TOKEN}" > "${OFFLINE_TOKEN_OUTPUT_PATH}"
log "Offline token saved to ${OFFLINE_TOKEN_OUTPUT_PATH}"

# ---------------------------------------------------------------------------
# Step 5: Wait for Minder server
# ---------------------------------------------------------------------------

wait_for_url "${MINDER_API_URL}/api/v1/health" "Minder server"

# ---------------------------------------------------------------------------
# Step 6: Bootstrap user in Minder (first auth triggers auto-enrollment)
# ---------------------------------------------------------------------------

log "Authenticating test user with Minder (triggers auto-enrollment)..."
${MINDER_BINARY} auth offline-token use --file "${OFFLINE_TOKEN_OUTPUT_PATH}" \
    || fatal "Failed to authenticate with Minder using offline token"

# ---------------------------------------------------------------------------
# Step 7: Extract root project ID
# ---------------------------------------------------------------------------

log "Retrieving root project ID..."
PROJECT_LIST=$(${MINDER_BINARY} project list -o json 2>/dev/null) \
    || fatal "Failed to list Minder projects"

PROJECT_ID=$(echo "${PROJECT_LIST}" | jq -r '.projects[0].projectId // empty')
if [ -z "${PROJECT_ID}" ]; then
    fatal "No projects found. Auto-enrollment may have failed."
fi

log "Root project ID: ${PROJECT_ID}"

# Export for downstream use (e.g., GitHub Actions, Taskfile)
export MINDER_PROJECT="${PROJECT_ID}"

# If running in GitHub Actions, persist to $GITHUB_ENV
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "MINDER_PROJECT=${PROJECT_ID}" >> "${GITHUB_ENV}"
    log "MINDER_PROJECT exported to GITHUB_ENV"
fi

# Also write to a file for non-GHA consumers
echo "${PROJECT_ID}" > ./minder-project-id
log "Project ID written to ./minder-project-id"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "============================================"
log " Bootstrap complete!"
log " User:    ${TEST_USER}"
log " Token:   ${OFFLINE_TOKEN_OUTPUT_PATH}"
log " Project: ${PROJECT_ID}"
log "============================================"
