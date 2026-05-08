# mlx-platform

Build a relocatable `mlx-vlm` server distribution using
[`python-build-standalone`](https://github.com/astral-sh/python-build-standalone).

The build downloads a standalone CPython archive for the current platform,
installs `mlx-vlm` into a private copy of that Python, and writes a native
launcher executable that runs:

```sh
python -m mlx_vlm.server
```

## Requirements

- macOS Apple Silicon for MLX runtime use.
- `python3` on the build machine.
- Network access to GitHub releases and PyPI.

The build defaults to CPython 3.12.13 from the pinned
`python-build-standalone` `20260508` release. Python package versions are
pinned in `PythonDistribution/Requirements/mlx-vlm-server-macos-arm64.txt`.

## Project Layout

```text
PythonDistribution/
├── Launcher/
├── Requirements/
└── Scripts/
Sources/
├── MLXServerDemo/
└── MLXServerKit/
project.yml
```

`PythonDistribution/` owns everything needed to generate the embedded Python
runtime. `Sources/` contains the Swift targets used by the Xcode project.

## Build

```sh
make build
```

The output is written to:

```text
dist/mlx-vlm-server/
```

Run the server launcher with any arguments accepted by `mlx_vlm.server`:

```sh
./dist/mlx-vlm-server/bin/mlx-vlm-server --help
```

## Useful Options

```sh
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --python-version 3.12
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --mlx-vlm-version 0.5.0
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --pbs-release 20260508
python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --output dist/custom-name
```

Use `--skip-install` to assemble the Python distribution and launcher without
installing `mlx-vlm`, which is useful for testing the packaging flow quickly.

## Output Layout

```text
dist/mlx-vlm-server/
├── bin/mlx-vlm-server
└── python/
```

`bin/mlx-vlm-server` resolves its own install directory at runtime, sets
`PYTHONHOME` to the bundled `python/` directory, and executes
`mlx_vlm.server`.

## Xcode Demo

Generate and build the Xcode project:

```sh
make xcode-generate
make xcode-build
```

Run the non-GUI app smoke test:

```sh
make xcode-smoke
```

The `MLXServerKit` framework build phase runs:

```sh
python3 "$SRCROOT/PythonDistribution/Scripts/build_xcode_framework_resource.py"
```

That script builds `mlx-vlm-server` directly into the framework resources:

```text
MLXServerKit.framework/Resources/mlx-vlm-server/
```

The output is stamped with the Python archive, requirements hash, and launcher
hash, so repeat Xcode builds reuse the existing resource tree until one of those
inputs changes.
