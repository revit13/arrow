# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

#' @importFrom utils object.size
.serialize_arrow_r_metadata <- function(x) {
  assert_is(x, "list")

  # drop problems attributes (most likely from readr)
  x[["attributes"]][["problems"]] <- NULL

  out <- serialize(x, NULL, ascii = TRUE)

  # if the metadata is over 100 kB, compress
  if (option_compress_metadata() && object.size(out) > 100000) {
    out_comp <- serialize(memCompress(out, type = "gzip"), NULL, ascii = TRUE)

    # but ensure that the compression+serialization is effective.
    if (object.size(out) > object.size(out_comp)) out <- out_comp
  }

  rawToChar(out)
}

.unserialize_arrow_r_metadata <- function(x) {
  tryCatch({
    out <- unserialize(charToRaw(x))

    # if this is still raw, try decompressing
    if (is.raw(out)) {
      out <- unserialize(memDecompress(out, type = "gzip"))
    }
    out
  }, error = function(e) {
    warning("Invalid metadata$r", call. = FALSE)
    NULL
  })
}

apply_arrow_r_metadata <- function(x, r_metadata) {
  tryCatch({
    columns_metadata <- r_metadata$columns
    if (is.data.frame(x)) {
      if (length(names(x)) && !is.null(columns_metadata)) {
        for (name in intersect(names(columns_metadata), names(x))) {
          x[[name]] <- apply_arrow_r_metadata(x[[name]], columns_metadata[[name]])
        }
      }
    } else if (is.list(x) && !inherits(x, "POSIXlt") && !is.null(columns_metadata)) {
      x <- map2(x, columns_metadata, function(.x, .y) {
        apply_arrow_r_metadata(.x, .y)
      })
      x
    }

    if (!is.null(r_metadata$attributes)) {
      attributes(x)[names(r_metadata$attributes)] <- r_metadata$attributes
      if (inherits(x, "POSIXlt")) {
        # We store POSIXlt as a StructArray, which is translated back to R
        # as a data.frame, but while data frames have a row.names = c(NA, nrow(x))
        # attribute, POSIXlt does not, so since this is now no longer an object
        # of class data.frame, remove the extraneous attribute
        attr(x, "row.names") <- NULL
      }
    }

  }, error = function(e) {
    warning("Invalid metadata$r", call. = FALSE)
  })
  x
}

arrow_attributes <- function(x, only_top_level = FALSE) {
  att <- attributes(x)

  removed_attributes <- character()
  if (identical(class(x), c("tbl_df", "tbl", "data.frame"))) {
    removed_attributes <- c("class", "row.names", "names")
  } else if (inherits(x, "data.frame")) {
    removed_attributes <- c("row.names", "names")
  } else if (inherits(x, "factor")) {
    removed_attributes <- c("class", "levels")
  } else if (inherits(x, "integer64") || inherits(x, "Date")) {
    removed_attributes <- c("class")
  } else if (inherits(x, "POSIXct")) {
    removed_attributes <- c("class", "tzone")
  } else if (inherits(x, "hms") || inherits(x, "difftime")) {
    removed_attributes <- c("class", "units")
  }

  att <- att[setdiff(names(att), removed_attributes)]
  if (isTRUE(only_top_level)) {
    return(att)
  }

  if (is.data.frame(x)) {
    columns <- map(x, arrow_attributes)
    out <- if (length(att) || !all(map_lgl(columns, is.null))) {
      list(attributes = att, columns = columns)
    }
    return(out)
  }

  columns <- NULL
  if (is.list(x) && !inherits(x, "POSIXlt")) {
    # for list columns, we also keep attributes of each
    # element in columns
    columns <- map(x, arrow_attributes)
    if (all(map_lgl(columns, is.null))) {
      columns <- NULL
    }
  }

  if (length(att) || !is.null(columns)) {
    list(attributes = att, columns = columns)
  } else {
    NULL
  }
}
