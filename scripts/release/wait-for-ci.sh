#!/bin/bash
# Release gate: waits for the CI workflow (ci.yml) on a commit instead of re-running the tests in release.yml.
# Usage: scripts/release/wait-for-ci.sh <commit sha>   (needs GH_TOKEN with actions: read, and gh)
# Read-only: it only lists workflow runs through the GitHub API. Exit codes:
#   0  a CI run for the commit succeeded (any event: push to main, pull request, dispatch)
#   1  CI failed for the commit (the ::error:: names the run), or no run finished within TIMEOUT_SECONDS
#   3  no usable CI run: none exists for the commit, or every run was cancelled/skipped (ci.yml cancels the
#      in-progress run of a ref when main moves on); the caller runs the tests itself
# A success anywhere wins; a failure is reported only once no run for the commit is still queued or running.
# Environment: GITHUB_REPOSITORY (default: gh's current repo), TIMEOUT_SECONDS (3000), POLL_SECONDS (30),
# APPEAR_SECONDS (120: how long to wait for a run to show up when the tag was pushed right after the commit).
set -euo pipefail
sha="${1:?usage: wait-for-ci.sh <commit sha>}"
repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
timeout="${TIMEOUT_SECONDS:-3000}"; poll="${POLL_SECONDS:-30}"; appear="${APPEAR_SECONDS:-120}"
start=$(date +%s); pending=""

while :; do
  # One line per run: <status> <conclusion or -> <html_url>. API errors are retried until the timeout.
  if runs="$(gh api "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$sha&per_page=100" \
      --jq '.workflow_runs[] | "\(.status) \(.conclusion // "-") \(.html_url)"')"; then
    success="$(printf '%s\n' "$runs" | awk '$1 == "completed" && $2 == "success" { print $3; exit }')"
    pending="$(printf '%s\n' "$runs" | awk '$1 != "completed" && NF { print $3; exit }')"
    failure="$(printf '%s\n' "$runs" | awk '$1 == "completed" && $2 != "success" && $2 != "cancelled" && $2 != "skipped" { print $3; exit }')"
    if [ -n "$success" ]; then echo "CI passed for $sha: $success"; exit 0; fi
    if [ -z "$pending" ]; then
      if [ -n "$failure" ]; then
        echo "::error title=CI failed::CI failed for $sha: $failure - fix or re-run CI, then re-run this release"
        exit 1
      fi
      if [ -n "$runs" ] || [ $(( $(date +%s) - start )) -ge "$appear" ]; then
        if [ -n "$runs" ]; then echo "CI runs for $sha were all cancelled or skipped:"; printf '  %s\n' "$runs"
        else echo "no CI run exists for $sha"; fi
        exit 3
      fi
      echo "no CI run for $sha yet; waiting for one to appear"
    else
      echo "CI for $sha still running: $pending"
    fi
  else
    echo "::warning::could not list CI runs for $sha; retrying"
  fi
  if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
    echo "::error title=CI timeout::no CI run for $sha finished within $timeout s${pending:+ ($pending)} - re-run this release once CI is done"
    exit 1
  fi
  sleep "$poll"
done
