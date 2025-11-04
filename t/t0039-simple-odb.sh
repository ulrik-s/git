#!/bin/sh

TEST_NO_CREATE_REPO=1

test_description='exercise the native simple ODB helper'

. ./test-lib.sh

ODB_FILE=simple.odb

test_when_finished "rm -f "$ODB_FILE""

test_expect_success 'initialize simple object database' '
test-tool simple-odb init "$ODB_FILE"
'

write_blob () {
printf %s "$1" | test-tool simple-odb write "$ODB_FILE" blob
}

test_expect_success 'write and list blob entry' '
echo foo >expect &&
test_when_finished "rm -f expect expect_oid list" &&
oid=$(write_blob foo) &&
test-tool simple-odb list "$ODB_FILE" >list &&
echo "$oid" >expect_oid &&
test_cmp expect_oid list
'

test_expect_success 'read blob content back' '
test_when_finished "rm -f out expect_type actual_type expect_payload" &&
printf foo >expect_payload &&
type=$(test-tool simple-odb read "$ODB_FILE" "$oid" out) &&
echo blob >expect_type &&
echo "$type" >actual_type &&
test_cmp expect_type actual_type &&
test_cmp expect_payload out
'

# write a second object to ensure we append correctly

test_expect_success 'append another blob' '
echo bar >expect2 &&
test_when_finished "rm -f expect2 expect_list list" &&
oid2=$(write_blob bar) &&
test-tool simple-odb list "$ODB_FILE" >list &&
printf "%s\n%s\n" "$oid" "$oid2" >expect_list &&
test_cmp expect_list list
'

test_done
