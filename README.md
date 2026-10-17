# weakened-checks

Reports the changes a branch makes that weaken or bypass a check: a silenced lint, a skipped or deleted test, a re-accepted snapshot, a loosened bound, a changed check config. Coding agents reach for these when a check is in the way. Sometimes they're right, but they should never do it silently. Each finding has to be explained in the pull request, and where a project prohibits one, it can't merge unless the project's exceptions file allows it.

It replaces the `scripts/check-weakened.sh` copies in nota and conspector. Both of their test suites run here, unchanged, against this detector (`tests/ported/`).

| Piece | Where | How a project uses it |
|---|---|---|
| Detector | `check-weakened.sh` | Run by the action in CI, or from a clone in a git hook |
| GitHub action | `action.yml` | `uses: gaius-codius/weakened-checks@<release SHA>` in a `pull_request` job |
| Annotation rules | `rules/` (ast-grep) | Used by the detector; ast-grep is pinned in `scripts/install-ast-grep.sh` |
| Built-in lists and config parser | `lib/config.bash` | Shared by the detector and the hook |
| Claude Code hook | `agent/claude-protect-config.sh` | Symlinked into `~/.claude/hooks/` and registered in `~/.claude/settings.json`, once per machine |
| Project configs | `examples/` | nota's and conspector's configs; copy one as a starting point |

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
      - uses: gaius-codius/weakened-checks@<release commit SHA> # v1.x.y
```

Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/weakened-checks 'v1.*'`). Keeping the job name `Weakened checks are explained` means a branch ruleset that already requires that check doesn't need to change.

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

Without `PR_BODY` in the environment, advisory findings are only reported (exit 0). Prohibited findings exit 1 locally too, because no PR text can allow them. A missing commit or merge base exits 2 (for example, a shallow clone). It never reports "nothing found" in that case. If neither `AST_GREP` nor a matching `ast-grep` on `PATH` is found, the detector fetches the pinned version into `~/.cache/weakened-checks`.

A lefthook pre-push job, using a clone pinned to the same release as CI:

```yaml
pre-push:
  jobs:
    - name: weakened checks
      run: |
        wc=${XDG_CACHE_HOME:-$HOME/.cache}/weakened-checks/v1.x.y
        [ -x "$wc/check-weakened.sh" ] ||
          git clone -q --depth 1 -b v1.x.y https://github.com/gaius-codius/weakened-checks "$wc"
        if git rev-parse -q --verify origin/main >/dev/null; then "$wc/check-weakened.sh" origin/main HEAD; fi
```

## What it reports

The detector compares `HEAD` with its merge base with `BASE` (`git diff BASE...HEAD`). Changes that `BASE` gained after the branch left it are not counted. Each rule has an id, which the config uses to disable or prohibit it.

| Rule | Engine | Reported when the branch... |
|---|---|---|
| `check-config` | path | changes a check-config path (the list is below), this config, or the exceptions file |
| `cargo-lint-levels` | diff | edits a lint table or a lint level in any `Cargo.toml`. Adding `[lints]` / `workspace = true` doesn't count. |
| `cargo-workspace-lints` | path | adds or changes a member `Cargo.toml` (`cargo-members`) that doesn't inherit `[workspace.lints]`, in a workspace that has some |
| `check-bound` | diff | changes, deletes or untags a line tagged `check-bound` (below) |
| `tests-removed` | diff | deletes more tests than it adds: Rust `#[test]`/`#[proptest]`/`#[rstest]` in any file; Go `func Test`/`Fuzz` in `_test.go`; JS/TS `it(`/`test(` and Python `def test` in test paths. Counted over the whole diff, so moving a test isn't reported. |
| `snapshot` | path | modifies or deletes a snapshot or golden file (`snapshot-path`) |
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

Review then checks that the explanation holds up. This is the same line nota and conspector PRs already write.

A **prohibited** finding fails whatever the PR body says. The only way to allow it is an entry in the exceptions file. With an entry, the finding is listed as advisory again, together with the entry's reason, and it still needs the `Check changes:` line. The exceptions file is check config, so adding an entry is itself a finding, and review sees it.

## The config

`.github/weakened-checks.conf` (or the `config` input / `--config`) holds one directive per line. `#` starts a comment, and blank lines are ignored. An unknown directive or rule id is an error, so a typo can't quietly turn a check off. The config is read from `BASE`, so a branch can't relax the rules it is checked against. A branch that adds the first config is checked with that config, read from `HEAD`.

| Directive | Meaning |
|---|---|
| `config-path PATHSPEC...` | Check-config paths (git pathspecs, so `:(glob)` works). The first use replaces the built-in list. `@defaults` brings the built-in entries back. |
| `snapshot-path PATHSPEC...` | Snapshot and golden files. Built in: `*.snap`, `*.golden`, `**/__snapshots__/**`. |
| `test-path PATTERN...` | Test files (shell patterns where `*` also matches `/`). These are used for `ts-as-unknown` and for counting JS/TS and Python tests. Built in: `*.test.*`, `*.spec.*`, `*__tests__/*`, `tests/*`, `test/*`, `*_test.go`, `test_*.py`, `testdata/*`, `e2e/*` and the like. |
| `cargo-members PATHSPEC` | Crates that must inherit the workspace lints (built in: `:(glob)crates/*/Cargo.toml`). `none` turns this off. |
| `bound-tag WORD` | The bound tag (built in: `check-bound`) |
| `exceptions PATH` | The exceptions file (built in: `.github/weakened-checks-exceptions`), or `none` |
| `disable RULE...` | Turns rules off |
| `prohibit RULE PATTERN...` | Makes the rule's findings in matching paths prohibited (shell patterns where `*` also matches `/`). For `tests-removed`, the tests deleted and added in the files that match each pattern are counted together, so moving a test within the pattern is allowed. |

The built-in check-config list covers CI workflows and actions, CODEOWNERS, git hook configs (lefthook, pre-commit, husky), `scripts/check-*`, the Rust toolchain, clippy, rustfmt, typos, deny, nextest, cargo-mutants and `.cargo/config`, golangci-lint, `tsconfig*.json`, Biome, ESLint, Vitest, Jest, Playwright and Stryker configs, semgrep and gitleaks configs, and codecov. `lib/config.bash` holds the exact list. A project with nothing to prohibit can go without a config file.

For example, a project that keeps clinical code under `services/clinical/`:

```text
config-path @defaults scripts/verify-*.sh
prohibit ts-nocheck services/clinical/* app/src/lib/clinical/*
prohibit nosemgrep services/clinical/* app/src/lib/clinical/*
prohibit ts-as-unknown services/clinical/*
prohibit tests-removed services/clinical/*
```

`examples/nota.conf` and `examples/conspector.conf` reproduce the two old scripts' check-config lists. They prohibit nothing.

## The exceptions file

`.github/weakened-checks-exceptions` is read from `HEAD`. It holds one entry per line, `RULE PATTERN REASON...`, and `#` starts a comment:

```text
# rule        path pattern                         reason (required)
ts-nocheck    services/clinical/legacy/import.ts   generated from the vendor schema; GAI-123 types it
tests-removed services/clinical/*                  the dose tests moved to the shared suite in #456
```

An entry allows the rule's prohibited findings in the paths its pattern matches. For `tests-removed`, the pattern is matched against the prohibition's own pattern. An entry without a reason is an error. Protect the file with CODEOWNERS so that adding an entry needs the right reviewer.

## Moving from scripts/check-weakened.sh

For nota and conspector:

1. Copy `examples/<project>.conf` to `.github/weakened-checks.conf`.
2. Replace the `weakened` job's run step with the action (above), keeping the job name. conspector runs the base's copy of its script so that a PR can't change the check meant to catch it. The action, pinned by SHA in the workflow, gives the same guarantee: changing the pin is a change to `.github/workflows`, which is reported.
3. Point the lefthook pre-push job at a pinned clone (above).
4. Delete `scripts/check-weakened.sh`. In nota, `scripts/check-weakened.test.sh` also guards nota's own tree (that its bounds carry the tag, and that its sweeps report into the sweep helper). Keep those guards as a nota test and drop the detector cases, which now run here. In conspector, delete the check-weakened section of `scripts/check-scripts.test.sh`.

Differences from the old scripts, all checked against 20 merged PRs of each (`tests/compare-prs.sh`):

- Each project gets the other's rules. nota gains `rustfmt::skip` and the workspace-lints rule (all its crates comply), and both gain the new annotation rules and the extra bound and test languages.
- Lint-level changes use conspector's rule in both projects. Adding `[lints]` / `workspace = true` isn't a finding, and single-quoted levels are.
- Annotations are matched on the syntax tree rather than per line. Comments or strings that mention `unsafe` or `ignore` aren't findings, and an attribute written across several lines is. In conspector #53, a `#[cfg_attr(not(test), expect(dead_code, ...))]` split over four lines was missed by the old script and is caught here.
- The `added:` line names the file, the line and the rule: `added: crates/a/src/lib.rs:12: #[allow(dead_code)] [rust-allow]`.

## Claude Code hook

The detector reports a weakened check once a pull request is open. By then an agent stuck on a finding may have silenced it and built on top. `agent/claude-protect-config.sh` is a `PreToolUse` hook that asks you first: before an agent changes check config or adds a suppression, Claude Code shows you the reason and waits for your approval. It reads the same lists and config as the detector, so it serves Rust, Go and TypeScript repositories alike, and asks for a few things CI doesn't report (below). It needs bash 4.4, git and jq.

It replaces rust-ci's `agent/claude-rust-protect-config.sh`. Register one of them, not both, or each change asks twice.

What asks, with paths relative to the root of the git repository the file is in (of the working directory, for a Bash command):

- **Check config.** A path in the `config-path` list, read from `.github/weakened-checks.conf` as committed on the default branch (the first of `origin/HEAD`, `origin/main`, `origin/master`, `main`, `master`), so an uncommitted edit to it can't narrow what it protects. Without a committed config, the built-in list. Wherever the built-in list applies (no `config-path`, `@defaults`, or a config that doesn't parse), so do the hook's own paths: `docs/CODEOWNERS`, `.lefthook.yaml`, `lefthook-local.yml`/`.yaml` (also with a leading dot), `.github/zizmor.yml`/`.yaml`, `.github/actionlint.yml`/`.yaml`, and `.gitattributes` and `build.rs` at any depth. The config and the exceptions file always ask, by name, also with `disable check-config` or an `:(exclude)` pathspec. A config that doesn't parse protects the built-in list plus every pathspec on its `config-path` lines, and the hook says it didn't parse. A config at another path (the action's `config` input) isn't seen.
- **Claude Code's project settings and hooks**: `.claude/settings.json`, `.claude/settings.local.json` and anything under `.claude/hooks/`, at any depth, always ask, like the config (see "Protecting the hook itself" below).
- **`Cargo.toml`**, at any depth, only when the change touches the `[lints]`, `[workspace.lints]` or `[profile]` tables, or when the edit's old text isn't in the file (the hook can't tell). Each value is compared by its full dotted path, so the table a key sits under counts and its spelling doesn't: a dotted `lints.*` key moved under another table asks, and `clippy.unwrap_used = "deny"` under `[workspace.lints]` in place of `unwrap_used = "deny"` under `[workspace.lints.clippy]` doesn't.
- **A suppression added or widened** in a source file. An Edit is applied to the file as it is, and each match runs to the end of its attribute or comment, so `#[allow(dead_code)]` becoming `#[allow(dead_code, unused)]` asks, whichever part of it the edit replaces, and keeping one unchanged doesn't. Rust attributes are compared without their whitespace, so respacing one doesn't ask. A symlink is judged by its own name and by the file it points to. The rules are the detector's annotation rules, matched as text rather than on the syntax tree, so a suppression quoted in a string also asks:

  | Files | Suppressions |
  |---|---|
  | `.rs` | `#[allow(..)]`, `#[expect(..)]` (also in `cfg_attr`), `#[ignore]`, `#[should_panic]`, `#[rustfmt::skip]`, `#[cfg(any())]` / `#[cfg(not(all()))]` / `#[cfg(false)]` / `#[cfg(miri)]` |
  | `.go` | `//nolint`; `t.Skip`, `Skipf`, `SkipNow` in `_test.go` files |
  | `.ts`, `.tsx`, `.js` and the like | `@ts-nocheck`, `@ts-ignore`, `@ts-expect-error` without a reason, `eslint-disable`, `biome-ignore`, `it.skip`, `test.only`, `xit` and the like |
  | `.svelte` | the TS/JS ones, and `svelte-ignore` |
  | `.py` | `@pytest.mark.skip`/`skipif`/`xfail`, `@unittest.skip*`, `pytest.skip()`, `self.skipTest()` |
  | all of these, `.sh`, `.bash` | `nosemgrep` |
  | any file | `gitleaks:allow` |

  A rule the config disables doesn't ask: `#[should_panic]` goes with `rust-ignore`, and `#[cfg(miri)]` with the other disabling cfgs, which no rule turns off. `gitleaks:allow` has no rule, so nothing turns it off.
- **A Rust lint attribute removed or narrowed**: a `#![deny(..)]`, `#![forbid(..)]` or `#[warn(..)]`, or a `cfg_attr` applying one, that the file loses, or a lint dropped from its list, since a crate's `#![deny]` is a check too. Each level and lint is compared as a pair, so moving or respacing one doesn't ask, and adding a lint to the list doesn't either. `disable rust-allow` turns it off. `x as unknown as T` outside the test paths doesn't ask: it tells the agent that the detector will report it. Where the config prohibits `ts-as-unknown` and the exceptions file (read from `HEAD`) doesn't allow it, it asks.
- **Bash, best effort.** A command that names a protected path, or a directory holding one, and writes with `sed -i`, `perl -i`, `tee`, `mv`, `cp`, `rm`, `truncate`, `ln`, `install`, `patch`, `dd` or `git checkout`/`restore`/`rm`/`mv`/`apply`, or redirects into one (`>`, `>>`, `>|`); paths are resolved against the working directory, so a `cd` earlier in the command, or a path held in a variable, isn't followed. `cp` from a protected file asks too. Also: any write to a `Cargo.toml` (from a command line there's no telling which table it lands in; a `--manifest-path` argument doesn't count); a source file together with one of its suppressions, spaced or sed-escaped (`#[ allow(`, `#\[allow(`); a `.rs` file together with `deny` or `forbid`; `gitleaks:allow` in a command that writes. A write through any other program (a script, an editor) isn't seen.

What CI reports and the hook doesn't: tagged bounds, removed tests, snapshots, workspace-lints inheritance, `unsafe` and `no_mangle`. A rule the config prohibits among those still fails in CI.

What the hook asks for and CI doesn't report: its own paths above, `[profile]` tables, `#[should_panic]`, `#[cfg(miri)]`, removed or narrowed lint attributes, `gitleaks:allow`, and Claude Code's settings and hooks. A pull request with them passes CI as before.

Outcomes: `permissionDecision: "ask"` with the reason for a protected change; nothing otherwise, and nothing outside a git repository; `additionalContext` for an advisory note or when the check can't run (jq or git missing or failing, input jq can't read, `lib/` missing, an older bash). It never blocks. `WEAKENED_CHECKS_PROTECT_CONFIG=off` turns it off: in the environment Claude Code starts in, for every project, or under `env` in a project's `.claude/settings.local.json`, for that project. An agent's edit to that file asks, so you make that change yourself or approve it.

### Protecting the hook itself

A project's `.claude/settings.json` and `.claude/settings.local.json` can turn the hook off: `WEAKENED_CHECKS_PROTECT_CONFIG=off` (or rust-ci's `RUST_CI_PROTECT_CONFIG=off`, or a `WEAKENED_CHECKS_HOOK` pointing elsewhere) under `env`, `disableAllHooks`, or a changed `hooks` entry. A script under `.claude/hooks/` can be the hook a project registers. Checked with Claude Code 2.1.299: an agent's Write of an `env` setting to `.claude/settings.local.json` reached the hooks, and the Bash tool, on the next tool call of the same session. So these files always ask, at any depth (Claude Code reads them from the directory it starts in, which in a monorepo needn't be the repository root), and neither the config nor `disable check-config` can take them out. A Bash command naming a directory that holds them asks too, even when they're gitignored. They aren't in the detector's built-in list: they don't define what CI checks, and reporting them on pull requests would be noise. Settings outside the repository (`~/.claude/settings.json`, managed settings) aren't seen.

Install once per machine, from a clone of this repository (the hook finds `lib/` through its symlink, so keep the clone):

```sh
mkdir -p ~/.claude/hooks
ln -sf "$WEAKENED_CHECKS/agent/claude-protect-config.sh" ~/.claude/hooks/protect-config.sh
```

and register it in `~/.claude/settings.json`, under `hooks.PreToolUse`:

```json
{
  "matcher": "Edit|Write|MultiEdit|Bash",
  "hooks": [
    { "type": "command", "command": "\"$HOME\"/.claude/hooks/protect-config.sh", "timeout": 10 }
  ]
}
```

Differences from rust-ci v3's own rules (its `agent/rust-protect-remainder.sh`), besides the languages:

- It judges every git repository, not only those with a root `Cargo.toml`.
- It reads `Cargo.toml` without Python. Where rust-ci has no `tomllib` (Python before 3.11), its line heuristic asks for any new table header. This hook asks only when the lints or `[profile]` values change, which is what rust-ci does with `tomllib`.
- It protects Claude Code's project settings and hooks, which rust-ci's rules don't.
- Respacing an `#[allow]`, or writing a lints table another way with the same lints, doesn't ask in either.

`docs/CODEOWNERS` and `.lefthook.yaml` move from the hook's own list to the built-in list in the next major version (#4).

## Changing weakened-checks

CI (`ci.yml`) runs these checks:

- `tests/test-rules.sh`: the rules load, each rule id is one the detector knows, and the TypeScript rules' two copies match.
- `tests/test-detector.sh`: every rule, the config, prohibitions and exceptions, and one case for each gap the old scripts had (GAI-359, GAI-379, GAI-413, GAI-422, GAI-480), each as the diff it should catch.
- `tests/test-protect-hook.sh`: the Claude Code hook, with every case of rust-ci's hook test ported (the differences above are marked) and cases for Go, TypeScript, Svelte, Python, a repository with a config and one without, and Claude Code's settings.
- `tests/run-ported.sh`: nota's and conspector's suites, unchanged. nota's suite runs against a fetch of nota at the commit it was taken from.
- shellcheck and actionlint.
- The `actions` job runs `action.yml` against fixture repositories. It checks that an explained advisory finding passes, an unexplained one fails, and a prohibited one fails even when explained.

`rules.yml` runs the action on this repository's own pull requests. Here the ported suites and `examples/` are check config, so a change to what parity means needs a `Check changes:` line.

When nota's or conspector's suite changes, refresh the copy with `tests/ported/extract.sh nota|conspector CHECKOUT [REF] > tests/ported/...`. For nota, also set `nota_commit` in `tests/run-ported.sh`. `NOTA_DIR=... CONSPECTOR_DIR=... tests/run-ported.sh` reports a copy that has drifted.

To bump ast-grep, set `version` and the four SHA-256s in `scripts/install-ast-grep.sh` (the release's asset digests: `gh api repos/ast-grep/ast-grep/releases/tags/<v> --jq '.assets[] | "\(.name) \(.digest)"'`), and the pin in `mise.toml`. Grammar changes can change what the rules match, so a bump is its own pull request.

A change that would fail a project that passed before is a new major version: a new rule on by default, a wider built-in list, or a new required input. A new rule that is off by default isn't, and nor is the hook asking for more (its own paths, a new pattern), since CI's results don't change.

### Releasing

A release is one commit on `main` tagged `v1.x.y`:

1. Check that `main` is green and that the commit to release is the one you mean. The release is the merge commit of the last PR, so no separate release commit is needed: nothing in this repository refers to its own version.
2. Tag it and push the tag: `git tag v1.x.y <SHA> && git push origin v1.x.y`. CI runs again on the tag.
3. Move the `v1` tag to it: `git tag -f v1 v1.x.y && git push -f origin v1`. This is a convenience for reading, since projects pin SHAs.
4. Never move or delete a `v1.x.y` tag. A repository ruleset ("Release tags") rejects updates and deletions of `v1.*` tags. It doesn't cover the moving `v1` tag.

A branch ruleset ("main checks") requires the `self-test` and `actions` checks before anything merges into `main`. Repository admins can bypass it. Merge pull requests with a squash merge.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT), at your option.
