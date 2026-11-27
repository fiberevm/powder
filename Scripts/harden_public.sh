#!/usr/bin/env bash
# Run this right after making the repository public. GitHub only offers these three protections on
# public repositories (or on its Enterprise plan), so they could not be switched on while it was private.
#
#   ./Scripts/harden_public.sh [owner/repo]

set -euo pipefail

repo="${1:-fiberevm/powder}"
[[ "$(gh repo view "${repo}" --json visibility --jq .visibility)" == "PUBLIC" ]] || {
    echo "${repo} is not public yet; nothing to do." >&2
    exit 1
}
reviewer="$(gh api user --jq .id)"

# 1. A maintainer must approve every run that can reach the signing key.
printf '{"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "${reviewer}" \
    | gh api -X PUT "repos/${repo}/environments/release" --input - >/dev/null
echo "Release environment: approval required from $(gh api user --jq .login)"

# 2. Workflows on pull requests from people outside the project wait for approval.
printf '{"approval_policy":"all_external_contributors"}' \
    | gh api -X PUT "repos/${repo}/actions/permissions/fork-pr-contributor-approval" --input - >/dev/null
echo "Outside pull requests: workflows need approval"

# 3. Security problems can be reported privately (SECURITY.md points here).
gh api -X PUT "repos/${repo}/private-vulnerability-reporting" >/dev/null
echo "Private vulnerability reporting: on"
