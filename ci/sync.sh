#!/bin/bash
# Sync the tree in chunks and drop each chunk's git history right after checkout.
# The build only needs the working trees; this roughly halves the disk used.
# Run from the top of an initialized repo client.
set -uo pipefail

CHUNK=${CHUNK:-40}
PINS=.repo/local_manifests/zz_pin_saved_state.xml

repo list --all -f > /tmp/projects.txt   # "<abs path> : <name>"
total=$(wc -l < /tmp/projects.txt)
[ "$total" -gt 0 ] || { echo "No projects in manifest"; exit 1; }

# While a saved out/ exists (ci/state.sh), sync upstream projects at the revisions
# it was built from: an upstream commit to e.g. bionic or frameworks/base would
# otherwise make the restored out/ stale and the run rebuild nearly everything.
# Projects from the local manifests still follow their branches.
pin_to_saved_state() {
    rm -f "$PINS"
    "$(dirname "$0")/state.sh" revisions /tmp/saved-revisions.txt ||
        { echo "No saved out/ state, syncing the latest sources"; return 0; }
    python3 - /tmp/saved-revisions.txt /tmp/projects.txt "$PWD" .repo/local_manifests/*.xml > /tmp/pins.xml <<'PY' || return 1
import sys, xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr
saved, projects, top, local = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
revs = dict(l.split() for l in open(saved) if len(l.split()) == 2)
own = {p.get("path") or p.get("name") for f in local for p in ET.parse(f).getroot().iter("project")}
print("<manifest>")
n = 0
for line in open(projects):
    path, _, name = line.strip().partition(" : ")
    path = path.removeprefix(top + "/")
    if path in own or path not in revs:
        continue
    print(f"  <extend-project name={quoteattr(name)} path={quoteattr(path)} revision={quoteattr(revs[path])} />")
    n += 1
print("</manifest>")
print(f"Pinning {n} projects to the saved out/ state", file=sys.stderr)
PY
    mv /tmp/pins.xml "$PINS"
}
pin_to_saved_state || { echo "::warning::Could not pin to the saved state, syncing the latest sources"; rm -f "$PINS"; }

echo "Syncing $total projects in chunks of $CHUNK"

sync_chunk() {
    local jobs
    for jobs in 8 4 2; do
        nice -n 15 ionice -c2 -n7 repo sync -c --jobs-network=$jobs --jobs-checkout=2 \
            --force-sync --no-clone-bundle --no-tags --optimized-fetch "$@" < /dev/null && return 0
        echo "repo sync failed with -j$jobs, retrying"
    done
    # A pinned commit can vanish upstream (force push); take the branch for this chunk.
    if [ -f "$PINS" ]; then
        echo "::warning::Pinned sync failed, syncing this chunk at the latest revisions"
        mv "$PINS" "$PINS.off"
        nice -n 15 ionice -c2 -n7 repo sync -c --jobs-network=4 --jobs-checkout=2 \
            --force-sync --no-clone-bundle --no-tags --optimized-fetch "$@" < /dev/null
        local rc=$?
        mv "$PINS.off" "$PINS"
        return $rc
    fi
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
