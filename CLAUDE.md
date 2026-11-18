# cryo-ci

> Instructions for coding agents working in this repo. `AGENTS.md` is a symlink to this file, so
> edit `CLAUDE.md` only.

`cryo-ci` runs GitHub Actions jobs on [cryo](https://github.com/rizwankce/cryo) capsules: it polls
repos for queued jobs with a `cryo` label, leases a clean macOS VM from the bay on the same Mac,
starts a one-job runner in it, and releases the VM when the job ends. It is a client of the bay,
like `cryo lease`; `cryo ci …` runs `cryo-ci …`.

## Words

bay = Cryo on one Mac · capsule = one VM position (max 2 per Mac) · lease = one client's use of a
capsule (`L81`). Full list: cryo's
[docs/glossary.md](https://github.com/rizwankce/cryo/blob/main/docs/glossary.md).

## Layout

- `Sources/CryoCI`: the poller, GitHub API, runner launch in the VM, state, token storage.
- `Sources/CryoCICLI` + `Sources/cryo-ci`: the command line.
- `Tests/CryoCITests`: runs against cryo's in-process `FakeBay`.
- `docs/ci.md`: flow, rules, labels, retries and commands. `scripts/build.sh`: release build to
  `~/.cryo/bin`.
- Depends on the `cryo` package (`CryoAPI`, `CryoHTTP`, `CryoClient`, `FakeBay`), pinned in
  `Package.swift`/`Package.resolved`. A change that needs new cryo API lands and is released in
  cryo first, then this repo bumps the dependency.

## Build, test, lint

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
shellcheck scripts/*.sh
scripts/build.sh          # release build to ~/.cryo/bin, next to cryo
```

CI runs lint (swift-format, shellcheck, actionlint), `swift test` on Linux, and `swift test` plus
a release build on macOS 27. Run all of the above before a PR.

## Rules

- macOS 27 only; no support for macOS 26 or earlier. The code and tests must keep building on Linux.
- Swift 6 language mode, strict concurrency. Tabs, 160-column lines (`.swift-format`).
- Tests use Swift Testing (`import Testing`) and `FakeBay`: no real bay, VM, GitHub token or
  network access.
- Never register runners, call GitHub or touch the host's real bay or `~/.cryo` from tests or
  scripts without being asked. Tokens live in the login Keychain; never print or log them.
- Replace installed binaries (copy then `mv`), never overwrite in place, or the next launch is killed.
- Changing behaviour, commands or labels means updating `docs/ci.md` and the README.

## Git

- Branch off an up-to-date `main`: `fix/`, `feature/` or `other/` plus kebab-case.
- Commit messages: plain description of why, subject under ~72 chars, no emojis.
- PR titles complete "If applied, this PR will …": no `fix:`/`feat:` prefixes. Bodies: a short
  summary, a bulleted list of changes, and a **Test plan** when behaviour changes.
- Merge only when CI is green.
