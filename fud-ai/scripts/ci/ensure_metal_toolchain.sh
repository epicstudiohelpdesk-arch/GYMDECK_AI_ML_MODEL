#!/bin/bash
# Xcode distributes Metal separately; the voice orb shader needs its compiler.
set -euo pipefail

# Finding a tool path is insufficient when Xcode only has the downloader shim.
if xcrun metal --version >/dev/null 2>&1; then
  echo 'Metal compiler is available.'
else
  echo 'Installing the Metal toolchain for the selected Xcode.'
  xcodebuild -downloadComponent MetalToolchain
  # The download returns before the toolchain is registered, and xcrun caches the
  # failed lookup from the check above, so clear the cache and wait for registration.
  for _ in $(seq 1 24); do
    xcrun --kill-cache
    if xcrun metal --version >/dev/null 2>&1; then
      break
    fi
    echo 'Waiting for the Metal toolchain to finish installing.'
    sleep 5
  done
fi

# Fail before the expensive build if installation did not provide a usable tool.
# Clear the cache first so a lookup that failed just before the last wait is not reused.
xcrun --kill-cache
xcrun metal --version
