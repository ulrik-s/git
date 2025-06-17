#!/bin/sh

# Test bup-style chunk storage efficiency

test_description='bup chunking reduces repo size over repeated small changes'

. ./test-lib.sh

TEST_REPO=chunk-test

# Setup repository and initial commit

test_expect_success 'setup repository with initial 100k file' '
	test_create_repo "$TEST_REPO" &&
	(
	cd "$TEST_REPO" &&
	export GIT_BUP_CHUNKING=1 &&
	test-tool genrandom seed 100000 >file &&
	git add file &&
	git commit -m initial
	)
'

# Modify random 10-byte blocks and commit repeatedly

test_expect_success 'random 10-byte modifications committed 100 times' '
	(
	cd "$TEST_REPO" &&
	export GIT_BUP_CHUNKING=1 &&
	: >../stats &&
	: >../seen &&
	for i in $(test_seq 1 100)
	do
	off=$(perl -e "srand($i); print int(rand(100000-10));") &&
	test-tool genrandom seed$i 10 | dd of=file bs=1 seek=$off count=10 conv=notrunc &&
	git add file &&
	git commit -m "update $i" &&
	oid=$(git rev-parse HEAD:file) &&
	GIT_BUP_CHUNKING= git cat-file -p "$oid" >../chunks &&
	uniq=0 && reuse=0 &&
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
	echo "$i $uniq $reuse $size" >>../stats || return 1
	done || return 1
	)
'

# Display stats

test_expect_success 'display repository statistics' '
	cat stats
	'


test_done
