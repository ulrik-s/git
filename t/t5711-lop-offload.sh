#!/bin/sh

test_description='LOP push offload routes blobs via promisor filters'

. ./test-lib.sh

if test -n "$GIT_TEST_LOP_COVERAGE"
then
    . "$TEST_DIRECTORY"/lib-lop-gcov.sh
    lop_gcov_prepare
fi

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

    git -C server.git config promisor.advertise true || return 1
    git -C server.git config promisor.sendFields partialCloneFilter || return 1
    git -C server.git config remote.lopLarge.promisor true || return 1
    git -C server.git config remote.lopSmall.promisor true || return 1
    git -C server.git config receive.lop.enable true || return 1
    lop_set_filters "blob:limit=1024" "blob:limit=256" || return 1
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

    (
        cd client &&
        mkdir -p large &&
        test-tool genrandom "$char" 2048 >large/blob.bin &&
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
    git -C "$1" count-objects -v | sed -n 's/^size-pack: //p'
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
    trace=$PWD/trace-large.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$large_oid" &&
    verify_blob_missing lop-small.git "$large_oid" &&
    verify_blob_missing server.git "$large_oid" &&
    trace_has_remote "$trace" lopLarge &&
    trace_has_stat "$trace" blob-count 1
'

test_expect_success 'push keeps small blob local' '
    reset_server_policy &&
    reset_client_to_base &&
    write_small_commit &&
    small_oid=$(git -C client rev-parse HEAD:small/blob.bin) &&
    trace=$PWD/trace-small-local.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$small_oid" &&
    verify_blob_missing lop-large.git "$small_oid" &&
    verify_blob_missing lop-small.git "$small_oid" &&
    trace_lacks_offload "$trace"
'

test_expect_success 'push routes medium blob to lopSmall' '
    reset_server_policy &&
    reset_client_to_base &&
    write_medium_commit &&
    medium_oid=$(git -C client rev-parse HEAD:medium/blob.bin) &&
    trace=$PWD/trace-medium.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$medium_oid" &&
    verify_blob_missing server.git "$medium_oid" &&
    verify_blob_missing lop-large.git "$medium_oid" &&
    trace_has_remote "$trace" lopSmall
'

test_expect_success 'push offloads all blobs when filter blob:none' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "blob:none" "blob:limit=256" &&
    write_small_commit D "blob none payload" &&
    oid=$(git -C client rev-parse HEAD:small/blob.bin) &&
    trace=$PWD/trace-blob-none.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing server.git "$oid" &&
    trace_has_remote "$trace" lopLarge &&
    trace_has_match "$trace" lopLarge
'

test_expect_success 'push honors combine filter with blob:none' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "combine:blob:none+tree:0" "blob:limit=256" &&
    write_medium_commit E "combine filter" &&
    oid=$(git -C client rev-parse HEAD:medium/blob.bin) &&
    trace=$PWD/trace-combine.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing server.git "$oid" &&
    trace_has_remote "$trace" lopLarge
'

test_expect_success 'push skips promisor with unsupported filter' '
    reset_server_policy &&
    reset_client_to_base &&
    lop_set_filters "tree:1" "tree:1" &&
    write_large_commit F "unsupported filter" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    trace=$PWD/trace-unsupported.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    verify_blob_missing lop-large.git "$oid" &&
    verify_blob_missing lop-small.git "$oid" &&
    trace_lacks_offload "$trace"
'

test_expect_success 'push disabled policy keeps blob local' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config receive.lop.enable false &&
    write_large_commit G "policy disabled" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    trace=$PWD/trace-disabled.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    verify_blob_missing lop-large.git "$oid" &&
    trace_lacks_offload "$trace"
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
    trace=$PWD/trace-order.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing lop-small.git "$oid" &&
    trace_has_remote "$trace" lopLarge &&
    lop_set_filters "blob:limit=1024" "blob:limit=256"
'

test_expect_success 'push uses small promisor when large disabled' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config --replace-all remote.lopLarge.promisor false &&
    write_medium_commit J "small only" &&
    oid=$(git -C client rev-parse HEAD:medium/blob.bin) &&
    trace=$PWD/trace-small-only.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$oid" &&
    verify_blob_missing server.git "$oid" &&
    trace_has_remote "$trace" lopSmall &&
    git -C server.git config --replace-all remote.lopLarge.promisor true
'

test_expect_success 'push keeps blob when no promisor configured' '
    reset_server_policy &&
    reset_client_to_base &&
    git -C server.git config --replace-all remote.lopLarge.promisor false &&
    git -C server.git config --replace-all remote.lopSmall.promisor false &&
    write_large_commit K "no promisors" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    trace=$PWD/trace-no-promisors.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    trace_lacks_offload "$trace" &&
    git -C server.git config --replace-all remote.lopLarge.promisor true &&
    git -C server.git config --replace-all remote.lopSmall.promisor true
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

test_expect_success 'partial clone saves disk compared to full clone' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    reset_client_to_base &&
    write_blob_commit big/binary.bin 1048576 M "disk demo" &&
    git init --bare server-full.git &&
    test_when_finished "rm -rf server-full.git" &&
    git -C client push origin HEAD:main &&
    git -C client push "file://$(pwd)/server-full.git" HEAD:main &&
    GIT_NO_LAZY_FETCH=0 git clone --no-checkout "file://$(pwd)/server.git" clone-lop &&
    git clone --no-checkout "file://$(pwd)/server-full.git" clone-full &&
    lop_pack=$(pack_size_kib clone-lop) &&
    full_pack=$(pack_size_kib clone-full) &&
    test -n "$lop_pack" && test -n "$full_pack" &&
    test "$(expr "$lop_pack" + 0)" -lt "$(expr "$full_pack" + 0)" &&
    rm -rf clone-lop clone-full
'

test_expect_success LOP_GCOV 'coverage: promisor filter helpers executed' '
    lop_assert_gcov_functions builtin/clone.c \
        extract_promisor_filter
'

test_expect_success LOP_GCOV 'coverage: lop receive-pack pipeline exercised' '
    lop_assert_gcov_functions builtin/receive-pack.c \
        lop_policy_init \
        lop_policy_ensure_init \
        lop_policy_reload_routes \
        lop_route_rule_apply_filter \
        lop_route_matches \
        lop_match_blob \
        lop_remove_local_blob \
        lop_stats_get \
        lop_stats_clear \
        lop_record_blob \
        lop_offload_blob_cb \
        lop_for_each_new_blob \
        lop_process_push
'

# final cleanup

test_done
