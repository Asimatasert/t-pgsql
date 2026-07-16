# t-pgsql

Fortgeschrittenes CLI-Werkzeug zum Sichern, Wiederherstellen und Synchronisieren von PostgreSQL-Datenbanken.

**Dokumentation:** [English](README.md) | [Español](README_ES.md) | [Русский](README_RU.md)

## Funktionen

### Kernoperationen
- **Dump**: Sicherung aus einer lokalen oder entfernten Datenbank
- **Restore**: Wiederherstellung einer Sicherung in eine lokale oder entfernte Datenbank (standardmäßig sicher bei `--force`)
- **Clone**: Dump + Restore in einem einzigen Befehl (vollständige Synchronisierung)
- **Upgrade**: Logische Migration einer Hauptversion (z. B. PG16 → PG18) inklusive Globals
- **Fetch**: Herunterladen eines vorhandenen Dumps von einem entfernten Server
- **Streaming**: Direkter Pipe-Clone ohne temporäre Dateien (`--stream`)

### Stapelverarbeitung & Automatisierung
- **Batch-Jobs**: Mehrere Jobs aus `jobs.yaml` ausführen
- **Parallele Ausführung**: Jobs nebenläufig ausführen (`--parallel N`)
- **Job-Filterung**: Bestimmte Jobs ausführen (`--only-jobs`) oder Jobs überspringen (`--exclude-jobs`)
- **Telegram-Bot**: Sicherungen aus einem Chat auslösen und überwachen (`bot`-Befehl)
- **Benachrichtigungen**: Telegram, Slack, Webhook, E-Mail mit Zusammenfassungs-Unterstützung

### Datenverwaltung
- **Datenmaskierung**: Sensible Daten nach der Wiederherstellung anonymisieren (`--mask`)
- **Tabellenfilterung**: Tabellen oder Schemata ein-/ausschließen
- **GFS-Aufbewahrung**: Grandfather-Father-Son-Rotationsrichtlinie für Sicherungen
- **Kodierungssicher**: Bewahrt bei der Wiederherstellung die Kodierung/Locale der Quelldatenbank

### Sicherheit & Zuverlässigkeit
- **Sichere Wiederherstellung**: `--force` stellt in eine temporäre Datenbank wieder her und tauscht sie nur bei Erfolg ein — eine fehlgeschlagene/beschädigte Wiederherstellung zerstört niemals die vorhandenen Daten
- **Health-Checks**: Verbindungen vor Operationen überprüfen
- **SSH-Tunnel**: Sicherer Zugriff auf entfernte Datenbanken
- **Passwortsicherheit**: Wird aus dem Prozess-argv herausgehalten (`.pgpass`/env); aus Dateien oder der Umgebung gelesen
- **Übertragungssteuerung**: Bandbreitenbegrenzung (`--bwlimit`) und Wiederholungen (`--retries`) für große/instabile Verbindungen
- **Metadaten**: Erfassung von Zeitverlauf, Quelle und Operationsdetails

## Installation

### Schnellinstallation (empfohlen)

```bash
curl -fsSL https://raw.githubusercontent.com/Asimatasert/t-pgsql/master/install.sh | bash
```

### Homebrew (macOS/Linux)

```bash
brew tap Asimatasert/t-pgsql
brew install t-pgsql
```

### Debian/Ubuntu

```bash
# Download latest .deb package
curl -LO https://github.com/Asimatasert/t-pgsql/releases/latest/download/t-pgsql_latest_all.deb
sudo dpkg -i t-pgsql_latest_all.deb
```

### Arch Linux (AUR)

```bash
# Using yay
yay -S t-pgsql

# Or manually
git clone https://github.com/Asimatasert/t-pgsql.git
cd t-pgsql/arch
makepkg -si
```

### Manuelle Installation

```bash
# Clone the repository
git clone https://github.com/Asimatasert/t-pgsql
cd t-pgsql

# Install with make
sudo make install

# Or manual install
chmod +x t-pgsql
sudo ln -s $(pwd)/t-pgsql /usr/local/bin/t-pgsql
```

### Shell-Vervollständigungen

Vervollständigungen werden mit Paketmanagern automatisch installiert. Für die manuelle Einrichtung:

```bash
# Zsh
cp completions/_t-pgsql ~/.zsh/completions/

# Bash
cp completions/t-pgsql.bash /etc/bash_completion.d/t-pgsql

# Fish
cp completions/t-pgsql.fish ~/.config/fish/completions/
```

### Handbuchseite

```bash
man t-pgsql
```

### Voraussetzungen

- PostgreSQL-Client (`pg_dump`, `pg_restore`, `psql`)
- SSH-Client (für entfernte Operationen)
- Bash 4.0+
- Optional: `pv` (für den Streaming-Puffer)

## Docker

Ein `Dockerfile` ist enthalten. Die Hauptversion des PostgreSQL-Clients ist ein Build-Argument —
setzen Sie es auf die Version Ihres **Ziel**-Servers, damit versionsübergreifende Dumps die richtigen
Werkzeuge verwenden (z. B. Dump eines PG16-Servers zur Wiederherstellung in PG18 → Build mit `PG_MAJOR=18`).

```bash
# Build with the desired client version
docker build --build-arg PG_MAJOR=18 -t t-pgsql:18 .

# One-off dump (mount a dumps volume)
docker run --rm -v "$PWD/dumps:/data/dumps" \
  t-pgsql:18 dump --from "postgres@db.example.com/mydb" --output /data/dumps -y

# Run the Telegram bot as a service (see docker-compose.yml)
docker compose up -d --build
```

Binden Sie Ihre `jobs.yaml`, Ihre Passwortdateien und Ihren SSH-Schlüssel in `/data` ein (und den SSH-Schlüssel
unter `/home/tpgsql/.ssh`). Das Image läuft als Nicht-Root-Benutzer.

## Hauptversions-Upgrades (logisch)

Der Befehl `upgrade` führt eine **logische** Migration einer Hauptversion durch (z. B. PG16 → PG18):
Er migriert die Cluster-Globals (Rollen, Tablespaces), prüft, dass das Ziel keine ältere
Hauptversion ist, und klont dann die Datenbank.

```bash
# Run from a host/container whose pg_dump matches the TARGET version (18 here).
t-pgsql upgrade \
  --from "postgres@old-16-host:5432/appdb" \
  --to   "postgres@new-18-host:5432/appdb" -y

# Or add globals to a plain clone, and pick client tools explicitly:
t-pgsql clone --from ... --to ... --globals --pg-bindir /usr/lib/postgresql/18/bin
```

**Ehrliche Einordnung:** Dies ist der Dump/Restore-Pfad, geeignet für kleine/mittelgroße Datenbanken oder
einen sauberen logischen Neuaufbau. Für große Cluster oder Umstellungen mit minimaler Ausfallzeit bleiben `pg_upgrade`
(in-place) und logische Replikation die etablierteren Werkzeuge — dieser Befehl
ersetzt sie nicht. Die Globals-Migration funktioniert für lokale/TCP- und SSH-Quellen und wird
auf jedes `--to`-Ziel angewendet.

## Entwicklung (modulare Quellen)

`t-pgsql` ist eine **generierte Einzeldatei**, die aus kleinen Modulen unter `src/`
(header, globals, logging, dump, restore, clone, upgrade, batch, bot, args, main, …) zusammengesetzt
und in der in `src/build.manifest` aufgeführten Reihenfolge aneinandergehängt wird.

```bash
# Edit a module, then rebuild the single file:
$EDITOR src/55-dump.sh
./build.sh            # or: make build

# Verify the committed t-pgsql is in sync with src/ (CI runs this):
./build.sh --check    # or: make check-build
```

Bearbeiten Sie `t-pgsql` **nicht** von Hand — Änderungen gehören in `src/`. Die Distribution bleibt unverändert:
Es wird weiterhin eine einzige ausführbare Datei installiert/ausgeliefert (Paketierung, Vervollständigungen und das
Verhalten von `SCRIPT_DIR` sind identisch). Da alles in einem einzigen Bash-Prozess mit einem
gemeinsamen globalen Namensraum läuft, ist das Aufteilen der Datei rein eine Frage der Code-Organisation — es
gibt keine Laufzeitkopplung und keine Synchronisierungsbedenken.

## Schnellstart

```bash
# Dump from local database
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump from remote server
./t-pgsql dump --from "ssh://user@192.0.2.20/postgres@localhost/mydb" --from-password-file .secrets/remote.pass

# Restore a dump
./t-pgsql restore --file ./dumps/mydb_20250101.tar.gz --to "postgres@localhost/mydb_copy" --to-password-file .secrets/local.pass

# Clone with single command (dump + restore)
./t-pgsql clone --from "ssh://user@server/postgres@localhost/prod" --to "postgres@localhost/dev" --from-password-file .secrets/prod.pass --to-password-file .secrets/local.pass --force
```

---

## Verbindungsformate

### Lokale Verbindung

```
[db_user@]host[:port]/database
```

| Beispiel | Beschreibung |
|---------|-------------|
| `localhost/mydb` | Standardbenutzer mit localhost |
| `postgres@localhost/mydb` | Mit dem Benutzer postgres |
| `postgres@localhost:5432/mydb` | Mit explizitem Port |
| `dbadmin@localhost/test123` | Benutzerdefinierter Benutzer |

### SSH-Verbindung (entfernt)

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Beispiel | Beschreibung |
|---------|-------------|
| `ssh://ubuntu@192.0.2.20/mydb` | Einfaches Format (db: localhost, Benutzer: postgres) |
| `ssh://ubuntu@192.0.2.20/postgres@localhost/mydb` | Mit angegebenem DB-Benutzer |
| `ssh://dbadmin@192.0.2.10/postgres@localhost/appdb` | Vollständiges Format |
| `ssh://dbadmin@server:2222/postgres@localhost:5433/prod` | Benutzerdefinierte Ports |

### Verbindungsstruktur

```
ssh://dbadmin@192.0.2.10/postgres@localhost/appdb
       |        |            |        |       |
       |        |            |        |       +-- Database name
       |        |            |        +---------- DB host (inside SSH)
       |        |            +------------------- DB user
       |        +-------------------------------- SSH server IP
       +----------------------------------------- SSH user
```

---

## Befehle

### dump

Erstellt eine Datenbanksicherung.

```bash
./t-pgsql dump --from <connection> [options]
```

**Beispiele:**

```bash
# Simple dump
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump from remote server
./t-pgsql dump \
  --from "ssh://dbadmin@192.0.2.10/postgres@localhost/appdb" \
  --from-password-file .secrets/from.pass \
  --output ./dumps

# Exclude specific tables
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-table "logs,sessions,temp_data"

# Include only specific tables
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --only-table "users,orders,products"

# Exclude data only (keep structure)
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-data "logs,audit_trail"

# Clean old dumps on source
./t-pgsql dump \
  --from "ssh://user@server/postgres@localhost/prod" \
  --from-password-file .secrets/prod.pass \
  --from-keep 3  # Keep last 3 dumps

# Custom dump name
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --dump-name myapp-backup  # Creates: myapp-backup_YYYYMMDD_HHMMSS.dump
```

**Ausgabe:** `<script dir>/../data/dumps/database_YYYYMMDD_HHMMSS.tar.gz` (Standard-Ausgabeverzeichnis; mit `--output` überschreibbar)

Das tar-Archiv enthält:
- `database_YYYYMMDD_HHMMSS.dump` - PostgreSQL-Dump-Datei (oder benutzerdefinierter Name)
- `metadata.yaml` - Operationsinformationen

---

### restore

Stellt eine Dump-Datei in eine Datenbank wieder her.

```bash
./t-pgsql restore --to <connection> [--file <file>] [options]
```

**Beispiele:**

```bash
# Restore latest dump (auto-find)
./t-pgsql restore --to "postgres@localhost/mydb" --to-password-file .secrets/local.pass

# Restore specific file
./t-pgsql restore \
  --file ./dumps/mydb_20250130.tar.gz \
  --to "postgres@localhost/mydb_copy" \
  --to-password-file .secrets/local.pass

# Drop and recreate existing DB
./t-pgsql restore \
  --file ./dumps/prod_backup.tar.gz \
  --to "postgres@localhost/test_db" \
  --to-password-file .secrets/local.pass \
  --force
```

> **Hinweis:** Wenn `--file` nicht angegeben ist, wird automatisch die neueste `.tar.gz`-Datei im `--output`-Verzeichnis gefunden.

---

### clone

Führt Dump + Restore in einem einzigen Befehl aus.

```bash
./t-pgsql clone --from <source> --to <target> [options]
```

**Beispiele:**

```bash
# Clone from remote to local
./t-pgsql clone \
  --from "ssh://dbadmin@192.0.2.10/postgres@localhost/appdb" \
  --to "dbadmin@localhost/test123" \
  --from-password-file .secrets/from.pass \
  --to-password-file .secrets/to.pass \
  --force

# Push from local to remote
./t-pgsql clone \
  --from "postgres@localhost/dev" \
  --to "ssh://user@server/postgres@localhost/staging" \
  --from-password-file .secrets/local.pass \
  --to-password-file .secrets/remote.pass

# Clone to multiple targets
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev1" \
  --to "postgres@localhost/dev2" \
  --to "postgres@localhost/test" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force

# Streaming clone (no temp files, direct pipe)
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --stream \
  --force

# Streaming with custom buffer size
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --stream \
  --stream-buffer 128 \
  --force
```

---

### fetch

Lädt eine vorhandene Dump-Datei von einem entfernten Server herunter (ohne einen neuen Dump zu erstellen).

```bash
./t-pgsql fetch --from <connection> --from-file [pattern] [options]
```

**Beispiele:**

```bash
# Download latest dump
./t-pgsql fetch \
  --from "ssh://user@server/postgres@localhost/mydb" \
  --from-file \
  --output ./dumps

# Download with specific pattern
./t-pgsql fetch \
  --from "ssh://user@server/postgres@localhost/mydb" \
  --from-file "mydb_20250130*.dump" \
  --output ./dumps
```

---

### list

Listet Dump-Dateien auf.

```bash
./t-pgsql list [--output <directory>]
```

**Beispielausgabe:**

```
Dumps in: /opt/t-pgsql/data/dumps

FILE                                      SIZE DATE
---------------------------------------------------------------------------
appdb_20251230_225325.tar.gz     39MiB 2025-12-30 22:54
mydb_20251229_143022.tar.gz              15MiB 2025-12-29 14:30
```

---

### meta

Zeigt die Metadateninformationen eines Dump-Archivs an.

```bash
./t-pgsql meta --file <archive.tar.gz>
```

**Beispielausgabe:**

```yaml
timing:
  started_at: "2025-12-30 22:53:25"
  finished_at: "2025-12-30 22:54:39"
  elapsed: "1m 14s"
  elapsed_seconds: 74

source:
  type: ssh
  host: 192.0.2.10
  port: 5432
  database: appdb
  user: postgres

file:
  name: appdb_20251230_225325.dump
  size: "41M"
  compression: gzip
  compress_level: 6

operation:
  command: dump
  status: success
  exit_code: 0

environment:
  script_version: "3.9.0"
  executed_by: dbadmin
  executed_on: macbookair
  working_dir: /opt/t-pgsql/t-pgsql
```

---

### clean

Löscht alte Dump-Dateien.

```bash
./t-pgsql clean [--output <directory>] [--keep <N>]
```

---

### jobs

Listet gespeicherte Batch-Jobs auf.

```bash
./t-pgsql jobs
```

---

## Batch-System

Speichern Sie wiederkehrende Operationen und führen Sie sie mit einem einzigen Befehl aus.

### Einen Job speichern

Speichern Sie einen beliebigen Befehl mit `--save <name>`:

```bash
./t-pgsql clone \
  --from "ssh://dbadmin@192.0.2.10/postgres@localhost/appdb" \
  --to "dbadmin@localhost/test123" \
  --from-password-file .secrets/from.pass \
  --to-password-file .secrets/to.pass \
  --force \
  --save nightly-sync
```

### Jobs ausführen

```bash
# Run a single job
./t-pgsql batch nightly-sync

# Run all jobs sequentially
./t-pgsql batch all

# Use different YAML file
./t-pgsql batch all --yaml sync-30     # bare name -> <script-dir>/sync-30.yaml
./t-pgsql batch all --yaml /path/to/custom.yaml   # path or *.yaml -> used as-is

# Run jobs in parallel (3 concurrent jobs)
./t-pgsql batch all --parallel 3

# Parallel with error handling
./t-pgsql batch all --parallel 4 --continue-on-error

# Run only specific jobs
./t-pgsql batch all --only-jobs "job1,job2,job3"

# Exclude specific jobs
./t-pgsql batch all --exclude-jobs "slow_job,optional_job"

# Send summary notification after batch
./t-pgsql batch all --notify telegram:TOKEN:CHAT --notify-summary

# Combined: parallel with filtering and notifications
./t-pgsql batch all \
  --yaml sync-myproductions \
  --parallel 3 \
  --exclude-jobs "slow_backup" \
  --continue-on-error \
  --notify-summary
```

### Jobs auflisten

```bash
# List jobs from default jobs.yaml
./t-pgsql jobs
./t-pgsql jobs list

# List jobs from custom YAML file
./t-pgsql jobs list --yaml sync-30                 # -> <script-dir>/sync-30.yaml
./t-pgsql jobs list --yaml /path/to/custom.yaml

# Show specific job details
./t-pgsql jobs show nightly-sync
./t-pgsql jobs show nightly-sync --yaml sync-30

# Remove a job
./t-pgsql jobs remove old_job
./t-pgsql jobs remove old_job --yaml sync-30

# Output:
# Available jobs:
# ===============
#   - nightly-sync
#   - appdb_sync
#   - daily_backup
```

---

### bot

Führt einen langlebigen Telegram-Bot aus, mit dem Sie Sicherungen aus einem Chat auslösen und überwachen können. Er ruft Telegram per Long-Polling ab (`getUpdates`) und reagiert nur auf den **konfigurierten Chat** (fail-closed — ohne konfigurierten Chat ignoriert er jeden Befehl).

```bash
# Token from --token, or defaults.notify.telegram in the YAML, or $TELEGRAM_BOT_TOKEN
./t-pgsql bot --yaml sync-30 --token "123456:ABC..." --cooldown 1h
```

**Chat-Befehle:**

| Befehl | Aktion |
|---------|--------|
| `/help` | Verfügbare Befehle anzeigen |
| `/list` | YAML-Dateien im Skriptverzeichnis auflisten |
| `/list <yaml>` | Die in einer YAML definierten Jobs auflisten |
| `/backup <yaml> <job>` | Einen Sicherungsjob im Hintergrund starten und das Ergebnis melden |

Fehlerbenachrichtigungen enthalten eine Inline-Schaltfläche **„Re-run Backup“**. `--cooldown` (Standard `1h`, Format `<N>[h|m|d]`) begrenzt, wie oft derselbe Job über die Schaltfläche oder `/backup` erneut ausgelöst werden kann. Die Chat-ID und der (optionale) Forum-Thread werden aus `defaults.notify.telegram` der YAML oder aus `TELEGRAM_CHAT_ID` / `TELEGRAM_THREAD_ID` gelesen.

> Führen Sie ihn unter einem Prozessmanager aus (systemd, `docker compose`, `tmux`) — siehe den Abschnitt [Docker](#docker) für einen Compose-Dienst.

---

### jobs.yaml-Format

t-pgsql unterstützt drei Job-Formate: profilbasiert, Verbindungszeichenkette und Legacy-Args.

#### Profilbasiertes Format (empfohlen)

Definieren Sie wiederverwendbare Verbindungsprofile und Standardwerte, um Wiederholungen zu reduzieren:

```yaml
# Profiles - reusable connection configurations
profiles:
  production:
    type: ssh
    ssh_user: deploy
    ssh_host: prod.example.com
    db_user: postgres
    db_host: localhost
    db_port: 5432
    password_file: ~/.secrets/prod.pass

  local:
    type: local
    db_user: postgres
    db_host: localhost
    password_file: ~/.secrets/local.pass

# Defaults - inherited by all jobs
defaults:
  output: ~/data/dumps
  from_keep: 1
  skip_if_recent: 24h
  force: true
  compress: gzip
  compress_level: 6
  stream_buffer: 256
  exclude_data: "audit.*,public.sessionlog"
  parallel: 4
  continue_on_error: true
  notify:
    telegram:
      chat_id: "-123456789"
      token: "BOT_TOKEN"
      message_thread_id: 12345  # Optional: for forum topics

# Jobs using profiles (inherit defaults)
jobs:
  prod-to-local:
    command: clone
    dump_name: myapp-backup  # Custom dump name (optional)
    from:
      profile: production
      database: myapp
    to:
      profile: local
      database: myapp_dev
    # force, output, exclude_data etc. inherited from defaults
```

#### Format mit Verbindungszeichenkette

Verwenden Sie direkte Verbindungszeichenketten für einfachere Jobs:

```yaml
jobs:
  quick-backup:
    command: dump
    from: ssh://user@server/postgres@localhost/mydb
    from_password_file: ~/.secrets/prod.pass
    output: ./dumps
    keep: 7
```

#### Legacy-Args-Format (abwärtskompatibel)

Das alte Format funktioniert weiterhin zur Abwärtskompatibilität:

```yaml
jobs:
  legacy_job:
    command: clone
    args: --from 'ssh://user@server/postgres@localhost/db' --to 'postgres@localhost/db' --force
```

#### Job-Optionen

| Option | Beschreibung |
|--------|-------------|
| `force` | Vorhandene Datenbank löschen und neu erstellen |
| `verbose` | Detaillierte Ausgabe anzeigen |
| `from_keep` | Anzahl der auf der Quelle zu behaltenden Dumps |
| `keep` | Anzahl der lokal zu behaltenden Dumps |
| `dump_name` | Benutzerdefinierter Dump-Dateiname (ohne Zeitstempel) |
| `skip_if_recent` | Überspringen, wenn innerhalb des Zeitrahmens bereits ein Dump existiert (z. B. `24h`, `1d`, `today`) |
| `output` | Ausgabeverzeichnis für Dumps |
| `exclude_table` | Vollständig auszuschließende Tabellen |
| `exclude_data` | Tabellen, bei denen nur die Daten ausgeschlossen werden (unterstützt `schema.*`-Platzhalter) |
| `exclude_schema` | Auszuschließende Schemata |

---

## Fortgeschrittene Funktionen

### GFS-Aufbewahrung (Grandfather-Father-Son)

Automatisierte Rotationsrichtlinie für Sicherungen, die tägliche, wöchentliche, monatliche und jährliche Sicherungen behält:

```bash
# Enable GFS retention with defaults (7 daily, 4 weekly, 12 monthly, 3 yearly)
./t-pgsql dump \
  --from "postgres@localhost/prod" \
  --password-file .secrets/db.pass \
  --retention

# Custom retention periods
./t-pgsql dump \
  --from "postgres@localhost/prod" \
  --password-file .secrets/db.pass \
  --retention \
  --retention-daily 14 \
  --retention-weekly 8 \
  --retention-monthly 24 \
  --retention-yearly 5

# In jobs.yaml
jobs:
  daily-backup:
    command: dump
    from: postgres@localhost/prod
    from_password_file: .secrets/prod.pass
    output: /backups
    retention: true
    retention_daily: 7
    retention_weekly: 4
```

### Datenmaskierung

Anonymisieren Sie sensible Daten nach der Wiederherstellung für Entwicklungs-/Testumgebungen. Die Maskierung läuft **nach** der Wiederherstellung (daher wird sie mit `--stream` nicht unterstützt). Sie ist ausfallsicher: Wenn `--mask` auf **nichts** zutraf — oder eine Maskierungsanweisung einen Fehler verursacht —, **schlägt** die Operation fehl, anstatt eine unmaskierte Kopie als Erfolg zu melden.

- `--mask-tables` maskiert automatisch eine feste Menge bekannter sensibler Spalten (`email`, `phone`, `password`, `password_hash`, `address`, `ssn`, `credit_card`) — jedoch nur die Spalten, die in jeder benannten aktualisierbaren Basistabelle tatsächlich **existieren**. Ein einfacher Tabellenname, der auf mehrere Schemata passt, maskiert die Tabelle in jedem Schema (schemaqualifiziert). Bezeichner werden stets in Anführungszeichen gesetzt, sodass reservierte Wörter / Tabellennamen mit gemischter Groß-/Kleinschreibung funktionieren.
- `--mask-rules` wendet Ihre eigenen SQL-Ausdrücke aus einer JSON-Datei an (siehe unten).

```bash
# Auto-mask common fields in specified tables
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --mask \
  --mask-tables "users,customers,orders" \
  --force

# Use custom masking rules file
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --mask \
  --mask-rules mask-rules.json \
  --force
```

**mask-rules.json-Format:**

```json
{
  "users.email": "CONCAT(LEFT(email, 2), '***@example.com')",
  "users.phone": "'555-***-****'",
  "users.name": "CONCAT('User_', id)",
  "customers.address": "'[REDACTED]'",
  "orders.notes": "NULL"
}
```

**Automatisch maskierte Felder** (bei Verwendung von `--mask-tables`):
- `email` → `ab***@***.com`
- `phone` → `***-***-****`
- `password` / `password_hash` → `********` / `MASKED`
- `address` → `[MASKED]`
- `ssn` → `***-**-****`
- `credit_card` → `****-****-****-****`

### Health-Checks

Datenbankverbindungen vor Operationen überprüfen:

```bash
# Enable health check (verify connection before operation)
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --health-check \
  --force

# Abort if health check fails
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --health-check \
  --health-check-fail \
  --force

# Disable health checks
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --no-health-check \
  --force
```

### Streaming-Modus

Direkte Pipe-Übertragung ohne Erstellung temporärer Dateien (schneller, weniger Speicherplatz):

```bash
# Stream clone (pg_dump | pg_restore)
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --stream \
  --force

# With custom buffer size (requires pv installed)
./t-pgsql clone \
  --from "postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --stream \
  --stream-buffer 256 \
  --force
```

> **Hinweis:** Der Streaming-Modus erstellt keine lokalen Dump-Dateien. Verwenden Sie einen regulären Clone, wenn Sie Sicherungen behalten möchten.

---

## Passwortverwaltung

Passwörter sollten nicht im Bash-Verlauf erscheinen. Es gibt 3 Methoden:

### 1. Passwortdatei (empfohlen)

#### Einrichtung des .secrets-Verzeichnisses

```bash
# Create .secrets directory
mkdir -p .secrets
chmod 700 .secrets

# Add to .gitignore (IMPORTANT!)
echo ".secrets/" >> .gitignore
```

#### Passwortdateien erstellen

```bash
# IMPORTANT: Use -n flag to avoid newline at end of file
echo -n "your_password_here" > .secrets/db.pass

# Set secure permissions (read/write only for owner)
chmod 600 .secrets/db.pass

# Verify no newline exists
cat .secrets/db.pass | xxd | tail -1
# Should NOT end with '0a' (newline character)
```

#### Empfohlene .secrets-Struktur

```
.secrets/
├── from.pass      # Source database password
├── to.pass        # Target database password
├── prod.pass      # Production database password
├── dev.pass       # Development database password
└── ssh.key        # SSH private key (optional)
```

#### Passwortdatei-Format

| Anforderung | Beschreibung |
|-------------|-------------|
| **Kein Zeilenumbruch** | Verwenden Sie `echo -n`, um einen abschließenden Zeilenumbruch zu vermeiden |
| **Klartext** | Nur das Passwort, sonst nichts |
| **UTF-8** | UTF-8-Kodierung verwenden |
| **Berechtigungen** | `chmod 600` (nur Lesen/Schreiben für den Eigentümer) |

#### Verwendungsbeispiele

```bash
# Single password file for both connections
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Separate password files for source and target
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/dev.pass
```

### 2. Umgebungsvariable

```bash
# Single password for both connections
export T_PGSQL_PASSWORD="supersecret"
./t-pgsql dump --from "postgres@localhost/mydb"

# Separate passwords for source and target
export T_PGSQL_FROM_PASSWORD="prod_pass"
export T_PGSQL_TO_PASSWORD="local_pass"
./t-pgsql clone --from "..." --to "..."

# Using in scripts (password not visible in ps)
T_PGSQL_PASSWORD="secret" ./t-pgsql dump --from "postgres@localhost/mydb"
```

| Umgebungsvariable | Beschreibung |
|---------------------|-------------|
| `T_PGSQL_PASSWORD` | Passwort für beide Verbindungen |
| `T_PGSQL_FROM_PASSWORD` | Passwort der Quellverbindung |
| `T_PGSQL_TO_PASSWORD` | Passwort der Zielverbindung |

### 3. Interaktive Eingabeaufforderung

Wenn kein Passwort angegeben ist, wird es sicher vom Terminal abgefragt:

```bash
./t-pgsql dump --from "postgres@localhost/mydb"
# FROM password: ********  (input is hidden)
```

> **Hinweis:** Die interaktive Eingabeaufforderung funktioniert nur im Terminal (TTY). Verwenden Sie für Skripte und Cron-Jobs Passwortdateien oder Umgebungsvariablen.

### Reihenfolge der Passwort-Priorität

Wenn mehrere Passwortquellen verfügbar sind, verwendet t-pgsql diese Priorität:

1. **Direkter Parameter** (`--password`, `--from-password`, `--to-password`)
2. **Umgebungsvariable** (`T_PGSQL_PASSWORD`, usw.)
3. **Passwortdatei** (`--password-file`, usw.)
4. **Interaktive Eingabeaufforderung** (falls TTY verfügbar)

### Bewährte Sicherheitspraktiken

| Praxis | Beschreibung |
|----------|-------------|
| `.gitignore` verwenden | Passwortdateien niemals in git committen |
| `chmod 600` verwenden | Dateizugriff auf den Eigentümer beschränken |
| `chmod 700` verwenden | Verzeichniszugriff auf den Eigentümer beschränken |
| `--password` vermeiden | Kein direktes Passwort in der Befehlszeile verwenden |
| Separate Dateien verwenden | Unterschiedliche Dateien für Prod-/Dev-Umgebungen verwenden |
| Passwörter rotieren | Passwortdateien regelmäßig aktualisieren |

---

## Konfigurationsdatei (`--config`)

`--config <file>` lädt **Standardwerte pro Ausführung** für einen einzelnen Befehl (verschieden von der über `--yaml` gesetzten Jobs-YAML). Es handelt sich um eine einfache `key: value`-Datei; **CLI-Flags und Umgebungsvariablen haben stets Vorrang** vor der Datei.

```yaml
# db.conf — loaded with:  t-pgsql dump --config db.conf
from: "ssh://user@prod/postgres@localhost/app"
to: "postgres@localhost/dev"
from_password_file: ~/.secrets/prod.pass    # ~ expands for PATH keys only
output: ~/backups
keep: 7
compress: zstd
exclude_table: "logs,sessions"
notify: "telegram:TOKEN:CHAT"               # repeatable
verbose: true
```

Die unterstützten Schlüssel spiegeln die Flags wider: `from`, `to`, `password`/`from_password`/`to_password`, `password_file`/`from_password_file`/`to_password_file`, `output`, `keep`, `from_keep`, `compress`, `exclude_table`/`exclude_data`/`exclude_schema`, `only_table`/`only_schema`, `notify` (wiederholbar) sowie die Booleans `verbose`/`force`/`sudo`. `~` wird nur für pfadartige Schlüssel expandiert — niemals für Passwörter oder Verbindungszeichenketten.

---

## Vollständige Parameterreferenz

### Verbindungsparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--from <conn>` | Verbindungszeichenkette der Quelldatenbank | - | Ja (dump/clone) | `postgres@localhost/mydb` |
| `--to <conn>` | Verbindungszeichenkette der Zieldatenbank (wiederholbar für mehrere Ziele) | - | Ja (restore/clone) | `ssh://user@host/db` |

**Formate der Verbindungszeichenkette:**
- Lokal: `[user@]host[:port]/database`
- SSH: `ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database`

### Passwortparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--password <pass>` | Passwort für Quelle und Ziel | - | Nein | `mysecret` |
| `--from-password <pass>` | Passwort nur für die Quellverbindung | - | Nein | `srcpass` |
| `--to-password <pass>` | Passwort nur für die Zielverbindung | - | Nein | `dstpass` |
| `--password-file <file>` | Passwort aus Datei lesen (beide Verbindungen) | - | Nein | `.secrets/db.pass` |
| `--from-password-file <file>` | Quellpasswort aus Datei lesen | - | Nein | `.secrets/from.pass` |
| `--to-password-file <file>` | Zielpasswort aus Datei lesen. Wiederholbar — positionsgenau jedem `--to` zugeordnet oder einmal angegeben, um für alle Ziele zu gelten. | - | Nein | `.secrets/to.pass` |
| `--config <file>` | Datei mit Standardwerten pro Ausführung (siehe [Konfigurationsdatei](#konfigurationsdatei-config)) | - | Nein | `db.conf` |

**Umgebungsvariablen:**
- `T_PGSQL_PASSWORD` - Passwort für beide Verbindungen
- `T_PGSQL_FROM_PASSWORD` - Quellpasswort
- `T_PGSQL_TO_PASSWORD` - Zielpasswort

### Filterparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--exclude-table <tables>` | Kommagetrennte auszuschließende Tabellen | - | Nein | `logs,sessions,temp` |
| `--exclude-schema <schemas>` | Kommagetrennte auszuschließende Schemata | - | Nein | `audit,temp` |
| `--exclude-data <tables>` | Daten ausschließen, aber Struktur behalten (unterstützt `schema.*`-Platzhalter) | - | Nein | `audit.*,logs` |
| `--only-table <tables>` | Nur diese Tabellen einschließen | - | Nein | `users,orders` |
| `--only-schema <schemas>` | Nur diese Schemata einschließen | - | Nein | `public,app` |

### Komprimierungsparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--compress <type>` | Komprimierungsalgorithmus | `gzip` | Nein | `zstd`, `xz`, `bzip2`, `none` |
| `--compress-level <1-9>` | Komprimierungsstufe | `6` | Nein | `9` |
| `--pg-compress-level <0-9>` | Interne Komprimierung von pg_dump | `6` | Nein | `0` (keine Komprimierung) |
| `--compress-where <where>` | Bei SSH-Dumps: zstd/xz/bzip2 auf dem `source`-Host vor dem Kopieren ausführen oder auf dem `target` danach. `source` überträgt eine viel kleinere Datei über langsame Uplinks; fällt auf `target` zurück, wenn das Tool auf der Quelle fehlt | `target` | Nein | `source` |

### Speicherparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--output <dir>` | Ausgabeverzeichnis für Dumps | `<script dir>/../data/dumps` | Nein | `/backups/daily` |
| `--keep <N>` | Anzahl der lokal zu behaltenden Dumps | `-1` (alle) | Nein | `7`, `0` (löschen), `-1` (alle) |
| `--from-keep <N>` | Anzahl der auf der Quelle zu behaltenden Dumps | `1` | Nein | `3`, `0` (löschen), `-1` (alle) |
| `--from-stale <time>` | Mit `--from-keep 0`: vor dem Dump liegengebliebene Dumps dieses Jobs, die älter als `<time>` sind, aus dem Staging-Verzeichnis der Quelle löschen (fehlgeschlagene Läufe erreichen die normale Bereinigung nie) | `72h` | Nein | `48h`, `2d`, `0` (aus) |
| `--dump-name <name>` | Benutzerdefinierter Dump-Dateiname (ohne Zeitstempel) | Datenbankname | Nein | `myapp-backup` |
| `--skip-if-recent <time>` | Überspringen, wenn innerhalb des Zeitrahmens ein Dump existiert | - | Nein | `24h`, `12h`, `1d`, `today` |
| `--file <path>` | Bestimmte Dump-Datei für die Wiederherstellung | - | Nein | `./dumps/backup.tar.gz` |
| `--from-file [pattern]` | Vorhandenen Dump abrufen (kein Wert = neuester) | - | Nein | `mydb_*.dump` |

### Aufbewahrungsparameter (GFS - Grandfather-Father-Son)

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--retention` | GFS-Aufbewahrungsrichtlinie aktivieren | `false` | Nein | - |
| `--retention-daily <N>` | Zu behaltende tägliche Sicherungen | `7` | Nein | `14` |
| `--retention-weekly <N>` | Zu behaltende wöchentliche Sicherungen | `4` | Nein | `8` |
| `--retention-monthly <N>` | Zu behaltende monatliche Sicherungen | `12` | Nein | `24` |
| `--retention-yearly <N>` | Zu behaltende jährliche Sicherungen | `3` | Nein | `5` |

### Health-Check-Parameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--health-check` | Datenbank vor der Operation prüfen | `true` | Nein | - |
| `--health-check-after` | Datenbank nach der Operation prüfen | `false` | Nein | - |
| `--no-health-check` | Alle Health-Checks deaktivieren | `false` | Nein | - |
| `--health-check-fail` | Bei fehlgeschlagenem Health-Check abbrechen | `false` | Nein | - |

### Benachrichtigungsparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--notify <channel>` | Benachrichtigungskanal (wiederholbar) | - | Nein | `telegram:TOKEN:CHAT` |
| `--notify-on-error` | Nur bei Fehlern benachrichtigen | `false` | Nein | - |
| `--notify-summary` | Zusammenfassung nach dem Batch senden | `false` | Nein | - |

**Unterstützte Kanäle:** `telegram`, `slack:URL`, `webhook:URL`, `email:ADDRESS`

### Datenmaskierungsparameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--mask` | Datenmaskierung aktivieren | `false` | Nein | - |
| `--mask-rules <file>` | JSON-Datei mit Maskierungsregeln | - | Nein | `mask-rules.json` |
| `--mask-tables <tables>` | Tabellen, auf die die Maskierung angewendet wird | - | Nein | `users,customers` |

### Streaming-Parameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--stream` | Stream-Modus (keine temporären Dateien); leitet `pg_dump \| pg_restore` direkt weiter | `false` | Nein | - |
| `--stream-buffer <MB>` | Puffergröße für Daten in Übertragung in Megabyte (`pv`) | `64` | Nein | `128` |

> **Sicherheitshinweis:** Anders als bei jedem anderen Pfad trägt `--stream` den entfernten `pg_restore`-Befehl (mit seiner `.pgpass`-Präambel) im ssh-argv, sodass die Anmeldedaten für die Dauer des Streams kurzzeitig via `ps` auf dem entfernten Host sichtbar sind. Verwenden Sie `--sudo` (Peer-Authentifizierung) oder den Nicht-Stream-Clone, falls das relevant ist. `--mask` wird mit `--stream` nicht unterstützt (die Maskierung läuft nach einer vollständigen Wiederherstellung).

### Übertragungs- & Zuverlässigkeitsparameter

Gelten für SSH-/scp-Übertragungen (und die `--stream`-Pipe, wenn `pv` installiert ist).

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--bwlimit <rate>` | Übertragungsbandbreite drosseln. `10m` = 10 MB/s, `500k` = 500 KB/s, bloße Zahl = KB/s. scp verwendet sein `-l`; Streaming verwendet `pv -L` (benötigt `pv`). | unbegrenzt | Nein | `10m` |
| `--retries <N>` | Zusätzliche Wiederholungsversuche für eine fehlgeschlagene scp-Übertragung (annähernd exponentieller Backoff) | `0` | Nein | `3` |

### Batch-Parameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--yaml <name>` | Jobs-YAML-Datei. Ein bloßer Name wird zu `<script-dir>/<name>.yaml` aufgelöst; ein Wert, der `/` enthält oder auf `.yaml` endet, wird unverändert verwendet | `<script-dir>/jobs.yaml` | Nein | `sync-30`, `./jobs/prod.yaml` |
| `--save <name>` | Den aktuellen Befehl + Flags als Job speichern (statt ausführen) | - | Nein | `daily_backup` |
| `--batch <name\|all>` | Gespeicherte(n) Job(s) ausführen; entspricht `t-pgsql batch <name\|all>` | - | Nein | `daily_backup`, `all` |
| `--parallel <N>` | Anzahl der parallel auszuführenden Jobs | `1` | Nein | `4` |
| `--continue-on-error` | Den Batch fortsetzen, auch wenn ein Job fehlschlägt | `false` | Nein | - |
| `--only-jobs <jobs>` | Nur diese Jobs ausführen (kommagetrennt) | - | Nein | `job1,job2` |
| `--exclude-jobs <jobs>` | Diese Jobs überspringen (kommagetrennt) | - | Nein | `slow_job` |
| `--only <jobs>` | Veralteter Alias für `--only-jobs` | - | Nein | `job1,job2` |
| `--exclude <jobs>` | Veralteter Alias für `--exclude-jobs` | - | Nein | `slow_job` |
| `--skip-if-recent <time>` | Einen Job überspringen, wenn innerhalb des Zeitfensters ein Dump existiert | - | Nein | `24h`, `30m`, `2d`, `today` |

### Migrationsparameter (`upgrade` / `clone`)

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--globals` | Auch Cluster-Globals (Rollen, Tablespaces) via `pg_dumpall --globals-only` migrieren; bereits vorhandene Rollen werden toleriert. Bei `upgrade` erzwungen. | `false` | Nein | - |
| `--pg-bindir <dir>` | `<dir>` dem `PATH` voranstellen, um eine bestimmte PostgreSQL-Client-Version für **lokale** `pg_dump`/`pg_restore`/`psql`/`createdb`/`pg_dumpall` (nicht SSH-remote) auszuwählen | - | Nein | `/usr/lib/postgresql/18/bin` |

### Bot-Parameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `--token <token>` | Telegram-Bot-Token (andernfalls aus `defaults.notify.telegram` in der YAML oder aus `TELEGRAM_BOT_TOKEN` gelesen) | - | Nein | `123:ABC...` |
| `--cooldown <time>` | Minimales Intervall zwischen über Schaltfläche/`/backup` ausgelösten Läufen desselben Jobs. Format `<N>[h\|m\|d]`. | `1h` | Nein | `30m`, `2d` |

### Allgemeine Parameter

| Parameter | Beschreibung | Standard | Erforderlich | Beispiel |
|-----------|-------------|---------|----------|---------|
| `-f, --force` | Vorhandene Datenbank löschen und neu erstellen | `false` | Nein | - |
| `-v, --verbose` | Detaillierte Ausgabe anzeigen | `false` | Nein | - |
| `-q, --quiet` | Minimale Ausgabe | `false` | Nein | - |
| `-y, --yes` | Alle Bestätigungen überspringen | `false` | Nein | - |
| `--dry-run` | Anzeigen, was getan würde, ohne es auszuführen | `false` | Nein | - |
| `--sudo` | sudo für Datenbankoperationen verwenden | `false` | Nein | - |
| `--log <file>` | Protokolle in Datei schreiben | - | Nein | `/var/log/t-pgsql.log` |
| `--log-level <level>` | Ausführlichkeit der Protokollierung | `info` | Nein | `debug`, `warn`, `error` |
| `--no-meta` | Keine Metadaten in Archive schreiben | `false` | Nein | - |
| `-h, --help` | Hilfemeldung anzeigen | - | Nein | - |
| `--version` | Versionsnummer anzeigen | - | Nein | - |

### Umgebungsvariablen

| Variable | Beschreibung |
|----------|-------------|
| `T_PGSQL_PASSWORD` | Passwort für Quelle und Ziel |
| `T_PGSQL_FROM_PASSWORD` | Passwort der Quellverbindung |
| `T_PGSQL_TO_PASSWORD` | Passwort der Zielverbindung |
| `T_PGSQL_OUTPUT_DIR` | Standard-Ausgabeverzeichnis für Dumps (durch `--output` überschrieben) |
| `PGCONNECT_TIMEOUT` | libpq-Verbindungs-Timeout in Sekunden (Standard `10`) |
| `TELEGRAM_BOT_TOKEN` | Löst den bloßen `--notify telegram`-Kanal und das `bot`-Token auf |
| `TELEGRAM_CHAT_ID` | Chat-ID für den bloßen `--notify telegram`-Kanal |
| `TELEGRAM_THREAD_ID` | Optionale Forum-Thema-Thread-ID für Telegram-Benachrichtigungen |

> Passwörter, die über Umgebungsvariablen übergeben werden (oder inline eingeschränkt, z. B. `T_PGSQL_PASSWORD=secret t-pgsql ...`), werden niemals in ein Prozess-argv gelegt und sind daher für `ps` nicht sichtbar.

### Interne Standardwerte

| Variable | Standardwert | Beschreibung |
|----------|---------------|-------------|
| `FROM_DB_USER` | `postgres` | Standard-Datenbankbenutzer |
| `FROM_DB_HOST` | `localhost` | Standard-Datenbankhost |
| `FROM_DB_PORT` | `5432` | Standard-PostgreSQL-Port |
| `FROM_SSH_PORT` | `22` | Standard-SSH-Port |

---

## Praktische Beispiele

### Tägliche Sicherung

```bash
# For cron job
0 2 * * * /path/to/t-pgsql dump \
  --from "ssh://user@prod/postgres@localhost/app" \
  --from-password-file /path/to/.secrets/prod.pass \
  --output /backups/daily \
  --keep 7 \
  --from-keep 1 \
  >> /var/log/t-pgsql.log 2>&1
```

### Synchronisierung der Entwicklungsumgebung

```bash
# Clone from prod to dev
./t-pgsql clone \
  --from "ssh://dbadmin@prod.example.com/postgres@localhost/production" \
  --to "postgres@localhost/development" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --exclude-table "logs,sessions,audit_trail" \
  --force

# Save as job
./t-pgsql clone ... --save prod_to_dev

# Repeat with single command
./t-pgsql --batch prod_to_dev
```

### Bereitstellung in mehreren Umgebungen

```bash
./t-pgsql clone \
  --from "ssh://dbadmin@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev" \
  --to "postgres@localhost/staging" \
  --to "postgres@localhost/test" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force
```

### Große Tabellen ausschließen

```bash
./t-pgsql dump \
  --from "postgres@localhost/analytics" \
  --password-file .secrets/db.pass \
  --exclude-data "raw_events,page_views,click_stream" \
  --output ./dumps
```

---

## Dateistruktur

```
t-pgsql/
├── t-pgsql              # Main script
├── jobs.yaml           # Batch job definitions
├── README.md           # This document
├── .secrets/           # Password files
│   ├── from.pass
│   └── to.pass
└── dumps/              # Dump files
    ├── mydb_20251230_143022.tar.gz
    └── prod_20251229_090000.tar.gz
```

---

## Fehlerbehebung

### SSH-Verbindungsfehler

```bash
# Test SSH access
ssh dbadmin@192.0.2.10 "echo ok"

# Run with verbose mode
./t-pgsql dump --from "ssh://..." -v
```

### Passwortfehler

```bash
# Check password file
cat .secrets/db.pass | xxd  # Should have no newline

# Fix it
echo -n "password" > .secrets/db.pass
```

### Fehler „Datenbank existiert bereits“

```bash
# Use --force to drop existing DB
./t-pgsql restore --to "..." --force
```

### Zugriff verweigert

```bash
# Password file permissions
chmod 600 .secrets/*.pass
```

---

## Lizenz

MIT-Lizenz

## Mitwirken

Pull Requests sind willkommen.
