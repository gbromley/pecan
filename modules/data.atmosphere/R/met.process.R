##' @name met.process
##' @title met.process
##' @export
##'
##' @param site Site info from settings file
##' @param input currently "NARR" or "Ameriflux"
##' @param start_date the start date of the data to be downloaded (will only use the year part of the date)
##' @param end_date the end date of the data to be downloaded (will only use the year part of the date)
##' @param model model_type name
##' @param host Host info from settings file
##' @param bety  database settings from settings file
##' @param dir  directory to write outputs to
##' 
##' @author Elizabeth Cowdery, Michael Dietze
met.process <- function(site, input, start_date, end_date, model, host, bety, dir){
  
  require(RPostgreSQL)
  
  driver   <- "PostgreSQL"
  user     <- bety$user
  dbname   <- bety$dbname
  password <- bety$password
  bety.host<- bety$host
  username <- ""
  dbparms <- list(driver=driver, user=user, dbname=dbname, password=password, host=bety.host)
  con       <- db.open(dbparms)
  
  met <- input 
  regional <- met == "NARR" # Either regional or site run
  new.site = as.numeric(site$id)
  str_ns    <- paste0(new.site %/% 1000000000, "-", new.site %% 1000000000)
  
  #--------------------------------------------------------------------------------------------------#
  # Download raw met from the internet 
  
  outfolder  <- file.path(dir,met)
  pkg        <- "PEcAn.data.atmosphere"
  fcn        <- paste0("download.",met)
  if(met == "NARR"){
    site.id <- 1135
    raw.id <- 1000000127
  }else{
    if(met == "Ameriflux"){
      
      ## download files
      outfolder = paste0(outfolder,"-",str_ns)
      site.code = sub(".* \\((.*)\\)", "\\1", site$name)
      args <- list(site.code, outfolder, start_date, end_date, overwrite=FALSE, verbose=FALSE) #, pkg,raw.host = host,dbparms,con=con)
      new.files <- do.call(fcn,args)
      host$name = new.files$host[1]
      
      check = dbfile.input.check(site$id, start_date, end_date, 
                                 mimetype=new.files$mimetype[1], formatname=new.files$formatname[1], 
                                 con=con, hostname=new.files$host[1])
      if(length(check)>0){
        raw.id = check$container_id[1]
      }else{
        ## insert database record
        raw.id <- dbfile.input.insert(in.path=dirname(new.files$file[1]),
                                      in.prefix=site.code, 
                                      siteid = site$id, 
                                      startdate = start_date, 
                                      enddate = end_date, 
                                      mimetype=new.files$mimetype[1], 
                                      formatname=new.files$formatname[1],
                                      parentid=NA,
                                      con = con,
                                      hostname = host$name)$input.id
      }    
    } else {  ## site level, not Ameriflux
      print("NOT AMERIFLUX")
      site.id <- site$id
      args <- list(site.id, outfolder, start_date, end_date, overwrite=FALSE, verbose=FALSE) #, pkg,raw.host = host,dbparms,con=con)
      raw.id <- do.call(fcn,args)
      
    }
    
  } 
  
  #--------------------------------------------------------------------------------------------------#
  print("### Change to CF Standards")
  
  input.id  <-  raw.id
  #outfolder <-  file.path(dir,paste0(met,"_CF"))
  outfolder <-  paste0(outfolder,"_CF")
  pkg       <- "PEcAn.data.atmosphere"
  fcn       <-  paste0("met2CF.",met)
  formatname <- 'CF Meteorology'
  mimetype <- 'application/x-netcdf'
  
  if(met == "NARR"){
    cf.id <- 1000000023 #ID of permuted CF files
  }else{    
    cf.id <- convert.input(input.id,outfolder,formatname,mimetype,site$id,start_date,end_date,pkg,fcn,
                           username,con=con,hostname=host$name,write=TRUE) 
  }
  
  #--------------------------------------------------------------------------------------------------#
  # Extraction 
  
  if(regional){ #ie NARR right now    
    
    input.id <- cf.id
    outfolder <- file.path(dir,paste0(met,"_CF_site_",str_ns))
    pkg       <- "PEcAn.data.atmosphere"
    fcn       <- "extract.nc"
    formatname <- 'CF Meteorology'
    mimetype <- 'application/x-netcdf'
    
    new.lat <- db.site.lat.lon(new.site,con=con)$lat
    new.lon <- db.site.lat.lon(new.site,con=con)$lon
    
    ready.id <- convert.input(input.id,outfolder,formatname,mimetype,site.id=site$id,start_date,end_date,pkg,fcn,
                              username,con=con,hostname=host$name,write=TRUE,
                              slat=new.lat,slon=new.lon,newsite=new.site)
    
  }else{ 
    #### SITE-LEVEL PROCESSING ##########################
    
    print("# run gapfilling") 
    #    ready.id <- convert.input()
    #    ready.id <- metgapfill(outfolder, site.code, file.path(settings$run$dbfiles, "gapfill"), start_date=start_date, end_date=end_date)
    
    outfolder <- paste0(outfolder,"_gapfill")
    pkg       <- "PEcAn.data.atmosphere"
    fcn       <- "gapfill"
    formatname <- 'CF Meteorology'
    mimetype <- 'application/x-netcdf'
    lst <- site.lst(site,con)
    
    ready.id <- convert.input(input.id=cf.id,outfolder=outfolder,formatname=formatname,mimetype=mimetype,
                              site.id=site$id,start_date,end_date,
                              pkg,fcn,username=username,con=con,hostname=host$name,write=TRUE,lst=lst)
    
  }
  print("Standardized Met Produced")
  
  #--------------------------------------------------------------------------------------------------#
  # Prepare for Model
  
  ## NOTE: ALL OF THIS CAN BE QUERIED THROUGH DATABASE
  ## MODEL_TYPES -> FORMATS where tag = "met"
  if(model == "ED2"){
    formatname <- 'ed.met_driver_header_files_format'
    mimetype <- 'text/plain'
  }else if(model == "SIPNET"){
    formatname <- 'Sipnet.climna'
    mimetype <- 'text/csv'
  }else if(model == "BIOCRO"){
    formatname <- 'biocromet'
    mimetype <- 'text/csv'
  }else if(model == "DALEC"){
    formatname <- 'DALEC meteorology'
    mimetype <- 'text/plain'
  }else if(model == "LINKAGES"){
    formatname = 'LINKAGES met'
    mimetype <- 'text/plain'
  }
  
  lst <- site.lst(site,con)
  
  print("# Convert to model format")
  outfolder <- file.path(dir,paste0(met,"_",model,"_site_",str_ns))
  pkg       <- paste0("PEcAn.",model)
  fcn       <- paste0("met2model.",model)
  write     <- TRUE
  overwrite <- ""
  
  model.id <- convert.input(input.id=ready.id,outfolder=outfolder,formatname=formatname,
                            mimetype=mimetype,site.id=site$id,start_date=start_date,end_date=end_date,
                            pkg=pkg,fcn=fcn,
                            username=username,con=con,host=host$name,write=write,lst=lst,overwrite=overwrite)
  print(c("Done model convert",model.id,outfolder))
  
  db.close(con)
  return(outfolder)
  
}

##' @name find.prefix
##' @title find.prefix
##' @export
##' @param files
##' @author Betsy Cowdery
find.prefix <- function(files){
  files.split <- (strsplit(files, "[.]"))
  files.split <- lapply(files.split, `length<-`,max(unlist(lapply(files.split, length))))
  files.df <- as.data.frame(do.call(rbind, files.split))
  files.uniq <- sapply(files.df, function(x)length(unique(x)))
  
  prefix <- ""
  ifelse(files.uniq[1] == 1,prefix <- as.character(files.df[1,1]),return(prefix))
  
  for(i in 2:length(files.uniq)){
    if(files.uniq[i]==1){
      prefix <- paste(prefix,as.character(files.df[1,i]),sep = ".")
    }else{
      return(prefix)
    }
  }
  return(prefix)
}


##' @name db.site.lat.lon
##' @title db.site.lat.lon
##' @export
##' @param site.id
##' @param con
##' @author Betsy Cowdery
db.site.lat.lon <- function(site.id,con){
  site <- db.query(paste("SELECT id, ST_X(ST_CENTROID(geometry)) AS lon, ST_Y(ST_CENTROID(geometry)) AS lat FROM sites WHERE id =",site.id),con)
  if(nrow(site)==0){logger.error("Site not found"); return(NULL)} 
  if(!(is.na(site$lat)) && !(is.na(site$lat))){
    return(list(lat = site$lat, lon = site$lon))
  }
}