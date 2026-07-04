# t-pgsql

Продвинутый инструмент командной строки для резервного копирования, восстановления и синхронизации баз данных PostgreSQL.

**Документация:** [English](README.md) | [Español](README_ES.md) | [Deutsch](README_DE.md)

## Возможности

### Основные операции
- **Dump**: Резервное копирование из локальной или удалённой базы данных
- **Restore**: Восстановление резервной копии в локальную или удалённую базу данных (безопасно по умолчанию при `--force`)
- **Clone**: Одна команда dump + restore (полная синхронизация)
- **Upgrade**: Логическая миграция между мажорными версиями (например, PG16 → PG18) с глобальными объектами
- **Fetch**: Загрузка существующего дампа с удалённого сервера
- **Streaming**: Прямой клон через канал без временных файлов (`--stream`)

### Пакетная обработка и автоматизация
- **Пакетные задания**: Запуск нескольких заданий из `jobs.yaml`
- **Параллельное выполнение**: Запуск заданий одновременно (`--parallel N`)
- **Фильтрация заданий**: Запуск конкретных заданий (`--only-jobs`) или пропуск заданий (`--exclude-jobs`)
- **Telegram-бот**: Запуск и мониторинг резервных копий из чата (команда `bot`)
- **Уведомления**: Telegram, Slack, Webhook, Email с поддержкой сводки

### Управление данными
- **Маскирование данных**: Анонимизация конфиденциальных данных после восстановления (`--mask`)
- **Фильтрация таблиц**: Включение/исключение таблиц или схем
- **GFS-хранение**: Политика ротации резервных копий «дед-отец-сын»
- **Безопасность кодировки**: Сохраняет кодировку/локаль исходной базы данных при восстановлении

### Безопасность и надёжность
- **Безопасное восстановление**: `--force` восстанавливает во временную базу данных и подменяет её только в случае успеха — неудачное/повреждённое восстановление никогда не уничтожает существующие данные
- **Проверки работоспособности**: Проверка соединений перед операциями
- **SSH-туннель**: Безопасный доступ к удалённым базам данных
- **Безопасность паролей**: Не попадают в argv процесса (`.pgpass`/env); читаются из файлов или окружения
- **Контроль передачи**: Ограничение полосы пропускания (`--bwlimit`) и повторные попытки (`--retries`) для больших/нестабильных каналов
- **Метаданные**: Отслеживание времени, источника и деталей операции

## Установка

### Быстрая установка (рекомендуется)

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

### Ручная установка

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

### Автодополнение оболочки

Автодополнения устанавливаются автоматически с помощью пакетных менеджеров. Для ручной настройки:

```bash
# Zsh
cp completions/_t-pgsql ~/.zsh/completions/

# Bash
cp completions/t-pgsql.bash /etc/bash_completion.d/t-pgsql

# Fish
cp completions/t-pgsql.fish ~/.config/fish/completions/
```

### Man-страница

```bash
man t-pgsql
```

### Требования

- Клиент PostgreSQL (`pg_dump`, `pg_restore`, `psql`)
- SSH-клиент (для удалённых операций)
- Bash 4.0+
- Опционально: `pv` (для буфера потоковой передачи)

## Docker

В комплект входит `Dockerfile`. Мажорная версия клиента PostgreSQL задаётся аргументом сборки —
установите её равной версии вашего **целевого** сервера, чтобы кросс-версионные дампы использовали правильные
инструменты (например, дамп сервера PG16 для восстановления в PG18 → сборка с `PG_MAJOR=18`).

```bash
# Build with the desired client version
docker build --build-arg PG_MAJOR=18 -t t-pgsql:18 .

# One-off dump (mount a dumps volume)
docker run --rm -v "$PWD/dumps:/data/dumps" \
  t-pgsql:18 dump --from "postgres@db.example.com/mydb" --output /data/dumps -y

# Run the Telegram bot as a service (see docker-compose.yml)
docker compose up -d --build
```

Смонтируйте ваш `jobs.yaml`, файлы паролей и SSH-ключ в `/data` (а SSH-ключ —
в `/home/tpgsql/.ssh`). Образ запускается от имени пользователя без прав root.

## Обновления мажорных версий (логические)

Команда `upgrade` выполняет **логическую** миграцию между мажорными версиями (например, PG16 → PG18):
она мигрирует глобальные объекты кластера (роли, табличные пространства), проверяет, что цель не является более старой
мажорной версией, а затем клонирует базу данных.

```bash
# Run from a host/container whose pg_dump matches the TARGET version (18 here).
t-pgsql upgrade \
  --from "postgres@old-16-host:5432/appdb" \
  --to   "postgres@new-18-host:5432/appdb" -y

# Or add globals to a plain clone, and pick client tools explicitly:
t-pgsql clone --from ... --to ... --globals --pg-bindir /usr/lib/postgresql/18/bin
```

**Честная область применения:** это путь dump/restore, подходящий для малых/средних баз данных или
чистой логической пересборки. Для больших кластеров или переключений с минимальным простоем `pg_upgrade`
(на месте) и логическая репликация остаются более проверенными инструментами — эта команда
их не заменяет. Миграция глобальных объектов работает для локальных/TCP и SSH-источников и
применяется к каждой цели `--to`.

## Разработка (модульные исходники)

`t-pgsql` — это **генерируемый единый файл**, собираемый из небольших модулей в каталоге `src/`
(header, globals, logging, dump, restore, clone, upgrade, batch, bot, args, main, …),
объединённых в порядке, указанном в `src/build.manifest`.

```bash
# Edit a module, then rebuild the single file:
$EDITOR src/55-dump.sh
./build.sh            # or: make build

# Verify the committed t-pgsql is in sync with src/ (CI runs this):
./build.sh --check    # or: make check-build
```

**Не** редактируйте `t-pgsql` вручную — изменения относятся к `src/`. Распространение не меняется:
по-прежнему устанавливается/поставляется один исполняемый файл (упаковка, автодополнения и поведение `SCRIPT_DIR`
идентичны). Поскольку всё выполняется в одном процессе Bash с единым
общим глобальным пространством имён, разделение файла — это чисто изменение организации кода;
здесь нет никакой связанности во время выполнения или вопросов синхронизации.

## Быстрый старт

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

## Форматы подключения

### Локальное подключение

```
[db_user@]host[:port]/database
```

| Пример | Описание |
|---------|-------------|
| `localhost/mydb` | Пользователь по умолчанию с localhost |
| `postgres@localhost/mydb` | С пользователем postgres |
| `postgres@localhost:5432/mydb` | С явным портом |
| `dbadmin@localhost/test123` | Пользовательский пользователь |

### SSH-подключение (удалённое)

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Пример | Описание |
|---------|-------------|
| `ssh://ubuntu@192.0.2.20/mydb` | Простой формат (db: localhost, user: postgres) |
| `ssh://ubuntu@192.0.2.20/postgres@localhost/mydb` | С указанным пользователем БД |
| `ssh://dbadmin@192.0.2.10/postgres@localhost/appdb` | Полный формат |
| `ssh://dbadmin@server:2222/postgres@localhost:5433/prod` | Пользовательские порты |

### Структура подключения

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

## Команды

### dump

Создаёт резервную копию базы данных.

```bash
./t-pgsql dump --from <connection> [options]
```

**Примеры:**

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

**Вывод:** `<script dir>/../data/dumps/database_YYYYMMDD_HHMMSS.tar.gz` (каталог вывода по умолчанию; переопределяется с помощью `--output`)

Tar-архив содержит:
- `database_YYYYMMDD_HHMMSS.dump` — файл дампа PostgreSQL (или пользовательское имя)
- `metadata.yaml` — информация об операции

---

### restore

Восстанавливает файл дампа в базу данных.

```bash
./t-pgsql restore --to <connection> [--file <file>] [options]
```

**Примеры:**

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

> **Примечание:** Если `--file` не указан, автоматически находит последний файл `.tar.gz` в каталоге `--output`.

---

### clone

Выполняет dump + restore одной командой.

```bash
./t-pgsql clone --from <source> --to <target> [options]
```

**Примеры:**

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

Загружает существующий файл дампа с удалённого сервера (без создания нового дампа).

```bash
./t-pgsql fetch --from <connection> --from-file [pattern] [options]
```

**Примеры:**

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

Выводит список файлов дампов.

```bash
./t-pgsql list [--output <directory>]
```

**Пример вывода:**

```
Dumps in: /opt/t-pgsql/data/dumps

FILE                                      SIZE DATE
---------------------------------------------------------------------------
appdb_20251230_225325.tar.gz     39MiB 2025-12-30 22:54
mydb_20251229_143022.tar.gz              15MiB 2025-12-29 14:30
```

---

### meta

Отображает информацию метаданных из архива дампа.

```bash
./t-pgsql meta --file <archive.tar.gz>
```

**Пример вывода:**

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

Очищает старые файлы дампов.

```bash
./t-pgsql clean [--output <directory>] [--keep <N>]
```

---

### jobs

Выводит список сохранённых пакетных заданий.

```bash
./t-pgsql jobs
```

---

## Система пакетной обработки

Сохраняйте повторяющиеся операции и запускайте их одной командой.

### Сохранение задания

Сохраните любую команду с помощью `--save <name>`:

```bash
./t-pgsql clone \
  --from "ssh://dbadmin@192.0.2.10/postgres@localhost/appdb" \
  --to "dbadmin@localhost/test123" \
  --from-password-file .secrets/from.pass \
  --to-password-file .secrets/to.pass \
  --force \
  --save nightly-sync
```

### Запуск заданий

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

### Просмотр списка заданий

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

Запускает постоянно работающий Telegram-бот, позволяющий запускать и отслеживать резервные копии из чата. Он использует длинный опрос Telegram (`getUpdates`) и реагирует только на **настроенный чат** (fail-closed — если чат не настроен, он игнорирует любую команду).

```bash
# Token from --token, or defaults.notify.telegram in the YAML, or $TELEGRAM_BOT_TOKEN
./t-pgsql bot --yaml sync-30 --token "123456:ABC..." --cooldown 1h
```

**Команды чата:**

| Команда | Действие |
|---------|--------|
| `/help` | Показать доступные команды |
| `/list` | Вывести список YAML-файлов в каталоге скрипта |
| `/list <yaml>` | Вывести список заданий, определённых в YAML |
| `/backup <yaml> <job>` | Запустить задание резервного копирования в фоне и сообщить результат |

Уведомления о сбоях включают встроенную кнопку **«Re-run Backup»**. Параметр `--cooldown` (по умолчанию `1h`, формат `<N>[h|m|d]`) ограничивает, как часто одно и то же задание может быть повторно запущено кнопкой или `/backup`. Идентификатор чата и (опционально) тред форума читаются из `defaults.notify.telegram` в YAML или из `TELEGRAM_CHAT_ID` / `TELEGRAM_THREAD_ID`.

> Запускайте его под менеджером процессов (systemd, `docker compose`, `tmux`) — см. раздел [Docker](#docker) для сервиса compose.

---

### Формат jobs.yaml

t-pgsql поддерживает три формата заданий: на основе профилей, строка подключения и устаревшие аргументы.

#### Формат на основе профилей (рекомендуется)

Определите переиспользуемые профили подключения и значения по умолчанию, чтобы уменьшить повторения:

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

#### Формат строки подключения

Используйте прямые строки подключения для более простых заданий:

```yaml
jobs:
  quick-backup:
    command: dump
    from: ssh://user@server/postgres@localhost/mydb
    from_password_file: ~/.secrets/prod.pass
    output: ./dumps
    keep: 7
```

#### Формат устаревших аргументов (обратно совместимый)

Старый формат по-прежнему работает для обратной совместимости:

```yaml
jobs:
  legacy_job:
    command: clone
    args: --from 'ssh://user@server/postgres@localhost/db' --to 'postgres@localhost/db' --force
```

#### Параметры задания

| Параметр | Описание |
|--------|-------------|
| `force` | Удалить и пересоздать существующую базу данных |
| `verbose` | Показать подробный вывод |
| `from_keep` | Количество дампов для хранения на источнике |
| `keep` | Количество локальных дампов для хранения |
| `dump_name` | Пользовательское имя файла дампа (без временной метки) |
| `skip_if_recent` | Пропустить, если дамп существует в пределах временного окна (например, `24h`, `1d`, `today`) |
| `output` | Каталог вывода для дампов |
| `exclude_table` | Таблицы для полного исключения |
| `exclude_data` | Таблицы для исключения только данных (поддерживает шаблон `schema.*`) |
| `exclude_schema` | Схемы для исключения |

---

## Продвинутые возможности

### GFS-хранение (дед-отец-сын)

Автоматизированная политика ротации резервных копий, которая хранит ежедневные, еженедельные, ежемесячные и ежегодные резервные копии:

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

### Маскирование данных

Анонимизирует конфиденциальные данные после восстановления для сред разработки/тестирования. Маскирование выполняется **после** восстановления (поэтому оно не поддерживается с `--stream`). Оно отказоустойчиво: если `--mask` не совпал **ни с чем** — или любой оператор маскирования завершается ошибкой — операция **завершается неудачей**, а не сообщает о немаскированной копии как об успехе.

- `--mask-tables` автоматически маскирует фиксированный набор известных конфиденциальных столбцов (`email`, `phone`, `password`, `password_hash`, `address`, `ssn`, `credit_card`) — но только те столбцы, которые фактически **существуют** в каждой указанной обновляемой базовой таблице. Голое имя таблицы, совпадающее с несколькими схемами, маскирует таблицу в каждой схеме (с указанием схемы). Идентификаторы всегда заключаются в кавычки, поэтому имена таблиц с зарезервированными словами / смешанным регистром работают.
- `--mask-rules` применяет ваши собственные SQL-выражения из JSON-файла (см. ниже).

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

**Формат mask-rules.json:**

```json
{
  "users.email": "CONCAT(LEFT(email, 2), '***@example.com')",
  "users.phone": "'555-***-****'",
  "users.name": "CONCAT('User_', id)",
  "customers.address": "'[REDACTED]'",
  "orders.notes": "NULL"
}
```

**Автоматически маскируемые поля** (при использовании `--mask-tables`):
- `email` → `ab***@***.com`
- `phone` → `***-***-****`
- `password` / `password_hash` → `********` / `MASKED`
- `address` → `[MASKED]`
- `ssn` → `***-**-****`
- `credit_card` → `****-****-****-****`

### Проверки работоспособности

Проверяйте соединения с базой данных перед операциями:

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

### Потоковый режим

Прямая передача через канал без создания временных файлов (быстрее, меньше места на диске):

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

> **Примечание:** Потоковый режим не создаёт локальных файлов дампов. Используйте обычный clone, если вам нужно хранить резервные копии.

---

## Управление паролями

Пароли не должны появляться в истории bash. Есть 3 метода:

### 1. Файл пароля (рекомендуется)

#### Настройка каталога .secrets

```bash
# Create .secrets directory
mkdir -p .secrets
chmod 700 .secrets

# Add to .gitignore (IMPORTANT!)
echo ".secrets/" >> .gitignore
```

#### Создание файлов паролей

```bash
# IMPORTANT: Use -n flag to avoid newline at end of file
echo -n "your_password_here" > .secrets/db.pass

# Set secure permissions (read/write only for owner)
chmod 600 .secrets/db.pass

# Verify no newline exists
cat .secrets/db.pass | xxd | tail -1
# Should NOT end with '0a' (newline character)
```

#### Рекомендуемая структура .secrets

```
.secrets/
├── from.pass      # Source database password
├── to.pass        # Target database password
├── prod.pass      # Production database password
├── dev.pass       # Development database password
└── ssh.key        # SSH private key (optional)
```

#### Формат файла пароля

| Требование | Описание |
|-------------|-------------|
| **Без символа новой строки** | Используйте `echo -n`, чтобы избежать завершающего перевода строки |
| **Обычный текст** | Только пароль, ничего больше |
| **UTF-8** | Используйте кодировку UTF-8 |
| **Права доступа** | `chmod 600` (чтение/запись только для владельца) |

#### Примеры использования

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

### 2. Переменная окружения

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

| Переменная окружения | Описание |
|---------------------|-------------|
| `T_PGSQL_PASSWORD` | Пароль для обоих подключений |
| `T_PGSQL_FROM_PASSWORD` | Пароль подключения-источника |
| `T_PGSQL_TO_PASSWORD` | Пароль подключения-цели |

### 3. Интерактивный запрос

Если пароль не указан, безопасно запрашивается из терминала:

```bash
./t-pgsql dump --from "postgres@localhost/mydb"
# FROM password: ********  (input is hidden)
```

> **Примечание:** Интерактивный запрос работает только в терминале (TTY). Для скриптов и заданий cron используйте файлы паролей или переменные окружения.

### Порядок приоритета паролей

Когда доступно несколько источников паролей, t-pgsql использует следующий приоритет:

1. **Прямой параметр** (`--password`, `--from-password`, `--to-password`)
2. **Переменная окружения** (`T_PGSQL_PASSWORD` и т.д.)
3. **Файл пароля** (`--password-file` и т.д.)
4. **Интерактивный запрос** (если доступен TTY)

### Рекомендации по безопасности

| Практика | Описание |
|----------|-------------|
| Используйте `.gitignore` | Никогда не коммитьте файлы паролей в git |
| Используйте `chmod 600` | Ограничьте доступ к файлу только владельцем |
| Используйте `chmod 700` | Ограничьте доступ к каталогу только владельцем |
| Избегайте `--password` | Не используйте пароль напрямую в командной строке |
| Используйте отдельные файлы | Используйте разные файлы для сред prod/dev |
| Ротируйте пароли | Регулярно обновляйте файлы паролей |

---

## Файл конфигурации (`--config`)

`--config <file>` загружает **значения по умолчанию для одного запуска** одной команды (в отличие от YAML заданий, задаваемого через `--yaml`). Это простой файл вида `key: value`; **флаги CLI и переменные окружения всегда имеют приоритет** над файлом.

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

Поддерживаемые ключи повторяют флаги: `from`, `to`, `password`/`from_password`/`to_password`, `password_file`/`from_password_file`/`to_password_file`, `output`, `keep`, `from_keep`, `compress`, `exclude_table`/`exclude_data`/`exclude_schema`, `only_table`/`only_schema`, `notify` (повторяемый) и булевы `verbose`/`force`/`sudo`. `~` раскрывается только для ключей путевого типа — никогда для паролей или строк подключения.

---

## Полный справочник параметров

### Параметры подключения

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--from <conn>` | Строка подключения к базе данных-источнику | - | Да (dump/clone) | `postgres@localhost/mydb` |
| `--to <conn>` | Строка подключения к базе данных-цели (повторяемая для нескольких целей) | - | Да (restore/clone) | `ssh://user@host/db` |

**Форматы строк подключения:**
- Локальный: `[user@]host[:port]/database`
- SSH: `ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database`

### Параметры паролей

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--password <pass>` | Пароль для источника и цели | - | Нет | `mysecret` |
| `--from-password <pass>` | Пароль только для подключения-источника | - | Нет | `srcpass` |
| `--to-password <pass>` | Пароль только для подключения-цели | - | Нет | `dstpass` |
| `--password-file <file>` | Читать пароль из файла (оба подключения) | - | Нет | `.secrets/db.pass` |
| `--from-password-file <file>` | Читать пароль источника из файла | - | Нет | `.secrets/from.pass` |
| `--to-password-file <file>` | Читать пароль цели из файла. Повторяемый — сопоставляется с каждым `--to` по позиции, или указывается один раз для применения ко всем целям. | - | Нет | `.secrets/to.pass` |
| `--config <file>` | Файл значений по умолчанию для одного запуска (см. [Файл конфигурации](#файл-конфигурации---config)) | - | Нет | `db.conf` |

**Переменные окружения:**
- `T_PGSQL_PASSWORD` — Пароль для обоих подключений
- `T_PGSQL_FROM_PASSWORD` — Пароль источника
- `T_PGSQL_TO_PASSWORD` — Пароль цели

### Параметры фильтрации

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--exclude-table <tables>` | Таблицы для исключения, через запятую | - | Нет | `logs,sessions,temp` |
| `--exclude-schema <schemas>` | Схемы для исключения, через запятую | - | Нет | `audit,temp` |
| `--exclude-data <tables>` | Исключить данные, но сохранить структуру (поддерживает шаблон `schema.*`) | - | Нет | `audit.*,logs` |
| `--only-table <tables>` | Включить только эти таблицы | - | Нет | `users,orders` |
| `--only-schema <schemas>` | Включить только эти схемы | - | Нет | `public,app` |

### Параметры сжатия

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--compress <type>` | Алгоритм сжатия | `gzip` | Нет | `zstd`, `xz`, `bzip2`, `none` |
| `--compress-level <1-9>` | Уровень сжатия | `6` | Нет | `9` |
| `--pg-compress-level <0-9>` | Внутреннее сжатие pg_dump | `6` | Нет | `0` (без сжатия) |

### Параметры хранилища

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--output <dir>` | Каталог вывода для дампов | `<script dir>/../data/dumps` | Нет | `/backups/daily` |
| `--keep <N>` | Количество локальных дампов для хранения | `-1` (все) | Нет | `7`, `0` (удалить), `-1` (все) |
| `--from-keep <N>` | Количество дампов для хранения на источнике | `1` | Нет | `3`, `0` (удалить), `-1` (все) |
| `--dump-name <name>` | Пользовательское имя файла дампа (без временной метки) | Имя базы данных | Нет | `myapp-backup` |
| `--skip-if-recent <time>` | Пропустить, если дамп существует в пределах временного окна | - | Нет | `24h`, `12h`, `1d`, `today` |
| `--file <path>` | Конкретный файл дампа для восстановления | - | Нет | `./dumps/backup.tar.gz` |
| `--from-file [pattern]` | Загрузить существующий дамп (без значения = последний) | - | Нет | `mydb_*.dump` |

### Параметры хранения (GFS — дед-отец-сын)

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--retention` | Включить политику GFS-хранения | `false` | Нет | - |
| `--retention-daily <N>` | Ежедневных копий для хранения | `7` | Нет | `14` |
| `--retention-weekly <N>` | Еженедельных копий для хранения | `4` | Нет | `8` |
| `--retention-monthly <N>` | Ежемесячных копий для хранения | `12` | Нет | `24` |
| `--retention-yearly <N>` | Ежегодных копий для хранения | `3` | Нет | `5` |

### Параметры проверки работоспособности

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--health-check` | Проверять базу данных перед операцией | `true` | Нет | - |
| `--health-check-after` | Проверять базу данных после операции | `false` | Нет | - |
| `--no-health-check` | Отключить все проверки работоспособности | `false` | Нет | - |
| `--health-check-fail` | Прервать при неудачной проверке работоспособности | `false` | Нет | - |

### Параметры уведомлений

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--notify <channel>` | Канал уведомлений (повторяемый) | - | Нет | `telegram:TOKEN:CHAT` |
| `--notify-on-error` | Уведомлять только об ошибках | `false` | Нет | - |
| `--notify-summary` | Отправить сводку после пакета | `false` | Нет | - |

**Поддерживаемые каналы:** `telegram`, `slack:URL`, `webhook:URL`, `email:ADDRESS`

### Параметры маскирования данных

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--mask` | Включить маскирование данных | `false` | Нет | - |
| `--mask-rules <file>` | JSON-файл с правилами маскирования | - | Нет | `mask-rules.json` |
| `--mask-tables <tables>` | Таблицы для применения маскирования | - | Нет | `users,customers` |

### Параметры потоковой передачи

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--stream` | Потоковый режим (без временных файлов); направляет `pg_dump \| pg_restore` напрямую | `false` | Нет | - |
| `--stream-buffer <MB>` | Размер буфера в мегабайтах во время передачи (`pv`) | `64` | Нет | `128` |

> **Замечание по безопасности:** В отличие от всех остальных путей, `--stream` передаёт удалённую команду `pg_restore` (с её преамбулой `.pgpass`) в argv ssh, поэтому учётные данные ненадолго видны для `ps` на удалённом хосте на время потоковой передачи. Используйте `--sudo` (peer-аутентификация) или непотоковый clone, если это важно. `--mask` не поддерживается с `--stream` (маскирование выполняется после полного восстановления).

### Параметры передачи и надёжности

Применяются к передачам SSH/scp (и к каналу `--stream`, когда установлен `pv`).

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--bwlimit <rate>` | Ограничить полосу пропускания передачи. `10m` = 10 МБ/с, `500k` = 500 КБ/с, голое число = КБ/с. scp использует свой `-l`; потоковая передача использует `pv -L` (требует `pv`). | без ограничений | Нет | `10m` |
| `--retries <N>` | Дополнительные попытки повтора для неудачной передачи scp (с примерно экспоненциальной задержкой) | `0` | Нет | `3` |

### Параметры пакетной обработки

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--yaml <name>` | YAML-файл заданий. Голое имя разрешается в `<script-dir>/<name>.yaml`; значение, содержащее `/` или оканчивающееся на `.yaml`, используется как есть | `<script-dir>/jobs.yaml` | Нет | `sync-30`, `./jobs/prod.yaml` |
| `--save <name>` | Сохранить текущую команду + флаги как задание (вместо запуска) | - | Нет | `daily_backup` |
| `--batch <name\|all>` | Запустить сохранённое задание(я); эквивалентно `t-pgsql batch <name\|all>` | - | Нет | `daily_backup`, `all` |
| `--parallel <N>` | Количество заданий для параллельного запуска | `1` | Нет | `4` |
| `--continue-on-error` | Продолжить пакет, даже если задание завершилось неудачей | `false` | Нет | - |
| `--only-jobs <jobs>` | Запустить только эти задания (через запятую) | - | Нет | `job1,job2` |
| `--exclude-jobs <jobs>` | Пропустить эти задания (через запятую) | - | Нет | `slow_job` |
| `--only <jobs>` | Устаревший псевдоним для `--only-jobs` | - | Нет | `job1,job2` |
| `--exclude <jobs>` | Устаревший псевдоним для `--exclude-jobs` | - | Нет | `slow_job` |
| `--skip-if-recent <time>` | Пропустить задание, если дамп существует в пределах окна | - | Нет | `24h`, `30m`, `2d`, `today` |

### Параметры миграции (`upgrade` / `clone`)

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--globals` | Также мигрировать глобальные объекты кластера (роли, табличные пространства) через `pg_dumpall --globals-only`; уже существующие роли допускаются. Принудительно включается командой `upgrade`. | `false` | Нет | - |
| `--pg-bindir <dir>` | Добавить `<dir>` в начало `PATH`, чтобы выбрать конкретную версию клиента PostgreSQL для **локальных** `pg_dump`/`pg_restore`/`psql`/`createdb`/`pg_dumpall` (не для удалённых по SSH) | - | Нет | `/usr/lib/postgresql/18/bin` |

### Параметры бота

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `--token <token>` | Токен Telegram-бота (иначе читается из `defaults.notify.telegram` в YAML или из `TELEGRAM_BOT_TOKEN`) | - | Нет | `123:ABC...` |
| `--cooldown <time>` | Минимальный интервал между запусками одного и того же задания через кнопку/`/backup`. Формат `<N>[h\|m\|d]`. | `1h` | Нет | `30m`, `2d` |

### Общие параметры

| Параметр | Описание | По умолчанию | Обязательный | Пример |
|-----------|-------------|---------|----------|---------|
| `-f, --force` | Удалить и пересоздать существующую базу данных | `false` | Нет | - |
| `-v, --verbose` | Показать подробный вывод | `false` | Нет | - |
| `-q, --quiet` | Минимальный вывод | `false` | Нет | - |
| `-y, --yes` | Пропустить все подтверждения | `false` | Нет | - |
| `--dry-run` | Показать, что было бы сделано, без выполнения | `false` | Нет | - |
| `--sudo` | Использовать sudo для операций с базой данных | `false` | Нет | - |
| `--log <file>` | Записывать логи в файл | - | Нет | `/var/log/t-pgsql.log` |
| `--log-level <level>` | Уровень детализации логов | `info` | Нет | `debug`, `warn`, `error` |
| `--no-meta` | Не записывать метаданные в архивы | `false` | Нет | - |
| `-h, --help` | Показать справочное сообщение | - | Нет | - |
| `--version` | Показать номер версии | - | Нет | - |

### Переменные окружения

| Переменная | Описание |
|----------|-------------|
| `T_PGSQL_PASSWORD` | Пароль для источника и цели |
| `T_PGSQL_FROM_PASSWORD` | Пароль подключения-источника |
| `T_PGSQL_TO_PASSWORD` | Пароль подключения-цели |
| `T_PGSQL_OUTPUT_DIR` | Каталог вывода по умолчанию для дампов (переопределяется `--output`) |
| `PGCONNECT_TIMEOUT` | Тайм-аут подключения libpq в секундах (по умолчанию `10`) |
| `TELEGRAM_BOT_TOKEN` | Определяет голый канал `--notify telegram` и токен `bot` |
| `TELEGRAM_CHAT_ID` | Идентификатор чата для голого канала `--notify telegram` |
| `TELEGRAM_THREAD_ID` | Опциональный идентификатор треда темы форума для уведомлений Telegram |

> Пароли, переданные через переменные окружения (или с ограниченной областью встроенно, например `T_PGSQL_PASSWORD=secret t-pgsql ...`), никогда не помещаются в argv процесса, поэтому они не видны для `ps`.

### Внутренние значения по умолчанию

| Переменная | Значение по умолчанию | Описание |
|----------|---------------|-------------|
| `FROM_DB_USER` | `postgres` | Пользователь базы данных по умолчанию |
| `FROM_DB_HOST` | `localhost` | Хост базы данных по умолчанию |
| `FROM_DB_PORT` | `5432` | Порт PostgreSQL по умолчанию |
| `FROM_SSH_PORT` | `22` | Порт SSH по умолчанию |

---

## Практические примеры

### Ежедневная резервная копия

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

### Синхронизация среды разработки

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

### Развёртывание в несколько сред

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

### Исключение больших таблиц

```bash
./t-pgsql dump \
  --from "postgres@localhost/analytics" \
  --password-file .secrets/db.pass \
  --exclude-data "raw_events,page_views,click_stream" \
  --output ./dumps
```

---

## Структура файлов

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

## Устранение неполадок

### Ошибка SSH-подключения

```bash
# Test SSH access
ssh dbadmin@192.0.2.10 "echo ok"

# Run with verbose mode
./t-pgsql dump --from "ssh://..." -v
```

### Ошибка пароля

```bash
# Check password file
cat .secrets/db.pass | xxd  # Should have no newline

# Fix it
echo -n "password" > .secrets/db.pass
```

### Ошибка «база данных уже существует»

```bash
# Use --force to drop existing DB
./t-pgsql restore --to "..." --force
```

### Отказано в доступе

```bash
# Password file permissions
chmod 600 .secrets/*.pass
```

---

## Лицензия

MIT License

## Участие в разработке

Pull-запросы приветствуются.
