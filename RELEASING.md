# Releasing NgrokMonitor

This document describes how to cut a signed, notarized release.

## Prerequisites (one-time setup)

1. **Apple Developer Program membership** ($99/yr) — required for a Developer ID certificate.
2. **Developer ID Application certificate** installed in your login keychain.
   - In Xcode: *Settings → Accounts → Manage Certificates → + Developer ID Application*.
   - Verify: `security find-identity -v -p codesigning` should list a `Developer ID Application: <Name> (<TEAMID>)` entry.
3. **App-specific password** for `notarytool`.
   - Generate at <https://appleid.apple.com> → Sign-in & Security → App-Specific Passwords.
   - Store it in the keychain so you don't have to type it every release:
     ```bash
     xcrun notarytool store-credentials NGROK_MONITOR_NOTARY \
       --apple-id "you@example.com" \
       --team-id "TEAMID" \
       --password "xxxx-xxxx-xxxx-xxxx"
     ```

## Cutting a release

Set the signing identity once per shell, then run the release script:

```bash
export CODESIGN_IDENTITY="Developer ID Application: David Nguyen (TEAMID)"
export NOTARY_PROFILE="NGROK_MONITOR_NOTARY"

# 1. Bump version in Sources/NgrokMonitor/Resources/bundle.plist
#    - CFBundleShortVersionString  → e.g. 1.0.1
#    - CFBundleVersion             → monotonically increasing build number

# 2. Update CHANGELOG.md (move [Unreleased] → [1.0.1])

# 3. Build, sign, notarize, staple
./scripts/release.sh

# 4. The script produces dist/NgrokMonitor-<version>.zip ready to upload.

# 5. Tag and push
git tag v1.0.1
git push origin v1.0.1

# 6. Create a GitHub Release from the tag, attach dist/NgrokMonitor-<version>.zip,
#    and paste the relevant CHANGELOG section as the body.
```

## What the release script does

1. `swift build -c release`
2. Assembles `NgrokMonitor.app` in `dist/`.
3. `codesign --deep --force --options runtime --entitlements …` with `$CODESIGN_IDENTITY`.
4. Zips the `.app`.
5. `xcrun notarytool submit --wait` with `$NOTARY_PROFILE`.
6. `xcrun stapler staple` the `.app`.
7. Re-zips the stapled `.app` for distribution.
8. `spctl --assess` to verify Gatekeeper acceptance.

## Verifying a build

```bash
codesign -dv --verbose=4 dist/NgrokMonitor.app
spctl --assess -vvv --type execute dist/NgrokMonitor.app
# Expected: "accepted, source=Notarized Developer ID"
```

## Unsigned development builds

`./build.sh` produces an unsigned bundle for local development. On first launch the user must right-click → Open (or remove the quarantine attribute):

```bash
xattr -dr com.apple.quarantine ~/Applications/NgrokMonitor.app
```

This is fine for local dev. Never ship an unsigned build to end users.
