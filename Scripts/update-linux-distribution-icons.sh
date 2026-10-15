#!/bin/sh
set -eu
# Compatibility entry point; generation now includes macOS and Windows artwork.
if [ "$#" -ne 1 ]; then
    echo "usage: $0 SIMPLE_ICONS_VERSION" >&2
    exit 64
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/update-host-icons.py" --simple-icons-version "$1"
