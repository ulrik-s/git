#!/bin/sh

test_description='blob tree object type'

. ./test-lib.sh

test_expect_success 'add creates blob-tree' '
 echo "hello world" >file &&
 git add file &&
 oid=$(git ls-files -s file | cut -d" " -f2) &&
 test "$(git cat-file -t $oid)" = "blob-tree" &&
 git cat-file -p $oid >chunks &&
 test -s chunks &&
 while read ch; do
  test "$(git cat-file -t $ch)" = "blob" || return 1
 done <chunks
'

test_done
