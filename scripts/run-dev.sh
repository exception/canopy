#!/bin/zsh
# Starts an isolated debug Canopy (own data dir, automation port).
cd "${0:A:h}/.."
unset PITWALL_SOCKET PITWALL_TILE_ID PITWALL_BOARD_ID PITWALL_SESSION_ID PITWALL_CLI
pkill -f "build/dd/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy" 2>/dev/null
sleep 0.5
export CANOPY_HOME=$PWD/build/home CANOPY_CONTROL_PORT=${CANOPY_CONTROL_PORT:-47199}
build/dd/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy -AppleLanguages "(en)" > build/app.log 2>&1 &
echo $! > build/pid
sleep 2.5
