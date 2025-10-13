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

test_expect_success 'lop-write dispatches by blob size and keeps large blobs in LOP' '
        test_create_repo lop-main &&
        lop_store=$PWD/lop-store &&
        test_when_finished "rm -rf lop-main \"$lop_store\"" &&
        (
                cd lop-main &&
                test-tool simple-odb init "$lop_store" &&
                echo "tiny" >small &&
                small=$(test-tool simple-odb lop-write "$lop_store" 8 blob small) &&
                test_path_is_file ".git/objects/$(test_oid_to_path $small)" &&
                test_path_is_missing "$lop_store/objects/$(test_oid_to_path $small)" &&
                cat >large <<-EOF &&
                contents stored in lop
EOF
                large=$(test-tool simple-odb lop-write "$lop_store" 8 blob large) &&
                test_path_is_missing ".git/objects/$(test_oid_to_path $large)" &&
                test_path_is_file "$lop_store/objects/$(test_oid_to_path $large)" &&
                git cat-file -p "$large" >out &&
                cat >expect <<-EOF &&
                contents stored in lop
EOF
                test_cmp expect out
        )
'

test_expect_success 'porcelain commit stores large blob in simple ODB alternate' '
        test_create_repo lop-porcelain &&
        lop_store=$PWD/lop-porcelain-store &&
        test_when_finished "rm -rf lop-porcelain \"$lop_store\"" &&
        (
                cd lop-porcelain &&
                test-tool simple-odb init "$lop_store" &&
                perl -e "binmode STDOUT; print pack(q(C*), map { \$_ % 256 } 0 .. 2047)" >binary.bin &&
                blob=$(test-tool simple-odb lop-write "$lop_store" 512 blob binary.bin) &&
                git add binary.bin &&
                git commit -m "commit binary via lop" &&
                git show HEAD:binary.bin >out &&
                test_cmp binary.bin out &&
                test_path_is_missing ".git/objects/$(test_oid_to_path $blob)" &&
                test_path_is_file "$lop_store/objects/$(test_oid_to_path $blob)"
        )
'

test_expect_success 'porcelain push keeps large blob in shared simple ODB store' '
        test_create_repo lop-sender &&
        lop_store=$PWD/lop-shared-store &&
        test_when_finished "rm -rf lop-sender lop-clone lop-remote.git \"$lop_store\"" &&
        (
                cd lop-sender &&
                test-tool simple-odb init "$lop_store" &&
                perl -e "binmode STDOUT; print pack(q(C*), map { \$_ % 256 } 0 .. 4095)" >huge.bin &&
                blob=$(test-tool simple-odb lop-write "$lop_store" 1024 blob huge.bin) &&
                git add huge.bin &&
                git commit -m "stage binary for push" &&
                git init --bare ../lop-remote.git &&
                git -C ../lop-remote.git config receive.unpackLimit 1 &&
                mkdir -p ../lop-remote.git/objects/info &&
                echo "$lop_store/objects" >../lop-remote.git/objects/info/alternates &&
                git remote add origin ../lop-remote.git &&
                git push origin HEAD:main &&
                grep -F "$lop_store/objects" ../lop-remote.git/objects/info/alternates &&
                git --git-dir=../lop-remote.git symbolic-ref HEAD refs/heads/main &&
                git --git-dir=../lop-remote.git show main:huge.bin >../received.bin &&
                test_cmp huge.bin ../received.bin &&
                test_path_is_file "$lop_store/objects/$(test_oid_to_path $blob)" &&
                git clone ../lop-remote.git ../lop-clone &&
                (
                        cd ../lop-clone &&
                        mkdir -p .git/objects/info &&
                        echo "$lop_store/objects" >.git/objects/info/alternates &&
                        git show HEAD:huge.bin >../clone.bin
                ) &&
                test_cmp huge.bin ../clone.bin
        )
'

test_done
