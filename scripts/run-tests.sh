#!/bin/zsh
# Runs the buzz-guard (repeat detector) tests on synthetic audio. Does not touch any device.
set -euo pipefail
ROOT=${0:A:h:h}
mkdir -p "$ROOT/build"
swiftc -O "$ROOT/src/bridge/detector.swift" "$ROOT/tests/detector_test/main.swift" -o "$ROOT/build/detector_test"
"$ROOT/build/detector_test"
