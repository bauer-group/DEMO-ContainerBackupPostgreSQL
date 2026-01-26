#!/usr/bin/env bash
###############################################################################
#
#   backup-status.sh - Backup Status und Übersicht
#
#   Usage:
#     ./backup-status.sh                    # Auto-detect from .env
#     ./backup-status.sh -s mystack         # Specific stack
#     ./backup-status.sh -b mybucket        # Specific bucket
#     ./backup-status.sh -p production      # With S3 prefix
#
#   Environment:
#     STACK_NAME         Stack prefix (default: demo)
#     S3_BUCKET          S3 bucket name (default: pg-backups)
#     S3_PREFIX          S3 path prefix (default: none)
#
###############################################################################

set -euo pipefail

###############################################################################
# DEFAULTS
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if exists (as fallback)
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  source "$PROJECT_DIR/.env" 2>/dev/null || true
  set +a
fi

###############################################################################
# PARSE ARGUMENTS
###############################################################################

show_help() {
  echo "Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "Show PostgreSQL backup status overview"
  echo ""
  echo "Options:"
  echo "  -s, --stack NAME       Stack prefix name"
  echo "  -b, --bucket NAME      S3 bucket name"
  echo "  -p, --prefix NAME      S3 path prefix"
  echo "  -h, --help             Show this help"
  echo ""
  echo "Environment variables:"
  echo "  STACK_NAME             Stack prefix (default: demo)"
  echo "  S3_BUCKET              S3 bucket name (default: pg-backups)"
  echo "  S3_PREFIX              S3 path prefix (default: none)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0")"
  echo "  $(basename "$0") -s production"
  echo "  $(basename "$0") -p production -b shared-backups"
}

ARG_STACK=""
ARG_BUCKET=""
ARG_PREFIX=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--stack)
      ARG_STACK="$2"
      shift 2
      ;;
    -b|--bucket)
      ARG_BUCKET="$2"
      shift 2
      ;;
    -p|--prefix)
      ARG_PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Resolve: CLI > ENV > default
STACK_NAME="${ARG_STACK:-${STACK_NAME:-demo}}"
S3_BUCKET="${ARG_BUCKET:-${S3_BUCKET:-pg-backups}}"
S3_PREFIX="${ARG_PREFIX:-${S3_PREFIX:-}}"

# Build S3 path
if [[ -n "$S3_PREFIX" ]]; then
  S3_PATH="storage/${S3_BUCKET}/${S3_PREFIX}/"
else
  S3_PATH="storage/${S3_BUCKET}/"
fi

###############################################################################
# FUNCTIONS
###############################################################################

print_header() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ PostgreSQL Backup Status                                        │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Stack:  $STACK_NAME"
  echo "│ Bucket: $S3_BUCKET"
  echo "│ Prefix: ${S3_PREFIX:-<none>}"
  echo "│ Path:   $S3_PATH"
  echo "│ Time:   $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
}

show_containers() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Container Status                                                │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
  docker ps --filter "name=${STACK_NAME}_" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No containers found"
  echo ""
}

show_local_backups() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Local Backups                                                   │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""

  local container="${STACK_NAME}_backup"

  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    echo "Daily:"
    docker exec "$container" sh -c 'ls -lh /backups/daily/*.sql.gz 2>/dev/null | tail -5' || echo "  (none)"
    echo ""
    echo "Weekly:"
    docker exec "$container" sh -c 'ls -lh /backups/weekly/*.sql.gz 2>/dev/null | tail -3' || echo "  (none)"
    echo ""
    echo "Monthly:"
    docker exec "$container" sh -c 'ls -lh /backups/monthly/*.sql.gz 2>/dev/null | tail -3' || echo "  (none)"
  else
    echo "Backup container not running"
  fi
  echo ""
}

show_s3_backups() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ S3 Backups ($S3_PATH)"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""

  local container="${STACK_NAME}_backup_sync"

  if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    docker exec "$container" mc ls "$S3_PATH" --recursive 2>/dev/null | tail -10 || echo "  (none or not accessible)"
  else
    echo "Sync container not running"
  fi
  echo ""
}

show_recent_logs() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Recent Backup Logs                                              │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
  docker logs "${STACK_NAME}_backup" --tail 15 2>/dev/null || echo "No logs available"
  echo ""
}

###############################################################################
# MAIN
###############################################################################

print_header
show_containers
show_local_backups
show_s3_backups
show_recent_logs
