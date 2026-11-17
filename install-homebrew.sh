#!/bin/bash
# Installs Homebrew for the current user (official installer). Asks for your password.
set -euo pipefail
if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
  echo "Homebrew already installed:"; /opt/homebrew/bin/brew --version | head -1; exit 0
fi
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Add brew to PATH for future terminals (Apple Silicon prefix)
if ! grep -qs 'brew shellenv' ~/.zprofile; then
  printf '\neval "$(/opt/homebrew/bin/brew shellenv)"\n' >> ~/.zprofile
fi
echo; echo "Done. Open a NEW Terminal, or run in this one:"
echo '  eval "$(/opt/homebrew/bin/brew shellenv)"'
