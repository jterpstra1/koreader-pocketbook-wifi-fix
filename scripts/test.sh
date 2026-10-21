#!/bin/sh
# Run the simulation tests against a pinned KOReader checkout: the userpatch
# on stock KOReader, and the same scenarios with upstream/pocketbook-wifi.diff
# applied (no userpatch).
#
#   scripts/test.sh [workdir]     (needs: git, python3 with lupa)
set -eu

# The KOReader commit upstream/pocketbook-wifi.diff is made against.
KOREADER_REF=426e932970617aba29e9c249f34bd7c14e4bf680

root=$(cd "$(dirname "$0")/.." && pwd)
work=${1:-"$root/.cache"}
ko="$work/koreader"

if [ ! -d "$ko/.git" ]; then
    mkdir -p "$ko"
    git -C "$ko" init -q
    git -C "$ko" remote add origin https://github.com/koreader/koreader
fi
git -C "$ko" fetch -q --depth 1 origin "$KOREADER_REF"
git -C "$ko" checkout -q --force FETCH_HEAD

echo "== userpatch on stock KOReader"
python3 "$root/tests/run.py" "$ko"

echo "== upstream/pocketbook-wifi.diff"
git -C "$ko" apply "$root/upstream/pocketbook-wifi.diff"
status=0
python3 "$root/tests/run.py" --upstream "$ko" || status=$?
git -C "$ko" checkout -q --force FETCH_HEAD
exit $status
