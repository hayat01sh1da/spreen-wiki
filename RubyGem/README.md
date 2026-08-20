# spreen-wiki (Ruby)

The RubyGems implementation of [spreen-wiki](../README.md): generates `Home.md` and `_Sidebar.md` for a GitHub wiki grouped by the Owner/Category declared on the first line of each page, and exports reports of the pages whose owner or category is unknown.

## 1. Installation

```command
$ gem install spreen-wiki
```

Requires Ruby 3.4+.

## 2. CLI Usage

```command
$ cd path/to/your-repo.wiki
$ wiki-organise update --path . --org your-org --repo your-repo
Updated Home.md and _Sidebar.md.
Check them out at 'https://github.com/your-org/your-repo/wiki' !!

$ wiki-organise count-report --path .
Unknown Owner nor Necessity: 1
Unowned but Necessary: 1
Unowned: 10
Exported the unknown wiki count report to './unknown_wiki_count_list_by_namespace.txt'.

$ wiki-organise llm-export --path .
Exported the unknown wiki list for LLM to './unknown_wiki_list_for_llm.txt'.
```

Common flags (see `wiki-organise <command> --help`): `--group-by Owner|Category`, `--language English|Japanese`, `--overflow` (split Home into per-namespace pages under `wikis-by-owner/`), `--template-dir`, `--config`, `--exclude`, `--output`, `--wiki-url`.

Persistent settings, custom labels and additional languages go into a [`.spreen.yml`](../README.md#4-configuration) at the wiki root.

## 3. Library Usage

```ruby
require 'spreen_wiki'

SpreenWiki::Home.run(base_path: '.', organisation: 'your-org', repository: 'your-repo')
SpreenWiki::Sidebar.run(base_path: '.', organisation: 'your-org', repository: 'your-repo')
SpreenWiki::UnknownWikiCountListExporter.run(base_path: '.', output: 'report.txt')
SpreenWiki::UnknownWikiListExporterForLLM.run(base_path: '.', group_by: 'Category', language: 'Japanese')
```

All classes accept `base_path:`, `group_by:`, `language:`, `home_overflow:` plus the configuration keywords `organisation:`, `repository:`, `wiki_url:`, `owner_base_url:`, `template_dir:`, `excluded_dirs:`, `config_path:` (and `output:` on the exporters).

## 4. Development

### 4-1. Environment

- Ruby 4.0.6
- Gemfile 4.0.19
- Bundler 4.0.19

```command
$ bundle install
```

### 4-2. Interactive Rake Tasks (this repository's own automation)

The wiki cron workflows drive these stdin-prompted tasks; they pin this repository's settings and read `ORGANISATION_NAME` from the environment.

```command
$ rake update_wiki_list_on_home_and_sidebar
$ rake export_unknown_wiki_count_list_by_namespace
$ rake export_unknown_wiki_list_for_llm
```

### 4-3. Unit Tests

```command
$ bundle exec rake
Run options: --seed 33975

# Running:

.........................................................................................................................................................................

Finished in 9.889896s, 17.0881 runs/s, 32.7607 assertions/s.

174 runs, 323 assertions, 0 failures, 0 errors, 0 skips
```

### 4-4. Static Code Analysis

```command
$ bundle exec rubocop
Inspecting 21 files
....................

20 files inspected, no offenses detected
```

### 4-5. Type Checks

```command
$ bundle exec rbs-inline --output sig/generated/ lib test
🎉 Generated 16 RBS files under sig/generated
$ bundle exec steep check
# Type checking files:

..............................

No type error detected. 🫖
```

### 4-6. Build & Release

```command
$ gem build spreen-wiki.gemspec
$ gem push spreen-wiki-x.y.z.gem
```

Releases are tagged `ruby-vX.Y.Z`; update [CHANGELOG.md](../CHANGELOG.md) with every release.
