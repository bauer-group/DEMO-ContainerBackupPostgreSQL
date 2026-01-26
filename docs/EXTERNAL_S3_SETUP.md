# Externe S3 Storage Einrichtung

Diese Anleitung beschreibt die sichere Einrichtung von externem S3-Storage mit **WORM-Schutz** (Write Once Read Many).

## Übersicht

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Sicherheitsarchitektur                                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   1. Object Lock (WORM)     → Verhindert Löschen/Überschreiben          │
│   2. IAM Policy             → Minimale Rechte, kein BypassWORM          │
│   3. Lifecycle (pro Prefix) → Automatische Löschung nach Retention      │
│   4. Unique Filenames       → Jedes Backup = neues Objekt               │
│                                                                         │
│   Ergebnis: Selbst bei kompromittiertem Client sind Backups sicher      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Granulares Retention-Konzept

### Das Problem mit einheitlicher Retention

Die lokale Retention-Policy unterscheidet zwischen Backup-Typen:

| Backup-Typ | Lokale Aufbewahrung | Benötigte S3-Retention |
|------------|---------------------|------------------------|
| Last | stündlich | kein WORM (2 Tage Lifecycle) |
| Daily | 7 Tage | ~14 Tage (Puffer) |
| Weekly | 4 Wochen | ~35 Tage |
| Monthly | 6 Monate | ~185 Tage |

**Problem**: Eine einheitliche 30-Tage-WORM würde monatliche Backups vorzeitig löschen!

### Lösung: Prefix-basierte Retention

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Granulares WORM-Konzept (Prefix-basiert)                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   s3://pg-backups/                                                      │
│   ├── last/      → kein Object Lock       │ Lifecycle: 2 Tage          │
│   ├── daily/     → Object Lock: 14 Tage   │ Lifecycle: 15 Tage         │
│   ├── weekly/    → Object Lock: 35 Tage   │ Lifecycle: 36 Tage         │
│   └── monthly/   → Object Lock: 185 Tage  │ Lifecycle: 186 Tage        │
│                                                                         │
│   Jeder Prefix hat eigene Retention = Schutz entspricht Aufbewahrung   │
│   last/ = stündliche Backups ohne WORM (können überschrieben werden)   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Implementierungsoptionen

| Option | Beschreibung | Komplexität | Empfehlung |
|--------|--------------|-------------|------------|
| **A: Per-Object Retention** | Retention beim Upload setzen | Mittel | ✅ Flexibel |
| **B: Separate Buckets** | Ein Bucket pro Typ | Hoch | Für Enterprise |
| **C: Längste Retention** | 185d für alle | Niedrig | Einfach, aber mehr Storage |

**Empfehlung für Produktion**: Option A (Per-Object Retention)

---

## AWS S3

### Voraussetzungen

- AWS CLI installiert und konfiguriert (`aws configure`)
- IAM-Berechtigungen für Bucket- und Policy-Erstellung

### Schritt 1: Bucket mit Object Lock erstellen

> **Wichtig:** Object Lock muss bei Bucket-Erstellung aktiviert werden. Nachträglich nicht möglich!

```bash
# Variablen setzen
BUCKET_NAME="pg-backups-$(date +%s)"  # Eindeutiger Name
REGION="eu-central-1"

# Bucket erstellen mit Object Lock
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" \
  --object-lock-enabled-for-bucket

# Verifizieren
aws s3api get-object-lock-configuration --bucket "$BUCKET_NAME"
```

**Erwartete Ausgabe:**
```json
{
    "ObjectLockConfiguration": {
        "ObjectLockEnabled": "Enabled"
    }
}
```

### Schritt 2: Object Lock Default Retention konfigurieren

```bash
# GOVERNANCE Mode: 30 Tage Schutz
aws s3api put-object-lock-configuration \
  --bucket "$BUCKET_NAME" \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "GOVERNANCE",
        "Days": 30
      }
    }
  }'

# Verifizieren
aws s3api get-object-lock-configuration --bucket "$BUCKET_NAME"
```

**Erwartete Ausgabe:**
```json
{
    "ObjectLockConfiguration": {
        "ObjectLockEnabled": "Enabled",
        "Rule": {
            "DefaultRetention": {
                "Mode": "GOVERNANCE",
                "Days": 30
            }
        }
    }
}
```

**Modi-Erklärung:**

| Mode | Beschreibung | Empfehlung |
|------|--------------|------------|
| GOVERNANCE | Admin kann mit `s3:BypassGovernanceRetention` überschreiben | Standard für Backups |
| COMPLIANCE | Niemand kann löschen/überschreiben, auch nicht Root | Für regulatorische Anforderungen |

### Schritt 3: IAM User und Policy erstellen

```bash
# IAM User erstellen
aws iam create-user --user-name backup-sync-user

# Policy-Dokument erstellen
cat > /tmp/backup-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BackupSyncPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::BUCKET_NAME_PLACEHOLDER",
        "arn:aws:s3:::BUCKET_NAME_PLACEHOLDER/*"
      ]
    }
  ]
}
EOF

# Bucket-Name einsetzen
sed -i "s/BUCKET_NAME_PLACEHOLDER/$BUCKET_NAME/g" /tmp/backup-policy.json

# Policy erstellen
aws iam create-policy \
  --policy-name BackupSyncPolicy \
  --policy-document file:///tmp/backup-policy.json

# Policy an User anhängen (Account-ID anpassen!)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam attach-user-policy \
  --user-name backup-sync-user \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/BackupSyncPolicy"

# Access Keys erstellen
aws iam create-access-key --user-name backup-sync-user
```

**Speichere die Ausgabe sicher:**
```
AccessKeyId: AKIA...
SecretAccessKey: ...
```

> **Kritisch:** Die Policy enthält NICHT `s3:BypassGovernanceRetention`. Dadurch kann der Client WORM nicht umgehen.

### Schritt 4: Granulare Lifecycle Rules konfigurieren

> **Wichtig:** Unterschiedliche Retention für Daily/Weekly/Monthly Backups!

**Mit S3_PREFIX (Multi-Tenant):**

Wenn mehrere Stacks den gleichen Bucket nutzen, muss der Prefix in den Rules berücksichtigt werden:

```bash
# Variablen setzen
S3_PREFIX="production"  # oder leer lassen für root

# Lifecycle-Konfiguration generieren
if [ -n "$S3_PREFIX" ]; then
  DAILY_PREFIX="${S3_PREFIX}/daily/"
  WEEKLY_PREFIX="${S3_PREFIX}/weekly/"
  MONTHLY_PREFIX="${S3_PREFIX}/monthly/"
else
  DAILY_PREFIX="daily/"
  WEEKLY_PREFIX="weekly/"
  MONTHLY_PREFIX="monthly/"
fi

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --lifecycle-configuration "{
    \"Rules\": [
      {
        \"ID\": \"${S3_PREFIX:-root}-daily-cleanup\",
        \"Status\": \"Enabled\",
        \"Filter\": {
          \"Prefix\": \"${DAILY_PREFIX}\"
        },
        \"Expiration\": {
          \"Days\": 15
        },
        \"NoncurrentVersionExpiration\": {
          \"NoncurrentDays\": 1
        }
      },
      {
        \"ID\": \"${S3_PREFIX:-root}-weekly-cleanup\",
        \"Status\": \"Enabled\",
        \"Filter\": {
          \"Prefix\": \"${WEEKLY_PREFIX}\"
        },
        \"Expiration\": {
          \"Days\": 36
        },
        \"NoncurrentVersionExpiration\": {
          \"NoncurrentDays\": 1
        }
      },
      {
        \"ID\": \"${S3_PREFIX:-root}-monthly-cleanup\",
        \"Status\": \"Enabled\",
        \"Filter\": {
          \"Prefix\": \"${MONTHLY_PREFIX}\"
        },
        \"Expiration\": {
          \"Days\": 186
        },
        \"NoncurrentVersionExpiration\": {
          \"NoncurrentDays\": 1
        }
      }
    ]
  }"

# Verifizieren
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET_NAME"
```

**Retention-Übersicht:**

```
┌─────────────────────────┬───────────────────┬─────────────┬──────────────┐
│ Prefix (mit S3_PREFIX)  │ Lokale Retention  │ S3 Lifecycle│ Löschung     │
├─────────────────────────┼───────────────────┼─────────────┼──────────────┤
│ {prefix}/last/          │ stündlich         │ 2 Tage      │ Nach ~2d     │
│ {prefix}/daily/         │ 7 Tage            │ 15 Tage     │ Nach ~15d    │
│ {prefix}/weekly/        │ 4 Wochen (28d)    │ 36 Tage     │ Nach ~36d    │
│ {prefix}/monthly/       │ 6 Monate (180d)   │ 186 Tage    │ Nach ~186d   │
└─────────────────────────┴───────────────────┴─────────────┴──────────────┘
```

**Multi-Tenant Beispiel:**

```
s3://pg-backups/
├── production/           # S3_PREFIX=production
│   ├── daily/
│   ├── weekly/
│   └── monthly/
├── staging/              # S3_PREFIX=staging
│   ├── daily/
│   ├── weekly/
│   └── monthly/
└── development/          # S3_PREFIX=development
    ├── daily/
    └── weekly/           # (kein monthly für dev)
```

> **Hinweis:** Lifecycle löscht erst NACH Ablauf der Object Lock Retention.
> Bei WORM muss die Retention <= Lifecycle sein, sonst blockiert Object Lock die Löschung.

### Schritt 5: .env konfigurieren

```bash
# In deinem Projekt-Verzeichnis
cat >> .env << EOF

# Externe AWS S3 Konfiguration
S3_ENDPOINT=https://s3.${REGION}.amazonaws.com
S3_ACCESS_KEY=AKIA...  # Aus Schritt 3
S3_SECRET_KEY=...      # Aus Schritt 3
S3_BUCKET=${BUCKET_NAME}
S3_REGION=${REGION}
EOF
```

### Schritt 6: Verbindung testen

```bash
# Stack starten (ohne lokale MinIO)
docker compose up -d postgres backup backup-sync

# Logs prüfen
docker logs -f $(docker ps -qf "name=backup_sync")

# Manuellen Sync testen
./tools/sync-now.sh

# Bucket-Inhalt prüfen
aws s3 ls "s3://${BUCKET_NAME}/" --recursive
```

### Schritt 7: WORM-Schutz verifizieren

```bash
# Test-Datei hochladen
echo "test" | aws s3 cp - "s3://${BUCKET_NAME}/test-worm.txt"

# Versuche zu löschen (sollte fehlschlagen!)
aws s3 rm "s3://${BUCKET_NAME}/test-worm.txt"
```

**Erwarteter Fehler:**
```
delete failed: s3://bucket/test-worm.txt An error occurred (AccessDenied)
when calling the DeleteObject operation: Object is WORM protected
```

---

## Wasabi

Wasabi unterstützt S3-kompatibles Object Lock.

### Schritt 1: Bucket erstellen

1. Login unter https://console.wasabisys.com
2. **Buckets** → **Create Bucket**
3. Bucket-Name eingeben
4. Region wählen (z.B. `eu-central-1`)
5. **Enable Object Locking** aktivieren
6. **Create Bucket**

### Schritt 2: Object Lock konfigurieren

1. Bucket auswählen → **Settings** → **Object Locking**
2. **Default Retention**:
   - Mode: **Governance**
   - Duration: **30 days**
3. **Save**

### Schritt 3: Access Keys erstellen

1. **Access Keys** → **Create New Access Key**
2. Keys sicher speichern

### Schritt 4: .env konfigurieren

```bash
S3_ENDPOINT=https://s3.eu-central-1.wasabisys.com
S3_ACCESS_KEY=...
S3_SECRET_KEY=...
S3_BUCKET=pg-backups
S3_REGION=eu-central-1
```

---

## Externe MinIO

### Schritt 1: Bucket mit Object Lock erstellen

```bash
# Alias setzen
mc alias set myminio https://minio.example.com ACCESSKEY SECRETKEY

# Bucket mit Object Lock erstellen
mc mb --with-lock myminio/pg-backups

# Verifizieren
mc stat myminio/pg-backups
```

### Schritt 2: Default Retention konfigurieren

```bash
# GOVERNANCE Mode, 30 Tage
mc retention set --default GOVERNANCE 30d myminio/pg-backups

# Verifizieren
mc retention info myminio/pg-backups
```

### Schritt 3: Lifecycle konfigurieren

```bash
# Lifecycle Rule (31 Tage)
mc ilm rule add --expire-days 31 myminio/pg-backups

# Verifizieren
mc ilm rule ls myminio/pg-backups
```

### Schritt 4: Dedizierter User (Optional aber empfohlen)

```bash
# User erstellen
mc admin user add myminio backup-user SECRETPASSWORD

# Policy erstellen
cat > /tmp/backup-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
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
    }
  ]
}
EOF

mc admin policy create myminio backup-policy /tmp/backup-policy.json
mc admin policy attach myminio backup-policy --user backup-user
```

### Schritt 5: .env konfigurieren

```bash
S3_ENDPOINT=https://minio.example.com
S3_ACCESS_KEY=backup-user
S3_SECRET_KEY=SECRETPASSWORD
S3_BUCKET=pg-backups
```

---

## Checkliste

Nach der Einrichtung verifizieren:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Sicherheits-Checkliste                                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  [ ] Object Lock bei Bucket-Erstellung aktiviert                        │
│  [ ] Default Retention: GOVERNANCE, 30 Tage                             │
│  [ ] IAM Policy OHNE s3:BypassGovernanceRetention                       │
│  [ ] Lifecycle Rule: 31 Tage (> Retention)                              │
│  [ ] WORM-Test: Löschen schlägt fehl                                    │
│  [ ] Sync-Test: Neue Dateien werden hochgeladen                         │
│  [ ] Access Keys sicher gespeichert (nicht in Git!)                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Fehlerbehebung

### "Object Lock must be enabled when creating bucket"

Object Lock kann nur bei Bucket-Erstellung aktiviert werden. Lösung: Neuen Bucket erstellen.

### "Access Denied" beim Upload

- IAM Policy prüfen: Ist `s3:PutObject` enthalten?
- Bucket-Name korrekt in Policy?
- Access Keys korrekt in `.env`?

### "Object is WORM protected" beim Löschen

Das ist **korrekt**! Der WORM-Schutz funktioniert. Dateien können erst nach Ablauf der Retention gelöscht werden.

### Sync lädt keine Dateien hoch

Prüfen ob Dateien bereits existieren:
```bash
docker exec SYNC_CONTAINER mc ls storage/BUCKET/ --recursive
```

`mc mirror` ohne `--overwrite` lädt nur neue Dateien hoch.

---

## Referenzen

- [AWS S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [MinIO Object Locking](https://min.io/docs/minio/linux/administration/object-management/object-retention.html)
- [Wasabi Object Lock](https://wasabi-support.zendesk.com/hc/en-us/articles/360058673432)
