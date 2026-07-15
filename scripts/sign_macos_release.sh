#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sign_macos_release.sh [options] APP_PATH

Signs every Mach-O file inside a macOS app from the inside out, then signs
nested code bundles and the app itself.

Options:
  --identity ID    Codesigning identity name or SHA-1 hash.
  --team-id ID     Resolve a certificate whose subject OU matches this Team ID.
                   If neither option is provided, DEVELOPMENT_TEAM is read from
                   the Release build settings.
  --no-timestamp   Disable the secure timestamp for local development testing.
                   This selects Apple Development for Team ID resolution and is
                   rejected for Developer ID Application identities.
  -h, --help       Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
identity="${CODE_SIGN_IDENTITY:-}"
team_id="${MLX_VLM_SERVER_TEAM_ID:-}"
use_timestamp=true

while (($# > 0)); do
    case "$1" in
        --identity)
            (($# >= 2)) || fail "--identity requires a value"
            identity="$2"
            shift 2
            ;;
        --team-id)
            (($# >= 2)) || fail "--team-id requires a value"
            team_id="$2"
            shift 2
            ;;
        --no-timestamp)
            use_timestamp=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

(($# == 1)) || {
    usage >&2
    exit 2
}

app_path="$1"
[[ -d "$app_path" && -d "$app_path/Contents" ]] || fail "not a macOS app bundle: $app_path"

app_directory="$(cd "$(dirname "$app_path")" && pwd -P)"
app_path="$app_directory/$(basename "$app_path")"

[[ -z "$identity" || -z "$team_id" ]] || fail "use either --identity or --team-id, not both"

if [[ -z "$identity" && -z "$team_id" ]]; then
    team_id="$(
        xcodebuild \
            -project "$repository_root/MLXPlatform.xcodeproj" \
            -scheme MLXVLMServer \
            -configuration Release \
            -showBuildSettings 2>/dev/null |
            sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' |
            sort -u |
            head -n 1
    )"
    [[ -n "$team_id" ]] || fail "could not infer DEVELOPMENT_TEAM; pass --team-id or --identity"
    echo "Using DEVELOPMENT_TEAM from Release build settings: $team_id"
fi

if [[ -n "$team_id" ]]; then
    [[ "$team_id" =~ ^[[:alnum:]]{10}$ ]] || fail "invalid Team ID: $team_id"
    command -v openssl >/dev/null 2>&1 || fail "openssl is required to resolve a Team ID"

    certificate_kind="Developer ID Application"
    if [[ "$use_timestamp" == false ]]; then
        certificate_kind="Apple Development"
    fi

    matching_hashes=()
    matching_names=()
    while IFS= read -r identity_candidate; do
        certificate_hash="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) ".*"$/\1/p' <<< "$identity_candidate")"
        certificate_name="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' <<< "$identity_candidate")"
        [[ -n "$certificate_hash" && "$certificate_name" == "$certificate_kind:"* ]] || continue

        certificate_subject="$(
            security find-certificate -c "$certificate_name" -p 2>/dev/null |
                openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true
        )"
        [[ "$certificate_subject" == *"OU=$team_id"* ]] || continue
        matching_hashes+=("$certificate_hash")
        matching_names+=("$certificate_name")
    done < <(security find-identity -v -p codesigning 2>/dev/null)

    if ((${#matching_hashes[@]} == 0)); then
        fail "no $certificate_kind certificate found for Team ID $team_id"
    fi
    if ((${#matching_hashes[@]} > 1)); then
        echo "error: multiple $certificate_kind certificates found for Team ID $team_id:" >&2
        for certificate_name in "${matching_names[@]}"; do
            echo "  $certificate_name" >&2
        done
        fail "pass --identity to choose one explicitly"
    fi

    identity="${matching_hashes[0]}"
    identity_display_name="${matching_names[0]}"
    echo "Resolved signing identity: $identity_display_name"
fi

identity_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$identity" | head -n 1 || true)"
[[ -n "$identity_line" ]] || fail "codesigning identity not found: $identity"

if [[ "$use_timestamp" == false && "$identity_line" == *"Developer ID Application"* ]]; then
    fail "Developer ID Application signatures require a secure timestamp"
fi

timestamp_arguments=(--timestamp)
if [[ "$use_timestamp" == false ]]; then
    timestamp_arguments=(--timestamp=none)
fi

sign_target() {
    local target="$1"
    codesign \
        --force \
        --sign "$identity" \
        --options runtime \
        "${timestamp_arguments[@]}" \
        "$target"
}

native_files=()
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    if [[ "$file_type" == Mach-O* ]]; then
        native_files+=("$candidate")
    fi
done < <(find "$app_path" -type f -print0)

echo "Signing ${#native_files[@]} Mach-O files with: $identity"
for native_file in "${native_files[@]}"; do
    sign_target "$native_file"
done

# Re-seal nested code bundles after their contents have been modified. `find
# -depth` guarantees that nested bundles are handled before their containers.
while IFS= read -r -d '' code_bundle; do
    sign_target "$code_bundle"
done < <(
    find "$app_path" -depth -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' -o -name '*.app' \) \
        ! -path "$app_path" \
        -print0
)

# Signing without an entitlements file intentionally removes development-only
# entitlements such as com.apple.security.get-task-allow.
sign_target "$app_path"

for native_file in "${native_files[@]}"; do
    codesign --verify --strict "$native_file"
done
codesign --verify --deep --strict --verbose=2 "$app_path"

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
if [[ "$app_entitlements" == *"com.apple.security.get-task-allow"* ]]; then
    fail "the signed app still contains the development-only get-task-allow entitlement"
fi

echo "Signed and verified: $app_path"
