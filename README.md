# mlx-platform

`mlx-platform` is a small macOS/Xcode project for embedding and controlling an
`mlx-vlm` HTTP server from an app.

The primary targets are:

- `MLXServerKit`: a framework that embeds a relocatable `mlx-vlm` server bundle
  and exposes Swift APIs to locate, launch, monitor, and stop it.
- `MLXServerDemo`: a macOS app that uses `MLXServerKit`, starts the bundled
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
├── MLXServerDemo/
└── MLXServerKit/
PythonDistribution/
├── Launcher/
├── Requirements/
└── Scripts/
project.yml
```

`Sources/` contains the app and framework Swift sources. `PythonDistribution/`
contains the implementation details for generating the framework's embedded
`mlx-vlm-server` resource.

## Build And Run

Generate and build the Xcode project:

```sh
make xcode-generate
make xcode-build
```

Run the demo app from Xcode, or launch the built app directly:

```sh
open build/XcodeDerivedData/Build/Products/Debug/MLXServerDemo.app
```

When launched normally, `MLXServerDemo` starts `mlx-vlm-server` without
arguments. The app keeps a reference to the long-running process, streams
stdout/stderr into the window, and provides `Start`, `Stop`, and `Quit` actions
from the `MLX` menu bar extra.

When the server is running, the menu also polls
`http://127.0.0.1:8080/metrics` and shows a read-only `Serving Stats` submenu.
The menu bar popover includes a visual session summary with recent token
activity, request counts, decode speed, uptime, and the latest request.
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
