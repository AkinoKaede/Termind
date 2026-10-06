#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
exec bundle exec fastlane mac screenshots "$@"
