#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_URL="${FLUIDVOICE_UPSTREAM_URL:-https://github.com/altic-dev/FluidVoice.git}"
FORK_BRANCH="${FLUIDVOICE_FORK_BRANCH:-feat/custom-openai-endpoint}"

cd "$REPO_ROOT"

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean. Commit or stash changes before syncing." >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
if [ "$current_branch" != "$FORK_BRANCH" ]; then
  echo "Error: expected branch '$FORK_BRANCH', currently on '$current_branch'." >&2
  exit 1
fi

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

git fetch upstream --prune --tags

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "Already up to date with upstream/main."
  exit 0
fi

git merge --no-ff --no-edit upstream/main

echo "Upstream merged successfully. Review and test, then push with:"
echo "  git push origin $FORK_BRANCH"
