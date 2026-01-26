#!/usr/bin/env bash
###############################################################################
#
#   sync-now.sh - Sofortige S3 Synchronisation mit WORM-Retention
#
#   Usage:
#     ./sync-now.sh                         # Auto-detect from .env
#     ./sync-now.sh -c myapp_sync           # Specific container
#     ./sync-now.sh -b mybucket             # Specific bucket
#     ./sync-now.sh -p production           # With S3 prefix
#
#   Environment:
#     SYNC_CONTAINER     Sync container name (default: ${STACK_NAME}_backup_sync)
#     STACK_NAME         Stack prefix (default: demo)
#     S3_BUCKET          S3 bucket name (default: pg-backups)
#     S3_PREFIX          S3 path prefix (default: none)
#     RETENTION_DAILY    WORM retention for daily backups (default: 14)
#     RETENTION_WEEKLY   WORM retention for weekly backups (default: 35)
#     RETENTION_MONTHLY  WORM retention for monthly backups (default: 185)
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
  echo "Trigger immediate S3 synchronization"
  echo ""
  echo "Options:"
  echo "  -s, --stack NAME       Stack prefix name"
  echo "  -c, --container NAME   Sync container name"
  echo "  -b, --bucket NAME      S3 bucket name"
  echo "  -p, --prefix NAME      S3 path prefix"
  echo "  -h, --help             Show this help"
  echo ""
  echo "Environment variables:"
  echo "  STACK_NAME             Stack prefix (default: demo)"
  echo "  SYNC_CONTAINER         Sync container name"
  echo "  S3_BUCKET              S3 bucket name (default: pg-backups)"
  echo "  S3_PREFIX              S3 path prefix (default: none)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0")"
  echo "  $(basename "$0") -s production"
  echo "  $(basename "$0") -p production -b shared-backups"
}

ARG_STACK=""
ARG_CONTAINER=""
ARG_BUCKET=""
ARG_PREFIX=""

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

# Resolve stack name first: CLI > ENV > default
STACK_NAME="${ARG_STACK:-${STACK_NAME:-demo}}"

# Resolve: CLI > ENV > default (using resolved STACK_NAME)
CONTAINER="${ARG_CONTAINER:-${SYNC_CONTAINER:-${STACK_NAME}_backup_sync}}"
S3_BUCKET="${ARG_BUCKET:-${S3_BUCKET:-pg-backups}}"
S3_PREFIX="${ARG_PREFIX:-${S3_PREFIX:-}}"

# WORM Retention defaults
RETENTION_DAILY="${RETENTION_DAILY:-14}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-35}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-185}"

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
  echo "│ S3 Sync (with WORM Retention)                                   │"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ Container: $CONTAINER"
  echo "│ Bucket:    $S3_BUCKET"
  echo "│ Prefix:    ${S3_PREFIX:-<none>}"
  echo "│ Path:      $S3_PATH"
  echo "│ Time:      $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
  echo "├─────────────────────────────────────────────────────────────────┤"
  echo "│ WORM Retention:                                                 │"
  echo "│   last/    → none (überschreibbar)"
  echo "│   daily/   → ${RETENTION_DAILY} days"
  echo "│   weekly/  → ${RETENTION_WEEKLY} days"
  echo "│   monthly/ → ${RETENTION_MONTHLY} days"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
}

check_container() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: Container '$CONTAINER' is not running"
    echo ""
    echo "Start the stack:"
    echo "  docker compose up -d"
    echo ""
    exit 1
  fi
}

run_sync() {
  echo "Starting sync..."
  echo ""
  echo "Retention: last=none, daily=${RETENTION_DAILY}d, weekly=${RETENTION_WEEKLY}d, monthly=${RETENTION_MONTHLY}d"
  echo ""

  # Sync each prefix with appropriate retention (last without WORM)
  for prefix in last daily weekly monthly; do
    # Get retention for this prefix (empty = no WORM)
    case "$prefix" in
      last)    retention="" ;;
      daily)   retention="${RETENTION_DAILY}d" ;;
      weekly)  retention="${RETENTION_WEEKLY}d" ;;
      monthly) retention="${RETENTION_MONTHLY}d" ;;
    esac

    if [[ -n "$retention" ]]; then
      echo "Syncing ${prefix}/ (WORM: ${retention})..."
    else
      echo "Syncing ${prefix}/ (no WORM)..."
    fi

    # Upload new files with or without retention
    docker exec "$CONTAINER" sh -c "
      for local_file in /backups/${prefix}/*.sql.gz; do
        # Skip if no files match
        [ -e \"\$local_file\" ] || continue

        filename=\$(basename \"\$local_file\")

        # Skip symlinks (latest)
        case \"\$filename\" in
          *-latest.sql.gz) continue ;;
        esac

        # Check if file exists on S3
        if mc stat \"${S3_PATH}${prefix}/\${filename}\" >/dev/null 2>&1; then
          continue
        fi

        # Upload with or without WORM retention
        echo \"  Uploading: ${prefix}/\${filename}\"
        if [ -n \"${retention}\" ]; then
          mc cp \
            --retention-mode governance \
            --retention-duration \"${retention}\" \
            \"\$local_file\" \"${S3_PATH}${prefix}/\" 2>/dev/null || \
          mc cp \"\$local_file\" \"${S3_PATH}${prefix}/\" 2>/dev/null
        else
          mc cp \"\$local_file\" \"${S3_PATH}${prefix}/\" 2>/dev/null
        fi
      done
    "
  done
  echo ""
}

show_result() {
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ Sync Complete                                                   │"
  echo "└─────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "S3 contents:"
  docker exec "$CONTAINER" mc ls "$S3_PATH" --recursive 2>/dev/null | tail -10
  echo ""
}

###############################################################################
# MAIN
###############################################################################

print_header
check_container
run_sync
show_result
