#!/bin/sh
# Compile TagDrop once (and again after updates), then run it.
# Compiling instead of `swift tagdrop.swift` avoids the interpreter's
# "Symbols not found: ___isPlatformVersionAtLeast" error with SwiftUI.
cd "$(dirname "$0")" || exit 1
if [ ! -x TagDrop ] || [ tagdrop.swift -nt TagDrop ]; then
  echo "Building TagDrop… (only on the first run or after an update, ~30 seconds)"
  swiftc -O tagdrop.swift -o TagDrop || { echo "Build failed. Copy the error above and send it over."; exit 1; }
fi
exec ./TagDrop "$@"
