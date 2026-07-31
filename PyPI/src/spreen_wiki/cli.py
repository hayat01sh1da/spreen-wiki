"""Command line interface behind the `wiki-organise` executable:
`wiki-organise <update|count-report|llm-export> [options]`."""

import argparse
import sys
from typing import Any

from . import __version__
from .home import Home
from .sidebar import Sidebar
from .unknown_wiki_count_list_exporter import UnknownWikiCountListExporter
from .unknown_wiki_list_exporter_for_llm import UnknownWikiListExporterForLLM


def _common_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        '--path', dest='base_path', metavar='PATH',
        help='Path to the wiki clone (default: current directory)')
    common.add_argument(
        '--group-by', dest='group_by', metavar='GROUP_BY',
        help='Grouping criteria (default: Owner)')
    common.add_argument(
        '--language', metavar='LANGUAGE',
        help='Language of the labels (default: English)')
    common.add_argument(
        '--org', dest='organisation', metavar='ORGANISATION',
        help='GitHub organisation/user hosting the wiki')
    common.add_argument(
        '--repo', dest='repository', metavar='REPOSITORY',
        help='GitHub repository whose wiki is organised')
    common.add_argument(
        '--wiki-url', dest='wiki_url', metavar='URL',
        help='Wiki URL (overrides the one derived from --org/--repo)')
    common.add_argument(
        '--template-dir', dest='template_dir', metavar='DIR',
        help='Directory of <group_by>/<language>.md Home templates')
    common.add_argument(
        '--config', dest='config_path', metavar='FILE',
        help='Config file path (default: <path>/.spreen.yml)')
    common.add_argument(
        '--exclude', dest='excluded_dirs', action='append', metavar='DIR',
        help='Directory to skip while scanning (repeatable)')
    return common


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog='wiki-organise',
        description='Organise a GitHub wiki: generate Home.md/_Sidebar.md '
                    'and export unknown-namespace reports.')
    parser.add_argument('--version', action='version', version=__version__)
    subparsers = parser.add_subparsers(dest='command', required=True)
    common = _common_parser()
    update = subparsers.add_parser(
        'update', parents=[common],
        help='Regenerate Home.md and _Sidebar.md from the wiki tree')
    update.add_argument(
        '--overflow', dest='home_overflow', action='store_true',
        help='Split Home into per-namespace pages under wikis-by-owner/')
    count_report = subparsers.add_parser(
        'count-report', parents=[common],
        help='Export a count report of the unknown-namespace wikis')
    count_report.add_argument(
        '--output', metavar='FILENAME',
        help='Export filename (relative to --path unless absolute)')
    llm_export = subparsers.add_parser(
        'llm-export', parents=[common],
        help='Export the unknown-namespace wiki list for an LLM')
    llm_export.add_argument(
        '--output', metavar='FILENAME',
        help='Export filename (relative to --path unless absolute)')
    return parser


def _options(args: argparse.Namespace) -> dict[str, Any]:
    return {
        key: value
        for key, value in vars(args).items()
        if key != 'command' and value is not None
    }


def _update(options: dict[str, Any]) -> None:
    wiki_url = Home.run(**options)
    Sidebar.run(**options)
    print('Updated Home.md and _Sidebar.md.')
    if wiki_url:
        print(f"Check them out at '{wiki_url}' !!")


def _count_report(options: dict[str, Any]) -> None:
    counts, path_to_export = UnknownWikiCountListExporter.run(**options)
    print('\n'.join(counts))
    print(f"Exported the unknown wiki count report to '{path_to_export}'.")


def _llm_export(options: dict[str, Any]) -> None:
    path_to_export = UnknownWikiListExporterForLLM.run(**options)
    print(f"Exported the unknown wiki list for LLM to '{path_to_export}'.")


_COMMANDS = {
    'update': _update,
    'count-report': _count_report,
    'llm-export': _llm_export,
}


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        _COMMANDS[args.command](_options(args))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
