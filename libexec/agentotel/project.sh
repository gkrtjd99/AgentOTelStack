#!/bin/sh
. "$(dirname "$0")/common.sh"
root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not a git project'; file="$root/.agentotel/project.toml"; dir="$root/.agentotel"
# Checkout identity is deliberately kept in git-dir metadata: it must not become
# a tracked project setting and linked worktrees must receive distinct IDs.
checkout_file(){ git rev-parse --git-path agentotel-checkout-id 2>/dev/null; }
project_lock="$dir.lock"
lock_project(){
  [ ! -L "$project_lock" ] || die 'symlink rejected'
  i=0
  while ! mkdir "$project_lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -lt 100 ] || die 'project busy' 75
    sleep .01
  done
  trap unlock_project EXIT
}
unlock_project(){ rmdir "$project_lock" 2>/dev/null || :; trap - EXIT; }
parse(){
  [ -f "$file" ] || die 'project not initialized'; reject_symlink "$dir"; reject_symlink "$file"
  awk 'BEGIN{s=0;p=0} /^[[:space:]]*schema[[:space:]]*=[[:space:]]*1[[:space:]]*$/ {s++;next} /^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {p++;next} /^[[:space:]]*$/ {next} {exit 2} END{if(s!=1||p!=1)exit 2}' "$file" || die 'invalid project.toml'
  parsed_project_id=$(sed -n 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$file")
  valid_project_uuid "$parsed_project_id" || die 'project.toml requires a UUIDv4 project_id'
}
init_unlocked(){ [ ! -e "$file" ] || die 'project already initialized'; [ ! -L "$dir" ] || die 'symlink rejected'; mkdir -p "$dir"; id=$(rand_uuid_v4); valid_project_uuid "$id" || die 'generated invalid project UUID'; tmp="$file.tmp.$$"; { echo 'schema = 1'; echo "project_id = \"$id\""; } >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$file"; ensure_checkout; echo '{"status":"initialized"}'; }
init(){ lock_project; init_unlocked; unlock_project; }
rekey(){ parse; id=$(rand_uuid_v4); valid_project_uuid "$id" || die 'generated invalid project UUID'; tmp="$file.tmp.$$"; { echo 'schema = 1'; echo "project_id = \"$id\""; } >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$file"; echo '{"status":"rekeyed"}'; }
ensure_checkout(){
  [ ! -L "$dir" ] || die 'symlink rejected'; cf=$(checkout_file); [ -n "$cf" ] || die 'git metadata unavailable'; mkdir -p "$(dirname "$cf")"
  reject_symlink "$cf"
  if [ ! -f "$cf" ]; then cid=$(rand_uuid_v4); valid_project_uuid "$cid" || die 'generated invalid checkout UUID'; tmp="$cf.tmp.$$"; printf '%s\n' "$cid" >"$tmp"; chmod 600 "$tmp"; if ln "$tmp" "$cf" 2>/dev/null; then rm -f "$tmp"; else rm -f "$tmp"; [ -f "$cf" ] || die 'unable to create checkout ID'; fi; else cid=$(cat "$cf"); valid_project_uuid "$cid" || die 'invalid checkout ID'; fi
}
ensure(){ lock_project; if [ ! -f "$file" ]; then init_unlocked >/dev/null; fi; parse; ensure_checkout; printf '%s\n' "$parsed_project_id"; unlock_project; }
state(){ parse; ensure_checkout; head=$(git rev-parse --verify HEAD 2>/dev/null || echo null); tracked=$(git diff --binary | shasum -a 256 | awk '{print $1}'); staged=$(git diff --cached --binary | shasum -a 256 | awk '{print $1}'); dirty=0; [ -n "$(git status --porcelain 2>/dev/null)" ] && dirty=1; cid=$(cat "$(checkout_file)"); frame="commit=$head\ntracked=$tracked\nstaged=$staged\ndirty=$dirty\ncheckout=$cid"; sid=$(printf '%s' "$frame" | shasum -a 256 | awk '{print $1}'); case "$head" in null) commit=null;; *) commit="\"$head\"";; esac; printf '{"commit":%s,"dirty":%s,"staged":"%s","unstaged":"%s","checkout_id":"%s","source_state_id":"%s"}\n' "$commit" "$dirty" "$staged" "$tracked" "$cid" "$sid"; }
case "${1:-}" in init) init;; rekey) rekey;; ensure) ensure;; source-state) state;; *) die 'invalid project command';; esac
