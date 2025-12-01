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

test_expect_success 'partial clone fetches large blob from LOP remote via alternates' '
        test_create_repo lop-producer &&
        lop_store=$PWD/lop-promisor-store &&
        server=$PWD/lop-server.git &&
        lop_remote=$PWD/lop-promisor.git &&
        client=$PWD/lop-client &&
        blob_oid_file=$PWD/lop-blob.oid &&
        test_when_finished "rm -rf lop-producer" &&
        test_when_finished "rm -rf \"$client\"" &&
        test_when_finished "rm -rf \"$lop_store\" \"$server\" \"$lop_remote\"" &&
        test_when_finished "rm -f client.bin \"$blob_oid_file\"" &&
        test-tool simple-odb init "$lop_store" &&
        (
                cd lop-producer &&
                perl -e "binmode STDOUT; print pack(q(C*), map { \$_ % 251 } 0 .. 7000)" >huge.bin &&
                blob=$(test-tool simple-odb lop-write "$lop_store" 4096 blob huge.bin) &&
                git add huge.bin &&
                git commit -m "commit huge blob via lop" &&
                echo "$blob" >"$blob_oid_file"
        ) &&
        blob_oid=$(cat "$blob_oid_file") &&
        git init --bare "$server" &&
        mkdir -p "$server/objects/info" &&
        echo "$lop_store/objects" >"$server/objects/info/alternates" &&
        git -C "$server" config uploadpack.allowFilter true &&
        git -C "$server" config uploadpack.allowAnySHA1InWant true &&
        git -C "$server" config promisor.advertise true &&
        (
                cd lop-producer &&
                git remote add origin "$server" &&
                git push origin HEAD:main
        ) &&
        git -C "$server" symbolic-ref HEAD refs/heads/main &&
        test_path_is_missing "$server/objects/$(test_oid_to_path $blob_oid)" &&
        git init --bare "$lop_remote" &&
        mkdir -p "$lop_remote/objects/info" &&
        echo "$lop_store/objects" >"$lop_remote/objects/info/alternates" &&
        git -C "$lop_remote" config uploadpack.allowFilter true &&
        git -C "$lop_remote" config uploadpack.allowAnySHA1InWant true &&
        git -C "$server" remote add lop "file://$lop_remote" &&
        git -C "$server" config remote.lop.promisor true &&
        git -C "$server" config remote.lop.fetch "+refs/heads/*:refs/remotes/lop/*" &&
        git -C "$server" config remote.lop.url "file://$lop_remote" &&
        GIT_NO_LAZY_FETCH=0 git clone -c remote.lop.promisor=true \
                -c remote.lop.fetch="+refs/heads/*:refs/remotes/lop/*" \
                -c remote.lop.url="file://$lop_remote" \
                -c promisor.acceptfromserver=All \
                --no-local --filter="blob:limit=5k" "$server" "$client" &&
        test_path_is_missing "$client/.git/objects/$(test_oid_to_path $blob_oid)" &&
        (
                cd "$client" &&
                git cat-file -p HEAD:huge.bin >../client.bin
        ) &&
        test_cmp lop-producer/huge.bin client.bin &&
        test_path_is_file "$lop_store/objects/$(test_oid_to_path $blob_oid)" &&
        git -C "$client" cat-file -e "$blob_oid"
'

test_done
