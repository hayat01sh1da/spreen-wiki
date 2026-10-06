#!/usr/bin/env python3
"""Bump the pinned language runtime for daily runtime update PRs.

Usage:
    runtime_update.py <runtime> <label> [<body-path>]

    runtime    ruby | python | node
    label      ecosystem label used in the PR body (Ruby / RubyGem / Ruby on Rails / Python / PyPI / JavaScript / Action)
    body-path  where to write the pull request description (only written when the version moves)

Finds the newest release the CI setup action can install, staying inside the
pinned series so the bump never crosses a line that needs code changes:

    ruby    latest X.Y.* listed by ruby/setup-ruby@v1 (ruby-builder-versions.json)
    python  latest stable X.Y.* in the actions/python-versions manifest used by actions/setup-python
    node    latest vX.* on nodejs.org/dist (actions/setup-node downloads from there)

Every tracked version file (.ruby-version / .python-version / .node-version)
is rewritten, and so is every human-facing copy of the version: Dockerfile base
images and ARGs, the `RUBY VERSION` section of each Gemfile.lock, the
`python-version` input of action.yml, the Environment sections of README.md,
the SECURITY.md support tables (re-padded so the columns stay aligned), sample
pytest output, and package.json descriptions. CHANGELOG.md keeps its history,
and .github/workflows/ is left alone because GITHUB_TOKEN cannot push workflow
changes.

Writes `changed`, `old` and `new` to $GITHUB_OUTPUT.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

runtime, label = sys.argv[1], sys.argv[2]
body_path = sys.argv[3] if len(sys.argv) > 3 else None

VERSION_FILE = {'ruby': '.ruby-version', 'python': '.python-version', 'node': '.node-version'}[runtime]
NAME = {'ruby': 'Ruby', 'python': 'Python', 'node': 'Node.js'}[runtime]
# Text that precedes a runtime version wherever it is documented or pinned.
PREFIXES = {
    'ruby': [r'\b[Rr]uby[ :]', r'\bRUBY_VERSION='],
    'python': [r'\bC?[Pp]ython[ :]', r'\bpython-version: ', r'\bPYTHON_VERSION='],
    'node': [r'\b[Nn]ode v', r'\bNode\.js v', r'\bnode:', r'\bNODE_VERSION=v?'],
}[runtime]


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def key(v):
    return tuple(int(x) for x in v.split('.'))


def latest(current):
    major, minor = current.split('.')[:2]
    if runtime == 'ruby':
        versions = fetch('https://raw.githubusercontent.com/ruby/setup-ruby/v1/ruby-builder-versions.json')['ruby']
        series = f'{major}.{minor}.'
    elif runtime == 'python':
        manifest = fetch('https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json')
        versions = [e['version'] for e in manifest if e.get('stable')]
        series = f'{major}.{minor}.'
    else:
        versions = [e['version'].lstrip('v') for e in fetch('https://nodejs.org/dist/index.json')]
        series = f'{major}.'
    candidates = [v for v in versions if re.fullmatch(r'\d+\.\d+\.\d+', v) and v.startswith(series)]
    return max(candidates, key=key, default=current)


def tracked_files():
    out = subprocess.run(['git', 'ls-files', '-z'], capture_output=True, text=True, check=True).stdout
    for path in filter(None, out.split('\0')):
        base = os.path.basename(path)
        if path.startswith('.github/workflows/') or base == 'CHANGELOG.md':
            continue
        if base.endswith(('.lock', '-lock.json', '-lock.yaml')) and base != 'Gemfile.lock':
            continue
        yield path


def realign(line, old_line):
    """Keep a markdown table row aligned after a cell grew or shrank."""
    if not line.lstrip().startswith('|'):
        return line
    old_cells, new_cells = old_line.split('|'), line.split('|')
    if len(old_cells) != len(new_cells):
        return line
    for i, (o, n) in enumerate(zip(old_cells, new_cells)):
        delta = len(n) - len(o)
        if delta > 0 and n.endswith(' ' * (delta + 1)):
            new_cells[i] = n[:-delta]
        elif delta < 0 and o.endswith(' '):
            new_cells[i] = n + ' ' * -delta
    return '|'.join(new_cells)


def main():
    if os.path.exists(VERSION_FILE):
        with open(VERSION_FILE) as f:
            current = f.read().strip()
    else:  # a composite action pins its runtime in action.yml instead of a version file
        with open('action.yml') as f:
            current = re.search(rf'{runtime}-version: *["\']?([v\d.]+)', f.read()).group(1)
    v_prefix = 'v' if current.startswith('v') else ''
    old = current.lstrip('v')
    new = latest(old)
    changed = key(new) > key(old)
    with open(os.environ.get('GITHUB_OUTPUT', os.devnull), 'a') as out:
        out.write(f'changed={str(changed).lower()}\nold={v_prefix}{old}\nnew={v_prefix}{new}\n')
    if not changed:
        print(f'{NAME} {v_prefix}{old} is already the latest release of its series.')
        return

    pattern = re.compile('(' + '|'.join(PREFIXES) + r')' + re.escape(old) + r'(?![0-9])')
    touched = []
    for path in tracked_files():
        try:
            with open(path, encoding='utf-8', newline='') as f:
                text = f.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        if os.path.basename(path) == VERSION_FILE:
            updated = text.replace(f'{v_prefix}{old}', f'{v_prefix}{new}')
        else:
            lines = text.split('\n')
            updated = '\n'.join(realign(pattern.sub(lambda m: m.group(1) + new, l), l) for l in lines)
        if updated != text:
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.write(updated)
            touched.append(path)
    print(f'Bumped {NAME} {v_prefix}{old} -> {v_prefix}{new} in:', *touched, sep='\n  ')
    if body_path:
        write_body(f'{v_prefix}{old}', f'{v_prefix}{new}', touched)


def release_notes(new):
    v = new.lstrip('v')
    if runtime == 'ruby':
        return f'https://github.com/ruby/ruby/releases/tag/v{v}'
    if runtime == 'python':
        return f'https://www.python.org/downloads/release/python-{v.replace(".", "")}/'
    return f'https://nodejs.org/en/blog/release/v{v}'


def write_body(old, new, touched):
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    run = f"https://github.com/{repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    series = 'major line' if runtime == 'node' else 'minor series'
    o = ['## 1. Overview', '',
         f'This pull request was created automatically by the {label} - Daily Runtime Update workflow.  ',
         f'It bumps {NAME} from {old} to {new}, the newest release of the current {series} that the CI setup action can install.  ',
         '',
         f'Every pinned version file and every documented copy of the version (Dockerfiles, Gemfile.lock `RUBY VERSION`, action inputs, README Environment sections, SECURITY.md support tables, sample test output) is moved together; CHANGELOG.md history is left untouched.  ',
         '',
         '## 2. Key Changes & Differences', '',
         '|Files |Before |After |Changes & Differences |', '|:-|:-|:-|:-|']
    o += [f'|`{p}` |{old} |{new} |{NAME} version updated. |' for p in touched]
    o += ['', '## 3. Summary', '',
          f'{NAME} is bumped from {old} to {new} across {len(touched)} file{"s" if len(touched) != 1 else ""}.  ',
          f'Crossing into a new {series} is intentionally left to a manual pull request, because it can require code changes.  ',
          'Please review the release notes and make sure that all CI workflows pass before merging this pull request.  ',
          '', '## 4. References', '',
          f'- [{label} - Daily Runtime Update workflow run]({run})',
          f'- [{NAME} {new} release notes]({release_notes(new)})']
    with open(body_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(o) + '\n')


main()
