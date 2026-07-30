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
set -euo pipefail

ecosystem=$1
lockfile=$2
manifest=$3
label=$4

describe() {
  local name=$1 url filter
  case $ecosystem in
    pip)  url="https://pypi.org/pypi/${name}/json"           filter='.info.summary // empty' ;;
    gem)  url="https://rubygems.org/api/v1/gems/${name}.json" filter='.info // empty' ;;
    *)    url="https://registry.npmjs.org/${name}/latest"     filter='.description // empty' ;;
  esac
  curl -fsS --max-time 10 "$url" 2>/dev/null | jq -r "$filter" 2>/dev/null || true
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

declare -A before after req_before req_after direct

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
      [[ $line == *'('* ]] && continue
      [[ $line =~ ^([+-])\ \ \'?(.+)@([0-9][^\':]*)\'?:?$ ]] || continue
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

if [ -f "$manifest" ]; then
  case $ecosystem in
    pip)
      while IFS= read -r name; do
        direct[$name]=1
      done < <(sed -nE 's/^([A-Za-z0-9][A-Za-z0-9._-]*).*/\1/p' "$manifest" | tr 'A-Z_' 'a-z-')
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

rows=''
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
  description=$(clean "$(describe "$name")")
  normalised=$name
  if [ "$ecosystem" = 'pip' ]; then
    normalised=$(tr 'A-Z_' 'a-z-' <<<"$name")
  fi
  if [ "$name" = "$manager" ]; then
    kind='Package manager.'
  elif [ -n "${direct[$normalised]:-}" ]; then
    kind='Direct dependency.'
  else
    kind='Transitive dependency.'
  fi
  notes="${what}. ${description:+$description }${kind}"
  case $ecosystem in
    pip) registry_url="https://pypi.org/project/${normalised}/" ;;
    gem) registry_url="https://rubygems.org/gems/${name}" ;;
    *)   registry_url="https://www.npmjs.com/package/${name}" ;;
  esac
  old_cell=${old:+\`$old\`}
  new_cell=${new:+\`$new\`}
  rows+="|[\`${name}\`](${registry_url}) |${old_cell:--} |${new_cell:--} |${notes} |"$'\n'
done < <(printf '%s\n' "${!before[@]}" "${!after[@]}" "${!req_before[@]}" "${!req_after[@]}" | sort -fu)

echo "|${label} |Before |After |Changes & Differences |"
echo '|:-|:-|:-|:-|'
if [ -n "$rows" ]; then
  printf '%s' "$rows"
else
  echo '| | | |No dependency changes detected |'
fi
