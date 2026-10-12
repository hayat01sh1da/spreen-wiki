#!/usr/bin/env bash
# Generate the '2. Key Changes & Differences' table for daily dependency PRs.
#
# Usage:
#     dependency_report.sh <ecosystem> <lockfile> <manifest> <label>
#
#     ecosystem  PyPI | RubyGems | npm
#     lockfile   path to requirements.lock / Gemfile.lock / pnpm-lock.yaml
#     manifest   path to requirements.txt / Gemfile / package.json
#     label      first column heading (Libraries / Gems / Packages)
#
# Parses `git diff` of the lockfile and prints a markdown table describing each
# changed dependency: the semver level of the change, the package's summary
# fetched from its registry (PyPI / RubyGems / npm), and whether it is a direct
# or transitive dependency. Each dependency name links to its page on the
# official registry (https://rubygems.org / https://pypi.org /
# https://www.npmjs.com) so reviewers can check release notes and changelogs.
# Package-manager updates are reported too: pip as a regular requirements.lock
# entry, bundler from the lockfile's BUNDLED WITH section, and pnpm from the
# manifest's packageManager field.
# The same versions are documented for humans as well: the package manager in
# the Environment section of every README.md and in the `description` field of
# every package.json, and the dependencies themselves in the Environment
# sections that name them (a Ruby on Rails README opens with `- Rails 8.1.2`).
# None of those copies move on their own when a version changes, so this script
# mirrors the on-disk versions into them before printing the table.
# For gems, changes to the version requirements in the lockfile's DEPENDENCIES
# section are also reported, so a diff that only tightens requirements (e.g.
# `minitest (~> 5.25)` -> `minitest (~> 5.27.0)`) is never summarised as
# "No dependency changes detected".
#
# A version number alone does not tell a reviewer what moved, so every row also
# spells out what changed compared with the previous version:
#
#   - every release between the two versions, with its publication date, taken
#     from the registry;
#   - the highlights of those releases' notes, taken from the GitHub releases of
#     the package's source repository, with links to the release notes, the
#     compare view and the changelog;
#   - for a transitive dependency, which packages require it, i.e. why it moved
#     although nothing declares it.
#
# Below the table, a Mermaid dependency graph shows how each updated package is
# reached from the declared dependencies, a Mermaid histogram counts the updates
# per semver level, and the full release notes of the declared dependencies sit
# in collapsible sections. Scoped packages that move in lockstep (the 14
# platform builds of `@pnpm/exe.*`) collapse into one row.
#
# Release notes are quoted through release_notes.sh, which defuses @-mentions
# and issue references. GitHub API calls use $GH_TOKEN (or $GITHUB_TOKEN) when
# it is set; without one they fall back to the anonymous rate limit, and any
# lookup that fails only leaves its part of the description out.
set -euo pipefail

ecosystem=$1
lockfile=$2
manifest=$3
label=$4

# shellcheck source=release_notes.sh
source "$(dirname "${BASH_SOURCE[0]}")/release_notes.sh"

# Registry and GitHub responses are cached for the run: a row, the dependency
# graph and the release notes all read the same documents.
cache_dir=$(mktemp -d)
trap 'rm -rf "$cache_dir"' EXIT
github_token=${GH_TOKEN:-${GITHUB_TOKEN:-}}

fetch() {
  local url=$1 file
  shift
  file="$cache_dir/$(printf '%s %s' "$url" "$*" | md5sum | cut -c1-32)"
  if [ ! -f "$file" ]; then
    curl -fsSL --max-time 20 "$@" "$url" > "$file" 2>/dev/null || : > "$file"
  fi
  cat "$file"
}

github_api() {
  local -a headers=(-H 'Accept: application/vnd.github+json')
  if [ -n "$github_token" ]; then
    headers+=(-H "Authorization: Bearer ${github_token}")
  fi
  fetch "https://api.github.com/$1" "${headers[@]}"
}

registry_info() {
  case $ecosystem in
    pip) fetch "https://pypi.org/pypi/$1/json" ;;
    gem) fetch "https://rubygems.org/api/v1/gems/$1.json" ;;
    *)   fetch "https://registry.npmjs.org/$1/latest" ;;
  esac
}

describe() {
  local filter
  case $ecosystem in
    pip) filter='.info.summary // empty' ;;
    gem) filter='.info // empty' ;;
    *)   filter='.description // empty' ;;
  esac
  registry_info "$1" | jq -r "$filter" 2>/dev/null || true
}

# `owner/repo` of the package's GitHub repository, from the URLs its registry
# entry lists (source code first). Empty when it is not hosted on GitHub.
source_repository() {
  local filter
  case $ecosystem in
    pip) filter='(.info.project_urls // {} | to_entries | sort_by(.key | test("source|repo|code"; "i") | not) | .[].value), (.info.home_page // empty)' ;;
    gem) filter='.source_code_uri, .changelog_uri, .homepage_uri, .bug_tracker_uri | values' ;;
    *)   filter='(.repository | if type == "object" then .url else . end) // empty, (.homepage // empty)' ;;
  esac
  registry_info "$1" | jq -r "$filter" 2>/dev/null |
    sed -E 's#^github:##; s#^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$#github.com/\1#' |
    grep -oiE 'github\.com[/:][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' |
    sed -E 's#^github\.com[/:]##I; s#\.git$##' |
    grep -viE '^(sponsors|orgs|apps|marketplace)/' | head -n 1 || true
}

changelog_url() {
  local filter
  case $ecosystem in
    pip) filter='.info.project_urls // {} | to_entries[] | select(.key | test("change|release|history|news"; "i")) | .value' ;;
    gem) filter='.changelog_uri // empty' ;;
    *)   return 0 ;;
  esac
  registry_info "$1" | jq -r "$filter" 2>/dev/null | head -n 1 || true
}

# Every published version as `<version> <YYYY-MM-DD>` (`-` when the registry
# does not say: npm's compact document carries no dates).
published_versions() {
  case $ecosystem in
    pip) registry_info "$1" | jq -r '.releases // {} | to_entries[] | select(.value | length > 0) | "\(.key) \(.value[0].upload_time[0:10])"' ;;
    gem) fetch "https://rubygems.org/api/v1/versions/$1.json" | jq -r '.[] | "\(.number) \(.created_at[0:10])"' ;;
    *)   fetch "https://registry.npmjs.org/$1" -H 'Accept: application/vnd.npm.install-v1+json' | jq -r '.versions // {} | keys[] | "\(.) -"' ;;
  esac 2>/dev/null || true
}

# The releases a bump from <old> to <new> takes in: old < version <= new, oldest
# first. Pre-releases are skipped unless <new> is one itself.
releases_between() {
  local name=$1 old=$2 new=$3
  {
    if [[ $new =~ [A-Za-z] ]]; then
      published_versions "$name"
    else
      published_versions "$name" | grep -vE '^[^ ]*[A-Za-z]' || true
    fi
    printf '%s __OLD__\n%s __NEW__\n' "$old" "$new"
  } | awk '!seen[$1 FS ($2 ~ /^__/ ? $2 : "")]++' | sort -V -s -k1,1 | awk -v old="$old" -v new="$new" '
    $2 == "__OLD__" { after = 1; next }
    $2 == "__NEW__" { exit }
    after && $1 != old { print; if ($1 == new) exit }
  ' || true
}

# The GitHub release of <version> as one JSON object. Tags come in many shapes
# (v1.2.3, 1.2.3, rubocop-v1.2.3, @scope/pkg@1.2.3), so any tag that ends in the
# version matches, preferring one that names the package.
github_release() {
  local repo=$1 name=$2 version=$3
  github_api "repos/${repo}/releases?per_page=100" | jq -c --arg v "$version" --arg n "${name##*/}" '
    [ if type == "array" then .[] else empty end
      | select(.draft | not)
      | select(.tag_name | test("(^|[^0-9A-Za-z.])v?" + ($v | gsub("[.]"; "[.]")) + "$")) ]
    | ((map(select(.tag_name | ascii_downcase | contains($n | ascii_downcase))) | first) // first) // empty
    | {tag: .tag_name, url: .html_url, date: ((.published_at // "")[0:10]), body: (.body // "")}
  ' 2>/dev/null || true
}

clean() {
  local description sentence
  description=$(tr -d '\r' <<<"$1" | tr '\n\t' '  ' | sed -E 's/ +/ /g; s/^ +//; s/ +$//; s/\|/\\|/g')
  if [[ $description == *'. '* ]]; then
    sentence="${description%%. *}."
    if [ "${#sentence}" -ge 20 ]; then
      description=$sentence
    fi
  fi
  if [ "${#description}" -gt 200 ]; then
    description="$(sed -E 's/ +$//' <<<"${description:0:197}")..."
  fi
  if [[ -n $description && $description != *. ]]; then
    description+="."
  fi
  printf '%s' "$description"
}

level() {
  local old new i
  local -a olds news
  IFS=. read -ra olds <<<"$1"
  IFS=. read -ra news <<<"$2"
  for ((i = 0; i < ${#olds[@]} || i < ${#news[@]}; i++)); do
    old=${olds[i]:-0}
    new=${news[i]:-0}
    if [ "$old" != "$new" ]; then
      case $i in
        0) printf 'Major-level update' ;;
        1) printf 'Minor-level update' ;;
        *) printf 'Patch-level update' ;;
      esac
      return
    fi
  done
  printf 'Patch-level update'
}

declare -A before=() after=() req_before=() req_after=() direct=()

while IFS= read -r line; do
  requirement=''
  case $ecosystem in
    pip)
      [[ $line =~ ^([+-])([A-Za-z0-9][A-Za-z0-9._-]*)==([^[:space:]]+)$ ]] || continue
      ;;
    gem)
      # 4-space indent: resolved versions in the specs section. 2-space indent:
      # version requirements in the DEPENDENCIES section (mirrors the Gemfile).
      if [[ $line =~ ^([+-])\ {4}([^\ ]+)\ \(([0-9][^\)]*)\)$ ]]; then
        :
      elif [[ $line =~ ^([+-])\ \ ([^\ ]+)\ \(([^\)]+)\)$ ]]; then
        requirement=1
      else
        continue
      fi
      ;;
    *)
      # The name holds no whitespace and no colon. Inside `snapshots:` a
      # package's own dependencies sit one level deeper, and an aliased one
      # reads `react-is-18: react-is@18.3.1`, which a laxer name pattern reads
      # as a package called `    react-is-18: react-is` and links to a registry
      # URL that does not exist. Such an alias moves without the aliased package
      # changing at all: jest 30.5.1 renamed `react-is-18` to
      # `'@jest/react-is-18'` while react-is itself stayed on 18.3.1.
      [[ $line == *'('* ]] && continue
      [[ $line =~ ^([+-])\ \ \'?([^[:space:]\':]+)@([0-9][^\':]*)\'?:?$ ]] || continue
      ;;
  esac
  if [ -n "$requirement" ]; then
    if [ "${BASH_REMATCH[1]}" = '-' ]; then
      req_before[${BASH_REMATCH[2]}]=${BASH_REMATCH[3]}
    else
      req_after[${BASH_REMATCH[2]}]=${BASH_REMATCH[3]}
    fi
  elif [ "${BASH_REMATCH[1]}" = '-' ]; then
    before[${BASH_REMATCH[2]}]=${BASH_REMATCH[3]}
  else
    after[${BASH_REMATCH[2]}]=${BASH_REMATCH[3]}
  fi
done < <(git diff --unified=0 -- "$lockfile")

# bundler and pnpm versions live outside the dependency stanzas parsed above:
# bundler in the lockfile's BUNDLED WITH section and pnpm in the manifest's
# packageManager field. pip needs no extra handling here because it is a
# regular requirements.lock entry.
bundled_with() {
  awk 'prev == "BUNDLED WITH" { print $1; exit } { prev = $0 }'
}

pinned_pnpm() {
  jq -r '.packageManager // empty' 2>/dev/null | sed -E 's/^[^@]+@//; s/\+.*$//'
}

manager_before=''
manager_after=''
case $ecosystem in
  pip)
    manager=pip
    ;;
  gem)
    manager=bundler
    if head_file=$(git show "HEAD:$lockfile" 2>/dev/null); then
      manager_before=$(bundled_with <<<"$head_file" || true)
      manager_after=$(bundled_with < "$lockfile" || true)
    fi
    ;;
  *)
    manager=pnpm
    if head_file=$(git show "HEAD:$manifest" 2>/dev/null); then
      manager_before=$(pinned_pnpm <<<"$head_file" || true)
      manager_after=$(pinned_pnpm < "$manifest" || true)
    fi
    ;;
esac
if [ "$manager_before" != "$manager_after" ]; then
  if [ -n "$manager_before" ]; then before[$manager]=$manager_before; fi
  if [ -n "$manager_after" ]; then after[$manager]=$manager_after; fi
fi

# Mirror the versions into the copies written for humans: the Environment
# section of the README.md files that document this application (see
# documented_paths) and the `description` field of its package.json. They are
# read from the files on disk rather than from the diff above, so a copy that
# drifted in an earlier run is corrected too even when today's run upgrades
# nothing. Only a fully numeric version is rewritten,
# leaving a deliberate range such as `- pip 26.x` alone. Everything logged here
# goes to stderr: stdout is captured verbatim into the pull request body.
current_manager_version() {
  case $ecosystem in
    # pip appends itself to requirements.lock as a regular `pip==X.Y.Z` entry.
    pip) sed -nE 's/^pip==([0-9][^[:space:]]*)$/\1/p' "$lockfile" 2>/dev/null | tail -n 1 ;;
    gem) bundled_with < "$lockfile" 2>/dev/null ;;
    *)   pinned_pnpm < "$manifest" 2>/dev/null ;;
  esac
}

# READMEs spell bundler two ways, `- Gemfile X.Y.Z` and `- Bundler X.Y.Z`, and
# both are fed from BUNDLED WITH. `- Gemfile` could be read as the RubyGems
# version instead -- `gem --version` and `bundle --version` agree today -- but
# BUNDLED WITH is the reading to keep: the two labels were introduced in a single
# commit holding a single value and have never diverged in any repository, and
# RubyGems' own version is recorded in no file in the repository. Sourcing one
# label from the ambient `gem --version` would make the README depend on whichever
# toolchain last ran this script, so a developer on an older RubyGems would
# quietly revise the documented version downwards. If the two ever do need to be
# told apart, give RubyGems its own label rather than overloading this one.
documented_labels() {
  case $ecosystem in
    pip) printf '%s\n' pip ;;
    gem) printf '%s\n' Gemfile Bundler ;;
    *)   printf '%s\n' pnpm ;;
  esac
}

# Every resolved dependency version in the lockfile, as `<name> <version>` pairs.
# A README documents only a handful of them -- Rails, and nothing else so far --
# and mirror_dependencies below rewrites exactly those.
lockfile_versions() {
  case $ecosystem in
    pip) sed -nE 's/^([A-Za-z0-9][A-Za-z0-9._-]*)==([0-9]+(\.[0-9]+)*)$/\1 \2/p' "$lockfile" ;;
    gem) sed -nE 's/^    ([A-Za-z0-9._-]+) \(([0-9]+(\.[0-9]+)*)\)$/\1 \2/p' "$lockfile" ;;
    # A pnpm-lock.yaml holds no dependency that any README documents; pnpm
    # itself is mirrored as the package manager above.
    *)   : ;;
  esac
}

# A dependency name may carry regex metacharacters (`zope.interface`), so escape
# it before it is spliced into the sed script below.
escape_regex() { printf '%s' "$1" | sed -E 's|[][\.*^$(){}?+/]|\\&|g'; }

# The files that document this application: the ones in the lockfile's own
# directory and in every directory above it, up to the repository root. Scoping
# the mirror this way keeps a multi-application repository honest -- the Python
# application never rewrites the Ruby on Rails README's `- Docker` line, and two
# applications sitting on different Bundler versions stop overwriting each other
# in a shared Environment section.
documented_paths() {
  local name dir
  for name in "$@"; do
    dir=$(dirname "$lockfile")
    while [ -n "$dir" ] && [ "$dir" != '.' ] && [ "$dir" != '/' ]; do
      printf '%s/%s\n' "$dir" "$name"
      dir=$(dirname "$dir")
    done
    printf '%s\n' "$name"
  done
}

# Applies the sed expressions built by the two mirrors below to every file named
# by documented_paths, and reports the ones it actually changed.
# --others --exclude-standard picks up a README that is not committed yet while
# still honouring .gitignore, so node_modules and vendor stay out.
rewrite() {
  local reason=$1 spec file tmp
  shift
  local -a pathspecs=()
  while IFS= read -r spec; do
    pathspecs+=("$spec")
  done < <(documented_paths "$@")

  while IFS= read -r file; do
    [ -f "$file" ] || continue
    tmp=$(mktemp)
    sed -E "${expressions[@]}" "$file" > "$tmp"
    if cmp -s "$file" "$tmp"; then
      rm -f "$tmp"
    else
      cat "$tmp" > "$file"
      rm -f "$tmp"
      printf 'Mirrored %s to %s\n' "$reason" "$file" >&2
    fi
  done < <(git ls-files --cached --others --exclude-standard -- "${pathspecs[@]}" 2>/dev/null | sort -u)
}

mirror() {
  local version=$1 label
  expressions=()
  while IFS= read -r label; do
    # `- <label> <version>` bullet in a README's Environment section. The trailing
    # run is captured and replayed rather than dropped, so a CRLF line keeps its
    # carriage return and a markdown `  ` line break survives untouched.
    expressions+=(-e "s/^([[:space:]]*[-*][[:space:]]+${label}[[:space:]]+)(v?)[0-9]+(\.[0-9]+)*([[:space:]]*)\$/\1\2${version}\4/")
    # ... and `* <label> <version>` inside a package.json description. Anchoring
    # on the description key keeps the packageManager pin (`pnpm@X.Y.Z+sha512.`)
    # and the dependencies untouched.
    expressions+=(-e "/\"description\"[[:space:]]*:/ s/(${label}[[:space:]]+)(v?)[0-9]+(\.[0-9]+)*/\1\2${version}/g")
  done < <(documented_labels)
  rewrite "$manager $version" README.md package.json
}

mirror_dependencies() {
  local name version
  expressions=()
  while read -r name version _; do
    [ -n "${name:-}" ] && [ -n "${version:-}" ] || continue
    # Confined to the Environment section, because a dependency name is far
    # likelier than a package manager's to turn up in prose or in the sample
    # output a README quotes. Matched case-insensitively so the gem `rails`
    # rewrites the bullet `- Rails 8.1.2` and leaves its capitalisation alone.
    expressions+=(-e "/^#+ .*Environment[[:space:]]*\$/,/^#+ /{
      s/^([[:space:]]*[-*][[:space:]]+$(escape_regex "$name")[[:space:]]+)(v?)[0-9]+(\.[0-9]+)*([[:space:]]*)\$/\1\2${version}\4/I
    }")
    name=''
    version=''
  done < <(lockfile_versions)
  [ ${#expressions[@]} -gt 0 ] || return 0
  rewrite "the resolved ${ecosystem} versions" README.md
}

manager_version=$(current_manager_version || true)
if [ -n "$manager_version" ]; then
  mirror "$manager_version"
fi
mirror_dependencies

# Package names as the manifest, the lockfile and the dependency graph all spell
# them: PyPI treats `-`, `_` and `.` alike and ignores case.
key() {
  if [ "$ecosystem" = 'pip' ]; then
    tr 'A-Z_.' 'a-z--' <<<"$1"
  else
    printf '%s\n' "$1"
  fi
}

if [ -f "$manifest" ]; then
  case $ecosystem in
    pip)
      while IFS= read -r name; do
        direct[$name]=1
      done < <(sed -nE 's/^([A-Za-z0-9][A-Za-z0-9._-]*).*/\1/p' "$manifest" | tr 'A-Z_.' 'a-z--')
      ;;
    gem)
      while IFS= read -r name; do
        direct[$name]=1
      done < <(sed -nE "s/^[[:space:]]*gem ['\"]([^'\"]+)['\"].*/\1/p" "$manifest")
      ;;
    *)
      while IFS= read -r name; do
        direct[$name]=1
      done < <(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$manifest" 2>/dev/null | tr -d '\r' || true)
      ;;
  esac
fi

# `<parent> <child>` for every edge of the resolved dependency tree, which tells
# why a transitive dependency moved and draws the dependency graph.
dependency_edges() {
  case $ecosystem in
    pip)
      # requirements.lock is flat, so ask the environment the workflow has just
      # installed it into.
      command -v python3 > /dev/null || return 0
      python3 -c '
import re
from importlib.metadata import distributions

def key(name):
    return re.sub(r"[-_.]+", "-", name).lower()

for dist in distributions():
    parent = key(dist.metadata["Name"] or "")
    for requirement in dist.requires or []:
        if "extra ==" in requirement:
            continue
        match = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", requirement)
        if parent and match:
            print(parent, key(match.group(1)))
' 2>/dev/null || true
      ;;
    gem)
      # A spec sits at four spaces and each of its dependencies at six.
      awk '
        /^[A-Z]/ { section = $0 }
        section !~ /^(GEM|PATH|GIT)$/ { next }
        /^    [^ ]/ { parent = $1; next }
        /^      [^ ]/ { print parent, $1 }
      ' "$lockfile" 2>/dev/null || true
      ;;
    *)
      # Under `snapshots:`, `  name@version(peers):` is followed by its
      # dependency maps, whose entries sit at six spaces.
      awk '
        /^[^ ]/ { section = $0; next }
        section != "snapshots:" { next }
        /^  [^ ]/ {
          parent = $0
          sub(/^  /, "", parent); gsub(/\047/, "", parent); sub(/\(.*$/, "", parent); sub(/:$/, "", parent)
          sub(/@[^@]*$/, "", parent)
          next
        }
        /^      [^ ]/ {
          child = $1; gsub(/\047/, "", child); sub(/:$/, "", child)
          print parent, child
        }
      ' "$lockfile" 2>/dev/null || true
      ;;
  esac
}

declare -A parents=()
while read -r parent child _; do
  if [ -n "${parent:-}" ] && [ -n "${child:-}" ] && [ "$parent" != "$child" ]; then
    parents[$child]+=" $parent"
  fi
  parent=''
  child=''
done < <(dependency_edges)

required_by() {
  local p
  for p in ${parents[$(key "$1")]:-}; do
    printf '%s\n' "$p"
  done | sort -u
}

kind_of() {
  if [ "$1" = "$manager" ]; then
    echo manager
  elif [ -n "${direct[$(key "$1")]:-}" ]; then
    echo direct
  else
    echo transitive
  fi
}

level_class() {
  case $1 in
    Major*) echo major ;;
    Minor*) echo minor ;;
    Patch*) echo patch ;;
    Newly*) echo added ;;
    Removed) echo removed ;;
    *) echo requirement ;;
  esac
}

registry_url() {
  case $ecosystem in
    pip) printf 'https://pypi.org/project/%s/' "$(key "$1")" ;;
    gem) printf 'https://rubygems.org/gems/%s' "$1" ;;
    *)   printf 'https://www.npmjs.com/package/%s' "$1" ;;
  esac
}

# Joins its arguments as `a`, `b` and `c`.
code_list() {
  local out='' i
  local -a items=("$@")
  for ((i = 0; i < ${#items[@]}; i++)); do
    if ((i > 0)); then
      if ((i == ${#items[@]} - 1)); then out+=' and '; else out+=', '; fi
    fi
    out+="\`${items[i]}\`"
  done
  printf '%s' "$out"
}

common_prefix() {
  awk 'NR == 1 { p = $0; next } { while (index($0, p) != 1) p = substr(p, 1, length(p) - 1) } END { print p }'
}

# Every changed dependency with its versions and the kind of change.
declare -A entry_old=() entry_new=() entry_what=()
names=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  old=${before[$name]:-}
  new=${after[$name]:-}
  if [ "$old" != "$new" ]; then
    if [ -n "$old" ] && [ -n "$new" ]; then
      what=$(level "$old" "$new")
    elif [ -n "$new" ]; then
      what='Newly added'
    else
      what='Removed'
    fi
  else
    # No resolved-version change: report a requirement-only change (gem), e.g.
    # the lockfile's DEPENDENCIES section catching up with the Gemfile.
    old=${req_before[$name]:-}
    new=${req_after[$name]:-}
    [ "$old" = "$new" ] && continue
    what='Version requirement update'
  fi
  names+=("$name")
  entry_old[$name]=$old
  entry_new[$name]=$new
  entry_what[$name]=$what
done < <(printf '%s\n' "${!before[@]}" "${!after[@]}" "${!req_before[@]}" "${!req_after[@]}" | sort -fu)

# Transitive packages of one scope that move between the same two versions
# (platform builds such as `@pnpm/exe.linux-x64`) collapse into one row.
declare -A group_of=() group_members=() group_size=() group_name=()
for name in "${names[@]}"; do
  [[ $name == @*/* ]] && [ "$(kind_of "$name")" = transitive ] || continue
  group="${name%%/*} ${entry_old[$name]} ${entry_new[$name]} ${entry_what[$name]}"
  group_of[$name]=$group
  group_members[$group]+="${name}"$'\n'
  group_size[$group]=$(( ${group_size[$group]:-0} + 1 ))
done
for group in "${!group_size[@]}"; do
  if [ "${group_size[$group]}" -ge 3 ]; then
    group_name[$group]="$(printf '%s' "${group_members[$group]}" | common_prefix)*"
  fi
done

# The node of the dependency graph a package is drawn as: a grouped package
# shares its group's node.
declare -A node_of=() node_label=() node_class=()
for name in "${names[@]}"; do
  k=$(key "$name")
  group=${group_of[$name]:-}
  if [ -n "$group" ] && [ -n "${group_name[$group]:-}" ]; then
    node=${group_name[$group]}
    node_of[$k]=$node
    [ -n "${node_label[$node]:-}" ] && continue
    node_label[$node]="${node} ×${group_size[$group]}"
  else
    node=$k
    node_of[$k]=$k
    node_label[$k]=$name
  fi
  node_label[$node]+="<br/>${entry_old[$name]:-none} → ${entry_new[$name]:-none}"
  node_class[$node]=$(level_class "${entry_what[$name]}")
done

notes_md=''
notes_budget=${DEPENDENCY_REPORT_NOTES_BUDGET:-12000}
notes_skipped=()
lookup_limit=${DEPENDENCY_REPORT_LOOKUP_LIMIT:-40}
lookups=0
manifest_name=$(basename "$manifest")
lockfile_name=$(basename "$lockfile")

# Fills $cell with what changed compared with the previous version, and queues
# the release notes of a declared dependency for the collapsible section.
build_cell() {
  local name=$1 old=$2 new=$3 what=$4 kind=$5 members=${6:-}
  local description repo changelog version date rel url tag i count body text
  local new_url='' new_tag='' old_tag='' bodies='' block='' summary=''
  local -a releases=() requirers=() found=() links=() picks=()

  cell="**${what}.**"
  if [ "$what" = 'Version requirement update' ]; then
    cell+=" The \`DEPENDENCIES\` section of \`${lockfile_name}\` now records the requirement written in \`${manifest_name}\`; the resolved version of the gem does not change."
    return
  fi

  case $kind in
    manager) cell+=' Package manager.' ;;
    direct)  cell+=" Direct dependency declared in \`${manifest_name}\`." ;;
    *)
      if [ -n "$members" ]; then
        mapfile -t requirers < <(sed -E 's#^[^/]+/##' <<<"$members")
        cell+=" ${#requirers[@]} packages of one scope moving in lockstep: $(code_list "${requirers[@]}")."
        mapfile -t requirers < <(required_by "${members%%$'\n'*}")
      else
        mapfile -t requirers < <(required_by "$name")
      fi
      if [ -z "$new" ]; then
        cell+=' Transitive dependency that nothing requires any more.'
      elif [ ${#requirers[@]} -gt 3 ]; then
        text=$(printf '`%s`, ' "${requirers[@]:0:3}")
        cell+=" Transitive dependency, required by ${text}and $(( ${#requirers[@]} - 3 )) more."
      elif [ ${#requirers[@]} -gt 0 ]; then
        cell+=" Transitive dependency, required by $(code_list "${requirers[@]}")."
      else
        cell+=' Transitive dependency.'
      fi
      ;;
  esac

  description=$(clean "$(describe "$name")")
  [ -n "$description" ] && cell+="<br />${description}"
  [ -n "$new" ] || return 0

  if ((lookups >= lookup_limit)); then
    cell+="<br />_Release details skipped: more than ${lookup_limit} packages changed._"
    return
  fi
  lookups=$((lookups + 1))

  repo=$(source_repository "$name")
  changelog=$(changelog_url "$name")
  if [ -n "$old" ]; then
    mapfile -t releases < <(releases_between "$name" "$old" "$new")
  fi
  [ ${#releases[@]} -gt 0 ] || releases=("$new -")
  count=${#releases[@]}

  # Newest first, at most ten releases: their dates, highlights and notes.
  for ((i = count - 1; i >= 0 && i >= count - 10; i--)); do
    read -r version date _ <<<"${releases[i]}"
    rel=''
    [ -n "$repo" ] && rel=$(github_release "$repo" "$name" "$version")
    if [ -n "$rel" ]; then
      url=$(jq -r '.url' <<<"$rel")
      tag=$(jq -r '.tag' <<<"$rel")
      [ "${date:--}" = '-' ] && date=$(jq -r '.date' <<<"$rel")
      body=$(jq -r '.body' <<<"$rel")
      if [ "$version" = "$new" ]; then
        new_url=$url
        new_tag=$tag
      fi
      bodies+="${body}"$'\n'
      block+=$'\n'"**[${tag}](${url})**${date:+ (${date})}"$'\n\n'
      block+="$(release_notes_markdown "$repo" <<<"$body")"$'\n'
    fi
    releases[i]="${version} ${date:--}"
  done

  for ((i = 0; i < count; i++)); do
    read -r version date _ <<<"${releases[i]}"
    if [ "${date:--}" = '-' ]; then
      found+=("\`${version}\`")
    else
      found+=("\`${version}\` (${date})")
    fi
  done
  if ((count > 4)); then
    text="${found[0]} … ${found[count - 1]}"
  else
    text=$(printf '%s, ' "${found[@]}")
    text=${text%, }
  fi
  if [ -n "$old" ]; then
    cell+="<br />**Includes ${count} release$([ "$count" -eq 1 ] || printf s):** ${text}."
  else
    cell+="<br />**Release:** ${text}."
  fi

  mapfile -t picks < <(printf '%s' "$bodies" | highlights | awk '!seen[$0]++')
  if [ ${#picks[@]} -gt 0 ]; then
    cell+="<br />**What's new:**"
    for ((i = 0; i < ${#picks[@]} && i < 3; i++)); do
      cell+="<br />• ${picks[i]}"
    done
    if [ ${#picks[@]} -gt 3 ]; then
      cell+="<br />• … and $(( ${#picks[@]} - 3 )) more in the release notes."
    fi
  elif [ -n "$repo" ]; then
    cell+="<br />**What's new:** no GitHub release notes are published for $([ "$count" -eq 1 ] && echo 'this version' || echo 'these versions'); see the links below."
  fi

  [ -n "$new_url" ] && links+=("[Release notes](${new_url})")
  if [ -n "$repo" ] && [ -n "$old" ] && [ -n "$new_tag" ]; then
    old_tag=$(github_release "$repo" "$name" "$old" | jq -r '.tag // empty' 2>/dev/null || true)
    [ -n "$old_tag" ] || old_tag=${new_tag/$new/$old}
    links+=("[Compare \`${old_tag}...${new_tag}\`](https://github.com/${repo}/compare/${old_tag}...${new_tag})")
  fi
  [ -n "$changelog" ] && [ "$changelog" != "$new_url" ] && links+=("[Changelog](${changelog})")
  [ -n "$repo" ] && [ ${#links[@]} -eq 0 ] && links+=("[Repository](https://github.com/${repo})")
  if [ ${#links[@]} -gt 0 ]; then
    text=$(printf '%s · ' "${links[@]}")
    cell+="<br />${text% · }"
  fi

  # Full notes of the declared dependencies, while the budget lasts.
  if [ -n "$block" ] && [ "$kind" != transitive ]; then
    summary="<details>"$'\n'"<summary><code>${name}</code> ${old:-none} → ${new}</summary>"$'\n'"${block}"$'\n'"</details>"$'\n'
    if (( ${#notes_md} + ${#summary} <= notes_budget )); then
      notes_md+=$summary
    else
      notes_skipped+=("$name")
    fi
  fi
}

rows=''
declare -A level_count=()
for name in "${names[@]}"; do
  old=${entry_old[$name]}
  new=${entry_new[$name]}
  what=${entry_what[$name]}
  class=$(level_class "$what")
  level_count[$class]=$(( ${level_count[$class]:-0} + 1 ))
  group=${group_of[$name]:-}
  members=''
  display=$name
  if [ -n "$group" ] && [ -n "${group_name[$group]:-}" ]; then
    # Only the first member of a group prints the group's row.
    [ "${group_members[$group]%%$'\n'*}" = "$name" ] || continue
    members=${group_members[$group]%$'\n'}
    display=${group_name[$group]}
  fi
  build_cell "$name" "$old" "$new" "$what" "$(kind_of "$name")" "$members"
  old_cell=${old:+\`$old\`}
  new_cell=${new:+\`$new\`}
  rows+="|[\`${display}\`]($(registry_url "$name")) |${old_cell:--} |${new_cell:--} |${cell} |"$'\n'
done

# Mermaid flowchart from each declared dependency down to every updated package
# it pulls in, along the shortest path through the resolved tree.
declare -A edge=()
add_edge() {
  local from=${node_of[$1]:-$1} to=${node_of[$2]:-$2}
  [ "$from" != "$to" ] || return 0
  edge["${from} ${to}"]=1
  if [ -z "${node_label[$from]:-}" ]; then
    node_label[$from]=$from
    node_class[$from]=context
  fi
  if [ -z "${node_label[$to]:-}" ]; then
    node_label[$to]=$to
    node_class[$to]=context
  fi
}

for name in "${names[@]}"; do
  [ "$(kind_of "$name")" = transitive ] && [ -n "${entry_new[$name]}" ] || continue
  k=$(key "$name")
  unset seen prev
  declare -A seen=(["$k"]=1) prev=()
  queue=("$k")
  head=0
  found=''
  while ((head < ${#queue[@]})) && [ -z "$found" ] && ((head < 2000)); do
    current=${queue[head]}
    head=$((head + 1))
    for p in ${parents[$current]:-}; do
      [ -z "${seen[$p]:-}" ] || continue
      seen[$p]=1
      prev[$p]=$current
      if [ -n "${direct[$p]:-}" ] || [ "$p" = "$manager" ]; then
        found=$p
        break
      fi
      queue+=("$p")
    done
  done
  if [ -n "$found" ]; then
    p=$found
    while [ "$p" != "$k" ]; do
      add_edge "$p" "${prev[$p]}"
      p=${prev[$p]}
    done
  else
    for p in ${parents[$k]:-}; do
      add_edge "$p" "$k"
      break
    done
  fi
done

graph=''
if [ ${#edge[@]} -gt 0 ] && [ ${#node_label[@]} -le 60 ]; then
  declare -A node_id=()
  n=0
  graph+='flowchart LR'$'\n'
  while IFS= read -r node; do
    n=$((n + 1))
    node_id[$node]="n${n}"
    graph+="  n${n}[\"${node_label[$node]//\"/#quot;}\"]:::${node_class[$node]}"$'\n'
  done < <(printf '%s\n' "${!node_label[@]}" | sort)
  while read -r from to; do
    graph+="  ${node_id[$from]} --> ${node_id[$to]}"$'\n'
  done < <(printf '%s\n' "${!edge[@]}" | sort)
  graph+='  classDef major fill:#ffebe9,stroke:#cf222e,color:#1f2328'$'\n'
  graph+='  classDef minor fill:#fff8c5,stroke:#9a6700,color:#1f2328'$'\n'
  graph+='  classDef patch fill:#dafbe1,stroke:#1a7f37,color:#1f2328'$'\n'
  graph+='  classDef added fill:#ddf4ff,stroke:#0969da,color:#1f2328'$'\n'
  graph+='  classDef removed fill:#f6f8fa,stroke:#6e7781,stroke-dasharray:4 3,color:#1f2328'$'\n'
  graph+='  classDef requirement fill:#fbefff,stroke:#8250df,color:#1f2328'$'\n'
  graph+='  classDef context fill:#ffffff,stroke:#d0d7de,color:#57606a'$'\n'
fi

echo "|${label} |Before |After |Changes & Differences |"
echo '|:-|:-|:-|:-|'
if [ -n "$rows" ]; then
  printf '%s' "$rows"
else
  echo '| | | |No dependency changes detected |'
fi

if [ -n "$graph" ]; then
  echo
  echo "**Dependency graph**: how each updated package is reached from the dependencies declared in \`${manifest_name}\`, along the shortest path through \`${lockfile_name}\` (an arrow points from a package to a dependency it requires).  "
  echo
  echo '```mermaid'
  printf '%s' "$graph"
  echo '```'
  echo
  echo '🟥 Major · 🟨 Minor · 🟩 Patch · 🟦 Newly added · ⬜ Removed, or unchanged on the path  '
fi

if [ ${#names[@]} -ge 3 ]; then
  categories=''
  counts=''
  max=1
  for class in major minor patch added removed requirement; do
    c=${level_count[$class]:-0}
    [ "$c" -gt 0 ] || continue
    case $class in
      major) title=Major ;;
      minor) title=Minor ;;
      patch) title=Patch ;;
      added) title='Newly added' ;;
      removed) title=Removed ;;
      *) title=Requirement ;;
    esac
    categories+="\"${title}\", "
    counts+="${c}, "
    [ "$c" -gt "$max" ] && max=$c
  done
  echo
  echo "**Updates by semver level**: ${#names[@]} changed packages.  "
  echo
  echo '```mermaid'
  echo 'xychart-beta'
  echo "  x-axis [${categories%, }]"
  echo "  y-axis \"Packages\" 0 --> ${max}"
  echo "  bar [${counts%, }]"
  echo '```'
fi

if [ -n "$notes_md" ]; then
  echo
  echo '**Release notes of the declared dependencies**'
  echo
  printf '%s' "$notes_md"
  if [ ${#notes_skipped[@]} -gt 0 ]; then
    echo
    echo "_Left out to keep the description within GitHub's size limit: $(code_list "${notes_skipped[@]}"). Follow the links in the table._"
  fi
fi
