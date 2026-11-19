#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export ROUTING_TEST_ROOT="$(mktemp -d /private/tmp/tunnel-routing-check.XXXXXX)"
cleanup() {
  result=$?
  if [ "$result" -ne 0 ]; then
    cp "$ROUTING_TEST_ROOT/tunnel.log" /private/tmp/tunnel-routing-failure.log 2>/dev/null || true
    cp "$ROUTING_TEST_ROOT/relay.log" /private/tmp/tunnel-routing-relay-failure.log 2>/dev/null || true
  fi
  rm -rf "$ROUTING_TEST_ROOT"
}
trap cleanup EXIT
swiftc -module-cache-path "$ROUTING_TEST_ROOT/module-cache" -parse-as-library \
  TunnelProxy/Controllers/ServerProfile.swift \
  TunnelProxy/Controllers/TunnelConfig.swift \
  TunnelProxy/Controllers/SSHRoutePlanner.swift \
  TunnelProxy/Controllers/TunnelEngine.swift \
  TunnelProxy/Controllers/ProcessRunner.swift \
  TunnelProxy/Controllers/PortInspector.swift \
  tests/RoutingHarness.swift -o "$ROUTING_TEST_ROOT/check"
"$ROUTING_TEST_ROOT/check" "$@"
