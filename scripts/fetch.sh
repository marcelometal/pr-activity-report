#!/usr/bin/env bash
# Fetch a user's authored and participated (review/comment) pull requests in a
# GitHub org and write data/<handle>.json in the shape generate.py consumes.
#
# Runs as the authenticated gh user: GitHub Search only returns PRs from repos
# that account can see, so run it as the person (or an account with access to
# the relevant repos) for complete numbers.
#
# This is a "throttled" fetcher: it paginates manually with pauses and backs
# off on failure, to stay under GitHub's secondary rate limit on high-volume
# accounts.
#
# Usage:
#   scripts/fetch.sh --org ORG [options] <handle>
#
# Options:
#   --org ORG             (required) org/owner to scan
#   --name "Name"         display name (default: from the GitHub profile)
#   --window YYYY-MM-DD    only PRs created on/after this date (default: all)
#   --monorepos a,b,c     repos to break down into sub-projects
#   --monorepo-depth N    path depth of the sub-project key (default: 1)
#
# Env knobs: GAP (sleep between search pages, default 4s),
#            FGAP (sleep between per-PR files calls, default 1.2s).
#
# Requires: gh (authenticated), jq.
set -euo pipefail

ORG="" NAME_OVERRIDE="" WINDOW="" MONOREPOS="" DEPTH=1 H=""
while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="$2"; shift 2;;
    --name) NAME_OVERRIDE="$2"; shift 2;;
    --window) WINDOW="$2"; shift 2;;
    --monorepos) MONOREPOS="$2"; shift 2;;
    --monorepo-depth) DEPTH="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown flag: $1" >&2; exit 2;;
    *) H="$1"; shift;;
  esac
done
[ -n "$ORG" ] || { echo "error: --org is required" >&2; exit 2; }
[ -n "$H" ]   || { echo "error: handle is required" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$ROOT/data"; mkdir -p "$DATA_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GAP="${GAP:-4}"
FGAP="${FGAP:-1.2}"

# created:>=WINDOW qualifier, plus a human label for the footer
QUAL=""; WINDOW_LABEL="janela completa"
if [ -n "$WINDOW" ]; then QUAL=" created:>=$WINDOW"; WINDOW_LABEL="janela criada >= $WINDOW"; fi

gh_retry() { # echo gh stdout; growing backoff on failure
  local i out
  for i in 1 2 3 4 5 6; do
    if out="$(gh "$@" 2>/dev/null)"; then printf '%s' "$out"; return 0; fi
    sleep $((20*i))
  done
  return 1
}

NAME="$NAME_OVERRIDE"
[ -z "$NAME" ] && NAME="$(gh api "users/$H" --jq '.name // empty' 2>/dev/null || true)"
[ -z "$NAME" ] && NAME="$H"

MES=(x jan fev mar abr mai jun jul ago set out nov dez)
GENERATED="$(date +%-d) ${MES[$(date +%-m)]} $(date +%Y)"

ISSUE_JQ='.items[] | {n:.number, t:.title, r:(.repository_url|sub(".*/repos/"+$org+"/";"")), s:(if .pull_request.merged_at then "merged" elif .state=="closed" then "closed" else "open" end), d:(.created_at[0:10]), u:.html_url}'
REVIEW_JQ="${ISSUE_JQ%\}} , a:.user.login}"

paged() { # $1=query  $2=jq  $3=out.jsonl
  local q="$1" jqf="$2" out="$3" page=1 n resp
  : > "$out"
  while :; do
    resp="$(gh_retry api -X GET search/issues -f q="$q" -f per_page=100 -f page="$page")"
    n="$(printf '%s' "$resp" | jq '.items|length')"
    printf '%s' "$resp" | jq -c --arg org "$ORG" "$jqf" >> "$out"
    [ "$n" -lt 100 ] && break
    page=$((page+1)); [ "$page" -gt 10 ] && break   # Search caps at 1000 hits
    sleep "$GAP"
  done
}

echo "[$H] authored..."
paged "is:pr author:$H org:$ORG$QUAL" "$ISSUE_JQ" "$TMP/a.jsonl"
jq -s 'sort_by(.d,.n)|reverse' "$TMP/a.jsonl" > "$TMP/authored.json"
sleep "$GAP"

echo "[$H] reviews..."
paged "is:pr org:$ORG reviewed-by:$H -author:$H$QUAL" "$REVIEW_JQ" "$TMP/r.jsonl"
jq -s 'map(.k="review")' "$TMP/r.jsonl" > "$TMP/reviewed.json"
sleep "$GAP"

echo "[$H] comments..."
paged "is:pr org:$ORG commenter:$H -author:$H$QUAL" "$REVIEW_JQ" "$TMP/c.jsonl"
jq -s 'map(.k="comment")' "$TMP/c.jsonl" > "$TMP/commented.json"

jq -s '(.[0]+.[1])|group_by(.u)|map((map(select(.k=="review"))|first)//.[0])|sort_by(.d)|reverse' \
  "$TMP/reviewed.json" "$TMP/commented.json" > "$TMP/reviews.json"

# Optional monorepo sub-project derivation (only for repos in --monorepos):
# project = dominant changed-files directory at --monorepo-depth components.
: > "$TMP/projmap.jsonl"
if [ -n "$MONOREPOS" ]; then
  MONO_RE="^($(printf '%s' "$MONOREPOS" | tr ',' '|'))$"
  echo "[$H] deriving sub-projects for: $MONOREPOS (depth $DEPTH)..."
  jq -rs --arg re "$MONO_RE" '(.[0]+.[1])[]|select(.r|test($re))|"\(.r) \(.n)"' \
    "$TMP/authored.json" "$TMP/reviews.json" | sort -u > "$TMP/mono.txt"
  echo "  $(wc -l < "$TMP/mono.txt") monorepo PRs"
  while read -r repo num; do
    files=$(gh_retry api "repos/$ORG/$repo/pulls/$num/files" --paginate --jq '.[].filename' || true)
    proj=$(printf '%s\n' "$files" | awk -v d="$DEPTH" -F/ '
      NF>d { key=$1; for(i=2;i<=d;i++) key=key"/"$i; print key }
    ' | sort | uniq -c | sort -rn | head -1 | sed 's/^ *[0-9]* //')
    printf '{"r":"%s","n":%s,"p":"%s"}\n' "$repo" "$num" "$proj" >> "$TMP/projmap.jsonl"
    sleep "$FGAP"
  done < "$TMP/mono.txt"
fi

ADD_P='((.[0])|map({key:(.r+"#"+(.n|tostring)),value:.p})|from_entries) as $m
  | .[1] | map(. as $x|($m[$x.r+"#"+($x.n|tostring)]) as $p
  | if $p and $p!="" and ($p|test("^\\.|README")|not) then .+{p:$p} else . end)'
jq -s "$ADD_P" <(jq -s '.' "$TMP/projmap.jsonl") "$TMP/authored.json" > "$TMP/data.json"
jq -s "$ADD_P" <(jq -s '.' "$TMP/projmap.jsonl") "$TMP/reviews.json"  > "$TMP/reviews_p.json"

jq -n --arg h "$H" --arg name "$NAME" --arg gen "$GENERATED" \
  --arg org "$ORG" --arg window "$WINDOW_LABEL" \
  --slurpfile data "$TMP/data.json" --slurpfile reviews "$TMP/reviews_p.json" \
  '{handle:$h, name:$name, generated:$gen, org:$org, window:$window, data:$data[0], reviews:$reviews[0]}' \
  > "$DATA_DIR/$H.json"

echo "[$H] wrote: data/$H.json"
echo "  DATA $(jq '.data|length' "$DATA_DIR/$H.json") | REVIEWS $(jq '.reviews|length' "$DATA_DIR/$H.json") | name: $NAME | generated: $GENERATED"
