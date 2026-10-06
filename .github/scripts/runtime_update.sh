#!/usr/bin/env bash
# Bump the pinned language runtime for daily runtime update PRs.
#
# Usage:
#     runtime_update.sh <runtime> <label> [<body-path>]
#
#     runtime    ruby | python | node
#     label      ecosystem label used in the PR body
#                (Ruby / RubyGem / Ruby on Rails / Python / PyPI / JavaScript / Action)
#     body-path  where to write the pull request description
#                (only written when the version moves)
#
# Finds the newest release the CI setup action can install, staying inside the
# pinned series so the bump never crosses a line that needs code changes:
#
#     ruby    latest X.Y.* listed by ruby/setup-ruby@v1 (ruby-builder-versions.json)
#     python  latest stable X.Y.* in the actions/python-versions manifest used by
#             actions/setup-python
#     node    latest vX.* on nodejs.org/dist (actions/setup-node downloads from there)
#
# Every tracked version file (.ruby-version / .python-version / .node-version)
# is rewritten, and so is every human-facing copy of the version: Dockerfile
# base images and ARGs, the `RUBY VERSION` section of each Gemfile.lock, the
# `python-version` input of action.yml, the Environment sections of README.md,
# the SECURITY.md support tables (re-padded so the columns stay aligned), sample
# pytest output, and package.json descriptions. CHANGELOG.md keeps its history,
# and .github/workflows/ is left alone because GITHUB_TOKEN cannot push
# workflow changes.
#
# Writes `changed`, `old` and `new` to $GITHUB_OUTPUT.
set -euo pipefail

runtime=$1
label=$2
body_path=${3:-}

case $runtime in
  ruby)
    name=Ruby
    # Text that precedes a runtime version wherever it is documented or pinned.
    prefixes='\b[Rr]uby[ :]|\bRUBY_VERSION='
    ;;
  python)
    name=Python
    prefixes='\bC?[Pp]ython[ :]|\bpython-version: |\bPYTHON_VERSION='
    ;;
  node)
    name=Node.js
    prefixes='\b[Nn]ode v|\bNode\.js v|\bnode:|\bNODE_VERSION=v?'
    ;;
  *)
    echo "Unknown runtime: $runtime" >&2
    exit 1
    ;;
esac
version_file=".${runtime}-version"

# The pinned version; a composite action pins its runtime in action.yml instead
# of a version file.
if [[ -f $version_file ]]; then
  current=$(tr -d '[:space:]' <"$version_file")
else
  current=$(sed -nE "s/^ *${runtime}-version: *[\"']?(v?[0-9.]+).*/\1/p" action.yml | head -n 1)
fi
v_prefix=''
[[ $current == v* ]] && v_prefix=v
old=${current#v}
IFS=. read -r major minor _ <<<"$old"

# All releases of the pinned series that the CI setup action can install.
series_versions() {
  case $runtime in
    ruby)
      curl -fsS --max-time 30 https://raw.githubusercontent.com/ruby/setup-ruby/v1/ruby-builder-versions.json |
        jq -r '.ruby[]' | grep -E "^${major}\.${minor}\.[0-9]+$"
      ;;
    python)
      curl -fsS --max-time 30 https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json |
        jq -r '.[] | select(.stable) | .version' | grep -E "^${major}\.${minor}\.[0-9]+$"
      ;;
    node)
      curl -fsS --max-time 30 https://nodejs.org/dist/index.json |
        jq -r '.[].version' | sed 's/^v//' | grep -E "^${major}\.[0-9]+\.[0-9]+$"
      ;;
  esac
}

new=$( { echo "$old"; series_versions || true; } | sort -V | tail -n 1)

if [[ $new == "$old" ]]; then
  changed=false
else
  changed=true
fi
{
  echo "changed=$changed"
  echo "old=${v_prefix}${old}"
  echo "new=${v_prefix}${new}"
} >>"${GITHUB_OUTPUT:-/dev/null}"

if [[ $changed == false ]]; then
  echo "$name ${v_prefix}${old} is already the latest release of its series."
  exit 0
fi

# Tracked text files that may document the runtime version.
candidate_files() {
  git ls-files -z | while IFS= read -r -d '' path; do
    case $path in
      .github/workflows/* | CHANGELOG.md | */CHANGELOG.md) continue ;;
      Gemfile.lock | */Gemfile.lock) ;;
      *.lock | *-lock.json | *-lock.yaml) continue ;;
    esac
    [[ -f $path ]] && grep -Iq -F "$old" "$path" && printf '%s\n' "$path"
  done
}

# Replace the version after each known prefix. In a markdown table row the
# padding before the next `|` absorbs the change in length so the columns stay
# aligned.
replace_version() {
  OLD=$old NEW=$new PREFIXES=$prefixes perl -pi -e '
    BEGIN {
      $old = quotemeta $ENV{OLD};
      $new = $ENV{NEW};
      $prefixes = $ENV{PREFIXES};
      $delta = length($ENV{NEW}) - length($ENV{OLD});
    }
    if (/^\s*\|/) {
      s{($prefixes)$old(?![0-9])([^|]*?)( *)\|}{
        my ($prefix, $rest, $pad) = ($1, $2, $3);
        my $width = length($pad) - $delta;
        $pad = " " x $width if length($pad) > 0 && $width >= 1;
        "$prefix$new$rest$pad|"
      }ge;
    }
    s{($prefixes)$old(?![0-9])}{$1$new}g;
  ' "$1"
}

touched=()
while IFS= read -r path; do
  before=$(cksum <"$path")
  if [[ $(basename "$path") == "$version_file" ]]; then
    sed -i "s/${v_prefix}${old//./\\.}/${v_prefix}${new}/" "$path"
  else
    replace_version "$path"
  fi
  [[ $(cksum <"$path") != "$before" ]] && touched+=("$path")
done < <(candidate_files)

echo "Bumped $name ${v_prefix}${old} -> ${v_prefix}${new} in:"
printf '  %s\n' "${touched[@]}"

[[ -n $body_path ]] || exit 0

case $runtime in
  ruby)   series='minor series'; notes="https://github.com/ruby/ruby/releases/tag/v${new}" ;;
  python) series='minor series'; notes="https://www.python.org/downloads/release/python-${new//./}/" ;;
  node)   series='major line';   notes="https://nodejs.org/en/blog/release/v${new}" ;;
esac
count=${#touched[@]}
plural=s
[[ $count == 1 ]] && plural=''

{
  cat <<OVERVIEW
## 1. Overview

This pull request was created automatically by the ${label} - Daily Runtime Update workflow.  
It bumps ${name} from ${v_prefix}${old} to ${v_prefix}${new}, the newest release of the current ${series} that the CI setup action can install.  

Every pinned version file and every documented copy of the version (Dockerfiles, Gemfile.lock \`RUBY VERSION\`, action inputs, README Environment sections, SECURITY.md support tables, sample test output) is moved together; CHANGELOG.md history is left untouched.  

## 2. Key Changes & Differences

|Files |Before |After |Changes & Differences |
|:-|:-|:-|:-|
OVERVIEW
  for path in "${touched[@]}"; do
    echo "|\`${path}\` |${v_prefix}${old} |${v_prefix}${new} |${name} version updated. |"
  done
  cat <<SUMMARY

## 3. Summary

${name} is bumped from ${v_prefix}${old} to ${v_prefix}${new} across ${count} file${plural}.  
Crossing into a new ${series} is intentionally left to a manual pull request, because it can require code changes.  
Please review the release notes and make sure that all CI workflows pass before merging this pull request.  

## 4. References

- [${label} - Daily Runtime Update workflow run](https://github.com/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-})
- [${name} ${v_prefix}${new} release notes](${notes})
SUMMARY
} >"$body_path"
