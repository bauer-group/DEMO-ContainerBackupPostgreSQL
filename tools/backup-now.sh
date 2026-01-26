#!/usr/bin/env bash
###############################################################################
#
#   backup-now.sh - Manuelles PostgreSQL Backup
#
#   Usage:
#     ./backup-now.sh                      # Auto-detect from .env
#     ./backup-now.sh -s mystack           # Specific stack
#     ./backup-now.sh -c myapp_backup      # Specific container
#
#   Environment:
#     STACK_NAME         Stack prefix (default: demo)
#     BACKUP_CONTAINER   Container name (default: ${STACK_NAME}_backup)
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
  echo "Trigger a manual PostgreSQL backup"
  echo ""
  echo "Options:"
  echo "  -s, --stack NAME       Stack prefix name"
  echo "  -c, --container NAME   Backup container name"
  echo "  -h, --help             Show this help"
  echo ""
  echo "Environment variables:"
  echo "  STACK_NAME             Stack prefix (default: demo)"
  echo "  BACKUP_CONTAINER       Container name"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0")"
  echo "  $(basename "$0") -s production"
  echo "  $(basename "$0") -c mystack_backup"
}

ARG_STACK=""
ARG_CONTAINER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--stack)
      ARG_STACK="$2"
      shift 2
      ;;
    -c|--container)
      ARG_CONTAINER="$2"
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

# Resolve stack name first: CLI > ENV > default
STACK_NAME="${ARG_STACK:-${STACK_NAME:-demo}}"

# Resolve container: CLI > ENV > default (using resolved STACK_NAME)
CONTAINER="${ARG_CONTAINER:-${BACKUP_CONTAINER:-${STACK_NAME}_backup}}"

###############################################################################
# FUNCTIONS
###############################################################################

print_header() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ PostgreSQL Backup                                               │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Container: $CONTAINER"
  echo "│ Time:      $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
}

check_container() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: Container '$CONTAINER' not running"
    echo ""
    echo "Available backup containers:"
    docker ps --format '{{.Names}}' | grep -E '_backup$|backup' || echo "  (none found)"
    echo ""
    exit 1
  fi
}

run_backup() {
  echo "Starting backup..."
  docker exec "$CONTAINER" /backup.sh
}

show_result() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Backup Complete                                                 │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "Recent backups:"
  docker exec "$CONTAINER" find /backups -name "*.sql.gz" -type f -mmin -60 -exec ls -lh {} \; 2>/dev/null | head -5 || echo "  (none in last hour)"
  echo ""
}

###############################################################################
# MAIN
###############################################################################

print_header
check_container
run_backup
show_result
