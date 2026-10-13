#!/usr/bin/env bash
# Verifies trusted-header ("标头认证") authentication through the nginx test gateway.
#
#   scripts/trusted-header-smoke-test.sh [gateway_url] [direct_url]
#
# Defaults match docker-compose.trusted-header.yml:
#   gateway http://localhost:8081 (headers injected by nginx)
#   direct  http://localhost:18080 (backend straight, no headers unless the caller sends them)
#
# Overridable identity/secret (must match the compose environment):
#   TRUSTED_HEADER_TEST_USER, TRUSTED_HEADER_TEST_EMAIL, TRUSTED_HEADER_TEST_SECRET
set -euo pipefail

GATEWAY_URL="${1:-http://localhost:8081}"
DIRECT_URL="${2:-http://localhost:18080}"
TEST_USER="${TRUSTED_HEADER_TEST_USER:-gateway-user-1}"
TEST_EMAIL="${TRUSTED_HEADER_TEST_EMAIL:-gateway-user-1@example.com}"
TEST_SECRET="${TRUSTED_HEADER_TEST_SECRET-trusted-header-test-secret}"
OVERRIDE_USER="trusted-header-override-$$"
OVERRIDE_EMAIL="${OVERRIDE_USER}@example.com"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

json_string() {
  local body="$1" key="$2"
  printf '%s' "$body" | grep -o "\"${key}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# request <url> [curl args...] -> sets HTTP_STATUS and HTTP_BODY
request() {
  local url="$1"
  shift
  local response
  response="$(curl -s -m 15 -w $'\n%{http_code}' "$@" "$url" || true)"
  HTTP_STATUS="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"
}

expect_status() {
  local desc="$1" expected="$2" url="$3"
  shift 3
  request "$url" "$@"
  if [[ "$HTTP_STATUS" == "$expected" ]]; then
    pass "$desc (HTTP $HTTP_STATUS)"
  else
    fail "$desc (expected HTTP $expected, got ${HTTP_STATUS:-none})"
  fi
}

# Asserts that the caller is authenticated as the injected external identity.
# SkillHub assigns its own platform id (`usr_<uuid>`), so the external identity is asserted through
# displayName (the gateway login), email and oauthProvider.
expect_identity() {
  local desc="$1" expected_login="$2" expected_email="$3" expected_provider="$4" url="$5"
  shift 5
  request "$url" "$@"
  if [[ "$HTTP_STATUS" != "200" ]]; then
    fail "$desc (expected HTTP 200, got ${HTTP_STATUS:-none})"
    return
  fi
  local user_id login email provider
  user_id="$(json_string "$HTTP_BODY" userId)"
  login="$(json_string "$HTTP_BODY" displayName)"
  email="$(json_string "$HTTP_BODY" email)"
  provider="$(json_string "$HTTP_BODY" oauthProvider)"
  if [[ -z "$user_id" ]]; then
    fail "$desc (no userId in response)"
    return
  fi
  if [[ "$login" != "$expected_login" ]]; then
    fail "$desc (expected displayName=$expected_login, got '${login:-none}')"
    return
  fi
  if [[ -n "$expected_email" && "$email" != "$expected_email" ]]; then
    fail "$desc (expected email=$expected_email, got '${email:-none}')"
    return
  fi
  if [[ "$provider" != "$expected_provider" ]]; then
    fail "$desc (expected oauthProvider=$expected_provider, got '${provider:-none}')"
    return
  fi
  pass "$desc (userId=$user_id, displayName=$login, oauthProvider=$provider)"
}

echo "Trusted-header smoke test"
echo "  gateway: $GATEWAY_URL"
echo "  direct:  $DIRECT_URL"
echo "  secret:  $([[ -n "$TEST_SECRET" ]] && echo "configured" || echo "disabled")"
echo

# 1. Through the gateway: the injected headers sign the caller in with no session, no cookie and no
#    login page.
expect_identity "gateway injects the default identity" "$TEST_USER" "$TEST_EMAIL" "forward-auth" \
  "$GATEWAY_URL/api/v1/auth/me"

# 2. The test-only X-Test-User override switches identity, and first sight provisions a new account.
expect_identity "gateway honours X-Test-User override (JIT account)" "$OVERRIDE_USER" "$OVERRIDE_EMAIL" \
  "forward-auth" "$GATEWAY_URL/api/v1/auth/me" \
  -H "X-Test-User: $OVERRIDE_USER" -H "X-Test-Email: $OVERRIDE_EMAIL"

# 3. The browser entry point is served by the same gateway.
request "$GATEWAY_URL/"
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "gateway serves the SPA (HTTP 200)"
else
  fail "gateway serves the SPA (expected HTTP 200, got ${HTTP_STATUS:-none})"
fi

# 4. Bypassing the gateway must not authenticate: the backend is only reachable with the headers.
expect_status "direct request without headers is rejected" "401" "$DIRECT_URL/api/v1/auth/me"

if [[ -n "$TEST_SECRET" ]]; then
  # 5. With the gateway shared secret the backend accepts the assertions directly. Note that this is
  #    the *only* thing standing between a caller and impersonation on the direct path: the
  #    deployment must still keep the backend unreachable except through the gateway.
  expect_identity "direct request with the shared secret is accepted" "$TEST_USER" "$TEST_EMAIL" \
    "forward-auth" "$DIRECT_URL/api/v1/auth/me" \
    -H "X-Auth-Request-User: $TEST_USER" \
    -H "X-Forwarded-Email: $TEST_EMAIL" \
    -H "X-Skillhub-Proxy-Secret: $TEST_SECRET"

  # 6. Missing / 7. wrong secret are both rejected.
  expect_status "direct request with headers but no secret is rejected" "401" "$DIRECT_URL/api/v1/auth/me" \
    -H "X-Auth-Request-User: $TEST_USER" \
    -H "X-Forwarded-Email: $TEST_EMAIL"
  expect_status "direct request with a wrong secret is rejected" "401" "$DIRECT_URL/api/v1/auth/me" \
    -H "X-Auth-Request-User: $TEST_USER" \
    -H "X-Forwarded-Email: $TEST_EMAIL" \
    -H "X-Skillhub-Proxy-Secret: wrong-secret"
else
  skip "shared-secret assertions (TRUSTED_HEADER_TEST_SECRET is empty)"
fi

# 8. Gateway health.
expect_status "gateway health endpoint" "200" "$GATEWAY_URL/nginx-health"

echo
echo "Trusted-header smoke test: $PASS passed, $FAIL failed, $SKIP skipped."
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
