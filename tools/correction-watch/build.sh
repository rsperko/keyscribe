#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc -swift-version 5 -O correction-watch.swift -o .build/correction-watch
echo "built $(pwd)/.build/correction-watch"
