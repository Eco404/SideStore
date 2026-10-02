#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -swift-version 6 -parse-as-library \
  "$repo_root/SideStore/Core/Shortcuts/RefreshShortcutReport.swift" \
  "$repo_root/SideStore/Core/Shortcuts/RefreshShortcutOutcome.swift" \
  "$repo_root/scripts/tests/refresh-result/main.swift" \
  -o "$test_dir/refresh-result-tests"
"$test_dir/refresh-result-tests"
