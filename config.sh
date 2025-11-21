#!/bin/bash
#
# Postfix Prometheus Exporter Configuration
# Source this file to configure the exporter settings
#

# Postfix Configuration
export POSTFIX_LOG="${POSTFIX_LOG:-/var/log/mail.log}"
export POSTFIX_QUEUE_DIR="${POSTFIX_QUEUE_DIR:-/var/spool/postfix}"

# Prometheus Exporter Configuration
export METRICS_PREFIX="${METRICS_PREFIX:-postfix}"

# HTTP Server Configuration
export LISTEN_PORT="${LISTEN_PORT:-9154}"
export LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
export MAX_CONNECTIONS="${MAX_CONNECTIONS:-10}"
export TIMEOUT="${TIMEOUT:-30}"

# Logging Configuration
export LOG_LEVEL="${LOG_LEVEL:-info}"

# pflogsumm Configuration
export USE_PFLOGSUMM="${USE_PFLOGSUMM:-true}"
export LOG_LINES="${LOG_LINES:-10000}"

# Cache Configuration
export CACHE_FILE="${CACHE_FILE:-/tmp/postfix_exporter_cache}"
export CACHE_TTL="${CACHE_TTL:-60}"

# Advanced Configuration
export ENABLE_EXTENDED_METRICS="${ENABLE_EXTENDED_METRICS:-true}"
