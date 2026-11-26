# t-pgsql

Herramienta CLI avanzada para respaldar, restaurar y sincronizar bases de datos PostgreSQL.

**Documentación:** [English](README.md) | [Русский](README_RU.md) | [Deutsch](README_DE.md)

## Características

### Operaciones principales
- **Dump**: Respaldo desde base de datos local o remota
- **Restore**: Restaura un respaldo en una base de datos local o remota (seguro por defecto con `--force`)
- **Clone**: Un solo comando de dump + restore (sincronización completa)
- **Upgrade**: Migración lógica de versión mayor (por ejemplo, PG16 → PG18) con globales
- **Fetch**: Descarga un dump existente desde un servidor remoto
- **Streaming**: Clonación por tubería directa sin archivos temporales (`--stream`)

### Lotes y automatización
- **Trabajos por lotes**: Ejecuta múltiples trabajos desde `jobs.yaml`
- **Ejecución en paralelo**: Ejecuta trabajos de forma concurrente (`--parallel N`)
- **Filtrado de trabajos**: Ejecuta trabajos específicos (`--only-jobs`) u omite trabajos (`--exclude-jobs`)
- **Bot de Telegram**: Dispara y monitoriza respaldos desde un chat (comando `bot`)
- **Notificaciones**: Telegram, Slack, Webhook, Email con soporte de resumen

### Gestión de datos
- **Enmascaramiento de datos**: Anonimiza datos sensibles tras la restauración (`--mask`)
- **Filtrado de tablas**: Incluye/excluye tablas o esquemas
- **Retención GFS**: Política de rotación de respaldos Grandfather-Father-Son (Abuelo-Padre-Hijo)
- **Seguro respecto a codificación**: Preserva la codificación/locale de la base de datos de origen al restaurar

### Seguridad y fiabilidad
- **Restauración segura**: `--force` restaura en una base de datos temporal y la intercambia solo si tiene éxito — una restauración fallida/corrupta nunca destruye los datos existentes
- **Comprobaciones de salud**: Verifica las conexiones antes de las operaciones
- **Túnel SSH**: Acceso seguro a bases de datos remotas
- **Seguridad de contraseñas**: Se mantiene fuera del argv del proceso (`.pgpass`/entorno); se lee desde archivos o desde el entorno
- **Control de transferencia**: Límite de ancho de banda (`--bwlimit`) y reintentos (`--retries`) para enlaces grandes/inestables
- **Metadatos**: Registra tiempos, origen y detalles de la operación

## Instalación

### Instalación rápida (Recomendada)

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
# Descarga el último paquete .deb
curl -LO https://github.com/Asimatasert/t-pgsql/releases/latest/download/t-pgsql_latest_all.deb
sudo dpkg -i t-pgsql_latest_all.deb
```

### Arch Linux (AUR)

```bash
# Usando yay
yay -S t-pgsql

# O manualmente
git clone https://github.com/Asimatasert/t-pgsql.git
cd t-pgsql/arch
makepkg -si
```

### Instalación manual

```bash
# Clona el repositorio
git clone https://github.com/Asimatasert/t-pgsql
cd t-pgsql

# Instala con make
sudo make install

# O instalación manual
chmod +x t-pgsql
sudo ln -s $(pwd)/t-pgsql /usr/local/bin/t-pgsql
```

### Autocompletado del shell

El autocompletado se instala automáticamente con los gestores de paquetes. Para configuración manual:

```bash
# Zsh
cp completions/_t-pgsql ~/.zsh/completions/

# Bash
cp completions/t-pgsql.bash /etc/bash_completion.d/t-pgsql

# Fish
cp completions/t-pgsql.fish ~/.config/fish/completions/
```

### Página de manual

```bash
man t-pgsql
```

### Requisitos

- Cliente de PostgreSQL (`pg_dump`, `pg_restore`, `psql`)
- Cliente SSH (para operaciones remotas)
- Bash 4.0+
- Opcional: `pv` (para el búfer de streaming)

## Docker

Se incluye un `Dockerfile`. La versión mayor del cliente de PostgreSQL es un argumento de compilación —
configúrala con la versión del servidor **de destino** para que los dumps entre versiones usen las
herramientas correctas (por ejemplo, hacer dump de un servidor PG16 para restaurar en PG18 → compila con `PG_MAJOR=18`).

```bash
# Compila con la versión de cliente deseada
docker build --build-arg PG_MAJOR=18 -t t-pgsql:18 .

# Dump puntual (monta un volumen de dumps)
docker run --rm -v "$PWD/dumps:/data/dumps" \
  t-pgsql:18 dump --from "postgres@db.example.com/mydb" --output /data/dumps -y

# Ejecuta el bot de Telegram como un servicio (ver docker-compose.yml)
docker compose up -d --build
```

Monta tu `jobs.yaml`, los archivos de contraseñas y la clave SSH en `/data` (y la clave SSH
bajo `/home/tpgsql/.ssh`). La imagen se ejecuta como un usuario no root.

## Actualizaciones de versión mayor (lógicas)

El comando `upgrade` realiza una migración **lógica** de versión mayor (por ejemplo, PG16 → PG18):
migra los globales del clúster (roles, tablespaces), comprueba que el destino no sea una versión mayor
anterior y luego clona la base de datos.

```bash
# Ejecuta desde un host/contenedor cuyo pg_dump coincida con la versión de DESTINO (18 aquí).
t-pgsql upgrade \
  --from "postgres@old-16-host:5432/appdb" \
  --to   "postgres@new-18-host:5432/appdb" -y

# O añade globales a un clone simple y elige explícitamente las herramientas de cliente:
t-pgsql clone --from ... --to ... --globals --pg-bindir /usr/lib/postgresql/18/bin
```

**Alcance honesto:** este es el camino de dump/restore, apto para bases de datos pequeñas/medianas o
para una reconstrucción lógica limpia. Para clústeres grandes o migraciones con mínimo tiempo de
inactividad, `pg_upgrade` (in situ) y la replicación lógica siguen siendo las herramientas mejor
establecidas — este comando no las reemplaza. La migración de globales funciona para orígenes
local/TCP y SSH, y se aplica a cada destino `--to`.

## Desarrollo (fuentes modulares)

`t-pgsql` es un **único archivo generado** ensamblado a partir de pequeños módulos bajo `src/`
(header, globals, logging, dump, restore, clone, upgrade, batch, bot, args, main, …),
concatenados en el orden indicado en `src/build.manifest`.

```bash
# Edita un módulo y luego reconstruye el archivo único:
$EDITOR src/55-dump.sh
./build.sh            # o: make build

# Verifica que el t-pgsql confirmado esté sincronizado con src/ (CI lo ejecuta):
./build.sh --check    # o: make check-build
```

**No** edites `t-pgsql` a mano — los cambios pertenecen a `src/`. La distribución no cambia:
se sigue instalando/enviando un único archivo ejecutable (el empaquetado, el autocompletado y el
comportamiento de `SCRIPT_DIR` son idénticos). Como todo se ejecuta en un único proceso Bash con un
espacio de nombres global compartido, dividir el archivo es un cambio puramente de organización del
código — no hay acoplamiento en tiempo de ejecución ni preocupación por la sincronización.

## Inicio rápido

```bash
# Dump desde una base de datos local
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump desde un servidor remoto
./t-pgsql dump --from "ssh://user@192.0.2.20/postgres@localhost/mydb" --from-password-file .secrets/remote.pass

# Restaura un dump
./t-pgsql restore --file ./dumps/mydb_20250101.tar.gz --to "postgres@localhost/mydb_copy" --to-password-file .secrets/local.pass

# Clona con un solo comando (dump + restore)
./t-pgsql clone --from "ssh://user@server/postgres@localhost/prod" --to "postgres@localhost/dev" --from-password-file .secrets/prod.pass --to-password-file .secrets/local.pass --force
```

---

## Formatos de conexión

### Conexión local

```
[db_user@]host[:port]/database
```

| Ejemplo | Descripción |
|---------|-------------|
| `localhost/mydb` | Usuario por defecto con localhost |
| `postgres@localhost/mydb` | Con el usuario postgres |
| `postgres@localhost:5432/mydb` | Con puerto explícito |
| `dbadmin@localhost/test123` | Usuario personalizado |

### Conexión SSH (remota)

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Ejemplo | Descripción |
|---------|-------------|
| `ssh://ubuntu@192.0.2.20/mydb` | Formato simple (db: localhost, usuario: postgres) |
| `ssh://ubuntu@192.0.2.20/postgres@localhost/mydb` | Con usuario de BD especificado |
| `ssh://dbadmin@192.0.2.10/postgres@localhost/appdb` | Formato completo |
| `ssh://dbadmin@server:2222/postgres@localhost:5433/prod` | Puertos personalizados |

### Estructura de la conexión

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

## Comandos

### dump

Crea un respaldo de la base de datos.

```bash
./t-pgsql dump --from <connection> [options]
```

**Ejemplos:**

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

**Salida:** `<script dir>/../data/dumps/database_YYYYMMDD_HHMMSS.tar.gz` (directorio de salida por defecto; anúlalo con `--output`)

El archivo tar contiene:
- `database_YYYYMMDD_HHMMSS.dump` - Archivo de dump de PostgreSQL (o nombre personalizado)
- `metadata.yaml` - Información de la operación

---

### restore

Restaura un archivo de dump en una base de datos.

```bash
./t-pgsql restore --to <connection> [--file <file>] [options]
```

**Ejemplos:**

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

> **Nota:** Si no se especifica `--file`, encuentra automáticamente el archivo `.tar.gz` más reciente en el directorio `--output`.

---

### clone

Realiza dump + restore en un solo comando.

```bash
./t-pgsql clone --from <source> --to <target> [options]
```

**Ejemplos:**

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

Descarga un archivo de dump existente desde el remoto (sin crear un nuevo dump).

```bash
./t-pgsql fetch --from <connection> --from-file [pattern] [options]
```

**Ejemplos:**

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

Lista los archivos de dump.

```bash
./t-pgsql list [--output <directory>]
```

**Ejemplo de salida:**

```
Dumps in: /opt/t-pgsql/data/dumps

FILE                                      SIZE DATE
---------------------------------------------------------------------------
appdb_20251230_225325.tar.gz     39MiB 2025-12-30 22:54
mydb_20251229_143022.tar.gz              15MiB 2025-12-29 14:30
```

---

### meta

Muestra la información de metadatos de un archivo de dump.

```bash
./t-pgsql meta --file <archive.tar.gz>
```

**Ejemplo de salida:**

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

Limpia archivos de dump antiguos.

```bash
./t-pgsql clean [--output <directory>] [--keep <N>]
```

---

### jobs

Lista los trabajos por lotes guardados.

```bash
./t-pgsql jobs
```

---

## Sistema de lotes

Guarda operaciones repetitivas y ejecútalas con un solo comando.

### Guardar un trabajo

Guarda cualquier comando con `--save <name>`:

```bash
./t-pgsql clone \
  --from "ssh://dbadmin@192.0.2.10/postgres@localhost/appdb" \
  --to "dbadmin@localhost/test123" \
  --from-password-file .secrets/from.pass \
  --to-password-file .secrets/to.pass \
  --force \
  --save nightly-sync
```

### Ejecutar trabajos

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

### Listar trabajos

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

Ejecuta un bot de Telegram de larga duración que te permite disparar y monitorizar respaldos desde un chat. Realiza long-polling a Telegram (`getUpdates`) y solo actúa sobre el **chat configurado** (fail-closed — sin ningún chat configurado, ignora todos los comandos).

```bash
# Token from --token, or defaults.notify.telegram in the YAML, or $TELEGRAM_BOT_TOKEN
./t-pgsql bot --yaml sync-30 --token "123456:ABC..." --cooldown 1h
```

**Comandos del chat:**

| Comando | Acción |
|---------|--------|
| `/help` | Muestra los comandos disponibles |
| `/list` | Lista los archivos YAML en el directorio del script |
| `/list <yaml>` | Lista los trabajos definidos en un YAML |
| `/backup <yaml> <job>` | Inicia un trabajo de respaldo en segundo plano e informa del resultado |

Las notificaciones de fallo incluyen un botón en línea **"Re-run Backup"**. `--cooldown` (por defecto `1h`, formato `<N>[h|m|d]`) limita la frecuencia con la que el mismo trabajo puede volver a dispararse mediante el botón o `/backup`. El id del chat y el (opcional) hilo del foro se leen de `defaults.notify.telegram` del YAML o de `TELEGRAM_CHAT_ID` / `TELEGRAM_THREAD_ID`.

> Ejecútalo bajo un gestor de procesos (systemd, `docker compose`, `tmux`) — consulta la sección [Docker](#docker) para un servicio de compose.

---

### Formato de jobs.yaml

t-pgsql admite tres formatos de trabajo: basado en perfiles, cadena de conexión y argumentos heredados.

#### Formato basado en perfiles (Recomendado)

Define perfiles de conexión reutilizables y valores por defecto para reducir la repetición:

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

#### Formato de cadena de conexión

Usa cadenas de conexión directas para trabajos más simples:

```yaml
jobs:
  quick-backup:
    command: dump
    from: ssh://user@server/postgres@localhost/mydb
    from_password_file: ~/.secrets/prod.pass
    output: ./dumps
    keep: 7
```

#### Formato de argumentos heredado (Compatible con versiones anteriores)

El formato antiguo sigue funcionando para mantener la compatibilidad:

```yaml
jobs:
  legacy_job:
    command: clone
    args: --from 'ssh://user@server/postgres@localhost/db' --to 'postgres@localhost/db' --force
```

#### Opciones de trabajo

| Opción | Descripción |
|--------|-------------|
| `force` | Elimina y recrea la base de datos existente |
| `verbose` | Muestra salida detallada |
| `from_keep` | Número de dumps a conservar en el origen |
| `keep` | Número de dumps locales a conservar |
| `dump_name` | Nombre de archivo de dump personalizado (sin marca de tiempo) |
| `skip_if_recent` | Omite si existe un dump dentro del periodo (por ejemplo, `24h`, `1d`, `today`) |
| `output` | Directorio de salida para los dumps |
| `exclude_table` | Tablas a excluir por completo |
| `exclude_data` | Tablas cuyos datos excluir (admite el comodín `schema.*`) |
| `exclude_schema` | Esquemas a excluir |

---

## Características avanzadas

### Retención GFS (Grandfather-Father-Son)

Política automatizada de rotación de respaldos que conserva respaldos diarios, semanales, mensuales y anuales:

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

### Enmascaramiento de datos

Anonimiza datos sensibles tras la restauración para entornos de desarrollo/pruebas. El enmascaramiento se ejecuta **después** de la restauración (por lo que no es compatible con `--stream`). Es a prueba de fallos: si `--mask` no coincidió con **nada** — o si cualquier sentencia de enmascaramiento produce un error — la operación **falla** en lugar de reportar como éxito una copia sin enmascarar.

- `--mask-tables` enmascara automáticamente un conjunto fijo de columnas conocidas como sensibles (`email`, `phone`, `password`, `password_hash`, `address`, `ssn`, `credit_card`) — pero solo las columnas que realmente **existen** en cada tabla base actualizable nombrada. Un nombre de tabla simple que coincida con varios esquemas enmascara la tabla en cada esquema (con esquema cualificado). Los identificadores siempre se entrecomillan, por lo que los nombres de tabla con palabras reservadas / mayúsculas y minúsculas funcionan.
- `--mask-rules` aplica tus propias expresiones SQL desde un archivo JSON (ver más abajo).

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

**Formato de mask-rules.json:**

```json
{
  "users.email": "CONCAT(LEFT(email, 2), '***@example.com')",
  "users.phone": "'555-***-****'",
  "users.name": "CONCAT('User_', id)",
  "customers.address": "'[REDACTED]'",
  "orders.notes": "NULL"
}
```

**Campos enmascarados automáticamente** (al usar `--mask-tables`):
- `email` → `ab***@***.com`
- `phone` → `***-***-****`
- `password` / `password_hash` → `********` / `MASKED`
- `address` → `[MASKED]`
- `ssn` → `***-**-****`
- `credit_card` → `****-****-****-****`

### Comprobaciones de salud

Verifica las conexiones de base de datos antes de las operaciones:

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

### Modo streaming

Transferencia por tubería directa sin crear archivos temporales (más rápido, menos espacio en disco):

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

> **Nota:** El modo streaming no crea archivos de dump locales. Usa un clone normal si necesitas conservar respaldos.

---

## Gestión de contraseñas

Las contraseñas no deberían aparecer en el historial de bash. Hay 3 métodos:

### 1. Archivo de contraseña (Recomendado)

#### Configurar el directorio .secrets

```bash
# Create .secrets directory
mkdir -p .secrets
chmod 700 .secrets

# Add to .gitignore (IMPORTANT!)
echo ".secrets/" >> .gitignore
```

#### Crear archivos de contraseña

```bash
# IMPORTANT: Use -n flag to avoid newline at end of file
echo -n "your_password_here" > .secrets/db.pass

# Set secure permissions (read/write only for owner)
chmod 600 .secrets/db.pass

# Verify no newline exists
cat .secrets/db.pass | xxd | tail -1
# Should NOT end with '0a' (newline character)
```

#### Estructura recomendada de .secrets

```
.secrets/
├── from.pass      # Source database password
├── to.pass        # Target database password
├── prod.pass      # Production database password
├── dev.pass       # Development database password
└── ssh.key        # SSH private key (optional)
```

#### Formato del archivo de contraseña

| Requisito | Descripción |
|-------------|-------------|
| **Sin salto de línea** | Usa `echo -n` para evitar el salto de línea final |
| **Texto plano** | Solo la contraseña, nada más |
| **UTF-8** | Usa codificación UTF-8 |
| **Permisos** | `chmod 600` (solo lectura/escritura del propietario) |

#### Ejemplos de uso

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

### 2. Variable de entorno

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

| Variable de entorno | Descripción |
|---------------------|-------------|
| `T_PGSQL_PASSWORD` | Contraseña para ambas conexiones |
| `T_PGSQL_FROM_PASSWORD` | Contraseña de la conexión de origen |
| `T_PGSQL_TO_PASSWORD` | Contraseña de la conexión de destino |

### 3. Solicitud interactiva

Si no se especifica ninguna contraseña, la solicita de forma segura desde la terminal:

```bash
./t-pgsql dump --from "postgres@localhost/mydb"
# FROM password: ********  (input is hidden)
```

> **Nota:** La solicitud interactiva solo funciona en terminal (TTY). Para scripts y trabajos cron, usa archivos de contraseña o variables de entorno.

### Orden de prioridad de contraseñas

Cuando hay varias fuentes de contraseña disponibles, t-pgsql usa esta prioridad:

1. **Parámetro directo** (`--password`, `--from-password`, `--to-password`)
2. **Variable de entorno** (`T_PGSQL_PASSWORD`, etc.)
3. **Archivo de contraseña** (`--password-file`, etc.)
4. **Solicitud interactiva** (si hay TTY disponible)

### Buenas prácticas de seguridad

| Práctica | Descripción |
|----------|-------------|
| Usa `.gitignore` | Nunca confirmes archivos de contraseña en git |
| Usa `chmod 600` | Restringe el acceso al archivo solo al propietario |
| Usa `chmod 700` | Restringe el acceso al directorio solo al propietario |
| Evita `--password` | No uses la contraseña directa en la línea de comandos |
| Usa archivos separados | Usa archivos diferentes para entornos de prod/dev |
| Rota las contraseñas | Actualiza regularmente los archivos de contraseña |

---

## Archivo de configuración (`--config`)

`--config <file>` carga **valores por defecto por ejecución** para un solo comando (distinto del YAML de trabajos configurado con `--yaml`). Es un simple archivo `key: value`; **las opciones de la CLI y las variables de entorno siempre prevalecen** sobre el archivo.

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

Las claves admitidas reflejan las opciones: `from`, `to`, `password`/`from_password`/`to_password`, `password_file`/`from_password_file`/`to_password_file`, `output`, `keep`, `from_keep`, `compress`, `exclude_table`/`exclude_data`/`exclude_schema`, `only_table`/`only_schema`, `notify` (repetible) y los booleanos `verbose`/`force`/`sudo`. `~` se expande solo para las claves de tipo ruta — nunca para contraseñas ni cadenas de conexión.

---

## Referencia completa de parámetros

### Parámetros de conexión

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--from <conn>` | Cadena de conexión de la base de datos de origen | - | Sí (dump/clone) | `postgres@localhost/mydb` |
| `--to <conn>` | Cadena de conexión de la base de datos de destino (repetible para varios destinos) | - | Sí (restore/clone) | `ssh://user@host/db` |

**Formatos de cadena de conexión:**
- Local: `[user@]host[:port]/database`
- SSH: `ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database`

### Parámetros de contraseña

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--password <pass>` | Contraseña para origen y destino | - | No | `mysecret` |
| `--from-password <pass>` | Contraseña solo para la conexión de origen | - | No | `srcpass` |
| `--to-password <pass>` | Contraseña solo para la conexión de destino | - | No | `dstpass` |
| `--password-file <file>` | Lee la contraseña desde un archivo (ambas conexiones) | - | No | `.secrets/db.pass` |
| `--from-password-file <file>` | Lee la contraseña de origen desde un archivo | - | No | `.secrets/from.pass` |
| `--to-password-file <file>` | Lee la contraseña de destino desde un archivo. Repetible — emparejado con cada `--to` por posición, o dado una vez para aplicarse a todos los destinos. | - | No | `.secrets/to.pass` |
| `--config <file>` | Archivo de valores por defecto por ejecución (ver [Archivo de configuración](#archivo-de-configuración-config)) | - | No | `db.conf` |

**Variables de entorno:**
- `T_PGSQL_PASSWORD` - Contraseña para ambas conexiones
- `T_PGSQL_FROM_PASSWORD` - Contraseña de origen
- `T_PGSQL_TO_PASSWORD` - Contraseña de destino

### Parámetros de filtrado

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--exclude-table <tables>` | Tablas separadas por comas a excluir | - | No | `logs,sessions,temp` |
| `--exclude-schema <schemas>` | Esquemas separados por comas a excluir | - | No | `audit,temp` |
| `--exclude-data <tables>` | Excluye los datos pero conserva la estructura (admite el comodín `schema.*`) | - | No | `audit.*,logs` |
| `--only-table <tables>` | Incluye solo estas tablas | - | No | `users,orders` |
| `--only-schema <schemas>` | Incluye solo estos esquemas | - | No | `public,app` |

### Parámetros de compresión

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--compress <type>` | Algoritmo de compresión | `gzip` | No | `zstd`, `xz`, `bzip2`, `none` |
| `--compress-level <1-9>` | Nivel de compresión | `6` | No | `9` |
| `--pg-compress-level <0-9>` | Compresión interna de pg_dump | `6` | No | `0` (sin compresión) |
| `--compress-where <where>` | Para dumps SSH: ejecutar zstd/xz/bzip2 en el host `source` antes de la copia, o en el `target` después. `source` transfiere un archivo mucho más pequeño por enlaces lentos; recurre a `target` si la herramienta falta en el origen | `target` | No | `source` |

### Parámetros de almacenamiento

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--output <dir>` | Directorio de salida para los dumps | `<script dir>/../data/dumps` | No | `/backups/daily` |
| `--keep <N>` | Número de dumps locales a conservar | `-1` (todos) | No | `7`, `0` (eliminar), `-1` (todos) |
| `--from-keep <N>` | Número de dumps a conservar en el origen | `1` | No | `3`, `0` (eliminar), `-1` (todos) |
| `--from-stale <time>` | Con `--from-keep 0`: antes del dump, purgar del directorio de staging del origen los dumps de este job más antiguos que `<time>` (las ejecuciones fallidas nunca llegan a la limpieza normal) | `72h` | No | `48h`, `2d`, `0` (desactivado) |
| `--dump-name <name>` | Nombre de archivo de dump personalizado (sin marca de tiempo) | Nombre de la base de datos | No | `myapp-backup` |
| `--skip-if-recent <time>` | Omite si existe un dump dentro del periodo | - | No | `24h`, `12h`, `1d`, `today` |
| `--file <path>` | Archivo de dump específico para restaurar | - | No | `./dumps/backup.tar.gz` |
| `--from-file [pattern]` | Obtiene un dump existente (sin valor = el más reciente) | - | No | `mydb_*.dump` |

### Parámetros de retención (GFS - Grandfather-Father-Son)

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--retention` | Habilita la política de retención GFS | `false` | No | - |
| `--retention-daily <N>` | Respaldos diarios a conservar | `7` | No | `14` |
| `--retention-weekly <N>` | Respaldos semanales a conservar | `4` | No | `8` |
| `--retention-monthly <N>` | Respaldos mensuales a conservar | `12` | No | `24` |
| `--retention-yearly <N>` | Respaldos anuales a conservar | `3` | No | `5` |

### Parámetros de comprobación de salud

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--health-check` | Comprueba la base de datos antes de la operación | `true` | No | - |
| `--health-check-after` | Comprueba la base de datos después de la operación | `false` | No | - |
| `--no-health-check` | Deshabilita todas las comprobaciones de salud | `false` | No | - |
| `--health-check-fail` | Aborta si falla la comprobación de salud | `false` | No | - |

### Parámetros de notificación

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--notify <channel>` | Canal de notificación (repetible) | - | No | `telegram:TOKEN:CHAT` |
| `--notify-on-error` | Notifica solo en caso de errores | `false` | No | - |
| `--notify-summary` | Envía un resumen tras el lote | `false` | No | - |

**Canales admitidos:** `telegram`, `slack:URL`, `webhook:URL`, `email:ADDRESS`

### Parámetros de enmascaramiento de datos

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--mask` | Habilita el enmascaramiento de datos | `false` | No | - |
| `--mask-rules <file>` | Archivo JSON con reglas de enmascaramiento | - | No | `mask-rules.json` |
| `--mask-tables <tables>` | Tablas a las que aplicar el enmascaramiento | - | No | `users,customers` |

### Parámetros de streaming

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--stream` | Modo streaming (sin archivos temporales); canaliza `pg_dump \| pg_restore` directamente | `false` | No | - |
| `--stream-buffer <MB>` | Tamaño del búfer en tránsito en megabytes (`pv`) | `64` | No | `128` |

> **Nota de seguridad:** A diferencia de cualquier otro camino, `--stream` transporta el comando `pg_restore` remoto (con su preámbulo `.pgpass`) en el argv de ssh, por lo que la credencial es brevemente visible para `ps` en el host remoto durante la duración del stream. Usa `--sudo` (autenticación peer) o el clone sin streaming si eso importa. `--mask` no es compatible con `--stream` (el enmascaramiento se ejecuta tras una restauración completa).

### Parámetros de transferencia y fiabilidad

Se aplican a las transferencias SSH/scp (y a la tubería `--stream` cuando `pv` está instalado).

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--bwlimit <rate>` | Limita el ancho de banda de la transferencia. `10m` = 10 MB/s, `500k` = 500 KB/s, número simple = KB/s. scp usa su `-l`; el streaming usa `pv -L` (requiere `pv`). | ilimitado | No | `10m` |
| `--retries <N>` | Intentos de reintento adicionales para una transferencia scp fallida (backoff aproximadamente exponencial) | `0` | No | `3` |

### Parámetros de lote

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--yaml <name>` | Archivo YAML de trabajos. Un nombre simple se resuelve a `<script-dir>/<name>.yaml`; un valor que contenga `/` o termine en `.yaml` se usa tal cual | `<script-dir>/jobs.yaml` | No | `sync-30`, `./jobs/prod.yaml` |
| `--save <name>` | Guarda el comando + opciones actual como un trabajo (en lugar de ejecutarlo) | - | No | `daily_backup` |
| `--batch <name\|all>` | Ejecuta el/los trabajo(s) guardado(s); equivale a `t-pgsql batch <name\|all>` | - | No | `daily_backup`, `all` |
| `--parallel <N>` | Número de trabajos a ejecutar en paralelo | `1` | No | `4` |
| `--continue-on-error` | Continúa el lote aunque falle un trabajo | `false` | No | - |
| `--only-jobs <jobs>` | Ejecuta solo estos trabajos (separados por comas) | - | No | `job1,job2` |
| `--exclude-jobs <jobs>` | Omite estos trabajos (separados por comas) | - | No | `slow_job` |
| `--only <jobs>` | Alias obsoleto de `--only-jobs` | - | No | `job1,job2` |
| `--exclude <jobs>` | Alias obsoleto de `--exclude-jobs` | - | No | `slow_job` |
| `--skip-if-recent <time>` | Omite un trabajo si existe un dump dentro de la ventana | - | No | `24h`, `30m`, `2d`, `today` |

### Parámetros de migración (`upgrade` / `clone`)

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--globals` | Migra también los globales del clúster (roles, tablespaces) mediante `pg_dumpall --globals-only`; se toleran los roles preexistentes. Activado a la fuerza por `upgrade`. | `false` | No | - |
| `--pg-bindir <dir>` | Antepone `<dir>` al `PATH` para elegir una versión específica del cliente de PostgreSQL para `pg_dump`/`pg_restore`/`psql`/`createdb`/`pg_dumpall` **locales** (no SSH-remotos) | - | No | `/usr/lib/postgresql/18/bin` |

### Parámetros del bot

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `--token <token>` | Token del bot de Telegram (si no, se lee de `defaults.notify.telegram` en el YAML, o de `TELEGRAM_BOT_TOKEN`) | - | No | `123:ABC...` |
| `--cooldown <time>` | Intervalo mínimo entre ejecuciones del mismo trabajo disparadas por el botón o `/backup`. Formato `<N>[h\|m\|d]`. | `1h` | No | `30m`, `2d` |

### Parámetros generales

| Parámetro | Descripción | Por defecto | Obligatorio | Ejemplo |
|-----------|-------------|---------|----------|---------|
| `-f, --force` | Elimina y recrea la base de datos existente | `false` | No | - |
| `-v, --verbose` | Muestra salida detallada | `false` | No | - |
| `-q, --quiet` | Salida mínima | `false` | No | - |
| `-y, --yes` | Omite todas las confirmaciones | `false` | No | - |
| `--dry-run` | Muestra lo que se haría sin ejecutarlo | `false` | No | - |
| `--sudo` | Usa sudo para las operaciones de base de datos | `false` | No | - |
| `--log <file>` | Escribe los registros en un archivo | - | No | `/var/log/t-pgsql.log` |
| `--log-level <level>` | Nivel de detalle de los registros | `info` | No | `debug`, `warn`, `error` |
| `--no-meta` | No escribe metadatos en los archivos | `false` | No | - |
| `-h, --help` | Muestra el mensaje de ayuda | - | No | - |
| `--version` | Muestra el número de versión | - | No | - |

### Variables de entorno

| Variable | Descripción |
|----------|-------------|
| `T_PGSQL_PASSWORD` | Contraseña para origen y destino |
| `T_PGSQL_FROM_PASSWORD` | Contraseña de la conexión de origen |
| `T_PGSQL_TO_PASSWORD` | Contraseña de la conexión de destino |
| `T_PGSQL_OUTPUT_DIR` | Directorio de salida por defecto para los dumps (anulado por `--output`) |
| `PGCONNECT_TIMEOUT` | Tiempo de espera de conexión de libpq en segundos (por defecto `10`) |
| `TELEGRAM_BOT_TOKEN` | Resuelve el canal simple `--notify telegram` y el token del `bot` |
| `TELEGRAM_CHAT_ID` | Id del chat para el canal simple `--notify telegram` |
| `TELEGRAM_THREAD_ID` | Id opcional del hilo de tema de foro para las notificaciones de Telegram |

> Las contraseñas pasadas mediante variables de entorno (o acotadas en línea, por ejemplo `T_PGSQL_PASSWORD=secret t-pgsql ...`) nunca se colocan en el argv de un proceso, por lo que no son visibles para `ps`.

### Valores por defecto internos

| Variable | Valor por defecto | Descripción |
|----------|---------------|-------------|
| `FROM_DB_USER` | `postgres` | Usuario de base de datos por defecto |
| `FROM_DB_HOST` | `localhost` | Host de base de datos por defecto |
| `FROM_DB_PORT` | `5432` | Puerto de PostgreSQL por defecto |
| `FROM_SSH_PORT` | `22` | Puerto SSH por defecto |

---

## Ejemplos prácticos

### Respaldo diario

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

### Sincronización de entorno de desarrollo

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

### Despliegue en múltiples entornos

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

### Excluir tablas grandes

```bash
./t-pgsql dump \
  --from "postgres@localhost/analytics" \
  --password-file .secrets/db.pass \
  --exclude-data "raw_events,page_views,click_stream" \
  --output ./dumps
```

---

## Estructura de archivos

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

## Resolución de problemas

### Error de conexión SSH

```bash
# Test SSH access
ssh dbadmin@192.0.2.10 "echo ok"

# Run with verbose mode
./t-pgsql dump --from "ssh://..." -v
```

### Error de contraseña

```bash
# Check password file
cat .secrets/db.pass | xxd  # Should have no newline

# Fix it
echo -n "password" > .secrets/db.pass
```

### Error: la base de datos ya existe

```bash
# Use --force to drop existing DB
./t-pgsql restore --to "..." --force
```

### Permiso denegado

```bash
# Password file permissions
chmod 600 .secrets/*.pass
```

---

## Licencia

Licencia MIT

## Contribuciones

Se agradecen las pull requests.
