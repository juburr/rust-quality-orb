# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, that holds Rust code to a standard on every commit. It installs a checksum-verified Rust (a pinned release, or rustup and a toolchain), cargo-nextest, cargo-llvm-cov, cargo-hack, cargo-semver-checks and cargo-shear, and wraps the checks around them and rustfmt, clippy and rustdoc: `fmt`, `lint`, `docs`, `test`, `coverage`, `msrv`, `features`, `unused_deps` and `semver_checks`. Security checks (cargo-audit, cargo-deny, cargo-vet, SBOMs) are rust-security-orb's; building and caching projects is `circleci/rust`'s.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh actions/*.sh tests/*.sh tests/install_fixtures/*.sh

# Tests (offline; commands_test.sh needs cargo with rustfmt and clippy, and jq)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh lint working_dir=tests/fixtures/dirty

# Generate SHA-512 checksum table entries for a new release of one tool
./src/install/<tool>/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/`
  - `install.yml` - Installs the tools named in `tools`, through one `install_<tool>` step per tool, each picked by a `when: condition: matches:` on the `tools` string (`^(.*[ ,])?<tool>([ ,].*)?$`). Its first step, `scripts/install_tools.sh`, rejects unknown names, and `rust` together with `rustup`. The toolchain goes first.
  - `install_<tool>.yml` - One per tool, in the family's standard install command shape: cache key from `scripts/cache_key.sh` (and for `install_rust`, a second from `scripts/rust_cache_key.sh` naming the components and targets), `restore_cache`, the tool's `install/<tool>/install.sh`, `save_cache`. `ORB_NAME` is `rust-quality-orb-<tool>`, so each tool has its own cache directory and key.
  - `fmt`, `lint`, `docs`, `test`, `coverage`, `msrv`, `features`, `unused_deps`, `semver_checks` - One script each in `scripts/`. `msrv` also caches toolchains, keyed by `scripts/msrv_cache_key.sh` (the Rust versions the packages declare), and passes `install/rust/install.sh` to its script as `SCRIPT_RUST_INSTALL`.
- `install/<tool>/install.sh` and `install_hash.sh` - Kept outside `scripts/`, because `tests/shell_conventions_test.sh` exempts only `src/scripts/install.sh`, `install_hash.sh` and `cache_key.sh` by exact path. orb pack ignores the directory; commands include its files with `<< include(install/<tool>/install.sh) >>`.
- `scripts/lib/rust_quality.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_RUST_QUALITY_LIB: << include(scripts/lib/rust_quality.sh) >>` and `eval`ed after a check that it is set. Only defines functions and variables; no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below).
- `../schemas/run-record.v1.json` - The run record's JSON Schema. Its URL is in every run record, so fields are only ever added within v1.

### Install scripts (`src/install/<tool>/install.sh`)

Each follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`. The tool definition holds a helper block, `# >>> rust-quality-orb install helpers >>>` to `# <<< ... <<<`, identical in all seven scripts (`tests/install_test.sh` checks): `rq_musl_triple`, `rq_gnu_triple`, `rq_download_base_url` (an `https://` mirror replacing the default host, refusing credentials, a query or a fragment), `rq_install_record` (writes `.<binary>.install.json` beside the binary, which `rq_tool_verified` and the run records read) and `rq_install_prebuilt`.

The default `install_path` of the cargo tools is `~/.rust-quality-orb/bin`, not `~/bin` as in most juburr orbs: cimg/rust puts `~/.cargo/bin` first on the `PATH`, and the shared logic only adds a directory that isn't on it yet, so a copy there would win. A directory of the orb's own is added first.

- **cargo-nextest, cargo-llvm-cov, cargo-hack, cargo-semver-checks, cargo-shear**: the static (musl) GitHub release archive; the table holds the binary's SHA-512. `install_hash.sh` checks the archive against the SHA-256 in taiki-e/install-action's manifest for the tool (`raw.githubusercontent.com/taiki-e/install-action/main/manifests/<tool>.json`). cargo-shear 1.12.0 to 1.12.3 have no musl build, and cargo-nextest 0.9.147 was never released.
- **rust**: the table pins the SHA-512 of the release's channel manifest (`channel-rust-<version>.toml`, the same for both architectures). `tool_install` reads `[pkg.<name>.target.<triple>]` entries from it (following `[renames]`: clippy is `clippy-preview`; rust-src's target is `"*"`), fetches each component (the `.tar.xz` when `xz` exists, else the `.tar.gz`) through the cache, checks it against the manifest's SHA-256, runs each archive's own `install.sh --prefix=… --disable-ldconfig` into a staging directory beside `install_path`, smoke-tests cargo and rustc, and only then swaps it in. `install_path` must be missing, hold no files, or be an earlier installation (`bin/rustc` and `lib/rustlib/rust-installer-version`). `install_hash.sh` verifies the manifest's OpenPGP signature with the Rust release key (fingerprint `108F66205EAEB0AAA8DD5E1C85AB96E6FA1BE5FE`, pinned; the key itself comes from `static.rust-lang.org/rust-key.gpg.ascii`) and its `.sha256`, and that the manifest offers rustc, cargo, rust-std, clippy, rustfmt and llvm-tools for each triple. The table covers every stable release from 1.56.0. The shared install contract assumes one download per install, so `tests/install_rust_test.sh` tests it instead, with stand-in manifests and components.
- **rustup**: `rustup-init` (the glibc build) from `static.rust-lang.org/rustup/archive/<version>/<triple>/`, checked by `install_hash.sh` against the `.sha256` beside it. `tool_install` runs it with `--no-modify-path --profile minimal --default-toolchain none` into `install_path` (rustup's `CARGO_HOME`, default `CARGO_HOME` or `~/.cargo`), then installs `toolchain` (or the `rust-toolchain.toml` found upward from the working directory, or stable; `none` skips it) and makes it the default. A mirror becomes `RUSTUP_DIST_SERVER` unless that is set. Non-default `CARGO_HOME`/`RUSTUP_HOME` are exported.

When a tool's default version changes, change it in `install_<tool>.yml` and in `install.yml`'s `<tool>_version`, then regenerate the actions; `tests/wiring_test.sh` fails when the YAML defaults differ, `tests/actions_test.sh` when an action's do. A new cargo-semver-checks release must read the default Rust's rustdoc JSON (its `trustfall_rustdoc` features name the format versions; Rust's `src/rustdoc-json-types/lib.rs` names each release's).

### Command scripts (`src/scripts/`)

Every check runs in `working_dir`, on the workspace `cargo metadata --no-deps` finds there (`rq_metadata`), for every member or the `packages` named (`rq_package_args`: `--workspace` or `-p` each, each a member). Every check takes `output_dir`, `report_name`, `junit`, `run_record`, `report_only` (all but `test`) and `store_artifacts`, and first removes what an earlier run with the same `report_name` left (`rq_clear_reports`), so no stale report is stored with this run's. The rule every gate follows: findings fail the step unless `report_only` is true; a tool that didn't complete, or that would pass while checking nothing, always fails it. Each script tells them apart from the tool's output, not only its exit code:

- **fmt**: `cargo fmt --all|-p … --check --message-format short` lists the files it would change on stdout and exits 1, and exits 1 for a file it can't parse too, with an error on stderr: that, or a non-zero exit with no files, is an error. Paths are made relative to the workspace root. A second run with `-- --color never` writes the diff. `extra_args` go to rustfmt after `--`.
- **lint**: `cargo clippy … --message-format=json -- <lint_args> --cap-lints warn`, so a denied lint doesn't stop the build at the first crate: every lint is a warning and a finding, and a build that still fails has code that doesn't compile. `RQ_DIAGNOSTICS_JQ` classifies cargo's messages: a lint is a diagnostic whose code is a lint name (`dead_code`, `clippy::x`, `rustdoc::x`); `E0000` codes and uncoded errors are errors; findings are deduplicated by code, file, line, column and message (cargo reports a lint once per target). SARIF only for a complete run. `--cap-lints` in `lint_args` is refused.
- **docs**: `cargo doc --no-deps --message-format=json`, adding no rustdoc flags, so `RUSTDOCFLAGS` apply. A run that failed is complete only when denied lints (error-level findings) stopped it.
- **test**: cargo-nextest with JUnit turned on through `--tool-config-file rust-quality-orb:<file>` (`[profile.<profile>.junit] path = "rust-quality-orb-junit.xml"`, written to `<target>/nextest/<profile>/`), which the repository's config overrides. Exit codes: 0 and 100 (failing tests, which the JUnit must name) are results, 4 is no tests with `no_tests: fail`, 101 is a build failure, anything else an error. The JUnit is read with awk (testcase, failure, flakyFailure, XML entities). Then `cargo test --doc` for packages with a library, on node 0 only with `partition`; its `test … ok|FAILED|ignored` lines are the doctests, and a failure without `test result: FAILED` and a failed test is a build error. `partition` reads `CIRCLE_NODE_TOTAL`/`CIRCLE_NODE_INDEX` (`--partition hash:<n>/<total>`).
- **coverage**: `cargo llvm-cov clean --workspace`, then one `llvm-cov [nextest] --no-report` run, then `llvm-cov report` once per format (`--json --summary-only`, `--lcov`, `--cobertura`, `--html`), all with `CARGO_TERM_COLOR=never`. `coverage_min` compares `covered * 100 < min * count` with awk, never a rounded percentage. A test run that fails is an error, with a hint when llvm-tools is missing.
- **msrv**: groups the selected packages by `rust_version` (or their `rust-version`), skipping those without one (none at all is an error), and runs `cargo check -p …` once per version. `toolchain_source` `rustup` runs `rustup toolchain install V --profile minimal --no-self-update` and `rustup run V cargo`; `rust` runs `SCRIPT_RUST_INSTALL` from the step's work directory with `BASH_ENV` pointed at a scratch file (nothing reaches later steps) into `<work>/toolchains/<release>`, and runs its cargo with `RUSTUP_TOOLCHAIN` unset and `RUSTC`/`RUSTDOC` set; `rust_release` picks the newest patch release the table lists for `1.70`. A version the table lacks is an error under `strict`, `x.y.0` otherwise. A failing check prints a hint about Cargo.lock version 4 needing Rust 1.78.
- **features**: one `cargo hack <subcommand> … --each-feature|--feature-powerset [--depth] --keep-going --log-group none --color never` run per target (`--log-group none`, since on GitHub Actions cargo-hack would print `::group::` lines instead of `info: running`). Each combination starts with an `info: running \`<cmd>\` on <package> (i/n)` line and failed when an `error` line follows before the next; a run with failures ends with `failed to run N commands`. A non-zero exit without that summary is cargo-hack failing.
- **unused_deps**: `cargo shear --format json --color never` (cargo-shear has no `--workspace`: no `-p` means the whole workspace). Exit 2, or output that isn't one JSON object with `summary` and `findings`, is an error (on failure cargo-shear writes `error: …` to stdout in place of the report). Errors are findings, and warnings with `deny_warnings` (passed as `--deny-warnings`, so exit 1 must agree with the report). Each finding's byte `offset` in its file (relative to the workspace root) becomes a line and column (`LC_ALL=C awk`). A positional directory in `extra_args` is refused.
- **semver_checks**: `cargo semver-checks check-release`, with output parsed from the combined log: `Checking <pkg> v<base> -> v<cur> (<change>)` and `Summary …` status lines (stderr, right-aligned to 12 columns), and `--- failure|warning <lint>: <name> ---` sections (stdout) with the items under `Failed in:`. Failures are findings; warnings are reported. 0.49.0 and later exit 100 for failed lints and 101 for errors; earlier releases exit 1 for both, told apart by an `error` line. A run that checked no package (workspace members with `publish = false` are skipped unless named) is an error. `-q` would hide the status lines, so it is refused.

### Shared helpers (`scripts/lib/rust_quality.sh`)

- `rq_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (local runs and GitHub Actions). `rq_list` substitutes and splits on commas and spaces; `rq_words` splits `extra_args` with `split_shell_words` (the parser container-ops-orb, oras-orb, crane-orb, skopeo-orb, rust-security-orb and the Go orbs use), refusing `$(...)`, backticks and shell operators outside quotes. `rq_extra_args VALUE OPTION...` also refuses options a command sets itself.
- `rq_bool`, `rq_match` (`[[ =~ ]]` in the C locale), `rq_uint`, `rq_output`/`rq_clear_reports`, `rq_tool`/`rq_tool_verified` (warns when a binary isn't the one its install record names), `rq_cargo`, `rq_require_jq`, `rq_metadata`, `rq_package_args`, `rq_feature_args`, `rq_export`, `rq_json_is` (never `jq -e` on a tool's output: jq 1.6 exits 0 on an empty file), `rq_sha256`, `rq_url_public`, `rq_tail`.
- `RQ_DIAGNOSTICS_JQ`, `rq_print_findings`, `rq_print_errors`, `rq_findings_junit`, `rq_sarif` for cargo's JSON messages.
- `rq_junit FILE SUITE CASES_JSON`, `rq_gate FINDINGS REPORT_ONLY SUMMARY`, `rq_plural`.
- `rq_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED` writes the run record from `RQ_TOOL`, `RQ_TOOL_VERSION`, `RQ_ARGS`, `RQ_INPUTS` (`role:path`; `rq_workspace_inputs` adds the lockfile, toolchain file and members' manifests), `RQ_REPORTS`, `RQ_COUNTS` and `RQ_RESULTS`, with `rq_ci_json` (CircleCI or GitHub Actions), `rq_tool_json` (SHA-512 and install record), `rq_toolchain_json` (cargo, `rustc -vV`, the rustup toolchain, and `RUSTFLAGS`, `RUSTDOCFLAGS`, `CARGO_BUILD_TARGET`, `CARGO_TARGET_DIR`, `RUSTUP_TOOLCHAIN`) and `rq_args_json` (URLs without credentials). Keep `schemas/run-record.v1.json` in step with it; `tests/commands_test.sh` checks every record it writes against it.
- Variables a script sets for the lib to read carry `# shellcheck disable=SC2034 # read by ...`, since shellcheck can't see into the eval'd lib.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_RUST_QUALITY_LIB=<lib>` (and `SCRIPT_RUST_INSTALL=<install.sh>` for msrv), with `working-directory: ${{ inputs.working_dir }}`. Inputs never appear inside a `run:` script. A command that stores artifacts has a step that names the artifact `rust-quality-reports-<report_name>-<random>` and an `actions/upload-artifact` step with `if: always() && (inputs.store_artifacts == 'true' || inputs.store_artifacts == '1')`. Install actions and msrv restore and save `actions/cache` around the step, with the command's key ingredients. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. The actions were generated from the command YAML; keep them in sync by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number. `tests/actions_test.sh` checks all of this.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install` (`tests/install_test.sh`, the shared install contract for the five cargo tools and rustup against `tests/install_fixtures/`, then `tests/install_rust_test.sh`), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/commands_test.sh` on `cimg/rust:1.99.1`, then `tests/wiring_test.sh`), `test-actions` (`tests/actions_test.sh`), orb-tools lint, pack and review (`orb_name: rust-quality`), shellcheck.
- `.circleci/test-deploy.yml` - Runs against `tests/fixtures`: `clean` (a workspace of `app` and its path dependency `helper`, which every check passes), `dirty` (a package and an unused member: an unformatted file, a `needless_return`, a broken intra-doc link, a failing test, a `LazyLock` its 1.70 rust-version can't build, a feature that doesn't build alone, and an unused dependency) and `semver` (`baseline` 0.1.0 and `current` 0.1.1, which drops a public function). Jobs: `install-test` (everything on cimg/rust, the pinned binaries, the pinned Rust first on the `PATH`, a second install from the cache), `rustup-test` (on cimg/base, a named toolchain, then rust-toolchain.toml), `checksum-test` (unlisted versions fail closed, `known_versions`, a local HTTPS mirror serving the real cargo-shear release and then a tampered one), `arm64-test`, `checks-test` (every check passes on clean, and the checkout is left unchanged), `findings-test` (report_only reports every finding; each check fails by default; code that doesn't compile fails with report_only), `msrv-rustup-test` (the image's rustup), `machine-test` (no Rust in the image). Steps that must fail run through `tests/run_command.sh`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The actions on GitHub's runners: `offline-tests`, `install` (amd64 and arm64, pinned binaries, a second install from the cache, an unlisted version failing), `install-from-cache` (every download host blocked), `rustup`, `checks`, `findings`.

`tests/commands_test.sh` runs fmt, lint and docs with the real cargo, rustfmt, clippy and rustdoc against copies of the fixtures, and the others against stand-ins for cargo-nextest, cargo-llvm-cov, cargo-hack, cargo-shear, cargo-semver-checks, rustup and the CircleCI CLI, plus a `cargo` wrapper that answers `cargo test --doc` when a test asks. It must pass with bash 4.0, 4.3 and 5 first on the `PATH`, and with jq 1.6.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline; the fixture fragments in `tests/install_fixtures/` carry a `# shellcheck shell=bash` directive. `actionlint` checks `.github/workflows/actions.yml`, including the local actions' inputs.

Scripts pass parameter values to `circleci env subst` on stdin, as `rq_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` as unbound, even inside `${@+"$@"}`, so copy `"$@"` into an array only when `$#` is non-zero.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself. Under `pipefail`, a `grep` that matches nothing ends a pipeline with status 1, which in an assignment exits the script silently: end such a pipeline with `|| true`.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_RUST_QUALITY_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).
- Never name a variable after one bash sets itself (`GROUPS`, `UID`, `RANDOM`, `SECONDS`...): `declare -A GROUPS` fails.
- The scripts must work with jq 1.6: never `jq -e` on a tool's output, never name a jq variable `$module`, and bind a field before piping into another value (`.name as $name | $packages | contains($name)`, not `$packages | contains(.name)`, where `.` is no longer the package).

## Naming

Command names say what they check (`fmt`, `lint`, `docs`, `test`, `msrv`, `features`, `unused_deps`, `semver_checks`) or measure (`coverage`), in snake_case. Parameters that map onto one flag take its long name in snake_case (`all_targets`, `no_dev_deps`, `deny_warnings`, `baseline_rev`, `release_type`, `document_private_items`); `packages`, `features`, `locked` and `extra_args` mean the same in every command. Plumbing matches the other juburr orbs: `working_dir`, `output_dir`, `report_name`, `junit`, `run_record`, `report_only`, `store_artifacts`; lists take commas or spaces.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh actions/*.sh tests/*.sh tests/install_fixtures/*.sh`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH` and with jq 1.6
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`, and validate `.circleci/test-deploy.yml` with the packed orb spliced in under `orbs.rust-quality-orb`
- Run `actionlint .github/workflows/actions.yml`
- For changes to a command, also run it with the real tools against the fixtures through `tests/run_command.sh`, as `test-deploy.yml` does
