#!/usr/bin/env bash
# Helpers shared by dependency_report.sh and runtime_update.sh to quote
# third-party release notes in a daily pull request description.
#
# Usage (sourced):
#     source .github/scripts/release_notes.sh
#     highlights < notes.md                        # one condensed line per bullet
#     release_notes_markdown <owner/repo> < notes.md
#
# Release notes are third-party text, so they are defused before they reach the
# pull request: @-mentions get a zero-width space (no notifications), and issue
# references point at redirect.github.com (no backlinks in upstream issues), the
# way Dependabot does it.

# The bullet points of release notes (read from stdin), one plain line each:
# links, contributor credits and issue numbers are dropped, and chores such as
# dependency bumps are skipped so that the first lines are the ones worth reading.
highlights() {
  perl -CSD -0777 -ne '
    s/\r//g;
    # A bullet together with the indented lines it wraps onto.
    for (/^ ?[*-][ \t]+(.+(?:\n[ \t]{2,}(?![*-][ \t]).*\S.*)*)/mg) {
    s/\n[ \t]*/ /g;
    s/\s+by \@[\w-]+(?:\[bot\])?(?:(?:,|,? and) \@[\w-]+(?:\[bot\])?)*(?: in \S+)?\s*$//;
    s/\s+in https?:\/\/\S+\s*$//;
    s/\\?\[\[?`?[0-9a-f]{7,40}`?\]?(?:\([^)]*\))?\]\s*-\s*//;
    s/\[([^\]]*)\]\([^)]*\)/$1/g;
    s/\[([^\]]+)\]\[[^\]]*\]/$1/g;
    s/\(\s*\@[\w-]+(?:\[bot\])?(?:\s*(?:,|and)\s*\@[\w-]+(?:\[bot\])?)*\s*\)//g;
    s/<[^>]+>//g;
    s/_?\*\*_?//g;
    s/^(?:#\d+|GH-\d+|gh-\d+)(?:,\s*#\d+)*\s*[:\-]\s*//;
    s/\(\s*(?:#\d+|GH-\d+)(?:,\s*#\d+)*\s*\)//g;
    s/\s+/ /g; s/^\s+|\s+$//g; s/\s+([.,;])/$1/g; s/[,;:]$//;
    next if $_ eq "" || length($_) < 8;
    next if /first contribution|full changelog|dependabot|renovate|pre-commit|sponsor|^revert\b/i;
    next if /^(?:chore|ci|build|deps|test|tests|docs|style|refactor)(?:\([^)]*\))?!?:/i;
    next if /^\[(?:build|ci|test|tests|docs?|chore|deps)\]/i;
    next if /^(?:bump|update|upgrade)\b.*\b(?:from|to)\s+v?\d/i;
    s/\@(?=[A-Za-z0-9])/\@\x{200B}/g;
    s/\|/\\|/g; s/</&lt;/g;
    if (length($_) > 120) {
      s/^(.{1,117})\s.*$/$1/;
      $_ = substr($_, 0, 117);
      $_ .= "`" if (() = /`/g) % 2;
      $_ .= "\x{2026}";
    }
    print "$_\n";
    }
  '
}

# Release notes (read from stdin) made safe to embed in the pull request: headings
# become bold lines so the template outline stays intact, @-mentions cannot
# notify anyone, issue references cannot leave backlinks upstream, and long notes
# are cut off without leaving a code fence or a <details> element open.
release_notes_markdown() {
  REPO=$1 perl -CSD -ne '
    BEGIN { $repo = $ENV{REPO}; $limit = 40; }
    s/\r//g;
    # Sponsor banners and other layout HTML carry nothing to review.
    $table++ if /<table\b/i;
    if ($table) { $table-- if /<\/table>/i; next; }
    next if /^\s*<!--.*-->\s*$/ || /^\s*<\/?(?:p|div|picture|source|img|br|a|td|tr)\b[^>]*>\s*$/i;
    next if /^#{1,6}\s+.*sponsors?\s*$/i;
    next if !$started && /^\s*$/;
    $started = 1;
    if ($n >= $limit) { $more++; next; }
    $n++;
    if (/^\s*(?:```|~~~)/) { $fence = !$fence; print; next; }
    unless ($fence) {
      s/^#{1,6}\s+(.+?)\s*#*\s*$/**$1**/;
      s{\[\@([\w-]+)\]\(https://github\.com/[\w-]+/?\)}{\@$1}g;
      s{https://github\.com/([\w.-]+/[\w.-]+)/(issues|pull|discussions)/}{https://redirect.github.com/$1/$2/}g;
      # Existing links and Redmine references (`Bug #22188` is a
      # bugs.ruby-lang.org ticket, not a GitHub issue) pass through untouched.
      s{(\[[^\]]*\]\([^)]*\)|\b(?:Bug|Feature|Misc) #\d+)|(?<![\w/.\[-])([\w.-]+/[\w.-]+)#(\d+)\b}{$1 // "[$2#$3](https://redirect.github.com/$2/issues/$3)"}ge;
      s{(\[[^\]]*\]\([^)]*\)|\b(?:Bug|Feature|Misc) #\d+)|(?<![\w/&\[#-])#(\d+)\b(?!\])}{$1 // "[#$2](https://redirect.github.com/$repo/issues/$2)"}ge;
      s/(?<![\w`\/])\@(?=[A-Za-z0-9])/\@\x{200B}/g;
      $details += () = /<details\b/gi;
      $details -= () = /<\/details>/gi;
    }
    print;
    END {
      print "```\n" if $fence;
      print "</details>\n" x $details if $details > 0;
      print "\n_\x{2026} $more more lines in the full release notes._\n" if $more;
    }
  ' | cat -s
}

