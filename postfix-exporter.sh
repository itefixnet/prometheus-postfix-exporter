#!/bin/bash
#
# Postfix Prometheus Exporter
# A bash-based exporter for Postfix mail server statistics
#

# Set strict error handling
set -euo pipefail

# Source configuration if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Default configuration
POSTFIX_LOG="${POSTFIX_LOG:-/var/log/mail.log}"
POSTFIX_QUEUE_DIR="${POSTFIX_QUEUE_DIR:-/var/spool/postfix}"
METRICS_PREFIX="${METRICS_PREFIX:-postfix}"
LOG_LINES="${LOG_LINES:-10000}"
STATE_FILE="${STATE_FILE:-/var/lib/postfix-exporter/state}"
CACHE_TTL="${CACHE_TTL:-60}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Initialize state directory and file
init_state() {
    local state_dir
    state_dir="$(dirname "$STATE_FILE")"
    
    log "Using state file: $STATE_FILE"
    
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            log "WARNING: Cannot create state directory $state_dir, using /tmp"
            STATE_FILE="/tmp/postfix-exporter-state"
            log "State file changed to: $STATE_FILE"
        }
    fi
    
    if [[ ! -f "$STATE_FILE" ]]; then
        log "Initializing new state file"
        # Initialize state file with zeros
        cat > "$STATE_FILE" <<EOF
last_inode=0
last_position=0
messages_received=0
messages_delivered=0
messages_deferred=0
messages_bounced=0
messages_rejected=0
smtpd_connections=0
smtpd_noqueue=0
smtpd_sasl_authenticated=0
smtpd_sasl_failed=0
reject_rbl=0
reject_helo=0
reject_sender=0
reject_recipient=0
reject_client=0
reject_unknown_user=0
smtp_delivery=0
lmtp_delivery=0
virtual_delivery=0
pipe_delivery=0
EOF
    fi
}

# Load state from file
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
    fi
}

# Save state to file
save_state() {
    cat > "$STATE_FILE" <<EOF
last_inode=$last_inode
last_position=$last_position
messages_received=$messages_received
messages_delivered=$messages_delivered
messages_deferred=$messages_deferred
messages_bounced=$messages_bounced
messages_rejected=$messages_rejected
smtpd_connections=$smtpd_connections
smtpd_noqueue=$smtpd_noqueue
smtpd_sasl_authenticated=$smtpd_sasl_authenticated
smtpd_sasl_failed=$smtpd_sasl_failed
reject_rbl=$reject_rbl
reject_helo=$reject_helo
reject_sender=$reject_sender
reject_recipient=$reject_recipient
reject_client=$reject_client
reject_unknown_user=$reject_unknown_user
smtp_delivery=$smtp_delivery
lmtp_delivery=$lmtp_delivery
virtual_delivery=$virtual_delivery
pipe_delivery=$pipe_delivery
EOF
}

# Array to track metrics that have been defined
declare -A METRIC_DEFINED

# Function to format Prometheus metric
format_metric() {
    local metric_name="$1"
    local value="$2"
    local labels="$3"
    local help="$4"
    local type="${5:-gauge}"
    
    local full_name="${METRICS_PREFIX}_${metric_name}"

    # Only output HELP and TYPE once per metric name
    if [[ -z "${METRIC_DEFINED[$full_name]:-}" ]]; then
        echo "# HELP ${full_name} ${help}"
        echo "# TYPE ${full_name} ${type}"
        METRIC_DEFINED[$full_name]=1
    fi
    
    if [[ -n "$labels" ]]; then
        echo "${full_name}{${labels}} ${value}"
    else
        echo "${full_name} ${value}"
    fi
}

# Function to get queue counts
get_queue_stats() {
    if [[ ! -d "$POSTFIX_QUEUE_DIR" ]]; then
        log "WARNING: Postfix queue directory not found: $POSTFIX_QUEUE_DIR"
        return 0
    fi
    
    # Count messages in various queues
    local incoming maildrop active deferred hold corrupt
    
    incoming=$(find "${POSTFIX_QUEUE_DIR}/incoming" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
    maildrop=$(find "${POSTFIX_QUEUE_DIR}/maildrop" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
    active=$(find "${POSTFIX_QUEUE_DIR}/active" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
    deferred=$(find "${POSTFIX_QUEUE_DIR}/deferred" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
    hold=$(find "${POSTFIX_QUEUE_DIR}/hold" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
    corrupt=$(find "${POSTFIX_QUEUE_DIR}/corrupt" -type f 2>/dev/null | wc -l | tr -d ' ' || true)
    
    # Default to 0 if empty
    incoming=${incoming:-0}
    maildrop=${maildrop:-0}
    active=${active:-0}
    deferred=${deferred:-0}
    hold=${hold:-0}
    corrupt=${corrupt:-0}
    
    format_metric "queue_size" "$incoming" "queue=\"incoming\"" "Number of messages in queue"
    format_metric "queue_size" "$maildrop" "queue=\"maildrop\"" "Number of messages in queue"
    format_metric "queue_size" "$active" "queue=\"active\"" "Number of messages in queue"
    format_metric "queue_size" "$deferred" "queue=\"deferred\"" "Number of messages in queue"
    format_metric "queue_size" "$hold" "queue=\"hold\"" "Number of messages in queue"
    format_metric "queue_size" "$corrupt" "queue=\"corrupt\"" "Number of messages in queue"
}

# Function to parse log directly and update counters
parse_log_direct() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        log "WARNING: Cannot read log file: $POSTFIX_LOG"
        return 0
    fi
    
    # Get current log file inode
    local current_inode
    current_inode=$(stat -c '%i' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    
    # Check if log file was rotated
    if [[ "$current_inode" != "$last_inode" ]]; then
        log "Log file rotated, resetting position"
        last_position=0
        last_inode=$current_inode
    fi
    
    # Get current file size
    local current_size
    current_size=$(stat -c '%s' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    
    # If file was truncated, reset position
    if [[ $current_size -lt $last_position ]]; then
        log "Log file truncated, resetting position"
        last_position=0
    fi
    
    # Read only new lines since last position
    local new_lines
    if [[ $last_position -gt 0 ]]; then
        new_lines=$(tail -c +$((last_position + 1)) "$POSTFIX_LOG" 2>/dev/null || echo "")
    else
        # First run, read last LOG_LINES entries
        new_lines=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$new_lines" ]]; then
        return 0
    fi
    
    # Count events in new lines and increment counters
    local count
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*client=" || true)
    messages_received=$((messages_received + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/.*status=sent" || true)
    messages_delivered=$((messages_delivered + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/.*status=deferred" || true)
    messages_deferred=$((messages_deferred + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/.*status=bounced" || true)
    messages_bounced=$((messages_bounced + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:" || true)
    messages_rejected=$((messages_rejected + count))
    
    # Update position
    last_position=$current_size
    
    # Output metrics
    format_metric "messages_received_total" "$messages_received" "" "Total number of messages received" "counter"
    format_metric "messages_delivered_total" "$messages_delivered" "" "Total number of messages delivered" "counter"
    format_metric "messages_deferred_total" "$messages_deferred" "" "Total number of messages deferred" "counter"
    format_metric "messages_bounced_total" "$messages_bounced" "" "Total number of messages bounced" "counter"
    format_metric "messages_rejected_total" "$messages_rejected" "" "Total number of messages rejected" "counter"
}

# Function to get SMTP connection stats
get_smtp_stats() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        return 0
    fi
    
    # Get current log file info
    local current_inode current_size
    current_inode=$(stat -c '%i' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    current_size=$(stat -c '%s' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    
    # Read only new lines
    local new_lines
    if [[ "$current_inode" == "$last_inode" ]] && [[ $last_position -gt 0 ]] && [[ $current_size -ge $last_position ]]; then
        new_lines=$(tail -c +$((last_position + 1)) "$POSTFIX_LOG" 2>/dev/null || echo "")
    else
        new_lines=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$new_lines" ]]; then
        return 0
    fi
    
    # Count connections and authentication
    local count
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*connect from" || true)
    smtpd_connections=$((smtpd_connections + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*NOQUEUE:" || true)
    smtpd_noqueue=$((smtpd_noqueue + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*sasl_method=" || true)
    smtpd_sasl_authenticated=$((smtpd_sasl_authenticated + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*SASL.*authentication failed" || true)
    smtpd_sasl_failed=$((smtpd_sasl_failed + count))
    
    format_metric "smtpd_connections_total" "$smtpd_connections" "" "Total SMTP connections" "counter"
    format_metric "smtpd_noqueue_total" "$smtpd_noqueue" "" "Total NOQUEUE rejections" "counter"
    format_metric "smtpd_sasl_authenticated_total" "$smtpd_sasl_authenticated" "" "Total SASL authenticated sessions" "counter"
    format_metric "smtpd_sasl_failed_total" "$smtpd_sasl_failed" "" "Total SASL authentication failures" "counter"
}

# Function to get rejection reasons
get_rejection_stats() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        return 0
    fi
    
    # Get current log file info
    local current_inode current_size
    current_inode=$(stat -c '%i' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    current_size=$(stat -c '%s' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    
    # Read only new lines
    local new_lines
    if [[ "$current_inode" == "$last_inode" ]] && [[ $last_position -gt 0 ]] && [[ $current_size -ge $last_position ]]; then
        new_lines=$(tail -c +$((last_position + 1)) "$POSTFIX_LOG" 2>/dev/null || echo "")
    else
        new_lines=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$new_lines" ]]; then
        return 0
    fi
    
    # Count different rejection reasons
    local count
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:.*RBL" || true)
    reject_rbl=$((reject_rbl + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:.*HELO" || true)
    reject_helo=$((reject_helo + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:.*Sender address rejected" || true)
    reject_sender=$((reject_sender + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:.*Recipient address rejected" || true)
    reject_recipient=$((reject_recipient + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:.*Client host rejected" || true)
    reject_client=$((reject_client + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/smtpd.*reject:.*User unknown" || true)
    reject_unknown_user=$((reject_unknown_user + count))
    
    format_metric "smtpd_reject_total" "$reject_rbl" "reason=\"rbl\"" "SMTP rejections by reason" "counter"
    format_metric "smtpd_reject_total" "$reject_helo" "reason=\"helo\"" "SMTP rejections by reason" "counter"
    format_metric "smtpd_reject_total" "$reject_sender" "reason=\"sender\"" "SMTP rejections by reason" "counter"
    format_metric "smtpd_reject_total" "$reject_recipient" "reason=\"recipient\"" "SMTP rejections by reason" "counter"
    format_metric "smtpd_reject_total" "$reject_client" "reason=\"client\"" "SMTP rejections by reason" "counter"
    format_metric "smtpd_reject_total" "$reject_unknown_user" "reason=\"unknown_user\"" "SMTP rejections by reason" "counter"
}

# Function to get delivery status details
get_delivery_stats() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        return 0
    fi
    
    # Get current log file info
    local current_inode current_size
    current_inode=$(stat -c '%i' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    current_size=$(stat -c '%s' "$POSTFIX_LOG" 2>/dev/null || echo "0")
    
    # Read only new lines
    local new_lines
    if [[ "$current_inode" == "$last_inode" ]] && [[ $last_position -gt 0 ]] && [[ $current_size -ge $last_position ]]; then
        new_lines=$(tail -c +$((last_position + 1)) "$POSTFIX_LOG" 2>/dev/null || echo "")
    else
        new_lines=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$new_lines" ]]; then
        return 0
    fi
    
    # Count delivery by transport
    local count
    
    count=$(echo "$new_lines" | grep -c "postfix/smtp.*status=sent" || true)
    smtp_delivery=$((smtp_delivery + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/lmtp.*status=sent" || true)
    lmtp_delivery=$((lmtp_delivery + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/virtual.*status=sent" || true)
    virtual_delivery=$((virtual_delivery + count))
    
    count=$(echo "$new_lines" | grep -c "postfix/pipe.*status=sent" || true)
    pipe_delivery=$((pipe_delivery + count))
    
    format_metric "delivery_status_total" "$smtp_delivery" "transport=\"smtp\",status=\"sent\"" "Deliveries by transport and status" "counter"
    format_metric "delivery_status_total" "$lmtp_delivery" "transport=\"lmtp\",status=\"sent\"" "Deliveries by transport and status" "counter"
    format_metric "delivery_status_total" "$virtual_delivery" "transport=\"virtual\",status=\"sent\"" "Deliveries by transport and status" "counter"
    format_metric "delivery_status_total" "$pipe_delivery" "transport=\"pipe\",status=\"sent\"" "Deliveries by transport and status" "counter"
}

# Function to get Postfix version
get_version_info() {
    local version
    
    if command -v postconf >/dev/null 2>&1; then
        version=$(postconf -d mail_version 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "unknown")
        format_metric "version_info" "1" "version=\"${version}\"" "Postfix version information"
    fi
}

# Function to get process status
get_process_stats() {
    local master_running master_pid master_uptime
    
    if pgrep -x "master" >/dev/null 2>&1; then
        master_running=1
        master_pid=$(pgrep -x "master" | head -1)
        
        # Get process uptime in seconds
        if [[ -n "$master_pid" ]]; then
            master_uptime=$(ps -p "$master_pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "0")
        else
            master_uptime=0
        fi
    else
        master_running=0
        master_uptime=0
    fi
    
    format_metric "master_process_running" "$master_running" "" "Postfix master process status (1=running, 0=not running)"
    format_metric "master_process_uptime_seconds" "$master_uptime" "" "Postfix master process uptime in seconds" "counter"
}

# Main function to collect and output all metrics
collect_metrics() {
    # Output metrics header
    echo "# Postfix Mail Server Metrics"
    echo "# Generated at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    
    # Collect process stats
    get_process_stats
    echo ""
    
    # Collect version info
    get_version_info
    echo ""
    
    # Collect queue stats
    get_queue_stats
    echo ""
    
    # Collect log-based metrics (always use direct parsing with state)
    parse_log_direct
    echo ""
    
    # Collect SMTP stats
    get_smtp_stats
    echo ""
    
    # Collect rejection stats
    get_rejection_stats
    echo ""
    
    # Collect delivery stats
    get_delivery_stats
}

# Function to test connectivity
test_connection() {
    log "Testing Postfix exporter configuration..."
    
    local errors=0
    
    # Check if Postfix is running
    if ! pgrep -x "master" >/dev/null 2>&1; then
        log "WARNING: Postfix master process is not running"
        errors=$((errors + 1))
    else
        log "SUCCESS: Postfix master process is running"
    fi
    
    # Check queue directory
    if [[ ! -d "$POSTFIX_QUEUE_DIR" ]]; then
        log "ERROR: Queue directory not found: $POSTFIX_QUEUE_DIR"
        errors=$((errors + 1))
    else
        log "SUCCESS: Queue directory found: $POSTFIX_QUEUE_DIR"
    fi
    
    # Check log file
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        log "WARNING: Cannot read log file: $POSTFIX_LOG"
        log "You may need to run the exporter with appropriate permissions"
        errors=$((errors + 1))
    else
        log "SUCCESS: Log file readable: $POSTFIX_LOG"
    fi
    
    # Check postconf
    if command -v postconf >/dev/null 2>&1; then
        log "SUCCESS: postconf is available"
    else
        log "WARNING: postconf not found (version info will not be available)"
    fi
    
    if [[ $errors -eq 0 ]]; then
        log "Configuration test completed successfully"
        return 0
    else
        log "Configuration test completed with $errors errors/warnings"
        return 1
    fi
}

# Handle command line arguments
case "${1:-collect}" in
    "collect"|"metrics"|"")
        # Initialize and load state before collecting metrics
        init_state
        load_state
        
        # Collect and output metrics
        collect_metrics
        
        # Save state after collecting metrics
        save_state
        ;;
    "test")
        test_connection
        ;;
    "version")
        echo "Postfix Exporter v1.0.0"
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [collect|test|version|help]"
        echo ""
        echo "Commands:"
        echo "  collect  - Collect and output Prometheus metrics (default)"
        echo "  test     - Test configuration and Postfix accessibility"
        echo "  version  - Show exporter version"
        echo "  help     - Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  POSTFIX_LOG          - Path to Postfix log file (default: /var/log/mail.log)"
        echo "  POSTFIX_QUEUE_DIR    - Path to Postfix queue directory (default: /var/spool/postfix)"
        echo "  METRICS_PREFIX       - Metrics prefix (default: postfix)"
        echo "  STATE_FILE           - State file for persistent counters (default: /var/lib/postfix-exporter/state)"
        echo "  LOG_LINES            - Number of log lines to parse on first run (default: 10000)"
        ;;
    *)
        log "ERROR: Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
