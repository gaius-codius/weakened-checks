# weakened-checks

Reports the changes a branch makes that weaken or bypass a check: a silenced lint, a skipped or deleted test, a re-accepted snapshot, a loosened bound, a changed check config. Coding agents reach for these when a check is in the way. Sometimes they're right, but they should never do it silently. Each finding has to be explained in the pull request, and where a project prohibits one, it can't merge unless the project's exceptions file allows it.

nota's `check-weakened.sh` test suite runs here, unchanged, against this detector (`tests/ported/`).

| Piece | Where | How a project uses it |
|---|---|---|
| Detector | `check-weakened.sh` | Run by the action in CI, or from a clone in a git hook |
| GitHub action | `action.yml` | `uses: gaius-codius/weakened-checks@<release SHA>` in a `pull_request` job |
| Annotation rules | `rules/` (ast-grep) | Used by the detector; ast-grep is pinned in `scripts/install-ast-grep.sh` |
| Built-in lists and config parser | `lib/config.bash` | Sourced by the detector, and by other scripts that read the same config |
| Project config | `examples/` | nota's config; copy it as a starting point |

## Using it in CI

Add a job to a workflow that runs on `pull_request`, including `edited`, so that editing the PR body runs the check again:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]

permissions:
  contents: read

jobs:
  weakened:
    name: Weakened checks are explained
    if: github.event.pull_request.state == 'open'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<SHA> # v7.0.1
        with:
          fetch-depth: 0          # the detector needs the merge base
          persist-credentials: false
      - uses: gaius-codius/weakened-checks@<release commit SHA> # v2.x.y
```

Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/weakened-checks 'v2.*'`); the moving `v2` tag is for reading only. Keeping the job name `Weakened checks are explained` means a branch ruleset that already requires that check doesn't need to change.

Inputs (each has a default that suits a `pull_request` event):

| Input | Default | Meaning |
|---|---|---|
| `base` | the PR's base SHA | Commit to compare with |
| `head` | the PR's head SHA | Commit that is checked |
| `pr-body` | the PR's body | Text searched for the `Check changes:` line |
| `config` | `.github/weakened-checks.conf` | Config path from the repository root. If the default path is missing, the built-in defaults apply. Any other path must exist. |
| `working-directory` | `.` | The checkout, relative to the workspace |

The action needs bash 4, git, awk, jq, curl and unzip, all of which are on GitHub's Ubuntu runners. It downloads the pinned ast-grep into the runner's tool cache and checks its SHA-256 first. It only downloads it when the branch changes a file that ast-grep parses. The report also goes to the job summary.

## Running it locally

```sh
check-weakened.sh BASE [HEAD] [--config FILE]   # e.g. origin/main HEAD
```

Without `PR_BODY` in the environment, advisory findings are only reported (exit 0). Prohibited findings exit 1 locally too, because no PR text can allow them. A missing commit or merge base exits 2 (for example, a shallow clone). It never reports "nothing found" in that case. A config error also exits 2, after the report (see "The config"). If neither `AST_GREP` nor a matching `ast-grep` on `PATH` is found, the detector fetches the pinned version into `~/.cache/weakened-checks`.

A lefthook pre-push job, using a clone pinned to the same release as CI:

```yaml
pre-push:
  jobs:
    - name: weakened checks
      run: |
        wc=${XDG_CACHE_HOME:-$HOME/.cache}/weakened-checks/v2.x.y
        [ -x "$wc/check-weakened.sh" ] ||
          git clone -q --depth 1 -b v2.x.y https://github.com/gaius-codius/weakened-checks "$wc"
        if git rev-parse -q --verify origin/main >/dev/null; then "$wc/check-weakened.sh" origin/main HEAD; fi
```

## What it reports

The detector compares `HEAD` with its merge base with `BASE` (`git diff BASE...HEAD`). Changes that `BASE` gained after the branch left it are not counted. Each rule has an id, which the config uses to disable or prohibit it.

| Rule | Engine | Reported when the branch... |
|---|---|---|
| `check-config` | path | changes a check-config path (the list is below), this config, or the exceptions file. A file moved between check-config paths is reported at both. |
| `cargo-lint-levels` | diff | edits a lint table or a lint level in any `Cargo.toml`. Adding `[lints]` / `workspace = true` doesn't count. |
| `cargo-workspace-lints` | path | adds, changes or moves a member `Cargo.toml` (`cargo-members`) that doesn't inherit `[workspace.lints]`, in a workspace that has some |
| `check-bound` | diff | changes, deletes or untags a line tagged `check-bound` (below) |
| `tests-removed` | diff | deletes more tests than it adds: Rust `#[test]`/`#[proptest]`/`#[rstest]` in any file; Go `func Test`/`Fuzz` in `_test.go`; JS/TS `it(`/`test(` and Python `def test` in test paths. Counted over the whole diff, so moving a test isn't reported. A renamed file's tests count as leaving its old path, so renaming a test file out of the test paths is reported. |
| `snapshot` | path | modifies, deletes, or renames and modifies a snapshot or golden file (`snapshot-path`). A renamed one is prohibited where either its old or its new path is, and moving one unchanged out of a prohibited path is reported too. |
| `rust-allow` | ast-grep | adds `#[allow(..)]`/`#[expect(..)]`, outer or inner, including inside `cfg_attr` and across lines |
| `rust-ignore` | ast-grep | adds `#[ignore]`, also with a reason or under `cfg_attr` |
| `rust-rustfmt-skip` | ast-grep | adds `#[rustfmt::skip]` |
| `rust-no-mangle` | ast-grep | adds `no_mangle` |
| `rust-unsafe` | ast-grep | adds `unsafe` code (block, fn, impl, trait, extern, attribute). Reported at the `unsafe` line, so editing inside an existing block doesn't count. |
| `go-nolint` | ast-grep | adds a `//nolint` comment |
| `go-test-skip` | ast-grep | adds `t.Skip`/`Skipf`/`SkipNow` in a `_test.go` file |
| `ts-nocheck`, `ts-ignore` | ast-grep | adds `@ts-nocheck` / `@ts-ignore` |
| `ts-expect-error` | ast-grep | adds `@ts-expect-error` with no reason after it |
| `ts-as-unknown` | ast-grep | adds `x as unknown as T` outside the test paths |
| `eslint-disable`, `biome-ignore` | ast-grep | adds an ESLint or Biome suppression comment |
| `js-test-skip` | ast-grep | adds `it.skip`, `test.only`, `describe.skip`, `xit` and the like |
| `py-test-skip` | ast-grep | adds `@pytest.mark.skip`/`skipif`/`xfail`, `@unittest.skip*` or `pytest.skip()` |
| `nosemgrep` | ast-grep | adds a `nosemgrep` comment (Rust, Go, TS/JS, Python, shell) |
| `svelte-ignore` | regex | adds a `<!-- svelte-ignore -->` comment |

The ast-grep rules only see comments and code, never strings: `#[doc = "may ignore"]` isn't an ignore. They run on the branch's copy of each changed file, and a match counts when any of its lines is added. TypeScript files use the TypeScript grammar. JavaScript and TSX use the TSX grammar.

**Svelte.** ast-grep has no Svelte grammar, so in `.svelte` files a regex fallback checks the lines of `<script>` blocks for the TS/JS rules (`ts-*`, `eslint-disable`, `biome-ignore`, `ts-as-unknown`, `js-test-skip`). It checks every line for `nosemgrep` and `svelte-ignore`.

**Tagged bounds.** A bound that a test or harness checks (a loss limit, a lag bound, a sweep's coverage floor, a soak's pass limit) carries a `check-bound` comment on the line that sets it. Any change to that line is then reported, with `bound set:` for the new line and `bound was:` for the old one. That includes a new value, a deleted line or a dropped tag. In Rust, Go, TS/JS and Svelte, the tag is a `//` comment anywhere on the line. In `.sh`, `.bash` and `.py` files, it is a `#` comment that ends a line of code, so a tag quoted in a string or mentioned in a comment doesn't count. Lines are compared together with their file's path. A tagged line moved unchanged within its file isn't reported, but two files swapping values are. A bound loosened where it is compared, rather than where it is set, is left to review.

## Advisory and prohibited findings

Every finding is **advisory** unless the config prohibits its rule in its path. Advisory findings pass when the PR body has a line that starts, after optional spaces, with `Check changes:` (any case) followed by some text, for example:

```text
Check changes: the new crate's tests run under nextest's slow profile, so #[ignore] moves to its config.
```

Review then checks that the explanation holds up. nota's pull requests already write the same line.

A **prohibited** finding fails whatever the PR body says. The only way to allow it is an entry in the exceptions file. With an entry, the finding is listed as advisory again, together with the entry's reason, and it still needs the `Check changes:` line. The exceptions file is check config, so adding an entry is itself a finding, and review sees it.

## The config

`.github/weakened-checks.conf` (or the `config` input / `--config`) holds one directive per line. `#` starts a comment, and blank lines are ignored. An unknown directive or rule id is an error, so a typo can't quietly turn a check off. The config is read from `BASE`, so a branch can't relax the rules it is checked against. A branch that adds the first config is checked with that config, read from `HEAD`.

A `config-path`, `snapshot-path` or `cargo-members` entry that git rejects as a pathspec (`:(bogus)x`, say), or an `exceptions` path outside the repository, is a config error too. The detector reports the findings the other entries match, then the rejected entries, and exits 2. A branch that changes the config is also held to its own version: an error there fails the branch, so a broken config can't reach `BASE`. If `BASE`'s config already has errors and the branch's config has none, the branch that fixes it passes, and the errors are only reported.

| Directive | Meaning |
|---|---|
| `config-path PATHSPEC...` | Check-config paths (git pathspecs, so `:(glob)` works). The first use replaces the built-in list. `@defaults` brings the built-in entries back. |
| `snapshot-path PATHSPEC...` | Snapshot and golden files. Built in: `*.snap`, `*.golden`, `**/__snapshots__/**`. |
| `test-path PATTERN...` | Test files (shell patterns where `*` also matches `/`). These are used for `ts-as-unknown` and for counting JS/TS and Python tests. Built in: `*.test.*`, `*.spec.*`, `*__tests__/*`, `tests/*`, `test/*`, `*_test.go`, `test_*.py`, `testdata/*`, `e2e/*` and the like. |
| `cargo-members PATHSPEC` | Crates that must inherit the workspace lints (built in: `:(glob)crates/*/Cargo.toml`). `none` turns this off. |
| `bound-tag WORD` | The bound tag (built in: `check-bound`) |
| `exceptions PATH` | The exceptions file (built in: `.github/weakened-checks-exceptions`), or `none` |
| `disable RULE...` | Turns rules off |
| `prohibit RULE PATTERN...` | Makes the rule's findings in matching paths prohibited (shell patterns where `*` also matches `/`). For `tests-removed`, the tests deleted and added in the files that match each pattern are counted together, so moving a test within the pattern is allowed, and renaming a test file out of it isn't. |

In the shell patterns (`test-path`, `prohibit` and the exceptions file), a bracket expression matches either its own text or, as in bash, one character of its class. So `routes/orders/[id]/*` matches the route directory `routes/orders/[id]/`, and also `routes/orders/i/`. In the git pathspecs (`config-path`, `snapshot-path`), a bracket is a class, so write a bracket segment there as `*` or use `:(literal)`.

The built-in check-config list covers CI workflows and actions, CODEOWNERS, git hook configs (lefthook, pre-commit, husky), `scripts/check-*`, the Rust toolchain, clippy, rustfmt, typos, deny, nextest, cargo-mutants and `.cargo/config`, golangci-lint, `tsconfig*.json`, Biome, ESLint, Vitest, Jest, Playwright and Stryker configs, semgrep and gitleaks configs, and codecov. `lib/config.bash` holds the exact list. A project with nothing to prohibit can go without a config file.

For example, a project that keeps clinical code under `services/clinical/`:

```text
config-path @defaults scripts/verify-*.sh
prohibit ts-nocheck services/clinical/* app/src/lib/clinical/*
prohibit nosemgrep services/clinical/* app/src/lib/clinical/*
prohibit ts-as-unknown services/clinical/*
prohibit tests-removed services/clinical/*
```

`examples/nota.conf` reproduces nota's former check-config list. It prohibits nothing.

## The exceptions file

`.github/weakened-checks-exceptions` is read from `HEAD`. It holds one entry per line, `RULE PATTERN REASON...`, and `#` starts a comment:

```text
# rule        path pattern                         reason (required)
ts-nocheck    services/clinical/legacy/import.ts   generated from the vendor schema; GAI-123 types it
tests-removed services/clinical/*                  the dose tests moved to the shared suite in #456
```

An entry allows the rule's prohibited findings in the paths its pattern matches. For `tests-removed`, the pattern is matched against the prohibition's own pattern. An entry without a reason is an error. Protect the file with CODEOWNERS so that adding an entry needs the right reviewer.

## Changing weakened-checks

CI (`ci.yml`) runs these checks:

- `tests/test-rules.sh`: the rules load, each rule id is one the detector knows, and the TypeScript rules' two copies match.
- `tests/test-detector.sh`: every rule, the config, prohibitions and exceptions, and one case for each gap the earlier scripts had, each as the diff it should catch.
- `tests/run-ported.sh`: nota's suite, unchanged, against a fetch of nota at the commit it was taken from.
- shellcheck and actionlint.
- The `actions` job runs `action.yml` against fixture repositories. It checks that an explained advisory finding passes, an unexplained one fails, and a prohibited one fails even when explained.

`rules.yml` runs the action on this repository's own pull requests. Here the ported suite and `examples/` are check config, so a change to what parity means needs a `Check changes:` line.

When nota's suite changes, refresh the copy with `tests/ported/extract.sh nota CHECKOUT [REF] > tests/ported/nota/check-weakened.test.sh`, and set `nota_commit` in `tests/run-ported.sh`. `NOTA_DIR=... tests/run-ported.sh` reports a copy that has drifted.

To bump ast-grep, set `version` and the four SHA-256s in `scripts/install-ast-grep.sh` (the release's asset digests: `gh api repos/ast-grep/ast-grep/releases/tags/<v> --jq '.assets[] | "\(.name) \(.digest)"'`), and the pin in `mise.toml`. Grammar changes can change what the rules match, so a bump is its own pull request.

A change that would fail a project that passed before is a new major version: a new rule on by default, a wider built-in list, or a new required input. A new rule that is off by default isn't.

**`lib/` is an interface.** Other scripts, outside this repository, source `lib/config.bash` from a clone of it. A change to `lib/` must keep the names it defines (the rule list, the built-in lists, `wc_reset`, `wc_parse_config`, `wc_parse_exceptions`, `wc_match` and the `wc_config_error` callback) and what they do stable for those callers, or ship as a new major version.

### Releasing

A release is one commit on `main` tagged `v2.x.y`:

1. Check that `main` is green and that the commit to release is the one you mean. The release is the merge commit of the last PR, so no separate release commit is needed: nothing in this repository refers to its own version.
2. Tag it and push the tag: `git tag v2.x.y <SHA> && git push origin v2.x.y`. CI runs again on the tag.
3. Move the `v2` tag to it: `git tag -f v2 v2.x.y && git push -f origin v2`. This is a convenience for reading, since projects pin SHAs.
4. Never move or delete a `v2.x.y` tag. A repository ruleset ("Release tags") rejects updates and deletions of tags matching `v[0-9]*.*`. It doesn't cover the moving `v2` tag.

A branch ruleset ("main checks") requires the `self-test` and `actions` checks before anything merges into `main`. Repository admins can bypass it. Merge pull requests with a squash merge.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.
