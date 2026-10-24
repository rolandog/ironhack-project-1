#!/usr/bin/env bash
# rg-code-scanning.sh -- list CodeQL alerts; optionally file one issue per rule
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
repo=rolandog/ironhack-project-1
state=open
format=tsv
create=no
milestone=
labels='security,status:todo'

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
List code scanning alerts grouped by rule; GITHUB_TOKEN is required.

  --repo=OWNER/NAME  repository (default: $repo)
  --state=STATE      open, closed, dismissed or fixed (default: $state)
  --format=FORMAT    tsv, markdown or json (default: $format)
  --create           create one issue per rule (default: dry run)
  --milestone=N      milestone number for created issues
  --labels=LIST      comma-separated labels (default: $labels)
  --help             display this help and exit
  --version          output version information and exit
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

for arg; do
  case $arg in
    --help)        usage; exit 0 ;;
    --version)     printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --repo=*)      repo=${arg#*=} ;;
    --state=*)     state=${arg#*=} ;;
    --format=*)    format=${arg#*=} ;;
    --create)      create=yes ;;
    --milestone=*) milestone=${arg#*=} ;;
    --labels=*)    labels=${arg#*=} ;;
    *)             usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

[[ -n ${GITHUB_TOKEN:-} ]] || die "GITHUB_TOKEN is not set"
command -v jq >/dev/null || die "jq not found"

tmp=$(mktemp "${TMPDIR:-/tmp}/$PROGRAM.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

# why: the token goes in a curl config on stdin, so it stays out of ps
api() {
  local method=$1 path=$2; shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" \
    | curl -fsS -K - -X "$method" -H 'Accept: application/vnd.github+json' \
        "$@" "https://api.github.com/repos/$repo/$path"
}

fetch_alerts() {
  local page=1 out
  while :; do
    out=$(api GET "code-scanning/alerts?state=$state&per_page=100&page=$page") || exit 1
    [[ $(jq length <<<"$out") -gt 0 ]] || break
    printf '%s\n' "$out"
    page=$((page + 1))
  done | jq -s 'add // []'
}

# why: "#N" in an issue body would link to an issue, not an alert
# why: JQ_DEFS is a jq program, so the shell must not expand it
# shellcheck disable=SC2016
readonly JQ_DEFS='
def sev: .[0].rule.security_severity_level // .[0].rule.severity;
def loc: .most_recent_instance.location;
def msg: (.most_recent_instance.message.text // "") | gsub("\n+"; " ");
def title: "security: fix CodeQL alert: \(.[0].rule.description) (\(.[0].rule.id))";
def body:
  "- Rule: `\(.[0].rule.id)`\n"
  + "- Severity: \(sev)\n"
  + "- Tool: \(.[0].tool.name) \(.[0].tool.version // "")\n"
  + "- Alerts: \(map(.number | tostring) | join(", "))\n\n"
  + ((.[0].rule.full_description // "") + "\n\n### Locations\n\n")
  + (map("- `\(loc.path):\(loc.start_line)`: \(msg) ([alert \(.number)](\(.html_url)))") | join("\n"))
  + "\n\n### Guidance\n\n" + ((.[0].rule.help // "see the alert page") | split("\n## References")[0]);
'

alerts=$(fetch_alerts) || die "cannot fetch alerts (check GITHUB_TOKEN and its read access to code scanning)"
(( $(jq length <<<"$alerts") > 0 )) || { printf '%s: no %s alerts\n' "$PROGRAM" "$state" >&2; exit 0; }

case $format in
  json)     jq . <<<"$alerts" ;;
  tsv)      jq -r "$JQ_DEFS"'group_by(.rule.id)[]
              | [.[0].rule.id, sev, length, .[0].rule.description,
                 (map(loc.path + ":" + (loc.start_line | tostring)) | unique | join(","))]
              | @tsv' <<<"$alerts" ;;
  markdown) jq -r "$JQ_DEFS"'group_by(.rule.id)[] | "# " + title + "\n\n" + body + "\n"' <<<"$alerts" ;;
  *)        die "unknown format '$format'" ;;
esac

[[ $create == yes ]] || exit 0

jq -c --arg l "$labels" --argjson m "${milestone:-null}" "$JQ_DEFS"'
  group_by(.rule.id)[]
  | {title: title, body: body, labels: ($l | split(","))}
    + (if $m then {milestone: $m} else {} end)' <<<"$alerts" \
| while IFS= read -r payload; do
    printf '%s' "$payload" >| "$tmp"      # >| because noclobber is set
    api POST issues --data-binary @"$tmp" | jq -r '"created #\(.number) \(.title)"'
    sleep 1                               # why: stay clear of secondary rate limits
  done
