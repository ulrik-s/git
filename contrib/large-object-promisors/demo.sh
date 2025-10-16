#!/usr/bin/env bash
set -euo pipefail

DEST=${DEST:-$PWD/lop-demo}
BRANCH=${BRANCH:-main}
THRESHOLD=${THRESHOLD:-1048576}
SEED_INITIAL=${SEED_INITIAL:-1}

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
abspath() { (cd "$1" >/dev/null 2>&1 && pwd -P) || { echo "ERROR: '$1' not found" >&2; exit 1; }; }
file_url() { printf 'file://%s\n' "$(abspath "$1")"; }

rm -rf "$DEST"
mkdir -p "$DEST"
ROOT=$(abspath "$DEST")

LOP_SMALL="$ROOT/lop-small.git"
LOP_LARGE="$ROOT/lop-large.git"
SERVER="$ROOT/server.git"
CLIENT="$ROOT/client"
CLIENT2="$ROOT/client2"

init_bare() {
  git init --bare "$1" >/dev/null
  git -C "$1" config uploadpack.allowFilter true
  git -C "$1" config uploadpack.allowAnySHA1InWant true
}

say "Create bare repositories"
init_bare "$LOP_SMALL"
init_bare "$LOP_LARGE"
init_bare "$SERVER"

SERVER_URL=$(file_url "$SERVER")
LOP_SMALL_URL=$(file_url "$LOP_SMALL")
LOP_LARGE_URL=$(file_url "$LOP_LARGE")

say "Configure promisor remotes on server"
git -C "$SERVER" config promisor.advertise true
git -C "$SERVER" config promisor.sendFields partialCloneFilter

config_promisor_remote() {
  local repo=$1 name=$2 url=$3 filter=${4:-}
  git -C "$repo" config "remote.${name}.url" "$url"
  git -C "$repo" config "remote.${name}.fetch" "+refs/heads/*:refs/remotes/${name}/*"
  git -C "$repo" config "remote.${name}.promisor" true
  if [ -n "$filter" ]; then
    git -C "$repo" config "remote.${name}.partialCloneFilter" "$filter"
  fi
}

config_promisor_remote "$SERVER" lopSmall "$LOP_SMALL_URL" "blob:limit=$THRESHOLD"
config_promisor_remote "$SERVER" lopLarge "$LOP_LARGE_URL" blob:none
git -C "$SERVER" config --add promisor.remote lopSmall
git -C "$SERVER" config --add promisor.remote lopLarge

say "Configure promisor stores"
git -C "$LOP_SMALL" config remote.server.url "$SERVER_URL"
git -C "$LOP_SMALL" config remote.server.fetch "+refs/heads/*:refs/heads/*"
git -C "$LOP_LARGE" config remote.server.url "$SERVER_URL"
git -C "$LOP_LARGE" config remote.server.fetch "+refs/heads/*:refs/heads/*"

say "Link server alternates to promisor stores"
mkdir -p "$SERVER/objects/info"
{
  printf '%s/objects\n' "$(abspath "$LOP_LARGE")"
  printf '%s/objects\n' "$(abspath "$LOP_SMALL")"
} >"$SERVER/objects/info/alternates"

git -C "$SERVER" config gc.writeBitmaps false
git -C "$SERVER" config repack.writeBitmaps false

say "Install post-receive hook"
cat <<'HOOK' >"$SERVER/hooks/post-receive"
#!/usr/bin/env bash
set -euo pipefail

zeros=0000000000000000000000000000000000000000
root=$(pwd -P)
small=$(git config --get lop.smallPath)
large=$(git config --get lop.largePath)
threshold=$(git config --get lop.thresholdBytes)

[ -n "${small:-}" ] && [ -n "${large:-}" ] && [ -n "${threshold:-}" ] || exit 0

refs=()
tips=()
while read -r old new ref; do
  [ "$new" = "$zeros" ] && continue
  case "$ref" in
  refs/heads/*)
    refs+=("+$ref:$ref")
    tips+=("$new")
    ;;
  esac
done

[ "${#refs[@]}" -eq 0 ] && exit 0

git -C "$small" fetch --filter="blob:limit=$threshold" server "${refs[@]}"
git -C "$large" fetch --filter="blob:none" server "${refs[@]}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

git rev-list --objects --filter="blob:limit=$threshold" --filter-print-omitted "${tips[@]}" \
  | sed -n 's/^~//p' >"$tmp"
if [ -s "$tmp" ]; then
  xargs -r -n256 git -C "$large" fetch server <"$tmp"
fi

git -c repack.writeBitmaps=false -c repack.packKeptObjects=true -C "$root" \
  repack -Ad -d --no-write-bitmap-index \
  --filter="blob:limit=$threshold" \
  --filter-to="$large/objects"

git -c repack.writeBitmaps=false -c repack.packKeptObjects=true -C "$root" \
  repack -Ad -d --no-write-bitmap-index \
  --filter="blob:none" \
  --filter-to="$small/objects"

git -C "$root" prune-packed
HOOK
chmod +x "$SERVER/hooks/post-receive"

git -C "$SERVER" config lop.smallPath "$LOP_SMALL"
git -C "$SERVER" config lop.largePath "$LOP_LARGE"
git -C "$SERVER" config lop.thresholdBytes "$THRESHOLD"

clone_with_promisors() {
  local dest=$1 filter=${2:-} no_checkout=${3:-0}
  rm -rf "$dest"
  local clone_args=(-c promisor.acceptFromServer=All)
  clone_args+=(
    -c remote.lopSmall.promisor=true
    -c "remote.lopSmall.url=$LOP_SMALL_URL"
    -c "remote.lopSmall.fetch=+refs/heads/*:refs/remotes/lopSmall/*"
    -c "remote.lopSmall.partialCloneFilter=blob:limit=$THRESHOLD"
    -c remote.lopLarge.promisor=true
    -c "remote.lopLarge.url=$LOP_LARGE_URL"
    -c "remote.lopLarge.fetch=+refs/heads/*:refs/remotes/lopLarge/*"
    -c remote.lopLarge.partialCloneFilter=blob:none
  )
  if [ -n "$filter" ]; then
    clone_args+=("--filter=$filter")
  fi
  if [ "$no_checkout" = 1 ]; then
    clone_args+=(--no-checkout)
  fi
  local display_opts=""
  if [ "${#clone_args[@]}" -gt 0 ]; then
    printf -v display_opts ' %q' "${clone_args[@]}"
  fi
  printf '  git clone%s %q %q\n' "$display_opts" "$SERVER_URL" "$dest"
  git clone "${clone_args[@]}" "$SERVER_URL" "$dest" >/dev/null
}

say "Clone client"
clone_with_promisors "$CLIENT"

if [ "$SEED_INITIAL" = 1 ]; then
  say "Create sample commits"
  git -C "$CLIENT" switch -c "$BRANCH" >/dev/null || git -C "$CLIENT" checkout -b "$BRANCH" >/dev/null
  git -C "$CLIENT" config user.name "LOP Demo"
  git -C "$CLIENT" config user.email "lop-demo@example.invalid"
  echo '# LOP demo' >"$CLIENT/README.md"
  git -C "$CLIENT" add README.md
  git -C "$CLIENT" commit -m "Initial commit" >/dev/null
  git -C "$CLIENT" push -u origin "$BRANCH" >/dev/null

  (
    cd "$CLIENT" >/dev/null

    write_random_blob() {
      local path=$1 bytes=$2
      dd if=/dev/urandom of="$path" bs="$bytes" count=1 status=none
    }

    ensure_above_threshold() {
      local size=$1 threshold=$2
      while [ "$size" -le "$threshold" ]; do
        size=$((size + 1024 * 1024))
      done
      printf '%s' "$size"
    }

    ensure_below_threshold() {
      local size=$1 threshold=$2
      if [ "$threshold" -le 1 ]; then
        printf '1'
        return
      fi
      if [ "$size" -ge "$threshold" ]; then
        size=$((threshold - 1))
        [ "$size" -lt 1 ] && size=1
      fi
      printf '%s' "$size"
    }

    add_blob_commit() {
      local path=$1 bytes=$2 message=$3
      write_random_blob "$path" "$bytes"
      git add "$path"
      git commit -m "$message" >/dev/null
      git push >/dev/null
    }

    big_path=big-demo.bin
    big_bytes_1=$(ensure_above_threshold $((8 * 1024 * 1024)) "$THRESHOLD")
    big_bytes_2=$(ensure_above_threshold $((2 * 1024 * 1024)) "$THRESHOLD")
    add_blob_commit "$big_path" "$big_bytes_1" "Add large demo blob"
    add_blob_commit "$big_path" "$big_bytes_2" "Replace with newer large blob"

    small_path=small-demo.bin
    small_bytes_1=$(ensure_below_threshold $((512 * 1024)) "$THRESHOLD")
    small_bytes_2=$(ensure_below_threshold $((256 * 1024)) "$THRESHOLD")
    [ "$small_bytes_2" -ge "$small_bytes_1" ] && small_bytes_2=$((small_bytes_1 > 1 ? small_bytes_1 - 1 : 1))
    add_blob_commit "$small_path" "$small_bytes_1" "Add small demo blob"
    add_blob_commit "$small_path" "$small_bytes_2" "Replace with newer small blob"
  )

  git -C "$SERVER" symbolic-ref HEAD "refs/heads/$BRANCH" >/dev/null || true

  say "Clone smart client (client2)"
  clone_with_promisors "$CLIENT2" "blob:none" 1
  git -C "$CLIENT2" checkout "$BRANCH" >/dev/null
fi

say "Repository sizes"
du -hs "$SERVER" "$LOP_SMALL" "$LOP_LARGE" "$CLIENT" ${CLIENT2:+"$CLIENT2"}

cat <<EOF
============================================================
Setup complete.

Server  : $SERVER
Small   : $LOP_SMALL
Large   : $LOP_LARGE
Client  : $CLIENT
Client2 : ${CLIENT2:-<not created>}

Threshold: $THRESHOLD bytes

Inspect server:
  ls -lh "$SERVER/objects/pack"

Inspect promisor stores:
  git -C "$LOP_SMALL" rev-list --objects --all | head
  git -C "$LOP_LARGE" rev-list --objects --all | grep big-8MiB.bin || true

Inspect smart clone:
  git -C "$CLIENT2" rev-list --objects --all | grep big-8MiB.bin || true
  git -C "$CLIENT2" count-objects -vH
============================================================
EOF
