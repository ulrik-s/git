# Large Object Promisors demo

This directory contains `demo.sh`, a self-contained script that builds a throwaway
setup for demonstrating the large object promisor plumbing. It wires a bare server
with two promisor remotes ("small" and "large" stores), installs a post-receive hook
that splits incoming blobs by size, and clones clients that can push and later show
partial-clone behaviour.

The script expects to be run with a Git binary that already includes the Large Object
Promisors feature (git.git `master` or later). It removes any previous `$DEST`
directory before creating the demo repositories.

```sh
PATH=/path/to/git/bin-wrappers:/path/to/git:$PATH \
  bash contrib/large-object-promisors/demo.sh
```

The `DEST`, `BRANCH`, `THRESHOLD`, and `SEED_INITIAL` environment variables can be
overridden to tweak where the repositories live, which branch is created, the size
threshold used to classify blobs (default 1 MiB), and whether to create the sample
commits. When `SEED_INITIAL=1` the script pushes two large blobs (8 MiB then 2 MiB)
from the first client, clones a fresh `client2` after those pushes with
`--filter=blob:none`, explicitly prefetches just the tip blob from the large
promisor store, and prints a size summary for each repository so you can compare how
much data landed in the smart clone.
