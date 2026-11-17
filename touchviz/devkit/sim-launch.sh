#!/bin/sh

if [ -z "$THEOS_DEVICE_SIMULATOR" ]; then
  exit 0
fi

cd "$(dirname "$0")"/.. || exit

if [ -z "$1" ]; then
  echo "Usage: $0 <device_id>"
  exit 1
fi

DEVICE_ID="$1"
XCODE_PATH=$(xcode-select -p)

xcrun simctl boot "$DEVICE_ID"
open "$XCODE_PATH"/Applications/Simulator.app
