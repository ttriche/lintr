#' Lintr
#'
#' Checks adherence to a given style, syntax errors and possible semantic
#' issues.  Supports on the fly checking of R code edited with Emacs, Vim and
#' Sublime Text.
#' @name lintr
#' @seealso \code{\link{lint}}, \code{\link{lint_package}}, \code{\link{linters}}
NULL

#' Lint a given file
#'
#' Apply one or more linters to a file and return a list of lints found.
#' @param filename the given filename to lint.
#' @param linters a list of linter functions to apply see \code{\link{linters}}
#' for a full list of default and available linters.
#' @param cache toggle caching of lint results
#' @export
#' @name lint_file
lint <- function(filename, linters = default_linters, cache = FALSE) {

  if (!is.list(linters)) {
    name <- deparse(substitute(linters))
    linters <- list(linters)
    names(linters) <- name
  }

  source_expressions <- get_source_expressions(filename)

  lints <- list()
  itr <- 0

  if (isTRUE(cache)) {
    lint_cache <- load_cache(filename)
    lints <- retrieve_file(lint_cache, filename, linters)
    if (!is.null(lints)) {
      return(lints)
    }
  }

  for (expr in source_expressions$expressions) {
    for (linter in names(linters)) {
      if (cache && has_lint(lint_cache, expr, linter)) {

        lints[[itr <- itr + 1L]] <- retrieve_lint(lint_cache, expr, linter, source_expressions$lines)
      }
      else {

        expr_lints <- flatten_lints(linters[[linter]](expr))

        lints[[itr <- itr + 1L]] <- expr_lints
        if (cache) {
          cache_lint(lint_cache, expr, linter, expr_lints)
        }
      }
    }
  }

  if (inherits(source_expressions$error, "lint")) {
    lints[[itr <- itr + 1L]] <- source_expressions$error

    if (isTRUE(cache)) {
      cache_lint(lint_cache, list(filename=filename, content=""), "error", source_expressions$error)
    }
  }

  lints <- structure(reorder_lints(flatten_lints(lints)), class = "lints")

  if (isTRUE(cache)) {
    cache_file(lint_cache, filename, linters, lints)
    save_cache(lint_cache, filename)
  }

  lints
}

reorder_lints <- function(lints) {
  files <- vapply(lints, `[[`, character(1), "filename")
  lines <- vapply(lints, `[[`, integer(1), "line_number")
  columns <- vapply(lints, `[[`, integer(1), "column_number")
  lints[
    order(files,
      lines,
      columns)
    ]
}

#' Lint a package
#'
#' Apply one or more linters to all of the R files in a package.
#' @param path the path to the base directory of the package, if \code{NULL},
#' the base directory will be searched for by looking in the parent directories
#' of the current directory.
#' @param relative_path if \code{TRUE}, file paths are printed using their path
#' relative to the package base directory.  If \code{FALSE}, use the full
#' absolute path.
#' @param ... additional arguments passed to \code{\link{lint}}
#' @export
lint_package <- function(path = NULL, relative_path = TRUE, ...) {
  if (is.null(path)) {
    path <- find_package()
  }
  files <- dir(path=path,
    pattern = rex(".", one_of("Rr"), end),
    recursive = TRUE,
    full.names = TRUE)

  lints <- flatten_lints(lapply(files,
      function(file) {
        if (interactive()) {
          message(".", appendLF = FALSE)
        }
        lint(file, ...)
      }))

  if (interactive()) {
    message()
  }

  if (relative_path == TRUE) {
    lints[] <- lapply(lints,
      function(x) {
        x$filename <- re_substitutes(x$filename, rex(path), ".")
        x
      })
    attr(lints, "package_path") <- path
  }

  lints <- reorder_lints(lints)
  class(lints) <- "lints"
  lints
}

find_package <- function(path = getwd()) {
  start_wd <- getwd()
  on.exit(setwd(start_wd))
  setwd(path)

  prev_path <- ""
  while (!file.exists(file.path(prev_path, "DESCRIPTION"))) {
    # this condition means we are at the root directory, so give up
    if (prev_path %==% getwd()) {
      return(NULL)
    }
    prev_path <- getwd()
    setwd("..")
  }
  prev_path
}

pkg_name <- function(path = find_package()) {
  if (is.null(path)) {
    return(NULL)
  } else {
    read.dcf(file.path(path, "DESCRIPTION"), fields = "Package")[1]
  }
}

#' Create a \code{Lint} object
#' @param filename path to the source file that was linted.
#' @param line_number line number where the lint occurred.
#' @param column_number column the lint occurred.
#' @param type type of lint.
#' @param message message used to describe the lint error
#' @param line code source where the lint occured
#' @param ranges ranges on the line that should be emphasized.
#' @export
Lint <- function(filename, line_number = 1L, column_number = NULL,
  type = c("style", "warning", "error"),
  message = "", line = "", ranges = NULL) {

  type <- match.arg(type)

  structure(
    list(
      filename = filename,
      line_number = as.integer(line_number),
      column_number = as.integer(column_number) %||% 1L,
      type = type,
      message = message,
      line = line,
      ranges = ranges
      ),
    class="lint")
}

rstudio_source_markers <- function(lints) {

  # package path will be NULL unless it is a relative path
  package_path <- attr(lints, "package_path")

  # generate the markers
  markers <- lapply(lints, function(x) {
    filename <- if (!is.null(package_path)) {
      file.path(package_path, x$filename)
    } else {
      x$filename
    }

    marker <- list()
    marker$type <- x$type
    marker$file <- filename
    marker$line <- x$line_number
    marker$column <- x$column_number
    marker$message <- x$message
    marker
  })

  # request source markers
  rstudioapi::callFun("sourceMarkers",
                      name = "lintr",
                      markers = markers,
                      basePath = package_path,
                      autoSelect = "first")
}

highlight_string <- function(message, column_number = NULL, ranges = NULL) {

  maximum <- max(column_number, unlist(ranges))

  line <- fill_with(" ", maximum)

  lapply(ranges, function(range) {
    substr(line, range[1], range[2]) <<-
      fill_with("~", range[2] - range[1] + 1L)
    })

  substr(line, column_number, column_number + 1L) <- "^"

  line
}

fill_with <- function(character = " ", length = 1L) {
  paste0(collapse = "", rep.int(character, length))
}
