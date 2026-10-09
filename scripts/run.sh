#!/bin/zsh
# Build and launch scopeOS.
#   scripts/run.sh            debug build (simulator, DEBUG badge, movement switches)
#   scripts/run.sh release    release build (no simulator, movement always on, optimised)
#   scripts/run.sh install    release build, copied to /Applications (run again to update it)
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-debug}
case $mode in
  debug) config=Debug ;;
  release|install) config=Release ;;
  *) echo "Usage: scripts/run.sh [debug|release|install]"; exit 1 ;;
esac

osascript -e 'quit app "scopeOS"' 2>/dev/null || true
xcodebuild -project ScopeOS.xcodeproj -scheme ScopeOS -configuration "$config" -derivedDataPath build.noindex build -quiet
app="build.noindex/Build/Products/$config/scopeOS.app"
if [[ $mode == install ]]; then
  rm -rf /Applications/scopeOS.app
  ditto "$app" /Applications/scopeOS.app
  app=/Applications/scopeOS.app
  echo "Installed to /Applications."
fi
open "$app"
echo "Launched scopeOS ($mode)."
