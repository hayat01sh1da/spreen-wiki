# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).  
One repository hosts two packages, so releases are tagged per ecosystem (`ruby-vX.Y.Z` for the RubyGems gem, `python-vX.Y.Z` for the PyPI library).

## 0.2.1 (PyPI)

PyPI only — the RubyGems gem is unaffected and stays on `0.3.0`, so no `ruby-` tag is cut.

### 1. Fixed

- `wiki-organise --version` reported `0.1.0` on the `0.2.0` release. `__version__` in `spreen_wiki/__init__.py` is declared separately from the packaging metadata in `pyproject.toml`, and the `0.2.0` release bumped only the latter, so the published wheel carried a stale constant. Both now read `0.2.1`. The gem is not affected: its gemspec reads `SpreenWiki::VERSION`, so the version has a single source there.

### 2. Added

- `PyPI/test/test_version.py`, asserting `spreen_wiki.__version__` matches the `version` declared in `pyproject.toml`, so a release that bumps only one of the two fails CI instead of shipping.

## 0.3.0 (RubyGem) / 0.2.0 (PyPI)

Both ecosystems ship this release: the gem goes `0.2.0` → `0.3.0` (tag `ruby-v0.3.0`) and the library `0.1.0` → `0.2.0` (tag `python-v0.2.0`). The version numbers differ because the library sat out `0.2.0`, which was RubyGem-only.

### 1. Changed

- **Breaking (gem and library):** renamed the CLI executable from `spreen` to `wiki-organise`. The brand name carried no hint of what the command does, whereas `wiki-organise` states the object and the action, matching the `<object>-<action>` shape of the sibling CLIs (`pr-title`, `track-delimiter`, `file-clean`, `readme-update`). This restores the working title the tool carried before the 0.1.0 naming decision. The gem name, the PyPI project name, the `SpreenWiki`/`spreen_wiki` namespaces, the `.spreen.yml` config file and every subcommand and flag are unchanged — only the executable name differs.

### 2. Removed

- The `spreen` executable, superseded by `wiki-organise`. No alias is shipped, so scripts, aliases and CI steps invoking `spreen` must be updated to `wiki-organise`.

## 0.2.0

RubyGem only — the PyPI library has no shipped changes since `0.1.0` and stays on that version, so no `python-v0.2.0` tag is cut.

### 1. Added

- RubyGem release automation: `RubyGem/Rakefile` defines the Bundler gem tasks with the `ruby-` tag prefix, and `.github/workflows/rubygem--release.yml` builds and publishes via RubyGems Trusted Publishing on `ruby-v*` tags.
- PyPI release automation: `.github/workflows/pypi--release.yml` builds the distributions and publishes via PyPI Trusted Publishers on `python-v*` tags, with the OIDC grant isolated in a `pypi`-environment publish job.
- Ecosystem-scoped toolchain version files `RubyGem/.ruby-version` and `PyPI/.python-version`, alongside the repository-root ones.

### 2. Changed

- **Breaking (gem):** renamed the Ruby namespace from `Spreen::Wiki` to `SpreenWiki` and the lib path from `lib/spreen/wiki/` to `lib/spreen_wiki/`, matching the Python package's flat `spreen_wiki` layout. `require 'spreen-wiki'`, the gem name and the `spreen` CLI are unchanged, so CLI users are unaffected; library callers must replace `Spreen::Wiki::Home` with `SpreenWiki::Home` (likewise `Sidebar`, `UnknownWikiCountListExporter`, `UnknownWikiListExporterForLLM`, `Configuration`, `Application`).
- Bumped the development Ruby toolchain from 4.0.5 to 4.0.6; the gem's `required_ruby_version` remains `>= 3.4`.
- Updated the daily RubyGems dependencies (`concurrent-ruby` 1.3.7 → 1.3.8); the gem has no runtime dependencies, so this affects the development bundle only.
- `.github/scripts/dependency_report.sh` labels ecosystems by registry name (`PyPI` / `RubyGems` / `npm`) instead of by installer command (`pip` / `gem` / `pnpm`).
- Refined the `README.md` "Origin of the Name" section and replaced the obsolete workflow captures with current ones.
- Rewrote `SECURITY.md` for the packaged releases, and pinned explicit `permissions` on the CodeQL workflow.
- Numbered the `CHANGELOG.md` section headings to match the convention used across the other repositories.

### 3. Removed

- The `Spreen::Wiki` namespace and the `lib/spreen/wiki/` load path, superseded by `SpreenWiki` and `lib/spreen_wiki/`. `require 'spreen/wiki'` no longer resolves.

## 0.1.0

### 1. Added

- `spreen` CLI with `update`, `count-report` and `llm-export` subcommands plus `--path`, `--group-by`, `--language`, `--overflow`, `--org`, `--repo`, `--wiki-url`, `--template-dir`, `--config`, `--exclude` and `--output` flags, replacing the interactive prompts as the packaged entry point (Ruby and Python).
- `.spreen.yml` config file: sets the organisation/repository (or explicit `wiki_url` / `owner_base_url`), the excluded directories, a custom template directory, and overrides or extends the built-in Owner/Category labels, languages and first-line regexes.
- Ruby gem packaging: `Spreen::Wiki` module under `RubyGem/lib/`, `spreen-wiki.gemspec`, `exe/spreen`, RBS signatures, and the four default Home templates shipped as gem data.
- Python packaging: `spreen_wiki` package under `PyPI/src/`, full PyPI metadata in `pyproject.toml`, `spreen` console script, `py.typed`, and the four default Home templates shipped as package data.
- Configuration tests covering precedence (explicit option > config file > `ORGANISATION_NAME` environment variable > defaults) in both ecosystems.

### 2. Changed

- Renamed the repository to `spreen-wiki` and the ecosystem directories to `RubyGem/` (from `ruby/`) and `PyPI/` (from `python/`).
- Named the packages **`spreen-wiki`** — a blend of the falcon's *stoop* and the *preen* that follows, after Hayato (隼人, "falcon man"): RubyGem `spreen-wiki` (`Spreen::Wiki`), PyPI `spreen-wiki` (`spreen_wiki`), CLI `spreen`, config file `.spreen.yml` (renamed from the working titles `github_wiki_organiser` / `github-wiki-organiser`, CLI `wiki-organise`, `.wiki-organiser.yml`).
- Generalised the hardcoded assumptions: the organisation/repository/wiki URL, the owner-team URL, the template path, the scanned base path (now defaulting to the current directory), the excluded directories and the export filenames are all configuration, with the previous behaviour preserved as defaults.
- Owner headings degrade gracefully to unlinked text when no organisation is configured instead of linking to a hardcoded personal account.
- The wiki cron workflows pass `ORGANISATION_NAME` from `github.repository_owner` and keep driving the (unchanged) interactive Rake task interface.
- Fixed `README.md` § 4-1-2: the wiki clone instruction pointed at an unrelated repository; now points at this repository's wiki.

### 3. Removed

- Flat `ruby/src/` and `PyPI/src/` script layouts (superseded by the gem and
  package layouts above).
