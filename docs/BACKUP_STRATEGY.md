# Backup-Strategie

Dieses Dokument erklärt die Backup-Strategie, Sicherheitsarchitektur und Restore-Prozesse.

## Übersicht

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BACKUP ARCHITEKTUR                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PostgreSQL ─────► pg_dump ─────► Lokaler Storage ─────► S3/MinIO          │
│                      (Cron)         (Docker Volume)        (mc mirror)      │
│                                                                             │
│   Scheduling:        @hourly        Retention:              Sync:           │
│   - @hourly          @daily         - 7 Tage täglich        - Inkrementell  │
│   - @daily           @weekly        - 4 Wochen wöchentl.    - Nur neue      │
│   - Cron-Expression  @monthly       - 6 Monate monatlich      Dateien       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Sicherheitskonzept (WORM)

### Granulares WORM-Konzept

Das Problem mit einheitlicher Retention: Unterschiedliche Backup-Typen benötigen unterschiedliche Aufbewahrungszeiten.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Granulare WORM-Retention (per Object)                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Lokale Retention          S3 WORM Retention         S3 Lifecycle          │
│   ┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐     │
│   │ daily/   7d     │─────▶│ daily/   14d    │─────▶│ daily/   15d    │     │
│   │ weekly/  28d    │─────▶│ weekly/  35d    │─────▶│ weekly/  36d    │     │
│   │ monthly/ 180d   │─────▶│ monthly/ 185d   │─────▶│ monthly/ 186d   │     │
│   └─────────────────┘      └─────────────────┘      └─────────────────┘     │
│                                   │                        │                │
│                                   │                        │                │
│                                   ▼                        ▼                │
│                            WORM schützt vor         Lifecycle löscht        │
│                            Delete/Overwrite         nach WORM-Ablauf        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementierung

Die WORM-Retention wird **per Object beim Upload** gesetzt:

```bash
# Beispiel: Daily Backup mit 14 Tagen WORM
mc cp \
  --retention-mode governance \
  --retention-duration 14d \
  backup.sql.gz storage/bucket/daily/

# Beispiel: Monthly Backup mit 185 Tagen WORM
mc cp \
  --retention-mode governance \
  --retention-duration 185d \
  backup.sql.gz storage/bucket/monthly/
```

### Konfiguration (Umgebungsvariablen)

| Variable | Default | Beschreibung |
|----------|---------|--------------|
| `RETENTION_DAILY` | 14 | WORM-Tage für tägliche Backups |
| `RETENTION_WEEKLY` | 35 | WORM-Tage für wöchentliche Backups |
| `RETENTION_MONTHLY` | 185 | WORM-Tage für monatliche Backups |

### Warum WORM statt IAM-Restriktionen?

| Ansatz | Problem |
|--------|---------|
| `s3:DeleteObject` entfernen | Client kann trotzdem mit `PutObject` überschreiben |
| Nur `PutObject` erlauben | Bei Versioning: Upload erstellt neue Version, Original bleibt |
| **Object Lock (WORM)** | ✅ Blockiert Delete UND Overwrite auf Objektebene |

### Konfiguration

1. **Bucket mit Object Lock erstellen** (muss bei Erstellung aktiviert werden!)
2. **Per-Object Retention beim Upload** (GOVERNANCE Mode)
3. **IAM**: OHNE `s3:BypassGovernanceRetention`
4. **Lifecycle Rules pro Prefix** (löscht nach WORM-Ablauf)

> **Vollständige Anleitung**: [EXTERNAL_S3_SETUP.md](EXTERNAL_S3_SETUP.md)

---

## Komponenten

### 1. Backup Service (`prodrigestivill/postgres-backup-local`)

Bewährtes Docker-Image für PostgreSQL-Backups:

- **pg_dump**: Standard PostgreSQL Backup-Tool
- **Kompression**: gzip Level 6 (konfigurierbar via `BACKUP_EXTRA_OPTS`)
- **Rotation**: Automatische Retention-Policies (daily/weekly/monthly)
- **Healthcheck**: HTTP-Endpoint für Monitoring

### 2. S3 Sync Service (MinIO Client)

Synchronisiert lokale Backups zu S3-kompatiblem Storage:

- **mc mirror**: Inkrementelle Synchronisation (nur neue Dateien)
- **Kein --overwrite**: Verhindert ungewollte Duplikate bei Object Lock
- **Interval**: Konfigurierbar (Standard: 1 Stunde, Demo: 5 Minuten)

---

## Backup-Formate

### Dateinamenskonvention

```
demoapp-20250126-120000.sql.gz
│       │        │
│       │        └── Uhrzeit (HHMMSS)
│       └── Datum (YYYYMMDD)
└── Datenbankname
```

### Verzeichnisstruktur

```
/backups/
├── daily/                    # Tägliche Backups
│   ├── demoapp-20250126-030000.sql.gz
│   ├── demoapp-20250125-030000.sql.gz
│   └── ...
├── weekly/                   # Wöchentliche Backups (Sonntag)
│   ├── demoapp-20250119-030000.sql.gz
│   └── ...
└── monthly/                  # Monatliche Backups (1. des Monats)
    ├── demoapp-20250101-030000.sql.gz
    └── ...
```

---

## Retention-Policies

| Typ | Aufbewahrung | Beispiel |
|-----|--------------|----------|
| Täglich | 7 Tage | Letzte Woche |
| Wöchentlich | 4 Wochen | Letzter Monat |
| Monatlich | 6 Monate | Letztes Halbjahr |

### Speicherbedarf-Kalkulation

Annahme: 100 MB komprimierte Backup-Größe

```
Lokal:
  Täglich:     7 × 100 MB  =  700 MB
  Wöchentlich: 4 × 100 MB  =  400 MB
  Monatlich:   6 × 100 MB  =  600 MB
  ────────────────────────────────
  Gesamt:                   1.700 MB (~1,7 GB)

S3 (mit 30 Tagen WORM):
  Alle Backups 30 Tage geschützt, danach Lifecycle-Löschung
```

---

## Scheduling

### Cron-Expressions

| Expression | Bedeutung |
|------------|-----------|
| `@hourly` | Jede Stunde |
| `@daily` | Täglich 00:00 |
| `0 3 * * *` | Täglich 03:00 |
| `*/15 * * * *` | Alle 15 Minuten |
| `0 */6 * * *` | Alle 6 Stunden |

### Empfehlungen

| Umgebung | Schedule | Begründung |
|----------|----------|------------|
| Entwicklung | `@hourly` | Häufige Änderungen |
| Staging | `0 3 * * *` | Nächtlich |
| Produktion | `0 */4 * * *` | Alle 4 Stunden |

---

## Restore-Prozess

### Übersicht

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RESTORE WORKFLOW                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   1. Backup identifizieren                                                  │
│      └── ./tools/backup-status.sh                                           │
│          └── Zeigt lokale + S3 Backups                                      │
│                                                                             │
│   2. Optional: Von S3 herunterladen                                         │
│      └── docker exec SYNC_CONTAINER mc cp storage/BUCKET/... /backups/      │
│                                                                             │
│   3. Restore ausführen                                                      │
│      └── ./tools/restore.sh daily/dbname-20250126-030000.sql.gz             │
│          └── Interaktive Bestätigung                                        │
│          └── Automatische Verifikation                                      │
│                                                                             │
│   4. Verifizieren                                                           │
│      └── Anwendung testen                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Schritt 1: Verfügbare Backups anzeigen

```bash
# Status-Übersicht (empfohlen)
./tools/backup-status.sh

# Oder manuell - Lokale Backups
docker exec ${STACK_NAME}_backup ls -la /backups/daily/
docker exec ${STACK_NAME}_backup ls -la /backups/weekly/
docker exec ${STACK_NAME}_backup ls -la /backups/monthly/

# S3 Backups
docker exec ${STACK_NAME}_backup_sync mc ls storage/${S3_BUCKET}/ --recursive
```

### Schritt 2: Backup von S3 holen (falls nötig)

Wenn das gewünschte Backup nur noch auf S3 existiert:

```bash
# Einzelne Datei von S3 ins lokale Backup-Verzeichnis kopieren
docker exec ${STACK_NAME}_backup_sync \
  mc cp "storage/${S3_BUCKET}/daily/demoapp-20250120-030000.sql.gz" /backups/daily/

# Oder: Alle fehlenden Dateien synchronisieren
docker exec ${STACK_NAME}_backup_sync \
  mc mirror "storage/${S3_BUCKET}/" /backups/
```

### Schritt 3: Restore mit Tool (empfohlen)

```bash
# Interaktiver Restore mit Bestätigung
./tools/restore.sh daily/demoapp-20250126-030000.sql.gz

# Mit spezifischem Stack
./tools/restore.sh -s production daily/proddb-20250126-030000.sql.gz

# Mit spezifischer Datenbank
./tools/restore.sh --db otherdb --user otheruser daily/otherdb-20250126.sql.gz
```

**Das Tool führt automatisch durch:**
1. Prüfung ob Container laufen
2. Prüfung ob Backup-Datei existiert
3. Interaktive Bestätigung (WARNING)
4. Restore via `gunzip | psql`
5. Verifikation mit `\dt` (Tabellenliste)

### Schritt 3 (Alternative): Manueller Restore

```bash
# Backup dekomprimieren und direkt einspielen
docker exec ${STACK_NAME}_backup cat /backups/daily/demoapp-20250126-030000.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME}_postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

# Oder mit lokaler Datei
gunzip -c backup.sql.gz | docker exec -i ${STACK_NAME}_postgres psql -U postgres -d demoapp
```

### Schritt 4: Verifizieren

```bash
# Tabellen prüfen
docker exec ${STACK_NAME}_postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "\dt"

# Datensätze zählen
docker exec ${STACK_NAME}_postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} \
  -c "SELECT COUNT(*) FROM users;"

# Anwendung testen
curl http://localhost:8080/api/health
```

---

## Disaster Recovery Szenarien

### Szenario 1: Lokale Backups verloren

```bash
# 1. S3-Backups in neues Volume synchronisieren
docker exec ${STACK_NAME}_backup_sync mc mirror "storage/${S3_BUCKET}/" /backups/

# 2. Gewünschtes Backup wiederherstellen
./tools/restore.sh daily/demoapp-20250126-030000.sql.gz
```

### Szenario 2: Kompletter Server-Ausfall

```bash
# 1. Neuen Server aufsetzen
git clone https://github.com/bauer-group/DEMO-ContainerBackupPostgreSQL.git
cd DEMO-ContainerBackupPostgreSQL
cp .env.example .env
# .env mit S3-Credentials konfigurieren

# 2. Stack starten
docker compose up -d

# 3. Backups von S3 synchronisieren
docker exec ${STACK_NAME}_backup_sync mc mirror "storage/${S3_BUCKET}/" /backups/

# 4. Neuestes Backup wiederherstellen
./tools/restore.sh daily/demoapp-20250126-030000.sql.gz
```

### Szenario 3: Point-in-Time Recovery (PITR)

> **Hinweis:** pg_dump erstellt nur Vollbackups. Für echtes PITR mit WAL-Archivierung ist eine erweiterte Konfiguration erforderlich.

Verfügbare Wiederherstellungspunkte:
- **Stündlich**: Letzte 24 Backups (bei @hourly)
- **Täglich**: Letzte 7 Tage
- **Wöchentlich**: Letzte 4 Wochen
- **Monatlich**: Letzte 6 Monate

---

## Tools-Referenz

| Tool | Beschreibung | Beispiel |
|------|--------------|----------|
| `backup-now.sh` | Sofortiges Backup erstellen | `./tools/backup-now.sh -s production` |
| `backup-status.sh` | Status und Übersicht | `./tools/backup-status.sh` |
| `sync-now.sh` | Sofort zu S3 synchronisieren | `./tools/sync-now.sh` |
| `restore.sh` | Backup wiederherstellen | `./tools/restore.sh daily/db-2025.sql.gz` |

### Gemeinsame Optionen

Alle Tools unterstützen:
- `-s, --stack NAME` - Stack-Prefix (default: aus .env oder "demo")
- `-h, --help` - Hilfe anzeigen

Spezifische Optionen:
- `backup-now.sh`: `-c, --container` - Backup-Container
- `sync-now.sh`: `-c, --container`, `-b, --bucket` - Sync-Container und Bucket
- `restore.sh`: `-u, --user`, `-d, --db`, `-b, --backup`, `-p, --postgres`

---

## Monitoring

### Healthchecks

Der Backup-Service bietet einen HTTP-Healthcheck:

```bash
# Lokaler Test
curl http://localhost:8080/

# Im Container
docker exec ${STACK_NAME}_backup wget -q -O - http://localhost:8080/
```

### Status-Übersicht

```bash
./tools/backup-status.sh
```

Zeigt:
- Container-Status
- Lokale Backups (daily/weekly/monthly)
- S3-Backups
- Letzte Backup-Logs

### Integration mit Monitoring

```yaml
# Beispiel: Uptime Kuma / Healthchecks.io
environment:
  HEALTHCHECK_URL: https://hc-ping.com/your-uuid-here
```

---

## Best Practices

### 1. 3-2-1 Regel

- **3** Kopien der Daten (Original + Lokal + S3)
- **2** verschiedene Medien (Docker Volume + S3)
- **1** Off-Site Kopie (S3 in anderer Region)

### 2. Regelmäßige Restore-Tests

```bash
# Monatlicher Test-Restore auf Staging
./tools/restore.sh -s staging monthly/demoapp-20250101-030000.sql.gz

# Dokumentieren: Datum, Backup-Datei, Ergebnis
```

### 3. WORM aktivieren

- Object Lock bei Bucket-Erstellung aktivieren
- GOVERNANCE Mode für normale Backups
- COMPLIANCE Mode für regulatorische Anforderungen

### 4. Verschlüsselung

- **S3**: Server-Side Encryption (SSE-S3 oder SSE-KMS)
- **Optional**: GPG-Verschlüsselung vor Upload

### 5. Monitoring & Alerting

- Backup-Erfolg überwachen
- Speicherplatz überwachen (lokal + S3)
- Alerting bei:
  - Fehlgeschlagenen Backups
  - Sync-Fehlern
  - Ungewöhnlichen Backup-Größen

---

## Fehlerbehebung

### Backup läuft nicht

```bash
# Container-Status prüfen
docker ps -a | grep backup

# Logs prüfen
docker logs ${STACK_NAME}_backup --tail 50

# Manuell testen
./tools/backup-now.sh
```

### Sync schlägt fehl

```bash
# S3-Verbindung testen
docker exec ${STACK_NAME}_backup_sync mc ls storage/

# Credentials prüfen
docker exec ${STACK_NAME}_backup_sync env | grep S3

# Manuell synchronisieren
./tools/sync-now.sh
```

### Restore schlägt fehl

```bash
# Backup-Datei prüfen
docker exec ${STACK_NAME}_backup ls -la /backups/daily/

# Datei-Integrität testen
docker exec ${STACK_NAME}_backup gunzip -t /backups/daily/demoapp-20250126.sql.gz

# Manuell mit Verbose
docker exec ${STACK_NAME}_backup cat /backups/daily/demoapp-20250126.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME}_postgres psql -U postgres -d demoapp -v ON_ERROR_STOP=1
```
