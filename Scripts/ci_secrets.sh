#!/usr/bin/env bash
# Gives the Release workflow what it needs to sign Powder: the Developer ID certificate and its key,
# stored as encrypted repository secrets. Run it yourself; it uploads a signing key to GitHub.
#
#   ./Scripts/ci_secrets.sh [owner/repo]
#
# Reads the certificate and key from ~/Library/Application Support/Powder/signing (or POWDER_SIGNING_DIR).
# Notarization needs two more secrets, which only you can supply:
#   gh secret set APPLE_ID --repo <owner/repo>             the Apple ID email on the team
#   gh secret set APPLE_APP_PASSWORD --repo <owner/repo>   an app-specific password for it

set -euo pipefail

repo="${1:-fiberevm/powder}"
dir="${POWDER_SIGNING_DIR:-$HOME/Library/Application Support/Powder/signing}"
key="${dir}/developer-id.key"
certificate="${dir}/developer-id.pem"
[[ -f "${key}" && -f "${certificate}" ]] || { echo "No certificate and key in ${dir}." >&2; exit 1; }

team="$(openssl x509 -in "${certificate}" -noout -subject | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')"
name="$(openssl x509 -in "${certificate}" -noout -subject | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')"
echo "Certificate: ${name}"
echo "Repository:  ${repo}"

bundle="$(mktemp -t powder-signing).p12"
password="$(uuidgen)"
trap 'rm -f "${bundle}"' EXIT
# The system's openssl writes the older format that `security import` on the runner reads.
/usr/bin/openssl pkcs12 -export -inkey "${key}" -in "${certificate}" -name "${name}" -out "${bundle}" -passout "pass:${password}"

base64 -i "${bundle}" | gh secret set DEVELOPER_ID_P12 --repo "${repo}"
printf '%s' "${password}" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "${repo}"
printf '%s' "${team}" | gh secret set APPLE_TEAM_ID --repo "${repo}"

echo
echo "Signing secrets are set. For notarization, also run:"
echo "  gh secret set APPLE_ID --repo ${repo}"
echo "  gh secret set APPLE_APP_PASSWORD --repo ${repo}"
echo "Then start a build:  gh workflow run release.yml --repo ${repo}"
