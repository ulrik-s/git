#!/bin/sh

test_description='LOP push offload routes large blobs to promisor repositories'

. ./test-lib.sh

if test -n "$GIT_TEST_LOP_COVERAGE"
then
    . "$TEST_DIRECTORY"/lib-lop-gcov.sh
    lop_gcov_prepare
fi

TEST_PASSES_SANITIZE_LEAK=true

setup_lop_repos () {
    git init --bare server.git || return 1
    git init --bare lop-large.git || return 1
    git init --bare lop-small.git || return 1

    git -C server.git remote add lopLarge "file://$(pwd)/lop-large.git" || return 1
    git -C server.git remote add lopSmall "file://$(pwd)/lop-small.git" || return 1

    git -C server.git config uploadpack.allowFilter true || return 1
    git -C server.git config uploadpack.allowAnySHA1InWant true || return 1
    git -C lop-large.git config uploadpack.allowFilter true || return 1
    git -C lop-large.git config uploadpack.allowAnySHA1InWant true || return 1
    git -C lop-small.git config uploadpack.allowFilter true || return 1
    git -C lop-small.git config uploadpack.allowAnySHA1InWant true || return 1

    git -C server.git config promisor.advertise true || return 1
    git -C server.git config promisor.sendFields partialCloneFilter || return 1
    git -C server.git config remote.lopLarge.promisor true || return 1
    git -C server.git config remote.lopSmall.promisor true || return 1
    git -C server.git config remote.lopLarge.partialclonefilter blob:none || return 1
    git -C server.git config remote.lopSmall.partialclonefilter blob:none || return 1

    git -C server.git config receive.lop.enable true || return 1
    git -C server.git config receive.lop.sizeAbove 1024 || return 1
    git -C server.git config receive.lop.path large/** || return 1
    git -C server.git config --add receive.lop.path media/** || return 1
    git -C server.git config lop.route.large.remote lopLarge || return 1
    git -C server.git config lop.route.large.sizeAbove 1024 || return 1
    git -C server.git config lop.route.large.include large/** || return 1
    git -C server.git config lop.route.small.remote lopSmall || return 1
    git -C server.git config lop.route.small.include media/** || return 1
}

reset_server_policy () {
    git -C server.git config receive.lop.enable true &&
    git -C server.git config receive.lop.sizeAbove 1024 &&
    git -C server.git config --replace-all receive.lop.path large/** &&
    git -C server.git config --add receive.lop.path media/** &&
    git -C server.git config --unset-all lop.route.small.sizeAbove || true &&
    git -C server.git config --replace-all lop.route.large.remote lopLarge &&
    git -C server.git config --replace-all lop.route.large.sizeAbove 1024 &&
    git -C server.git config --replace-all lop.route.large.include large/** &&
    git -C server.git config --replace-all lop.route.small.remote lopSmall &&
    git -C server.git config --replace-all lop.route.small.include media/**
}

reset_promisor_advertisement () {
    git -C server.git config promisor.advertise true &&
    git -C server.git config promisor.sendFields partialCloneFilter &&
    git -C server.git config --replace-all remote.lopLarge.promisor true &&
    git -C server.git config --replace-all remote.lopSmall.promisor true &&
    git -C server.git config --replace-all remote.lopLarge.partialclonefilter blob:none &&
    git -C server.git config --replace-all remote.lopSmall.partialclonefilter blob:none &&
    git -C server.git config --replace-all remote.lopLarge.url "file://$(pwd)/lop-large.git" &&
    git -C server.git config --replace-all remote.lopSmall.url "file://$(pwd)/lop-small.git"
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

write_media_commit () {
    char=${1:-B}
    msg=${2:-"media payload"}

    (
        cd client &&
        mkdir -p media &&
        test-tool genrandom "$char" 512 >media/clip.bin &&
        git add media/clip.bin &&
        git commit -m "$msg"
    )
}

write_mixed_commit () {
    large_char=${1:-D}
    small_char=${2:-S}
    msg=${3:-"mixed payload"}

    (
        cd client &&
        mkdir -p large small &&
        test-tool genrandom "$large_char" 2048 >large/mixed.bin &&
        test-tool genrandom "$small_char" 128 >small/keep.txt &&
        git add large/mixed.bin small/keep.txt &&
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
        git remote add origin ../server.git
    ) &&
    test_config_global promisor.acceptFromServer all &&
    reset_server_policy &&
    reset_promisor_advertisement
'

test_expect_success 'push offloads large blob to lopLarge' '
    reset_server_policy &&
    write_large_commit &&
    large_oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    trace=$PWD/trace-large.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$large_oid" &&
    verify_blob_missing lop-small.git "$large_oid" &&
    trace_has_remote "$trace" lopLarge &&
    trace_has_match "$trace" lopLarge &&
    trace_has_stat "$trace" blob-count 1
'

test_expect_success 'push routes media blob to lopSmall' '
    reset_server_policy &&
    write_media_commit &&
    small_oid=$(git -C client rev-parse HEAD:media/clip.bin) &&
    trace=$PWD/trace-small.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$small_oid" &&
    verify_blob_missing lop-large.git "$small_oid" &&
    trace_has_remote "$trace" lopSmall &&
    trace_has_match "$trace" lopSmall &&
    trace_has_stat "$trace" blob-count 1
'

test_expect_success 'push offloads only matching blobs' '
    reset_server_policy &&
    write_mixed_commit &&
    large_oid=$(git -C client rev-parse HEAD:large/mixed.bin) &&
    small_oid=$(git -C client rev-parse HEAD:small/keep.txt) &&
    trace=$PWD/trace-mixed.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$large_oid" &&
    verify_blob_missing server.git "$large_oid" &&
    verify_blob_missing lop-small.git "$large_oid" &&
    verify_blob_in_repo server.git "$small_oid" &&
    verify_blob_missing lop-large.git "$small_oid" &&
    verify_blob_missing lop-small.git "$small_oid" &&
    trace_has_remote "$trace" lopLarge &&
    trace_has_match "$trace" lopLarge
'

test_expect_success 'push offloads with size threshold but no path rules' '
    reset_server_policy &&
    git -C server.git config --unset-all receive.lop.path &&
    git -C server.git config --unset-all lop.route.large.include &&
    write_blob_commit sizeonly/payload.bin 3072 E "size threshold only" &&
    oid=$(git -C client rev-parse HEAD:sizeonly/payload.bin) &&
    trace=$PWD/trace-sizeonly.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing server.git "$oid" &&
    trace_has_remote "$trace" lopLarge
'

test_expect_success 'push keeps blobs below size threshold locally' '
    reset_server_policy &&
    git -C server.git config receive.lop.sizeAbove 4096 &&
    write_blob_commit small/keep.bin 2048 F "should stay local" &&
    oid=$(git -C client rev-parse HEAD:small/keep.bin) &&
    trace=$PWD/trace-below-size.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    verify_blob_missing lop-large.git "$oid" &&
    trace_lacks_offload "$trace"
'

test_expect_success 'push offloads path-matched blob despite large size cutoff' '
    reset_server_policy &&
    git -C server.git config receive.lop.sizeAbove 8192 &&
    write_media_commit G "path override payload" &&
    oid=$(git -C client rev-parse HEAD:media/clip.bin) &&
    trace=$PWD/trace-path-override.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$oid" &&
    trace_has_remote "$trace" lopSmall
'

test_expect_success 'push route sizeAbove still offloads when blob exceeds threshold' '
    reset_server_policy &&
    git -C server.git config lop.route.small.sizeAbove 256 &&
    write_media_commit H "route gated" &&
    oid=$(git -C client rev-parse HEAD:media/clip.bin) &&
    trace=$PWD/trace-route-gated.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$oid" &&
    trace_has_remote "$trace" lopSmall
'

test_expect_success 'push route without remote keeps blob local' '
    reset_server_policy &&
    git -C server.git config --unset-all lop.route.large.remote &&
    write_large_commit I "no remote set" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    trace=$PWD/trace-no-remote.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    verify_blob_missing lop-large.git "$oid" &&
    trace_lacks_offload "$trace"
'

test_expect_success 'push disabled policy keeps blobs local' '
    reset_server_policy &&
    git -C server.git config receive.lop.enable false &&
    write_large_commit J "policy disabled" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    trace=$PWD/trace-disabled.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo server.git "$oid" &&
    trace_lacks_offload "$trace"
'

test_expect_success 'push fails when LOP remote missing' '
    reset_server_policy &&
    git -C server.git config lop.route.large.remote missingRemote &&
    write_large_commit K "missing remote" &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    test_must_fail git -C client push origin HEAD:main &&
    verify_blob_missing lop-large.git "$oid"
'

test_expect_success 'push fails when LOP remote URL is not local file' '
    reset_server_policy &&
    test_when_finished "git -C server.git config remote.lopLarge.url \"file://$(pwd)/lop-large.git\"" &&
    git -C server.git config remote.lopLarge.url https://example.invalid/lop-large.git &&
    write_large_commit L "bad url" &&
    test_must_fail git -C client push origin HEAD:main &&
    oid=$(git -C client rev-parse HEAD:large/blob.bin) &&
    verify_blob_missing lop-large.git "$oid"
'

test_expect_success 'end-to-end LOP reduces clone footprint' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    write_blob_commit large/huge.bin 1048576 Q "lop e2e payload" &&
    huge_oid=$(git -C client rev-parse HEAD:large/huge.bin) &&
    trace=$PWD/trace-e2e.json &&
    test_when_finished "cleanup_trace $trace" &&
    server_before=$(pack_size_kib server.git) &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    server_after=$(pack_size_kib server.git) &&
    server_growth=$((server_after - server_before)) &&
    test "$server_growth" -lt 64 &&
    verify_blob_in_repo lop-large.git "$huge_oid" &&
    verify_blob_missing server.git "$huge_oid" &&
    git clone "file://$(pwd)/server.git" clone-lop &&
    test_when_finished "rm -rf clone-lop" &&
    lop_clone_kib=$(pack_size_kib clone-lop) &&
    git init --bare server-nonlop.git &&
    test_when_finished "rm -rf server-nonlop.git" &&
    git -C server-nonlop.git config uploadpack.allowFilter true &&
    git -C server-nonlop.git config uploadpack.allowAnySHA1InWant true &&
    git -C client remote add nonlop ../server-nonlop.git &&
    test_when_finished "git -C client remote remove nonlop" &&
    git -C client push nonlop HEAD:main &&
    git clone "file://$(pwd)/server-nonlop.git" clone-full &&
    test_when_finished "rm -rf clone-full" &&
    full_clone_kib=$(pack_size_kib clone-full) &&
    test "$full_clone_kib" -gt "$lop_clone_kib"
'

test_expect_success 'push offloads nested large blob and prunes local copy' '
    reset_server_policy &&
    write_blob_commit large/nested/deep.bin 3072 M "nested blob" &&
    oid=$(git -C client rev-parse HEAD:large/nested/deep.bin) &&
    trace=$PWD/trace-nested.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    verify_blob_missing server.git "$oid" &&
    trace_has_remote "$trace" lopLarge
'

test_expect_success 'push offloads multiple blobs and records totals' '
    reset_server_policy &&
    write_blob_commit large/multi-one.bin 4096 N "multi one" &&
    write_blob_commit large/multi-two.bin 4096 O "multi two" &&
    first=$(git -C client rev-parse HEAD:large/multi-one.bin) &&
    second=$(git -C client rev-parse HEAD:large/multi-two.bin) &&
    trace=$PWD/trace-multi.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$first" &&
    verify_blob_in_repo lop-large.git "$second" &&
    trace_has_remote "$trace" lopLarge &&
    trace_has_stat "$trace" blob-count 2
'



test_expect_success 'push offloads via policy path when size disabled' '
    reset_server_policy &&
    git -C server.git config receive.lop.sizeAbove 1048576 &&
    git -C server.git config --replace-all receive.lop.path pathonly/** &&
    git -C server.git config --unset-all lop.route.large.include &&
    write_blob_commit pathonly/item.bin 512 S "path only policy" &&
    oid=$(git -C client rev-parse HEAD:pathonly/item.bin) &&
    trace=$PWD/trace-path-only.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$oid" &&
    trace_has_remote "$trace" lopLarge
'

test_expect_success 'push route include handles comma-separated patterns' '
    reset_server_policy &&
    git -C server.git config lop.route.small.include "media/**,alt-media/**" &&
    write_blob_commit alt-media/video.bin 512 T "alt media pattern" &&
    oid=$(git -C client rev-parse HEAD:alt-media/video.bin) &&
    trace=$PWD/trace-alt-media.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$oid" &&
    trace_has_remote "$trace" lopSmall
'

test_expect_success 'push offloads nested media path via wildcard' '
    reset_server_policy &&
    write_blob_commit media/nested/clip.bin 512 U "nested media payload" &&
    oid=$(git -C client rev-parse HEAD:media/nested/clip.bin) &&
    trace=$PWD/trace-media-nested.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-small.git "$oid" &&
    trace_has_remote "$trace" lopSmall
'

test_expect_success 'push offloads blobs to multiple promisors' '
    reset_server_policy &&
    write_blob_commit large/multi-mixed.bin 4096 P "mixed blob" &&
    write_media_commit Q "mixed media" &&
    large_oid=$(git -C client rev-parse HEAD:large/multi-mixed.bin) &&
    small_oid=$(git -C client rev-parse HEAD:media/clip.bin) &&
    trace=$PWD/trace-multi-remote.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    verify_blob_in_repo lop-large.git "$large_oid" &&
    verify_blob_in_repo lop-small.git "$small_oid" &&
    trace_has_remote "$trace" lopLarge &&
    trace_has_remote "$trace" lopSmall
'

test_expect_success 're-pushing already offloaded commit emits no offload events' '
    reset_server_policy &&
    write_large_commit R "first push" &&
    first_trace=$PWD/trace-initial.json &&
    test_when_finished "cleanup_trace $first_trace" &&
    GIT_TRACE2_EVENT=$first_trace git -C client push origin HEAD:main &&
    trace=$PWD/trace-repush.json &&
    test_when_finished "cleanup_trace $trace" &&
    GIT_TRACE2_EVENT=$trace git -C client push origin HEAD:main &&
    trace_lacks_offload "$trace"
'

# Clone and fetch UX tests

test_expect_success 'partial clone gets promisor routing without client config' '
    reset_server_policy &&
    reset_promisor_advertisement &&
    clone_pkt=$PWD/clone-trace.pkt &&
    test_when_finished "rm -f $clone_pkt" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$clone_pkt \
    git clone "file://$(pwd)/server.git" clone-simple &&
    test_grep "packet:.*filter blob:none" "$clone_pkt" &&
    test_grep "packet:.*promisor-remote=.*partialCloneFilter=blob:none" "$clone_pkt" &&
    test_must_fail git -C clone-simple config --get remote.lopLarge.url &&
    test_must_fail git -C clone-simple config --get remote.lopSmall.url &&
    test_must_fail git -C clone-simple config --get remote.lopLarge.promisor &&
    test_must_fail git -C clone-simple config --get remote.lopSmall.promisor
'

test_expect_success 'on-demand blob fetch works after partial clone' '
    blob_oid=$(git -C server.git rev-parse main:large/blob.bin) &&
    test_must_fail env GIT_NO_LAZY_FETCH=1 git -C clone-simple cat-file -e "$blob_oid" &&
    fetch_trace=$PWD/on-demand-trace.json &&
    test_when_finished "rm -f $fetch_trace" &&
    test_when_finished "rm -f large-blob" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE2_EVENT=$fetch_trace \
        git -C clone-simple show origin/main:large/blob.bin >large-blob &&
    test_file_not_empty large-blob &&
    git -C clone-simple cat-file -e "$blob_oid"
'

test_expect_success 'subsequent fetch keeps blob filter without extra remotes' '
    reset_server_policy &&
    write_large_commit C "large payload follow-up" &&
    new_blob=$(git -C client rev-parse HEAD:large/blob.bin) &&
    git -C client push origin HEAD:main &&
    test_when_finished "rm -f fetch-trace.pkt" &&
    GIT_TRACE_PACKET=$PWD/fetch-trace.pkt git -C clone-simple fetch origin &&
    test_grep "packet:.*filter blob:none" fetch-trace.pkt &&
    test_must_fail git -C clone-simple config --get remote.lopLarge.url &&
    test_must_fail git -C clone-simple config --get remote.lopSmall.url &&
    test_must_fail git -C clone-simple config --get remote.lopLarge.promisor &&
    test_must_fail git -C clone-simple config --get remote.lopSmall.promisor &&
    test_must_fail env GIT_NO_LAZY_FETCH=1 git -C clone-simple cat-file -e "$new_blob"
'

test_expect_success 'clone without promisor advertisement fetches complete data' '
    reset_promisor_advertisement &&
    git -C server.git config promisor.advertise false &&
    trace=$PWD/clone-noadv.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone "file://$(pwd)/server.git" clone-noadv &&
    ! test_grep "promisor-remote" "$trace" &&
    blob=$(git -C server.git rev-parse main:large/blob.bin) &&
    git -C clone-noadv cat-file -e "$blob" &&
    rm -rf clone-noadv &&
    git -C server.git config promisor.advertise true
'

test_expect_success 'clone ignores inconsistent promisor filters' '
    reset_promisor_advertisement &&
    git -C server.git config remote.lopSmall.partialclonefilter blob:limit=1 &&
    trace=$PWD/clone-inconsistent.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone "file://$(pwd)/server.git" clone-inconsistent &&
    ! test_grep "filter blob:none" "$trace" &&
    blob=$(git -C server.git rev-parse main:large/blob.bin) &&
    git -C clone-inconsistent cat-file -e "$blob" &&
    rm -rf clone-inconsistent &&
    reset_promisor_advertisement
'

test_expect_success 'fetch after inconsistent filters still lacks automatic filter' '
    reset_promisor_advertisement &&
    git -C server.git config remote.lopSmall.partialclonefilter blob:limit=1 &&
    mkdir inconsistent-fetch &&
    git -C inconsistent-fetch init &&
    git -C inconsistent-fetch remote add origin "file://$(pwd)/server.git" &&
    trace=$PWD/fetch-inconsistent.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git -C inconsistent-fetch fetch origin &&
    ! test_grep "filter blob:none" "$trace" &&
    rm -rf inconsistent-fetch &&
    reset_promisor_advertisement
'



test_expect_success 'existing clone fetch sees inconsistent advertisement' '
    reset_promisor_advertisement &&
    git -C server.git config remote.lopSmall.partialclonefilter blob:limit=1 &&
    trace=$PWD/existing-fetch-inconsistent.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git -C clone-simple fetch origin &&
    ! test_grep "filter blob:none" "$trace" &&
    reset_promisor_advertisement
'

test_expect_success 'existing clone fetch recovers filter after advertisement restored' '
    reset_promisor_advertisement &&
    trace=$PWD/existing-fetch-restored.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git -C clone-simple fetch origin &&
    test_grep "promisor-remote=.*partialCloneFilter=blob:none" "$trace"
'

test_expect_success 'restoring consistent filters reapplies automatic filter' '
    reset_promisor_advertisement &&
    trace=$PWD/clone-restored.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone "file://$(pwd)/server.git" clone-restored &&
    test_grep "filter blob:none" "$trace" &&
    rm -rf clone-restored
'

test_expect_success 'lazy fetch works again after inconsistent handshake reset' '
    reset_promisor_advertisement &&
    git -C server.git config remote.lopSmall.partialclonefilter blob:limit=1 &&
    trace=$PWD/clone-temp.pkt &&
    test_when_finished "rm -f $trace" &&
    GIT_NO_LAZY_FETCH=0 GIT_TRACE_PACKET=$trace git clone "file://$(pwd)/server.git" clone-temp &&
    ! test_grep "filter blob:none" "$trace" &&
    rm -rf clone-temp &&
    reset_promisor_advertisement &&
    GIT_NO_LAZY_FETCH=0 git clone "file://$(pwd)/server.git" clone-restored-fetch &&
    blob=$(git -C server.git rev-parse main:large/blob.bin) &&
    test_must_fail env GIT_NO_LAZY_FETCH=1 git -C clone-restored-fetch cat-file -e "$blob" &&
    git -C clone-restored-fetch show origin/main:large/blob.bin >/dev/null &&
    rm -rf clone-restored-fetch
'

test_expect_success LOP_GCOV 'coverage: partial clone filter helpers executed' '
    lop_assert_gcov_functions builtin/clone.c \
        extract_promisor_filter
'

test_expect_success LOP_GCOV 'coverage: lop receive-pack pipeline exercised' '
    lop_assert_gcov_functions builtin/receive-pack.c \
        lop_policy_init \
        lop_policy_ensure_init \
        lop_policy_get_route \
        lop_route_rule_add_includes \
        lop_match_patterns \
        lop_route_matches \
        lop_policy_should_consider \
        lop_match_blob \
        lop_remove_local_blob \
        lop_stats_get \
        lop_stats_clear \
        lop_record_blob \
        lop_offload_blob_cb \
        lop_for_each_new_blob \
        lop_process_push
'

test_expect_success 'cleanup partial clone workspace' '
    rm -rf clone-simple
'

# final cleanup of traces that may linger

test_done
