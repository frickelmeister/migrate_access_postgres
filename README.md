# migrate_access_to_postgres.R

Migrates every user table (schema + data) from a Microsoft Access database
(`.mdb` / `.accdb`) into a PostgreSQL database, table by table, streamed in
batches.

## What it does

1. Connects to the Access file over ODBC.
2. Lists all user tables (Access system tables, `MSys*`, are skipped
   automatically).
3. For each table (optionally filtered via `--tables` / `--exclude`):
   - Sanitizes the Access table/column names into valid, lowercase,
     deduplicated PostgreSQL identifiers (spaces, mixed case, and special
     characters in Access names are normalized to `snake_case`).
   - Streams the rows out of Access in batches (`--batch-size`) and appends
     them into a matching PostgreSQL table, so large tables don't need to be
     fully materialized in R memory at once.
   - Creates the target table on the first batch; on later batches it just
     appends.
4. Prints a per-table progress log and a final summary (rows migrated /
   skipped / failed per table).

## Requirements

### R packages

```r
install.packages(c("DBI", "odbc", "RPostgres", "optparse", "glue", "cli"))
```

### ODBC driver for Access

- **Windows**: uses the "Microsoft Access Driver (\*.mdb, \*.accdb)", which
  ships with Access or the free *Access Database Engine* redistributable.
  No extra setup needed.

- **Linux / macOS**: requires [mdbtools](https://github.com/mdbtools/mdbtools)
  and its ODBC driver, registered with unixODBC.

  ```bash
  # Debian/Ubuntu
  sudo apt-get install mdbtools mdbtools-dev unixodbc unixodbc-dev

  # macOS (Homebrew)
  brew install mdbtools unixodbc
  ```

  Register the driver once (locate the actual `.so` with
  `find / -name "libmdbodbc*"` if the path below doesn't match your system):

  ```bash
  sudo odbcinst -i -d -f /etc/mdbtools/odbcinst.ini
  ```

  or add it manually to `/etc/odbcinst.ini`:

  ```ini
  [MDBTools]
  Description = MDBTools ODBC Driver
  Driver      = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so
  Setup       = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so
  FileUsage   = 1
  ```

  Verify the driver is registered and can open the file:

  ```bash
  odbcinst -j
  odbcinst -q -d
  isql -v MDBTools /path/to/db.mdb
  ```

### PostgreSQL

A reachable PostgreSQL server and a database/user with permission to create
schemas and tables in the target database.

## Usage

```bash
Rscript migrate_access_to_postgres.R \
  --mdb /path/to/database.accdb \
  --pg-host localhost \
  --pg-port 5432 \
  --pg-db mydatabase \
  --pg-user postgres \
  --pg-schema public \
  --overwrite \
  --batch-size 10000
```

The PostgreSQL password can be passed via `--pg-password` or, preferably,
via the `PGPASSWORD` environment variable so it doesn't end up in shell
history:

```bash
PGPASSWORD=secret Rscript migrate_access_to_postgres.R --mdb db.accdb --pg-db mydb --pg-user postgres
```

`PGHOST`, `PGPORT`, `PGDATABASE`, and `PGUSER` are also read from the
environment as defaults if the matching flags are omitted.

### Options

| Flag | Default | Description |
|---|---|---|
| `--mdb` | *(required)* | Path to the Access `.mdb`/`.accdb` file |
| `--pg-host` | `localhost` / `$PGHOST` | PostgreSQL host |
| `--pg-port` | `5432` / `$PGPORT` | PostgreSQL port |
| `--pg-db` | `$PGDATABASE` | PostgreSQL database name *(required unless `--dry-run`)* |
| `--pg-user` | `$PGUSER` | PostgreSQL user *(required unless `--dry-run`)* |
| `--pg-password` | `$PGPASSWORD` | PostgreSQL password |
| `--pg-schema` | `public` | Target schema (created automatically if missing) |
| `--tables` | *(all)* | Comma-separated list of Access table names to migrate |
| `--exclude` | *(none)* | Comma-separated list of Access table names to skip |
| `--batch-size` | `10000` | Rows fetched/written per batch |
| `--overwrite` | off | Drop and recreate target tables if they already exist |
| `--dry-run` | off | List tables and row counts only; writes nothing to PostgreSQL |
| `--odbc-driver` | auto | Override the ODBC driver name (auto-detected by OS otherwise) |

Run `Rscript migrate_access_to_postgres.R --help` to see this listing from
the script itself.

### Dry run first

Before migrating for real, do a dry run to confirm the script can see the
expected tables and row counts:

```bash
Rscript migrate_access_to_postgres.R --mdb /path/to/database.accdb --dry-run
```

## Identifier naming

Access allows spaces, mixed case, and special characters in table/column
names; PostgreSQL doesn't accommodate those well without quoting everywhere.
The script normalizes every identifier by:

1. Lowercasing.
2. Replacing any run of non-`[a-z0-9_]` characters with a single `_`.
3. Trimming leading/trailing underscores.
4. Prefixing with `t_` if the name starts with a digit.
5. Truncating to 63 bytes (PostgreSQL's `NAMEDATALEN` limit).
6. Deduplicating collisions (`name`, `name_2`, `name_3`, ...).

Example: `Customer Orders` → `customer_orders`, `2024 Sales` → `t_2024_sales`.

## Known limitations

- **Primary keys, foreign keys, and indexes are not migrated.** Only table
  schema (inferred from the data) and row data are transferred. Recreate
  constraints and indexes manually in PostgreSQL after migration, or extend
  the script if you need this automated.
- **Access queries (saved queries) are not migrated**, only real tables.
- Column *data types* are inferred by `RPostgres`/`DBI` from the R types
  returned over ODBC (e.g. Access "Yes/No" → `boolean`, Date/Time →
  `timestamp`, OLE Object/binary → `bytea`). Review the resulting column
  types in PostgreSQL, especially for Memo fields and any Access-specific
  types, and adjust with `ALTER TABLE` if needed.
- Tables that already exist in the target schema are **skipped** unless
  `--overwrite` is passed (which drops and recreates them — this destroys
  any existing data in that PostgreSQL table).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Failed to connect to the Access database` | ODBC driver not installed/registered. Check `odbcinst -j` and `odbcinst -q -d`; on Linux confirm `mdbtools` is installed and the `MDBTools` driver entry exists in `/etc/odbcinst.ini`. |
| Garbled text in migrated character columns | Confirm the source `.mdb`/`.accdb` isn't using an unusual code page; mdbtools normally returns UTF-8. |
| `relation already exists` / table skipped silently | Table already exists in the target schema; rerun with `--overwrite` if you want it replaced. |
| Very large tables run out of memory | Lower `--batch-size`; the script streams via `dbFetch(n = batch_size)` so smaller batches reduce peak memory. |
| Migration is slow | Batch inserts are already used; wrapping the whole run in a single PostgreSQL transaction, or temporarily dropping target indexes/constraints before a bulk load, can help further — not done automatically to keep the script simple and safe to re-run per table. |
