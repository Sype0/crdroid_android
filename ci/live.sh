#!/bin/bash
# Every 3 minutes, push the tail of the resource monitor, the preparation log
# and the build log to the ci-live branch.
dir=/tmp/ci-live
while true; do
    sleep 180
    rm -rf "$dir" && mkdir -p "$dir" && cd "$dir" || continue
    {
        echo "run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID  $(date -u +%FT%TZ)"
        free -m; swapon --show; df -h / /build/src/out 2>/dev/null
        echo "---- monitor ----"; tail -12 /build/monitor.log 2>/dev/null
        echo "---- preparation ----"; tail -25 /build/prep.log 2>/dev/null
        echo "---- build ----"; tail -40 /build/build.log 2>/dev/null | cut -c1-300
    } > live.txt
    git init -q && git checkout -q -b ci-live && git add live.txt &&
        git -c user.name=ci -c user.email=ci@localhost commit -qm live &&
        git push -qf "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY" ci-live
done
