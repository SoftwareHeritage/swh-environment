#!/bin/bash
# Run the four-cell test matrix inside the Docker image.
# Bind-mount the host's swh-environment to /work; results land in
# /work/notes/git-loader-rehaul/test-rig/results/.
#
# This script uses the container's SYSTEM Python (where the Dockerfile
# pre-installed pytest + maturin + cassandra-driver). No venv layer is
# created — keeps the per-cell setup fast and avoids interpreter / dep
# duplication.

set -u
RESULTS=/work/notes/git-loader-rehaul/test-rig/results
mkdir -p "$RESULTS"

# Container runs as uid=1000 (host user); no safe.directory tripwire,
# initdb works (PG refuses root).  Install editable into ~/.local via
# `pip install --user`.

# Remove any stale .venv left from earlier script versions.
rm -rf /work/.venv /work/notes/git-loader-rehaul/test-rig/.venv 2>/dev/null || true

echo "=== editable installs (pip install --user) ==="
for d in swh-core swh-model swh-shard swh-objstorage swh-storage \
         swh-scheduler swh-vault swh-journal swh-loader-core; do
    echo "  pip install --user -e /work/$d"
    pip install --user --no-build-isolation -e /work/$d 2>&1 | tail -1 \
        || echo "  (failed: $d — continuing)"
done

# Build _gix.so via maturin (rebuilds for each branch's gix-py source).
# Uses `maturin build` + pip install of the resulting wheel because
# `maturin develop` requires a venv and we use the container's system
# python instead.
build_gix () {
    if [ ! -d /work/swh-loader-git/gix-py ]; then
        echo "  no gix-py/ on this branch — skipping _gix build (master path)"
        return 0
    fi
    echo "  building _gix.so via maturin (workdir=/work/swh-loader-git/gix-py)..."
    pushd /work/swh-loader-git/gix-py >/dev/null
    rm -rf /tmp/gix-wheels && mkdir -p /tmp/gix-wheels
    maturin build --release --out /tmp/gix-wheels 2>&1 | tail -3
    pip install --user --force-reinstall --no-deps /tmp/gix-wheels/*.whl 2>&1 | tail -1
    popd >/dev/null
}

# Install swh-loader-git Python package (gix-py already provides _gix; this
# step adds the Python source as editable but skips the Rust rebuild).
install_loader () {
    echo "  pip install --user -e swh-loader-git (Python part)"
    pip install --user --no-build-isolation -e /work/swh-loader-git 2>&1 | tail -2 || true
    # The pip install above may write a stale _gix.cpython-*.so into the
    # package dir, masking the maturin-installed one in site-packages.
    # Remove it so 'from swh.loader.git import _gix' picks up the latest.
    rm -f /work/swh-loader-git/swh/loader/git/_gix*.so 2>/dev/null || true
}

run_cell () {
    local repo="$1" branch="$2" cellid="$3" needs_gix="$4"
    local log="$RESULTS/${cellid}.log"
    {
        echo "=================================================================="
        echo "# host: docker-bookworm"
        echo "# repo: $repo"
        echo "# branch: $branch"
    } | tee "$log"
    cd "/work/$repo"
    # Force-checkout to overwrite any leftover untracked-from-prior-cell files
    # (e.g., the rehaul branch's gix-lib/ tracked files persist as untracked
    # after a master checkout if not cleaned).  Then `git clean -fd` removes
    # any remaining untracked dirs that aren't ignored (target/, .pytest_cache/
    # are in .gitignore and survive — that's intentional, cargo and pytest
    # handle their own caches).
    git checkout -f "$branch" 2>&1 | tee -a "$log"
    git clean -fd 2>&1 | tee -a "$log"
    {
        echo "# commit: $(git rev-parse HEAD)"
        echo "# started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "=================================================================="
    } | tee -a "$log"
    if [ "$needs_gix" = "yes" ]; then
        build_gix      2>&1 | tee -a "$log"
        install_loader 2>&1 | tee -a "$log"
    fi
    cd "/work/$repo"
    if [ -f Makefile ] && [ "$repo" = "swh-loader-git" ]; then
        make test 2>&1 | tee -a "$log"
    else
        pytest 2>&1 | tee -a "$log"
    fi
    local rc=${PIPESTATUS[0]}
    {
        echo "=================================================================="
        echo "# finished_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# exit_status: $rc"
    } | tee -a "$log"
    cd /work
}

run_cell swh-loader-git master                                    D-loader-master  yes
run_cell swh-loader-git fix/gix-loader-pack-reader-tree-tuple     D-loader-rehaul  yes
run_cell swh-storage   origin/master                              D-storage-master no
run_cell swh-storage   feat/content-add-concurrent                D-storage-recl4  no

echo "ALL DONE: results in $RESULTS/"
touch "$RESULTS/.done"
