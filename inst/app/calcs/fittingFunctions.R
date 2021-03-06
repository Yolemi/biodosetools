# Fitting functions ----
get_model_statistics <- function(model_data, fit_coeffs_vec, glm_results, fit_algorithm,
                                 response = "yield", link = "identity", type = "theory") {
  # Calculate from theory or use statistics calculated by glm
  if (type == "theory") {
    # Renormalize data if necessary
    if (response == "yield") {
      model_data[["aberr"]] <- model_data[["aberr"]] / model_data[["C"]]
      model_data[["α"]] <- model_data[["α"]] / model_data[["C"]]
      model_data[["β"]] <- model_data[["β"]] / model_data[["C"]]
      model_data[["C"]] <- model_data[["C"]] / model_data[["C"]]
    }

    # Generalized variance-covariance matrix
    general_fit_coeffs <- numeric(length = 3L) %>%
      `names<-`(c("C", "α", "β"))

    for (var in names(fit_coeffs_vec)) {
      general_fit_coeffs[[var]] <- fit_coeffs_vec[[var]]
    }

    # Predict yield / aberrations
    predict_eta <- function(data, coeffs) {
      coeffs[["C"]] * data[["C"]] +
        coeffs[["α"]] * data[["α"]] +
        coeffs[["β"]] * data[["β"]]
    }

    eta_sat <- model_data[["aberr"]]
    eta <- predict_eta(model_data, general_fit_coeffs)

    num_data <- length(eta_sat)
    num_params <- sum(fit_coeffs_vec != 0)

    # Calculate logLik depending on fitting link
    if (link == "identity") {
      logLik <- sum(log(eta) * eta_sat - eta - log(factorial(eta_sat)))
    } else if (link == "log") {
      logLik <- sum(eta * eta_sat - exp(eta) - log(factorial(eta_sat)))
    }

    # Calculate model-specific statistics
    fit_model_statistics <- cbind(
      logLik =   logLik,
      deviance = sum(2 * (eta_sat * log(eta_sat / eta) - (eta_sat - eta))),
      df =       num_data - num_params,
      AIC =      2 * num_params - 2 * logLik,
      BIC =      log(num_data) * num_params - 2 * logLik
    )

  } else if (type == "raw" & fit_algorithm == "glm") {
    # Get model-specific statistics
    fit_model_statistics <- cbind(
      logLik =   stats::logLik(glm_results) %>% as.numeric(),
      deviance = stats::deviance(glm_results),
      df =       stats::df.residual(glm_results),
      AIC =      stats::AIC(glm_results),
      BIC =      stats::BIC(glm_results)
    )
  } else if (type == "raw" & fit_algorithm == "constraint-maxlik-optimization") {
    # Get model-specific statistics
    fit_model_statistics <- cbind(
      logLik =   stats::logLik(glm_results),
      deviance = sum(poisson(link = "identity")$dev.resids(Y, mu, 1)),
      df =       n - npar,
      AIC =      2 * length(fit_coeffs_vec) - 2 * stats::logLik(glm_results),
      BIC =      log(n) * length(fit_coeffs_vec) - 2 * stats::logLik(glm_results)
    )
  }

  return(fit_model_statistics)
}

prepare_maxlik_count_data <- function(count_data, model_formula) {

  if (ncol(count_data) > 3 & aberr_module != "translocations") {
    # Full distribution data
    dose_vec <- rep(
      count_data[["D"]],
      count_data[["N"]]
    )

    cell_vec <- rep(
      rep(1, nrow(count_data)),
      count_data[["N"]]
    )

    dics_vec <- rep(
      count_data %>%
        names() %>%
        grep("C", ., value = TRUE) %>%
        gsub("C", "", .) %>%
        rep(nrow(count_data)) %>%
        as.numeric()
      ,
      count_data %>%
        .[, grep("C", names(.), value = T)] %>%
        as.matrix() %>%
        t() %>%
        as.numeric()
    )

    parsed_data <- data.frame(
      aberr = dics_vec,
      dose = dose_vec,
      C = cell_vec) %>%
      dplyr::mutate(
        α = dose * C,
        β = dose^2 * C) %>%
      dplyr::select(aberr, C, α, β, dose)
  } else {
    # Aggregated data only or if using translocations
    parsed_data <- count_data %>%
      dplyr::rename(
        aberr = X,
        C = N
      ) %>%
      dplyr::mutate(
        α = D * C,
        β = D^2 * C
      ) %>%
      dplyr::select(aberr, C, α, β)
  }

  # Delete C column for models with no intercept
  if (stringr::str_detect(model_formula, "no-int")) {
    parsed_data <- parsed_data %>%
      dplyr::select(-C)
  }

  # Return data frame
  return(parsed_data)
}

get_fit_glm_method <- function(count_data, model_formula, model_family, fit_link = "identity") {

  # Store fit algorithm as a string
  fit_algorithm <- "glm"

  # Parse count data
  doses <- count_data[["D"]]
  aberr <- count_data[["X"]]
  cells <- count_data[["N"]]
  if (ncol(count_data) > 3) {
    # Full distribution data
    disp <- count_data[["DI"]]
  } else {
    # Aggregated data only
    disp <- rep(1, nrow(count_data))
  }

  # Construct predictors and model data
  C <- cells
  α <- cells * doses
  β <- cells * doses * doses
  model_data <- list(C = C, α = α, β = β, aberr = aberr)
  weights <- 1 / disp

  # Select model formula
  if (model_formula == "lin-quad") {
    fit_formula_raw <- "aberr ~ -1 + C + α + β"
    fit_formula_tex <- "Y = C + \\alpha D + \\beta D^{2}"
  } else if (model_formula == "lin") {
    fit_formula_raw <- "aberr ~ -1 + C + α"
    fit_formula_tex <- "Y = C + \\alpha D"
  }
  else if (model_formula == "lin-quad-no-int") {
    fit_formula_raw <- "aberr ~ -1 + α + β"
    fit_formula_tex <- "Y = \\alpha D + \\beta D^{2}"
  }
  else if (model_formula == "lin-no-int") {
    fit_formula_raw <- "aberr ~ -1 + α"
    fit_formula_tex <- "Y = \\alpha D"
  }
  fit_formula <- as.formula(fit_formula_raw)

  # Perform automatic fit calculation
  if (model_family == "poisson") {
    # Poisson model
    fit_results <- glm(
      formula = fit_formula,
      family = poisson(link = fit_link),
      data = model_data
    )
    fit_dispersion <- NULL
    fit_final_model <- "poisson"
  } else if (model_family == "automatic" | model_family == "quasipoisson") {
    # Automatic and Quasi-poisson model
    fit_results <- glm(
      formula = fit_formula,
      family = quasipoisson(link = fit_link),
      weights = weights,
      data = model_data
    )
    fit_dispersion <- summary(fit_results)$dispersion
    fit_final_model <- "quasipoisson"
    # Check if Poisson model is more suitable
    if (fit_dispersion <= 1 & aberr_module != "micronuclei") {
      fit_results <- glm(
        formula = fit_formula,
        family = poisson(link = fit_link),
        data = model_data
      )
      fit_dispersion <- NULL
      fit_final_model <- "poisson"
    }
  } else if (model_family == "nb2") {
    fit_results <- MASS::glm.nb(
      formula = fit_formula,
      link = fit_link,
      weights = weights,
      data = model_data
    )
    # fit_dispersion <- NULL
    fit_dispersion <- summary(fit_results)$dispersion
    fit_final_model <- "nb2"
  }

  # Summarise fit
  fit_summary <- summary(fit_results, correlation = TRUE)
  fit_cor_mat <- fit_summary$correlation
  fit_var_cov_mat <- stats::vcov(fit_results)
  fit_coeffs_vec <- stats::coef(fit_results)

  # Model-specific statistics
  fit_model_statistics <- get_model_statistics(model_data, fit_coeffs_vec, fit_results, fit_algorithm,
                                               response = "yield", link = "identity", type = "theory")

  # Correct p-values depending on model dispersion
  t_value <- fit_coeffs_vec / sqrt(diag(fit_var_cov_mat))

  # Make coefficients table
  if (fit_final_model == "poisson") {
    # For Poisson model
    fit_coeffs <- cbind(
      estimate =  fit_coeffs_vec,
      std.error = sqrt(diag(fit_var_cov_mat)),
      statistic = t_value,
      p.value =   2 * pnorm(-abs(t_value))
    ) %>%
      `row.names<-`(names(fit_coeffs_vec)) %>%
      `colnames<-`(c("estimate", "std.error", "statistic", "p.value"))

    # Summary of model used
    fit_model_summary <- paste("A Poisson model assuming equidispersion was used as the model dispersion ≤ 1.")
  } else if (fit_final_model == "quasipoisson") {
    # For Quasi-poisson model
    fit_coeffs <- cbind(
      estimate =  fit_coeffs_vec,
      std.error = sqrt(diag(fit_var_cov_mat)),
      statistic = t_value,
      p.value =   2 * 2 * pt(-abs(t_value), fit_results$df.residual)
    ) %>%
      `row.names<-`(names(fit_coeffs_vec)) %>%
      `colnames<-`(c("estimate", "std.error", "statistic", "p.value"))

    # Summary of model used
    fit_model_summary <- paste0("A Quasi-poisson model accounting for overdispersion was used as the model dispersion (=", round(fit_dispersion, 2), ") > 1.")
  } else if (fit_final_model == "nb2") {
    # For Poisson model
    fit_coeffs <- cbind(
      estimate =  fit_coeffs_vec,
      std.error = sqrt(diag(fit_var_cov_mat)),
      statistic = t_value,
      p.value =   2 * pnorm(-abs(t_value))
    ) %>%
      `row.names<-`(names(fit_coeffs_vec)) %>%
      `colnames<-`(c("estimate", "std.error", "statistic", "p.value"))

    # Summary of model used
    fit_model_summary <- paste("A Negative binomial (NB2) model was used.")
  }

  # Return objects
  fit_results_list <- list(
    # Raw data
    fit_raw_data = count_data %>% as.matrix(),
    # Formulas
    fit_formula_raw = fit_formula_raw,
    fit_formula_tex = fit_formula_tex,
    # Coefficients
    fit_coeffs = fit_coeffs,
    fit_cor_mat = fit_cor_mat,
    fit_var_cov_mat = fit_var_cov_mat,
    # Model statistics
    fit_dispersion = fit_dispersion,
    fit_model_statistics = fit_model_statistics,
    # Algorithm and model summary
    fit_algorithm = "glm",
    fit_model_summary = fit_model_summary
  )

  return(fit_results_list)
}

get_fit_maxlik_method <- function(data, model_formula, model_family, fit_link) {
  # type can be "poisson", "quasipoisson" or "automatic"
  # in case of automatic the script will choose a quasipoisson model if deviance > df (see below)
  # start should include starting values for the coefficients of the regression model
  # Please note that most parts of this code are from Oliviera et al. this should be cited somewhere

  # Store fit algorithm as a string
  fit_algorithm <- "constraint-maxlik-optimization"

  # Parse full data into aggregated format
  if ("dose" %in% colnames(data)) {
    data_aggr <- data %>%
      dplyr::group_by(aberr, dose) %>%
      dplyr::summarise(n = n()) %>%
      dplyr::group_by(dose) %>%
      dplyr::summarise(
        C = sum(n),
        X = sum(ifelse(aberr > 0, n * aberr, 0))
      ) %>%
      dplyr::mutate(
        α = dose * C,
        β = dose^2 * C
      ) %>%
      dplyr::rename(aberr = X) %>%
      dplyr::select(aberr, dose, C, α, β)
  } else {
    data_aggr <- data
  }

  # Select model formula
  if (model_formula == "lin-quad") {
    fit_formula_raw <- "aberr ~ -1 + C + α + β"
    fit_formula_tex <- "Y = C + \\alpha D + \\beta D^{2}"
  } else if (model_formula == "lin") {
    fit_formula_raw <- "aberr ~ -1 + C + α"
    fit_formula_tex <- "Y = C + \\alpha D"
  }
  else if (model_formula == "lin-quad-no-int") {
    fit_formula_raw <- "aberr ~ -1 + α + β"
    fit_formula_tex <- "Y = \\alpha D + \\beta D^{2}"
  }
  else if (model_formula == "lin-no-int") {
    fit_formula_raw <- "aberr ~ -1 + α"
    fit_formula_tex <- "Y = \\alpha D"
  }
  fit_formula <- as.formula(fit_formula_raw)

  if (stringr::str_detect(model_formula, "no-int")) {
    data_aggr <- data_aggr %>%
      dplyr::select(-C)
  }

  # Find starting values for the mean
  mustart <- lm(fit_formula, data = data_aggr)$coefficients
  if (mustart[1] <= 0) {
    mustart[1] <- 0.001
  }

  # Black magic
  mf <- match.call()
  m <- match(c("formula", "data"), names(mf), 0)
  mf <- mf[c(1, m)]
  mf$drop.unused.levels <- TRUE

  if (length(fit_formula[[3]]) > 1 & identical(fit_formula[[3]][[1]], as.name("|"))) {
    ff <- fit_formula
    fit_formula[[3]][1] <- call("+")
    mf$formula <- fit_formula
    ffc <- . ~ .
    ffz <- ~.
    ffc[[2]] <- ff[[2]]
    ffc[[3]] <- ff[[3]][[2]]
    ffz[[3]] <- ff[[3]][[3]]
    ffz[[2]] <- NULL
  } else {
    ffz <- ffc <- ff <- fit_formula
    ffz[[2]] <- NULL
  }

  if (inherits(try(terms(ffz), silent = TRUE), "try-error")) {
    ffz <- eval(parse(text = sprintf(paste("%s -", deparse(ffc[[2]])), deparse(ffz))))
  }

  mf[[1]] <- as.name("model.frame")
  mf <- eval(mf, parent.frame())
  mt <- attr(mf, "terms")
  mtX <- terms(ffc, data = data)
  X <- model.matrix(mtX, mf)
  mtZ <- terms(ffz, data = data)
  mtZ <- terms(update(mtZ, ~.), data = data)
  Z <- model.matrix(mtZ, mf)
  Y <- model.response(mf, "numeric")

  if (all(X[, 1] == 1)) {
    intercept <- TRUE
  } else {
    intercept <- FALSE
  }

  # Summarise black magic
  ndic <- max(Y)
  n <- length(Y)
  linkstr <- "logit"
  linkobj <- make.link(linkstr)
  linkinv <- linkobj$linkinv
  grad <- NULL
  kx <- NCOL(X)
  Y0 <- Y <= 0
  Y1 <- Y > 0

  # Find starting values for the mean
  if (fit_link == "log") {
    if (is.null(mustart)) mustart <- as.numeric(glm.fit(X, Y, family = poisson())$coefficients)
  } else {
    if (is.null(mustart)) {
      stop("If link=identity, starting values must be provided")
    } else {
      mustart <- mustart
    }
  }

  # Model constraints
  npar <- kx
  if (intercept) {
    A <- rbind(X, c(1, rep(0, npar - 1)))
    B <- rep(0, n + 1)
  } else {
    A <- X
    B <- rep(0, n)
  }

  # Loglikelihood function
  loglik <- function(parms) {
    if (fit_link == "log") {
      mu <- as.vector(exp(X %*% parms[1:npar]))
    } else {
      mu <- as.vector(X %*% parms[1:npar])
    }
    loglikh <- sum(-mu + Y * log(mu) - lgamma(Y + 1))

    return(loglikh)
  }

  # Perform fitting
  if (fit_link == "log") {
    constraints <- NULL
    fit_results <- maxLik::maxLik(logLik = loglik, grad = grad, start = mustart, constraints = constraints, iterlim = 1000)
  } else {
    fit_results <- maxLik::maxLik(logLik = loglik, grad = grad, start = mustart, constraints = list(ineqA = A, ineqB = B), iterlim = 1000)
  }
  hess <- maxLik::hessian(fit_results)

  if (fit_link == "log") {
    mu <- as.vector(exp(X %*% fit_results$estimate[1:npar]))
  } else {
    mu <- as.vector(X %*% fit_results$estimate[1:npar])
  }

  # Summarise fit
  fit_summary <- summary(fit_results)
  fit_var_cov_mat <- base::solve(-hess)
  fit_coeffs_vec <- fit_results$estimate
  fit_dispersion <- sum(((Y - mu)^2) / (mu * (n - npar)))

  # Model-specific statistics
  fit_model_statistics <- get_model_statistics(data_aggr, fit_coeffs_vec, fit_results, fit_algorithm,
                                               response = "yield", link = "identity", type = "theory")

  # Correct p-values depending on model dispersion
  if (model_family == "poisson" | (model_family == "automatic" & fit_dispersion <= 1)) {
    t_value <- fit_coeffs_vec / sqrt(diag(fit_var_cov_mat))

    # For Poisson model
    fit_coeffs <- cbind(
      estimate =  fit_coeffs_vec,
      std.error = sqrt(diag(fit_var_cov_mat)),
      statistic = t_value,
      p.value =   2 * pnorm(-abs(t_value))
    ) %>%
      `row.names<-`(names(fit_coeffs_vec))

    # Summary of model used
    fit_model_summary <- paste("A Poisson model assuming equidispersion was used as the model dispersion ≤ 1.")
  } else if (model_family == "quasipoisson" | (model_family == "automatic" & fit_dispersion > 1)) {
    fit_var_cov_mat <- fit_var_cov_mat * fit_dispersion
    t_value <- fit_coeffs_vec / sqrt(diag(fit_var_cov_mat))

    # For Quasi-poisson model
    fit_coeffs <- cbind(
      estimate =  fit_coeffs_vec,
      std.error = sqrt(diag(fit_var_cov_mat)),
      statistic = t_value,
      p.value =   2 * 2 * pt(-abs(t_value), fit_model_statistics[, "df"] %>% as.numeric())
    ) %>%
      `row.names<-`(names(fit_coeffs_vec))

    # Summary of model used
    fit_model_summary <- paste0("A Quasi-poisson model accounting for overdispersion was used as the model dispersion (=", round(fit_dispersion, 2), ") > 1.")
  } else if (model_family == "nb2") {
    # TODO: update coefficients for NB2
    fit_var_cov_mat <- fit_var_cov_mat * fit_dispersion
    t_value <- fit_coeffs_vec / sqrt(diag(fit_var_cov_mat))

    # For Quasi-poisson model
    fit_coeffs <- cbind(
      estimate =  fit_coeffs_vec,
      std.error = sqrt(diag(fit_var_cov_mat)),
      statistic = t_value,
      p.value =   2 * 2 * pt(-abs(t_value), fit_model_statistics[, "df"] %>% as.numeric())
    ) %>%
      `row.names<-`(names(fit_coeffs_vec))

    # Summary of model used
    fit_model_summary <- paste("Work in progress: A Negative binomial (NB2) model was used.")
  }

  # Calculate correlation matrix
  fit_cor_mat <- fit_var_cov_mat
  for (x_var in rownames(fit_var_cov_mat)) {
    for (y_var in colnames(fit_var_cov_mat)) {
      fit_cor_mat[x_var, y_var] <- fit_var_cov_mat[x_var, y_var] / (fit_coeffs[x_var, "std.error"] * fit_coeffs[y_var, "std.error"])
    }
  }

  # Return objects
  fit_results_list <- list(
    # Raw data
    fit_raw_data = data_aggr %>% as.matrix(),
    # Formulas
    fit_formula_raw = fit_formula_raw,
    fit_formula_tex = fit_formula_tex,
    # Coefficients
    fit_coeffs = fit_coeffs,
    fit_cor_mat = fit_cor_mat,
    fit_var_cov_mat = fit_var_cov_mat,
    # Model statistics
    fit_dispersion = fit_dispersion,
    fit_model_statistics = fit_model_statistics,
    # Algorithm and model summary
    fit_algorithm = fit_algorithm,
    fit_model_summary = fit_model_summary
  )

  return(fit_results_list)
}

get_fit_results <- function(count_data, model_formula, model_family, fit_link = "identity") {
  # If glm produces an error, constraint ML maximization is performed
  tryCatch({
    # Perform fitting
    fit_results_list <- get_fit_glm_method(count_data, model_formula, model_family, fit_link)

    # Return results
    return(fit_results_list)
  },
  error = function(error_message) {
    message("Warning: Problem with glm -> constraint ML optimization will be used instead of glm")
    # Perform fitting
    prepared_data <- prepare_maxlik_count_data(count_data, model_formula)
    fit_results_list <- get_fit_maxlik_method(prepared_data, model_formula, model_family, fit_link)
    fit_results_list[["fit_raw_data"]] <- count_data %>% as.matrix()

    # Return results
    return(fit_results_list)
  })
}
