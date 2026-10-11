#!/bin/sh
# Fetches Claude subscription usage for the bar (ClaudeUsage.qml).
#
# Prints the response body of Claude Code's own usage endpoint — the one behind
# its `/usage` command — then a last line `status <code>`: an HTTP status,
# `000` when the request never got an answer, or `no-credentials`.
#
# The token Claude Code keeps in ~/.claude/.credentials.json is read on every
# call, never cached: Claude Code refreshes it on its own and this script must
# never write to that file. It reaches curl on stdin (`-H @-`), so it shows up
# neither in a process listing nor in the bar's QML.

set -u

token=$(jq -er '.claudeAiOauth.accessToken' "$HOME/.claude/.credentials.json" 2>/dev/null) || {
    echo "status no-credentials"
    exit 0
}

# The endpoint rate-limits unknown clients hard. Only the claude-code/ prefix
# matters, so the version is not looked up: `claude` is not even on the bar's
# PATH.
printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\n' "$token" |
    curl --silent --max-time 15 --header @- \
        --user-agent "claude-code/2.1.289" \
        --write-out '\nstatus %{http_code}\n' \
        https://api.anthropic.com/api/oauth/usage
