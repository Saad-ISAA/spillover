# Releasing

Releases are built on a Mac with `scripts/release.sh` and published as GitHub Releases. The
Homebrew cask lives in a separate tap repository.

## What a release contains

| File | For |
| --- | --- |
| `Spillover-<version>.dmg` | Most people: open it and drag Spillover to Applications. |
| `Spillover-<version>.zip` | Anyone who prefers a zip; also what Homebrew could use instead of the disk image. |
| `SHA256SUMS` | Checksums of both, to verify a download. |
| `spillover.rb` | The Homebrew cask for this version (goes into the tap, not the release). |

The app is universal (Apple silicon and Intel) and needs macOS 14 or later.

## Steps

1. Set the version in `Sources/spillover/main.swift` (`let version = "x.y.z"`) and add the release
   to `CHANGELOG.md`. Commit.
2. Run the tests: `swift test`.
3. Build the release from a clean working tree:

   ```sh
   scripts/release.sh
   ```

   Output goes to `dist/release/`. For a trial run with uncommitted changes, use
   `ALLOW_DIRTY=1 scripts/release.sh`.
4. Check the disk image: open it, drag the app to Applications on a test account or second Mac,
   and launch it.
5. Tag and publish (needs the GitHub CLI, `gh`):

   ```sh
   git tag -a vX.Y.Z -m "Spillover X.Y.Z"
   git push origin main vX.Y.Z
   gh release create vX.Y.Z dist/release/Spillover-X.Y.Z.dmg dist/release/Spillover-X.Y.Z.zip \
       dist/release/SHA256SUMS --title "Spillover X.Y.Z" --notes-file <notes>
   ```

   The notes are the version's section of `CHANGELOG.md`.
6. Update the tap: copy `dist/release/spillover.rb` to `Casks/spillover.rb` in
   `github.com/Saad-ISAA/homebrew-spillover`, commit and push. Check with
   `brew install --cask saad-isaa/spillover/spillover` on a clean machine.

## Signing and notarization

Without an Apple Developer ID the app is ad-hoc signed. It works, but the first launch on another
Mac needs **System Settings → Privacy & Security → Open Anyway**.

With a Developer ID (Apple Developer Program), releases open without that prompt:

1. Install the "Developer ID Application" certificate in your login keychain.
2. Save notarization credentials once:

   ```sh
   xcrun notarytool store-credentials spillover-notary \
       --apple-id <apple id> --team-id <team id> --password <app-specific password>
   ```

3. Build with both set:

   ```sh
   SIGN_IDENTITY="Developer ID Application: <name> (<team id>)" NOTARY_PROFILE=spillover-notary \
       scripts/release.sh
   ```

   The script signs the app with a secure timestamp and the hardened runtime, notarizes and
   staples it, then signs, notarizes and staples the disk image.

## Homebrew tap

The tap repository is `Saad-ISAA/homebrew-spillover` with one file, `Casks/spillover.rb`. Users
install with `brew install --cask saad-isaa/spillover/spillover`; the cask also links the
`spillover` command. The cask template is `packaging/homebrew/spillover.rb.in`; check changes with
`brew style` from inside the tap.
