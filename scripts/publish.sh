#!/bin/bash
set -euo pipefail

# Run on a computer with GitHub CLI authenticated as nmt3325.
REPO="nmt3325/flyover-pitch-lab"
if ! command -v gh >/dev/null 2>&1; then
    echo 'Install GitHub CLI: https://cli.github.com/' >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo 'First run: gh auth login' >&2
    exit 1
fi
if [ ! -d .git ]; then
    git init -b main
fi
git add .
if ! git diff --cached --quiet; then
    git commit -m 'Initial Flyover camera pitch experiment'
fi
if git remote get-url origin >/dev/null 2>&1; then
    echo 'Remote origin already exists. Pushing the main branch.'
    git push -u origin main
else
    gh repo create "$REPO" --public --source=. --remote=origin --push
fi
printf '\nGitHub Actions: https://github.com/%s/actions\n' "$REPO"
