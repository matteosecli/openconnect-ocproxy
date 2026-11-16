#!/bin/sh
# Prints the login state of the VPN container, as one line, for the macOS and Linux notifiers.
# Shared because it is the whole interface between a helper and the container: anything reading
# this output only needs vpn-status's fields (state, reason, expires_epoch) and login.lock to stay
# as they are. Output:
#   unavailable                      Docker or the container is not running
#   busy                             a vpn-login is already in progress
#   login <reason>                   a login is needed; reason as in vpn-status (login-required,
#                                    tunnel-exited-<code>, startup-failed, health-check-failed)
#   expiring <minutes> <epoch>       the session expires within the warning window
#   ok                               connected or starting, nothing to do
# Usage: vpn-state.sh [container-name] [warning-seconds]
c=${1:-openconnect-ocproxy}
warn=${2:-900}
# Apps started from Finder get a minimal PATH; add the usual Docker CLI locations.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin"
command -v docker >/dev/null 2>&1 || { echo unavailable; exit 0; }
[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo unavailable; exit 0; }
status=$(docker exec "$c" vpn-status 2>/dev/null)
# vpn-login holds this lock for the whole login; a second prompt would only be refused.
docker exec "$c" sh -c 'exec 9>>"${VPN_RUNTIME:-/run/vpn}/login.lock" && flock -n 9' >/dev/null 2>&1 || {
    echo busy; exit 0;
}
case $status in
    *state=AUTH_REQUIRED*)
        reason=$(printf '%s\n' "$status" | sed -n 's/^reason=\([a-z0-9-]*\)$/\1/p')
        echo "login ${reason:-unknown}"; exit 0 ;;
esac
expires=$(printf '%s\n' "$status" | sed -n 's/^expires_epoch=\([0-9][0-9]*\)$/\1/p')
if [ -n "$expires" ]; then
    left=$((expires - $(date +%s)))
    if [ "$left" -le "$warn" ]; then
        [ "$left" -gt 0 ] || left=0
        echo "expiring $(( (left + 59) / 60 )) $expires"; exit 0
    fi
fi
echo ok
