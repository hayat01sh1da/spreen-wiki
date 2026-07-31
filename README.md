[![Actions Status: PyPI - CI](https://github.com/hayat01sh1da/spreen-wiki/workflows/PyPI%20-%20CI/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22PyPI%20-%20CI%22)
[![Actions Status: PyPI - Daily Dependencies Update](https://github.com/hayat01sh1da/spreen-wiki/workflows/PyPI%20-%20Daily%20Dependencies%20Update/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22PyPI%20-%20Daily%20Dependencies%20Update%22)
[![Actions Status: RubyGem - CI](https://github.com/hayat01sh1da/spreen-wiki/workflows/RubyGem%20-%20CI/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22RubyGem%20-%20CI%22)
[![Actions Status: RubyGem - Daily Dependencies Update](https://github.com/hayat01sh1da/spreen-wiki/workflows/RubyGem%20-%20Daily%20Dependencies%20Update/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22RubyGem%20-%20Daily%20Dependencies%20Update%22)
[![Actions Status: Export Unknown Wiki List for LLM](https://github.com/hayat01sh1da/spreen-wiki/workflows/Export%20Unknown%20Wiki%20List%20for%20LLM/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22Export%20Unknown%20Wiki%20List%20for%20LLM%22)
[![Actions Status: Notify Uncategorised Wiki Count by Namespace](https://github.com/hayat01sh1da/spreen-wiki/workflows/Notify%20Uncategorised%20Wiki%20Count%20by%20Namespace/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22Notify%20Uncategorised%20Wiki%20Count%20by%20Namespace%22)
[![Actions Status: Notify Unknown Wiki Count by Namespace](https://github.com/hayat01sh1da/spreen-wiki/workflows/Notify%20Unknown%20Wiki%20Count%20by%20Namespace/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22Notify%20Unknown%20Wiki%20Count%20by%20Namespace%22)
[![Actions Status: Update Wiki List on Home and Sidebar](https://github.com/hayat01sh1da/spreen-wiki/workflows/Update%20Wiki%20List%20on%20Home%20and%20Sidebar/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22Update%20Wiki%20List%20on%20Home%20and%20Sidebar%22)
[![Actions Status: CodeQL](https://github.com/hayat01sh1da/spreen-wiki/workflows/CodeQL/badge.svg)](https://github.com/hayat01sh1da/spreen-wiki/actions?query=workflow%3A%22CodeQL%22)

# spreen-wiki

<img src="./assets/spreen-icon.svg" align="center" width="300" alt="spreen: an origami falcon stooping across a falcon's-eye stone" />

Organises a GitHub wiki: generates `Home.md` and `_Sidebar.md` by grouping the pages by the **Owner** or **Category** declared on the first line of each page (English and Japanese labels built in, extensible via a config file), and exports reports of the pages whose owner or category is unknown.

The tool ships twice with identical behaviour: as the RubyGems gem **`spreen-wiki`** and as the PyPI library **`spreen-wiki`**.  
Both install the same `wiki-organise` command.

## 1. Origin of the Name

**stoop + preen = spreen** — dive on the messy wiki, then groom it page by page.  
The icon tells the story: an origami falcon(隼 /hayabusa/) mid-stoop across the falcon's-eye stone, its golden eye keeping watch over the field.

The author's name hides a small legend: the given name *Hayato* (隼人) is the **falcon man**, and the surname *Ishida* (石田) is the **stone in the rice field**.  
The hunt for a name flew through *hayabusa* (隼) — the peregrine falcon, the fastest animal alive — and landed on **falcon's eye**, the blue-grey quartz whose single chatoyant band of light sweeps across the stone like a cat's eye.

So the falcon man releases a **falconet** — a small falcon — over the rice field of wiki pages.  
First it **stoops**: the peregrine's signature dive, 300 km/h of intent.  
Then it **preens**: straightening every feather until the plumage gleams.

## 2. Quickstart

Install one of the two implementations:

```command
$ gem install spreen-wiki
```

```command
$ pipx install spreen-wiki
```

Clone your repository's wiki, declare an owner (or category) on the first line of each page, and run the organiser:

```command
$ git clone git@github.com:<org>/<repo>.wiki.git
$ cd <repo>.wiki
$ wiki-organise update --path . --org <org> --repo <repo>
Updated Home.md and _Sidebar.md.
Check them out at 'https://github.com/<org>/<repo>/wiki' !!
$ git add Home.md _Sidebar.md && git commit -m 'Organise wiki' && git push origin master
```

The other two commands export reports about the pages whose owner/category is still unknown:

```command
$ wiki-organise count-report --path . # counts per unknown namespace
$ wiki-organise llm-export --path .   # flat page list to feed to an LLM
```

Run `wiki-organise <command> --help` for the full flag list (`--group-by`, `--language`, `--overflow`, `--template-dir`, `--exclude`, `--output`, ...).

## 3. Wiki Page Convention

Declare the owner or the category of every wiki page on the top line of the document as follows.

```markdown
Owner: @sample-owner

---

This is a sample Wiki.
```

```markdown
Category: sample-category

---

This is a sample Wiki.
```

Pages without a declaration are collected under the "Unowned" / "Uncategorised" namespace (`Owner記名なし` / `Category記載なし` in Japanese) so they stay visible until someone claims them.

## 4. Configuration

Every hardcoded assumption of the original tool is now configurable. Values are resolved with the same precedence everywhere: **explicit CLI flag / keyword argument → `.spreen.yml` → `ORGANISATION_NAME` environment variable (organisation only) → built-in default**.

Place a `.spreen.yml` at the root of the wiki clone (or point at one with `--config`):

```yaml
# Used to build the wiki URL and the owner-team links. Equivalent to
# --org/--repo; omit them and set wiki_url/owner_base_url directly if your
# links do not follow the github.com defaults.
organisation: my-org
repository: my-repo
# wiki_url: https://github.com/my-org/my-repo/wiki
# owner_base_url: https://github.com/orgs/my-org/teams/

# Directories skipped while scanning (default below). Keep wikis-by-owner in
# the list when you use `update --overflow`, which writes into it.
exclude:
  - spreen-wiki
  - wikis-by-owner

# Where the Home header templates live, as <group_by>/<language>.md
# (e.g. owner/english.md). Defaults to the templates shipped with the package.
# template_dir: ./my_templates

# Override or extend the built-in labels: change the first-line regexp, add
# languages, or add whole group_by criteria. Anything not listed here keeps
# its built-in value.
labels:
  Owner:
    # regexp: '[Oo]wner:\s?'
    languages:
      French:
        no_declaration: Sans propriétaire        # namespace for undeclared pages
        unknown_namespaces:                      # namespaces in count-report
          - Sans propriétaire
        llm_target_namespace: Sans propriétaire  # namespace llm-export dumps
```

When no organisation is configured at all, owner headings are rendered without team links instead of failing.

## 5. GitHub Actions Reference Implementations

The point of the organiser is automation: this repository runs it on its own wiki with cron workflows you can copy into your repository.  
They check out the wiki, run the organiser, commit and push when there is a diff, and notify a Slack channel (as a sample, [#github-actions-notifications - hayat01sh1da](https://hayat01sh1da.slack.com/archives/C09BBHZPD5E) is set as the target channel).

### 5-1. Update Wiki List on Home And Sidebar

[update-wiki-list-on-home-and-sidebar.yml](./.github/workflows/update-wiki-list-on-home-and-sidebar.yml) regenerates Home and Sidebar at 12:00 and 22:00 JST every weekday.

<img src="./assets/update-wiki-list-on-home-and-sidebar.png" width="700" alt="spreen-wiki Daily Wiki List on Home and Sidebar Update Report" />

### 5-2. Notify Wiki Count vy Namespace

[notify-wiki-count-by-namespace.yml](./.github/workflows/notify-wiki-count-by-namespace.yml) reports the unknown-owner and uncategorised counts at 09:00 JST every Monday.

<img src="./assets/notify-wiki-count-by-namespace.png" width="500" alt="spreen-wiki Daily Wiki List on Home and Sidebar Update Report" />

### 5-3. Export Unknown Wiki List dor LLM

[export-unknown-wiki-list-for-llm.yml](./.github/workflows/export-unknown-wiki-list-for-llm.yml) exports the ignored page list for LLM noise-cancelling at 00:00 JST every weekday.

<img src="./assets/export-unknown-wiki-list-for-llm.png" width="900" alt="spreen-wiki Daily Wiki List on Home and Sidebar Update Report" />

## 6. Editing This Repository's Wiki

### 6-1. GUI

You can directly create, update and delete wiki pages on [spreen-wiki Wiki](https://github.com/hayat01sh1da/spreen-wiki/wiki).  
These actions are managed as git commits.

### 6-2. On Your Machine

GitHub Wiki is also managed as a git repository, which allows you to use git commands, needless to say.  
Follow the instructions below to edit wiki pages.

1. Run `git clone git@github.com:hayat01sh1da/spreen-wiki.wiki.git` to clone this repository's Wiki.
2. Create, update or delete a wiki and make some differences.
3. Run `git add #{FILENAME}`, `git commit -m #{COMMIT_MESSAGE}` and `git push origin master` in order to push commit(s) to the remote repository.
    - \* The branch you can see on GUI is `master`

⚠️ Make sure that you must not rename and move markdown file on CLI or change the title on GUI in case you lost the revisions.

You can also freely configure the Home header passage this repository's cron jobs use.
Edit it on [./home_template/](https://github.com/hayat01sh1da/spreen-wiki/blob/master/home_template) based on the mode you are in. (Package consumers get the same defaults shipped with the package and override them with `template_dir`.)

## 7. Development

- Common environment: WSL (Ubuntu 25.10)
- [Ruby implementation](./RubyGem/README.md) — gem sources under [./RubyGem/](./RubyGem/)
- [Python implementation](./PyPI/README.md) — package sources under [./PyPI/](./PyPI/)
- Release notes live in [CHANGELOG.md](./CHANGELOG.md)
