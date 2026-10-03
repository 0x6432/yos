#!/bin/sh
# Usage: scripts/backup.sh <tag> "<message>"
# Commits, tags, writes a tarball to backups/, and pushes if GH_REMOTE is set.
set -e
TAG=$1; MSG=$2
git add -A
git commit -q -m "$MSG" || true
git tag -f "$TAG" >/dev/null
mkdir -p backups
git archive --format=tar.gz --prefix=yos-$TAG/ -o backups/yos-$TAG.tar.gz "$TAG"
if [ -n "$GH_REMOTE" ]; then
    git push -q "$GH_REMOTE" main
    git push -q -f "$GH_REMOTE" "refs/tags/$TAG"
fi
echo "backup $TAG done"
