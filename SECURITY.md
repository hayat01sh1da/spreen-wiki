## Supported Versions

| Surface                                                            | Supported                                                              |
|--------------------------------------------------------------------|------------------------------------------------------------------------|
| [`spreen-wiki` on RubyGems](https://rubygems.org/gems/spreen-wiki) | Latest release only (currently 0.1.x); older versions are not patched. |
| [`spreen-wiki` on PyPI](https://pypi.org/project/spreen-wiki/)     | Latest release only (currently 0.1.x); older versions are not patched. |
| Repository automation (`.github/workflows`, wiki cron jobs)        | Latest content on `master` only.                                       |
| Historical wiki exports / generated artifacts                      | Snapshots; not retroactively secured.                                  |

## Ecosystem & Compatibility

| Component / Workflow     | Version(s) / Tooling                | Notes                                                                                                                                                                                 |
|--------------------------|-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| OS baseline              | WSL (Ubuntu 25.10)                  | Shared development environment across tracks; CI runs on GitHub-hosted Ubuntu images.                                                                                                 |
| Ruby toolchain           | Ruby 4.0.6 (`.ruby-version`)        | Gem sources in `RubyGem/`; the published gem supports Ruby >= 3.4 (`required_ruby_version`).                                                                                          |
| RubyGems                 | 4.0.16                              | Publishing requires MFA (`rubygems_mfa_required` is set in the gemspec).                                                                                                              |
| Bundler                  | 4.0.16                              | Resolves and installs the gems declared in `RubyGem/Gemfile`; `Gemfile.lock` is committed.                                                                                            |
| Python toolchain         | CPython 3.14.7 (`.python-version`)  | Package sources in `PyPI/src/`; the published library supports Python >= 3.10 (`requires-python`).                                                                                    |
| Python dependencies      | `PyYAML >= 6.0` (runtime)           | Declared in `PyPI/pyproject.toml`; development/CI dependencies are pinned in `PyPI/requirements.lock`.                                                                                |
| GitHub Actions workflows | Runs on GitHub-hosted Ubuntu images | CI, daily dependency updates, wiki cron jobs (Slack notifications, wiki mutation), and release workflows; keep action versions pinned and `GITHUB_TOKEN` permissions least-privilege. |

## Release & Supply-chain Security

- Releases are tag-driven (`ruby-vX.Y.Z` / `python-vX.Y.Z`) and publish through **Trusted Publishing (OIDC)** — `rubygems/release-gem@v1` and `pypa/gh-action-pypi-publish` exchange short-lived tokens per run; no registry API keys are stored in the repository or its secrets.
- The PyPI publisher is bound to the `pypi` GitHub deployment environment; the RubyGems publisher is bound to the `rubygem--release.yml` workflow filename.
- CodeQL code scanning runs on the repository, including workflow-permission checks.
- Dependencies are refreshed by the daily dependency-update workflows; security-relevant bumps land through the normal PR flow.

## Backward Compatibility

- Both packages follow Semantic Versioning from `0.1.0`; while on 0.x, breaking changes may occur between minor versions and are always called out in `CHANGELOG.md` and the GitHub Release notes (e.g. the `Spreen::Wiki` → `SpreenWiki` namespace rename after v0.1.0).
- CLI helpers and workflows are expected to remain compatible across Ruby 4.0.x and Python 3.14.x. When a workflow contract changes (e.g., new env vars), the corresponding README section and workflow dispatch docs will call it out.
- Archived wiki exports remain untouched; we do not backport automation fixes to historical snapshots.

## Reporting a Vulnerability

Please report issues privately via **GitHub Security Advisory** (preferred) — open through the repository’s **Security → Report a vulnerability** workflow.

Acknowledgement occurs and status updates follow as soon as possible.  
After remediation we publish guidance alongside required dependency updates, and affected package versions are superseded by a patched release on RubyGems / PyPI.
