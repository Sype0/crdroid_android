#!/bin/bash
# Carry out/ between workflow runs as zstd-compressed tar chunks attached to the
# "ci-out-state" release, so a build that runs out of job time continues next run.
#   state.sh restore        normalize source mtimes, unpack a saved out/ except
#                           the build outputs (BULK): the analysis does not need
#                           them, and the disk they take is needed for swap
#   state.sh restore_bulk   unpack the build outputs after the analysis, keeping
#                           the files the analysis wrote
#   state.sh save           pack out/ and replace the saved state
# Run from the top of the source tree. /build/revisions.txt ("<path> <sha>") is
# written by ci/sync.sh.
set -uo pipefail

TAG=ci-out-state
REPO=$GITHUB_REPOSITORY
EPOCH=1577836800   # 2020-01-01: older than every restored output
CHUNK=1900M        # release assets must be < 2 GiB
export SHELL=/bin/bash
# Saved as out.tar.zst.*, the rest of out/ as out-meta.tar.zst.*. A state saved
# before this split has all of out/ in out.tar.zst.*.
BULK=(./target ./host ./soong/.intermediates)

assets() { gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null; }
bulk_excludes() { local b; for b in "${BULK[@]}"; do echo "--exclude=$b"; echo "--exclude=$b/*"; done; }
# fetch <prefix>: the concatenated chunks of <prefix>.tar.zst.* on stdout
fetch() {
    local a
    for a in $(assets | grep "^$1\.tar\.zst\." | sort); do
        gh release download "$TAG" -R "$REPO" -p "$a" -O - || return 1
    done
}
# After a failed restore, keep the saved state instead of replacing it with less.
no_save() { touch /build/no-save-state; echo "::warning::$1; the saved state will not be replaced"; }

restore() {
    local dir=/build/state changed ex
    # Freshly synced files are newer than the saved outputs. Age every source file,
    # then re-touch projects whose revision changed so only those get rebuilt.
    # Also on a first run: Siso (Android 17) records the exact input mtimes, so
    # the state it saves only matches the next run if both used the same ones.
    echo "Normalizing source mtimes"
    find . -path ./out -prune -o -path ./.repo -prune -o -exec touch -h -d "@$EPOCH" {} +
    assets | grep -q '^revisions.txt$' || { echo "No saved out/ state"; return 0; }
    rm -rf "$dir" && mkdir -p "$dir"
    gh release download "$TAG" -R "$REPO" -p revisions.txt -D "$dir" || return 1

    changed=$(comm -23 <(sort /build/revisions.txt) <(sort "$dir/revisions.txt") | cut -d' ' -f1)
    echo "Projects changed since the saved state:" $changed
    for p in $changed; do [ -e "$p" ] && find "$p" -exec touch -h {} +; done

    if assets | grep -q '^out-meta\.tar\.zst\.'; then
        echo "Restoring out/ without the build outputs"
        fetch out-meta | zstd -dc -T0 | tar -x -C out
    else
        echo "Restoring out/ without the build outputs (from a full archive)"
        mapfile -t ex < <(bulk_excludes)
        fetch out | zstd -dc -T0 | tar -x -C out "${ex[@]}"
    fi || { no_save "Restoring out/ failed, building from scratch"; rm -rf out/* out/.[!.]*; return 1; }
    touch /build/bulk-pending
    du -sh out
}

restore_bulk() {
    [ -f /build/bulk-pending ] || return 0
    echo "Restoring the build outputs in out/"
    fetch out | zstd -dc -T0 | tar -x -C out --skip-old-files ||
        { no_save "Restoring the build outputs failed"; return 1; }
    rm -f /build/bulk-pending
    du -sh out
}

# pack <prefix> <tar args>: upload out/ as <prefix>.tar.zst.* chunks
pack() {
    local prefix=$1; shift
    tar -C out -cf - "$@" | zstd -T0 -3 -q | TAG=$TAG split -b "$CHUNK" -d -a 3 \
        --filter='f=/build/$FILE; cat > "$f" && gh release upload "$TAG" "$f" -R "$GITHUB_REPOSITORY" --clobber && rm -f "$f"' \
        - "$prefix.tar.zst."
}

save() {
    local a b revs=/build/revisions.save ex present=()
    [ -f /build/no-save-state ] && { echo "Not saving out/: it was not fully restored"; return 1; }
    # Stopped before the analysis finished: nothing was built, keep the saved state.
    [ -f /build/bulk-pending ] && { echo "Build outputs were never restored, keeping the saved state"; return 0; }
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
    mapfile -t ex < <(bulk_excludes)
    pack out-meta "${ex[@]}" . || return 1
    for b in "${BULK[@]}"; do [ -e "out/$b" ] && present+=("$b"); done
    [ ${#present[@]} -eq 0 ] || pack out "${present[@]}" || return 1
    # Uploaded last: restore() treats a state without revisions.txt as absent.
    mkdir -p /build/revup && cp "$revs" /build/revup/revisions.txt
    gh release upload "$TAG" /build/revup/revisions.txt -R "$REPO" --clobber || return 1
    echo "Saved $(assets | grep -c '\.tar\.zst\.') chunks"
}

"$@"
