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
commits. When `SEED_INITIAL=1` the script pushes two large blobs (first oversized,
then a replacement that still exceeds the threshold) and two small blobs (both
below the threshold) from the first client. After those pushes it clones a fresh
`client2` with `--filter=blob:none`, checks out the branch to trigger a lazy fetch
of only the tip's large blob from the large promisor store, and prints a size
summary for each repository so you can compare where the large and small histories
ended up. The script writes a throwaway global config that sets
`promisor.acceptFromServer=All`, allowing the clones it performs to accept the
promisor remotes advertised by the server without spelling out `-c remote.*`
arguments. Each clone forces protocol v2 (`-c protocol.version=2`) so the
`promisor-remote` capability is available. The script validates that both
promisor remotes arrive via the
advertisement protocol (see `t/t5710` for the low-level coverage) so you know
you are running with a recent enough Git. It also prints the full `git clone`
command for clarity during the demo.
