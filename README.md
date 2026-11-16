# cryo-ci

**GitHub Actions jobs on cryo capsules.** `cryo-ci` watches your repos for queued jobs that ask
for a `cryo` label, leases a clean macOS VM from the [cryo](https://github.com/rizwankce/cryo) bay
on the same Mac for each job, starts a one-job GitHub runner in it, and gives the VM back when the
job is done. Every job gets a fresh Mac; nothing carries over from the last one.

```yaml
jobs:
  test:
    runs-on: cryo-xcode-27.2   # or `cryo`, or `cryo-macos-27`
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -parallel-testing-enabled NO
```

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [How it works](#how-it-works)
- [Building](#building)
- [Docs](docs/ci.md)
- [License](#license)

## Requirements

- A Mac running a [cryo](https://github.com/rizwankce/cryo) bay: Apple silicon, macOS 27. macOS 26
  and earlier are not supported.
- A GitHub token with admin rights on the repos (to register one-job runners).

## Install

On the bay's Mac:

```sh
brew install rizwankce/tap/cryo-ci
cryo-ci github login                     # stores the token in the login Keychain
cryo-ci install --repo owner/name        # runs `cryo-ci github` as the LaunchAgent dev.rizwan.cryo.ci
cryo-ci status
```

Or from a checkout: `scripts/build.sh` builds `cryo-ci` into `~/.cryo/bin`, next to `cryo`.
`cryo ci …` runs `cryo-ci …`, so either name works.

## How it works

1. Polls the repos for queued jobs every 10 s; no webhook or public URL needed.
2. Leases a capsule for a job whose labels the bay offers, then asks GitHub for a one-job runner
   config.
3. Copies the runner into the VM through the lease folder and starts it there.
4. Renews the lease while the job runs, and releases the capsule when the runner exits. Only
   default-branch runs save the repo's cache back.

Rules, labels, retries and commands: [docs/ci.md](docs/ci.md).

## Building

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
```

`cryo-ci` depends on the [cryo](https://github.com/rizwankce/cryo) package for the API types, the
bay client and the fake bay its tests use. The tests also run on Linux.

## License

Apache-2.0. See [LICENSE](LICENSE).
