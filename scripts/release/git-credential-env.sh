#!/bin/bash
# Git credential helper for release.yml: answers `get` with $GIT_TOKEN as an x-access-token password, so a workflow step
# authenticates git without the token ever being written to .git/config, a remote URL or a command line. Set up with
#   git config --global credential.https://github.com.helper ''        (drops osxkeychain, which would store the token)
#   git config --global --add credential.https://github.com.helper "$PWD/scripts/release/git-credential-env.sh"
# then set GIT_TOKEN in the env of each step that talks to GitHub. Without GIT_TOKEN it answers nothing (anonymous).
set -euo pipefail
[ "${1:-}" = get ] || exit 0
cat > /dev/null   # git writes the request (protocol, host, ...) to stdin
[ -n "${GIT_TOKEN:-}" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$GIT_TOKEN"
