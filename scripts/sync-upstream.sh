#!/bin/bash
# scripts/sync-upstream.sh — pull upstream (palmier-io) changes into the Venice fork.
#
# Keeps `main` as a clean mirror of upstream and merges upstream into the Venice
# work branch, reusing past conflict resolutions (rerere) so repeated syncs stay cheap.
#
# Usage:
#   scripts/sync-upstream.sh            # fetch, ff main, merge upstream into work branch, build
#   scripts/sync-upstream.sh --push     # also push the work branch to your fork when clean
#   scripts/sync-upstream.sh --no-build # skip the swift build verification step

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- config: where upstream lives and where our work lives --------------------
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}" # palmier-io/palmier-pro
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"          # local pristine mirror of upstream
WORK_BRANCH="${WORK_BRANCH:-venice-integration}" # our Venice branch
FORK_REMOTE="${FORK_REMOTE:-origin}"            # jordanurbs/venice-video-creator (our repo)

do_push=false
do_build=true
for arg in "$@"; do
    case "$arg" in
        --push) do_push=true ;;
        --no-build) do_build=false ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- make repeated syncs cheap ------------------------------------------------
# rerere remembers how we resolved each conflict and replays it next time.
git config rerere.enabled true
git config rerere.autoUpdate true
# Define the `ours` merge driver referenced by .gitattributes (always keep our
# version of brand-only files). This config is per-clone, so set it idempotently.
git config merge.ours.driver true

# --- safety: refuse to run on a dirty tree ------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    die "working tree is dirty. Commit or stash changes before syncing."
fi

START_BRANCH="$(git symbolic-ref --short HEAD)"

say "Fetching $UPSTREAM_REMOTE (upstream)…"
git fetch "$UPSTREAM_REMOTE" --prune --tags

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

# --- keep local main a pristine fast-forward of upstream ----------------------
if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
    if git merge-base --is-ancestor "$MIRROR_BRANCH" "$UPSTREAM_REF"; then
        if [ "$START_BRANCH" = "$MIRROR_BRANCH" ]; then
            git merge --ff-only "$UPSTREAM_REF"
        else
            git branch -f "$MIRROR_BRANCH" "$UPSTREAM_REF"
        fi
        say "Mirror branch '$MIRROR_BRANCH' fast-forwarded to $UPSTREAM_REF."
    else
        say "WARNING: '$MIRROR_BRANCH' has diverged from $UPSTREAM_REF; leaving it untouched."
        say "         It should be a clean mirror — do all work on '$WORK_BRANCH'."
    fi
else
    git branch "$MIRROR_BRANCH" "$UPSTREAM_REF"
    say "Created mirror branch '$MIRROR_BRANCH' at $UPSTREAM_REF."
fi

# --- merge upstream into the Venice work branch -------------------------------
git checkout "$WORK_BRANCH"

BEHIND="$(git rev-list --count "HEAD..$UPSTREAM_REF")"
if [ "$BEHIND" -eq 0 ]; then
    say "'$WORK_BRANCH' is already up to date with $UPSTREAM_REF. Nothing to merge."
else
    say "Merging $BEHIND upstream commit(s) into '$WORK_BRANCH'…"
    if ! git merge --no-edit "$UPSTREAM_REF"; then
        UNRESOLVED="$(git diff --name-only --diff-filter=U)"
        if [ -n "$UNRESOLVED" ]; then
            echo >&2
            say "Merge stopped on conflicts in:"
            printf '    %s\n' $UNRESOLVED >&2
            echo >&2
            say "Resolve them, then run:  git add -A && git commit --no-edit && swift build"
            say "Or abort entirely with:  git merge --abort"
            exit 1
        fi
    fi
    say "Merge complete."
fi

# --- verify it still builds ---------------------------------------------------
if $do_build; then
    say "Verifying build (swift build)…"
    swift build
    say "Build OK."
fi

# --- optionally publish to the fork ------------------------------------------
if $do_push; then
    say "Pushing '$WORK_BRANCH' to $FORK_REMOTE…"
    git push "$FORK_REMOTE" "$WORK_BRANCH"
fi

say "Done. Upstream synced into '$WORK_BRANCH'."
