#!/bin/bash
# Installs MoEShift (if missing) and starts the setup wizard.
set -euo pipefail
eval "$(/opt/homebrew/bin/brew shellenv)"
if ! command -v moeshift >/dev/null 2>&1; then
  brew install davide-troiani/moeshift/moeshift
fi
moeshift
