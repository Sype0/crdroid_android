#!/bin/bash
# Build; when an attempt fails, keep the synced tree and wait for a fix pushed to
# this repo or to any project in local_manifests.xml, re-sync only what changed,
# then build again. Stops at the job time budget.
# Run from the top of the source tree. Needs JOB_START, JOB_BUDGET_MIN, DEVICE,
# VARIANT, TARGET, WAIT_FOR_FIX, MANIFESTS_DIR.
set -u

# Stop building early enough to save out/ for the next run (ci/state.sh).
SAVE_MIN=${SAVE_MIN:-45}
deadline=$(( JOB_START + (JOB_BUDGET_MIN - SAVE_MIN) * 60 ))
minutes_left() { echo $(( (deadline - $(date +%s)) / 60 )); }
manifest_head() { git ls-remote "https://github.com/$GITHUB_REPOSITORY" "refs/heads/$GITHUB_REF_NAME" | cut -f1; }

# "<path> <url> <sha>" for every project in local_manifests.xml
project_heads() {
    python3 - "$MANIFESTS_DIR/local_manifests.xml" <<'PY' |
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
remotes = {r.get("name"): r.get("fetch").rstrip("/") for r in root.iter("remote")}
for p in root.iter("project"):
    print(p.get("path"), f'{remotes[p.get("remote")]}/{p.get("name")}', p.get("revision"))
PY
    while read -r path url rev; do
        echo "$path $url $(git ls-remote "$url" "refs/heads/$rev" | cut -f1)"
    done
}

# "<path> <hash of the project's manifest entry>": catches linkfile/copyfile
# edits that leave the revision alone
project_entries() {
    python3 - "$MANIFESTS_DIR/local_manifests.xml" <<'PY'
import hashlib, sys, xml.etree.ElementTree as ET
for p in ET.parse(sys.argv[1]).getroot().iter("project"):
    print(p.get("path"), hashlib.sha1(ET.tostring(p)).hexdigest())
PY
}

# Publish the failure to the ci-status branch so it can be read while the job waits.
publish_status() {
    local dir=/tmp/ci-status
    rm -rf "$dir" && mkdir -p "$dir" && cd "$dir" || return
    git init -q && git checkout -q -b ci-status
    {
        echo "run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
        echo "attempt: $1  rc: $2  state: $3  time: $(date -u +%FT%TZ)  minutes_left: $(minutes_left)"
        df -h /build | tail -1
        mountpoint -q /build/src/out && { df -h /build/src/out | tail -1; sudo compsize -x /build/src/out 2>/dev/null | tail -3; }
        echo "---- preparation ----"
        tail -25 /build/prep.log 2>/dev/null
        echo "---- errors ----"
        grep -nE -A6 'error:|FAILED:|ERROR:|Error:|fatal:' /build/build.log | grep -v '^\[ *[0-9]*% ' | head -300
        echo "---- tail ----"
        tail -80 /build/build.log
    } > status.txt
    git add status.txt && git -c user.name=ci -c user.email=ci@localhost commit -qm "attempt $1: $3"
    git push -qf "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY" ci-status
    cd - > /dev/null
}

wait_for_fix() {
    local old_manifest=$1 now_manifest
    echo "::warning::Build failed. Waiting for a fix to be pushed ($(minutes_left)m left; cancel the run to stop)."
    while [ "$(minutes_left)" -gt 20 ]; do
        sleep 60
        now_manifest=$(manifest_head)
        if [ -n "$now_manifest" ] && [ "$now_manifest" != "$old_manifest" ]; then
            git -C "$MANIFESTS_DIR" fetch -q origin "$GITHUB_REF_NAME" && git -C "$MANIFESTS_DIR" reset -q --hard FETCH_HEAD
            return 0
        fi
        project_heads > /tmp/heads.new
        cmp -s /tmp/heads.old /tmp/heads.new || return 0
    done
    return 1
}

resync_changed() {
    cp "$MANIFESTS_DIR/local_manifests.xml" "$MANIFESTS_DIR/ci/remove_unneeded.xml" .repo/local_manifests/
    project_heads > /tmp/heads.new
    local changed
    project_entries > /tmp/entries.new
    changed=$( { diff /tmp/heads.old /tmp/heads.new; diff /tmp/entries.old /tmp/entries.new; } |
        sed -n 's/^> \([^ ]*\) .*/\1/p' | sort -u)
    echo "Re-syncing: ${changed:-nothing}"
    # repo itself breaks with the build-manifest shim in place
    [ -e .repo/repo/repo.real ] && mv -f .repo/repo/repo.real .repo/repo/repo
    for path in $changed; do
        rm -rf "$path" ".repo/projects/$path.git"
        repo sync -c --force-sync --no-clone-bundle --no-tags "$path" < /dev/null || return 1
    done
    mv /tmp/heads.new /tmp/heads.old
    mv /tmp/entries.new /tmp/entries.old
}

# Delete toolchain versions the build does not use (several GB each), plus a few
# large test-only trees. Missing test deps are tolerated via ALLOW_MISSING_DEPENDENCIES.
# Soong's analysis needs far more than the 16 GB of RAM; without the disk swap
# file the runner gets killed. Put it back if it was dropped and there is room.
ensure_disk_swap() {
    local avail
    avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
    if ! swapon --show=NAME --noheadings | grep -qx /swapfile && [ "${avail:-0}" -ge 8192 ]; then
        echo "Re-creating the disk swap file for the analysis"
        sudo fallocate -l 5G /swapfile && sudo chmod 600 /swapfile && sudo mkswap -q /swapfile && sudo swapon -p 10 /swapfile
        avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
    fi
    # The analysis peaks well above RAM + zram; add more while there is room
    if ! swapon --show=NAME --noheadings | grep -qx /swapfile2 && [ "${avail:-0}" -ge 10240 ]; then
        echo "Adding a second swap file for the analysis (${avail}M free)"
        sudo fallocate -l 6G /swapfile2 && sudo chmod 600 /swapfile2 && sudo mkswap -q /swapfile2 && sudo swapon -p 10 /swapfile2
    fi
    swapon --show
}

prune_tree() {
    local default keep d v clang=prebuilts/clang/host/linux-x86
    # Default clang: ClangDefaultVersion up to Android 16, the
    # RELEASE_BUILD_CLANG_VERSION release flag from Android 17 on.
    default=$( { sed -n 's/.*ClangDefaultVersion *= *"\(clang-[^"]*\)".*/\1/p' build/soong/cc/config/global.go
                 grep -rl --include=RELEASE_BUILD_CLANG_VERSION.textproto . build/release vendor/*/release 2>/dev/null |
                     xargs -r grep -hoE '"clang-r[0-9]+[a-z]?"' | tr -d '"'; } | sort -u)
    # Without the default, pruning would delete the compiler the build uses.
    [ -n "$default" ] || { echo "::warning::Default clang version not found, not pruning $clang"; }
    # Plus any other version the build system pins (e.g. bindgen's).
    keep=$( { echo "$default"
              [ -n "$default" ] && grep -rhoE '"clang-r[0-9]+[a-z]?"' build/soong/rust/config build/soong/rust/bindgen.go | tr -d '"'; } |
            sed '/^$/d' | sort -u)
    for v in $keep; do
        if [ ! -d "$clang/$v" ]; then
            echo "$clang/$v is missing (pruned earlier?), re-syncing $clang"
            rm -rf "$clang" ".repo/projects/$clang.git"
            repo sync -c --force-sync --no-clone-bundle --no-tags "$clang" < /dev/null
            # Fresh mtimes on the compiler would make every C/C++ output stale.
            find "$clang" -exec touch -h -d @1577836800 {} +
            break
        fi
    done
    if [ -n "$keep" ]; then
        for d in "$clang"/clang-r*; do
            [ -L "$d" ] && continue
            grep -qx "$(basename "$d")" <<< "$keep" && continue
            # Keep anything a symlink (clang-stable, llvm-binutils-stable, ...) points into.
            find "$clang" -maxdepth 1 -type l -exec readlink {} \; | grep -q "$(basename "$d")" && continue
            echo "Pruning $d (keeping:" $keep")"; rm -rf "$d"
        done
    fi
    v=$(sed -n 's/.*RustDefaultVersion *= *"\([0-9.]*\)".*/\1/p' build/soong/rust/config/global.go)
    if [ -n "$v" ] && [ -d "prebuilts/rust/linux-x86/$v" ]; then
        for d in prebuilts/rust/*/[0-9]*.[0-9]*; do
            [ -L "$d" ] || [ "$(basename "$d")" = "$v" ] && continue
            echo "Pruning $d (default is $v)"; rm -rf "$d"
        done
    fi
    # Whole projects go in ci/remove_unneeded.xml instead, so they are not
    # synced back. Not cts: system modules such as aconfigd-system use it.
}

# Put out/ on a zstd-compressed btrfs image (level 9: the restored out/ must fit
# next to the tree): build output compresses 2-3x,
# which is the only way it fits next to the source on the runner's disk.
setup_compressed_out() {
    mountpoint -q out && return 0
    command -v mkfs.btrfs > /dev/null || sudo apt-get install -y -qq btrfs-progs btrfs-compsize > /dev/null || return 1
    truncate -s 400G /build/out.img && mkfs.btrfs -q -f /build/out.img || return 1
    [ -d out ] && mv out out.plain
    mkdir -p out
    if ! sudo mount -o loop,compress-force=zstd:9,noatime,discard=async /build/out.img out; then
        rmdir out; [ -d out.plain ] && mv out.plain out; rm -f /build/out.img; return 1
    fi
    sudo chown "$(id -u):$(id -g)" out
    if [ -d out.plain ]; then
        echo "Moving existing out/ ($(du -sh out.plain | cut -f1)) onto the compressed volume"
        cp -a out.plain/. out/ && rm -rf out.plain
    fi
}

# LineageOS writes product/etc/build-manifest.xml with `repo manifest -r`, which
# needs the git history ci/sync.sh strips. Answer that one call from the
# revisions recorded during the sync; everything else goes to the real repo.
shim_repo_manifest() {
    local real=.repo/repo/repo.real
    [ -e "$real" ] || mv .repo/repo/repo "$real"
    cat > .repo/repo/repo <<'SHIM'
#!/usr/bin/env python3
# CI shim, see ci/build.sh: pinned manifest without git history
import os, sys
from xml.sax.saxutils import quoteattr
if sys.argv[1:] == ["manifest", "-o", "-", "-r"]:
    print('<?xml version="1.0" encoding="UTF-8"?>')
    print("<manifest>")
    with open("/build/revisions.txt") as f:
        for line in sorted(f):
            path, _, rev = line.strip().partition(" ")
            if path and rev:
                print(f"  <project path={quoteattr(path)} name={quoteattr(path)} revision={quoteattr(rev)} />")
    print("</manifest>")
    sys.exit(0)
real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "repo.real")
os.execv(sys.executable, [sys.executable, real] + sys.argv[1:])
SHIM
    chmod 755 .repo/repo/repo
}

# The disk swap file is only needed for the memory-hungry analysis; zram stays.
free_disk_swap() {
    local f
    # Packaging grows out/ by 10+ GB; that space matters more than swap now
    for f in /swapfile2 /swapfile; do
        swapon --show=NAME --noheadings | grep -qx "$f" || continue
        echo "Analysis done, dropping $f"
        sudo swapoff "$f" && sudo rm -f "$f"
    done
    df -h / | tail -1
}

exec 3>&1 4>&2
exec > >(tee -a /build/prep.log) 2>&1
echo "== preparation, attempt ${ATTEMPT:-1} $(date -u +%T)"
# The real repo is needed while preparing (repo list/sync read their own
# launcher), the shim only for the build itself
[ -e .repo/repo/repo.real ] && mv -f .repo/repo/repo.real .repo/repo/repo
prune_tree
setup_compressed_out || echo "::warning::Could not set up compressed out/, continuing without it"
# Keep room for packing out/ even when the build fills the disk.
[ -f /build/ballast ] || fallocate -l 2500M /build/ballast
if [ ! -f /tmp/state-restored ]; then
    touch /tmp/state-restored
    cp "$MANIFESTS_DIR/ci/state.sh" /build/ci-state.sh
    /build/ci-state.sh restore
fi
df -h /build out | tail -2

# Projects dropped from the CI manifest after the tree was synced still sit on disk.
for path in $(sed -n 's/.*<remove-project path="\([^"]*\)".*/\1/p' "$MANIFESTS_DIR/ci/remove_unneeded.xml"); do
    [ -e "$path" ] && { echo "Removing $path (dropped in ci/remove_unneeded.xml)"; rm -rf "$path"; }
done

# Projects added back to the manifest after the tree was synced are missing on disk.
missing=$(repo list --all -p | while read -r path; do [ -e "$path" ] || echo "$path"; done)
if [ -n "$missing" ]; then
    echo "Syncing missing projects:" $missing
    repo sync -c --force-sync --no-clone-bundle --no-tags $missing < /dev/null
fi

echo "cts present: $([ -d cts ] && echo yes || echo no)"
shim_repo_manifest
exec 1>&3 2>&4 3>&- 4>&-

[ -f /tmp/heads.old ] || project_heads > /tmp/heads.old
[ -f /tmp/entries.old ] || project_entries > /tmp/entries.old
attempt=${ATTEMPT:-1}
while :; do
    left=$(minutes_left)
    [ "$left" -gt 5 ] || { rc=124; break; }
    echo "=== Attempt $attempt, building for at most ${left}m"
    (
        set +u  # envsetup.sh is not nounset-clean
        # Emulator/cuttlefish host tools reference prebuilts dropped in ci/remove_unneeded.xml.
        export ALLOW_MISSING_DEPENDENCIES=true
        source build/envsetup.sh
        breakfast "$DEVICE" "$VARIANT" || exit 1
        # Analysis (Soong/Kati) first, while the disk swap file is there; the
        # build after it needs the disk space more than the swap
        ensure_disk_swap
        timeout --signal=INT --kill-after=2m "${left}m" m --skip-ninja "$TARGET" || exit $?
        free_disk_swap
        # A full disk kills the runner before out/ can be saved: stop the build
        # first, the interrupt is then saved like a timeout
        ( while sleep 20; do
            a=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
            if [ "${a:-0}" -lt 2048 ]; then
                echo "Only ${a}M left on the disk, stopping the build to save out/"
                pkill -INT -f soong_ui
                break
            fi
        done ) &
        guard=$!
        timeout --signal=INT --kill-after=2m "$(minutes_left)m" m "$TARGET" -j"$(nproc)"
        rc=$?
        kill "$guard" 2>/dev/null
        exit $rc
    ) 2>&1 | tee /build/build.log
    rc=${PIPESTATUS[0]}
    df -h /build | tail -1
    [ "$rc" = 0 ] && { publish_status "$attempt" 0 success; break; }
    if [ "$rc" = 124 ] || [ "$rc" = 130 ]; then
        echo "::warning::Build stopped at the time budget; saving out/ so the next run continues."
        break
    fi
    cp /build/build.log "/build/build-attempt$attempt.log"
    if [ "$WAIT_FOR_FIX" != true ]; then publish_status "$attempt" "$rc" failed; break; fi
    publish_status "$attempt" "$rc" waiting-for-fix
    head=$(manifest_head)
    wait_for_fix "$head" || break
    resync_changed || { publish_status "$attempt" "$rc" resync-failed; break; }
    attempt=$((attempt + 1))
    publish_status "$attempt" "" building
    # Continue with the freshly pushed version of this script.
    cp "$MANIFESTS_DIR/ci/build.sh" "/build/ci-build-$attempt.sh"
    ATTEMPT=$attempt exec "/build/ci-build-$attempt.sh"
done
if [ "$rc" != 0 ]; then
    rm -f /build/ballast
    publish_status "$attempt" "$rc" saving-state
    if /build/ci-state.sh save; then st=state-saved; else st=state-save-failed; fi
    # Free the disk so the ccache can still be saved.
    mountpoint -q out && sudo umount out && rm -f /build/out.img
    publish_status "$attempt" "$rc" "$st"
fi
exit "$rc"
