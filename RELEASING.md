# Releasing

A release is a tag on `main`. The workflow in `.github/workflows/release.yml` does the rest.

1. Bump `cryoCIVersion` in `Sources/CryoCICLI/Context.swift` to the new version in a PR, and merge it.
2. Tag the merge commit on an up-to-date `main` and push the tag:

   ```sh
   git checkout main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

3. The workflow checks that the tag matches `cryoCIVersion`, runs `swift build` and `swift test`, builds
   `cryo-ci-X.Y.Z.tar.gz` and its `.sha256` with `git archive`, attests the tarball (build provenance),
   and publishes a GitHub release with generated notes. Verify the attestation with
   `gh attestation verify cryo-ci-X.Y.Z.tar.gz --repo rizwankce/cryo-ci`.
4. Publish the Homebrew formula and bottle by running `scripts/bump.sh` in the
   [homebrew-tap](https://github.com/rizwankce/homebrew-tap) repo.

Release notes are grouped by PR label (see `.github/release.yml`): `bug`/`fix`, `enhancement`/`feature`,
`documentation`, everything else last. `Package.swift` depends on tagged releases of the `cryo` package,
so a change that needs new cryo API waits for a cryo release first.
