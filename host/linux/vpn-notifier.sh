#!/bin/bash
# OpenConnect Proxy Login: a background helper for the openconnect-ocproxy container on Linux.
# Every minute it asks the container for its state (via vpn-state.sh, shared with the macOS
# helper). When a login is needed (first start, expired or dropped session) or the session is
# about to expire, it shows a desktop notification that says why and asks to click it; the click
# opens a terminal running `docker exec -it <container> vpn-login`. It stores no credentials.
#
# Install with install.sh (a systemd --user service). Send SIGUSR1 to check right away, e.g.:
#   systemctl --user kill -s USR1 openconnect-ocproxy-notifier.service
#
# Settings (optional): edit ~/.config/openconnect-ocproxy-notifier/config (shell syntax), e.g.:
#   CONTAINER_NAME=openconnect-ocproxy
#   REMINDER_MINUTES=30
#   TERMINAL_APP=gnome-terminal     # overrides auto-detection
#
# Tested on Ubuntu Desktop (GNOME); notification actions depend on the notification daemon and on
# gdbus being installed (part of GLib; present wherever D-Bus itself is). Without either, or on a
# daemon with no action support, it still shows the notification, with the login command as text.
set -u
APP_NAME='OpenConnect Proxy'
ICON_NAME=security-high-symbolic
CHECK_INTERVAL=60          # seconds between checks
EXPIRY_WARNING_SECONDS=900 # matches the container's default reminder
HERE=$(cd "$(dirname "$0")" && pwd)
[[ ${1:-} == --version ]] && { cat "$HERE/VERSION"; exit 0; }
STATE_SCRIPT="$HERE/vpn-state.sh"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/openconnect-ocproxy-notifier/config"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/openconnect-ocproxy-notifier"
mkdir -p "$RUNTIME_DIR"

CONTAINER_NAME=openconnect-ocproxy
REMINDER_MINUTES=30
TERMINAL_APP=
[[ -r $CONFIG_FILE ]] && source "$CONFIG_FILE"

# Persisted across this script's own background subshells (see watch_notification), not just
# in-process variables: a click reaches us from a different process than the main loop. Falls back
# to the default both when the file is missing and when it exists but is empty (a bare `cat ||`
# would only catch the former - `cat` on an empty file still succeeds - which left an arithmetic
# comparison like `now >= $(get_var snooze_until 0)` silently seeing an empty right-hand side and
# evaluating true on every check instead of waiting out the reminder interval).
get_var() {
    local v; v=$(cat "$RUNTIME_DIR/$1" 2>/dev/null)
    [[ -n $v ]] && printf '%s' "$v" || printf '%s' "$2"
}
set_var() { printf '%s' "$2" > "$RUNTIME_DIR/$1"; }

vpn_state() { "$STATE_SCRIPT" "$CONTAINER_NAME" "$EXPIRY_WARNING_SECONDS" 2>/dev/null || echo unavailable; }

# Notifications are posted and watched directly over D-Bus (via gdbus, part of GLib, present
# wherever D-Bus itself is) rather than through notify-send: its --action flag has been observed
# to silently post an empty actions array on some systems (notify-send 0.8.8 on Ubuntu 26.04 among
# them), which leaves nothing for a click to invoke - the notification shows, but can never answer
# a click. gdbus/dbus-monitor talk to the same org.freedesktop.Notifications service notify-send
# does, just without going through its buggy argument handling.
DBUS_NOTIFICATIONS=org.freedesktop.Notifications
DBUS_NOTIFICATIONS_PATH=/org/freedesktop/Notifications
command -v gdbus >/dev/null 2>&1 && GDBUS_AVAILABLE=1 || GDBUS_AVAILABLE=0
ACTIONS_SUPPORTED=0
if [[ $GDBUS_AVAILABLE == 1 ]]; then
    gdbus call --session --dest "$DBUS_NOTIFICATIONS" --object-path "$DBUS_NOTIFICATIONS_PATH" \
        --method "$DBUS_NOTIFICATIONS.GetCapabilities" 2>/dev/null | grep -q "'actions'" && ACTIONS_SUPPORTED=1
fi

# clickAction: "login" adds a "default" action (most daemons, GNOME included, invoke this on a
# plain click of the notification body) and a second, explicitly labelled "login" button (for
# daemons that only honour named actions), and arranges for either to call back into this script;
# "" posts an informational notification with no action. Records the new notification's id.
post_notification() {
    local headline=$1 message=$2 clickAction=$3 actions='[]' timeout_ms=10000 id
    if [[ $clickAction == login ]]; then
        # 0: never auto-expire. Its whole lifecycle (replaced by the next reminder, or removed on
        # a successful login) is managed explicitly, by id, through clear_notification.
        timeout_ms=0
        if [[ $ACTIONS_SUPPORTED == 1 ]]; then
            actions='["default", "Log In", "login", "Log In"]'
        else
            message="$message Run: docker exec -it $CONTAINER_NAME vpn-login"
        fi
    fi
    if [[ $GDBUS_AVAILABLE == 0 ]]; then
        notify-send --app-name="$APP_NAME" --icon="$ICON_NAME" "$headline" "$message" 2>/dev/null &
        return 0
    fi
    # A bare "0" is required, not "-1" ("server decides"): gdbus's own option parser - not the
    # D-Bus call itself - misparses a leading "-" in a positional argument as an unknown flag.
    id=$(gdbus call --session --dest "$DBUS_NOTIFICATIONS" --object-path "$DBUS_NOTIFICATIONS_PATH" \
        --method "$DBUS_NOTIFICATIONS.Notify" "$APP_NAME" 0 "$ICON_NAME" "$headline" "$message" \
        "$actions" '{"urgency": <byte 1>}' "$timeout_ms" 2>/dev/null \
        | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
    [[ -n $id ]] || return 1
    set_var notify_id "$id"
    [[ $clickAction == login && $ACTIONS_SUPPORTED == 1 ]] && watch_notification "$id"
    return 0
}

# Waits for this specific notification's ActionInvoked ("default" or "login" - a click) or
# NotificationClosed (dismissed, replaced, or its -1 timeout elapsed, all shown identically as
# reason=2 by the spec); on a real click it calls back into this script. Reads dbus-monitor's own
# text stream rather than a library, so no python/gjs dependency beyond what GNOME already needs.
# Both ends of the pipe must be line-by-line, or a click sits in a buffer forever given how little
# traffic there is: stdbuf -oL because dbus-monitor block-buffers when its stdout is a pipe, and a
# bash read loop rather than awk because mawk (Debian/Ubuntu's default awk) block-buffers its input
# from a pipe, even with -W interactive. "set -m" around the backgrounding gives the whole pipeline
# its own new process group (otherwise, with job control off, it shares the main loop's): "$!" after
# backgrounding a bare pipeline is only its *last* stage, and killing just that leaves dbus-monitor
# itself running forever, so clear_notification kills the whole group instead - which, without its
# own group, would mean killing the main loop too.
watch_notification() {
    local id=$1
    set -m
    ( stdbuf -oL dbus-monitor --session "interface='$DBUS_NOTIFICATIONS',member='ActionInvoked'" \
                             "interface='$DBUS_NOTIFICATIONS',member='NotificationClosed'" 2>/dev/null \
        | while IFS= read -r line; do
            # A signal is a header line, then one line per argument: the notification id first,
            # then the action key (ActionInvoked) or the close reason (NotificationClosed).
            case $line in
                *member=ActionInvoked*) mode=action; continue ;;
                *member=NotificationClosed*) mode=closed; continue ;;
            esac
            if [[ ${mode:-} && $line =~ ^[[:space:]]*uint32\ ([0-9]+)$ && ${BASH_REMATCH[1]} == "$id" ]]; then
                [[ $mode == closed ]] && break
                IFS= read -r line
                [[ $line == *'"default"' || $line == *'"login"' ]] && { "$0" --on-click; break; }
            fi
            mode=
        done ) &
    set_var watch_pid "$!"
    set +m
}

# Retracts a login notification still waiting for a click (a new reminder, or a successful login),
# so at most one is ever live, and stops watching it.
clear_notification() {
    local wp pgid; wp=$(get_var watch_pid '')
    if [[ -n $wp ]]; then
        # The watcher leads its own group until its pipeline ends; anything else means it is gone
        # and the number may belong to an unrelated process by now.
        pgid=$(ps -o pgid= -p "$wp" 2>/dev/null | tr -d ' ')
        [[ $pgid == "$wp" ]] && kill -- "-$wp" 2>/dev/null
    fi
    local id; id=$(get_var notify_id '')
    if [[ -n $id && $GDBUS_AVAILABLE == 1 ]]; then
        gdbus call --session --dest "$DBUS_NOTIFICATIONS" --object-path "$DBUS_NOTIFICATIONS_PATH" \
            --method "$DBUS_NOTIFICATIONS.CloseNotification" "$id" >/dev/null 2>&1
    fi
    set_var notify_id ''; set_var watch_pid ''
}

# Why a login is needed, from the container's reason (see vpn-state.sh). Ends with a space.
reason_text() {
    case $1 in
        login-required) echo 'The VPN container started. ' ;;
        tunnel-exited*) echo 'The VPN session ended. ' ;;
        startup-failed) echo 'The last login did not connect. ' ;;
        health-check-failed) echo 'The VPN stopped working. ' ;;
        *) echo '' ;;
    esac
}

notify_login() { clear_notification; post_notification "$1" "$2" login; }

# Picks a terminal: the TERMINAL_APP setting, else $TERMINAL, else Debian/Ubuntu's own default
# (x-terminal-emulator), else the first of a few common ones that is actually installed.
pick_terminal() {
    [[ -z $TERMINAL_APP ]] || { echo "$TERMINAL_APP"; return; }
    local t=${TERMINAL:-}
    [[ -z $t ]] || ! command -v "$t" >/dev/null 2>&1 || { echo "$t"; return; }
    for t in x-terminal-emulator gnome-terminal konsole xfce4-terminal tilix alacritty kitty xterm; do
        command -v "$t" >/dev/null 2>&1 && { echo "$t"; return; }
    done
}

# Runs vpn-login in a terminal, from a private temporary script that deletes itself. On success it
# exits at once; on failure it keeps the error visible until a key is pressed. Both exit cleanly,
# so the terminal closes the window. Mirrors the macOS helper's openLogin.
start_login() {
    clear_notification
    local term; term=$(pick_terminal)
    if [[ -z $term ]]; then
        post_notification 'No terminal found' \
            "Run: docker exec -it $CONTAINER_NAME vpn-login" ''
        return
    fi
    local dir script
    dir=$(mktemp -d -t openconnect-proxy-login.XXXXXX)
    script="$dir/vpn-login"
    cat > "$script" <<SCRIPT
#!/bin/bash
# Opened by OpenConnect Proxy Login; deletes itself.
rm -rf -- "\$(dirname "\$0")"
clear
docker exec -it $(printf '%q' "$CONTAINER_NAME") vpn-login && exit 0
echo
read -rsn1 -p 'Login did not complete. Press any key to close this window.'
exit 0
SCRIPT
    chmod 700 "$script"
    case $term in
        x-terminal-emulator|gnome-terminal|tilix) setsid "$term" -- bash "$script" >/dev/null 2>&1 & ;;
        konsole|xfce4-terminal|alacritty|xterm)   setsid "$term" -e bash "$script" >/dev/null 2>&1 & ;;
        kitty)                                    setsid "$term" bash "$script" >/dev/null 2>&1 & ;;
        *)                                         setsid "$term" -e bash "$script" >/dev/null 2>&1 & ;;
    esac
    disown
    # Grace period while the terminal starts; afterwards vpn-login's lock reports "busy".
    set_var snooze_until "$(($(date +%s) + 120))"
}

# mode: "auto" (the periodic check), "click" (a login notification was clicked/actioned) or
# "manual" (SIGUSR1). For a click or manual check, a due login starts right away; otherwise a
# click is answered with a notification (the reminder was out of date) and a manual one with the
# current state.
check_now() {
    local mode=$1 words state reason minutes_left expiry_id now
    words=($(vpn_state)); state=${words[0]}; now=$(date +%s)
    if [[ $state == ok && $(get_var last_state '') =~ ^(login|busy)$ ]]; then
        clear_notification
        post_notification 'VPN connected' 'The login succeeded.' ''
    fi
    set_var last_state "$state"
    if [[ $state == login ]]; then
        if [[ $mode != auto ]]; then
            start_login
        elif (( now >= $(get_var snooze_until 0) )); then
            notify_login 'VPN login needed' "$(reason_text "${words[1]:-}")Click to log in."
            set_var snooze_until "$((now + REMINDER_MINUTES * 60))"
        fi
    elif [[ $state == expiring ]]; then
        minutes_left=${words[1]}; expiry_id=${words[2]}
        if [[ $mode != auto ]]; then
            start_login
        elif [[ $expiry_id != "$(get_var warned_expiry '')" && $now -ge $(get_var snooze_until 0) ]]; then
            set_var warned_expiry "$expiry_id"
            notify_login "VPN session ends in $minutes_left min" 'Click to log in again now.'
            set_var snooze_until "$((now + REMINDER_MINUTES * 60))"
        fi
    elif [[ $mode == click ]]; then
        case $state in
            busy) post_notification 'No action needed' 'A login is already in progress.' '' ;;
            ok) post_notification 'No action needed' 'The VPN is already connected.' '' ;;
            *) post_notification 'VPN not available' 'The container or Docker is not running.' '' ;;
        esac
    elif [[ $mode == manual ]]; then
        case $state in
            busy) post_notification 'VPN status' 'A login is already in progress.' '' ;;
            ok) post_notification 'VPN status' 'The VPN is connected (or starting). Nothing to do.' '' ;;
            *) post_notification 'VPN status' "The container $CONTAINER_NAME is not running, or Docker is not running." '' ;;
        esac
    fi
}

# The watch_notification subshell calls back here when its action is clicked.
if [[ ${1:-} == --on-click ]]; then
    check_now click
    exit 0
fi

trap 'check_now manual' USR1
# A TERM trap suppresses the signal's own default (terminating) action, so without an explicit
# exit here the daemon would just keep running - never actually stopping on `systemctl stop`.
trap 'clear_notification; exit 0' TERM
trap clear_notification EXIT
check_now auto
while :; do
    sleep "$CHECK_INTERVAL" &
    wait $!
    check_now auto
done
