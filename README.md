# mlx-platform

`mlx-platform` is a small macOS/Xcode project for embedding and controlling an
`mlx-vlm` HTTP server from an app.

The primary targets are:

- `MLXServerKit`: a framework that embeds a relocatable `mlx-vlm` server bundle
  and exposes Swift APIs to locate, launch, monitor, and stop it.
- `MLXVLMServer`: a macOS app that uses `MLXServerKit`, starts the bundled
  server, streams its log output, and exposes Start/Stop actions from a menu bar
  extra.

The Python packaging flow exists to support `MLXServerKit`: the framework build
phase creates a self-contained Python runtime and installs `mlx-vlm` into the
framework resources.

## Requirements

- macOS Apple Silicon for MLX runtime use.
- Xcode and `xcodebuild`.
- `xcodegen` for regenerating `MLXPlatform.xcodeproj`.
- `python3` on the build machine.
- Network access to GitHub releases and PyPI when the embedded Python bundle
  needs to be built or refreshed.

## Project Layout

```text
Sources/
├── MLXVLMServer/
│   ├── Features/
│   │   ├── Chat/
│   │   ├── Dashboard/
│   │   ├── ImageGeneration/
│   │   ├── Logs/
│   │   └── Models/
│   ├── Utilities/
│   └── ModelProviderIcons/
└── MLXServerKit/
PythonDistribution/
├── Launcher/
├── Requirements/
└── Scripts/
project.yml
```

`Sources/` contains the app and framework Swift sources. App features are
grouped by domain under `Features/`, while shared presentation helpers live in
`Utilities/`. `PythonDistribution/` contains the implementation details for
generating the framework's embedded `mlx-vlm-server` resource.

## Build And Run

Generate and build the Xcode project:

```sh
make xcode-generate
make xcode-build
```

Run the demo app from Xcode, or launch the built app directly:

```sh
open build/XcodeDerivedData/Build/Products/Debug/MLXVLMServer.app
```

When launched normally, `MLXVLMServer` starts `mlx-vlm-server` without
arguments. The app keeps a reference to the long-running process, streams
stdout/stderr into the window, and provides `Start`, `Stop`, and `Quit` actions
from the `MLX` menu bar extra.

When the server is running, the menu also polls
`http://127.0.0.1:8080/metrics` and shows a read-only `Serving Stats` submenu.
The menu bar popover includes a visual session summary with recent token
activity, request counts, decode speed, uptime, and the latest request.
Its model submenu discovers locally cached models, displays their on-disk size
and context capacity, and can restart the server to load a different language
model directly from the menu bar.
Session values reset with the server process. All-time counters are accumulated
by the app in `~/Library/Caches/<bundle-id>/MLXServerStats.plist`.

## Smoke Tests

Check that the bundled executable can run and print `mlx_vlm.server` help:

```sh
make xcode-smoke
```

Check process lifecycle management:

```sh
make xcode-lifecycle-smoke
```

The lifecycle smoke test starts `mlx-vlm-server` without arguments, confirms it
continues running, then stops it through `MLXServerProcessController`.

## Release Signing And Notarization

Distribution outside the Mac App Store requires a `Developer ID Application`
certificate and Apple notarization credentials. Create a timestamped unsigned
Release archive under `dist/archive/`:

```sh
scripts/archive_macos_release.sh
```

The script prints the archive and application paths. It regenerates the Xcode
project, archives with Xcode signing disabled, and verifies that Organizer will
recognize the result as a macOS app archive. To archive and immediately sign in
one command, let the script infer `DEVELOPMENT_TEAM` from the Release build
settings and resolve the matching Developer ID certificate:

```sh
scripts/archive_macos_release.sh --sign
```

For a local test with an Apple Development certificate, also pass
`--no-timestamp`; Team ID resolution will select Apple Development instead of
Developer ID Application:

```sh
scripts/archive_macos_release.sh --sign --no-timestamp
```

You can override the configured team with `--team-id TEAMID`, or bypass
resolution with `--identity`. Apple Development signing does not produce a
distributable build, but it exercises the same recursive hardened-runtime path.

To sign an existing archive separately, pass its app to the signing script:

```sh
scripts/sign_macos_release.sh \
  --identity "Developer ID Application: Example Company (TEAMID)" \
  path/to/MLXVLMServer.app
```

The signing script discovers every Mach-O file in the embedded Python runtime,
signs nested bundles, re-signs the application, removes development-only
entitlements, and performs strict signature verification. For local validation
with an Apple Development certificate, pass `--no-timestamp`; that option is
rejected for Developer ID identities. The embedded launcher disables Python
bytecode writes so launching the server does not invalidate the sealed bundle.

For local notarization, store credentials in the Keychain once:

```sh
xcrun notarytool store-credentials mlx-vlm-server-notary \
  --apple-id developer@example.com \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD
```

Then submit, wait, staple, validate, and create the final ZIP:

```sh
scripts/notarize_macos_release.sh path/to/MLXVLMServer.app
```

The Keychain profile defaults to `mlx-vlm-server-notary`. Override it with
`--keychain-profile` or `NOTARYTOOL_PROFILE`. CI can use an App Store Connect
API key instead by setting `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, and optionally
`NOTARY_ISSUER`.
Notarization results and failure logs are written beside the final archive
under `dist/release/` by default.

To run the complete local release pipeline, including a signed Sparkle feed:

```sh
scripts/release_macos.sh \
  --release-notes path/to/release-notes.md \
  0.2.0
```

This stamps the app version, assigns a timestamp-based build number, builds and
signs the archive, notarizes and staples the app, creates
`dist/release/MLXVLMServer-0.2.0.zip`, and writes
`dist/release/appcast.xml`. Pass `--build-number` when a specific monotonically
increasing `CFBundleVersion` is required.

## Software Updates And GitHub Releases

The app uses Sparkle 2.9.4. GitHub Releases are the source of truth for release
versions and assets, while GitHub Pages hosts the stable feed at
`https://marvis-labs.github.io/mlx-platform/appcast.xml`. The feed is published
only after the notarized ZIP has been uploaded to its GitHub Release, so clients
never see an update whose asset is not yet available.

The app's Sparkle EdDSA public key is committed in
`Configuration/Signing.xcconfig`. Its private key remains in the local Keychain
under the `Marvis-Labs` account. `scripts/generate_macos_appcast.sh` uses that
Keychain key locally. Export it once for GitHub Actions with Sparkle's bundled
tool, then copy the file into the `SPARKLE_PRIVATE_KEY` Actions secret:

```sh
umask 077
build/XcodeDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account Marvis-Labs \
  -x /tmp/mlx-vlm-server-sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/mlx-vlm-server-sparkle-private-key
rm /tmp/mlx-vlm-server-sparkle-private-key
```

The release workflow in `.github/workflows/release.yml` requires these
repository variables:

- `APPLE_TEAM_ID`
- `MLX_VLM_SERVER_BUNDLE_IDENTIFIER`
- `MLX_SERVER_KIT_BUNDLE_IDENTIFIER`

It also requires these Actions secrets:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`: base64-encoded Developer ID
  Application certificate and private key exported as a `.p12`.
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: password used for that `.p12`.
- `APPLE_API_KEY_P8_BASE64`: base64-encoded App Store Connect API `.p8` key.
- `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID`: identifiers for the API key.
- `SPARKLE_PRIVATE_KEY`: the exported Sparkle key described above.

For example, encode the binary credentials without line wrapping:

```sh
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | \
  gh secret set DEVELOPER_ID_APPLICATION_P12_BASE64
base64 -i AuthKey_ABC123.p8 | tr -d '\n' | \
  gh secret set APPLE_API_KEY_P8_BASE64
```

Before the first release, configure the repository's Pages source to **GitHub
Actions**. Then create a GitHub Release with a stable numeric tag such as
`v0.2.0` and publish it. Publishing triggers the workflow to check out that tag,
build and notarize the app, attach `MLXVLMServer-0.2.0.zip`, and finally deploy
the signed appcast. Draft and prerelease releases do not publish updates.

To exercise the stats menu manually, start the app or server and run:

```sh
scripts/run_metrics_queries.py
```

The script sends a few `/v1/chat/completions` requests with
`mlx-community/Qwen3.5-0.8B-8bit`, then prints the `/metrics` before/after
values and deltas. The first request may take longer while the model downloads
and loads.

## MLXServerKit

`MLXServerKit` embeds this resource in the built framework:

```text
MLXServerKit.framework/Resources/mlx-vlm-server/
├── bin/mlx-vlm-server
└── python/
```

The framework exposes:

- `MLXServer.distributionURL()`
- `MLXServer.executableURL()`
- `MLXServer.makeProcess(arguments:)`
- `MLXServer.run(arguments:timeout:)`
- `MLXServerProcessController.start(arguments:)`
- `MLXServerProcessController.stop(timeout:)`

`MLXServerProcessController` is the app-facing API for long-running server
management. It retains the active `Process`, streams output through callbacks,
and clears its state when the server exits.

## Embedded Python Bundle

The `MLXServerKit` build phase runs:

```sh
python3 "$SRCROOT/PythonDistribution/Scripts/build_xcode_framework_resource.py"
```

That script builds `mlx-vlm-server` directly into the framework resources. The
output is stamped with the Python archive, requirements hash, and launcher hash,
so repeat Xcode builds reuse the existing resource tree until one of those
inputs changes.

The build defaults to:

- CPython `3.12.13`
- `python-build-standalone` release `20260508`
- macOS arm64 `install_only_stripped` asset
- pinned Python packages from
  `PythonDistribution/Requirements/mlx-vlm-server-macos-arm64.txt`

During Xcode builds, if `../mlx-vlm` exists and is checked out on `main`, the
build phase installs that local checkout over the pinned `mlx-vlm` wheel after
installing dependencies. The build stamp includes the local checkout's branch,
HEAD, and tracked working-tree status so source changes refresh the embedded
server resource.

## Standalone Bundle

For development, the same bundling script can write a standalone output under
`dist/`:

```sh
make build
```

The output is:

```text
dist/mlx-vlm-server/
├── bin/mlx-vlm-server
└── python/
```

Run it directly with any arguments accepted by `mlx_vlm.server`:

```sh
./dist/mlx-vlm-server/bin/mlx-vlm-server --help
```

Useful builder options:

```sh
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --python-version 3.12
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --mlx-vlm-version 0.5.0
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --mlx-vlm-source ../mlx-vlm
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --pbs-release 20260508
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --output dist/custom-name
```

Use `--skip-install` to assemble the Python distribution and launcher without
installing `mlx-vlm`, which is useful for testing the packaging flow quickly.
