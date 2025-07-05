#!/bin/sh

test_description='bblob smart transfer'

. ./test-lib.sh

cat_bigfile() {
    perl -e "print \"$1\" x 20000" >bigfile
}

setup_server() {
    git init server &&
    (
        cd server &&
        cat_bigfile a &&
        oid1=$(git hash-object -t bblob -w bigfile) &&
        git update-index --add --cacheinfo 100644 $oid1 big.bin &&
        git commit -m initial
    )
}

setup_client() {
    git clone server client &&
    git -C client rev-parse HEAD > /dev/null
}

test_expect_success 'initial clone transfers bblob object' '
    setup_server &&
    setup_client &&
    git -C server cat-file -p HEAD:big.bin >expect &&
    git -C client cat-file -p HEAD:big.bin >actual &&
    test_cmp expect actual
'

test_expect_failure 'fetch reuses existing bblob data' '
    (
        cd server &&
        echo note >note &&
        git add note &&
        git commit -m second
    ) &&
    before=$(ls client/.git/objects/pack | wc -l) &&
    git -C client fetch ../server >/dev/null &&
    after=$(ls client/.git/objects/pack | wc -l) &&
    test $((after-before)) = 1 &&
    pack=$(ls client/.git/objects/pack/pack-*.pack | sort | tail -n1) &&
    size=$(wc -c <"$pack") &&
    test $size -lt 5000
'

test_expect_failure 'fetch transfers new bblob chunks only once' '
    (
        cd server &&
        cat_bigfile b &&
        oid2=$(git hash-object -t bblob -w bigfile) &&
        git update-index --add --cacheinfo 100644 $oid2 big.bin &&
        git commit -m third
    ) &&
    before=$(ls client/.git/objects/pack | wc -l) &&
    git -C client fetch ../server >/dev/null &&
    after=$(ls client/.git/objects/pack | wc -l) &&
    test $((after-before)) = 1 &&
    git -C server cat-file -p HEAD:big.bin >expect &&
    git -C client cat-file -p FETCH_HEAD:big.bin >actual &&
    test_cmp expect actual
'

test_expect_failure 'redundant fetch sends no additional pack' '
    before=$(ls client/.git/objects/pack | wc -l) &&
    git -C client fetch ../server >/dev/null &&
    after=$(ls client/.git/objects/pack | wc -l) &&
    test $before = $after
'

test_expect_failure 'reusing existing bblob avoids retransmission' '
    (
        cd server &&
        git reset --hard HEAD^ &&
        echo more >>note && git add note && git commit -m fourth
    ) &&
    before=$(ls client/.git/objects/pack | wc -l) &&
    git -C client fetch ../server >/dev/null &&
    after=$(ls client/.git/objects/pack | wc -l) &&
    test $((after-before)) = 1 &&
    pack=$(ls client/.git/objects/pack/pack-*.pack | sort | tail -n1) &&
    size=$(wc -c <"$pack") &&
    test $size -lt 5000
'

test_done
