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
CONSOLE_USER=$(stat -f '%Su' /dev/console)

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
  # Fallback to SUDO_USER if stat fails or returns root
  CONSOLE_USER=$SUDO_USER
fi

if [ -z "$CONSOLE_USER" ]; then
  echo "Error: Could not determine the active user." >&2
  exit 1
fi

echo "Configuring passwordless pmset access for user: $CONSOLE_USER (Ghost Mode by Arpit)"

# Create /private/etc/sudoers.d directory if it does not exist
mkdir -p /private/etc/sudoers.d
chmod 750 /private/etc/sudoers.d

# Write the rule to a temp file first for validation
TEMP_SUDOERS=$(mktemp)
echo "# Ghost Mode power management rule - Developed by Arpit" > "$TEMP_SUDOERS"
echo "$CONSOLE_USER ALL=(ALL) NOPASSWD: /usr/bin/pmset" >> "$TEMP_SUDOERS"

# Validate using visudo
if visudo -cf "$TEMP_SUDOERS" >/dev/null 2>&1; then
  mv "$TEMP_SUDOERS" /private/etc/sudoers.d/ghostmode
  chmod 0440 /private/etc/sudoers.d/ghostmode
  echo "Success: Passwordless pmset access configured successfully for Ghost Mode (by Arpit)."
else
  echo "Error: Sudoers rule validation failed." >&2
  rm -f "$TEMP_SUDOERS"
  exit 1
fi
