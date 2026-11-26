#!/bin/bash
# ==============================================================================
#  Ghost Mode - Hardened Sudo Setup Helper
#  Author & Developer: Arpit
#  Copyright © 2026 Arpit. All rights reserved.
#  Project: Ghost Mode for macOS (com.arpit.GhostMode)
# ==============================================================================

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
IFS=$' \t\n'
umask 077

# Ensure the script is run with sudo / root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script with sudo." >&2
  exit 1
fi

# Determine the GUI user (who runs the menu bar app)
CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ] || [ "$CONSOLE_USER" = "_mbsetupuser" ]; then
  CONSOLE_USER="${SUDO_USER:-}"
fi

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ] || [ "$CONSOLE_USER" = "_mbsetupuser" ]; then
  echo "Error: Could not determine a valid interactive console user." >&2
  exit 1
fi

if ! [[ "$CONSOLE_USER" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$CONSOLE_USER" == -* ]] || [[ "$CONSOLE_USER" == .* ]] || [ ${#CONSOLE_USER} -gt 64 ]; then
  echo "Error: Invalid username format for console user: $CONSOLE_USER" >&2
  exit 1
fi

echo "Configuring passwordless pmset access for user: $CONSOLE_USER (Ghost Mode by Arpit)"

# Reject symlinks on /private/etc and /private/etc/sudoers.d
if [ -L /private/etc ] || [ -L /private/etc/sudoers.d ]; then
  echo "Error: Unsafe symlink detected on sudoers directory." >&2
  exit 1
fi

if [ ! -d /private/etc/sudoers.d ]; then
  /bin/mkdir -m 0750 /private/etc/sudoers.d
fi
/usr/sbin/chown root:wheel /private/etc/sudoers.d
/bin/chmod 0750 /private/etc/sudoers.d

if [ -L /private/etc/sudoers.d/ghostmode ] || [ -d /private/etc/sudoers.d/ghostmode ]; then
  echo "Error: Unsafe target detected in /private/etc/sudoers.d." >&2
  exit 1
fi

# Stage inside root-only 0750/0700 directory to eliminate /tmp/$TMPDIR TOCTOU races
TMP_DIR=$(/usr/bin/mktemp -d /private/etc/sudoers.d/.ghostmode.XXXXXX)
cleanup() {
  /bin/rm -rf "$TMP_DIR"
}
trap cleanup EXIT

TEMP_SUDOERS="$TMP_DIR/ghostmode"
/usr/bin/printf '%s\n' \
  "# Ghost Mode power management rule - Developed by Arpit" \
  "Cmnd_Alias GHOSTMODE_PMSET = /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -g" \
  "$CONSOLE_USER ALL=(root) NOPASSWD: GHOSTMODE_PMSET" > "$TEMP_SUDOERS"

/bin/chmod 0440 "$TEMP_SUDOERS"

if /usr/sbin/visudo -cf "$TEMP_SUDOERS" >/dev/null 2>&1; then
  /usr/sbin/chown root:wheel "$TEMP_SUDOERS"
  /bin/chmod 0440 "$TEMP_SUDOERS"
  /bin/mv -f "$TEMP_SUDOERS" /private/etc/sudoers.d/ghostmode
  echo "Success: Passwordless pmset access configured successfully for Ghost Mode (by Arpit)."
else
  echo "Error: Sudoers rule validation failed." >&2
  exit 1
fi
