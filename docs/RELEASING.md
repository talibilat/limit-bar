# Releasing LimitBar

LimitBar releases must be signed, notarized, stapled ZIP files published through GitHub Releases.

## Migration Gate

Run these repository checks before producing an artifact:

```sh
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

## External Acceptance

Run acceptance on the oldest and newest supported macOS releases.

1. Verify the expected Developer ID identity and bundle identifier with `codesign`.
2. Verify the signature, stapled ticket, and Gatekeeper assessment.
3. Launch the quarantined download through Finder.
4. Confirm clean installation creates the canonical schema.
5. Upgrade each prior public release and confirm settings, metrics, custom sources, and expected Keychain authorization behavior remain intact.
6. Complete the release migration and recovery matrix.
7. Promote the draft release only after every blocking check passes.
