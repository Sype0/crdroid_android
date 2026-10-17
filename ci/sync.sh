#!/bin/bash
# Sync the tree in chunks and drop each chunk's git history right after checkout.
# The build only needs the working trees; this roughly halves the disk used.
# Run from the top of an initialized repo client.
set -uo pipefail

CHUNK=${CHUNK:-40}

repo list --all -f > /tmp/projects.txt   # "<abs path> : <name>"
total=$(wc -l < /tmp/projects.txt)
[ "$total" -gt 0 ] || { echo "No projects in manifest"; exit 1; }
echo "Syncing $total projects in chunks of $CHUNK"

sync_chunk() {
    local jobs
    for jobs in 8 4 2; do
        nice -n 15 ionice -c2 -n7 repo sync -c --jobs-network=$jobs --jobs-checkout=2 \
            --force-sync --no-clone-bundle --no-tags --optimized-fetch "$@" < /dev/null && return 0
        echo "repo sync failed with -j$jobs, retrying"
    done
    return 1
}

i=0
while mapfile -t -n "$CHUNK" chunk && [ ${#chunk[@]} -gt 0 ]; do
    paths=(); names=()
    for line in "${chunk[@]}"; do
        paths+=("${line%% : *}"); names+=("${line##* : }")
    done
    sync_chunk "${paths[@]}" || { df -h /build; exit 1; }
    for k in "${!paths[@]}"; do
        rel=${paths[$k]#"$PWD/"}
        echo "$rel $(git -C "${paths[$k]}" rev-parse HEAD 2>/dev/null)" >> /build/revisions.txt
        rm -rf "${paths[$k]}/.git" ".repo/projects/$rel.git" ".repo/project-objects/${names[$k]}.git"
    done
    i=$((i + ${#chunk[@]}))
    echo "== $i/$total synced, $(df -h --output=avail /build | tail -1) free"
done < /tmp/projects.txt
