#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 \
  "$repo_dir/SideStore/Core/Shortcuts/RefreshShortcutReport.swift" \
  "$repo_dir/SideStore/Core/Shortcuts/RefreshExecutionGate.swift" \
  "$repo_dir/SideStore/Core/Shortcuts/StagedRefreshBatch.swift" \
  "$repo_dir/scripts/tests/staged-refresh/main.swift" \
  -o "$test_dir/staged-refresh-tests"
"$test_dir/staged-refresh-tests"
