# pr-activity-report

Generates a self-contained HTML page with a person's pull request activity in a
GitHub organization: authored PRs (open, merged, closed) and participation in
other people's PRs (reviews and comments), with a monthly chart, the most
active projects, and filterable tables. No runtime dependencies: the HTML opens
straight in a browser.

Note: the generated report's labels are in Portuguese (pt-BR).

## How it works

Two steps. `fetch.sh` queries the GitHub Search API and writes
`data/<handle>.json`. `generate.py` fills `report.template.html` from it and
writes `reports/relatorio-prs-<handle>.html`.

```bash
scripts/fetch.sh --org YOUR_ORG --window 2025-11-01 marcelometal
python3 scripts/generate.py marcelometal
```

Then open `reports/relatorio-prs-marcelometal.html`.

## Important: run as the right account

The GitHub Search API **only returns PRs from repositories the authenticated
account can see**. If you run it with a token that lacks access to private
repos where the person contributes, the numbers come out lower than the real
ones. For complete numbers, run authenticated as the person themselves
(`gh auth status`) or as an account that can reach the relevant repositories.

## Requirements

- [`gh`](https://cli.github.com/) authenticated (`gh auth login`)
- `jq`
- `python3`
- `node` (optional, only to validate the HTML)

## Fetch options

```
scripts/fetch.sh --org ORG [options] <handle>

  --org ORG             (required) org/owner to scan
  --name "Name"         display name (default: the GitHub profile)
  --window YYYY-MM-DD   only PRs created on or after this date (default: all)
  --monorepos a,b,c     repos to break down into sub-projects
  --monorepo-depth N    path depth of the sub-project key (default: 1)
```

Env: `GAP` (sleep between search pages, default 4s) and `FGAP` (sleep between
per-PR files calls, default 1.2s). The fetch is throttled on purpose to stay
under GitHub's secondary rate limit on high-volume accounts, so it can take a
few minutes.

### Monorepos

For monorepo repositories, the fetch can break PRs down by sub-project, using
the dominant directory of the changed files. For example, `--monorepos
go-monorepo,web --monorepo-depth 2` groups by `packages/apps`, `libs/foo`, and
so on. Without `--monorepos`, each PR stays at the repository level.

## Data model (`data/<handle>.json`)

- `data[]` (authored) and `reviews[]` (participation). Fields: `n` number, `t`
  title, `r` repo, `s` `merged|open|closed`, `d` creation date `YYYY-MM-DD`,
  `u` URL, `p` sub-project (optional), `a` author (reviews), `k`
  `review|comment`.
- Meta: `handle`, `name`, `generated`, `org`, `window`.
- `lede` (optional) overrides the auto-generated summary; `themes` (optional)
  is the editorial "key work streams" section, a list of `{title, meta, text}`.

## Validation (optional)

The `reports/*.html` is self-contained (inline CSS and JS). To check that the
script runs without a runtime error, you can execute its `<script>` in a Node
DOM shim and confirm that `#chart`, `#repos`, `#rows`, and `#rrows` populate.

## License

MIT. See [LICENSE](LICENSE).
