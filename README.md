# migrate_access_to_postgres.R

Migrates every user table (schema + data) from a Microsoft Access database
(`.mdb` / `.accdb`) into a PostgreSQL database, table by table, streamed in
batches.

Two ways to run it:

- **CLI**: `migrate_access_to_postgres.R`, driven by command-line flags (see
  [Usage](#usage) below).
- **Web UI**: `app.R`, a [Shiny](https://shiny.posit.co/) app that prompts
  for the Access file via a browser file-selection dialog and for the
  PostgreSQL connection details via a form (see
  [Web UI (Shiny app)](#web-ui-shiny-app)).

Both share the same underlying migration logic in
`migrate_access_to_postgres.R`.

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

To use the web UI (`app.R`) as well, also install `shiny`:

```r
install.packages("shiny")
```

### ODBC driver for Access

- **Windows**: uses the "Microsoft Access Driver (\*.mdb, \*.accdb)", which
  ships with Access or the free *Access Database Engine* redistributable.
  No extra setup needed.

- **Linux / macOS**: requires [mdbtools](https://github.com/mdbtools/mdbtools)
  and its ODBC driver, registered with unixODBC.

  ```bash
  # Debian/Ubuntu — the ODBC driver itself (libmdbodbc.so) is packaged
  # separately from the mdbtools CLI tools as odbc-mdbtools
  sudo apt-get install mdbtools mdbtools-dev odbc-mdbtools unixodbc unixodbc-dev

  # macOS (Homebrew)
  brew install mdbtools unixodbc
  ```

  Current Debian/Ubuntu packages of mdbtools don't ship an
  `/etc/mdbtools/odbcinst.ini` to register with (older versions did), so
  register the driver manually instead. Locate the actual `.so` first if the
  path below doesn't match your system (`dpkg -L odbc-mdbtools | grep so$` on
  Debian/Ubuntu, or `find / -name "libmdbodbc*"` otherwise):

  ```bash
  cat <<'EOF' > /tmp/mdbtools-odbcinst.ini
  [MDBTools]
  Description = MDBTools ODBC Driver
  Driver      = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so
  Setup       = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so
  FileUsage   = 1
  EOF
  sudo odbcinst -i -d -f /tmp/mdbtools-odbcinst.ini
  rm /tmp/mdbtools-odbcinst.ini
  ```

  (Equivalently, add the same `[MDBTools]` block by hand to `/etc/odbcinst.ini`.)

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

## Web UI (Shiny app)

`app.R` provides a browser-based form for the same migration, for anyone who
doesn't want to use the command line. It reuses `run_migration()` and
`validate_migration_args()` from `migrate_access_to_postgres.R` (sourced by
`app.R`), so behavior matches the CLI script exactly.

Start it from this directory:

```bash
Rscript -e "shiny::runApp('.', launch.browser = TRUE)"
```

or, from an R session with this directory as the working directory:

```r
shiny::runApp()
```

This opens a page with:

- A **file input** that opens the browser's native file-selection dialog to
  pick the `.mdb`/`.accdb` file (instead of typing a `--mdb` path).
- Fields for the PostgreSQL **host, port, database, user, password, and
  schema** (equivalent to `--pg-host`/`--pg-port`/`--pg-db`/`--pg-user`/
  `--pg-password`/`--pg-schema`).
- The same options as the CLI: dry run, overwrite, batch size, table
  include/exclude filters, and an ODBC driver override.
- A **Run migration** button that shows a progress indicator while it runs,
  then a summary table (per-table status and row counts) and a full log of
  what happened.

Notes:

- The app must run on a machine that has the ODBC driver set up (see
  [ODBC driver for Access](#odbc-driver-for-access) above) and network
  access to the target PostgreSQL server — the same requirements as the CLI
  script.
- Selecting a file uploads a copy of it to the machine running the Shiny
  app (this is how browser file inputs work). For local use — running
  `app.R` on your own machine and opening it in your own browser — this is
  effectively instant since no network is involved. If you deploy `app.R`
  to a remote Shiny server, be aware the whole Access file is transferred
  over that connection first.
- The password field is masked in the UI but is otherwise handled the same
  way as `--pg-password`/`PGPASSWORD` (sent to `RPostgres::Postgres()`,
  never written to disk by the app itself).

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
