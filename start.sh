#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WATCHDOG_PID_FILE="/tmp/ssh-tunnel-watchdog.pid"
# Watchdog check interval in seconds. Overridable via $2 (e.g. `start.sh --always 10`)
# or the WATCHDOG_INTERVAL env var; falls back to 30.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"

if [ ! -f "${ENV_FILE}" ]; then
    echo "Config file not found: ${ENV_FILE}"
    exit 1
fi

source "${ENV_FILE}"

# Platform detection: pick Privoxy config path and service manager
if [ "$(uname -s)" = "Darwin" ]; then
    PRIVOXY_CONFIG="${PRIVOXY_CONFIG:-/opt/homebrew/etc/privoxy/config}"
    PRIVOXY_INSTALL_HINT="brew install privoxy"
else
    PRIVOXY_CONFIG="${PRIVOXY_CONFIG:-/etc/privoxy/config}"
    PRIVOXY_INSTALL_HINT="sudo apt-get install privoxy"
fi

privoxy_restart() {
    if [ "$(uname -s)" = "Darwin" ]; then
        brew services restart privoxy
    elif command -v systemctl &>/dev/null; then
        systemctl restart privoxy
    else
        service privoxy restart
    fi
}

# Check dependencies
if ! command -v privoxy &>/dev/null; then
    echo "privoxy not found, install with: ${PRIVOXY_INSTALL_HINT}"
    exit 1
fi

if [ ! -f "${PRIVOXY_CONFIG}" ]; then
    echo "privoxy config not found at ${PRIVOXY_CONFIG}"
    exit 1
fi

start_ssh_tunnel() {
    pkill -f "ssh.*-D ${SOCKS_PORT}.*${SSH_HOST}" 2>/dev/null
    sleep 1
    ssh -fNC \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o ConnectTimeout=10 \
        -D ${SOCKS_PORT} ${SSH_HOST}
}

# Start SSH tunnel
echo "$(date): Starting SSH tunnel..." >> "$LOG_FILE"
start_ssh_tunnel

sleep 2

# Start Privoxy
cat > "${PRIVOXY_CONFIG}" << EOF
forward-socks5 / 127.0.0.1:${SOCKS_PORT} .
listen-address 127.0.0.1:${HTTP_PROXY_PORT}
EOF
privoxy_restart >> "$LOG_FILE" 2>&1
sleep 2

# Health check
if curl -s --max-time 5 -x http://127.0.0.1:${HTTP_PROXY_PORT} \
    https://api.anthropic.com/v1/models 2>/dev/null | grep -q "authentication_error"; then
    echo "Tunnel + proxy OK"
    echo "$(date): Tunnel + proxy started successfully" >> "$LOG_FILE"
elif curl -s --max-time 5 --socks5-hostname 127.0.0.1:${SOCKS_PORT} \
    https://api.ipify.org 2>/dev/null | grep -q "."; then
    echo "Tunnel OK but proxy failed"
    echo "$(date): Tunnel OK but proxy failed" >> "$LOG_FILE"
else
    echo "Tunnel failed to start"
    echo "$(date): Tunnel failed to start" >> "$LOG_FILE"
fi

# Optional watchdog for auto-reconnect
if [ "$1" = "--always" ]; then
    # Optional interval override: `start.sh --always 10` -> check every 10s
    if [ -n "$2" ]; then
        if [ "$2" -gt 0 ] 2>/dev/null; then
            WATCHDOG_INTERVAL="$2"
        else
            echo "Invalid interval '$2', using ${WATCHDOG_INTERVAL}s"
        fi
    fi

    if [ -f "${WATCHDOG_PID_FILE}" ]; then
        kill "$(cat "${WATCHDOG_PID_FILE}")" 2>/dev/null
        rm -f "${WATCHDOG_PID_FILE}"
    fi

    (
        while true; do
            sleep "${WATCHDOG_INTERVAL}"
            if ! curl -s --max-time 5 --socks5-hostname 127.0.0.1:${SOCKS_PORT} \
                https://api.ipify.org 2>/dev/null | grep -qE "[0-9]+\.[0-9]+"; then
                echo "$(date): Tunnel down, reconnecting..." >> "$LOG_FILE"
                start_ssh_tunnel
            fi
        done
    ) &
    WATCHDOG_PID=$!
    echo "${WATCHDOG_PID}" > "${WATCHDOG_PID_FILE}"
    echo "Watchdog enabled (PID ${WATCHDOG_PID}), checking every ${WATCHDOG_INTERVAL}s"
    echo "$(date): Watchdog started (PID ${WATCHDOG_PID})" >> "$LOG_FILE"
fi

echo "Log: tail -f $LOG_FILE"
