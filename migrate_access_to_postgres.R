#!/usr/bin/env Rscript
#
# migrate_access_to_postgres.R
#
# Migrates every user table (and optionally its data) from a Microsoft
# Access database (.mdb / .accdb) into a PostgreSQL database.
#
# ---------------------------------------------------------------------------
# SETUP
# ---------------------------------------------------------------------------
# R packages (install once):
#
#   install.packages(c("DBI", "odbc", "RPostgres", "optparse", "glue", "cli"))
#
# ODBC driver for Access:
#
#   * Windows: the "Microsoft Access Driver (*.mdb, *.accdb)" ships with
#     Access / the free "Access Database Engine" redistributable. No extra
#     setup needed - odbc::odbc() will find it.
#
#   * Linux / macOS: install mdbtools and its ODBC driver, then register it
#     with unixODBC.
#
#       # Debian/Ubuntu
#       sudo apt-get install mdbtools mdbtools-dev unixodbc unixodbc-dev
#
#       # macOS (Homebrew)
#       brew install mdbtools unixodbc
#
#     Register the driver once (find the actual .so path with
#     `mdbtools-config --libs` or `find / -name "libmdbodbc*"`):
#
#       sudo odbcinst -i -d -f /etc/mdbtools/odbcinst.ini
#
#     or add manually to /etc/odbcinst.ini:
#
#       [MDBTools]
#       Description = MDBTools ODBC Driver
#       Driver      = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so
#       Setup       = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbc.so
#       FileUsage   = 1
#
#     Verify with: odbcinst -j    and   isql -v MDBTools /path/to/db.mdb
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#
#   Rscript migrate_access_to_postgres.R \
#     --mdb /path/to/database.accdb \
#     --pg-host localhost \
#     --pg-port 5432 \
#     --pg-db mydatabase \
#     --pg-user postgres \
#     --pg-schema public \
#     --overwrite \
#     --batch-size 10000
#
#   PGPASSWORD can be supplied via the PGPASSWORD env var instead of a flag.
#
#   Run with --dry-run to only list the tables that would be migrated and
#   the row counts, without touching PostgreSQL.
#
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(DBI)
  library(odbc)
  library(RPostgres)
  library(optparse)
  library(glue)
  library(cli)
})

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------

option_list <- list(
  make_option("--mdb", type = "character", help = "Path to the Access .mdb/.accdb file [required]"),
  make_option("--pg-host", type = "character", default = Sys.getenv("PGHOST", "localhost"), help = "PostgreSQL host [default: %default]"),
  make_option("--pg-port", type = "integer", default = as.integer(Sys.getenv("PGPORT", "5432")), help = "PostgreSQL port [default: %default]"),
  make_option("--pg-db", type = "character", default = Sys.getenv("PGDATABASE", ""), help = "PostgreSQL database name [required]"),
  make_option("--pg-user", type = "character", default = Sys.getenv("PGUSER", ""), help = "PostgreSQL user [required]"),
  make_option("--pg-password", type = "character", default = Sys.getenv("PGPASSWORD", ""), help = "PostgreSQL password (or set PGPASSWORD env var)"),
  make_option("--pg-schema", type = "character", default = "public", help = "Target schema [default: %default]"),
  make_option("--tables", type = "character", default = NULL, help = "Comma-separated list of table names to migrate (default: all user tables)"),
  make_option("--exclude", type = "character", default = NULL, help = "Comma-separated list of table names to skip"),
  make_option("--batch-size", type = "integer", default = 10000L, help = "Rows per batch when streaming into PostgreSQL [default: %default]"),
  make_option("--overwrite", action = "store_true", default = FALSE, help = "Drop and recreate target tables if they already exist"),
  make_option("--dry-run", action = "store_true", default = FALSE, help = "List tables/row counts only, write nothing to PostgreSQL"),
  make_option("--odbc-driver", type = "character", default = NULL, help = "Override the ODBC driver name (default: auto-detect by OS)")
)

parse_args_safely <- function() {
  parser <- OptionParser(option_list = option_list)
  args <- parse_args(parser)

  if (is.null(args$mdb) || !nzchar(args$mdb)) {
    print_help(parser)
    cli_abort("--mdb is required")
  }
  if (!file.exists(args$mdb)) {
    cli_abort("Access file not found: {args$mdb}")
  }
  if (!args$`dry-run`) {
    if (!nzchar(args$`pg-db`))   cli_abort("--pg-db is required (or set PGDATABASE)")
    if (!nzchar(args$`pg-user`)) cli_abort("--pg-user is required (or set PGUSER)")
  }
  args
}

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------

connect_access <- function(mdb_path, driver_override = NULL) {
  driver <- driver_override
  if (is.null(driver)) {
    driver <- if (.Platform$OS.type == "windows") {
      if (grepl("\\.accdb$", mdb_path, ignore.case = TRUE)) {
        "Microsoft Access Driver (*.mdb, *.accdb)"
      } else {
        "Microsoft Access Driver (*.mdb, *.accdb)"
      }
    } else {
      "MDBTools"
    }
  }
  cli_inform("Connecting to Access via ODBC driver {.val {driver}} ...")
  tryCatch(
    dbConnect(odbc::odbc(), driver = driver, dbq = mdb_path),
    error = function(e) {
      cli_abort(c(
        "Failed to connect to the Access database.",
        "x" = conditionMessage(e),
        "i" = "On Linux/macOS make sure mdbtools + the MDBTools ODBC driver are installed and registered (see header comments in this script).",
        "i" = "Run {.code odbcinst -j} and {.code odbcinst -q -d} to check driver registration."
      ))
    }
  )
}

connect_postgres <- function(host, port, dbname, user, password, schema) {
  cli_inform("Connecting to PostgreSQL {.val {dbname}} on {.val {host}}:{port} ...")
  con <- dbConnect(
    RPostgres::Postgres(),
    host = host, port = port, dbname = dbname,
    user = user, password = password
  )
  dbExecute(con, glue('CREATE SCHEMA IF NOT EXISTS "{schema}"'))
  con
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Access system tables (MSys*) and any query "tables" reported by the driver
# should never be migrated as data tables.
list_access_tables <- function(con) {
  all_tables <- dbListTables(con)
  all_tables[!grepl("^MSys", all_tables, ignore.case = TRUE)]
}

# Turn an arbitrary Access identifier into a safe, unquoted Postgres
# identifier: lowercase, ascii alnum + underscore, doesn't start with a
# digit, <= 63 bytes (Postgres' NAMEDATALEN limit).
sanitize_identifier <- function(name) {
  clean <- tolower(name)
  clean <- gsub("[^a-z0-9_]+", "_", clean)
  clean <- gsub("_+", "_", clean)
  clean <- gsub("^_|_$", "", clean)
  if (grepl("^[0-9]", clean)) clean <- paste0("t_", clean)
  if (!nzchar(clean)) clean <- "unnamed"
  substr(clean, 1, 63)
}

# Deduplicate a vector of sanitized names by appending _2, _3, ... to repeats.
dedupe_names <- function(names_vec) {
  make.unique(names_vec, sep = "_")
}

# Access-specific column fixups before handing a chunk to RPostgres:
#   - Access "Yes/No" fields sometimes arrive as raw 0/1 integers instead of
#     logical; leave them as-is, RPostgres maps R logical -> boolean fine.
#   - OLE Object / binary fields arrive as a list of raw vectors (blob) -
#     RPostgres understands that natively as bytea.
#   - Character encoding: mdbtools returns UTF-8 already; force it to be
#     safe against locale surprises.
fix_column_types <- function(df) {
  char_cols <- vapply(df, is.character, logical(1))
  df[char_cols] <- lapply(df[char_cols], function(x) {
    Encoding(x) <- "UTF-8"
    x
  })
  df
}

# ---------------------------------------------------------------------------
# Core migration for a single table, streamed in batches so large tables
# don't need to fit in memory twice (once in Access, once in Postgres).
# ---------------------------------------------------------------------------

migrate_table <- function(access_con, pg_con, access_table, pg_schema,
                           pg_table, batch_size, overwrite) {
  qualified <- Id(schema = pg_schema, table = pg_table)

  exists_already <- dbExistsTable(pg_con, qualified)
  if (exists_already) {
    if (overwrite) {
      cli_inform("  Dropping existing table {.val {pg_schema}.{pg_table}}")
      dbExecute(pg_con, glue('DROP TABLE IF EXISTS "{pg_schema}"."{pg_table}"'))
      exists_already <- FALSE
    } else {
      cli_warn("  Table {.val {pg_schema}.{pg_table}} already exists, skipping (use --overwrite to replace).")
      return(invisible(list(table = pg_table, rows = 0L, status = "skipped")))
    }
  }

  quoted_access_table <- if (grepl("\\s", access_table)) {
    glue("[{access_table}]")
  } else {
    access_table
  }

  res <- dbSendQuery(access_con, glue("SELECT * FROM {quoted_access_table}"))
  on.exit(dbClearResult(res), add = TRUE)

  total_rows <- 0L
  first_chunk <- TRUE

  repeat {
    chunk <- dbFetch(res, n = batch_size)
    if (nrow(chunk) == 0L) break

    chunk <- fix_column_types(chunk)

    if (first_chunk) {
      names(chunk) <- dedupe_names(sanitize_identifier(names(chunk)))
      dbWriteTable(pg_con, qualified, chunk, append = FALSE, overwrite = FALSE, row.names = FALSE)
      first_chunk <- FALSE
    } else {
      names(chunk) <- dedupe_names(sanitize_identifier(names(chunk)))
      dbWriteTable(pg_con, qualified, chunk, append = TRUE, row.names = FALSE)
    }

    total_rows <- total_rows + nrow(chunk)
    cli_inform("  ... {total_rows} rows written")

    if (dbHasCompleted(res)) break
  }

  if (first_chunk) {
    # Table had zero rows: still create an (empty) matching table so schema
    # comparisons downstream don't break.
    empty <- dbReadTable(access_con, access_table)
    empty <- fix_column_types(empty)[0, , drop = FALSE]
    names(empty) <- dedupe_names(sanitize_identifier(names(empty)))
    dbWriteTable(pg_con, qualified, empty, append = FALSE, row.names = FALSE)
  }

  invisible(list(table = pg_table, rows = total_rows, status = "migrated"))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main <- function() {
  args <- parse_args_safely()

  access_con <- connect_access(args$mdb, args$`odbc-driver`)
  on.exit(try(dbDisconnect(access_con), silent = TRUE), add = TRUE)

  available_tables <- list_access_tables(access_con)
  if (length(available_tables) == 0L) {
    cli_abort("No user tables found in {args$mdb}")
  }

  requested   <- if (!is.null(args$tables))  trimws(strsplit(args$tables, ",")[[1]])  else available_tables
  excluded    <- if (!is.null(args$exclude)) trimws(strsplit(args$exclude, ",")[[1]]) else character(0)
  tables_todo <- setdiff(intersect(requested, available_tables), excluded)

  missing <- setdiff(requested, available_tables)
  if (length(missing) > 0) {
    cli_warn("Requested tables not found in Access DB, ignoring: {paste(missing, collapse = ', ')}")
  }
  if (length(tables_todo) == 0L) {
    cli_abort("Nothing to migrate after applying --tables/--exclude filters.")
  }

  cli_h1("Tables to migrate ({length(tables_todo)})")
  for (t in tables_todo) {
    n <- tryCatch(
      dbGetQuery(access_con, glue("SELECT COUNT(*) AS n FROM {if (grepl('\\\\s', t)) glue('[{t}]') else t}"))$n,
      error = function(e) NA_integer_
    )
    cli_li("{t}  ({n} rows)")
  }

  if (isTRUE(args$`dry-run`)) {
    cli_inform("Dry run only — no data written to PostgreSQL.")
    return(invisible())
  }

  pg_con <- connect_postgres(
    host = args$`pg-host`, port = args$`pg-port`, dbname = args$`pg-db`,
    user = args$`pg-user`, password = args$`pg-password`, schema = args$`pg-schema`
  )
  on.exit(try(dbDisconnect(pg_con), silent = TRUE), add = TRUE)

  pg_names <- dedupe_names(vapply(tables_todo, sanitize_identifier, character(1)))

  cli_h1("Migrating")
  summary_rows <- list()
  for (i in seq_along(tables_todo)) {
    access_table <- tables_todo[i]
    pg_table <- pg_names[i]
    cli_inform("Table {.val {access_table}} -> {.val {args$`pg-schema`}.{pg_table}}")
    result <- tryCatch(
      migrate_table(access_con, pg_con, access_table, args$`pg-schema`, pg_table,
                     args$`batch-size`, args$overwrite),
      error = function(e) {
        cli_warn("  Failed: {conditionMessage(e)}")
        list(table = pg_table, rows = NA_integer_, status = "error")
      }
    )
    summary_rows[[access_table]] <- result
  }

  cli_h1("Summary")
  for (t in names(summary_rows)) {
    r <- summary_rows[[t]]
    cli_li("{t} -> {r$table}: {r$status} ({r$rows} rows)")
  }
}

if (identical(environment(), globalenv()) || sys.nframe() == 0L) {
  main()
}
