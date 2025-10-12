#!/bin/sh

test_description='simple ODB experiment via alternates'

. ./test-lib.sh

TEST_PASSES_SANITIZE_LEAK=true

simple_path=$PWD/simple-odb-store

clean_simple () {
        rm -rf "$simple_path"
}

test_when_finished 'clean_simple'

test_expect_success 'blob written to simple ODB is accessible via alternates' '
        test_create_repo main &&
        (
                cd main &&
                test-tool simple-odb init "$simple_path" &&
                echo "hello from simple" >payload &&
                blob=$(test-tool simple-odb write "$simple_path" blob payload) &&
                test-tool simple-odb add-alternate "$simple_path" &&
                git cat-file -p "$blob" >actual &&
                test_cmp payload actual
        )
'

test_expect_success 'stdin writes work for alternate ODB' '
        test_create_repo stdin-repo &&
        other_store=$PWD/simple-stdin &&
        test_when_finished "rm -rf stdin-repo \"$other_store\"" &&
        (
                cd stdin-repo &&
                test-tool simple-odb init "$other_store" &&
                printf "data via stdin" | test-tool simple-odb write "$other_store" blob - >oid &&
                test-tool simple-odb add-alternate "$other_store" &&
                oid=$(cat oid) &&
                git cat-file -p "$oid" >out &&
                printf "data via stdin" >expect &&
                test_cmp expect out
        )
'

test_done
