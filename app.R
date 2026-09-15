#!/usr/bin/env Rscript
#
# app.R
#
# Shiny web UI for migrate_access_to_postgres.R.
#
# Lets the user pick the Access database via a browser file-selection dialog,
# fill in the target PostgreSQL connection details, and run the same
# migration logic as the CLI script, with progress and a log shown in the
# page.
#
# ---------------------------------------------------------------------------
# SETUP
# ---------------------------------------------------------------------------
#
#   install.packages(c("shiny", "DBI", "odbc", "RPostgres", "optparse", "glue", "cli"))
#
# Same ODBC driver setup as migrate_access_to_postgres.R (see that file's
# header comment, or README.md) is required.
#
# ---------------------------------------------------------------------------
# RUN
# ---------------------------------------------------------------------------
#
#   Rscript -e "shiny::runApp('.', launch.browser = TRUE)"
#
# or, from an R session with this directory as the working directory:
#
#   shiny::runApp()
#
# ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(shiny)
})

# Pulls in run_migration(), validate_migration_args(), and friends without
# triggering the CLI entry point (see the sys.nframe() guard at the bottom
# of migrate_access_to_postgres.R).
source("migrate_access_to_postgres.R", local = TRUE)

ui <- fluidPage(
  titlePanel("Access → PostgreSQL Migration"),
  sidebarLayout(
    sidebarPanel(
      fileInput(
        "mdb_file",
        "Access database file",
        accept = c(".mdb", ".accdb"),
        placeholder = "Choose a .mdb / .accdb file..."
      ),
      tags$hr(),
      h4("PostgreSQL target"),
      textInput("pg_host", "Host", value = "localhost"),
      numericInput("pg_port", "Port", value = 5432, min = 1, max = 65535, step = 1),
      textInput("pg_db", "Database"),
      textInput("pg_user", "User"),
      passwordInput("pg_password", "Password"),
      textInput("pg_schema", "Schema", value = "public"),
      tags$hr(),
      h4("Options"),
      checkboxInput("dry_run", "Dry run (list tables only, write nothing)", value = FALSE),
      checkboxInput("overwrite", "Overwrite existing tables", value = FALSE),
      numericInput("batch_size", "Batch size", value = 10000, min = 1, step = 1000),
      textInput("tables", "Only these tables (comma-separated, optional)"),
      textInput("exclude", "Exclude tables (comma-separated, optional)"),
      textInput("odbc_driver", "ODBC driver override (optional)"),
      tags$hr(),
      actionButton("run", "Run migration", class = "btn-primary", width = "100%")
    ),
    mainPanel(
      uiOutput("summary_ui"),
      h4("Log"),
      verbatimTextOutput("log_output")
    )
  )
)

server <- function(input, output, session) {
  log_rv <- reactiveVal(character())
  summary_rv <- reactiveVal(NULL)

  append_log <- function(msg) log_rv(c(log_rv(), msg))

  observeEvent(input$run, {
    log_rv(character())
    summary_rv(NULL)

    if (is.null(input$mdb_file)) {
      showNotification("Please choose an Access database file.", type = "error")
      return(invisible())
    }

    # Shiny uploads land at a random temp path; give it back its real
    # extension so the ODBC driver detection/behavior matches the CLI script.
    ext <- tolower(tools::file_ext(input$mdb_file$name))
    if (!ext %in% c("mdb", "accdb")) {
      showNotification("File must be a .mdb or .accdb Access database.", type = "error")
      return(invisible())
    }
    mdb_path <- tempfile(fileext = paste0(".", ext))
    file.copy(input$mdb_file$datapath, mdb_path, overwrite = TRUE)
    on.exit(unlink(mdb_path), add = TRUE)

    args <- list(
      mdb = mdb_path,
      `pg-host` = input$pg_host,
      `pg-port` = as.integer(input$pg_port),
      `pg-db` = input$pg_db,
      `pg-user` = input$pg_user,
      `pg-password` = input$pg_password,
      `pg-schema` = if (nzchar(input$pg_schema)) input$pg_schema else "public",
      tables = if (nzchar(input$tables)) input$tables else NULL,
      exclude = if (nzchar(input$exclude)) input$exclude else NULL,
      `batch-size` = as.integer(input$batch_size),
      overwrite = isTRUE(input$overwrite),
      `dry-run` = isTRUE(input$dry_run),
      `odbc-driver` = if (nzchar(input$odbc_driver)) input$odbc_driver else NULL
    )

    validation_error <- tryCatch({
      validate_migration_args(args)
      NULL
    }, error = function(e) conditionMessage(e))

    if (!is.null(validation_error)) {
      showNotification(validation_error, type = "error", duration = NULL)
      return(invisible())
    }

    result <- withProgress(message = "Migrating", value = 0, {
      withCallingHandlers(
        tryCatch(
          run_migration(args),
          error = function(e) {
            append_log(paste("ERROR:", conditionMessage(e)))
            NULL
          }
        ),
        message = function(m) {
          txt <- sub("\n$", "", conditionMessage(m))
          if (nzchar(txt)) {
            append_log(txt)
            incProgress(0, detail = txt)
          }
          invokeRestart("muffleMessage")
        },
        warning = function(w) {
          append_log(paste("WARNING:", conditionMessage(w)))
          invokeRestart("muffleWarning")
        }
      )
    })

    if (!is.null(result) && !is.null(result$summary_rows)) {
      summary_rv(result$summary_rows)
    }
  })

  output$log_output <- renderText({
    lines <- log_rv()
    if (length(lines) == 0) return("(no output yet)")
    paste(lines, collapse = "\n")
  })

  output$summary_ui <- renderUI({
    rows <- summary_rv()
    if (is.null(rows) || length(rows) == 0) return(NULL)

    df <- do.call(rbind, lapply(names(rows), function(t) {
      r <- rows[[t]]
      data.frame(
        `Access table` = t,
        `PostgreSQL table` = r$table,
        Status = r$status,
        Rows = r$rows,
        check.names = FALSE,
        stringsAsFactors = FALSE
      )
    }))

    tagList(h4("Summary"), renderTable(df)())
  })
}

shinyApp(ui, server)
