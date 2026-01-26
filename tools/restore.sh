#!/usr/bin/env bash
###############################################################################
#
#   restore.sh - PostgreSQL Restore
#
#   Usage:
#     ./restore.sh <backup-file>
#     ./restore.sh -s mystack daily/mydb-20250126.sql.gz
#     ./restore.sh --db otherdb daily/otherdb-20250126.sql.gz
#
#   Environment:
#     STACK_NAME         Stack prefix (default: demo)
#     POSTGRES_USER      Database user (default: demoapp)
#     POSTGRES_DB        Database name (default: demodb)
#     BACKUP_CONTAINER   Backup container (default: ${STACK_NAME}_backup)
#     POSTGRES_CONTAINER PostgreSQL container (default: ${STACK_NAME}_postgres)
#
#   Examples:
#     ./restore.sh daily/demodb-20250126-030000.sql.gz
#     ./restore.sh weekly/demodb-20250119-030000.sql.gz
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
  echo "Usage: $(basename "$0") [OPTIONS] <backup-file>"
  echo ""
  echo "Restore a PostgreSQL backup"
  echo ""
  echo "Options:"
  echo "  -s, --stack NAME       Stack prefix name"
  echo "  -u, --user NAME        PostgreSQL user"
  echo "  -d, --db NAME          Database name"
  echo "  -b, --backup NAME      Backup container name"
  echo "  -p, --postgres NAME    PostgreSQL container name"
  echo "  -h, --help             Show this help"
  echo ""
  echo "Environment variables:"
  echo "  STACK_NAME             Stack prefix (default: demo)"
  echo "  POSTGRES_USER          Database user (default: demoapp)"
  echo "  POSTGRES_DB            Database name (default: demodb)"
  echo "  BACKUP_CONTAINER       Backup container name"
  echo "  POSTGRES_CONTAINER     PostgreSQL container name"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") daily/demodb-20250126-030000.sql.gz"
  echo "  $(basename "$0") -s production daily/proddb-20250126.sql.gz"
  echo "  $(basename "$0") --db mydb --user myuser weekly/mydb-20250119.sql.gz"
}

ARG_STACK=""
ARG_USER=""
ARG_DB=""
ARG_BACKUP_CONTAINER=""
ARG_POSTGRES_CONTAINER=""
BACKUP_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--stack)
      ARG_STACK="$2"
      shift 2
      ;;
    -u|--user)
      ARG_USER="$2"
      shift 2
      ;;
    -d|--db)
      ARG_DB="$2"
      shift 2
      ;;
    -b|--backup)
      ARG_BACKUP_CONTAINER="$2"
      shift 2
      ;;
    -p|--postgres)
      ARG_POSTGRES_CONTAINER="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      BACKUP_FILE="$1"
      shift
      ;;
  esac
done

# Resolve stack name first: CLI > ENV > default
STACK_NAME="${ARG_STACK:-${STACK_NAME:-demo}}"

# Resolve all parameters: CLI > ENV > default
POSTGRES_USER="${ARG_USER:-${POSTGRES_USER:-demoapp}}"
POSTGRES_DB="${ARG_DB:-${POSTGRES_DB:-demodb}}"
BACKUP_CONTAINER="${ARG_BACKUP_CONTAINER:-${BACKUP_CONTAINER:-${STACK_NAME}_backup}}"
POSTGRES_CONTAINER="${ARG_POSTGRES_CONTAINER:-${POSTGRES_CONTAINER:-${STACK_NAME}_postgres}}"

###############################################################################
# FUNCTIONS
###############################################################################

print_header() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ PostgreSQL Restore                                              │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Database: $POSTGRES_DB"
  echo "│ User:     $POSTGRES_USER"
  echo "│ Time:     $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
}

show_usage() {
  echo "Usage: $(basename "$0") [OPTIONS] <backup-file>"
  echo ""
  echo "Run '$(basename "$0") --help' for more information."
  echo ""
  echo "Available backups:"
  echo ""

  if docker ps --format '{{.Names}}' | grep -q "^${BACKUP_CONTAINER}$"; then
    docker exec "$BACKUP_CONTAINER" find /backups -name "*.sql.gz" -type f 2>/dev/null | sed 's|/backups/||' | sort -r | head -15
  else
    echo "  (backup container not running)"
  fi
  echo ""
  exit 1
}

check_containers() {
  local error=0

  if ! docker ps --format '{{.Names}}' | grep -q "^${BACKUP_CONTAINER}$"; then
    echo "ERROR: Backup container '$BACKUP_CONTAINER' is not running"
    error=1
  fi

  if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    echo "ERROR: PostgreSQL container '$POSTGRES_CONTAINER' is not running"
    error=1
  fi

  if [[ $error -eq 1 ]]; then
    echo ""
    echo "Start the stack:"
    echo "  docker compose up -d"
    echo ""
    exit 1
  fi
}

check_backup_exists() {
  if ! docker exec "$BACKUP_CONTAINER" test -f "/backups/$BACKUP_FILE"; then
    echo "ERROR: Backup file not found: /backups/$BACKUP_FILE"
    echo ""
    echo "Available backups:"
    docker exec "$BACKUP_CONTAINER" find /backups -name "*.sql.gz" -type f 2>/dev/null | sed 's|/backups/||' | sort -r | head -10
    echo ""
    exit 1
  fi
}

confirm_restore() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ WARNING                                                         │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ This will overwrite the database '$POSTGRES_DB'"
  echo "│ Backup: $BACKUP_FILE"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
  read -p "Continue? [y/N]: " -r REPLY
  echo ""

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

run_restore() {
  echo "Starting restore..."
  echo ""

  docker exec "$BACKUP_CONTAINER" cat "/backups/$BACKUP_FILE" | \
    gunzip | \
    docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" --quiet

  echo ""
}

show_result() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Restore Complete                                                │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "Verification:"
  docker exec "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt" 2>/dev/null | head -15
  echo ""
}

###############################################################################
# MAIN
###############################################################################

print_header

if [[ -z "$BACKUP_FILE" ]]; then
  show_usage
fi

check_containers
check_backup_exists
confirm_restore
run_restore
show_result
