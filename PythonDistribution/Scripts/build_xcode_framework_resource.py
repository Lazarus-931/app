#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_DISTRIBUTION_ROOT = REPO_ROOT / "PythonDistribution"
DEFAULT_RESOURCE_NAME = "mlx-vlm-server"


def default_output() -> Path:
    target_build_dir = os.environ.get("TARGET_BUILD_DIR")
    wrapper_name = os.environ.get("WRAPPER_NAME")
    if not target_build_dir or not wrapper_name:
        raise SystemExit(
            "Pass an output path or run from an Xcode build phase with "
            "TARGET_BUILD_DIR and WRAPPER_NAME set."
        )
    return Path(target_build_dir) / wrapper_name / "Resources" / DEFAULT_RESOURCE_NAME


def main() -> None:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else default_output()
    output.parent.mkdir(parents=True, exist_ok=True)

    command = [
        sys.executable,
        str(PYTHON_DISTRIBUTION_ROOT / "Scripts" / "build_mlx_vlm_server.py"),
        "--output",
        str(output),
    ]
    subprocess.run(command, cwd=REPO_ROOT, check=True)


if __name__ == "__main__":
    main()
