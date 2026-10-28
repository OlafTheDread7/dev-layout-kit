#!/usr/bin/env bash
# AI Review — works out what this run reviews and writes the prompt Claude reads.
# It also tells the plain checks (checks.py) which commits to scan, and it does that
# even when it decides the AI review can be skipped, because those checks always run.
#
# Normal pushes review everything since the last commit that PASSED this review on
# this branch. So if a push is blocked and the next push doesn't fix it, the blocked
# change is still in the diff and still blocks. With no earlier pass on record it
# falls back to this push's own changes.
set -euo pipefail

RUN_DIR="${GITHUB_WORKSPACE}/.ai-review-run"
mkdir -p "$RUN_DIR"

HEAD_SHA="${GITHUB_SHA}"
BRANCH="${GITHUB_REF_NAME}"
SCOPE="${REVIEW_SCOPE:-last-push}"
ZERO="0000000000000000000000000000000000000000"
MODE="diff"
BASE=""
WHY=""

out() { echo "$1" >> "$GITHUB_OUTPUT"; }

if [ "$SCOPE" = "whole-repo" ]; then
  MODE="whole"
  WHY="the whole repository (manual run)"
else
  LAST_OK=""
  if command -v gh >/dev/null 2>&1; then
    while read -r sha; do
      [ -z "$sha" ] && continue
      [ "$sha" = "$HEAD_SHA" ] && continue
      if git merge-base --is-ancestor "$sha" "$HEAD_SHA" 2>/dev/null; then
        LAST_OK="$sha"
        break
      fi
    done < <(gh run list --repo "$GITHUB_REPOSITORY" --workflow ai-review.yml \
               --branch "$BRANCH" --status success --limit 30 \
               --json headSha --jq '.[].headSha' 2>/dev/null || true)
  fi

  if [ -n "$LAST_OK" ]; then
    BASE="$LAST_OK"
    WHY="everything since the last approved commit (${LAST_OK:0:7})"
  elif [ -n "${PUSH_BEFORE:-}" ] && [ "$PUSH_BEFORE" != "$ZERO" ] \
       && git cat-file -e "${PUSH_BEFORE}^{commit}" 2>/dev/null; then
    BASE="$PUSH_BEFORE"
    WHY="the changes in this push (no earlier approved commit on record)"
  elif git rev-parse -q --verify "${HEAD_SHA}~1" >/dev/null; then
    BASE="$(git rev-parse "${HEAD_SHA}~1")"
    WHY="the latest commit"
  else
    MODE="whole"
    WHY="the whole repository (first commit)"
  fi
fi

out "base=${BASE}"
out "mode=${MODE}"

if [ "$MODE" = "diff" ]; then
  git diff --name-only "$BASE" "$HEAD_SHA" > "$RUN_DIR/files.txt"
  if [ ! -s "$RUN_DIR/files.txt" ]; then
    echo "Nothing changed since ${BASE:0:7} — passing without a review."
    echo "Nothing to review: no changes since the last approved commit." >> "$GITHUB_STEP_SUMMARY"
    out "range=${BASE:0:7}..${HEAD_SHA:0:7}"
    out "skip=true"
    exit 0
  fi
  # Pure media/font changes can't carry code; pass them without spending a review.
  if ! grep -qviE '\.(png|jpe?g|gif|webp|avif|ico|bmp|tiff?|pdf|woff2?|ttf|otf|eot|mp3|mp4|webm|mov|wav|zip)$' "$RUN_DIR/files.txt"; then
    echo "Only images/fonts/media changed — passing without a review."
    echo "Only images, fonts or media changed — no code to review." >> "$GITHUB_STEP_SUMMARY"
    out "range=${BASE:0:7}..${HEAD_SHA:0:7}"
    out "skip=true"
    exit 0
  fi
  # A push that only installs or tunes this review setup passes without a review.
  # This is what lets the first install go green and become the approved baseline.
  if ! grep -qvE '^(\.github/ai-review/|\.github/workflows/ai-review\.yml$)' "$RUN_DIR/files.txt"; then
    echo "Only the AI Review setup changed — passing without a review."
    echo "Only the AI Review setup itself changed — approved as the baseline." >> "$GITHUB_STEP_SUMMARY"
    out "range=${BASE:0:7}..${HEAD_SHA:0:7}"
    out "skip=true"
    exit 0
  fi
  git diff --stat "$BASE" "$HEAD_SHA" > "$RUN_DIR/stat.txt"
  git diff --no-color --unified=5 "$BASE" "$HEAD_SHA" > "$RUN_DIR/changes.patch"
  out "range=${BASE:0:7}..${HEAD_SHA:0:7}"
else
  git ls-files > "$RUN_DIR/files.txt"
  out "range=whole repository at ${HEAD_SHA:0:7}"
fi

{
  cat .github/ai-review/REVIEW.md
  echo
  echo "---"
  echo
  echo "## This run"
  echo
  echo "- Repository: ${GITHUB_REPOSITORY}"
  echo "- Branch: ${BRANCH}"
  echo "- Commit being shipped: ${HEAD_SHA}"
  echo "- Scope: ${WHY}"
  if [ "$MODE" = "diff" ]; then
    echo "- The full patch is at .ai-review-run/changes.patch, the changed files are listed in"
    echo "  .ai-review-run/files.txt and a summary is in .ai-review-run/stat.txt."
    echo "  You can also run \`git diff ${BASE} ${HEAD_SHA} -- <path>\` for one file."
    echo "- Review these changes. Read the surrounding code to judge real impact."
  else
    echo "- Review the whole repository. The tracked files are listed in .ai-review-run/files.txt."
  fi
  echo "- Ignore the .ai-review-run/ folder itself; it is scratch space for this run."
  if [ -f .github/ai-review/CONTEXT.md ]; then
    echo
    echo "## Project context"
    echo
    cat .github/ai-review/CONTEXT.md
  fi
} > "$RUN_DIR/prompt.md"

echo "Reviewing ${WHY}."
out "skip=false"
