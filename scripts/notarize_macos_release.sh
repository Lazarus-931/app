#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: notarize_macos_release.sh [options] APP_PATH

Submits a Developer ID-signed app to Apple's notary service, staples and
validates the accepted ticket, and creates the final ZIP release asset.

Authentication (choose one):
  --keychain-profile NAME           notarytool Keychain profile. Defaults to
                                    mlx-vlm-server-notary when no API key is set.
  --key PATH --key-id ID [--issuer ID]
                                    App Store Connect API key

The corresponding environment variables are NOTARYTOOL_PROFILE,
NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER.

Options:
  --output PATH     Final ZIP path. Defaults to
                    dist/release/APP-VERSION.zip.
  --timeout VALUE   notarytool wait timeout. Defaults to 30m.
  -h, --help        Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

keychain_profile="${NOTARYTOOL_PROFILE:-}"
key_path="${NOTARY_KEY_PATH:-}"
key_id="${NOTARY_KEY_ID:-}"
issuer="${NOTARY_ISSUER:-}"
output_path=""
timeout="30m"

while (($# > 0)); do
    case "$1" in
        --keychain-profile)
            (($# >= 2)) || fail "--keychain-profile requires a value"
            keychain_profile="$2"
            shift 2
            ;;
        --key)
            (($# >= 2)) || fail "--key requires a value"
            key_path="$2"
            shift 2
            ;;
        --key-id)
            (($# >= 2)) || fail "--key-id requires a value"
            key_id="$2"
            shift 2
            ;;
        --issuer)
            (($# >= 2)) || fail "--issuer requires a value"
            issuer="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || fail "--output requires a value"
            output_path="$2"
            shift 2
            ;;
        --timeout)
            (($# >= 2)) || fail "--timeout requires a value"
            timeout="$2"
            shift 2
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
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || fail "not a macOS app bundle: $app_path"

app_directory="$(cd "$(dirname "$app_path")" && pwd -P)"
app_path="$app_directory/$(basename "$app_path")"

if [[ -z "$keychain_profile" && -z "$key_path" && -z "$key_id" && -z "$issuer" ]]; then
    keychain_profile="mlx-vlm-server-notary"
fi

authentication_arguments=()
if [[ -n "$keychain_profile" ]]; then
    [[ -z "$key_path" && -z "$key_id" && -z "$issuer" ]] || \
        fail "use either a Keychain profile or an API key, not both"
    authentication_arguments=(--keychain-profile "$keychain_profile")
else
    [[ -n "$key_path" && -n "$key_id" ]] || \
        fail "provide --keychain-profile or both --key and --key-id"
    [[ -f "$key_path" ]] || fail "API key file not found: $key_path"
    authentication_arguments=(--key "$key_path" --key-id "$key_id")
    if [[ -n "$issuer" ]]; then
        authentication_arguments+=(--issuer "$issuer")
    fi
fi

codesign --verify --deep --strict --verbose=2 "$app_path"

signature_details="$(codesign -dvvv "$app_path" 2>&1)"
if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
    fail "the app must be signed with a Developer ID Application certificate before notarization"
fi
[[ "$signature_details" == *"Timestamp="* ]] || \
    fail "the app signature does not contain a secure timestamp"
app_team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<< "$signature_details" | head -n 1)"
[[ -n "$app_team_identifier" && "$app_team_identifier" != "not set" ]] || \
    fail "the app signature does not contain a Developer Team ID"

native_code_count=0
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    [[ "$file_type" == Mach-O* ]] || continue

    codesign --verify --strict "$candidate"
    candidate_signature="$(codesign -dvvv "$candidate" 2>&1)"
    [[ "$candidate_signature" == *"Authority=Developer ID Application:"* ]] || \
        fail "native code is not Developer ID signed: $candidate"
    [[ "$candidate_signature" == *"TeamIdentifier=$app_team_identifier"* ]] || \
        fail "native code has a different Team ID: $candidate"
    [[ "$candidate_signature" == *"runtime"* ]] || \
        fail "native code is missing the hardened-runtime flag: $candidate"
    [[ "$candidate_signature" == *"Timestamp="* ]] || \
        fail "native code is missing a secure timestamp: $candidate"
    ((native_code_count += 1))
done < <(find "$app_path" -type f -print0)
echo "Verified $native_code_count Developer ID-signed Mach-O files."

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
if [[ "$app_entitlements" == *"com.apple.security.get-task-allow"* ]]; then
    fail "the app contains the development-only get-task-allow entitlement"
fi

info_plist="$app_path/Contents/Info.plist"
app_name="$(basename "$app_path" .app)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
[[ -n "$version" ]] || fail "CFBundleShortVersionString is missing from $info_plist"

if [[ -z "$output_path" ]]; then
    output_path="dist/release/${app_name}-${version}.zip"
fi
output_directory="$(dirname "$output_path")"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
output_path="$output_directory/$(basename "$output_path")"

result_path="$output_directory/${app_name}-${version}-notary-result.json"
log_path="$output_directory/${app_name}-${version}-notary-log.json"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mlx-vlm-notary.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
submission_zip="$temporary_directory/${app_name}-${version}.zip"

echo "Creating notarization submission archive..."
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"

echo "Submitting to Apple's notary service..."
set +e
xcrun notarytool submit \
    "${authentication_arguments[@]}" \
    --wait \
    --timeout "$timeout" \
    --no-progress \
    --output-format json \
    "$submission_zip" > "$result_path"
submission_exit_code=$?
set -e

notary_status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"
submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"

if [[ "$submission_exit_code" -ne 0 || "$notary_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log \
            "${authentication_arguments[@]}" \
            "$submission_id" \
            "$log_path" || true
    fi
    fail "notarization failed with exit code $submission_exit_code and status '${notary_status:-unknown}'; see $result_path and $log_path"
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

echo "Creating final release archive..."
rm -f "$output_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_path"

echo "Notarized release asset: $output_path"
echo "Notary result: $result_path"
