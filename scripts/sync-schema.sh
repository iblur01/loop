#!/usr/bin/env bash
# Sync the canonical decode schema (protocol/whoop_protocol.json) into the
# WhoopProtocol package resource. Run from anywhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANON="$ROOT/protocol/whoop_protocol.json"
PKG="$ROOT/Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json"

cp "$CANON" "$PKG"
echo "synced → $PKG"
