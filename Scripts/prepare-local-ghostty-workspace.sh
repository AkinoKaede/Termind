#!/bin/bash
set -euo pipefail

# Build libghostty-spm/BinaryTarget/GhosttyKit.xcframework first using the
# package's build.sh. This stages a local SPM override without changing pins.
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
python3 - "$repo_root" <<'PY'
import shutil
import sys
from pathlib import Path
from xml.sax.saxutils import escape

root = Path(sys.argv[1])
package = root / 'libghostty-spm'
if not (package / 'BinaryTarget/GhosttyKit.xcframework/Info.plist').is_file():
    raise SystemExit('Build the local GhosttyKit.xcframework before preparing the workspace.')
staging = root / 'build/KeywordHighlighting'
local_package = staging / 'libghostty-spm'
local_package.mkdir(parents=True, exist_ok=True)
shutil.copy2(package / 'Package.local.swift', local_package / 'Package.swift')
for name in ['Sources', 'Tests', 'BinaryTarget']:
    link = local_package / name
    if link.is_symlink():
        link.unlink()
    elif link.exists():
        raise SystemExit(f'Refusing to replace non-symlink: {link}')
    link.symlink_to(package / name, target_is_directory=True)
workspace = staging / 'Termind.xcworkspace'
resolved_dir = workspace / 'xcshareddata/swiftpm'
resolved_dir.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', resolved_dir)
(workspace / 'contents.xcworkspacedata').write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0">\n'
    f'<FileRef location="absolute:{escape(str(root / "Termind.xcodeproj"))}"/>\n'
    '<FileRef location="group:libghostty-spm"/>\n</Workspace>\n')
print(workspace)
PY
