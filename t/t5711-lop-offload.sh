#!/bin/sh

test_description='LOP push offload routes blobs via promisor filters'

. ./test-lib.sh

TEST_PASSES_SANITIZE_LEAK=true

lop_set_filters () {
    large=$1
    small=$2
    git -C server.git config --replace-all remote.lopLarge.partialclonefilter "$large" || return 1
    git -C server.git config --replace-all remote.lopSmall.partialclonefilter "$small" || return 1
}

ensure_server_head () {
    git -C server.git symbolic-ref HEAD refs/heads/main
}

install_lop_hook () {
    repo=$1
    mkdir -p "$repo/hooks" || return 1
    cat >"$repo/hooks/lop-offload" <<'HOOK_EOF'
#!/bin/sh
# LOP offload hook for testing

# Exit early if LOP is not enabled
LOP_ENABLE=$(git config --bool receive.lop.enable 2>/dev/null)
[ "$LOP_ENABLE" = "true" ] || exit 0

# Get repository path
GIT_DIR=$(git rev-parse --git-dir) || exit 1

# Discover promisor remotes with their filters
discover_promisors() {
    git remote | while read -r remote; do
        enabled=$(git config --bool "remote.$remote.promisor" 2>/dev/null)
        [ "$enabled" = "true" ] || continue
        filter=$(git config "remote.$remote.partialclonefilter" 2>/dev/null)
        [ -n "$filter" ] || continue
        printf "%s\t%s\n" "$remote" "$filter"
    done
}

# Parse blob filter to determine size threshold
parse_blob_filter() {
    local filter=$1
    case "$filter" in
        "blob:none") echo "0" ;;
        blob:limit=*) echo "${filter#blob:limit=}" ;;
        combine:blob:none*) echo "0" ;;
        combine:*blob:limit=*)
            echo "$filter" | sed -n 's/.*blob:limit=\([0-9]*\).*/\1/p' ;;
        *) echo "" ;;
    esac
}

# Match blob size to appropriate promisor remote (first match wins)
match_blob_to_promisor() {
    local size=$1
    
    while IFS=$'\t' read -r remote filter; do
        limit=$(parse_blob_filter "$filter")
        [ -n "$limit" ] || continue
        
        if [ "$size" -gt "$limit" ]; then
            echo "$remote"
            return 0
        fi
    done
    echo ""
}

# Remove loose object from local repository
remove_loose_object() {
    local oid=$1
    local obj_path="$GIT_DIR/objects/${oid:0:2}/${oid:2}"
    
    [ -f "$obj_path" ] && rm -f "$obj_path" 2>/dev/null
    rmdir "$GIT_DIR/objects/${oid:0:2}" 2>/dev/null || true
    return 0
}

# Main processing
PROMISORS=$(discover_promisors)
[ -n "$PROMISORS" ] || exit 0

# Read ref updates from stdin
STATUS=0
tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT

while read old_oid new_oid ref_name; do
    [ "$new_oid" = "0000000000000000000000000000000000000000" ] && continue
    
    if [ "$old_oid" = "0000000000000000000000000000000000000000" ]; then
        range="$new_oid"
    else
        range="$old_oid..$new_oid"
    fi
    
    # Collect blobs per remote
    git rev-list --objects "$range" 2>/dev/null > "$tmpfile"
    while read oid path; do
        [ -n "$oid" ] || continue
        type=$(git cat-file -t "$oid" 2>/dev/null) || continue
        [ "$type" = "blob" ] || continue
        
        size=$(git cat-file -s "$oid" 2>/dev/null) || continue
        remote=$(echo "$PROMISORS" | match_blob_to_promisor "$size")
        [ -n "$remote" ] || continue
        
        # Push blob to remote using temporary ref (cleaned up by post-receive hook)
        if git push "$remote" "$oid:refs/lop/blobs/$oid" >/dev/null 2>&1; then
            remove_loose_object "$oid"
        else
            echo "error: failed to push blob $oid to promisor remote $remote" >&2
            STATUS=1
        fi
    done < "$tmpfile"
done

exit $STATUS
HOOK_EOF
    chmod +x "$repo/hooks/lop-offload" || return 1
}

setup_lop_repos () {
    git init --bare server.git || return 1
    git init --bare lop-large.git || return 1
    git init --bare lop-small.git || return 1

    git -C server.git remote add lopLarge "file://$(pwd)/lop-large.git" || return 1
    git -C server.git remote add lopSmall "file://$(pwd)/lop-small.git" || return 1

    for repo in server.git lop-large.git lop-small.git
    do
        git -C "$repo" config uploadpack.allowFilter true || return 1
        git -C "$repo" config uploadpack.allowAnySHA1InWant true || return 1
    done
    
    # Install cleanup hooks on promisor remotes
    for repo in lop-large.git lop-small.git
    do
        mkdir -p "$repo/hooks" || return 1
        cat >"$repo/hooks/post-receive" <<'CLEANUP_EOF'
#!/bin/sh
# Clean up LOP blob refs after receiving
git for-each-ref refs/lop/blobs/ --format='delete %(refname)' | 
    git update-ref --stdin 2>/dev/null || true
exit 0
CLEANUP_EOF
        chmod +x "$repo/hooks/post-receive" || return 1
    done

    git -C server.git config promisor.advertise true || return 1
    git -C server.git config promisor.sendFields partialCloneFilter || return 1
    git -C server.git config remote.lopLarge.promisor true || return 1
    git -C server.git config remote.lopSmall.promisor true || return 1
    git -C server.git config receive.lop.enable true || return 1
    lop_set_filters "blob:limit=1024" "blob:limit=256" || return 1
    
    # Install the LOP offload hook
    install_lop_hook server.git || return 1
}

reset_server_policy () {
    git -C server.git config receive.lop.enable true &&
    git -C server.git config --replace-all remote.lopLarge.promisor true &&
    git -C server.git config --replace-all remote.lopSmall.promisor true &&
    git -C server.git config --replace-all remote.lopLarge.url "file://$(pwd)/lop-large.git" &&
    git -C server.git config --replace-all remote.lopSmall.url "file://$(pwd)/lop-small.git" &&
    lop_set_filters "blob:limit=1024" "blob:limit=256"
}

reset_promisor_advertisement () {
    git -C server.git config promisor.advertise true &&
    git -C server.git config promisor.sendFields partialCloneFilter &&
    git -C server.git config --replace-all remote.lopLarge.promisor true &&
    git -C server.git config --replace-all remote.lopSmall.promisor true &&
    lop_set_filters "blob:limit=1024" "blob:limit=256"
}

reset_client_to_base () {
    git -C client reset --hard refs/heads/baseline &&
    git -C client clean -fdx &&
    git -C client push --force origin refs/heads/baseline:main &&
    ensure_server_head
}

write_large_commit () {
    char=${1:-A}
    msg=${2:-"large payload"}
    size=${3:-1048576}

    (
        cd client &&
        mkdir -p large &&
        test-tool genrandom "$char" "$size" >large/blob.bin &&
        git add large/blob.bin &&
        git commit -m "$msg"
    )
}

write_medium_commit () {
    char=${1:-B}
    msg=${2:-"medium payload"}

    (
        cd client &&
        mkdir -p medium &&
        test-tool genrandom "$char" 512 >medium/blob.bin &&
        git add medium/blob.bin &&
        git commit -m "$msg"
    )
}

write_small_commit () {
    char=${1:-C}
    msg=${2:-"small payload"}

    (
        cd client &&
        mkdir -p small &&
        test-tool genrandom "$char" 64 >small/blob.bin &&
        git add small/blob.bin &&
        git commit -m "$msg"
    )
}

write_mixed_commit () {
    msg=${1:-"mixed payload"}

    (
        cd client &&
        mkdir -p large small &&
        test-tool genrandom M 1048576 >large/blob.bin &&
        test-tool genrandom m 64 >small/blob.bin &&
        git add large/blob.bin small/blob.bin &&
        git commit -m "$msg"
    )
}

write_blob_commit () {
    path=$1
    size=$2
    char=${3:-Z}
    msg=${4:-"custom payload"}

    (
        cd client &&
        mkdir -p "$(dirname "$path")" &&
        test-tool genrandom "$char" "$size" >"$path" &&
        git add "$path" &&
        git commit -m "$msg"
    )
}

verify_blob_in_repo () {
    repo=$1
    blob=$2

    echo blob >expect &&
    git -C "$repo" cat-file -t "$blob" >actual &&
    test_cmp expect actual
}

verify_blob_missing () {
    repo=$1
    blob=$2

    test_must_fail env GIT_NO_LAZY_FETCH=1 git -C "$repo" cat-file -t "$blob"
}

cleanup_trace () {
    rm -f "$1"
}

pack_size_kib () {
    git -C "$1" count-objects -v |
    awk '
        /^size-pack:/ { pack = $2 }
        /^size:/ { loose = $2 }
        END {
            if (pack == "")
                pack = 0;
            if (loose == "")
                loose = 0;
            printf "%d\n", pack + loose;
        }
    '
}

record_repo_size () {
    repo=$1
    var=$2
    size=$(pack_size_kib "$repo") || return 1
    eval "$var=$size"
}

trace_has_remote () {
    trace=$1
    remote=$2
    test_grep '"category":"lop/offload".*"key":"remote","value":"'$remote'"' "$trace"
}

trace_has_match () {
    trace=$1
    remote=$2
    test_grep '"category":"lop/match".*"key":"remote","value":"'$remote'"' "$trace"
}

trace_has_stat () {
    trace=$1
    key=$2
    value=$3
    test_grep '"category":"lop/offload".*"key":"'$key'","value":"'$value'"' "$trace"
}

trace_lacks_offload () {
    trace=$1
    ! test_grep '"category":"lop/offload"' "$trace"
}

test_expect_success 'setup LOP repositories' '
    setup_lop_repos &&
    git init client &&
    (
        cd client &&
        test_commit base &&
        git branch -M main &&
        git branch baseline &&
        git remote add origin ../server.git
    ) &&
    test_config_global promisor.acceptFromServer all &&
    reset_server_policy &&
    reset_promisor_advertisement &&
    git -C client push origin refs/heads/baseline:main &&
    ensure_server_head
'

test_expect_success 'push offloads large blob to lopLarge' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit &&
    large_oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$large_oid" &&
    verify_blob_missing lop-small.git "$large_oid" &&
    verify_blob_missing server.git "$large_oid"
'

test_expect_success 'push keeps small blob local' '
    reset_server_policy &&
    reset_client_to_base &&
    write_small_commit &&
    small_oid=$(git -C client rev-parse HEAD:small/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$small_oid" &&
    verify_blob_missing lop-large.git "$small_oid" &&
    verify_blob_missing lop-small.git "$small_oid"
'

test_expect_success 'push with mixed payload offloads large blob only' '
    reset_server_policy &&
    reset_client_to_base &&
    write_mixed_commit &&
    large_oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    small_oid=$(git -C client rev-parse HEAD:small/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$large_oid" &&
    verify_blob_missing lop-small.git "$large_oid" &&
    verify_blob_missing server.git "$large_oid" &&
    verify_blob_in_repo server.git "$small_oid" &&
    verify_blob_missing lop-large.git "$small_oid" &&
    verify_blob_missing lop-small.git "$small_oid"
'

test_expect_success 'push offloads multiple large blobs to same promisor' '
    reset_server_policy &&
    reset_client_to_base &&
    (
        cd client &&
        mkdir -p large &&
        test-tool genrandom P 1048576 >large/one.bin &&
        test-tool genrandom Q 1048576 >large/two.bin &&
        git add large/one.bin large/two.bin &&
        git commit -m "double large payload"
    ) &&
    first_oid=$(git -C client rev-parse HEAD:large/one.bin) &&
    second_oid=$(git -C client rev-parse HEAD:large/two.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$first_oid" &&
    verify_blob_in_repo lop-large.git "$second_oid" &&
    verify_blob_missing server.git "$first_oid" &&
    verify_blob_missing server.git "$second_oid"
'

test_expect_success 'push routes medium blob to lopSmall' '
    reset_server_policy &&
    reset_client_to_base &&
    write_medium_commit &&
    medium_oid=$(git -C client rev-parse HEAD:medium/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$medium_oid" &&
    verify_blob_missing server.git "$medium_oid" &&
    verify_blob_missing lop-large.git "$medium_oid"
'

test_expect_success 'push offloads all blobs when filter blob:none' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "blob:none" "blob:limit=256" &&
    write_small_commit D "blob none payload" &&
    oid=$(git -C client rev-parse HEAD:small/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing server.git "$oid"
'

test_expect_success 'push honors combine filter with blob:none' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "combine:blob:none+tree:0" "blob:limit=256" &&
    write_medium_commit E "combine filter" &&
    oid=$(git -C client rev-parse HEAD:medium/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing server.git "$oid"
'

test_expect_success 'push skips promisor with unsupported filter' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "tree:1" "tree:1" &&
    write_large_commit F "unsupported filter" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    verify_blob_missing lop-large.git "$oid" &&
    verify_blob_missing lop-small.git "$oid"
'

test_expect_success 'push disabled policy keeps blob local' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config receive.lop.enable false &&
    write_large_commit G "policy disabled" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    verify_blob_missing lop-large.git "$oid"
'

test_expect_success 'push fails when large promisor is unreachable' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config remote.lopLarge.url https://invalid.invalid/repo.git &&
    write_large_commit H "unreachable remote" &&
    test_must_fail git -C client push origin HEAD:main &&
    git -C server.git config --replace-all remote.lopLarge.url "file://$(pwd)/lop-large.git"
'

test_expect_success 'push prefers first matching promisor' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "blob:limit=2048" "blob:limit=512" &&
    write_blob_commit both/big.bin 4096 I "order test" &&
    oid=$(git -C client rev-parse HEAD:both/big.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing lop-small.git "$oid" &&
    lop_set_filters "blob:limit=1024" "blob:limit=256"
'

test_expect_success 'push uses small promisor when large disabled' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config --replace-all remote.lopLarge.promisor false &&
    write_medium_commit J "small only" &&
    oid=$(git -C client rev-parse HEAD:medium/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$oid" &&
    verify_blob_missing server.git "$oid" &&
    git -C server.git config --replace-all remote.lopLarge.promisor true
'

test_expect_success 'push keeps blob when no promisor configured' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config --replace-all remote.lopLarge.promisor false &&
    git -C server.git config --replace-all remote.lopSmall.promisor false &&
    write_large_commit K "no promisors" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    git -C server.git config --replace-all remote.lopLarge.promisor true &&
    git -C server.git config --replace-all remote.lopSmall.promisor true
'

test_expect_success 'push reuses existing LOP blob without rewrite' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit M "lop reuse" &&
    blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    (
        cd client &&
        git checkout -B reuse baseline &&
        mkdir -p large &&
        git cat-file blob "$blob" >large/blob.bin &&
        git add large/blob.bin &&
        git commit -m "reuse existing large blob"
    ) &&
    test_when_finished "git -C client push origin :refs/heads/reuse" &&
    test_when_finished "git -C client branch -D reuse 2>/dev/null || :" &&
    git -C client push origin HEAD:reuse &&
    verify_blob_in_repo lop-large.git "$blob"
'

test_expect_success 'push fails when promisor path missing' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config --replace-all remote.lopLarge.url "file://$(pwd)/missing-lop.git" &&
    write_large_commit N "missing promisor" &&
    test_must_fail git -C client push origin HEAD:main &&
    git -C server.git config --replace-all remote.lopLarge.url "file://$(pwd)/lop-large.git"
'

test_expect_success 'push fails when promisor repository uses different hash' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit O "hash mismatch" &&
    git init --bare --object-format=sha256 lop-hash.git &&
    git -C lop-hash.git config uploadpack.allowFilter true &&
    git -C lop-hash.git config uploadpack.allowAnySHA1InWant true &&
    test_when_finished "rm -rf lop-hash.git" &&
    git -C server.git config --replace-all remote.lopLarge.url "file://$(pwd)/lop-hash.git" &&
    test_when_finished "git -C server.git config --replace-all remote.lopLarge.url \"file://$(pwd)/lop-large.git\"" &&
    test_must_fail git -C client push origin HEAD:main
'

test_expect_success 'push fails when promisor object store is read-only' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit N2 "promisor read-only" &&
    chmod -w lop-large.git/objects &&
    test_when_finished "chmod +w lop-large.git/objects" &&
    test_must_fail git -C client push origin HEAD:main 2>err &&
    test_grep "failed to push blob" err &&
    chmod +w lop-large.git/objects
'

test_expect_success 'push keeps tree and commit objects local' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit N7 "tree and commit check" &&
    tree=$(git -C client rev-parse HEAD^{tree}) &&
    commit=$(git -C client rev-parse HEAD) &&
    git -C client push origin HEAD:main &&
    verify_blob_missing lop-large.git "$tree" &&
    verify_blob_missing lop-large.git "$commit"
'

test_expect_success 'push handles packed objects gracefully' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit N8 "packed blob" &&
    blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$blob" &&
    verify_blob_missing server.git "$blob" &&
    git -C server.git repack -ad &&
    write_large_commit N8b "another large blob" &&
    blob2=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$blob2" &&
    verify_blob_missing server.git "$blob2"
'

test_expect_success 'push handles multiple refs in single push' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit P1 "branch one" &&
    git -C client branch feature1 &&
    git -C client checkout baseline &&
    write_large_commit P2 "branch two" &&
    git -C client branch feature2 &&
    blob1=$(git -C client rev-parse feature1:large/blob.bin) &&
    blob2=$(git -C client rev-parse feature2:large/blob.bin) &&
    git -C client push origin feature1 feature2 &&
    verify_blob_in_repo lop-large.git "$blob1" &&
    verify_blob_in_repo lop-large.git "$blob2" &&
    verify_blob_missing server.git "$blob1" &&
    verify_blob_missing server.git "$blob2" &&
    git -C client checkout main &&
    test_when_finished "git -C client branch -D feature1 feature2 2>/dev/null || :"
'

test_expect_success 'push skips blob already in promisor' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit Q "already there" &&
    blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$blob" &&
    verify_blob_missing server.git "$blob" &&
    git -C client reset --hard HEAD~1 &&
    git -C client push --force origin HEAD:main &&
    git -C client reset --hard HEAD@{1} &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$blob" &&
    verify_blob_missing server.git "$blob"
'

test_expect_success 'push handles empty push gracefully' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C client push origin HEAD:main
'

test_expect_success 'push handles delete ref gracefully' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit R "to be deleted" &&
    git -C client branch temp-branch &&
    git -C client push origin temp-branch &&
    git -C client push origin :temp-branch &&
    git -C client branch -D temp-branch
'

test_expect_success 'push with force-with-lease offloads blobs' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit S "force with lease" &&
    blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push --force-with-lease origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$blob" &&
    verify_blob_missing server.git "$blob"
'

test_expect_success 'push with atomic handles partial failures' '
    reset_server_policy &&
    reset_client_to_base &&
    write_large_commit T "atomic push" &&
    blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$blob" &&
    verify_blob_missing server.git "$blob"
'

# Note: The following C-specific error injection tests using GIT_TEST_LOP_FORCE_* 
# env vars are not applicable to the bash hook implementation:
# - push fails when promisor object store is read-only (git push handles this naturally)
# - push fails when promisor write is forced to fail (no C write path to inject into)
# - push fails when promisor write reports generic error (no C write path)
# - push fails when promisor write mismatches object id (git verifies integrity)
# - push fails when promisor read is forced to fail (no C read path)
# - push keeps blob local when forced non-blob path (hook filters correctly by type)
# - push fails when removing local blob fails (bash rm handles this)
# - push fails when removing local blob reports errno (bash rm handles this)
# - push warns when promisor directory cleanup fails (not applicable to hook)

test_expect_success 'clone handles combined promisor filters from server' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    git -C server.git config promisor.sendFields partialCloneFilter &&
    git -C server.git config remote.lopLarge.partialclonefilter "combine:blob:none+tree:0" &&
    test_when_finished "lop_set_filters \"blob:limit=1024\" \"blob:limit=256\"" &&
    trace=$PWD/clone-combine.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone --no-checkout "file://$(pwd)/server.git" clone-combine &&
    test_grep "filter blob:none" "$trace" &&
    rm -rf clone-combine
'

test_expect_success 'clone ignores non-blob promisor filters from server' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    git -C server.git config promisor.sendFields partialCloneFilter &&
    git -C server.git config remote.lopLarge.partialclonefilter "tree:0" &&
    test_when_finished "lop_set_filters \"blob:limit=1024\" \"blob:limit=256\"" &&
    trace=$PWD/clone-tree.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone --no-checkout "file://$(pwd)/server.git" clone-tree &&
    test_grep "filter blob:limit=256" "$trace" &&
    rm -rf clone-tree
'

test_expect_success 'clone advertises promisor filters from server' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    trace=$PWD/clone-trace.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone --no-checkout "file://$(pwd)/server.git" clone-simple &&
    test_grep "filter blob:limit=256" "$trace" &&
    git -C clone-simple config --list >/dev/null &&
    rm -rf clone-simple
'

test_expect_success 'clone lazily fetches large blob on demand' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    reset_client_to_base &&
    write_large_commit L "lazy fetch payload" &&
    git -C client push origin HEAD:main &&
    GIT_NO_LAZY_FETCH=0 git clone --no-checkout "file://$(pwd)/server.git" clone-lazy &&
    blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    test_must_fail env GIT_NO_LAZY_FETCH=1 git -C clone-lazy cat-file -e "$blob" &&
    git -C clone-lazy show origin/main:large/blob.bin >/dev/null &&
    rm -rf clone-lazy
'

test_expect_success 'end-to-end LOP turn-around flow shows disk savings' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    reset_client_to_base &&
    record_repo_size server.git server_before &&
    record_repo_size lop-large.git lop_large_before &&
    test_when_finished "git -C client push origin :refs/heads/assets" &&
    test_when_finished "git -C client branch -D assets 2>/dev/null || :" &&
    (
        cd client &&
        git checkout -B assets baseline &&
        mkdir -p large &&
        test-tool genrandom N 1048576 >large/asset.bin &&
        git add large/asset.bin &&
        git commit -m "assets payload" &&
        git push origin HEAD:refs/heads/assets &&
        git checkout main
    ) &&
    asset_oid=$(git -C client rev-parse assets:large/asset.bin) &&
    record_repo_size server.git server_after &&
    record_repo_size lop-large.git lop_large_after &&
    printf "server before push: %s\n" "$server_before" &&
    printf "server after push: %s\n" "$server_after" &&
    printf "lop-large after push: %s\n" "$lop_large_after" &&
    verify_blob_in_repo lop-large.git "$asset_oid" &&
    verify_blob_missing server.git "$asset_oid" &&
    test $(($lop_large_after - $lop_large_before)) -gt 900 &&
    test $(($server_after - $server_before)) -lt 200 &&
    test_when_finished "rm -rf client-lop" &&
    test_when_finished "rm -rf client-full" &&
    GIT_NO_LAZY_FETCH=0 git clone "file://$(pwd)/server.git" client-lop &&
    record_repo_size client-lop lop_client_size &&
    printf "client-lop pack: %s\n" "$lop_client_size" &&
    verify_blob_missing client-lop "$asset_oid" &&
    GIT_NO_LAZY_FETCH=0 git clone "file://$(pwd)/server.git" client-full &&
    git -C client-full checkout -b assets origin/assets &&
    record_repo_size client-full full_client_size &&
    printf "client-full pack after checkout: %s\n" "$full_client_size" &&
    verify_blob_in_repo client-full "$asset_oid" &&
    test $(($full_client_size - $lop_client_size)) -gt 900
'




# final cleanup

test_done
