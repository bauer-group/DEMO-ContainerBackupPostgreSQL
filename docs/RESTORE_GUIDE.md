# Restore-Anleitung

> **Hinweis:** Dies ist ein Demo-Projekt. Für produktive Umgebungen sind zusätzliche Tests und Validierungen erforderlich.

Vollständige Anleitung zur Wiederherstellung von PostgreSQL-Backups.

## Inhaltsverzeichnis

1. [Übersicht](#übersicht)
2. [Voraussetzungen](#voraussetzungen)
3. [Backup-Quellen](#backup-quellen)
4. [Restore-Szenarien](#restore-szenarien)
5. [Schritt-für-Schritt Anleitung](#schritt-für-schritt-anleitung)
6. [Verifizierung](#verifizierung)
7. [Disaster Recovery](#disaster-recovery)
8. [Fehlerbehebung](#fehlerbehebung)
9. [Checklisten](#checklisten)

---

## Übersicht

### Restore-Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RESTORE WORKFLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐         │
│   │   1.      │    │   2.      │    │   3.      │    │   4.      │         │
│   │  Backup   │───▶│  Backup   │───▶│  Restore  │───▶│ Verifiz.  │         │
│   │  suchen   │    │  prüfen   │    │ ausführen │    │  testen   │         │
│   └───────────┘    └───────────┘    └───────────┘    └───────────┘         │
│        │                │                │                │                 │
│        ▼                ▼                ▼                ▼                 │
│   backup-status    gunzip -t        restore.sh      \dt, SELECT           │
│   mc ls            Größe prüfen     gunzip|psql     COUNT(*)              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Backup-Typen

| Typ | Verzeichnis | Aufbewahrung | Verwendung |
|-----|-------------|--------------|------------|
| Täglich | `/backups/daily/` | 7 Tage | Kurzzeitige Wiederherstellung |
| Wöchentlich | `/backups/weekly/` | 4 Wochen | Mittelzeitige Wiederherstellung |
| Monatlich | `/backups/monthly/` | 6 Monate | Langzeitige Wiederherstellung |

### Dateinamensformat

```
demodb-20250126-030000.sql.gz
│      │        │       │
│      │        │       └── Komprimierung (gzip)
│      │        └── Uhrzeit: 03:00:00 UTC
│      └── Datum: 26.01.2025
└── Datenbankname
```

---

## Voraussetzungen

### Container-Status prüfen

```bash
# Alle Container müssen laufen
docker compose ps

# Oder spezifisch prüfen
docker ps --filter "name=${STACK_NAME:-demo}_postgres"
docker ps --filter "name=${STACK_NAME:-demo}_backup"
docker ps --filter "name=${STACK_NAME:-demo}_backup_sync"
```

### Erforderliche Container

| Container | Zweck | Erforderlich für |
|-----------|-------|------------------|
| `*_postgres` | Ziel-Datenbank | Alle Restores |
| `*_backup` | Lokale Backups | Restore von lokal |
| `*_backup_sync` | S3-Zugriff | Restore von S3 |

### Berechtigungen

Der Restore-User muss:
- Verbindung zur Datenbank herstellen können
- CREATE, DROP, INSERT Rechte haben
- Für vollständigen Restore: Superuser oder Owner sein

---

## Backup-Quellen

### Lokale Backups

```bash
# Übersicht aller lokalen Backups
./tools/backup-status.sh

# Manuell: Daily Backups
docker exec ${STACK_NAME:-demo}_backup ls -lh /backups/daily/

# Manuell: Weekly Backups
docker exec ${STACK_NAME:-demo}_backup ls -lh /backups/weekly/

# Manuell: Monthly Backups
docker exec ${STACK_NAME:-demo}_backup ls -lh /backups/monthly/

# Alle Backups mit Größe
docker exec ${STACK_NAME:-demo}_backup \
  find /backups -name "*.sql.gz" -exec ls -lh {} \; | sort -k9
```

### S3/MinIO Backups

```bash
# S3-Backups auflisten
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc ls "storage/${S3_BUCKET:-pg-backups}/" --recursive

# Mit Präfix (Multi-Tenant)
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc ls "storage/${S3_BUCKET:-pg-backups}/${S3_PREFIX}/" --recursive

# Dateigröße und Datum anzeigen
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc ls "storage/${S3_BUCKET:-pg-backups}/" --recursive --summarize
```

### Backup von S3 herunterladen

```bash
# Einzelne Datei
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc cp "storage/${S3_BUCKET}/daily/demodb-20250126-030000.sql.gz" /backups/daily/

# Alle fehlenden Dateien synchronisieren
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc mirror "storage/${S3_BUCKET}/" /backups/

# Mit Präfix
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc mirror "storage/${S3_BUCKET}/${S3_PREFIX}/" /backups/
```

---

## Restore-Szenarien

### Szenario 1: Standard-Restore (empfohlen)

**Situation**: Datenbank ist beschädigt oder Daten wurden versehentlich gelöscht.

```bash
# 1. Verfügbare Backups anzeigen
./tools/backup-status.sh

# 2. Restore mit interaktiver Bestätigung
./tools/restore.sh daily/demodb-20250126-030000.sql.gz

# 3. Verifizieren
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "\dt"
```

### Szenario 2: Restore in andere Datenbank

**Situation**: Backup in eine Test-/Staging-Datenbank einspielen.

```bash
# 1. Neue Datenbank erstellen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -c "CREATE DATABASE testdb;"

# 2. Backup in neue Datenbank einspielen
docker exec ${STACK_NAME:-demo}_backup \
  cat /backups/daily/demodb-20250126-030000.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d testdb

# 3. Verifizieren
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d testdb -c "\dt"
```

### Szenario 3: Restore von S3 (lokale Backups verloren)

**Situation**: Lokaler Storage ausgefallen, nur S3-Backups verfügbar.

```bash
# 1. Prüfen welche S3-Backups verfügbar sind
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc ls "storage/${S3_BUCKET}/" --recursive

# 2. Benötigtes Backup herunterladen
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc cp "storage/${S3_BUCKET}/daily/demodb-20250126-030000.sql.gz" /backups/daily/

# 3. Standard-Restore ausführen
./tools/restore.sh daily/demodb-20250126-030000.sql.gz
```

### Szenario 4: Restore auf neuem Server (Disaster Recovery)

**Situation**: Kompletter Server-Ausfall, Neuaufbau erforderlich.

```bash
# 1. Repository klonen
git clone https://github.com/bauer-group/DEMO-ContainerBackupPostgreSQL.git
cd DEMO-ContainerBackupPostgreSQL

# 2. Konfiguration erstellen
cp .env.example .env
# .env mit S3-Credentials bearbeiten!

# 3. Stack starten
docker compose up -d postgres backup backup-sync

# 4. Warten bis Container healthy sind
docker compose ps
# Warten bis alle "healthy" zeigen

# 5. Backups von S3 synchronisieren
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc mirror "storage/${S3_BUCKET}/" /backups/

# 6. Neuestes Backup identifizieren
docker exec ${STACK_NAME:-demo}_backup \
  ls -lt /backups/daily/ | head -5

# 7. Restore ausführen
./tools/restore.sh daily/demodb-20250126-030000.sql.gz
```

### Szenario 5: Partieller Restore (einzelne Tabellen)

**Situation**: Nur bestimmte Tabellen sollen wiederhergestellt werden.

```bash
# 1. Backup entpacken (temporär)
docker exec ${STACK_NAME:-demo}_backup \
  gunzip -k /backups/daily/demodb-20250126-030000.sql.gz

# 2. SQL-Inhalt prüfen (Tabellen finden)
docker exec ${STACK_NAME:-demo}_backup \
  grep -E "^CREATE TABLE|^COPY" /backups/daily/demodb-20250126-030000.sql | head -20

# 3. Spezifische Tabelle extrahieren und einspielen
docker exec ${STACK_NAME:-demo}_backup \
  cat /backups/daily/demodb-20250126-030000.sql | \
  grep -A1000 "COPY users" | \
  grep -B1000 "\\\\." | \
  docker exec -i ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb}

# 4. Temporäre Datei löschen
docker exec ${STACK_NAME:-demo}_backup \
  rm /backups/daily/demodb-20250126-030000.sql
```

> **Hinweis**: Für komplexere partielle Restores empfiehlt sich `pg_restore` mit einem Custom-Format Backup.

---

## Schritt-für-Schritt Anleitung

### Methode 1: Mit restore.sh (empfohlen)

```bash
# Einfachster Fall
./tools/restore.sh daily/demodb-20250126-030000.sql.gz
```

Das Skript führt automatisch durch:
1. Container-Verfügbarkeit prüfen
2. Backup-Datei prüfen
3. Interaktive Bestätigung anfordern
4. Restore ausführen
5. Ergebnis verifizieren

**Optionen:**

```bash
# Mit spezifischem Stack
./tools/restore.sh -s production daily/proddb-20250126.sql.gz

# Mit anderer Datenbank
./tools/restore.sh --db testdb daily/demodb-20250126.sql.gz

# Mit anderem User
./tools/restore.sh --user postgres daily/demodb-20250126.sql.gz

# Alle Optionen
./tools/restore.sh -s production -d testdb -u admin daily/demodb-20250126.sql.gz
```

### Methode 2: Manueller Restore

```bash
# Variante A: Pipe durch Container
docker exec ${STACK_NAME:-demo}_backup \
  cat /backups/daily/demodb-20250126-030000.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb}

# Variante B: Mit lokaler Datei
# 1. Backup herunterladen
docker cp ${STACK_NAME:-demo}_backup:/backups/daily/demodb-20250126-030000.sql.gz ./

# 2. Lokal entpacken und einspielen
gunzip -c demodb-20250126-030000.sql.gz | \
  docker exec -i ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb}

# 3. Lokale Datei löschen
rm demodb-20250126-030000.sql.gz
```

### Methode 3: Restore mit Fehlerbehandlung

```bash
# Mit ON_ERROR_STOP (bei Fehlern abbrechen)
docker exec ${STACK_NAME:-demo}_backup \
  cat /backups/daily/demodb-20250126-030000.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} \
  -v ON_ERROR_STOP=1

# Mit Verbose-Output
docker exec ${STACK_NAME:-demo}_backup \
  cat /backups/daily/demodb-20250126-030000.sql.gz | \
  gunzip | \
  docker exec -i ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} \
  -v ON_ERROR_STOP=1 --echo-errors
```

---

## Verifizierung

### Grundlegende Prüfungen

```bash
# 1. Tabellen auflisten
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "\dt"

# 2. Datensätze zählen (Beispiel für users-Tabelle)
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} \
  -c "SELECT COUNT(*) FROM users;"

# 3. Schema prüfen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} \
  -c "\d+ users"
```

### Erweiterte Prüfungen

```bash
# Alle Tabellen mit Zeilenanzahl
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "
SELECT
  schemaname,
  relname as table,
  n_live_tup as row_count
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;"

# Datenbankgröße
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "
SELECT pg_size_pretty(pg_database_size('${POSTGRES_DB:-demodb}'));"

# Letzte Änderungen prüfen (falls timestamp-Spalte vorhanden)
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "
SELECT MAX(updated_at) FROM users;"
```

### Integritätsprüfung

```bash
# Foreign Key Constraints prüfen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "
SELECT conname, conrelid::regclass, confrelid::regclass
FROM pg_constraint
WHERE contype = 'f';"

# Index-Status prüfen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "
SELECT indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes;"
```

---

## Disaster Recovery

### Checkliste für Disaster Recovery

```
□ S3-Credentials verfügbar und funktionsfähig
□ Zugriff auf S3-Bucket verifiziert
□ Neuester Server/VM bereitgestellt
□ Docker und Docker Compose installiert
□ Repository geklont
□ .env konfiguriert
□ Stack gestartet
□ Backups von S3 synchronisiert
□ Restore durchgeführt
□ Daten verifiziert
□ Anwendung getestet
```

### Recovery Time Objective (RTO)

| Phase | Geschätzte Dauer | Beschreibung |
|-------|-----------------|--------------|
| Infrastruktur | 10-30 Min | Server/VM bereitstellen |
| Setup | 5-10 Min | Docker, Clone, Konfiguration |
| S3 Sync | Variabel | Abhängig von Backup-Größe |
| Restore | 1-5 Min/GB | Abhängig von Datenbankgröße |
| Verifizierung | 10-15 Min | Tests durchführen |
| **Gesamt** | **30-60+ Min** | Je nach Datenmenge |

### S3-Download-Zeiten (Richtwerte)

| Backup-Größe | ~100 Mbit/s | ~1 Gbit/s |
|--------------|-------------|-----------|
| 100 MB | ~10 Sek | ~1 Sek |
| 1 GB | ~2 Min | ~10 Sek |
| 10 GB | ~15 Min | ~2 Min |
| 100 GB | ~2,5 Std | ~15 Min |

---

## Fehlerbehebung

### Problem: Container nicht erreichbar

```bash
# Status prüfen
docker compose ps

# Container starten
docker compose up -d

# Logs prüfen
docker compose logs postgres
docker compose logs backup
```

### Problem: Backup-Datei nicht gefunden

```bash
# Verfügbare Backups auflisten
docker exec ${STACK_NAME:-demo}_backup \
  find /backups -name "*.sql.gz" -type f | sort

# Prüfen ob Datei existiert
docker exec ${STACK_NAME:-demo}_backup \
  ls -la /backups/daily/demodb-20250126-030000.sql.gz

# Von S3 herunterladen falls nötig
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc cp "storage/${S3_BUCKET}/daily/demodb-20250126-030000.sql.gz" /backups/daily/
```

### Problem: Backup-Datei beschädigt

```bash
# Integrität prüfen
docker exec ${STACK_NAME:-demo}_backup \
  gunzip -t /backups/daily/demodb-20250126-030000.sql.gz

# Bei Fehler: Backup von S3 neu herunterladen
docker exec ${STACK_NAME:-demo}_backup_sync \
  mc cp --overwrite \
  "storage/${S3_BUCKET}/daily/demodb-20250126-030000.sql.gz" /backups/daily/
```

### Problem: Berechtigungsfehler beim Restore

```bash
# Als Superuser verbinden
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -d ${POSTGRES_DB:-demodb}

# Berechtigungen prüfen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -c "\du ${POSTGRES_USER:-demoapp}"

# Berechtigungen erteilen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB:-demodb} TO ${POSTGRES_USER:-demoapp};"
```

### Problem: Datenbank existiert nicht

```bash
# Datenbank erstellen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -c "CREATE DATABASE ${POSTGRES_DB:-demodb} OWNER ${POSTGRES_USER:-demoapp};"

# Dann Restore wiederholen
./tools/restore.sh daily/demodb-20250126-030000.sql.gz
```

### Problem: Bestehende Objekte verhindern Restore

```bash
# Option A: Datenbank droppen und neu erstellen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -c "DROP DATABASE IF EXISTS ${POSTGRES_DB:-demodb};"
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -c "CREATE DATABASE ${POSTGRES_DB:-demodb} OWNER ${POSTGRES_USER:-demoapp};"

# Option B: Alle Tabellen droppen (gefährlich!)
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U ${POSTGRES_USER:-demoapp} -d ${POSTGRES_DB:-demodb} -c "
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO ${POSTGRES_USER:-demoapp};"

# Dann Restore wiederholen
./tools/restore.sh daily/demodb-20250126-030000.sql.gz
```

### Problem: Restore dauert zu lange

```bash
# Fortschritt überwachen
docker exec ${STACK_NAME:-demo}_postgres \
  psql -U postgres -c "
SELECT
  pid,
  now() - pg_stat_activity.query_start AS duration,
  query
FROM pg_stat_activity
WHERE state != 'idle'
AND query NOT LIKE '%pg_stat_activity%';"

# Bei sehr großen Datenbanken: pg_restore mit Custom-Format
# (erfordert Backup im Custom-Format)
```

---

## Checklisten

### Vor dem Restore

```
□ Backup identifiziert (Datum, Typ)
□ Backup-Datei existiert (lokal oder S3)
□ Backup-Integrität geprüft (gunzip -t)
□ Ziel-Container läuft
□ Ausreichend Speicherplatz vorhanden
□ Aktuelles Backup erstellt (falls Daten vorhanden)
□ Betroffene Anwendungen informiert/gestoppt
```

### Nach dem Restore

```
□ Tabellen vorhanden (\dt)
□ Datensätze korrekt (COUNT)
□ Berechtigungen korrekt
□ Fremdschlüssel intakt
□ Anwendung funktioniert
□ Anwendungen wieder gestartet
□ Restore dokumentiert
```

### Restore-Protokoll (Vorlage)

```
Datum:          ____________________
Durchgeführt:   ____________________
Backup-Datei:   ____________________
Backup-Datum:   ____________________
Ziel-Datenbank: ____________________
Grund:          ____________________

Prüfungen:
□ Tabellen vorhanden
□ Datensätze korrekt
□ Anwendung funktioniert

Anmerkungen:
___________________________________
___________________________________
```

---

## Weiterführende Dokumentation

- [BACKUP_STRATEGY.md](BACKUP_STRATEGY.md) - Backup-Strategie und Architektur
- [EXTERNAL_S3_SETUP.md](EXTERNAL_S3_SETUP.md) - S3-Konfiguration für Produktion
- [PRODUCTION_GUIDE.md](PRODUCTION_GUIDE.md) - Produktions-Deployment
