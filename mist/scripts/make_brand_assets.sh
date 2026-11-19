#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec uv run --with pillow --with pymupdf python3 "$script_dir/make_brand_assets.py" "$@"
