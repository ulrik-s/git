#!/bin/sh

# Demonstrate disk usage with bup chunking during small edits

test_description='bup chunk storage savings'

. ./test-lib.sh

TEST_REPO=savings-test

# Initialize repository with chunking and initial 100k file

test_expect_success 'setup repository with 100k file' '
    test_create_repo "$TEST_REPO" &&
    (
        cd "$TEST_REPO" &&
        git config bup.chunking true &&
        test-tool genrandom seed 100000 >file &&
        git add file &&
        git commit -m initial
    )
'

# Perform 100 random 10-byte edits and record stats

test_expect_success 'record chunk reuse over 100 edits' '
    (
        cd "$TEST_REPO" &&
        git config bup.chunking true &&
        : >../stats &&
        : >../seen &&
        for i in $(test_seq 1 100)
        do
            off=$(perl -e "srand($i); print int(rand(100000-10));") &&
            test-tool genrandom seed$i 10 | dd of=file bs=1 seek=$off count=10 conv=notrunc 2>/dev/null &&
            git add file &&
            git commit -m "edit $i" &&
            oid=$(git rev-parse HEAD:file) &&
            path=$(test_oid_to_path $oid) &&
            test-tool zlib inflate <.git/objects/$path | tail -n +3 >../chunks &&
            uniq=0 reuse=0 &&
            while read c
            do
                if grep -q "^$c$" ../seen
                then
                    reuse=$((reuse+1))
                else
                    uniq=$((uniq+1)) && echo "$c" >>../seen || return 1
                fi
            done <../chunks || return 1 &&
            size=$(du -sk .git/objects | cut -f1) &&
            printf "%d %d %d %d\n" "$i" "$uniq" "$reuse" "$size" >>../stats || return 1
        done
    )
'

# Show final statistics

test_expect_success 'show stats' '
    cat stats
'


test_done
