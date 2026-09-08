#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DEVICE_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidestore-device-tests.XXXXXX")
trap 'rm -rf "$DEVICE_TEST_BUILD"' EXIT

"${SWIFTC:-swiftc}" -swift-version 6 -parse-as-library \
  "$REPO_ROOT/SideStore/Core/Operations/DeviceRegistrationFlow.swift" \
  "$REPO_ROOT/scripts/tests/device-registration/main.swift" \
  -o "$DEVICE_TEST_BUILD/device-registration-tests"
"$DEVICE_TEST_BUILD/device-registration-tests"
