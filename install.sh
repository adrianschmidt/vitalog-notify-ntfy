#!/usr/bin/env bash
#
# vitalog-notify-ntfy installer.
#
#   ./install.sh                  install (idempotent)
#   ./install.sh --uninstall      remove launchd job; keep config/state
#
# Effects of install:
#   - creates ~/.config/vitalog-notify/ if missing
#   - seeds ~/.config/vitalog-notify/config with a template (only if
#     the file does not already exist — never clobbers a user-edited
#     config)
#   - renders com.vitalog-notify.plist.example into
#     ~/Library/LaunchAgents/com.vitalog-notify.plist with absolute
#     paths substituted in
#   - `launchctl bootstrap`s the job (idempotent: bootout first if
#     already loaded)
#
# Effects of --uninstall:
#   - `launchctl bootout`s the job if loaded
#   - removes ~/Library/LaunchAgents/com.vitalog-notify.plist
#   - leaves ~/.config/vitalog-notify/ alone

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR="${HOME}/.config/vitalog-notify"
CONFIG_FILE="${CONFIG_DIR}/config"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_INSTALLED="${LAUNCH_AGENT_DIR}/com.vitalog-notify.plist"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.vitalog-notify.plist.example"
LOG_PATH="${HOME}/Library/Logs/vitalog-notify.log"
NOTIFY_SH="${SCRIPT_DIR}/notify.sh"

UID_NUM=$(id -u)
TARGET="gui/${UID_NUM}/com.vitalog-notify"

die() {
    echo "install.sh: $*" >&2
    exit 1
}

is_loaded() {
    launchctl print "$TARGET" >/dev/null 2>&1
}

uninstall() {
    if is_loaded; then
        echo "uninstall: launchctl bootout $TARGET"
        launchctl bootout "gui/${UID_NUM}" "$PLIST_INSTALLED" \
            || die "bootout failed (job may be in a weird state; try 'launchctl bootout gui/${UID_NUM} $PLIST_INSTALLED' manually)"
    else
        echo "uninstall: launchd job not loaded; nothing to bootout"
    fi
    if [ -f "$PLIST_INSTALLED" ]; then
        rm "$PLIST_INSTALLED"
        echo "uninstall: removed $PLIST_INSTALLED"
    else
        echo "uninstall: $PLIST_INSTALLED already absent"
    fi
    echo "uninstall: $CONFIG_DIR left in place (re-install will pick up your config)"
}

install_() {
    [ -x "$NOTIFY_SH" ] || die "$NOTIFY_SH is not executable; chmod +x notify.sh"
    [ -r "$PLIST_TEMPLATE" ] || die "missing $PLIST_TEMPLATE"

    # Ensure config directory + log dir.
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$(dirname "$LOG_PATH")"

    # Seed config only if missing — never clobber.
    if [ ! -f "$CONFIG_FILE" ]; then
        local vitalog_bin
        vitalog_bin=$(command -v vitalog || echo "/PATH/TO/vitalog")
        cat > "$CONFIG_FILE" <<EOF
# vitalog-notify-ntfy: configuration sourced by notify.sh on each run.
# Edit this file and the next launchd tick will pick up the changes.

# Where your phone is subscribed. Treat this URL as a shared secret;
# anyone with it can read your reminders or write to your topic.
NTFY_TOPIC_URL="https://ntfy.sh/CHANGE-ME-to-a-long-random-string"

# Absolute path to the vitalog binary you want to read status from.
VITALOG_BIN="${vitalog_bin}"
EOF
        echo "install: wrote $CONFIG_FILE (edit NTFY_TOPIC_URL!)"
    else
        echo "install: $CONFIG_FILE already exists; not touching it"
    fi

    # Render plist with absolute paths.
    mkdir -p "$LAUNCH_AGENT_DIR"
    sed \
        -e "s|__NOTIFY_SH__|${NOTIFY_SH}|g" \
        -e "s|__LOG_PATH__|${LOG_PATH}|g" \
        "$PLIST_TEMPLATE" \
        > "$PLIST_INSTALLED"
    echo "install: wrote $PLIST_INSTALLED"

    # Reload the job (bootout first if loaded, then bootstrap).
    if is_loaded; then
        echo "install: launchctl bootout (existing job)"
        launchctl bootout "gui/${UID_NUM}" "$PLIST_INSTALLED" || true
    fi
    echo "install: launchctl bootstrap gui/${UID_NUM} $PLIST_INSTALLED"
    launchctl bootstrap "gui/${UID_NUM}" "$PLIST_INSTALLED" \
        || die "bootstrap failed"

    echo
    echo "install: done."
    echo "  Next: edit $CONFIG_FILE and set NTFY_TOPIC_URL to your real topic."
    echo "  Then: $NOTIFY_SH --dry-run     # confirm what would be sent"
    echo "  Logs: $LOG_PATH"
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "" | install) install_ ;;
    *)
        echo "Usage: $0 [--uninstall]" >&2
        exit 2
        ;;
esac
