#!/bin/sh

cd "$(dirname "$0")"/.. || exit

plutil -convert xml1 CCTouchViz/Resources/Info.plist
plutil -convert xml1 TVZPrefs/Resources/Info.plist
