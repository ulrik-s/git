#!/bin/sh

# Test repack and fsck with bup-style chunked blobs

test_description='repack and fsck understand bup chunk storage'

. ./test-lib.sh

TEST_REPO=chunk-repack

setup_repo() {
	test_create_repo "$TEST_REPO" &&
	(
		cd "$TEST_REPO" &&
		git config bup.chunking true &&
		test-tool genrandom seed 100000 >file &&
		git add file &&
		git commit -m initial &&
		for i in $(test_seq 1 10)
		do
		off=$(perl -e "srand($i); print int(rand(100000-10));") &&
		test-tool genrandom seed$i 10 | dd of=file bs=1 seek=$off count=10 conv=notrunc 2>/dev/null &&
		git add file &&
		git commit -m "update $i" || return 1
		done
	)
}

cleanup_repo() {
	rm -rf "$TEST_REPO"
}

# Set up repository

test_expect_success 'setup repository with chunked blob' '
       setup_repo
'

test_expect_success 'chunks exist before repack' '
       (
               cd "$TEST_REPO" &&
               oid=$(git rev-parse HEAD:file) &&
               git -c bup.chunking=false cat-file -p "$oid" | tail -n +3 >../chunks &&
               cat ../chunks &&
               git count-objects -v >../count && cat ../count &&
               while read c; do
                       git cat-file -p "$c" >/dev/null || return 1
               done <../chunks
       )
'

# Repack and verify chunks remain

test_expect_success 'repack keeps chunk objects' '
       (
               cd "$TEST_REPO" &&
               git repack -ad &&
               git fsck --no-progress >../fsck.out &&
               cat ../fsck.out &&
               oid=$(git rev-parse HEAD:file) &&
               git -c bup.chunking=false cat-file -p "$oid" | tail -n +3 >../chunks &&
               cat ../chunks &&
               while read c; do
                       git cat-file -p "$c" >/dev/null || return 1
               done <../chunks
       )
'

# Remove a chunk and expect fsck to fail

test_expect_success 'fsck reports missing chunk' '
	cleanup_repo &&
	setup_repo &&
	(
		cd "$TEST_REPO" &&
		oid=$(git rev-parse HEAD:file) &&
               git -c bup.chunking=false cat-file -p "$oid" | tail -n +3 >../chunks &&
		first=$(head -n1 ../chunks) &&
		path=$(test_oid_to_path $first) &&
		rm -f .git/objects/$path &&
		test_must_fail git -c bup.chunking=true fsck >../err &&
		grep "missing blob" ../err
	)
'


test_done
