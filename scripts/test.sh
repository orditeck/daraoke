#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Command Line Tools includes Swift Testing, but does not add its framework path.
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
if [[ "$DEVELOPER_DIR" == */CommandLineTools && -d "$FRAMEWORKS/Testing.framework" ]]; then
    swift test --enable-swift-testing --disable-xctest \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
    swift test "$@"
fi
