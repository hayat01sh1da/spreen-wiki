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
# The pull request description spells out what changed rather than only listing
# files: for every file, the exact lines that were rewritten (with line numbers)
# and what that copy of the version controls, plus a Mermaid diagram of the bump
# fanning out to them; for the runtime itself, every release the bump takes in
# (date, security flag, size), Node.js's bundled components (npm, V8, libuv,
# OpenSSL, zlib) before and after, the highlights of the release notes, and a
# Mermaid histogram of the changes by subsystem or area. Release notes are
# quoted through release_notes.sh; GitHub API calls use $GH_TOKEN (or
# $GITHUB_TOKEN) when it is set, and a lookup that fails only leaves its part of
# the description out.
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

# shellcheck source=release_notes.sh
source "$(dirname "${BASH_SOURCE[0]}")/release_notes.sh"

github_token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
github_api() {
  local -a headers=(-H 'Accept: application/vnd.github+json')
  if [[ -n $github_token ]]; then
    headers+=(-H "Authorization: Bearer ${github_token}")
  fi
  curl -fsSL --max-time 30 "${headers[@]}" "https://api.github.com/$1" 2>/dev/null || true
}

case $runtime in
  ruby)
    series='minor series'
    setup_action=ruby/setup-ruby
    managers='rbenv, asdf or mise'
    notes="https://github.com/ruby/ruby/releases/tag/v$( ((major >= 4)) && echo "$new" || echo "${new//./_}")"
    ;;
  python)
    series='minor series'
    setup_action=actions/setup-python
    managers='pyenv, asdf or mise'
    notes="https://docs.python.org/release/${new}/whatsnew/changelog.html"
    ;;
  node)
    series='major line'
    setup_action=actions/setup-node
    managers='nodenv, fnm or mise'
    notes="https://nodejs.org/en/blog/release/v${new}"
    ;;
esac
shown_old="${v_prefix}${old}"
shown_new="${v_prefix}${new}"

# --- What each rewritten copy of the version is for --------------------------

# Every line the bump rewrote in <path>, as `<line>\t<before>\t<after>`. The
# rewrite only ever replaces a version inside a line, so removed and added
# lines pair up one to one within each hunk.
changed_lines() {
  git diff --unified=0 --no-color -- "$1" | awk '
    /^@@/ { split($3, a, ","); line = substr(a[1], 2) + 0; i = 0; j = 0; hunk = 1; next }
    !hunk { next }
    /^-/ { old[i++] = substr($0, 2); next }
    /^\+/ { printf "%d\t%s\t%s\n", line + j, old[j], substr($0, 2); j++ }
  '
}

# `<category>\t<what the copy controls>` for a rewritten line of <path>.
file_role() {
  local path=$1 line=$2 base
  base=$(basename "$path")
  case $base in
    "$version_file")
      printf 'Version pin\tThe pinned version: %s installs it in CI and %s switch to it locally. Every other copy follows it.' "$setup_action" "$managers"
      ;;
    action.yml | action.yaml)
      printf 'Action runtime\tThe `%s-version` input the composite action passes to %s, so every workflow that uses the action runs on %s %s.' "$runtime" "$setup_action" "$name" "$shown_new"
      ;;
    Dockerfile.production)
      printf 'Container image\tBase image or build argument of the production image deployed with Kamal; the next deploy runs on %s %s.' "$name" "$shown_new"
      ;;
    Dockerfile*)
      printf 'Container image\tBase image or build argument of the development image; containers run %s %s once the image is rebuilt.' "$name" "$shown_new"
      ;;
    Gemfile.lock)
      printf 'Lockfile\tThe `RUBY VERSION` that Bundler records, kept equal to the interpreter so `bundle install` reports no mismatch.'
      ;;
    package.json)
      if [[ $line == *'"engines"'* || $line =~ \"node\"[[:space:]]*: ]]; then
        printf 'Package metadata\t`engines.node`: package managers now expect %s %s.' "$name" "$shown_new"
      else
        printf 'Package metadata\tThe `description` field, which documents the runtime the package is developed on.'
      fi
      ;;
    SECURITY.md)
      printf 'Documentation\tThe supported-versions table now names %s %s; its columns are re-padded so the table stays aligned.' "$name" "$shown_new"
      ;;
    *.md)
      if [[ $line =~ platform[[:space:]].*--[[:space:]]Python ]]; then
        printf 'Documentation\tSample test output quoted in the README, kept equal to what a test run prints now.'
      elif [[ $line =~ ^[[:space:]]*[-*][[:space:]] ]]; then
        printf 'Documentation\tThe Environment section that tells readers which runtime to install.'
      else
        printf 'Documentation\tA documented copy of the version.'
      fi
      ;;
    *)
      printf 'Other\tA copy of the version kept equal to the pin.'
      ;;
  esac
}

# Part of a line, from character <start>, as an inline code span that survives a
# table cell.
code_span() {
  local text=$1 start=$2 prefix='' suffix=''
  if ((start > 0)); then
    text=${text:start}
    prefix='…'
  fi
  if ((${#text} > 90)); then
    text=${text:0:87}
    suffix='…'
  fi
  text="${prefix}${text}${suffix}"
  text=${text//|/\\|}
  if [[ $text == *'`'* ]]; then
    printf '`` %s ``' "$text"
  else
    printf '`%s`' "$text"
  fi
}

# Sets $pair_was and $pair_now to a rewritten line before and after. A long
# line is shown from a little before its first difference, so the version that
# moved is always in view (package.json descriptions run to 200 characters).
code_pair() {
  local was now start=0 i
  was=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1")
  now=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$2")
  if ((${#was} > 90 || ${#now} > 90)); then
    for ((i = 0; i < ${#was} && i < ${#now}; i++)); do
      [[ ${was:i:1} == "${now:i:1}" ]] || break
    done
    ((i > 30)) && start=$((i - 30))
  fi
  pair_was=$(code_span "$was" "$start")
  pair_now=$(code_span "$now" "$start")
}

# "<count> <category>" as a noun phrase: 2 version pins, 1 container image.
category_phrase() {
  local count=$1 noun
  case $2 in
    'Version pin')      noun='version pin' ;;
    'Action runtime')   noun='action input' ;;
    'Container image')  noun='container image' ;;
    Lockfile)           noun='lockfile' ;;
    'Package metadata') noun='package manifest' ;;
    Documentation)      noun='documentation file' ;;
    *)                  noun='other file' ;;
  esac
  ((count == 1)) || noun+=s
  printf '%s %s' "$count" "$noun"
}

rows=''
declare -A category_files=()
declare -A category_count=()
categories=()
for path in "${touched[@]}"; do
  category=''
  # Identical rewrites (the same sample output quoted five times) share one
  # before/after pair, and every distinct role lists the lines it covers.
  pairs=()
  roles=()
  declare -A pair_count=() role_lines=()
  while IFS=$'\t' read -r number was now; do
    [[ -n $number ]] || continue
    code_pair "$was" "$now"
    pair="${pair_was}"$'\t'"${pair_now}"
    [[ -n ${pair_count[$pair]:-} ]] || pairs+=("$pair")
    pair_count[$pair]=$(( ${pair_count[$pair]:-0} + 1 ))
    IFS=$'\t' read -r line_category role < <(file_role "$path" "$now") || true
    [[ -n $category ]] || category=$line_category
    [[ -n ${role_lines[$role]:-} ]] || roles+=("$role")
    role_lines[$role]+="${number}, "
  done < <(changed_lines "$path")
  if [[ -z $category ]]; then
    IFS=$'\t' read -r category role < <(file_role "$path" '') || true
    roles=("$role")
    role_lines[$role]=''
  fi
  before_cell=''
  after_cell=''
  for pair in "${pairs[@]}"; do
    times=''
    ((pair_count[$pair] > 1)) && times=" ×${pair_count[$pair]}"
    before_cell+="${before_cell:+<br />}${pair%%$'\t'*}${times}"
    after_cell+="${after_cell:+<br />}${pair#*$'\t'}${times}"
  done
  description="**${category}**"
  for role in "${roles[@]}"; do
    where=${role_lines[$role]%, }
    if [[ -z $where ]]; then
      description+=": ${role}"
    elif [[ $where == *,* ]]; then
      description+="<br />Lines ${where}: ${role}"
    else
      description+="<br />Line ${where}: ${role}"
    fi
  done
  unset pair_count role_lines
  rows+="|\`${path}\` |${before_cell:-${shown_old}} |${after_cell:-${shown_new}} |${description} |"$'\n'
  if [[ -z ${category_count[$category]:-} ]]; then
    categories+=("$category")
  fi
  category_count[$category]=$(( ${category_count[$category]:-0} + 1 ))
  category_files[$category]+="${path}"$'\n'
done

# Mermaid flowchart: the bump fanning out to every copy, grouped by what the copy
# controls.
fan_out='flowchart LR'$'\n'
fan_out+="  bump([\"${name} ${shown_old} → ${shown_new}\"]):::bump"$'\n'
n=0
c=0
for category in "${categories[@]}"; do
  c=$((c + 1))
  fan_out+="  subgraph g${c}[\"${category}\"]"$'\n'
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    n=$((n + 1))
    fan_out+="    f${n}[\"${path}\"]"$'\n'
  done <<<"${category_files[$category]}"
  fan_out+='  end'$'\n'
  fan_out+="  bump --> g${c}"$'\n'
done
fan_out+='  classDef bump fill:#ddf4ff,stroke:#0969da,color:#1f2328'$'\n'

breakdown=''
for category in "${categories[@]}"; do
  breakdown+="$(category_phrase "${category_count[$category]}" "$category"), "
done
breakdown=${breakdown%, }

# --- What changed in the runtime itself -------------------------------------

# Every release the bump takes in: old < version <= new, oldest first.
mapfile -t releases < <(
  { series_versions || true; printf '%s\n' "$old" "$new"; } | sort -V -u |
    awk -v old="$old" -v new="$new" '$0 == old { after = 1; next } after { print } $0 == new { exit }'
)
[[ ${#releases[@]} -gt 0 ]] || releases=("$new")

release_rows=''
highlight_source=''
notes_md=''
histogram_title=''
histogram_unit=Entries
declare -A bucket=()
component_rows=''

case $runtime in
  node)
    index=$(curl -fsS --max-time 30 https://nodejs.org/dist/index.json 2>/dev/null || true)
    for version in "${releases[@]}"; do
      info=$(jq -c --arg v "v${version}" '.[] | select(.version == $v)' <<<"$index" 2>/dev/null || true)
      [[ -n $info ]] || info="{}"
      date=$(jq -r '.date // "-"' <<<"$info")
      if [[ $(jq -r '.security // false' <<<"$info") == true ]]; then
        kind='**Security release**'
      else
        kind='Regular release'
      fi
      lts=$(jq -r 'if (.lts // false) == false then "" else .lts end' <<<"$info")
      [[ -n $lts ]] && kind+=" (LTS ${lts})"
      body=$(github_api "repos/nodejs/node/releases/tags/v${version}" | jq -r '.body // empty' 2>/dev/null || true)
      commits=$(grep -cE '^\* \\\[\[' <<<"$body" || true)
      release_rows+="|[v${version}](https://nodejs.org/en/blog/release/v${version}) |${date} |${kind} |${commits:-0} |"$'\n'
      [[ -n $body ]] || continue
      # Commit lines read `* \[[`sha`](url)] - **(SEMVER-MINOR)** **subsystem**: message (author) [#n](url)`.
      notable=$(awk '/^### Notable [Cc]hanges/ { on = 1; next } /^### Commits/ { on = 0 } on' <<<"$body")
      commit_lines=$(perl -ne '
        next unless /^\* \\\[\[`[0-9a-f]+`\]\([^)]*\)\] - (\*\*\(SEMVER-(\w+)\)\*\* )?(?:_\*\*Revert\*\*_ "?)?\*\*([^*]+)\*\*: (.*?)(?: \([^()]*\))?(?: \[#\d+\]\([^)]*\))*\s*$/;
        my ($semver, $subsystem, $message) = ($2 // "-", $3, $4);
        $subsystem =~ s/\\//g;
        $subsystem =~ s/,.*//;
        print "$semver\t$subsystem\t$message\n";
      ' <<<"$body")
      while IFS=$'\t' read -r semver subsystem message; do
        [[ -n $subsystem ]] || continue
        bucket[$subsystem]=$(( ${bucket[$subsystem]:-0} + 1 ))
        case $subsystem in
          doc | test | build | tools | benchmark | meta | deps) continue ;;
        esac
        # SEMVER-MINOR commits are the new features: list them first.
        if [[ $semver == MINOR || $semver == MAJOR ]]; then
          highlight_source="- ${subsystem}: ${message}"$'\n'"${highlight_source}"
        else
          highlight_source+="- ${subsystem}: ${message}"$'\n'
        fi
      done <<<"$commit_lines"
      if [[ -n $(tr -d '[:space:]' <<<"$notable") ]]; then
        notes_md+=$'\n'"**[v${version}](https://github.com/nodejs/node/releases/tag/v${version})** notable changes (${date})"$'\n\n'
        notes_md+="$(release_notes_markdown nodejs/node <<<"$notable")"$'\n'
      fi
    done
    histogram_title='Commits by subsystem'
    histogram_unit=Commits
    # Bundled components: what else moves along with the runtime.
    for field in npm:npm v8:V8 uv:libuv openssl:OpenSSL zlib:zlib; do
      was=$(jq -r --arg v "v${old}" --arg f "${field%%:*}" '.[] | select(.version == $v) | .[$f] // empty' <<<"$index" 2>/dev/null || true)
      now=$(jq -r --arg v "v${new}" --arg f "${field%%:*}" '.[] | select(.version == $v) | .[$f] // empty' <<<"$index" 2>/dev/null || true)
      [[ -n $was || -n $now ]] || continue
      if [[ $was == "$now" ]]; then
        change='Unchanged'
      else
        change='**Updated**'
      fi
      component_rows+="|${field#*:} |\`${was:--}\` |\`${now:--}\` |${change} |"$'\n'
    done
    ;;
  ruby)
    releases_yml=$(curl -fsS --max-time 30 https://raw.githubusercontent.com/ruby/www.ruby-lang.org/master/_data/releases.yml 2>/dev/null || true)
    for version in "${releases[@]}"; do
      date=$(awk -v v="$version" '$1 == "-" && $2 == "version:" { on = ($3 == v) } on && $1 == "date:" { print $2; exit }' <<<"$releases_yml")
      release=''
      for tag in "v${version//./_}" "v${version}"; do
        release=$(github_api "repos/ruby/ruby/releases/tags/${tag}")
        [[ -n $(jq -r '.tag_name // empty' <<<"$release" 2>/dev/null) ]] && break
        release=''
      done
      [[ -n $release ]] || release="{}"
      body=$(jq -r '.body // empty' <<<"$release" 2>/dev/null || true)
      url=$(jq -r ".html_url // \"https://github.com/ruby/ruby/releases/tag/v${version//./_}\"" <<<"$release" 2>/dev/null)
      # Patch releases list their fixes as `* [Bug #n: title - Ruby - Ruby Issue Tracking System](url)`.
      entries=$(perl -ne '
        next unless /^\* \[(.+?)\]\(([^)]*)\)\s*$/;
        my $title = $1;
        $title =~ s/ - Ruby - Ruby Issue Tracking System$//;
        $title =~ s/ by [\w-]+ · Pull Request #\d+.*$//;
        $title =~ s/ · Pull Request #\d+.*$//;
        print "$title\n";
      ' <<<"$body")
      fixes=$(grep -c . <<<"$entries" || true)
      if grep -q 'CVE-' <<<"$body"; then
        kind="**Security release** ($(grep -oE 'CVE-[0-9]+-[0-9]+' <<<"$body" | sort -u | paste -sd ' ' | sed 's/ /, /g'))"
      else
        kind='Bug-fix release'
      fi
      release_rows+="|[${version}](${url}) |${date:--} |${kind} |${fixes:-0} |"$'\n'
      while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        case $entry in
          Bug\ \#*) bucket['Bug fixes']=$(( ${bucket['Bug fixes']:-0} + 1 )) ;;
          Feature\ \#*) bucket['Features']=$(( ${bucket['Features']:-0} + 1 )) ;;
          Misc\ \#*) bucket['Misc']=$(( ${bucket['Misc']:-0} + 1 )) ;;
          *[Bb]ump*) bucket['Bundled gems and libraries']=$(( ${bucket['Bundled gems and libraries']:-0} + 1 )) ;;
          *) bucket['Other pull requests']=$(( ${bucket['Other pull requests']:-0} + 1 )) ;;
        esac
        highlight_source+="- ${entry}"$'\n'
      done <<<"$entries"
      if [[ -n $body ]]; then
        notes_md+=$'\n'"**[${version}](${url})** (${date:--})"$'\n\n'
        notes_md+="$(release_notes_markdown ruby/ruby <<<"$body")"$'\n'
      fi
    done
    histogram_title='Changes by kind'
    histogram_unit=Changes
    ;;
  python)
    python_releases=$(curl -fsS --max-time 30 'https://www.python.org/api/v2/downloads/release/?is_published=true' 2>/dev/null || true)
    # The changelog of the newest release also carries every older one in its series.
    changelog=$(curl -fsS --max-time 60 "https://docs.python.org/release/${new}/whatsnew/changelog.html" 2>/dev/null |
      VERSIONS="${releases[*]}" perl -0777 -ne '
        for my $v (split " ", $ENV{VERSIONS}) {
          (my $id = "python-$v-final") =~ s/\./-/g;
          next unless /<section id="\Q$id\E">(.*?)(?=<section id="python-\d|\z)/s;
          my $section = $1;
          while ($section =~ /<h3>(.*?)<a class="headerlink".*?<\/h3>(.*?)(?=<h3>|\z)/sg) {
            my ($title, $items) = ($1, $2);
            while ($items =~ /<li><p>(.*?)<\/p>/sg) {
              my $text = $1;
              $text =~ s/<[^>]+>//g;
              $text =~ s/&lt;/</g; $text =~ s/&gt;/>/g; $text =~ s/&quot;/"/g; $text =~ s/&#39;|&#x27;/\x27/g; $text =~ s/&amp;/&/g;
              $text =~ s/\s+/ /g;
              $text =~ s/^gh-\d+:\s*//;
              print "$v\t$title\t$text\n";
            }
          }
        }
      ' || true)
    for version in "${releases[@]}"; do
      date=$(jq -r --arg n "Python ${version}" '.[] | select(.name == $n) | .release_date[0:10]' <<<"${python_releases:-[]}" 2>/dev/null | head -n 1)
      entries=$(awk -F '\t' -v v="$version" '$1 == v' <<<"$changelog")
      total=$(grep -c . <<<"$entries" || true)
      security=$(awk -F '\t' '$2 == "Security"' <<<"$entries" | grep -c . || true)
      if ((security > 0)); then
        kind="**Includes ${security} security fix$([[ $security == 1 ]] || printf es)**"
      else
        kind='Bug-fix release'
      fi
      release_rows+="|[${version}](https://docs.python.org/release/${version}/whatsnew/changelog.html#python-${version//./-}-final) |${date:--} |${kind} |${total:-0} |"$'\n'
      while IFS=$'\t' read -r _ title text; do
        [[ -n $title ]] || continue
        bucket[$title]=$(( ${bucket[$title]:-0} + 1 ))
      done <<<"$entries"
      # Security fixes first, then the core and library changes.
      highlight_source+=$(awk -F '\t' '$2 == "Security" { print "- Security: " $3 }' <<<"$entries")$'\n'
      highlight_source+=$(awk -F '\t' '$2 == "Core and Builtins" || $2 == "Library" { print "- " $3 }' <<<"$entries")$'\n'
      if ((security > 0)); then
        notes_md+=$'\n'"**[${version}](https://docs.python.org/release/${version}/whatsnew/changelog.html#python-${version//./-}-final)** security fixes (${date:--})"$'\n\n'
        notes_md+="$(awk -F '\t' '$2 == "Security" { print "- " $3 }' <<<"$entries" | release_notes_markdown python/cpython)"$'\n'
      fi
    done
    histogram_title='Changelog entries by area'
    histogram_unit=Entries
    ;;
esac

mapfile -t picks < <(printf '%s' "$highlight_source" | highlights | awk '!seen[$0]++')

# Mermaid bar chart of the buckets, largest first, the tail folded into "Other".
histogram=''
if [[ ${#bucket[@]} -gt 1 ]]; then
  labels=''
  values=''
  max=1
  other=0
  i=0
  while IFS=$'\t' read -r count title; do
    i=$((i + 1))
    if ((i > 10)); then
      other=$((other + count))
      continue
    fi
    labels+="\"${title//\"/}\", "
    values+="${count}, "
    ((count > max)) && max=$count
  done < <(for title in "${!bucket[@]}"; do printf '%s\t%s\n' "${bucket[$title]}" "$title"; done | sort -t $'\t' -k1,1nr -k2,2)
  if ((other > 0)); then
    labels+='"Other", '
    values+="${other}, "
    ((other > max)) && max=$other
  fi
  histogram+='xychart-beta horizontal'$'\n'
  histogram+="  x-axis [${labels%, }]"$'\n'
  histogram+="  y-axis \"${histogram_unit}\" 0 --> ${max}"$'\n'
  histogram+="  bar [${values%, }]"$'\n'
fi

count=${#touched[@]}
plural=s
[[ $count == 1 ]] && plural=''
release_count=${#releases[@]}
release_plural=s
[[ $release_count == 1 ]] && release_plural=''

{
  cat <<OVERVIEW
## 1. Overview

This pull request was created automatically by the ${label} - Daily Runtime Update workflow.  
It bumps ${name} from ${shown_old} to ${shown_new}, the newest release of the current ${series} that the CI setup action can install.  

Every pinned version file and every documented copy of the version (Dockerfiles, Gemfile.lock \`RUBY VERSION\`, action inputs, README Environment sections, SECURITY.md support tables, sample test output) is moved together; CHANGELOG.md history is left untouched.  

## 2. Key Changes & Differences

### 2-1. Files

Each row shows the exact lines the bump rewrote and what that copy of the version controls.  

|Files |Before |After |Changes & Differences |
|:-|:-|:-|:-|
OVERVIEW
  printf '%s' "$rows"
  cat <<FANOUT

\`\`\`mermaid
${fan_out}\`\`\`

### 2-2. ${name} ${shown_old} → ${shown_new}

The bump takes in ${release_count} release${release_plural} of the ${series}.  

FANOUT
  case $runtime in
    node) echo '|Release |Date |Kind |Commits |' ;;
    ruby) echo '|Release |Date |Kind |Listed changes |' ;;
    *)    echo '|Release |Date |Kind |Changelog entries |' ;;
  esac
  echo '|:-|:-|:-|:-|'
  printf '%s' "$release_rows"
  if [[ -n $component_rows ]]; then
    cat <<'COMPONENTS'

Components bundled with Node.js:

|Component |Before |After |Changes & Differences |
|:-|:-|:-|:-|
COMPONENTS
    printf '%s' "$component_rows"
  fi
  if [[ ${#picks[@]} -gt 0 ]]; then
    echo
    echo "What's new:"
    echo
    for ((i = 0; i < ${#picks[@]} && i < 8; i++)); do
      echo "- ${picks[i]}"
    done
    if ((${#picks[@]} > 8)); then
      echo "- … and $(( ${#picks[@]} - 8 )) more in the release notes."
    fi
  fi
  if [[ -n $histogram ]]; then
    echo
    echo "${histogram_title}:"
    echo
    echo '```mermaid'
    printf '%s' "$histogram"
    echo '```'
  fi
  if [[ -n $notes_md ]]; then
    echo
    echo '<details>'
    echo "<summary>Release notes</summary>"
    printf '%s' "$notes_md"
    echo
    echo '</details>'
  fi
  cat <<SUMMARY

## 3. Summary

${name} is bumped from ${shown_old} to ${shown_new} across ${count} file${plural} (${breakdown}), taking in ${release_count} release${release_plural}.  
Crossing into a new ${series} is intentionally left to a manual pull request, because it can require code changes.  
Please review the release notes and make sure that all CI workflows pass before merging this pull request.  

## 4. References

- [${label} - Daily Runtime Update workflow run](https://github.com/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-})
- [${name} ${shown_new} release notes](${notes})
SUMMARY
} >"$body_path"
