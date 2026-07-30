# spreen-wiki (Python)

The PyPI implementation of [spreen-wiki](../README.md): generates `Home.md` and `_Sidebar.md` for a GitHub wiki grouped by the Owner/Category declared on the first line of each page, and exports reports of the pages whose owner or category is unknown.

## 1. Installation

```command
$ pipx install spreen-wiki
```

(or `pip install spreen-wiki` into a virtual environment). Requires Python 3.10+.

## 2. CLI Usage

```command
$ cd path/to/your-repo.wiki
$ spreen update --path . --org your-org --repo your-repo
Updated Home.md and _Sidebar.md.
Check them out at 'https://github.com/your-org/your-repo/wiki' !!

$ spreen count-report --path .
Unknown Owner nor Necessity: 1
Unowned but Necessary: 1
Unowned: 10
Exported the unknown wiki count report to './unknown_wiki_count_list_by_namespace.txt'.

$ spreen llm-export --path .
Exported the unknown wiki list for LLM to './unknown_wiki_list_for_llm.txt'.
```

Common flags (see `spreen <command> --help`): `--group-by Owner|Category`, `--language English|Japanese`, `--overflow` (split Home into per-namespace pages under `wikis-by-owner/`), `--template-dir`, `--config`, `--exclude`, `--output`, `--wiki-url`.

Persistent settings, custom labels and additional languages go into a [`.spreen.yml`](../README.md#4-configuration) at the wiki root.

## 3. Library Usage

```python
from spreen_wiki import (
    Home, Sidebar, UnknownWikiCountListExporter, UnknownWikiListExporterForLLM,
)

Home.run(base_path='.', organisation='your-org', repository='your-repo')
Sidebar.run(base_path='.', organisation='your-org', repository='your-repo')
UnknownWikiCountListExporter.run(base_path='.', output='report.txt')
UnknownWikiListExporterForLLM.run(base_path='.', group_by='Category', language='Japanese')
```

All classes accept `base_path`, `group_by`, `language`, `home_overflow` plus the configuration keywords `organisation`, `repository`, `wiki_url`, `owner_base_url`, `template_dir`, `excluded_dirs`, `config_path` (and `output` on the exporters). The package ships `py.typed`.

## 4. Development

### 4-1. Environment

- Python 3.14.6
- pip 26.2

```command
$ pip install -r requirements.txt
```

### 4-2. Interactive Invoke Tasks (this repository's own automation)

These stdin-prompted tasks pin this repository's settings and read `ORGANISATION_NAME` from the environment.

```command
$ invoke update_wiki_list_on_home_and_sidebar
$ invoke export_unknown_wiki_count_list_by_namespace
$ invoke export_unknown_wiki_list_for_llm
```

### 4-3. Unit Tests

```command
$ invoke
============================= test session starts ==============================
platform linux -- Python 3.14.6, pytest-9.0.3, pluggy-1.6.0
rootdir: spreen-wiki/PyPI
configfile: pyproject.toml
collected 46 items

test/test_application.py ....                                            [  8%]
test/test_configuration.py ..............                                [ 39%]
test/test_home.py ......                                                 [ 52%]
test/test_sidebar.py ....                                                [ 60%]
test/test_unknown_wiki_count_list_exporter.py ..............             [ 91%]
test/test_unknown_wiki_list_exporter_for_llm.py ....                     [100%]

============================== 46 passed in 3.81s ==============================
```

### 4-4. Static Code Analysis

```command
$ flake8 --max-complexity=10 --max-line-length=127 .
$ autoflake8 --in-place --remove-duplicate-keys --remove-unused-variables --recursive .
$ autopep8 --in-place --aggressive --aggressive --recursive .
```

### 4-5. Type Checks

```command
$ mypy .
Success: no issues found in 16 source files
```

### 4-6. Build & Release

```command
$ python -m build
$ twine check dist/*
$ twine upload dist/*
```

Releases are tagged `python-vX.Y.Z`; update [CHANGELOG.md](../CHANGELOG.md) with every release.
