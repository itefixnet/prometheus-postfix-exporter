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
USE_PFLOGSUMM="${USE_PFLOGSUMM:-true}"
LOG_LINES="${LOG_LINES:-10000}"
CACHE_FILE="${CACHE_FILE:-/tmp/postfix_exporter_cache}"
CACHE_TTL="${CACHE_TTL:-60}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
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

# Function to parse log with pflogsumm
parse_with_pflogsumm() {
    if ! command -v pflogsumm >/dev/null 2>&1; then
        log "WARNING: pflogsumm not found, skipping detailed log analysis"
        return 1
    fi
    
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        log "WARNING: Cannot read log file: $POSTFIX_LOG"
        return 1
    fi
    
    # Get recent log lines and run pflogsumm
    local pflog_output
    pflog_output=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null | pflogsumm -d today --smtpd_stats 2>/dev/null || echo "")
    
    if [[ -z "$pflog_output" ]]; then
        return 1
    fi
    
    # Parse pflogsumm output
    local received delivered forwarded deferred bounced rejected held discarded
    local bytes_received bytes_delivered
    
    received=$(echo "$pflog_output" | grep -E "^\s+[0-9]+ received" | grep -oE '[0-9]+' | head -1)
    delivered=$(echo "$pflog_output" | grep -E "^\s+[0-9]+ delivered" | grep -oE '[0-9]+' | head -1)
    forwarded=$(echo "$pflog_output" | grep -E "^\s+[0-9]+ forwarded" | grep -oE '[0-9]+' | head -1)
    deferred=$(echo "$pflog_output" | grep -E "^\s+[0-9]+ deferred" | grep -oE '[0-9]+' | head -1)
    bounced=$(echo "$pflog_output" | grep -E "^\s+[0-9]+ bounced" | grep -oE '[0-9]+' | head -1)
    rejected=$(echo "$pflog_output" | grep -E "^\s+[0-9]+ rejected" | grep -oE '[0-9]+' | head -1)
    
    # Default to 0 if empty
    received=${received:-0}
    delivered=${delivered:-0}
    forwarded=${forwarded:-0}
    deferred=${deferred:-0}
    bounced=${bounced:-0}
    rejected=${rejected:-0}
    
    format_metric "messages_received_total" "$received" "" "Total number of messages received" "counter"
    format_metric "messages_delivered_total" "$delivered" "" "Total number of messages delivered" "counter"
    format_metric "messages_forwarded_total" "$forwarded" "" "Total number of messages forwarded" "counter"
    format_metric "messages_deferred_total" "$deferred" "" "Total number of messages deferred" "counter"
    format_metric "messages_bounced_total" "$bounced" "" "Total number of messages bounced" "counter"
    format_metric "messages_rejected_total" "$rejected" "" "Total number of messages rejected" "counter"
}

# Function to parse log directly (fallback when pflogsumm is not available)
parse_log_direct() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        log "WARNING: Cannot read log file: $POSTFIX_LOG"
        return 0
    fi
    
    local log_data
    log_data=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || true)
    
    if [[ -z "$log_data" ]]; then
        return 0
    fi
    
    # Count various events from recent logs
    local received delivered deferred bounced rejected sent removed
    
    received=$(echo "$log_data" | grep -c "postfix/smtpd.*client=" || true)
    delivered=$(echo "$log_data" | grep -c "postfix/.*status=sent" || true)
    deferred=$(echo "$log_data" | grep -c "postfix/.*status=deferred" || true)
    bounced=$(echo "$log_data" | grep -c "postfix/.*status=bounced" || true)
    rejected=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:" || true)
    
    # grep -c always returns a number (0 if no matches), so no need for defaults
    
    format_metric "messages_received_total" "$received" "" "Total number of messages received" "counter"
    format_metric "messages_delivered_total" "$delivered" "" "Total number of messages delivered" "counter"
    format_metric "messages_deferred_total" "$deferred" "" "Total number of messages deferred" "counter"
    format_metric "messages_bounced_total" "$bounced" "" "Total number of messages bounced" "counter"
    format_metric "messages_rejected_total" "$rejected" "" "Total number of messages rejected" "counter"
}

# Function to get SMTP connection stats
get_smtp_stats() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        return 0
    fi
    
    local log_data
    log_data=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || true)
    
    if [[ -z "$log_data" ]]; then
        return 0
    fi
    
    # Count connections and authentication
    local connections noqueue sasl_authenticated sasl_failed
    
    connections=$(echo "$log_data" | grep -c "postfix/smtpd.*connect from" || true)
    noqueue=$(echo "$log_data" | grep -c "postfix/smtpd.*NOQUEUE:" || true)
    sasl_authenticated=$(echo "$log_data" | grep -c "postfix/smtpd.*sasl_method=" || true)
    sasl_failed=$(echo "$log_data" | grep -c "postfix/smtpd.*SASL.*authentication failed" || true)
    
    format_metric "smtpd_connections_total" "$connections" "" "Total SMTP connections" "counter"
    format_metric "smtpd_noqueue_total" "$noqueue" "" "Total NOQUEUE rejections" "counter"
    format_metric "smtpd_sasl_authenticated_total" "$sasl_authenticated" "" "Total SASL authenticated sessions" "counter"
    format_metric "smtpd_sasl_failed_total" "$sasl_failed" "" "Total SASL authentication failures" "counter"
}

# Function to get rejection reasons
get_rejection_stats() {
    if [[ ! -r "$POSTFIX_LOG" ]]; then
        return 0
    fi
    
    local log_data
    log_data=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || true)
    
    if [[ -z "$log_data" ]]; then
        return 0
    fi
    
    # Count different rejection reasons
    local reject_rbl reject_helo reject_sender reject_recipient reject_client reject_unknown_user
    
    reject_rbl=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:.*RBL" || true)
    reject_helo=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:.*HELO" || true)
    reject_sender=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:.*Sender address rejected" || true)
    reject_recipient=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:.*Recipient address rejected" || true)
    reject_client=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:.*Client host rejected" || true)
    reject_unknown_user=$(echo "$log_data" | grep -c "postfix/smtpd.*reject:.*User unknown" || true)
    
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
    
    local log_data
    log_data=$(tail -n "$LOG_LINES" "$POSTFIX_LOG" 2>/dev/null || true)
    
    if [[ -z "$log_data" ]]; then
        return 0
    fi
    
    # Count delivery by transport
    local smtp_delivery lmtp_delivery virtual_delivery pipe_delivery
    
    smtp_delivery=$(echo "$log_data" | grep -c "postfix/smtp.*status=sent" || true)
    lmtp_delivery=$(echo "$log_data" | grep -c "postfix/lmtp.*status=sent" || true)
    virtual_delivery=$(echo "$log_data" | grep -c "postfix/virtual.*status=sent" || true)
    pipe_delivery=$(echo "$log_data" | grep -c "postfix/pipe.*status=sent" || true)
    
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
    
    # Collect log-based metrics
    if [[ "$USE_PFLOGSUMM" == "true" ]]; then
        if parse_with_pflogsumm; then
            echo ""
        else
            parse_log_direct
            echo ""
        fi
    else
        parse_log_direct
        echo ""
    fi
    
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
    
    # Check pflogsumm
    if [[ "$USE_PFLOGSUMM" == "true" ]]; then
        if command -v pflogsumm >/dev/null 2>&1; then
            log "SUCCESS: pflogsumm is available"
        else
            log "WARNING: pflogsumm not found (will use direct log parsing)"
        fi
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
        collect_metrics
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
        echo "  USE_PFLOGSUMM        - Use pflogsumm for log analysis (default: true)"
        echo "  LOG_LINES            - Number of log lines to analyze (default: 10000)"
        ;;
    *)
        log "ERROR: Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
