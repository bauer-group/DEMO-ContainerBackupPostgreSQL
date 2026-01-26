# PostgreSQL Container Backup Demo

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](docker-compose.yml)

> **Hinweis:** Dies ist ein Demo-Projekt zu Lern- und Demonstrationszwecken. Es erhebt keinen Anspruch auf Vollständigkeit oder Richtigkeit. Für den produktiven Einsatz sind zusätzliche Sicherheitsmaßnahmen und Tests erforderlich.

Automatisierte PostgreSQL-Backups in Docker-Containern mit S3-kompatibler Storage-Anbindung.

## Architektur

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐              │
│   │              │      │              │      │              │              │
│   │  PostgreSQL  │─────▶│    Backup    │─────▶│    MinIO     │              │
│   │              │      │   Service    │      │   (oder S3)  │              │
│   │  Port: 5432  │      │              │      │              │              │
│   └──────────────┘      └──────────────┘      └──────────────┘              │
│         │                     │                     │                       │
│         │                     │ pg_dump             │ mc mirror             │
│         │                     │ @hourly             │ @interval             │
│         │                     ▼                     ▼                       │
│         │               /backups/            s3://bucket/                   │
│         │               ├── daily/           ├── daily/                     │
│         │               ├── weekly/          ├── weekly/                    │
│         │               └── monthly/         └── monthly/                   │
│         │                                                                   │
│         └───────────────────────────────────────────────────────────────────│
│                              Docker Network                                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
git clone https://github.com/bauer-group/DEMO-ContainerBackupPostgreSQL.git
cd DEMO-ContainerBackupPostgreSQL
cp .env.example .env
docker compose up -d
```

**MinIO Console:** http://localhost:9001 (minioadmin / minioadmin123)

## Deployment-Modi

```bash
# Lokale Demo (PostgreSQL + MinIO + Backup)
docker compose up -d

# Externe S3 (nur Backup-Services)
docker compose up -d postgres backup backup-sync
```

## Konfiguration

### S3 Storage

```
┌────────────────────┬─────────────────────────────────────────────────────┐
│ Provider           │ S3_ENDPOINT                                         │
├────────────────────┼─────────────────────────────────────────────────────┤
│ Lokale MinIO       │ http://minio:9000                                   │
│ Externe MinIO      │ https://minio.example.com                           │
│ AWS S3             │ https://s3.amazonaws.com                            │
│ AWS S3 (Region)    │ https://s3.eu-central-1.amazonaws.com               │
│ DigitalOcean       │ https://fra1.digitaloceanspaces.com                 │
│ Wasabi             │ https://s3.eu-central-1.wasabisys.com               │
│ Cloudflare R2      │ https://<account>.r2.cloudflarestorage.com          │
└────────────────────┴─────────────────────────────────────────────────────┘
```

### Backup Schedule

```
┌─────────────────────┬─────────────────────────────────────────────────────┐
│ Expression          │ Beschreibung                                        │
├─────────────────────┼─────────────────────────────────────────────────────┤
│ @hourly             │ Jede Stunde                                         │
│ @daily              │ Täglich 00:00 UTC                                   │
│ 0 3 * * *           │ Täglich 03:00 UTC                                   │
│ */15 * * * *        │ Alle 15 Minuten                                     │
│ 0 */4 * * *         │ Alle 4 Stunden                                      │
└─────────────────────┴─────────────────────────────────────────────────────┘
```

### Retention Policy

```
┌─────────────────┬─────────┬───────────────────────────────────────────────┐
│ Variable        │ Default │ Beschreibung                                  │
├─────────────────┼─────────┼───────────────────────────────────────────────┤
│ KEEP_DAYS       │ 7       │ Tägliche Backups der letzten N Tage           │
│ KEEP_WEEKS      │ 4       │ Wöchentliche Backups der letzten N Wochen     │
│ KEEP_MONTHS     │ 6       │ Monatliche Backups der letzten N Monate       │
└─────────────────┴─────────┴───────────────────────────────────────────────┘

Speicherbedarf (bei 100 MB/Backup): 7 + 4 + 6 = 17 × 100 MB ≈ 1.7 GB
```

## Externe S3 einrichten

> **Vollständige Anleitung:** [docs/EXTERNAL_S3_SETUP.md](docs/EXTERNAL_S3_SETUP.md)

Bei Verwendung externer S3-Provider (AWS, Wasabi, etc.) müssen Bucket, Policy und Object Lock **manuell** konfiguriert werden.

### 1. Bucket mit Object Lock erstellen

**Wichtig:** Object Lock muss bei Bucket-Erstellung aktiviert werden (nachträglich nicht möglich).

```bash
# AWS CLI - Bucket mit Object Lock
aws s3api create-bucket \
  --bucket pg-backups \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1 \
  --object-lock-enabled-for-bucket
```

### 2. Object Lock Retention (WORM)

Governance Mode: 30 Tage Schutz vor Löschen UND Überschreiben.

```bash
# Default Retention für alle neuen Objekte
aws s3api put-object-lock-configuration \
  --bucket pg-backups \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "GOVERNANCE",
        "Days": 30
      }
    }
  }'
```

```
┌─────────────────────┬─────────────────────────────────────────────────────┐
│ Mode                │ Beschreibung                                        │
├─────────────────────┼─────────────────────────────────────────────────────┤
│ GOVERNANCE          │ Admin kann mit speziellem Permission überschreiben  │
│ COMPLIANCE          │ Niemand kann löschen/überschreiben (auch nicht Root)│
└─────────────────────┴─────────────────────────────────────────────────────┘
```

### 3. IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload"
    ],
    "Resource": [
      "arn:aws:s3:::pg-backups",
      "arn:aws:s3:::pg-backups/*"
    ]
  }]
}
```

**Nicht enthalten (kritisch):**

- `s3:BypassGovernanceRetention` - Client kann WORM nicht umgehen

> **Hinweis:** `DeleteObject` ist erlaubt, aber Object Lock verhindert das Löschen während der Retention.
> Die eigentliche Sicherheit kommt vom WORM, nicht von IAM-Restriktionen.

### 4. S3 Lifecycle (Auto-Cleanup nach Retention)

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket pg-backups \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "cleanup-after-retention",
      "Status": "Enabled",
      "Expiration": {"Days": 31},
      "Filter": {"Prefix": ""}
    }]
  }'
```

> **Hinweis:** Lifecycle greift erst NACH Ablauf der Object Lock Retention.
> Bei 30 Tagen WORM + 31 Tagen Lifecycle = Löschung ab Tag 31.

### 5. .env konfigurieren

```bash
S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com
S3_ACCESS_KEY=AKIA...
S3_SECRET_KEY=...
S3_BUCKET=pg-backups
S3_REGION=eu-central-1
```

### 6. Stack starten (ohne MinIO)

```bash
docker compose up -d postgres backup backup-sync
```

### Sicherheitskonzept (Granulares WORM)

Unterschiedliche WORM-Retention pro Backup-Typ:

| Backup-Typ | Lokale Retention | WORM-Schutz | Lifecycle |
|------------|------------------|-------------|-----------|
| last/ | stündlich | kein WORM | 2 Tage |
| daily/ | 7 Tage | 14 Tage | 15 Tage |
| weekly/ | 4 Wochen | 35 Tage | 36 Tage |
| monthly/ | 6 Monate | 185 Tage | 186 Tage |

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Granulare WORM-Retention (per Object)                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Upload mit Retention          S3 Object Lock           Lifecycle      │
│   ┌─────────────────┐          ┌─────────────────┐     ┌───────────┐   │
│   │ last/    → none │─────────▶│ kein Schutz     │────▶│ 2 Tage    │   │
│   │ daily/   → 14d  │─────────▶│ WORM schützt    │────▶│ löscht    │   │
│   │ weekly/  → 35d  │          │ vor Delete und  │     │ nach      │   │
│   │ monthly/ → 185d │          │ Overwrite       │     │ Ablauf    │   │
│   └─────────────────┘          └─────────────────┘     └───────────┘   │
│                                                                         │
│   → WORM-Retention wird beim Upload per Object gesetzt                  │
│   → Monatliche Backups sind 6 Monate geschützt (nicht nur 30 Tage!)    │
│   → Lifecycle löscht automatisch nach WORM-Ablauf                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

Konfigurierbar via `.env`:

```bash
RETENTION_DAILY=14     # WORM-Tage für tägliche Backups
RETENTION_WEEKLY=35    # WORM-Tage für wöchentliche Backups
RETENTION_MONTHLY=185  # WORM-Tage für monatliche Backups
```

## Tools

```bash
./tools/backup-now.sh      # Manuelles Backup erstellen
./tools/backup-status.sh   # Status und Übersicht anzeigen
./tools/sync-now.sh        # Sofort zu S3 synchronisieren
./tools/restore.sh <file>  # Backup wiederherstellen
```

## Wiederherstellung (Restore)

### Schritt 1: Verfügbare Backups anzeigen

```bash
# Übersicht aller Backups (lokal + S3)
./tools/backup-status.sh

# Oder manuell
docker exec ${STACK_NAME}_backup ls -la /backups/daily/
docker exec ${STACK_NAME}_backup ls -la /backups/weekly/
```

### Schritt 2: Backup wiederherstellen

```bash
# Mit restore.sh (empfohlen - interaktive Bestätigung)
./tools/restore.sh daily/demodb-20250126-030000.sql.gz

# Für anderen Stack
./tools/restore.sh -s production daily/proddb-20250126-030000.sql.gz

# Mit anderer Datenbank/User
./tools/restore.sh --db mydb --user myuser daily/mydb-20250126.sql.gz
```

### Schritt 3: Von S3 wiederherstellen (Disaster Recovery)

Falls lokale Backups verloren sind:

```bash
# 1. Backup von S3 herunterladen
docker exec ${STACK_NAME}_backup_sync \
  mc cp "storage/${S3_BUCKET}/daily/demodb-20250126-030000.sql.gz" /backups/daily/

# 2. Restore ausführen
./tools/restore.sh daily/demodb-20250126-030000.sql.gz

# Oder: Alle Backups von S3 synchronisieren
docker exec ${STACK_NAME}_backup_sync mc mirror "storage/${S3_BUCKET}/" /backups/
```

### Manueller Restore (Alternative)

```bash
# Direkt von lokalem Backup
docker exec ${STACK_NAME}_backup cat /backups/daily/demodb-20250126.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME}_postgres psql -U demoapp -d demodb

# Von lokaler Datei
gunzip -c backup.sql.gz | docker exec -i ${STACK_NAME}_postgres psql -U demoapp -d demodb
```

### Verifizierung

```bash
# Tabellen prüfen
docker exec ${STACK_NAME}_postgres psql -U demoapp -d demodb -c "\dt"

# Datensätze zählen
docker exec ${STACK_NAME}_postgres psql -U demoapp -d demodb -c "SELECT COUNT(*) FROM users;"
```

> **Vollständige Restore-Dokumentation:** [docs/RESTORE_GUIDE.md](docs/RESTORE_GUIDE.md)

## Projektstruktur

```
.
├── .env.example           Konfigurationsvorlage
├── docker-compose.yml     Stack-Definition
├── init-scripts/          PostgreSQL Init-Scripts
│   └── 01-demo-data.sql
├── tools/                 CLI-Utilities
│   ├── backup-now.sh
│   ├── backup-status.sh
│   ├── restore.sh
│   └── sync-now.sh
└── docs/
    ├── BACKUP_STRATEGY.md
    ├── EXTERNAL_S3_SETUP.md
    ├── PRODUCTION_GUIDE.md
    └── RESTORE_GUIDE.md
```

## Referenzen

| Komponente | Dokumentation |
|------------|---------------|
| Backup Image | [prodrigestivill/postgres-backup-local](https://github.com/prodrigestivill/docker-postgres-backup-local) |
| MinIO | [min.io/docs](https://min.io/docs/minio/container/index.html) |
| PostgreSQL | [postgresql.org/docs](https://www.postgresql.org/docs/current/backup-dump.html) |
| mc (MinIO Client) | [min.io/docs/minio/linux/reference/minio-mc](https://min.io/docs/minio/linux/reference/minio-mc.html) |

## Lizenz

[MIT](LICENSE) - BAUER GROUP
