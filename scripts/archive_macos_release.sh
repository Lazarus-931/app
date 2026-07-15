#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: archive_macos_release.sh [options]

Generates the Xcode project and creates an unsigned Release xcarchive whose
app can be signed from the inside out with sign_macos_release.sh.

Options:
  --archive-path PATH   Output xcarchive. Defaults to a timestamped archive
                        under dist/archive/.
  --derived-data PATH   DerivedData directory. Defaults to
                        build/XcodeDerivedData.
  --skip-generate       Do not run xcodegen before archiving.
  --sign                Sign after archiving, inferring DEVELOPMENT_TEAM from
                        the Release build settings.
  --identity ID         Sign the archived app after building it.
  --team-id ID          Sign using a certificate resolved from this Team ID.
  --no-timestamp        Pass --no-timestamp to the signing script. Intended
                        only for local Apple Development signing.
  -h, --help            Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
archive_path=""
derived_data_path="${MLX_VLM_SERVER_DERIVED_DATA:-build/XcodeDerivedData}"
generate_project=true
sign_archive=false
identity=""
team_id=""
no_timestamp=false

while (($# > 0)); do
    case "$1" in
        --archive-path)
            (($# >= 2)) || fail "--archive-path requires a value"
            archive_path="$2"
            shift 2
            ;;
        --derived-data)
            (($# >= 2)) || fail "--derived-data requires a value"
            derived_data_path="$2"
            shift 2
            ;;
        --skip-generate)
            generate_project=false
            shift
            ;;
        --sign)
            sign_archive=true
            shift
            ;;
        --identity)
            (($# >= 2)) || fail "--identity requires a value"
            sign_archive=true
            identity="$2"
            shift 2
            ;;
        --team-id)
            (($# >= 2)) || fail "--team-id requires a value"
            sign_archive=true
            team_id="$2"
            shift 2
            ;;
        --no-timestamp)
            no_timestamp=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

if [[ -n "$identity" && -n "$team_id" ]]; then
    fail "use either --identity or --team-id, not both"
fi
if [[ "$no_timestamp" == true && "$sign_archive" == false ]]; then
    fail "--no-timestamp requires --sign, --team-id, or --identity"
fi

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
if [[ "$generate_project" == true ]]; then
    command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required (or pass --skip-generate)"
fi

if [[ -z "$archive_path" ]]; then
    archive_path="dist/archive/MLXVLMServer-$(date +%Y%m%d-%H%M%S).xcarchive"
fi

case "$archive_path" in
    /*) ;;
    *) archive_path="$repository_root/$archive_path" ;;
esac
case "$derived_data_path" in
    /*) ;;
    *) derived_data_path="$repository_root/$derived_data_path" ;;
esac

[[ "$archive_path" == *.xcarchive ]] || fail "--archive-path must end in .xcarchive"
[[ ! -e "$archive_path" ]] || fail "archive already exists: $archive_path"
mkdir -p "$(dirname "$archive_path")" "$derived_data_path"

cd "$repository_root"
if [[ "$generate_project" == true ]]; then
    echo "Generating MLXPlatform.xcodeproj..."
    xcodegen generate
fi

echo "Building unsigned Release archive..."
xcodebuild \
    -project MLXPlatform.xcodeproj \
    -scheme MLXVLMServer \
    -configuration Release \
    -derivedDataPath "$derived_data_path" \
    -archivePath "$archive_path" \
    CODE_SIGNING_ALLOWED=NO \
    archive

archive_info="$archive_path/Info.plist"
[[ -f "$archive_info" ]] || fail "archive metadata is missing: $archive_info"
application_path="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive_info" 2>/dev/null || true)"
[[ -n "$application_path" ]] || fail "archive is not classified as a macOS app archive"

app_path="$archive_path/Products/$application_path"
[[ -d "$app_path" && -f "$app_path/Contents/Info.plist" ]] || \
    fail "archived app is missing: $app_path"
[[ ! -e "$archive_path/Products/Library/Frameworks/MLXServerKit.framework" ]] || \
    fail "MLXServerKit was installed as a top-level archive product; check SKIP_INSTALL"

if [[ "$sign_archive" == true ]]; then
    signing_arguments=()
    if [[ -n "$identity" ]]; then
        signing_arguments+=(--identity "$identity")
    elif [[ -n "$team_id" ]]; then
        signing_arguments+=(--team-id "$team_id")
    fi
    if [[ "$no_timestamp" == true ]]; then
        signing_arguments+=(--no-timestamp)
    fi
    "$script_directory/sign_macos_release.sh" "${signing_arguments[@]}" "$app_path"
fi

echo
echo "Archive: $archive_path"
echo "App:     $app_path"
if [[ "$sign_archive" == false ]]; then
    echo
    echo "Next, sign the archived app:"
    printf '  %q %q\n' "$script_directory/sign_macos_release.sh" "$app_path"
fi
