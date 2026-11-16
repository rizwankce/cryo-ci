# GitHub Actions on capsules

> Running GitHub Actions jobs on capsules: one job per capsule, a one-job runner started inside it,
> with your own GitHub token on the bay's Mac. The bay: [cryo](https://github.com/rizwankce/cryo)
> ([bay](https://github.com/rizwankce/cryo/blob/main/docs/spec/bay.md),
> [CLI](https://github.com/rizwankce/cryo/blob/main/docs/spec/cli.md)).

`cryo-ci` is its own program, a client of the bay like `cryo lease`; `cryo ci …` runs it with the
same arguments, so `cryo ci github …` and `cryo-ci github …` are the same command. Build and install
it with `brew install rizwankce/tap/cryo-ci`, or `scripts/build.sh` from a checkout (to `~/.cryo/bin`, next to `cryo`). The runner's ssh uses
`cryo ssh <id>` as its ProxyCommand, with the `cryo` next to cryo-ci, else the first on PATH.

## Flow

```
 GitHub: job queued for runs-on: cryo-xcode-27.2
   ① cryo ci (on the Mac) polls queued jobs every 10 s
   ② leases a capsule first (cache <repo>, wait 600 s): while the bay is full nothing is registered
   ③ asks GitHub for a one-job runner config (JIT config) with the job's labels, under a new
     runner name per attempt (cryo-<host>-<job id>-<random>)
   ④ stages the runner tarball in the lease folder (APFS clone), copies it onto the VM disk over
     SSH, unpacks and starts it there with the JIT config on stdin
   ⑤ GitHub runs the job on it (checkout, build, test, upload); cryo ci renews the lease every
     minute and looks at the job once a minute
   ⑥ runner exits → release (cache saved only for default-branch, non-PR runs) → refill
```

## Rules

- **One job, one capsule:** the runner registers for a single job and is gone after it.
- **Runner not in the image:** `cryo ci` keeps the latest runner release tarball in
  `~/.cryo/runner/` (checked daily, SHA-256 checked against the release notes, never unpacked on
  the host) and copies it in through the lease folder; images stay generic.
- **Retries:** a job whose runner never took it (SSH failed, the runner didn't start) is tried
  again, 3 attempts in all; no capsule or no runner config also retries on the next tick.
- **Watching:** once a minute per running job; if the job was cancelled, is over, or another
  runner took it, the runner is stopped and the capsule released.
- **GitHub API:** lists are paged; a rate limit pauses all calls until GitHub's reset time (a
  minute when it gives none); a 401 re-reads the token (`GITHUB_TOKEN` or the Keychain) instead of
  failing every tick; runs with nothing left to take aren't re-read until they change (or 5 min).
- **Stopping:** SIGINT, SIGTERM or SIGHUP (`cryo ci uninstall`, logout) stops taking jobs, stops
  the runners, releases their capsules without a cache write and deletes the runners (up to
  60 s). A new `cryo ci` first releases the capsules and deletes the runners a killed process left
  in `~/.cryo/ci-state.json`.
- **Polling, not webhooks:** no public URL needed; ~10 s interval, within API limits for a few repos.
- **Labels:** one label is enough: `runs-on: cryo-xcode-27.2`. A bay offers `cryo` (any capsule),
  `cryo-<image tag>` (`cryo-xcode-27.2`) and `cryo-macos-<major>` (`cryo-macos-27`); no size, every
  capsule is the same. `self-hosted` is optional. A job asking for a label the bay doesn't offer
  is left for another runner.
- **Caches:** every job reads the repo's cache; only default-branch runs save it back (trust rule).
- **Sharing:** CI and agents share the bay's 2 capsules and its first-come queue.
- **Timeout:** the lease idle timeout is the job's `timeout-minutes` + 10 min, capped at 24 h.

## Commands

```
cryo ci github login [--token T]                       GitHub token with admin rights on the repos (or on stdin)
cryo ci github --repo owner/app [--repo …] [--labels cryo,cryo-xcode-27.2] [--timeout-minutes 360]
cryo ci status [--json]                                jobs seen, running, last results
cryo ci install --repo owner/app [--repo …] [--labels …] [--timeout-minutes N]   the same, as a LaunchAgent
cryo ci uninstall
cryo ci --help
```

`--labels` defaults to what the bay offers (`cryo`, `cryo-<image tag>`, `cryo-macos-<major>`);
`cryo ci github` waits up to 120 s for a bay to answer to learn the image tag.
`--timeout-minutes` (default 360) sets the lease idle timeout (+10 min), since the jobs API doesn't
return a job's `timeout-minutes`.

Runs as a LaunchAgent next to the bay: `cryo ci install` writes
`~/Library/LaunchAgents/dev.rizwan.cryo.ci.plist` (this binary + `ci github` + the options; `RunAtLoad`,
`KeepAlive`, log `~/.cryo/ci.log`) and bootstraps it into `gui/<uid>`; it refuses without a stored
token (the agent doesn't see `GITHUB_TOKEN`). Token stored in the login Keychain (service
`dev.rizwan.cryo.ci`, account `github`).

## Workflow

```yaml
jobs:
  test:
    runs-on: cryo-xcode-27.2
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -parallel-testing-enabled NO
```
