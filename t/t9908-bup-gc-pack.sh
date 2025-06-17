#!/bin/sh

# Test that gc packs chunked blobs and preserves data

test_description='chunked blobs survive aggressive gc'

. ./test-lib.sh

TEST_REPO=gc-pack-test

test_expect_success 'setup repository with 10 revisions' '
    test_create_repo "$TEST_REPO" &&
    (
        cd "$TEST_REPO" &&
        git config bup.chunking true &&
        test-tool genrandom seed 100000 >file &&
        git add file &&
        git commit -m rev0 &&
        cp file ../file0 &&
        git rev-parse HEAD >../rev0 &&
        for i in $(test_seq 1 9)
        do
            off=$(perl -e "srand($i); print int(rand(100000-10));") &&
            test-tool genrandom seed$i 10 | dd of=file bs=1 seek=$off count=10 conv=notrunc 2>/dev/null &&
            git add file &&
            git commit -m rev$i || return 1 &&
            cp file ../file$i &&
            git rev-parse HEAD >../rev$i || return 1
        done
    )
'

test_expect_success 'verify revisions before gc' '
    (
        cd "$TEST_REPO" &&
        for i in $(test_seq 0 9)
        do
            rev=$(cat ../rev$i) &&
            git archive --format=tar "$rev" file | tar xO >actual &&
            test_cmp ../file$i actual || return 1
        done
    )
'

test_expect_success 'expire reflog and run gc' '
    (
        cd "$TEST_REPO" &&
        git reflog expire --expire=now --all &&
        git gc --aggressive --prune=now
    )
'

test_expect_success 'all loose objects packed' '
    (
        cd "$TEST_REPO" &&
        git count-objects -v >../count &&
        grep "^count: 0$" ../count &&
        ls .git/objects/pack/pack-*.pack >/dev/null
    )
'

test_expect_success 'verify revisions after gc' '
    (
        cd "$TEST_REPO" &&
        for i in $(test_seq 0 9)
        do
            rev=$(cat ../rev$i) &&
            git archive --format=tar "$rev" file | tar xO >actual &&
            test_cmp ../file$i actual || return 1
        done
    )
'

test_done
