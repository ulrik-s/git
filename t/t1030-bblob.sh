#!/bin/sh

test_description='bblob storage and reading'

. ./test-lib.sh

cat_bigfile() {
	perl -e 'print "a" x 20000' >bigfile
}

test_expect_success 'create big blob written as bblob' '
       cat_bigfile &&
       oid=$(git hash-object -t bblob -w bigfile) &&
       test "$(git cat-file -t "$oid")" = bblob
'

test_expect_success 'explicit bblob type works' '
       echo small >small &&
       soid=$(git hash-object -t bblob -w small) &&
       test "$(git cat-file -t "$soid")" = bblob &&
       git cat-file -p "$soid" >actual &&
       test_cmp small actual
'

test_expect_success 'reading bblob yields original data' '
	git cat-file -p "$oid" >actual &&
	test_cmp bigfile actual
'

test_expect_success 'size helper matches original' '
	test "$(git cat-file -s "$oid")" = "$(wc -c <bigfile)"
'

test_expect_success 'server advertises bblob capability' '
	GIT_TRACE_PACKET="$PWD/trace" git -c protocol.version=2 \
	    ls-remote . >/dev/null &&
	grep "bblob" trace
'

test_expect_success 'fsck verifies bblob objects' '
       git fsck --full-bblob-verify >out &&
       ! grep "error" out || true
'

test_done
