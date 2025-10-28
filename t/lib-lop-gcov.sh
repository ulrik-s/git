# Helper routines for optional gcov-based coverage checks in LOP tests.

if test -z "$LIB_LOP_GCOV_SH"
then
LIB_LOP_GCOV_SH=1

lop__coverage_requested() {
case "${GIT_TEST_LOP_COVERAGE:-}" in
""|0|no|false)
        return 1 ;;
*)
        return 0 ;;
esac
}

lop__coverage_has_artifacts() {
file="$1"
dir=${file%/*}
base=${file##*/}
if test "$dir" = "$file"
then
dir="."
fi
stem=${base%.c}
if ! test_path_is_file "$GIT_BUILD_DIR/$dir/$stem.gcno"
then
        return 1
fi
if ! test_path_is_file "$GIT_BUILD_DIR/$dir/$stem.gcda"
then
        return 1
fi
return 0
}

if lop__coverage_requested &&
   command -v gcov >/dev/null 2>&1 &&
   lop__coverage_has_artifacts builtin/clone.c &&
   lop__coverage_has_artifacts builtin/receive-pack.c &&
   lop__coverage_has_artifacts promisor-remote.c
then
test_set_prereq LOP_GCOV
fi

lop_gcov_prepare() {
case "$LOP_GCOV_PREPARED" in
1)
        return ;;
esac
LOP_GCOV_PREPARED=1
if ! lop__coverage_requested
then
        return
fi
mkdir -p "$TRASH_DIRECTORY/gcov"
}

lop__gcov_run() {
file="$1"
dir=${file%/*}
base=${file##*/}
if test "$dir" = "$file"
then
dir="."
fi
output="$TRASH_DIRECTORY/gcov/$base.gcov"
if test ! -e "$TRASH_DIRECTORY/gcov/$file"
then
        if test "$dir" != "."
        then
                mkdir -p "$TRASH_DIRECTORY/gcov/$dir"
        fi
        ln -s "$GIT_SOURCE_DIR/$file" "$TRASH_DIRECTORY/gcov/$file" 2>/dev/null ||
        cp "$GIT_SOURCE_DIR/$file" "$TRASH_DIRECTORY/gcov/$file" 2>/dev/null ||
        true
fi
(
        cd "$TRASH_DIRECTORY/gcov" &&
        gcov --branch-probabilities --all-blocks \
                --object-directory="$GIT_BUILD_DIR/$dir" \
                "$GIT_SOURCE_DIR/$file" >/dev/null
) || return 1
echo "$output"
}

lop_assert_gcov_functions() {
    file="$1"
    shift
    cov_file=$(lop__gcov_run "$file") || return 1
    for fn in "$@"
    do
        grep "^function $fn" "$cov_file" >"$TRASH_DIRECTORY/gcov/$fn.func" || return 1
        ! grep "^function $fn called 0" "$cov_file" || return 1
    done
}

lop_assert_gcov_function_coverage() {
    file="$1"
    min="$2"
    shift 2
    cov_file=$(lop__gcov_run "$file") || return 1
    for fn in "$@"
    do
        percent=$(awk -v fn="$fn" '
            $0 ~ "^function " fn " " {
                for (i = 1; i <= NF; i++) {
                    if ($i == "blocks" && $(i + 1) == "executed") {
                        val = $(i + 2)
                        sub(/%/, "", val)
                        print val
                        exit
                    }
                }
            }
        ' "$cov_file") || return 1
        test -n "$percent" || return 1
        awk -v p="$percent" -v min="$min" 'BEGIN { exit !(p + 0 >= min + 0) }'
    done
}

fi
