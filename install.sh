#!/bin/bash
# Install Quattro GP into omarchy-shell.
#
# This delegates to `omarchy plugin add` rather than copying files in. An
# installed plugin is a git clone and `omarchy plugin update` is a fetch and
# fast-forward, so a plugin that was copied into place can never be updated.
set -euo pipefail

REPO_URL="${QUATTRO_GP_REPO:-https://github.com/28allday/Quattro-GP-Omarchy.git}"
PLUGIN_ID="nosignal.quattro-gp"

command -v omarchy >/dev/null 2>&1 || {
    echo "omarchy not found -- this plugin needs Omarchy 4 or newer." >&2
    exit 1
}

# Only pass --yes when there is nobody to ask. Passing it unconditionally
# would silently answer prompts on the user's behalf -- and the update path
# needs the same care as add: omarchy-plugin-update refuses to confirm
# without a TTY, which under set -e aborted headless re-runs of this script
# whenever an update was actually available.
if [ -t 0 ] && [ -t 1 ]; then
    ASSUME=()
else
    ASSUME=(--yes)
fi

if omarchy plugin list 2>/dev/null | grep -q "$PLUGIN_ID"; then
    echo "$PLUGIN_ID is already installed; updating."
    omarchy plugin update "$PLUGIN_ID" "${ASSUME[@]}"
    exit 0
fi

omarchy plugin add "$REPO_URL" --enable "${ASSUME[@]}"

echo
echo "Installed. Open the cabinet with:"
echo "  omarchy-shell shell toggle $PLUGIN_ID"
