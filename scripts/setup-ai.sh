#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/bin/python3; do
  if [ -x "$candidate" ]; then
    exec "$candidate" Resources/AI/engine.py setup
  fi
done
printf 'Install Python 3.10–3.12 from python.org or Homebrew, then retry.\n' >&2
exit 1
