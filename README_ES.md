# t-pgsql

Herramienta CLI avanzada para realizar copias de seguridad, restaurar y sincronizar bases de datos PostgreSQL.

**Documentación:** [English](README.md) | [Türkçe](README_TR.md) | [Русский](README_RU.md) | [Deutsch](README_DE.md)

## Características

- **Dump**: Copia de seguridad desde base de datos local o remota
- **Restore**: Restaurar copia de seguridad a base de datos local o remota
- **Clone**: Comando único dump + restore (sincronización completa)
- **Fetch**: Descargar dump existente desde servidor remoto
- **Batch**: Ejecutar múltiples trabajos secuencialmente
- **Metadata**: Almacenar información de tiempo, origen y destino con cada copia
- **Soporte SSH**: Acceder a servidores remotos mediante túnel SSH
- **Seguridad de Contraseñas**: Leer contraseñas desde archivos o variables de entorno

## Instalación

```bash
# Clonar el repositorio
git clone https://github.com/Asimatasert/t-pgsql.git
cd t-pgsql

# Hacer ejecutable
chmod +x t-pgsql

# Agregar al PATH (opcional)
sudo ln -s $(pwd)/t-pgsql /usr/local/bin/t-pgsql
```

### Requisitos

- Cliente PostgreSQL (`pg_dump`, `pg_restore`, `psql`)
- Cliente SSH (para operaciones remotas)
- Bash 4.0+

## Inicio Rápido

```bash
# Dump desde base de datos local
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Dump desde servidor remoto
./t-pgsql dump --from "ssh://user@192.168.1.100/postgres@localhost/mydb" --from-password-file .secrets/remote.pass

# Restaurar un dump
./t-pgsql restore --file ./dumps/mydb_20250101.tar.gz --to "postgres@localhost/mydb_copy" --to-password-file .secrets/local.pass

# Clonar con un solo comando (dump + restore)
./t-pgsql clone --from "ssh://user@server/postgres@localhost/prod" --to "postgres@localhost/dev" --from-password-file .secrets/prod.pass --to-password-file .secrets/local.pass --force
```

---

## Formatos de Conexión

### Conexión Local

```
[db_user@]host[:port]/database
```

| Ejemplo | Descripción |
|---------|-------------|
| `localhost/mydb` | Usuario por defecto con localhost |
| `postgres@localhost/mydb` | Con usuario postgres |
| `postgres@localhost:5432/mydb` | Con puerto explícito |

### Conexión SSH (Remota)

```
ssh://[ssh_user@]ssh_host[:ssh_port]/[db_user@]db_host[:db_port]/database
```

| Ejemplo | Descripción |
|---------|-------------|
| `ssh://user@192.168.1.100/mydb` | Formato simple (db: localhost, user: postgres) |
| `ssh://user@192.168.1.100/postgres@localhost/mydb` | Con usuario DB especificado |
| `ssh://user@server:2222/postgres@localhost:5433/prod` | Puertos personalizados |

---

## Comandos

### dump

Crea una copia de seguridad de la base de datos.

```bash
./t-pgsql dump --from <conexión> [opciones]
```

**Ejemplos:**

```bash
# Dump simple
./t-pgsql dump --from "postgres@localhost/mydb" --password-file .secrets/db.pass

# Excluir tablas específicas
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --exclude-table "logs,sessions,temp_data"

# Incluir solo tablas específicas
./t-pgsql dump \
  --from "postgres@localhost/mydb" \
  --password-file .secrets/db.pass \
  --only-table "users,orders,products"
```

---

### restore

Restaura un archivo dump a una base de datos.

```bash
./t-pgsql restore --to <conexión> [--file <archivo>] [opciones]
```

**Ejemplos:**

```bash
# Restaurar último dump (auto-buscar)
./t-pgsql restore --to "postgres@localhost/mydb" --to-password-file .secrets/local.pass

# Restaurar archivo específico
./t-pgsql restore \
  --file ./dumps/mydb_20250130.tar.gz \
  --to "postgres@localhost/mydb_copy" \
  --to-password-file .secrets/local.pass

# Eliminar y recrear DB existente
./t-pgsql restore \
  --file ./dumps/prod_backup.tar.gz \
  --to "postgres@localhost/test_db" \
  --to-password-file .secrets/local.pass \
  --force
```

---

### clone

Realiza dump + restore en un solo comando.

```bash
./t-pgsql clone --from <origen> --to <destino> [opciones]
```

**Ejemplos:**

```bash
# Clonar de remoto a local
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force

# Clonar a múltiples destinos
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

Descarga un archivo dump existente desde remoto (sin crear nuevo dump).

```bash
./t-pgsql fetch --from <conexión> --from-file [patrón] [opciones]
```

---

### list

Lista archivos dump.

```bash
./t-pgsql list [--output <directorio>]
```

---

### clean

Limpia archivos dump antiguos.

```bash
./t-pgsql clean [--output <directorio>] [--keep <N>]
```

---

## Sistema Batch

Guarda operaciones repetitivas y ejecútalas con un solo comando.

### Guardar un Trabajo

```bash
./t-pgsql clone \
  --from "ssh://user@server/postgres@localhost/prod" \
  --to "postgres@localhost/dev" \
  --from-password-file .secrets/prod.pass \
  --to-password-file .secrets/local.pass \
  --force \
  --save mi_sync
```

### Ejecutar Trabajos

```bash
# Ejecutar un solo trabajo
./t-pgsql --batch mi_sync

# Ejecutar todos los trabajos
./t-pgsql --batch all

# Continuar en caso de error
./t-pgsql --batch all --continue-on-error
```

---

## Gestión de Contraseñas

### 1. Archivo de Contraseña (Recomendado)

```bash
# Crear directorio .secrets
mkdir -p .secrets
chmod 700 .secrets

# Crear archivo de contraseña (sin salto de línea)
echo -n "tu_contraseña" > .secrets/db.pass
chmod 600 .secrets/db.pass

# Agregar a .gitignore
echo ".secrets/" >> .gitignore
```

### 2. Variable de Entorno

```bash
export T_PGSQL_PASSWORD="secreto"
./t-pgsql dump --from "postgres@localhost/mydb"
```

### 3. Prompt Interactivo

Si no se especifica contraseña, se solicita de forma segura desde la terminal.

---

## Parámetros Principales

| Parámetro | Descripción |
|-----------|-------------|
| `--from <conn>` | Cadena de conexión origen |
| `--to <conn>` | Cadena de conexión destino |
| `--password-file <file>` | Archivo con contraseña |
| `--exclude-table <tables>` | Tablas a excluir |
| `--only-table <tables>` | Solo estas tablas |
| `--force` | Eliminar y recrear DB existente |
| `--verbose` | Salida detallada |
| `--dry-run` | Mostrar sin ejecutar |

---

## Licencia

MIT License

## Contribuir

Los pull requests son bienvenidos.
