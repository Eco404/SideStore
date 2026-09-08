#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AUTH_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidestore-auth-tests.XXXXXX")
trap 'rm -rf "$AUTH_TEST_BUILD"' EXIT

"${SWIFTC:-swiftc}" -swift-version 6 -parse-as-library \
  "$REPO_ROOT/Dependencies/SideSign/Sources/DeveloperPortal/AppleAuthenticationTransport.swift" \
  "$REPO_ROOT/scripts/tests/apple-auth/main.swift" \
  -o "$AUTH_TEST_BUILD/apple-auth-tests"
"$AUTH_TEST_BUILD/apple-auth-tests"
