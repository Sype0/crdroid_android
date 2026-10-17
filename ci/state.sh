#!/bin/bash
# Carry out/ between workflow runs as zstd-compressed tar chunks attached to the
# "ci-out-state" release, so a build that runs out of job time continues next run.
#   state.sh restore   download and unpack a saved out/, normalize source mtimes
#   state.sh save      pack out/ and replace the saved state
# Run from the top of the source tree. /build/revisions.txt ("<path> <sha>") is
# written by ci/sync.sh.
set -uo pipefail

TAG=ci-out-state
REPO=$GITHUB_REPOSITORY
EPOCH=1577836800   # 2020-01-01: older than every restored output
CHUNK=1900M        # release assets must be < 2 GiB
export SHELL=/bin/bash

assets() { gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null; }

restore() {
    local dir=/build/state changed
    assets | grep -q '^revisions.txt$' || { echo "No saved out/ state"; return 0; }
    rm -rf "$dir" && mkdir -p "$dir"
    gh release download "$TAG" -R "$REPO" -p revisions.txt -D "$dir" || return 1

    # Freshly synced files are newer than the saved outputs. Age every source file,
    # then re-touch projects whose revision changed so only those get rebuilt.
    echo "Normalizing source mtimes"
    find . -path ./out -prune -o -path ./.repo -prune -o -exec touch -h -d "@$EPOCH" {} +
    changed=$(comm -23 <(sort /build/revisions.txt) <(sort "$dir/revisions.txt") | cut -d' ' -f1)
    echo "Projects changed since the saved state:" $changed
    for p in $changed; do [ -e "$p" ] && find "$p" -exec touch -h {} +; done

    echo "Restoring out/"
    for a in $(assets | grep '^out\.tar\.zst\.' | sort); do
        gh release download "$TAG" -R "$REPO" -p "$a" -O - || exit 1
    done | zstd -dc -T0 | tar -x -C out || { echo "::warning::Restoring out/ failed, building from scratch"; rm -rf out/* out/.[!.]*; return 1; }
    du -sh out
}

save() {
    local a revs=/build/revisions.save
    # Local manifest projects may have been re-synced during the run.
    cp /build/revisions.txt "$revs"
    if [ -f /tmp/heads.old ]; then
        while read -r path _ sha; do
            grep -v "^$path " "$revs" > "$revs.tmp"; echo "$path $sha" >> "$revs.tmp"; mv "$revs.tmp" "$revs"
        done < /tmp/heads.old
    fi

    gh release view "$TAG" -R "$REPO" > /dev/null 2>&1 || gh release create "$TAG" -R "$REPO" --prerelease \
        --title "CI build state (not a ROM)" --notes "Partial out/ used to resume the next CI build. Do not flash." || return 1
    for a in $(assets); do gh release delete-asset "$TAG" "$a" -R "$REPO" -y; done

    echo "Saving out/ ($(du -sh out | cut -f1))"
    tar -C out -cf - . | zstd -T0 -3 -q | TAG=$TAG split -b "$CHUNK" -d -a 3 \
        --filter='f=/build/$FILE; cat > "$f" && gh release upload "$TAG" "$f" -R "$GITHUB_REPOSITORY" --clobber && rm -f "$f"' \
        - out.tar.zst. || return 1
    # Uploaded last: restore() treats a state without revisions.txt as absent.
    mkdir -p /build/revup && cp "$revs" /build/revup/revisions.txt
    gh release upload "$TAG" /build/revup/revisions.txt -R "$REPO" --clobber || return 1
    echo "Saved $(assets | grep -c '^out\.tar\.zst\.') chunks"
}

"$@"
