#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: generate_macos_appcast.sh [options] RELEASE_ZIP

Creates a signed Sparkle appcast for a notarized release ZIP. The ZIP's app
version determines the GitHub Release tag and download URL.

Options:
  --release-notes PATH  Markdown, HTML, or plain-text release notes to embed.
  --output PATH         Output feed. Defaults to dist/release/appcast.xml.
  --account NAME        Sparkle signing-key Keychain account. Defaults to
                        Marvis-Labs. Ignored when SPARKLE_PRIVATE_KEY is set.
  --private-key PATH    Read the exported Sparkle private key from a file.
  --derived-data PATH   DerivedData used to locate generate_appcast. Defaults
                        to build/XcodeDerivedData.
  -h, --help            Show this help.

CI may provide the exported key through SPARKLE_PRIVATE_KEY. You can also set
SPARKLE_GENERATE_APPCAST to an explicit generate_appcast executable.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
release_notes=""
output_path="dist/release/appcast.xml"
account="${SPARKLE_KEY_ACCOUNT:-Marvis-Labs}"
private_key_path=""
derived_data_path="${MLX_VLM_SERVER_DERIVED_DATA:-build/XcodeDerivedData}"

while (($# > 0)); do
    case "$1" in
        --release-notes)
            (($# >= 2)) || fail "--release-notes requires a value"
            release_notes="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || fail "--output requires a value"
            output_path="$2"
            shift 2
            ;;
        --account)
            (($# >= 2)) || fail "--account requires a value"
            account="$2"
            shift 2
            ;;
        --private-key)
            (($# >= 2)) || fail "--private-key requires a value"
            private_key_path="$2"
            shift 2
            ;;
        --derived-data)
            (($# >= 2)) || fail "--derived-data requires a value"
            derived_data_path="$2"
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

release_zip="$1"
[[ -f "$release_zip" && "$release_zip" == *.zip ]] || fail "release ZIP not found: $release_zip"
[[ -z "$private_key_path" || -z "${SPARKLE_PRIVATE_KEY:-}" ]] || \
    fail "use either --private-key or SPARKLE_PRIVATE_KEY, not both"
if [[ -n "$private_key_path" ]]; then
    [[ -f "$private_key_path" ]] || fail "Sparkle private key file not found: $private_key_path"
fi
if [[ -n "$release_notes" ]]; then
    [[ -f "$release_notes" ]] || fail "release notes not found: $release_notes"
    case "$release_notes" in
        *.md|*.html|*.txt) ;;
        *) fail "release notes must end in .md, .html, or .txt" ;;
    esac
fi

case "$release_zip" in /*) ;; *) release_zip="$repository_root/$release_zip" ;; esac
case "$output_path" in /*) ;; *) output_path="$repository_root/$output_path" ;; esac
case "$derived_data_path" in /*) ;; *) derived_data_path="$repository_root/$derived_data_path" ;; esac

generate_appcast="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$generate_appcast" ]]; then
    generate_appcast="$derived_data_path/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
fi
[[ -x "$generate_appcast" ]] || fail "Sparkle generate_appcast not found at $generate_appcast; resolve packages or set SPARKLE_GENERATE_APPCAST"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mlx-vlm-appcast.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
archive_plist="$temporary_directory/Info.plist"
archive_plist_entry="$(unzip -Z1 "$release_zip" | awk -F/ 'NF == 3 && $1 ~ /[.]app$/ && $2 == "Contents" && $3 == "Info.plist" { print; exit }')"
[[ -n "$archive_plist_entry" ]] || fail "could not find an app Info.plist in $release_zip"
unzip -p "$release_zip" "$archive_plist_entry" > "$archive_plist"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$archive_plist" 2>/dev/null || true)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$archive_plist" 2>/dev/null || true)"
[[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || fail "invalid or missing app version in release ZIP: $version"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "invalid or missing build number in release ZIP: $build_number"

mkdir -p "$(dirname "$output_path")"
staging_directory="$temporary_directory/releases"
mkdir -p "$staging_directory"
staged_zip="$staging_directory/$(basename "$release_zip")"
ln "$release_zip" "$staged_zip" 2>/dev/null || cp "$release_zip" "$staged_zip"
if [[ -n "$release_notes" ]]; then
    notes_extension="${release_notes##*.}"
    cp "$release_notes" "${staged_zip%.zip}.$notes_extension"
fi

download_prefix="https://github.com/Marvis-Labs/mlx-platform/releases/download/v${version}/"
release_link="https://github.com/Marvis-Labs/mlx-platform/releases/tag/v${version}"
appcast_arguments=(
    --download-url-prefix "$download_prefix"
    --embed-release-notes
    --link "$release_link"
    --maximum-versions 1
    --maximum-deltas 0
    -o "$staging_directory/appcast.xml"
    "$staging_directory"
)

echo "Generating signed appcast for MLX Server $version ($build_number)..."
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" --ed-key-file - "${appcast_arguments[@]}"
elif [[ -n "$private_key_path" ]]; then
    "$generate_appcast" --ed-key-file "$private_key_path" "${appcast_arguments[@]}"
else
    "$generate_appcast" --account "$account" "${appcast_arguments[@]}"
fi

generated_appcast="$staging_directory/appcast.xml"
[[ -s "$generated_appcast" ]] || fail "generate_appcast did not create a feed"
xmllint --noout "$generated_appcast"
grep -Fq "url=\"${download_prefix}$(basename "$release_zip")\"" "$generated_appcast" || \
    fail "generated feed does not contain the expected GitHub download URL"
grep -Fq 'sparkle:edSignature=' "$generated_appcast" || fail "generated feed is not EdDSA signed"
grep -Fq "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$generated_appcast" || \
    fail "generated feed does not contain version $version"
grep -Fq "<sparkle:version>$build_number</sparkle:version>" "$generated_appcast" || \
    fail "generated feed does not contain build $build_number"

mv "$generated_appcast" "$output_path"
echo "Sparkle appcast: $output_path"
