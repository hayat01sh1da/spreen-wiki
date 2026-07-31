import re
import tomllib
from pathlib import Path

import spreen_wiki

PYPROJECT = Path(__file__).resolve().parent.parent / 'pyproject.toml'


def test_version_constant_matches_pyproject() -> None:
    """`__version__` is declared separately from the packaging metadata, so a
    release that bumps only `pyproject.toml` ships a wheel whose `--version`
    reports the previous release. This guard fails that release in CI."""
    with PYPROJECT.open('rb') as f:
        declared = tomllib.load(f)['project']['version']
    assert spreen_wiki.__version__ == declared


def test_version_is_semver() -> None:
    assert re.fullmatch(r'\d+\.\d+\.\d+', spreen_wiki.__version__)
