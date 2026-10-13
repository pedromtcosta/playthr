#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x .build/Playthr.app/Contents/MacOS/Playthr ]]; then
    bash scripts/build.sh
fi
open .build/Playthr.app
