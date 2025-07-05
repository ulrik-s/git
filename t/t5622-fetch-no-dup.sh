#!/bin/sh

test_description='fetch dedup'

. ./test-lib.sh

setup_repo() {
    git init server &&
    echo hello >server/file &&
    (cd server && git add file && git commit -m initial)
}

setup_client() {
    git clone server client
}

test_expect_success 'fetch from up-to-date repo is a no-op' '
    setup_repo &&
    setup_client &&
    before=$(ls client/.git/objects/pack | wc -l) &&
    git -C client fetch ../server >/dev/null 2>&1 &&
    after=$(ls client/.git/objects/pack | wc -l) &&
    test $before = $after
'

test_done
