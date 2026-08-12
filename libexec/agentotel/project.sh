#!/bin/sh
. "$(dirname "$0")/common.sh"
root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not a git project'; file="$root/.agentotel/project.toml"; dir="$root/.agentotel"
# Checkout identity is deliberately kept in git-dir metadata: it must not become
# a tracked project setting and linked worktrees must receive distinct IDs.
checkout_file(){ git rev-parse --git-path agentotel-checkout-id 2>/dev/null; }
parse(){ [ -f "$file" ] || die 'project not initialized'; reject_symlink "$dir"; reject_symlink "$file"; awk '
BEGIN{n=0} /^[[:space:]]*schema[[:space:]]*=[[:space:]]*1[[:space:]]*$/ {if(++s>1)exit 2;next} /^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"[[:space:]]*$/ {if(++p>1)exit 2;next} /^[[:space:]]*$/ {next} {exit 2} END{if(s!=1||p!=1)exit 2}' "$file" || die 'invalid project.toml'
}
init(){ [ ! -e "$file" ] || die 'project already initialized'; [ ! -L "$dir" ] || die 'symlink rejected'; mkdir -p "$dir"; id=$(rand_uuid | tr A-F a-f); tmp="$file.tmp.$$"; { echo 'schema = 1'; echo "project_id = \"$id\""; } >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$file"; ensure_checkout; echo '{"status":"initialized"}'; }
rekey(){ parse; id=$(rand_uuid | tr A-F a-f); tmp="$file.tmp.$$"; { echo 'schema = 1'; echo "project_id = \"$id\""; } >"$tmp"; chmod 600 "$tmp"; mv "$tmp" "$file"; echo '{"status":"rekeyed"}'; }
ensure_checkout(){ [ ! -L "$dir" ] || die 'symlink rejected'; cf=$(checkout_file); [ -n "$cf" ] || die 'git metadata unavailable'; mkdir -p "$(dirname "$cf")"; if [ ! -f "$cf" ]; then cid=$(rand_uuid | tr A-F a-f); printf '%s\n' "$cid" >"$cf.tmp.$$"; chmod 600 "$cf.tmp.$$"; mv "$cf.tmp.$$" "$cf"; fi; }
state(){ parse; ensure_checkout; head=$(git rev-parse --verify HEAD 2>/dev/null || echo null); tracked=$(git diff --binary | shasum -a 256 | awk '{print $1}'); staged=$(git diff --cached --binary | shasum -a 256 | awk '{print $1}'); dirty=0; [ -n "$(git status --porcelain 2>/dev/null)" ] && dirty=1; cid=$(cat "$(checkout_file)" 2>/dev/null || echo unknown); frame="commit=$head\ntracked=$tracked\nstaged=$staged\ndirty=$dirty\ncheckout=$cid"; sid=$(printf '%s' "$frame" | shasum -a 256 | awk '{print $1}'); case "$head" in null) commit=null;; *) commit="\"$head\"";; esac; printf '{"commit":%s,"dirty":%s,"staged":"%s","unstaged":"%s","checkout_id":"%s","source_state_id":"%s"}\n' "$commit" "$dirty" "$staged" "$tracked" "$cid" "$sid"; }
case "${1:-}" in init) init;; rekey) rekey;; source-state) state;; *) die 'invalid project command';; esac
