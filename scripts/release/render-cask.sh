#!/bin/bash
# Prints a Homebrew cask for MacExplorer (distribution spec §5 step 6).
# Usage: render-cask.sh --token macexplorer|macexplorer@beta --version V --sha256 SHA --url URL
# zap: settings and plugins (Application Support), the remote-repository cache (Caches/macExplorer), Sparkle's
# download cache (Caches/<bundle id>/org.sparkle-project.Sparkle) and URLSession storage, preferences, window state.
set -euo pipefail
usage() { echo "usage: $0 --token macexplorer|macexplorer@beta --version V --sha256 SHA --url URL" >&2; exit 64; }
token="" version="" sha="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) token="${2:-}"; shift ;;
    --version) version="${2:-}"; shift ;;
    --sha256) sha="${2:-}"; shift ;;
    --url) url="${2:-}"; shift ;;
    *) usage ;;
  esac
  shift
done
[ -n "$version" ] && [ -n "$sha" ] && [ -n "$url" ] || usage
case "$token" in
  macexplorer) other="macexplorer@beta"; name="MacExplorer" ;;
  macexplorer@beta) other="macexplorer"; name="MacExplorer (Beta)" ;;
  *) usage ;;
esac
cat <<EOF
cask "$token" do
  version "$version"
  sha256 "$sha"

  url "$url"
  name "$name"
  desc "Windows Explorer-style file manager"
  homepage "https://github.com/roniburd/macExplorer"

  auto_updates true
  conflicts_with cask: "$other"
  depends_on macos: :tahoe

  app "MacExplorer.app"

  zap trash: [
    "~/Library/Application Support/macExplorer",
    "~/Library/Caches/com.macexplorer.app",
    "~/Library/Caches/macExplorer",
    "~/Library/HTTPStorages/com.macexplorer.app",
    "~/Library/HTTPStorages/com.macexplorer.app.binarycookies",
    "~/Library/Preferences/com.macexplorer.app.plist",
    "~/Library/Saved Application State/com.macexplorer.app.savedState",
  ]

  caveats <<~EOS
    MacExplorer isn't notarized yet. If macOS says it can't be opened, run once:
      xattr -dr com.apple.quarantine "#{appdir}/MacExplorer.app"
    MacExplorer updates itself; \`brew upgrade --greedy\` also works.
  EOS
end
EOF
