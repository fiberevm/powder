#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${project_root}/.build"
module_cache="${build_root}/ModuleCache"
app_bundle="${build_root}/Powder.app"
contents="${app_bundle}/Contents"

SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}" \
CLANG_MODULE_CACHE_PATH="${module_cache}" \
swift build \
    --package-path "${project_root}" \
    --disable-sandbox \
    --configuration release \
    --product Powder

mkdir -p "${contents}/MacOS" "${contents}/Resources"
install -m 755 "${build_root}/arm64-apple-macosx/release/Powder" "${contents}/MacOS/Powder"
install -m 644 "${project_root}/Support/Info.plist" "${contents}/Info.plist"

# App icon: rasterise Support/AppIcon.svg into an .icns.
iconset="${build_root}/AppIcon.iconset"
rm -rf "${iconset}"
mkdir -p "${iconset}"
for size in 16 32 128 256 512; do
    sips -s format png -z "${size}" "${size}" "${project_root}/Support/AppIcon.svg" \
        --out "${iconset}/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z "$((size * 2))" "$((size * 2))" "${project_root}/Support/AppIcon.svg" \
        --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "${iconset}" --output "${contents}/Resources/AppIcon.icns"

# A stable signature lets macOS remember "Always Allow" for the app's Keychain items. An ad-hoc
# signature changes with every build, so each rebuild would ask again for every key.
# Set POWDER_SIGN_IDENTITY to choose one, or to "-" for ad-hoc.
identity="${POWDER_SIGN_IDENTITY:-}"
if [[ -z "${identity}" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -z "${identity}" ]] || ! codesign --force --deep --sign "${identity}" "${app_bundle}" 2>/dev/null; then
    codesign --force --deep --sign - "${app_bundle}"
fi

echo "${app_bundle}"
