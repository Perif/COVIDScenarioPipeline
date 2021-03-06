library(magrittr)
library(knitr)
library(tidyr)
library(dplyr)
library(readr)
library(gridExtra)
library(ggfortify)
library(flextable)
library(cowplot)
library(doParallel)
library(data.table)
library(foreach)

global_index_offset <- 0


load_scenario_sims <- function(scenario_dir,
                               keep_compartments=NULL,
                               time_filter_low = -Inf,
                               time_filter_high = Inf,
                               cores = 10){
  require(data.table)
  files <- dir(scenario_dir,full.names = TRUE)
  rc <- list()
  cl <- makeCluster( cores )
  registerDoParallel(cl)
  rc = foreach (i = 1:length(files), .packages = c('dplyr','tidyr','readr','data.table')) %dopar% {
    file <- files[i]
    #print(i)
    if (is.null(keep_compartments)) {
      #tmp <- data.table::fread(file) %>% as.data.frame()
      suppressMessages(tmp <- read_csv(file))
    } else {
      suppressMessages(
        tmp <-  read_csv(file) %>%
          filter(comp%in%keep_compartments)
      )
    }
    #colnames(tmp) <- tmp[1,]
    tmp <- #tmp[-1,] %>%
      tmp %>%
      filter(time <= time_filter_high & time >= time_filter_low) %>%
      pivot_longer(cols=c(-time, -comp), names_to = "geoid", values_to="N") %>%
      mutate(sim_num = i)
    tmp
  }
  stopCluster(cl)
  rc<- rbindlist(rc)
  return(rc)
}



build_hospdeath_par <- function(data, p_hosp, p_death, p_vent, p_ICU, p_hosp_type="gamma",
                                time_hosp_pars = c(1.23, 0.79), 
                                time_ICU_pars = c(log(10.5), log((10.5-7)/1.35)),
                                time_vent_pars = c(log(10.5), log((10.5-8)/1.35)),
                                time_death_pars = c(log(11.25), log(1.15)), 
                                time_disch_pars = c(log(11.5), log(1.22)),
                                time_ICUdur_pars = c(log(17.46), log(4.044)),
                                end_date = "2020-04-01",
                                length_geoid = 5,
                                incl.county=FALSE,
                                cores=8, 
                                run_parallel=FALSE, data_filename = "", scenario_name,
                                index_offset = 0){
  
  library(data.table)
  library(doParallel)
  
  dat_final <- list()
  
  
  n_sim <- length(list.files(data_filename))
  print(paste("Creating cluster with",cores,"cores"))
  cl <- makeCluster(cores)
  registerDoParallel(cl)

  
  print(paste("Running over",n_sim,"simulations"))
  dat_final <- foreach(s=seq_len(n_sim), .packages=c("dplyr","readr","data.table","tidyr")) %dopar% {
    source("COVIDScenarioPipeline/R/DataUtils_withHospCapacity.R")
    print(s)

    create_delay_frame <- function(X, p_X, data_, X_pars, varname) {
      X_ <- rbinom(length(data_[[X]]),data_[[X]],p_X)
      data_X <- data.frame(time=data_$time,  uid=data_$uid, count=X_)
      X_delay_ <- round(exp(X_pars[1] + X_pars[2]^2 / 2))
      
      X_time_ <- rep(as.Date(data_X$time), data_X$count) + X_delay_
      names(X_time_) <- rep(data_$uid, data_X$count)
      
      data_X <- data.frame(time=X_time_, uid=names(X_time_))
      data_X <- data.frame(setDT(data_X)[, .N, by = .(time, uid)])
      colnames(data_X) <- c("time","uid",paste0("incid",varname))
      return(data_X)
    }
    load_scenario_sim <- function(scenario_dir,
                                   sim_id,
                                   keep_compartments=NULL,
                                   time_filter_low = -Inf,
                                   time_filter_high = Inf
    ){
      require(data.table)
      files <- dir(scenario_dir,full.names = TRUE)
      rc <- list()
      i = sim_id
      file <- files[i]
      #print(i)
      if (is.null(keep_compartments)) {
        #tmp <- data.table::fread(file) %>% as.data.frame()
        suppressMessages(tmp <- read_csv(file))
      } else {
        suppressMessages(
          tmp <-  read_csv(file) %>%
            filter(comp%in%keep_compartments)
        )
      }
    
      tmp <- #tmp[-1,] %>%
        tmp %>%
        filter(time <= time_filter_high & time >= time_filter_low) %>%
        pivot_longer(cols=c(-time, -comp), names_to = "geoid", values_to="N") %>%
        mutate(sim_num = i)
      return(tmp)
    }

    

    county_dat <- read.csv("data/west-coast-AZ-NV/geodata.csv")
    county_dat$geoid <- as.character(county_dat$geoid)
    county_dat$new_pop <- county_dat$pop2010
    county_dat <- make_metrop_labels(county_dat)
    dat_ <- load_scenario_sim(data_filename,s,keep_compartments = c("diffI","cumI")) %>%
    filter(geoid %in% county_dat$geoid[county_dat$stateUSPS=="CA"], time<=end_date, comp == "diffI", N > 0) %>%
    mutate(hosp_curr = 0, icu_curr = 0, vent_curr = 0, uid = paste0(geoid, "-",sim_num)) %>%
    rename(incidI = N)
    dates_ <- as.Date(dat_$time)
    
    # Add time things
    dat_H <- create_delay_frame('incidI',p_hosp,dat_,time_hosp_pars,"H")
    data_ICU <- create_delay_frame('incidH',p_ICU,dat_H,time_ICU_pars,"ICU")
    data_Vent <- create_delay_frame('incidICU',p_vent,data_ICU,time_vent_pars,"Vent")
    data_D <- create_delay_frame('incidH',p_death,dat_H,time_death_pars,"D")
    
    
    R_delay_ <- round(exp(time_disch_pars[1]))
    ICU_dur_ <- round(exp(time_ICUdur_pars[1]))
    
    
    
    # Using `merge` instead     
    res <- merge(dat_H %>% mutate(uid = as.character(uid)), 
                 data_ICU %>% mutate(uid = as.character(uid)), all=TRUE)
    res <- merge(res, data_Vent %>% mutate(uid = as.character(uid)), all=TRUE)
    res <- merge(res, data_D %>% mutate(uid = as.character(uid)), all=TRUE)
    res <- merge(dat_ %>% mutate(uid = as.character(uid)), 
                 res %>% mutate(uid = as.character(uid)), all=TRUE)
    
    res <- res %>% 
      replace_na(
        list(incidI = 0,
             incidH = 0,
             incidICU = 0,
             incidVent = 0,
             incidD = 0,
             vent_curr = 0,
             hosp_curr = 0))
    
    # get sim nums
    res <- res %>% select(-geoid, -sim_num) %>%
      separate(uid, c("geoid", "sim_num"), sep="-", remove=FALSE)
    
    res <- res %>% mutate(date_inds = as.integer(time - min(time) + 1))
    n_sim <- length(unique(res$sim_num))
    
    
    
    res$sim_num_good <- as.numeric(res$sim_num) 
    res$sim_num_good <- res$sim_num_good - min(res$sim_num_good) +1
    
    res$geo_ind <- as.numeric(as.factor(res$geoid))
    inhosp <- matrix(0, nrow=max(res$date_inds),ncol=max(res$geo_ind))
    inicu <- inhosp
    len<-max(res$date_inds)
    for (i in 1:nrow(res)) {
      inhosp[res$date_inds[i]:min((res$date_inds[i]+R_delay_-1),len), res$geo_ind[i]] <- 
        inhosp[res$date_inds[i]:min((res$date_inds[i]+R_delay_-1),len), res$geo_ind[i]] + res$incidH[i]
      
      inicu[res$date_inds[i]:min((res$date_inds[i]+ICU_dur_-1),len), res$sim_num_good[i]] <- 
        inicu[res$date_inds[i]:min((res$date_inds[i]+ICU_dur_-1),len), res$sim_num_good[i]] + res$incidICU[i]
      
    }
  

    
     for (x in 1:nrow(res)){
       
       res$hosp_curr[x] <- inhosp[res$date_inds[x], res$geo_ind[x]]
       res$icu_curr[x] <- inicu[res$date_inds[x], res$geo_ind[x]]
       #res$hosp_curr <- res$hosp_curr + res$date_inds %in% (res$date_inds[x] + 0:R_delay_)*res$incidH[x]
       #res$icu_curr <- res$icu_curr + res$date_inds %in% (res$date_inds[x] + 0:ICU_dur_)*res$incidICU[x]
       #res$vent_curr <- res$vent_curr + res$date_inds %in% (res$date_inds[x] + 0:Vent_dur_)*res$incidVent[x]
     }
    
    outfile <- paste0(sub('/','/hospitalization/',data_filename),'/',scenario_name,'-',s + index_offset,'.csv')
    outfile <- paste0('hospitalization/',data_filename,'/',scenario_name,'-',s + index_offset,'.csv')
    outdir <- gsub('/[^/]*$','',outfile)
    if(!dir.exists(outdir)){
      dir.create(outdir,recursive=TRUE)
    }
    write.csv(res,outfile)
  }
  print(paste("Parallel portion finished"))
  
  stopCluster(cl)
}




## geoid + metrop label data ----------------------------------------

  # set parameters for time to hospitalization, time to death, time to discharge
  time_hosp_pars <- c(1.23, 0.79)
  time_disch_pars <- c(log(11.5), log(1.22))
  time_death_pars <- c(log(11.25), log(1.15))
  time_ICU_pars = c(log(10.5), log((10.5-7)/1.35))
  time_ICUdur_pars = c(log(17.46), log(4.044))
  time_vent_pars = c(log(10.5), log((10.5-8)/1.35))
  mean_inc <- 5.2
  dur_inf_shape <- 2
  dur_inf_scale <- 3
  
  # set death + hospitalization parameters
  p_death <- c(.0025, .005, .01)
  p_ICU=0.264
  p_vent=0.15

## write out  ----------------------------------------
  # separate csvs for each res objects
  # directory can be changed
  print("Starting hospitalization")
## hospitalizations: uncontrolled ----------------------------------------

#  res_npi3 <- build_hospdeath_par(NULL,
#                                  p_hosp = p_death[3]*10,
#                                  p_death = .1,
#                                  p_vent = p_vent,
#                                  p_ICU = p_ICU,
#                                  p_hosp_type = "gamma",
#                                  time_hosp_pars=time_hosp_pars,
#                                  time_death_pars=time_death_pars,
#                                  time_disch_pars=time_disch_pars,
#                                  time_ICU_pars = time_ICU_pars,
#                                  time_vent_pars = time_vent_pars,
#                                  time_ICUdur_pars = time_ICUdur_pars, 
#                                  end_date = "2020-10-01",
#                                  length_geoid = 4,
#                                  incl.county = TRUE,
#                                  cores = 32,
#                                  data_filename = "model_output/unifiedNPI/",
#                                  scenario_name = "high_death",
 #                                 index_offset = global_index_offset
#  )
  
## hospitalizations: Wuhan-like  ----------------------------------------
  
#  res_npi2 <- build_hospdeath_par(NULL,
#                                  p_hosp = p_death[2]*10,
#                                  p_death = .1,
#                                  p_vent = p_vent,
#                                  p_ICU = p_ICU,
#                                  p_hosp_type = "gamma",
#                                  time_hosp_pars=time_hosp_pars,
#                                  time_death_pars=time_death_pars,
#                                  time_disch_pars=time_disch_pars,
#                                  time_ICU_pars = time_ICU_pars,
#                                  time_vent_pars = time_vent_pars,
#                                  time_ICUdur_pars = time_ICUdur_pars, 
#                                  end_date = "2020-10-01",
#                                  length_geoid = 4,
#                                  incl.county = TRUE,
#                                  cores = 32,
#                                  data_filename = "model_output/unifiedNPI/",
#                                  scenario_name = "med_death",
#                                  index_offset = global_index_offset
#  )

  res_npi1 <- build_hospdeath_par(NULL,
                                  p_hosp = p_death[1]*10,
                                  p_death = .1,
                                  p_vent = p_vent,
                                  p_ICU = p_ICU,
                                  p_hosp_type = "gamma",
                                  time_hosp_pars=time_hosp_pars,
                                  time_death_pars=time_death_pars,
                                  time_disch_pars=time_disch_pars,
                                  time_ICU_pars = time_ICU_pars,
                                  time_vent_pars = time_vent_pars,
                                  time_ICUdur_pars = time_ICUdur_pars, 
                                  end_date = "2020-10-01",
                                  length_geoid = 4,
                                  incl.county = TRUE,
                                  cores = 32,
                                  data_filename = "model_output/unifiedNPI/",
                                  scenario_name = "low_death",
                                  index_offset = global_index_offset
  )
