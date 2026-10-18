#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/tools/remnawave-node-tls-setup.sh

bash -n "$script"
bash "$script" --self-test
python3 "$root/tests/remnawave-transport-templates.py"

if command -v shellcheck >/dev/null 2>&1; then
shellcheck "$script" "$root/tests/run-remnawave-transport-tests.sh"
else
    printf '%s\n' 'ShellCheck: NOT TESTED (binary unavailable)' >&2
    exit 2
fi

printf '%s\n' 'transport manager tests: PASS; run git diff --check in the repository checkout'
