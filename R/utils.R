if (getRversion() >= "2.15.1")  utils::globalVariables(".")

#' Extracts the JSON data from an HTTP response
#' @param response The HTTP response
#' @return The json
.get_json <- function(response){
  json_response <- tibble::tibble()
  if (!is.null(response)) {
    json_response <- httr::content(response, as = "text", encoding="UTF-8") %>%
      jsonlite::fromJSON(flatten = TRUE)
  }

  return(json_response)
}

.req_succeeded <- function(status_code) {
  return(status_code >= .COD_REQ_SUCCESS_MIN && status_code < .COD_REQ_SUCCESS_MAX)
}

.is_client_error <- function(status_code) {
  return(status_code >= .COD_ERRO_CLIENTE && status_code < .COD_ERRO_SERV)
}

.is_server_error <- function(status_code) {
  return(status_code >= .COD_ERRO_SERV)
}

.throw_req_error <- function(error_code, api_url){
  stop(sprintf(.MENSAGEM_ERRO_REQ, error_code, api_url), call. = FALSE)
}

.get_with_exponential_backoff_cached <- function(base_url, path=NULL, query=NULL,
                                                 base_sleep_time=.POWER_BASE_SLEEP_TIME,
                                                 max_attempts=.MAX_TENTATIVAS_REQ,
                                                 accept_json=FALSE) {
  num_tries <- 0
  status_code = 1000
  resp_in_cache = FALSE
  resp <- NULL

  if (is.null(base_url) || base_url == '') {
    warning("URL deve ser não-nula e não-vazia.")
    return(resp)
  }

  url <- httr::modify_url(base_url, path = path, query = query)


  while((!resp_in_cache) &&
        ((status_code >= .COD_ERRO_CLIENTE) && (num_tries < max_attempts))) {
    if (status_code == .COD_ERRO_NOT_FOUND) {
      break
    }

    if (num_tries > 0) {
      cat("\n","Error on Calling URL:",url," - Status Code:",status_code)
      sleep_time <- base_sleep_time^(num_tries)
      Sys.sleep(sleep_time)
    }

    resp <- .get_from_cache(api_url)

    if (is.null(resp)) {
      if (accept_json) resp <- httr::GET(url, httr::accept_json())
      else resp <- httr::GET(url)
      Sys.sleep(.DEF_POST_REQ_SLEEP_TIME)
      status_code <- httr::status_code(resp)
      num_tries <- num_tries + 1
    } else {
      resp_in_cache <- TRUE
      status_code <- 200
    }
  }

  if ((status_code >= .COD_ERRO_CLIENTE)) {
    warning("\n","Could not fetch from:",url," - Status Code:",status_code)
    .throw_req_error(status_code, url)
  }

  if (!resp_in_cache) .put_in_cache(url, resp)

  resp
}

.get_from_api_with_exponential_backoff_cached <- function(api_base=NULL, path=NULL, query=NULL){
  resp <- .get_with_exponential_backoff_cached(api_base, path, query, accept_json=TRUE)

  if (httr::http_type(resp) != "application/json") {
    stop(.ERRO_RETORNO_JSON, call. = FALSE)
  }

  return(resp)
}

.get_hrefs <- function(path=NULL, query=NULL) {
  resp <- .get_from_api_with_exponential_backoff_cached(.CAMARA_API_LINK, path, query)
  .get_json(resp)$links
}

#' Wraps an access to the camara API given a relative path and query arguments.
#' @param path URL relative to the API base URL
#' @param query Query parameters
#' @export
.camara_api <- function(path=NULL, query=NULL, asList = FALSE){

  resp <- .get_from_api_with_exponential_backoff_cached(.CAMARA_API_LINK, path, query)
  obtained_data <- .get_json(resp)$dados

  if(!is.data.frame(obtained_data) && !asList){
    obtained_data %>%
      .get_dataframe()
  } else obtained_data

}

#' Wraps an access to the senate API given a relative path and query arguments.
#' @param path URL relative to the API base URL
#' @param query Query parameters
#' @param asList If return should be a list or a dataframe
#' @export
.senado_api <- function(path=NULL, query=NULL, asList = FALSE){

  resp <- .get_from_api_with_exponential_backoff_cached(.SENADO_API_LINK, path, query)
  obtained_data <- .get_json(resp)
  if(!is.data.frame(obtained_data) && !asList){
    obtained_data %>%
      .get_dataframe()
  } else obtained_data

}

#' In case of receiving a list, this function converts the list into a dataframe.
#' @param x List
.get_dataframe <- function(x){
  x %>%
    #lapply(.replace_null) %>%
    unlist() %>%
    #.coerce_numeric() %>%
    as.list() %>%
    as.data.frame(stringsAsFactors = FALSE)
}

#' Prints a warning and a list.
#' @param msg warning message
#' @param l list
.print_warning_and_list <- function(msg, l) {
  cat(crayon::red("\n", msg, "\n  ", paste(l, collapse="\n   "),"\n"))
}

#' Garantees that the dataframe x has all the columns passed by y.
#' @param x dataframe
#' @param y vector of characters containing the names of columns.
#' @param warning boolean to show the prints
.assert_dataframe_completo <- function(x, y, warning = FALSE){
  if(nrow(x) != 0){
    colnames_x <- colnames(x)
    colnames_y <- names(y)
    types_y <- unname(y)
    indexes <- !(colnames_y %in% colnames_x)

    if (any(indexes) & warning) {
      .print_warning_and_list("Not found columns:", colnames_y[indexes])
    }
    nao_esperadas = colnames_x[!(colnames_x %in% colnames_y)]
    if (length(nao_esperadas) & warning) {
      .print_warning_and_list("Unexpected columns:", nao_esperadas)
    }
    
    if (any(indexes)) {
      df_y <- y %>%
        t() %>%
        as.data.frame()
      
      diff_df <- df_y[colnames_y[indexes]]
      
      diff_df <- diff_df %>%
        dplyr::mutate_all(.funs = ~ .replace_na(.))
      
      x <- x %>% 
        cbind(diff_df)
    }
    
    x
  } else tibble::tibble()
}

#' Given a column with its type as value, replace this value 
#' by the corresponding NA type.
#' @param x A column with a type (string) as value
.replace_na <- function(x) {
  if (x == "character") {
    x = as.character(NA)
  } else {
    x = as.numeric(NA)
  }
}

#' Garantees that the dataframe obj has all the correct types passed by types.
#' @param obj dataframe
#' @param types named vector of the columns names and types
.coerce_types <- function(obj, types, order_cols=TRUE){
  if(nrow(obj) != 0){
    if (order_cols) {
      obj <- obj[,order(colnames(obj))]
      types <- unname(types[sort(names(types))])
    } else {
      types <- unname(types[names(types)])
    }

    length(types) <- length(names(obj))
    types <- replace(types, is.na(types), "character")

    out <- lapply(1:length(obj),FUN = function(i){
      dynamic_cast <<-.switch_types(types[i])
      obj[,i] %>% unlist() %>% dynamic_cast
    })
    names(out) <- colnames(obj)
    as.data.frame(out,stringsAsFactors = FALSE)
  } else tibble::tibble()
}

#' Returns a conversion function given a type name.
#' @param x type name
.switch_types <- function(x){
  switch(x,
         character = as.character,
         numeric = as.numeric,
         integer = as.integer,
         is.na = NA,
         list = as.list,
         logical = as.logical)
}

#' Converts a vector of integer into a tibble. Also useful when the user is working with
#' dplyr functions.
#' @param num A integer vector
#' @return A tibble
#' @examples
#' df <- rcongresso:::.to_tibble(c(1,2))
#' @export
.to_tibble <- function(num) {
  if (is.null(num)) tibble::tibble()
  else tibble::tibble(num)
}

#' Verifies from the input if all the parameters are available and handles correctly
#' about the transformation into a valid URL query.
#' @param parametros A list of parameters from the input
#' @return A list of parameters without NULL
#' @examples
#' parametros <- rcongresso:::.verifica_parametros_entrada(list(NULL, itens=100, pagina=1))
#' @export
.verifica_parametros_entrada <- function(parametros) {
  is_missing <- parametros %>%
    purrr::map_lgl(is.null) %>%
    which()
  parametros[-is_missing]
}

#' Fetches a proposition using a list of queries
#'
#' @param parametros queries used on the search
#' @param API_path API path
#' @param asList If return should be a list or a dataframe
#'
#' @return Dataframe containing information about the proposition.
#'
#' @examples
#' pec241 <- rcongresso:::.fetch_using_queries(
#'    parametros = list(id = "2088351"),
#'    API_path = "/api/v2/proposicoes"
#' )
#'
#' @export
.fetch_using_queries <- function(parametros, API_path, asList = FALSE){
  if (!is.null(parametros$itens) && (parametros$itens == -1)){
    .fetch_all_items(.verifica_parametros_entrada(parametros), API_path)
  }
  else if (!is.null(parametros$itens)){
    .fetch_itens(.verifica_parametros_entrada(parametros), API_path)
  }
  else{
    .verifica_parametros_entrada(parametros) %>%
      tibble::as_tibble() %>%
      dplyr::rowwise() %>%
      dplyr::do(
        .camara_api(API_path, ., asList)
      )
  }
}

#' Fetches details from a proposition.
#'
#' @param id Proposition's ID
#' @param API_path API path
#' @param asList If return should be a list or a dataframe
#'
#' @return Dataframe containing information about the proposition.
#'
#' @examples
#' pec241 <- rcongresso:::.fetch_using_id(2088351, API_path = "/api/v2/proposicoes")
#'
#' @export
.fetch_using_id <- function(id, API_path, asList = FALSE){
  tibble::tibble(id) %>%
    dplyr::mutate(path = paste0(API_path, "/", id)) %>%
    dplyr::rowwise() %>%
    dplyr::do(
      .camara_api(.$path, asList = asList)
    ) %>%
    dplyr::ungroup()
}

#' Abstracts the pagination logic. There are three situations on a request from the API:
#' 1. The items number is less than the max by request, that is 100.
#' 2. The items number is divisible by 100.
#' 3. The items number is not divisible by 100.
#'
#' Case 1 and 2 are solved using the same logic: Fetches from the API the exact quantity
#' to fill n pages. 100 items fill into 1 page, 200 items fill into 2 pages and so on...
#'
#' Case 3 is solved using the previous thinking adding a little detail: Fetches all the items
#' until it fills completly the pages with 100 items each one, then insert the remaining
#' items. 530 items can also be read as 500 items + 30 items, then 5 pages with 100 items and
#' 1 page with 30 items.
#'
#' @param query query parameters
#' @param API_path API path
.fetch_itens <- function(query, API_path){

  query$pagina <- seq(1, query$itens/.MAX_ITENS)

  if((query$itens < .MAX_ITENS) || (query$itens %% .MAX_ITENS == 0)){
    query %>%
      tibble::as_tibble() %>%
      dplyr::rowwise() %>%
      dplyr::do(
        .camara_api(API_path, .)
      )
  } else {
    req_ultima_pagina <- query
    req_ultima_pagina$itens <- query$itens %% .MAX_ITENS
    req_ultima_pagina$pagina <- max(seq(1, query$itens/.MAX_ITENS)) +1
    query$itens <- .MAX_ITENS

    query %>%
      tibble::as_tibble() %>%
      dplyr::rowwise() %>%
      dplyr::do(
        .camara_api(API_path, .)
      ) %>%
      dplyr::bind_rows(req_ultima_pagina %>%
                         tibble::as_tibble() %>%
                         dplyr::rowwise() %>%
                         dplyr::do(
                           .camara_api(API_path, .)
                         ))
  }
}

#' Check if a proposition/party exists and returns a warning message when it does not.
#' @param x returned object from proposition or party function
#' @param message error message expected
.verifica_id <- function(x, message) {
  if(is.null(x)){
    warning(message)
    x
  } else x
}

.fetch_all_items <- function(query, API_path){

  href <- rel <- NULL

  query$itens <- .MAX_ITENS

  # Pegar pelo "last" e não buscar pelo índice diretamente, já que o índice pode variar.
  list_param <- .get_hrefs(path = API_path, query = query) %>%
    dplyr::filter(rel == "last") %>%
    dplyr::select(href) %>%
    purrr::pluck(1) %>%
    strsplit("/") %>%
    purrr::pluck(1, length(.[[1]])) %>%
    strsplit("&") %>%
    purrr::pluck(1)

  # Procurar pelo parâmetro página. Mesma lógica do babado aqui em cima.
  index_ult_pag <- list_param %>%
    stringr::str_detect("pagina")

  ult_pag <- list_param[index_ult_pag] %>%
    strsplit("=")

  query$itens <- as.integer(ult_pag[[1]][2]) * .MAX_ITENS

  .fetch_itens(query, API_path)
}

#' @title Renames dataframe's columns
#' @description Renames dataframe's columns using underscore and lowercase pattern.
#' @param df Dataframe
#' @return Dataframe with renamed columns.
.rename_df_columns <- function(df) {
  names(df) <- names(df) %>%
    .to_underscore
  df
}

#' @title Renames propositions dataframe's columns
#' @description Renames dataframe's columns using underscore and lowercase pattern and 
#' removing unnecessary strings from column names.
#' @param df Dataframe
#' @return Dataframe with renamed columns.
.rename_senate_propositions_df_columns <- function(df) {
  names(df) <- 
    stringr::str_remove_all(
      names(df),
      "IdentificacaoMateria\\.|DadosBasicosMateria\\.|NaturezaMateria\\.|AutoresPrincipais\\.AutorPrincipal\\.|SituacaoAtual\\.Autuacoes\\.Autuacao\\.|Situacoes\\.|LocalAdministrativo\\.")
  
  return(df %>% .rename_df_columns())
  
  }

#' @title Selects propositions by sigla dataframe's columns
#' @description Selects dataframe's columns renaming specific columns,
#  using underscore and lowercase pattern and 
#' removing unnecessary strings from column names.
#' @param df Dataframe
#' @return Dataframe with renamed columns.
.rename_senate_propositions_by_siglas_df_columns <- function(df) {
  df <- df %>%
    dplyr::select(
      codigo_materia = Codigo,
      sigla_subtipo_materia = Sigla,
      numero_materia = Numero,
      ano_materia = Ano,
      ementa_materia = Ementa,
      data_apresentacao = Data,
      nome_autor = Autor,
      descricao_identificacao_materia = DescricaoIdentificacao
    )
  return(df %>% .rename_senate_propositions_df_columns())
  
}
#' @title Renames a vector with the pattern of underscores and lowercases
#' @description Renames each item from vector with the pattern: split by underscore and lowercase
#' @param x Strings vector
#' @return Vector containing the renamed strings.
#' @export
.to_underscore <- function(x) {
  gsub('([A-Za-z])([A-Z])([a-z])', '\\1_\\2\\3', x) %>%
    gsub('.', '_', ., fixed = TRUE) %>%
    gsub('([a-z])([A-Z])', '\\1_\\2', .) %>%
    tolower()
}

#' @title Changes the column names of the input dataframe to underscore
#' @description Changes the column names of the input dataframe to underscore
#' @param df input dataframe
#' @return dataframe with underscore column names
#' @export
rename_table_to_underscore <- function(df) {
  new_names = names(df) %>%
    .to_underscore()

  names(df) <- new_names

  df
}

#' @title Renames the cols of the document's df on Senate
#' @description Renames each item from vector with the pattern: split by underscore and lowercase
#' @param documentos_df Dataframe
#' @return Dataframe containing the renamed strings.
.rename_documentos_senado <- function(documentos_df) {
  new_names = names(documentos_df) %>%
    .to_underscore() %>%
    stringr::str_replace(
      "/| ",
      "_") %>%
    .remove_special_character()

  names(documentos_df) <- new_names

  documentos_df
}

#' @title Replace special characters with it's normal value
#' @description Replace special characters with it's normal value
#' @param string_with_special String
#' @return String
.remove_special_character <- function(string_with_special) {
  iconv(string_with_special, from="UTF-8",
               to="ASCII//TRANSLIT")
}

#' @title Renames the cols of the bill's passage on Senate
#' @description Renames each item from vector with the pattern: split by underscore and lowercase
#' @param tramitacao_df Dataframe
#' @return Dataframe containing the renamed strings.
#' @export
.rename_tramitacao_df <- function(tramitacao_df) {
  new_names = names(tramitacao_df) %>%
    .to_underscore() %>%
    stringr::str_replace(
      "identificacao_tramitacao_|
      identificacao_tramitacao_origem_tramitacao_local_|
      identificacao_tramitacao_destino_tramitacao_local_|
      identificacao_tramitacao_situacao_",
      ""
    )

  names(tramitacao_df) <- new_names

  tramitacao_df
}

#' @title Renames the cols of the bill's voting on Senate
#' @description Renames each item from vector with the pattern: split by underscore and lowercase
#' @param df Dataframe
#' @return Dataframe containing the renamed strings.
#' @export
.rename_votacoes_df <- function(df) {
  new_names = names(df) %>%
    .to_underscore() %>%
    stringr::str_replace(
      "sessao_plenaria_|tramitacao_identificacao_tramitacao_|identificacao_parlamentar_",
      ""
    )

  names(df) <- new_names

  df
}

#' @title Get the author on Chamber
#' @description Return a dataframe with the link, name, code, type and house
#' @param prop_id Proposition ID
#' @return Dataframe contendo o link, o nome, o código do tipo, o tipo e a casa de origem do autor.
.extract_autor_in_camara <- function(prop_id) {
  camara_exp <- "camara dos deputados"
  senado_exp <- "senado federal"

  url <- paste0(.CAMARA_PROPOSICOES_PATH, "/", prop_id, "/autores")
  json_voting <- .camara_api(url, asList = T)

  authors <- json_voting %>%
    dplyr::rename(
      autor.uri = uri,
      autor.nome = nome,
      autor.tipo = tipo,
      autor.cod_tipo = codTipo) %>%
    dplyr::mutate(casa_origem =
                    dplyr::case_when(
                      stringr::str_detect(iconv(c(tolower(autor.nome)), from="UTF-8", to="ASCII//TRANSLIT"), camara_exp) | autor.tipo == "Deputado" ~ "Camara dos Deputados",
                      stringr::str_detect(tolower(autor.nome), senado_exp) | autor.tipo == "Senador" ~ "Senado Federal",
                      autor.cod_tipo == 40000 ~ "Senado Federal",
                      autor.cod_tipo == 2 ~ "Camara dos Deputados"))

  partido_estado <- rcongresso::extract_partido_estado_autor(authors$autor.uri %>% tail(1))

  authors %>%
    dplyr::mutate(autor.nome = paste0(autor.nome, " ", partido_estado))
}

#' @title Safely returns column value from dataframe
#' @description Returns column value if exists
#' @param df Dataframe from whom column value will be retrieved
#' @param col_name name of column whose value will be retrieved
#' @return Column value if column exists, NA otherwise.
.safe_get_value_coluna <- function(df, col_name) {
  if (col_name %in% names(df)) {
    return(df %>% dplyr::select((!!(col_name))) %>% dplyr::pull(!!(col_name)))
  } else {
    return(NA)
  }
}

.warnings_props_sigla <- function(sigla, numero, ano) {
  if(is.na(sigla) | is.na(numero) | is.na(ano)) {
    warning("Todos os parametros devem ser diferentes de NA")
    return(T)
  }

  if(sigla == '') {
    warning("Sigla nao pode ser vazia")
    return(T)
  }

  if(numero < 0 | ano < 0) {
    warning("Numero e ano devem ser positivos")
    return(T)
  }

  return(F)
}

#' @title Runs a given function after a specified delay
#' @description Runs a given function after a specified delay
#' @param delay delay to sleep before running function
#' @param fun function (with/out parameters or not) to be run after delay
#' @return the return value of the function
run_function_with_delay <- function(delay, fun) {
  Sys.sleep(delay)
  fun
}

#' @title Unnests a nested column from a dataframe
#' @description Unnests a nested column from a dataframe
#' @param base_df base dataframe from which nested column will be unnested
#' @param base_columns base columns to keep after dataframe is unnested
#' @param nested_column colum to be unnested
#' @return the dataframe with both the base and unnested column columns
.unnest_df_column <- function(base_df, base_columns, nested_column) {
  unnested_column_df <- base_df %>%
    dplyr::select_at(c(base_columns, nested_column)) %>%
    tidyr::unnest(cols = all_of(nested_column)) %>%
    dplyr::distinct() %>%
    dplyr::group_by_at(base_columns) %>%
    dplyr::summarise_each(~ paste(., collapse = ";")) %>%
    dplyr::ungroup()
}

#' @title Create a dataframe from list
#' @description Create a dataframe with senator's info
#' @param senator_data base list from which selected column will be returned
#' @return the dataframe with the senator's indo
.create_senator_dataframe <- function(senator_data) {
  if ("UltimoMandato" %in% names(senator_data)) {
    ufs <- senator_data$UltimoMandato$UfParlamentar
    uf <- ufs[length(ufs)]
    situacoes <- senator_data$UltimoMandato$DescricaoParticipacao
    situacao <- situacoes[length(situacoes)]
  } else if ("MandatoAtual" %in% names(senator_data)) {
    uf <- senator_data$MandatoAtual$UfParlamentar
    situacao <- senator_data$MandatoAtual$DescricaoParticipacao
  } else {
    uf <- NA
    situacao <- NA
  }

  if ("SiglaPartidoParlamentar" %in% names(senator_data$IdentificacaoParlamentar)) {
    partido <- senator_data$IdentificacaoParlamentar$SiglaPartidoParlamentar
  } else {
    partido <- NA
  }

  df <- tibble::tibble(
    id_parlamentar = senator_data$IdentificacaoParlamentar$CodigoParlamentar,
    nome_eleitoral = senator_data$IdentificacaoParlamentar$NomeParlamentar,
    nome_completo = senator_data$IdentificacaoParlamentar$NomeCompletoParlamentar,
    genero = senator_data$IdentificacaoParlamentar$SexoParlamentar
  ) %>%
    dplyr::mutate(casa = 'senado',
                  partido = partido,
                  uf = uf,
                  situacao = situacao)
  df
}
