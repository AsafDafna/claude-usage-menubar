#!/bin/bash
set -e
mkdir -p .build
swiftc Sources/main.swift \
  -o .build/ClaudeUsageMeter \
  -framework Cocoa \
  -framework Security \
  -swift-version 6
echo "Built: .build/ClaudeUsageMeter"
