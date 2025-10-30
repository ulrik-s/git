#!/usr/bin/env bash
# Demonstration script for Large-Object Promisors (LOPs).
#
# This script initializes a pair of promisor repositories, a primary
# server, and two client clones to highlight the LOP turn-around flow:
#   * A LOP-aware clone that relies on server-advertised promisor
#     filters to stay small until large blobs are demanded.
#   * A traditional full clone that downloads every object.
#
# It records repository sizes after each major step so you can compare
# how much data lives in the server, each promisor, and both clients.
#
# Usage:
#   ./contrib/lop/lop-demo.sh [workdir]
#
# The working directory defaults to "lop-demo" relative to the current
# directory.  Any existing directory with the chosen name will be
# removed.

set -euo pipefail

GIT_BIN=${GIT_BIN:-git}

if [[ $GIT_BIN == */* ]]; then
    if [[ ! -x $GIT_BIN ]]; then
        echo "error: git executable '$GIT_BIN' not found or not executable" >&2
        exit 1
    fi
    GIT_BIN="$(cd "$(dirname "$GIT_BIN")" && pwd)/$(basename "$GIT_BIN")"
    PATH="$(dirname "$GIT_BIN"):$PATH"
    export PATH
else
    if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
        echo "error: git executable '$GIT_BIN' not found" >&2
        exit 1
    fi
    GIT_BIN=$(command -v "$GIT_BIN")
fi

git() {
    "$GIT_BIN" "$@"
}

usage() {
    cat <<'USAGE'
Usage: lop-demo.sh [workdir]

Initializes a demonstration environment that showcases Large-Object
Promisors using two promisor repositories, a primary server, and two
clients (partial vs. full clone).  The script prints repository sizes
after each stage so you can compare disk usage.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

WORKDIR=${1:-lop-demo}

info() {
    printf '\n==> %s\n' "$*"
}

pack_size_kib() {
    local repo=$1
    git -C "$repo" count-objects -v | awk '
        /^size-pack:/ { pack = $2 }
        /^size:/ { loose = $2 }
        END {
            if (pack == "")
                pack = 0;
            if (loose == "")
                loose = 0;
            printf "%d", pack + loose;
        }
    '
}

print_sizes() {
    local header=$1
    shift
    printf '\n-- %s --\n' "$header"
    printf '%-20s %10s\n' "repository" "KiB"
    local repo
    for repo in "$@"; do
        printf '%-20s %10s\n' "$repo" "$(pack_size_kib "$repo")"
    done
}

make_payload() {
    local path=$1
    local size=$2
    python3 - "$size" >"$path" <<'PY'
import sys
size = int(sys.argv[1])
data = b'A' * size
sys.stdout.buffer.write(data)
PY
}

reset_workdir() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    export GIT_CONFIG_GLOBAL="$PWD/global.gitconfig"
    git config --global promisor.acceptFromServer all
}

configure_repository() {
    local repo=$1
    git -C "$repo" config uploadpack.allowFilter true
    git -C "$repo" config uploadpack.allowAnySHA1InWant true
}

setup_remotes() {
    git -C server.git remote add lopLarge "file://$(pwd)/lop-large.git"
    git -C server.git remote add lopSmall "file://$(pwd)/lop-small.git"

    git -C server.git config promisor.advertise true
    git -C server.git config promisor.sendFields partialCloneFilter

    git -C server.git config receive.lop.enable true

    git -C server.git config remote.lopLarge.promisor true
    git -C server.git config remote.lopLarge.partialclonefilter "blob:limit=524288"
    git -C server.git config remote.lopSmall.promisor true
    git -C server.git config remote.lopSmall.partialclonefilter "blob:limit=131072"
}

bootstrap_repositories() {
    info "Creating repositories"
    git init --bare server.git
    git init --bare lop-large.git
    git init --bare lop-small.git

    git -C server.git symbolic-ref HEAD refs/heads/main

    configure_repository server.git
    configure_repository lop-large.git
    configure_repository lop-small.git

    setup_remotes

    info "Bootstrapping baseline history"
    git clone "file://$(pwd)/server.git" author
    (
        cd author
        git config user.name "LOP Demo"
        git config user.email "lop@example.com"
        echo "baseline" >README.md
        git add README.md
        git commit -m "Initial commit"
        git push origin HEAD:main
    )
    print_sizes "After baseline push" server.git lop-large.git lop-small.git
}

publish_large_payloads() {
    info "Creating large and medium payloads"
    (
        cd author
        mkdir -p assets media
        make_payload assets/video.bin 1048576
        git add assets/video.bin
        git commit -m "Add large video asset"

        make_payload media/preview.bin 262144
        git add media/preview.bin
        git commit -m "Add medium preview asset"

        git push origin HEAD:main
    )
    print_sizes "After pushing large assets" server.git lop-large.git lop-small.git
}

clone_clients() {
    info "Cloning LOP-enabled client"
    # Use the server-advertised blob filter (blob:none) to keep the initial
    # clone small; this mirrors the configuration the server exposes to
    # ordinary clients.
    GIT_NO_LAZY_FETCH=0 git clone --filter=blob:none --no-checkout "file://$(pwd)/server.git" client-lop
    print_sizes "After LOP clone" client-lop

    info "Trigger lazy fetch of the large blob in client-lop"
    GIT_NO_LAZY_FETCH=0 git -C client-lop show HEAD:assets/video.bin >/dev/null
    print_sizes "client-lop after accessing large blob" client-lop

    info "Cloning traditional full client"
    git -C server.git config promisor.advertise false
    GIT_NO_LAZY_FETCH=0 git clone --no-checkout "file://$(pwd)/server.git" client-full
    git -C server.git config promisor.advertise true
    print_sizes "After full clone" client-full
}

compare_clients() {
    print_sizes "Server and promisor stores" server.git lop-large.git lop-small.git
    print_sizes "Clients" client-lop client-full
    info "For convenience, repository paths are located under:"
    printf '  %s\n' "$(pwd)"
}

main() {
    reset_workdir
    bootstrap_repositories
    publish_large_payloads
    clone_clients
    compare_clients
}

main "$@"
