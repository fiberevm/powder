#!/usr/bin/env bash
# Builds a copy of Powder that other people can open: signed with a Developer ID, notarized by Apple, stapled.
#
#   ./Scripts/release.sh                 Apple silicon
#   POWDER_ARCH=x86_64 ./Scripts/release.sh   Intel
#   ./Scripts/release.sh --sign-only     stop after signing (nothing is sent to Apple)
#   ./Scripts/release.sh --package-only  build the app and stop before signing
#   ./Scripts/release.sh --prebuilt      sign and notarize what --package-only built
#
# Needs a "Developer ID Application" certificate in the keychain (POWDER_RELEASE_IDENTITY names one).
# Notarization uses APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID when set (as in CI), else the
# keychain profile stored once with:
#   xcrun notarytool store-credentials powder-notary --apple-id <email> --team-id <team>
# With neither, the build is signed but not notarized, and the archive's name says so.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${POWDER_ARCH:-arm64}"
label="apple-silicon"
[[ "${arch}" == "x86_64" ]] && label="intel"
out="${project_root}/.build/release-${label}"
app="${out}/Powder.app"
profile="${POWDER_NOTARY_PROFILE:-powder-notary}"

# Built into its own folder and signed there: the day-to-day build keeps its signature and its Keychain permissions.
# `--package-only` stops here, and `--prebuilt` starts after here: CI compiles before the signing key is on the machine.
if [[ "${1:-}" != "--prebuilt" ]]; then
    rm -rf "${out}"
    mkdir -p "${out}"
    POWDER_ARCH="${arch}" POWDER_APP_DIR="${out}" POWDER_SIGN_IDENTITY="-" "${project_root}/Scripts/package_app.sh" >/dev/null
fi
if [[ "${1:-}" == "--package-only" ]]; then
    echo "${app}"
    exit 0
fi
[[ -d "${app}" ]] || { echo "Nothing to sign at ${app}." >&2; exit 1; }

identity="${POWDER_RELEASE_IDENTITY:-}"
if [[ -z "${identity}" ]]; then
    identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')"
    # Merkle's when there are several.
    identity="$(grep -m1 "Merkle" <<<"${identities}" || head -n 1 <<<"${identities}")"
fi
if [[ -z "${identity}" ]]; then
    echo "No Developer ID Application certificate found. Set POWDER_RELEASE_IDENTITY." >&2
    exit 1
fi

# Hardened runtime and a secure timestamp are what notarization requires.
codesign --force --options runtime --timestamp --sign "${identity}" "${app}"
codesign --verify --strict --verbose=2 "${app}"
echo "Signed as: ${identity}"
lipo -archs "${app}/Contents/MacOS/Powder"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist" 2>/dev/null || echo dev)"

if [[ "${1:-}" == "--sign-only" ]]; then
    echo "${app}"
    exit 0
fi

credentials=()
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    credentials=(--apple-id "${APPLE_ID}" --password "${APPLE_APP_PASSWORD}" --team-id "${APPLE_TEAM_ID}")
elif xcrun notarytool history --keychain-profile "${profile}" >/dev/null 2>&1; then
    credentials=(--keychain-profile "${profile}")
fi

if [[ ${#credentials[@]} -eq 0 ]]; then
    echo "No notary credentials: this build is signed but NOT notarized. macOS will warn before opening it." >&2
    archive="${out}/Powder-${version}-${label}-unnotarized.zip"
else
    upload="${out}/upload.zip"
    ditto -c -k --keepParent "${app}" "${upload}"
    xcrun notarytool submit "${upload}" "${credentials[@]}" --wait
    rm -f "${upload}"
    # The ticket goes inside the app, so it opens on a Mac that is offline.
    xcrun stapler staple "${app}"
    spctl --assess --type execute --verbose=2 "${app}"
    archive="${out}/Powder-${version}-${label}.zip"
fi

ditto -c -k --keepParent "${app}" "${archive}"
echo "${archive}"
