#!/bin/bash
# ==============================================================================
#  Ghost Mode - Sudo Setup Helper
#  Author & Developer: Arpit
#  Copyright © 2026 Arpit. All rights reserved.
#  Project: Ghost Mode for macOS (com.arpit.GhostMode)
# ==============================================================================

# Exit on error, unbound variables, and pipe failures
set -euo pipefail

# Ensure the script is run with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo." >&2
  exit 1
fi

# Determine the GUI user (who runs the menu bar app)
CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || true)

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ] || [ "$CONSOLE_USER" = "_mbsetupuser" ]; then
  # Fallback to SUDO_USER if stat fails or returns a non-interactive system user
  CONSOLE_USER="${SUDO_USER:-}"
fi

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ] || [ "$CONSOLE_USER" = "_mbsetupuser" ]; then
  echo "Error: Could not determine a valid interactive console user." >&2
  exit 1
fi

if ! [[ "$CONSOLE_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: Invalid username format for console user: $CONSOLE_USER" >&2
  exit 1
fi

echo "Configuring passwordless pmset access for user: $CONSOLE_USER (Ghost Mode by Arpit)"

# Create /private/etc/sudoers.d directory if it does not exist
mkdir -p /private/etc/sudoers.d
chmod 750 /private/etc/sudoers.d

# Write the least-privilege rule to a temp file first for validation
TEMP_SUDOERS=$(mktemp)
{
  echo "# Ghost Mode power management rule - Developed by Arpit"
  echo "Cmnd_Alias GHOSTMODE_PMSET = /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -g"
  echo "$CONSOLE_USER ALL=(root) NOPASSWD: GHOSTMODE_PMSET"
} > "$TEMP_SUDOERS"

# Validate using visudo before moving into place with 0440
if visudo -cf "$TEMP_SUDOERS" >/dev/null 2>&1; then
  chmod 0440 "$TEMP_SUDOERS"
  mv "$TEMP_SUDOERS" /private/etc/sudoers.d/ghostmode
  chown root:wheel /private/etc/sudoers.d/ghostmode
  chmod 0440 /private/etc/sudoers.d/ghostmode
  echo "Success: Passwordless pmset access configured successfully for Ghost Mode (by Arpit)."
else
  echo "Error: Sudoers rule validation failed." >&2
  rm -f "$TEMP_SUDOERS"
  exit 1
fi
