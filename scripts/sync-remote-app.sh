#!/bin/bash
# Copies the remote's shared code into the iPad app, which builds on its own (Xcode does not
# reliably load the main package as a dependency of a .swiftpm app). Run after changing
# Sources/MeasureRemote or Sources/MeasureRemoteUI; CI fails if the copies are out of date.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="RemoteApp/Measure Remote.swiftpm/Shared"
for target in MeasureRemote MeasureRemoteUI; do
    rm -rf "$APP/$target"
    mkdir -p "$APP/$target"
    cp Sources/$target/*.swift "$APP/$target/"
done
echo "Copied the remote's shared code into $APP."
