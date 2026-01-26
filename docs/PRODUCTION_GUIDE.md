# Produktions-Anleitung

Anleitung für den Einsatz in Produktionsumgebungen.

## Voraussetzungen

- Docker 24+ mit Compose V2
- Externe PostgreSQL-Datenbank (optional)
- S3-kompatibler Storage (MinIO, AWS S3, etc.)
- Netzwerkzugang zwischen Services

## Konfiguration

### 1. Sichere Credentials

```bash
# PostgreSQL Passwort generieren
openssl rand -base64 24

# MinIO Secret generieren
openssl rand -base64 32
```

### 2. .env für Produktion

```env
# Stack
STACK_NAME=pgbackup_prod
TZ=Etc/UTC

# PostgreSQL (extern)
POSTGRES_HOST=db.example.com
POSTGRES_PORT=5432
POSTGRES_USER=backup_user
POSTGRES_PASSWORD=<generiertes-passwort>
POSTGRES_DB=production_db

# MinIO (extern)
MINIO_ACCESS_KEY=<access-key>
MINIO_SECRET_KEY=<secret-key>

# Backup
BACKUP_SCHEDULE=0 */4 * * *
BACKUP_KEEP_DAYS=14
BACKUP_KEEP_WEEKS=8
BACKUP_KEEP_MONTHS=12
```

### 3. Docker Compose anpassen

Für externe Datenbank die `postgres`, `minio` und `minio-init` Services entfernen:

```yaml
services:
  backup:
    image: prodrigestivill/postgres-backup-local:16-alpine
    environment:
      POSTGRES_HOST: ${POSTGRES_HOST}
      # ...
```

## Sicherheit

### Netzwerk-Isolation

```yaml
networks:
  backup-network:
    driver: bridge
    internal: true  # Kein Internet-Zugang
```

### Least Privilege für PostgreSQL

```sql
-- Backup-User mit minimalen Rechten
CREATE USER backup_user WITH PASSWORD 'xxx';
GRANT CONNECT ON DATABASE production_db TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO backup_user;
```

### Verschlüsselung

#### S3 Server-Side Encryption

MinIO mit SSE-S3:
```yaml
environment:
  MINIO_KMS_SECRET_KEY: my-secret-key:xxx
```

#### Backup-Verschlüsselung (GPG)

```bash
# Backup mit GPG verschlüsseln
pg_dump ... | gzip | gpg --encrypt --recipient backup@example.com > backup.sql.gz.gpg
```

## Hochverfügbarkeit

### Multi-Node MinIO

```yaml
services:
  minio:
    command: server http://minio{1...4}/data{1...2}
    deploy:
      replicas: 4
```

### Backup auf mehrere Ziele

```yaml
# Primäres Backup zu S3
backup-sync-s3:
  # ...

# Sekundäres Backup zu Azure Blob
backup-sync-azure:
  image: mcr.microsoft.com/azure-cli
  # ...
```

## Monitoring

### Prometheus Metrics

```yaml
backup:
  environment:
    ENABLE_PROMETHEUS: "true"
  ports:
    - "9090:9090"  # Metrics Endpoint
```

### Alerting

```yaml
# AlertManager Regel
groups:
  - name: backup
    rules:
      - alert: BackupFailed
        expr: backup_last_success_timestamp < time() - 86400
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "Backup ist älter als 24 Stunden"
```

### Logging

```yaml
backup:
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"
```

## Disaster Recovery

### Recovery Time Objective (RTO)

| Szenario | RTO |
|----------|-----|
| Einzelne Tabelle | < 30 min |
| Gesamte Datenbank | < 2 h |
| Kompletter Stack | < 4 h |

### Recovery Point Objective (RPO)

| Backup-Intervall | RPO |
|-----------------|-----|
| Stündlich | 1 Stunde |
| Alle 4 Stunden | 4 Stunden |
| Täglich | 24 Stunden |

### Restore-Runbook

1. **Identifizieren**: Welches Backup wird benötigt?
2. **Vorbereiten**: Ziel-Datenbank bereitstellen
3. **Restore**: Backup einspielen
4. **Verifizieren**: Datenintegrität prüfen
5. **Umschalten**: Traffic auf wiederhergestellte DB

## Checkliste

- [ ] Sichere Passwörter generiert
- [ ] Externe Datenbank konfiguriert
- [ ] S3/MinIO mit TLS
- [ ] Backup-Schedule definiert
- [ ] Retention-Policies konfiguriert
- [ ] Monitoring eingerichtet
- [ ] Alerting konfiguriert
- [ ] Restore-Test durchgeführt
- [ ] Dokumentation aktualisiert
