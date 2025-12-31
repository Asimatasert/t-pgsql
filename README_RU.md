# t-pgsql

Продвинутый CLI-инструмент для резервного копирования, восстановления и синхронизации баз данных PostgreSQL.

**Документация:** [English](README.md) | [Türkçe](README_TR.md) | [Español](README_ES.md) | [Deutsch](README_DE.md)

## Возможности

- **Dump**: Резервное копирование локальной или удалённой базы данных
- **Restore**: Восстановление резервной копии в локальную или удалённую базу данных
- **Clone**: Одна команда dump + restore (полная синхронизация)
- **Fetch**: Загрузка существующего дампа с удалённого сервера
- **Batch**: Последовательный запуск нескольких задач
- **Metadata**: Сохранение информации о времени, источнике и назначении с каждой копией
- **Поддержка SSH**: Доступ к удалённым серверам через SSH-туннель
- **Безопасность паролей**: Чтение паролей из файлов или переменных окружения

## Установка

```bash
# Клонировать репозиторий
git clone https://github.com/Asimatasert/t-pgsql.git
cd t-pgsql

# Сделать исполняемым
chmod +x t-pgsql

# Добавить в PATH (опционально)
sudo ln -s $(pwd)/t-pgsql /usr/local/bin/t-pgsql
```

### Требования

- Клиент PostgreSQL (`pg_dump`, `pg_restore`, `psql`)
- SSH-клиент (для удалённых операций)
- Bash 4.0+

## Быстрый старт

```bash
# Дамп локальной базы данных
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Дамп с удалённого сервера
./t-pgsql dump --from "ssh://user@192.168.1.100/postgres@localhost/mydb" --from-password-file .secrets/remote.pass

# Восстановить дамп
./t-pgsql restore --file ./dumps/mydb_20250101.tar.gz --to "postgres@localhost/mydb_copy" --to-password-file .secrets/local.pass

# Клонировать одной командой (dump + restore)
./t-pgsql clone --from "ssh://user@server/postgres@localhost/prod" --to "postgres@localhost/dev" --from-password-file .secrets/prod.pass --to-password-file .secrets/local.pass --force
```

---

## Форматы подключения

### Локальное подключение

```
[db_user@]host[:port]/database
```

| Пример | Описание |
|--------|----------|
| `localhost/mydb` | Пользователь по умолчанию с localhost |
| `postgres@localhost/mydb` | С пользователем postgres |
| `postgres@localhost:5432/mydb` | С явным указанием порта |

### SSH (Удалённое) подключение

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Пример | Описание |
|--------|----------|
| `ssh://user@192.168.1.100/mydb` | Простой формат (db: localhost, user: postgres) |
| `ssh://user@192.168.1.100/postgres@localhost/mydb` | С указанием пользователя БД |
| `ssh://user@server:2222/postgres@localhost:5433/prod` | Пользовательские порты |

---

## Команды

### dump

Создаёт резервную копию базы данных.

```bash
./t-pgsql dump --from <подключение> [опции]
```

**Примеры:**

```bash
# Простой дамп
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Исключить определённые таблицы
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-table "logs,sessions,temp_data"

# Включить только определённые таблицы
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --only-table "users,orders,products"
```

---

### restore

Восстанавливает файл дампа в базу данных.

```bash
./t-pgsql restore --to <подключение> [--file <файл>] [опции]
```

**Примеры:**

```bash
# Восстановить последний дамп (автопоиск)
./t-pgsql restore --to "postgres@localhost/mydb" --to-password-file .secrets/local.pass

# Восстановить определённый файл
./t-pgsql restore \
  --file ./dumps/mydb_20250130.tar.gz \
  --to "postgres@localhost/mydb_copy" \
  --to-password-file .secrets/local.pass

# Удалить и пересоздать существующую БД
./t-pgsql restore \
  --file ./dumps/prod_backup.tar.gz \
  --to "postgres@localhost/test_db" \
  --to-password-file .secrets/local.pass \
  --force
```

---

### clone

Выполняет dump + restore одной командой.

```bash
./t-pgsql clone --from <источник> --to <назначение> [опции]
```

**Примеры:**

```bash
# Клонировать с удалённого на локальный
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force

# Клонировать на несколько целей
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

Загружает существующий файл дампа с удалённого сервера (без создания нового дампа).

```bash
./t-pgsql fetch --from <подключение> --from-file [шаблон] [опции]
```

---

### list

Показывает список файлов дампа.

```bash
./t-pgsql list [--output <директория>]
```

---

### clean

Очищает старые файлы дампа.

```bash
./t-pgsql clean [--output <директория>] [--keep <N>]
```

---

## Система Batch

Сохраняйте повторяющиеся операции и запускайте их одной командой.

### Сохранение задачи

```bash
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force \
  --save my_sync
```

### Запуск задач

```bash
# Запустить одну задачу
./t-pgsql --batch my_sync

# Запустить все задачи
./t-pgsql --batch all

# Продолжить при ошибке
./t-pgsql --batch all --continue-on-error
```

---

## Управление паролями

### 1. Файл пароля (Рекомендуется)

```bash
# Создать директорию .secrets
mkdir -p .secrets
chmod 700 .secrets

# Создать файл пароля (без перевода строки)
echo -n "ваш_пароль" > .secrets/db.pass
chmod 600 .secrets/db.pass

# Добавить в .gitignore
echo ".secrets/" >> .gitignore
```

### 2. Переменная окружения

```bash
export T_PGSQL_PASSWORD="секрет"
./t-pgsql dump --from "postgres@localhost/mydb"
```

### 3. Интерактивный ввод

Если пароль не указан, запрашивается безопасно из терминала.

---

## Основные параметры

| Параметр | Описание |
|----------|----------|
| `--from <conn>` | Строка подключения источника |
| `--to <conn>` | Строка подключения назначения |
| `--password-file <file>` | Файл с паролем |
| `--exclude-table <tables>` | Исключаемые таблицы |
| `--only-table <tables>` | Только эти таблицы |
| `--force` | Удалить и пересоздать существующую БД |
| `--verbose` | Подробный вывод |
| `--dry-run` | Показать без выполнения |

---

## Лицензия

MIT License

## Участие в разработке

Pull request'ы приветствуются.
