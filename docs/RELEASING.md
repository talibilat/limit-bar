# Releasing LimitBar

LimitBar releases are signed, notarized, stapled ZIP files published directly through GitHub Releases.
Publishing is intentionally unavailable without approval of the protected GitHub environment named `release` and all required environment secrets.

## Stable Identity

Every public build uses the same Developer ID Application certificate and these application identifiers:

- Bundle identifier: `com.talibilat.LimitBar`
- Signing class: `Developer ID Application`
- Hardened runtime: enabled
- App Sandbox: disabled by ADR 0001

Changing the Apple team, bundle identifier, or Developer ID Application identity is an identity migration.
It must not be done as routine certificate rotation because it can change Keychain authorization behavior and update trust.
Renew the certificate under the same Apple team and keep the protected `DEVELOPER_ID_APPLICATION` value synchronized with its exact Keychain name.

## Protected Environment

Create a GitHub environment named `release` with required reviewers and tag deployment restrictions.
Store these values as environment secrets, never repository variables, workflow inputs, artifacts, or logs:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_APPLICATION` | Exact stable identity, including `Developer ID Application:` and team ID. |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded certificate and private key export. |
| `DEVELOPER_ID_P12_PASSWORD` | Password for the P12 export. |
| `APPLE_ID` | Apple account used by `notarytool`. |
| `APPLE_TEAM_ID` | Stable Apple developer team identifier. |
| `APPLE_APP_PASSWORD` | App-specific password used by `notarytool`. |

Use a least-privilege Apple account and rotate its app-specific password after suspected disclosure.
Replace the P12 secret before certificate expiration without changing the Apple team or bundle identifier.

## Release Procedure

1. Confirm CI passes on macOS 14 with Xcode 16.
2. Confirm `docs/MIGRATIONS_AND_RECOVERY.md` covers every schema distributed so far.
3. Create an annotated `vMAJOR.MINOR.PATCH` tag on the reviewed commit and push the tag.
4. Run the `Release` workflow manually and provide that existing tag.
5. Approve the protected `release` environment after checking the tag and commit.
6. Download the ZIP from the resulting draft GitHub Release onto clean systems running the oldest and newest supported macOS releases.
7. Perform the clean-install, migration, and update acceptance checks below before promoting or announcing the release.

The workflow fails before certificate import when any protected value is absent, the tag format is invalid, the checked-out commit does not carry the tag, or the identity does not match the Apple team.
It never falls back to ad hoc signing or an unsigned artifact.

The workflow archives the release with manual Developer ID signing, checks the exact signing authority, submits a ZIP to Apple, staples the app, rebuilds the final ZIP, extracts it, and revalidates the signature and stapled ticket.
Only that final ZIP may be promoted as the public release artifact.

## Migration Gate

Run these repository checks before producing an artifact:

```sh
scripts/check-toolchain.sh
swift test --package-path LimitBarCore
scripts/validate-migrations.sh
xcodebuild -project LimitBar.xcodeproj -scheme LimitBar -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Create the final artifact as a draft GitHub Release.
Do not promote the draft until `docs/MIGRATIONS_AND_RECOVERY.md` covers every persistent schema distributed by a public release and external migration acceptance passes.

Release acceptance must use the exact final ZIP and exact prior published ZIPs rather than source rebuilds.
Retain each public ZIP and checksum permanently so future release migration checks remain reproducible.

The first public release cannot provide binary-to-binary update evidence because no prior public artifact exists.
It must instead freeze its app-generated schema fixture, pass the pre-release version-0 matrix, and validate clean installation and recovery behavior.

Do not run signing scripts with secrets in shell history.
The publishing workflow is the canonical signing environment.

## External Acceptance

Run acceptance on the oldest and newest supported macOS releases.

1. Verify the expected Developer ID identity and bundle identifier with `codesign`.
2. Verify the signature, stapled ticket, and Gatekeeper assessment.
3. Launch the quarantined download through Finder.
4. Confirm clean installation creates the canonical schema.
5. Upgrade each prior public release and confirm settings, metrics, custom sources, and expected Keychain authorization behavior remain intact.
6. Complete the release migration and recovery matrix.
7. Promote the draft release only after every blocking check passes.
