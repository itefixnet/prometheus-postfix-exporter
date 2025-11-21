#!/bin/bash
#
# Postfix Prometheus Exporter HTTP Server
# Uses socat to serve Prometheus metrics via HTTP
#

# Set strict error handling
set -euo pipefail

# Source configuration if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Default configuration
LISTEN_PORT="${LISTEN_PORT:-9154}"
LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
EXPORTER_SCRIPT="${EXPORTER_SCRIPT:-${SCRIPT_DIR}/postfix-exporter.sh}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-10}"
TIMEOUT="${TIMEOUT:-30}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Function to start the HTTP server
start_server() {
    log "Starting Postfix Prometheus Exporter HTTP Server"
    log "Listening on ${LISTEN_ADDRESS}:${LISTEN_PORT}"
    log "Exporter script: $EXPORTER_SCRIPT"
    log "Max connections: $MAX_CONNECTIONS"
    log "Timeout: ${TIMEOUT}s"
    
    # Check if exporter script exists and is executable
    if [[ ! -x "$EXPORTER_SCRIPT" ]]; then
        log "ERROR: Exporter script not found or not executable: $EXPORTER_SCRIPT"
        exit 1
    fi
    
    # Check if socat is available
    if ! command -v socat >/dev/null 2>&1; then
        log "ERROR: socat not found in PATH. Please install socat."
        exit 1
    fi
    
    # Test exporter script
    log "Testing exporter script..."
    if ! "$EXPORTER_SCRIPT" test; then
        log "WARNING: Exporter test failed, but continuing anyway"
    else
        log "Exporter test successful"
    fi
    
    # Create a temporary handler script
    local handler_script="/tmp/postfix_handler_$$"
    
    cat > "$handler_script" << 'EOF'
#!/bin/bash
read request_line
path=$(echo "$request_line" | cut -d' ' -f2)

# Skip headers
while read line && [ "$line" != "" ] && [ "$line" != "$(printf '\r')" ]; do
    continue
done

case "$path" in
    "/metrics")
        metrics=$(EXPORTER_SCRIPT collect 2>/dev/null || echo "# Error collecting metrics")
        printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: %d\r\n\r\n%s" "$(printf "%s" "$metrics" | wc -c)" "$metrics"
        ;;
    "/health")
        if EXPORTER_SCRIPT test >/dev/null 2>&1; then
            printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK"
        else
            printf "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nERROR"
        fi
        ;;
    "/")
        html="<!DOCTYPE html><html><head><title>Postfix Exporter</title></head><body><h1>Postfix Prometheus Exporter</h1><p><a href=\"/metrics\">Metrics</a> | <a href=\"/health\">Health</a></p><h2>Configuration</h2><pre>$(EXPORTER_SCRIPT help 2>/dev/null || echo "Help not available")</pre></body></html>"
        printf "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\n\r\n%s" "$(printf "%s" "$html" | wc -c)" "$html"
        ;;
    *)
        printf "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\n404 Not Found"
        ;;
esac
EOF
    
    # Replace EXPORTER_SCRIPT placeholder with actual path
    sed -i "s|EXPORTER_SCRIPT|$EXPORTER_SCRIPT|g" "$handler_script"
    chmod +x "$handler_script"
    
    # Cleanup on exit
    trap "rm -f '$handler_script'" EXIT
    
    log "Server starting..."
    
    # Use socat with the handler script
    exec socat TCP-LISTEN:${LISTEN_PORT},bind=${LISTEN_ADDRESS},reuseaddr,fork EXEC:"$handler_script"
}

# Function to stop the server (for systemd)
stop_server() {
    log "Stopping Postfix Prometheus Exporter HTTP Server"
    # Kill any socat processes listening on our port
    pkill -f "socat.*TCP-LISTEN:${LISTEN_PORT}" || true
}

# Signal handlers for graceful shutdown
trap 'stop_server; exit 0' SIGTERM SIGINT

# Handle command line arguments
case "${1:-start}" in
    "start"|"")
        start_server
        ;;
    "stop")
        stop_server
        ;;
    "restart")
        stop_server
        sleep 2
        start_server
        ;;
    "test")
        log "Testing HTTP server configuration..."
        if [[ ! -x "$EXPORTER_SCRIPT" ]]; then
            log "ERROR: Exporter script not found or not executable: $EXPORTER_SCRIPT"
            exit 1
        fi
        if ! command -v socat >/dev/null 2>&1; then
            log "ERROR: socat not found in PATH"
            exit 1
        fi
        log "Configuration test successful"
        ;;
    "version")
        echo "Postfix Exporter HTTP Server v1.0.0"
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [start|stop|restart|test|version|help]"
        echo ""
        echo "Commands:"
        echo "  start    - Start the HTTP server (default)"
        echo "  stop     - Stop the HTTP server"
        echo "  restart  - Restart the HTTP server"
        echo "  test     - Test configuration"
        echo "  version  - Show server version"
        echo "  help     - Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  LISTEN_PORT       - HTTP server port (default: 9154)"
        echo "  LISTEN_ADDRESS    - HTTP server bind address (default: 0.0.0.0)"
        echo "  EXPORTER_SCRIPT   - Path to exporter script (default: ./postfix-exporter.sh)"
        echo "  MAX_CONNECTIONS   - Maximum concurrent connections (default: 10)"
        echo "  TIMEOUT          - Request timeout in seconds (default: 30)"
        ;;
    *)
        log "ERROR: Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
