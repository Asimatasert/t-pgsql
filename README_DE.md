# t-pgsql

Erweitertes CLI-Tool zum Sichern, Wiederherstellen und Synchronisieren von PostgreSQL-Datenbanken.

**Dokumentation:** [English](README.md) | [Türkçe](README_TR.md) | [Español](README_ES.md) | [Русский](README_RU.md)

## Funktionen

- **Dump**: Sicherung von lokaler oder entfernter Datenbank
- **Restore**: Sicherung in lokale oder entfernte Datenbank wiederherstellen
- **Clone**: Einzelbefehl dump + restore (vollständige Synchronisation)
- **Fetch**: Vorhandenen Dump vom Remote-Server herunterladen
- **Batch**: Mehrere Jobs nacheinander ausführen
- **Metadata**: Zeit-, Quell- und Zielinformationen mit jeder Sicherung speichern
- **SSH-Unterstützung**: Zugriff auf Remote-Server über SSH-Tunnel
- **Passwortsicherheit**: Passwörter aus Dateien oder Umgebungsvariablen lesen

## Installation

```bash
# Repository klonen
git clone https://github.com/Asimatasert/t-pgsql.git
cd t-pgsql

# Ausführbar machen
chmod +x t-pgsql

# Zum PATH hinzufügen (optional)
sudo ln -s $(pwd)/t-pgsql /usr/local/bin/t-pgsql
```

### Anforderungen

- PostgreSQL-Client (`pg_dump`, `pg_restore`, `psql`)
- SSH-Client (für Remote-Operationen)
- Bash 4.0+

## Schnellstart

```bash
# Dump von lokaler Datenbank
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump von Remote-Server
./t-pgsql dump --from "ssh://user@192.168.1.100/postgres@localhost/mydb" --from-password-file .secrets/remote.pass

# Dump wiederherstellen
./t-pgsql restore --file ./dumps/mydb_20250101.tar.gz --to "postgres@localhost/mydb_copy" --to-password-file .secrets/local.pass

# Klonen mit einzelnem Befehl (dump + restore)
./t-pgsql clone --from "ssh://user@server/postgres@localhost/prod" --to "postgres@localhost/dev" --from-password-file .secrets/prod.pass --to-password-file .secrets/local.pass --force
```

---

## Verbindungsformate

### Lokale Verbindung

```
[db_user@]host[:port]/database
```

| Beispiel | Beschreibung |
|----------|--------------|
| `localhost/mydb` | Standardbenutzer mit localhost |
| `postgres@localhost/mydb` | Mit postgres-Benutzer |
| `postgres@localhost:5432/mydb` | Mit explizitem Port |

### SSH (Remote) Verbindung

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Beispiel | Beschreibung |
|----------|--------------|
| `ssh://user@192.168.1.100/mydb` | Einfaches Format (db: localhost, user: postgres) |
| `ssh://user@192.168.1.100/postgres@localhost/mydb` | Mit DB-Benutzer |
| `ssh://user@server:2222/postgres@localhost:5433/prod` | Benutzerdefinierte Ports |

---

## Befehle

### dump

Erstellt eine Datenbanksicherung.

```bash
./t-pgsql dump --from <verbindung> [optionen]
```

**Beispiele:**

```bash
# Einfacher Dump
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Bestimmte Tabellen ausschließen
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-table "logs,sessions,temp_data"

# Nur bestimmte Tabellen einschließen
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --only-table "users,orders,products"
```

---

### restore

Stellt eine Dump-Datei in einer Datenbank wieder her.

```bash
./t-pgsql restore --to <verbindung> [--file <datei>] [optionen]
```

**Beispiele:**

```bash
# Neuesten Dump wiederherstellen (automatische Suche)
./t-pgsql restore --to "postgres@localhost/mydb" --to-password-file .secrets/local.pass

# Bestimmte Datei wiederherstellen
./t-pgsql restore \
  --file ./dumps/mydb_20250130.tar.gz \
  --to "postgres@localhost/mydb_copy" \
  --to-password-file .secrets/local.pass

# Vorhandene DB löschen und neu erstellen
./t-pgsql restore \
  --file ./dumps/prod_backup.tar.gz \
  --to "postgres@localhost/test_db" \
  --to-password-file .secrets/local.pass \
  --force
```

---

### clone

Führt dump + restore in einem einzelnen Befehl aus.

```bash
./t-pgsql clone --from <quelle> --to <ziel> [optionen]
```

**Beispiele:**

```bash
# Von Remote nach Lokal klonen
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force

# Zu mehreren Zielen klonen
./t-pgsql clone \
  --from "ssh://user@prod/postgres@localhost/app" \
  --to "postgres@localhost/dev1" \
  --to "postgres@localhost/dev2" \
  --to "postgres@localhost/test" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force
```

---

### fetch

Lädt eine vorhandene Dump-Datei vom Remote herunter (ohne neuen Dump zu erstellen).

```bash
./t-pgsql fetch --from <verbindung> --from-file [muster] [optionen]
```

---

### list

Listet Dump-Dateien auf.

```bash
./t-pgsql list [--output <verzeichnis>]
```

---

### clean

Bereinigt alte Dump-Dateien.

```bash
./t-pgsql clean [--output <verzeichnis>] [--keep <N>]
```

---

## Batch-System

Speichern Sie wiederholte Operationen und führen Sie sie mit einem einzigen Befehl aus.

### Job speichern

```bash
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force \
  --save mein_sync
```

### Jobs ausführen

```bash
# Einzelnen Job ausführen
./t-pgsql --batch mein_sync

# Alle Jobs ausführen
./t-pgsql --batch all

# Bei Fehler fortfahren
./t-pgsql --batch all --continue-on-error
```

### jobs.yaml Format

t-pgsql unterstützt drei Job-Formate: profilbasiert, Verbindungsstring und Legacy-Args.

#### Profilbasiertes Format (Empfohlen)

```yaml
# Profile - wiederverwendbare Verbindungskonfigurationen
profiles:
  produktion:
    type: ssh
    ssh_user: deploy
    ssh_host: prod.example.com
    db_user: postgres
    password_file: ~/.secrets/prod.pass

  lokal:
    type: local
    db_user: postgres
    password_file: ~/.secrets/local.pass

# Jobs mit Profilen
jobs:
  prod-zu-lokal:
    command: clone
    from:
      profile: produktion
      database: myapp
    to:
      profile: lokal
      database: myapp_dev
    force: true
    exclude_data: "audit.*,logs"
```

#### Verbindungsstring-Format

```yaml
jobs:
  schnell-backup:
    command: dump
    from: ssh://user@server/postgres@localhost/mydb
    from_password_file: ~/.secrets/prod.pass
    keep: 7
```

---

## Passwortverwaltung

### 1. Passwortdatei (Empfohlen)

```bash
# .secrets-Verzeichnis erstellen
mkdir -p .secrets
chmod 700 .secrets

# Passwortdatei erstellen (ohne Zeilenumbruch)
echo -n "dein_passwort" > .secrets/db.pass
chmod 600 .secrets/db.pass

# Zu .gitignore hinzufügen
echo ".secrets/" >> .gitignore
```

### 2. Umgebungsvariable

```bash
export T_PGSQL_PASSWORD="geheim"
./t-pgsql dump --from "postgres@localhost/mydb"
```

### 3. Interaktive Eingabe

Wenn kein Passwort angegeben wird, wird sicher vom Terminal abgefragt.

---

## Wichtige Parameter

| Parameter | Beschreibung |
|-----------|--------------|
| `--from <conn>` | Quell-Verbindungsstring |
| `--to <conn>` | Ziel-Verbindungsstring |
| `--password-file <file>` | Datei mit Passwort |
| `--exclude-table <tables>` | Auszuschließende Tabellen |
| `--only-table <tables>` | Nur diese Tabellen |
| `--force` | Vorhandene DB löschen und neu erstellen |
| `--verbose` | Detaillierte Ausgabe |
| `--dry-run` | Zeigen ohne Ausführen |

---

## Lizenz

MIT-Lizenz

## Mitwirken

Pull Requests sind willkommen.
