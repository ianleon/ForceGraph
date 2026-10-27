#!/bin/sh
# Publish locally compiled, synthetic demo assets to the repository's Pages branch.
# Run build-web-demo.sh and review the result first. The caller authorizes the push.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REMOTE=${FORCEGRAPH_PAGES_REMOTE:-git@github.com:ianleon/ForceGraph.git}
BRANCH=gh-pages

for file in index.html styles.css demo.js engine.js forcegraph.wasm.gz build-info.json; do
    test -f "$ROOT/Web/$file" || { echo "Missing Web/$file; build the demo first." >&2; exit 1; }
done

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/forcegraph-pages.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

git init -q -b "$BRANCH" "$STAGING"
git -C "$STAGING" remote add origin "$REMOTE"
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    git -C "$STAGING" fetch -q --depth 1 origin "$BRANCH"
    git -C "$STAGING" checkout -q -B "$BRANCH" FETCH_HEAD
    git -C "$STAGING" rm -q -r --ignore-unmatch .
fi
for file in index.html styles.css demo.js engine.js forcegraph.wasm.gz build-info.json; do
    cp "$ROOT/Web/$file" "$STAGING/$file"
done
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$STAGING/"
: > "$STAGING/.nojekyll"
git -C "$STAGING" add .
if git -C "$STAGING" diff --cached --quiet; then
    echo "Pages assets already match."
    exit 0
fi
SOURCE=$(git -C "$ROOT" rev-parse --short HEAD)
git -C "$STAGING" commit -q -m "Publish Swift/Wasm playground from $SOURCE"
git -C "$STAGING" push origin "HEAD:refs/heads/$BRANCH"
