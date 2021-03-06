
library(doParallel)
library(stringr)
library(R.utils)

source("config.R")
source("common.R")
source("geo_utils.R")
source("RnBeadsCommon.R")
args <- commandArgs(trailingOnly = TRUE)


list_series_id_files <- function(series_id_folder) {
  non_relevant_patterns <- c(
    "_[Pp]rocessed2?[._]", "[Mm]atrix[Pp]rocessed2?[._]",
    "_Summary_icc_M[.]",
    "upload_Beta[.]","_SampleMethylationProfile[.]",
    "_average_beta[.]", "_betas?[.]",
    "_geo_all_cohorts[.]", "_Results[.]",
    "_dasen[.]", "_NewGSMs[.]",
    "_Normalized_data[.]",
    "_Metrics[.]", "_qc[.]", "_BM_Oligos_samplsheet[.]")
  
  series_id_files <- list.files(series_id_folder, pattern="*.(txt.gz|csv.gz|tsv.gz)$")
  # filter non relevant files
  series_id_files <- series_id_files[!grepl(paste(non_relevant_patterns, 
                                                  collapse="|"), series_id_files)]
  series_id_files
}

downloadIfNotExist <- function(destfile, url) {
  if(!file.exists(destfile)) {
    print(sprintf('downloading %s', url))
    download.file(url, destfile, "internal")
  }
}

decompressIfNotExist <- function(destfile) {
  # if it's compressed - decompress it
  if(grepl('[.]gz$', destfile)) {
    destfile_without_gz <- substr(destfile, 1, nchar(destfile)-3)
    if(!file.exists(destfile_without_gz)) {
      gunzip(destfile, remove=FALSE)
    }
    destfile_without_gz
  } else {
    destfile
  }
}

lastUrlComponent <- function(url) {
  sapply(strsplit(url, split='/', fixed=TRUE), tail, 1)
}

prepareIdatTarget <- function(targets, i, idat_folder, idat_filename, idat_url, some_index, r_index, c_index) {
  destfile <- file.path(idat_folder, idat_filename)
  downloadIfNotExist(destfile, idat_url)
  destfile_without_gz <- decompressIfNotExist(destfile)
  
  # GSE40699 had bad idat filenames:
  # GSM999355_hg19_wgEncodeHaibMethyl450HaeSitesRep1_Grn.idat
  # we copy them to inf450 format in order for RnBeads to work correctly
  inf450k.idats.present <- grepl("_R0[1-6]C0[1-2]", idat_filename)
  
  if(!inf450k.idats.present) {
    gsm_id <- str_match(idat_filename, '(GSM\\d+)_')[[2]]
    barcode <- paste0(gsm_id, '_', str_pad(some_index, 10, pad="0"), '_', 'R', str_pad(r_index,2,pad='0'), 'C', str_pad(c_index,2, pad='0'))
    targets[i,]$barcode <- barcode
    
    color <- str_match(idat_filename, '(Red|Grn)')[[2]]
    new_filename <- paste0(barcode, '_', color, '.idat')
    print(idat_filename)
    print(new_filename)
    new_fullfilename <- file.path(idat_folder, new_filename)
    if(!file.exists(new_fullfilename)) {
      file.copy(destfile_without_gz, new_fullfilename)
    }
  }
  targets
}

# GSE62727 for example
readGeoL1DataWithIdats <- function(series_id_folder, series_id_orig, series_id_files, 
                                   output_filename, targets, all.series.info) {
  # Download idats
  splited_supplementary_file <- strsplit(targets$supplementary_file, ";")
  splited_supplementary_file <- lapply(splited_supplementary_file, trim)
  
  # Each item should be of length two (Green & Red)
  splited_supplementary_file_len_unique <- unique(unlist(lapply(splited_supplementary_file, 
                                                                function(x) length(x))))
  stopifnot(splited_supplementary_file_len_unique[[1]] == 2)
  stopifnot(length(splited_supplementary_file_len_unique) == 1)
  
  idat_folder <- file.path(series_id_folder, "idats")
  dir.create(idat_folder, recursive=TRUE, showWarnings=FALSE)

  targets$idat1_url <- sapply(splited_supplementary_file, "[", 1)
  targets$idat2_url <- sapply(splited_supplementary_file, "[", 2)
  
  targets$idat1_filename <- lastUrlComponent(targets$idat1_url)
  targets$idat2_filename <- lastUrlComponent(targets$idat2_url)

  targets$barcode <- gsub("_(Grn|Red).idat.gz", "", targets$idat1_filename)
  rownames(targets) <- targets$barcode
  r_index <- 1
  c_index <- 1
  some_index <- 1
  
  for(i in 1:nrow(targets)) {
    target <- targets[i,]
    targets <- prepareIdatTarget(targets, i, idat_folder, target$idat1_filename, target$idat1_url, some_index, r_index, c_index)
    targets <- prepareIdatTarget(targets, i, idat_folder, target$idat2_filename, target$idat2_url, some_index, r_index, c_index)
    r_index <- r_index + 1
    c_index <- c_index + 1
    some_index <- some_index + 1
  }
  # Work on idats
  print("working on idats")
  print(targets)
  betas.table <- workOnIdatsFolder(idat_folder, targets, 'barcode')
  write_beta_values_table(output_filename, betas.table)
}

readGeoL1DataWithoutIdats <- function(series_id_folder, series_id_orig, series_id_files, 
                                      output_filename, targets, all.series.info) {
  #nrows = 10000 # XXX (should be -1 on production)
  nrows = -1
  
  this_targets = subset(targets, targets$series_id == series_id_orig)  
  filename_first_level <- levels(factor(this_targets$Filename))[[1]]
  this_all.series.info <- subset(all.series.info, 
                                 all.series.info$Filename == filename_first_level)
  print(series_id_files)
  series_id_fp <- file.path(series_id_folder, series_id_files)
  file_sizes <- sum(file.info(series_id_fp)$size/2**20)
  mem_limits <- tryCatch(memory.limit()/20, warning=function(x) NA)
  if(nrows == -1 & !is.na(mem_limits) && file_sizes > mem_limits)  {
    print(mem_limits)
    print (file_sizes)
    print(sprintf('GEO file %s is too big for memory. skipping', 
                  basename(output_filename)))
  } else {
    p.values <- NULL
    problematic_unmeth_suffixes <- c("[. _-]?[Uu]nmethylated[. _-]?[Ss]ignal$", 
                                     "[_ .]{1,2}[Uu]nmethylated$",
                                     "^Unmethylated_",
                                     "_Unmethylated[.]Detection$",
                                     "[.]UM$",
                                     "[.]unmeth$")
    unmeth_suffixes <- c(problematic_unmeth_suffixes, "[._: ]Signal[_]?A$")
    meth_suffixes <- c("[. _-]?[Mm]ethylated[. _-]?[Ss]ignal$", 
                       "[_ .]{1,2}[Mm]ethylated$",
                       "^Methylated_",
                       "_Methylated[.]Detection$",
                       "[.]?Signal[_]?B$", 
                       "_ M$", "[.]M$",
                       "[.]meth$",
                       # GSE58218 is strange
                       "[^h]ylated Signal")
    problematic_pvalue_suffixes <- c('Adjust.Pval')
    pvalue_suffixes <- c("_[ ]?pValue$",
                         "^Detection_P_",
                         "[. _:-]?Detection[. _-]?P[Vv]al(.\\d+)?$", 
                         "[.]Pval$", "[.]Detection$",
                         "[_ ]detection[_ ]p[-]?value[s]?$",
                         "[.]pval")
    suffixes = c(unmeth_suffixes, meth_suffixes, pvalue_suffixes)
    unmeth_files <- grep("Signal_A.NA|_unmeth|_Non_Methyl_", series_id_files)
    if(length(series_id_files) > 1 && length(series_id_files) - length(unmeth_files) == 1 ) {
      # works for GSE62992, GSE50498
      # => two files of raw signals: signal A and signal B, no pvals
      unmeth_signals <- read_l1_signal_file(series_id_fp[unmeth_files], nrows)
      meth_signals <- read_l1_signal_file(series_id_fp[-unmeth_files], nrows)
      
      colnum <- length(colnames(unmeth_signals))
      # remove unrelevant stuff from colnames
      samples.all <- gsub("[.]Signal_A","", colnames(unmeth_signals))
      relevant_samples <- get_relevant_samples(this_targets, samples.all, this_all.series.info)
      relevant_samples.all <- samples.all[relevant_samples, drop = FALSE]
      # assign unmethylated and methylated
      U <- data.matrix(unmeth_signals)[,relevant_samples, drop = FALSE]
      colnames(U) <- relevant_samples.all
      M <- data.matrix(meth_signals)[,relevant_samples, drop = FALSE]
      colnames(M) <- relevant_samples.all
    } else {
      # raw files with 3 columns for each sample
      # GSE36278 has two raw files for different samples
      if(length(series_id_fp) < 3) {
        signals <- do.call("cbind", lapply(series_id_fp, FUN=read_l1_signal_file, nrows))
      } else {
        stop('too many gz files')
      }
      
      if(grepl("ID_REF$|TargetID$", colnames(signals)[[1]], ignore.case = TRUE)) {
        # GSE46306, GSE48684
        if (colnames(signals)[[2]] == "ProbeID_A" && colnames(signals)[[3]] == "ProbeID_B") {
          # GSE50874
          rownames(signals) <- signals[, 1]
          signals <- signals[,-c(1,2,3)]
        } else {
          # GSE53162 which has two rownames columns
          rownames(signals) <- signals[, 1]
          signals <- signals[,-c(1)]
        }
      }
      
      # Remove AVG_Beta or Intensity columns (as in GSE52576, GSE50874, GSE53816)
      signals <- signals[!grepl("[._]AVG_Beta|[.]Intensity", colnames(signals))]
      
      # if there are two reps we use only the first (as in GSE53816)
      old_ncol <- ncol(signals)
      signals <- signals[!grepl("-rep2", colnames(signals))]
      if(ncol(signals) != old_ncol) {
        # remove the rep1 prefix from colnames
        colnames(signals) <- gsub('-rep1', '', colnames(signals))
      }
      
      # locate relevant samples
      if(length(colnames(signals)) == 0) {
        stop('signals is empty')
      }
      orig <- colnames(signals)
      unmeth_ids = grepl(paste(unmeth_suffixes, collapse="|"), orig)
      stopifnot(sum(unmeth_ids) > 0)
      # remove all unmeth expressions (because meth expressions are included in unmeth sometimes)
      orig <- gsub(paste(problematic_unmeth_suffixes, collapse="|"), "", orig)
      meth_ids =  grepl(paste(meth_suffixes, collapse="|"), orig)
      stopifnot(sum(meth_ids) > 0)
      # TODO - check GSE47627, GSE42118
      if(sum(unmeth_ids) != sum(meth_ids)) {
        print(sprintf("%d %d", sum(unmeth_ids), sum(meth_ids)))
        stop("different unmeth_ids and meth_ids!")
      }
      stopifnot(any(meth_ids & unmeth_ids) == FALSE)
      # remove some problematic pvalue expressions
      orig <- gsub(paste(problematic_pvalue_suffixes, collapse="|"), "", orig)
      pval_ids = grepl(paste(pvalue_suffixes, collapse="|"), orig)
      if(!is.null(pval_ids) & sum(pval_ids) > 0) {
        if(sum(unmeth_ids) != sum(pval_ids)) {
          stop(sprintf("different unmeth_ids (%d) and pval_ids (%d)!", sum(unmeth_ids), sum(pval_ids)))
        }
      }
      
      # remove suffixes from colnames
      colnames(signals) <- mgsub(suffixes, character(length(suffixes)), colnames(signals))
      samples.all <- colnames(signals)[unmeth_ids]
      
      relevant_samples <- get_relevant_samples(this_targets, samples.all, this_all.series.info)
      # assign  unmethylated, methylated and pvalue matrices
      U <- data.matrix(signals[,unmeth_ids, drop = FALSE])[,relevant_samples, drop = FALSE]
      M <- data.matrix(signals[,meth_ids, drop = FALSE])[,relevant_samples, drop = FALSE]
      if(!is.null(pval_ids) & sum(pval_ids) > 0) {
        p.values <- data.matrix(signals[,pval_ids, drop = FALSE])[,relevant_samples, drop = FALSE]
      }
    }
    stopifnot(dim(this_targets)[[1]] == dim(U)[[2]])
    betas.table <- rnbReadL1Betas(this_targets, U, M, p.values)
    write_beta_values_table(output_filename, betas.table)
  }
}

#' Read GEO L1 data of given series id
#' 
#' @param series_id_orig
#' @param targets
#' @param all.series.info
#' @param study
#' @param type
#' @param geo_data_folder
#' @param generated_GEO_folder
#' 
#' @return nothing
readGeoL1Data <- function(series_id_orig, targets, all.series.info, study, type, 
                          geo_data_folder, generated_GEO_folder) {
  cat('\tReading ', series_id_orig, ": ")
  # handle samples which comes from multiple serieses
  series_id_vec <- unlist(strsplit(series_id_orig, ","))
  series_id <- NULL
  
  # check for idat files in the first series id
  idat_targets <- subset(targets, !is.na(supplementary_file))
  stopifnot(length(idat_targets) == length(targets))
  if(nrow(idat_targets) > 0) {
    series_id <- series_id_vec[[1]]
    series_id_folder <- file.path(geo_data_folder, series_id)
    series_id_files <- list_series_id_files(series_id_folder)
    if(length(series_id_vec) > 1 & length(series_id_files) == 0) {
      # use the other series id
      series_id <- series_id_vec[[2]]
      series_id_folder <- file.path(geo_data_folder, series_id)
      series_id_files <- list_series_id_files(series_id_folder)
    }
  }
  if(is.null(series_id)) {
    for(series_id_tmp in series_id_vec) {
      # check for data files
      series_id_folder <- file.path(geo_data_folder, series_id_tmp)
      series_id_files <- list_series_id_files(series_id_folder)
      if(length(series_id_files) > 0) {
        series_id <- series_id_tmp
        break
      }
    }
    if(is.null(series_id)) {
      stop(paste('no data files found for', series_id_orig))
    }
  }
  output_filename <- get_output_filename(generated_GEO_folder, series_id, study, type)
  if(file.exists(output_filename)) {
    print(sprintf('%s already exists. skipping', basename(output_filename)))
  } else {
    ptime1 <- proc.time()
    if(nrow(idat_targets) > 0 & length(series_id_files) == 0) {
      readGeoL1DataWithIdats(series_id_folder, series_id_orig, series_id_files, 
                             output_filename, targets, all.series.info)
    } else {
      readGeoL1DataWithoutIdats(series_id_folder, series_id_orig, series_id_files, 
                                output_filename, targets, all.series.info)
    }
    stime <- (proc.time() - ptime1)[3]
    cat("   in", stime, "seconds\n")
  }
}

workOnGEOTargets <- function(targets, all.series.info, geo_data_folder) {
  study <- levels(factor(targets$disease))[[1]]
  type <- levels(factor(targets$tissue_or_cell_type))[[1]]
  series_id <- levels(factor(targets$series_id))
  name <- create_name(study, type)
  print(sprintf("Reading %d samples of %s from %d serieses (study=%s, type=%s)", 
                nrow(targets), name, length(series_id), study, type))
  ret <- lapply(series_id, FUN=readGeoL1Data, targets, all.series.info, 
                study, type, geo_data_folder, generated_GEO_folder)
}


run_organize_geo <- function() {
	dir.create(generated_GEO_folder, recursive=TRUE, showWarnings=FALSE)

	joined_folder <- file.path(data_folder, "global/GEO/joined")
	joined_files <- list.files(joined_folder, full.names = TRUE, pattern="*.txt")

	# == skip serieses ==
	# GEOs which I don't know how to parse:
	# - no l1 signals txt file
	# - different parsing on l1 txt file
	no_l1_list <- c('GSE37965', 'GSE39279', 'GSE39560', 'GSE41169', 'GSE53924', 'GSE39141', 
	                'GSE34777')
	not_released_list <- c('GSE62003', 'GSE49064')
	# work ids:
	
	# GSE48472 - When using idats - on the 9/10 target it has error inside illuminaio (which is used by rnbeads):
	#   "Reading 6 samples of Healthy.Subcutaneous_fat from 1 serieses (study=Healthy, type=Subcutaneous fat)"
	#     2015-06-17 13:23:38     0.8  STATUS STARTED Loading Data from IDAT Files
	#    Error in readBin(con, what = "integer", n = n, size = 4, endian = "little",  : 
	#	                   invalid 'n' argument
	# => But it works using GSE48472_non-normalized.txt.gz.
	
	
	# bad ids:
	
  # GSE41114 - has problem with the header columns - there 2is another ID_REF in it
	# GSE40699 - idat file names are not like 450k standart
	# RnBeads raises:
	# Undefined platform; please check Sentrix ID and Sentrix Position columns in the sample sheet
	
	# GSE30338
	# I don't understand the methylation_intensity files (3 files)

	# GSE29290
	# "read_l1_signal_file called on ../../../my_atlas/GEO/GSE29290/GSE29290_Matrix_Signal.txt.gz for -1 rows"
	#        Reading  GSE60185 : Error: splited_supplementary_file_len_unique[[1]] == 2 is not TRUE

	# GSE51032
	# Reading  GSE51032 : Error in `row.names<-.data.frame`(`*tmp*`, value = value) :
	# duplicate 'row.names' are not allowed
	# Calls: run_organize_geo ... rownames<- -> row.names<- -> row.names<-.data.frame

	#  GSE51032,GSE51057

	# GSE61278
	# [2] "GSE61278_MatrixSignalIntensities.csv.gz"
	# [1] "read_l1_signal_file called on ../../../my_atlas/GEO/GSE61278/GSE61278_MatrixProcessed.txt.gz for -1 rows"
	# [1] "read_l1_signal_file called on ../../../my_atlas/GEO/GSE61278/GSE61278_MatrixSignalIntensities.csv.gz for -1 rows"
	# Error in data.frame(..., check.names = FALSE) :
	#   arguments imply differing number of rows: 366306, 485512
	# Calls: run_organize_geo ... do.call -> do.call -> cbind -> cbind -> cbind -> data.frame


	# on 22.7
	# GSE42861
	# Error: sum(unmeth_ids) > 0 is not TRUE

	# GSE61450
	# 2015-07-22 14:41:14     2.7  STATUS STARTED Loading Data from IDAT Files
	# Error in if (magic != "IDAT") { : argument is of length zero
	# Calls: run_organize_geo ... workOnIdatsFolder -> rnb.execute.import -> read.idat.files -> readIDAT

	# GSE60655
	# Reading  GSE60655 : Error: splited_supplementary_file_len_unique[[1]] == 2 is not TRUE

	bad_list <- c(no_l1_list, not_released_list,
				  'GSE37754', 'GSE40360', 'GSE40279', 'GSE41826', 'GSE43976', 'GSE42882', 
				  'GSE46573', 'GSE49377', 'GSE55598', 'GSE55438', 'GSE56044', 'GSE61044', 
				  'GSE61380', 'GSE48684', 'GSE49542', 'GSE42372', 'GSE32079', 'GSE46168', 
				  'GSE47627', 'GSE61151', 'GSE32146', 'GSE41114', 'GSE30338', 
				  'GSE61107', 'GSE40790', 'GSE35069', 'GSE51032', 'GSE61278', 
				  'GSE42861', 'GSE61450', 'GSE60655')
	wait_list <- c('GSE62924', 'GSE51245', 'GSE38266', 'GSE29290', 'GSE50759', 'GSE51032', 'GSE51057')
	ignore_list <- paste0(joined_folder, "/", c(bad_list, wait_list), ".txt")
	geo_data_folder <- file.path(external_disk_data_path, 'GEO')
	stopifnot(file.exists(geo_data_folder))
	only_vec <- list.files(geo_data_folder)
	# XXX # TODO - see if GSE46306 is working?
	only_vec <- c('GSE40699')
	#only_vec <- c('GSE62727')
	# TODO
	# check GSE59250
	# it raises 
	# WARNING Some of the supplied probes are missing annotation and will be discarded
	
	# for hai ( is bad)
	#hai_bad_vec <- c('GSE30338', 'GSE42752', 'GSE41826', 'GSE49377', 'GSE61380', 
	#                 'GSE53924', 'GSE42882', 'GSE46573', 'GSE61107')
	#working_vec <- c('GSE36278', 'GSE52556', 'GSE52576', 'GSE61160', 'GSE32283', 'GSE53816', 
	#                 'GSE49576', 'GSE54776', 'GSE55712', 'GSE58218', 'GSE61431', 'GSE62727', 
	#                 'GSE31848', 'GSE43414', 'GSE50798', 'GSE48461', 'GSE59524', 'GSE46306')
	#only_vec <- working_vec
	
	only_list <- paste0(joined_folder, "/", c(only_vec), ".txt")
	skiped_joined_files <- joined_files[(joined_files %in% only_list) & (joined_files %in% ignore_list)]
	if(length(skiped_joined_files) > 0) {
	  print('The following files were ignored:')
	  print(skiped_joined_files)
	}
	joined_files <- joined_files[(joined_files %in% only_list) & !(joined_files %in% ignore_list)]
	stopifnot(length(joined_files) > 0)
	#print("joined_files:")
	#print(joined_files)

	all.series.info <- do.call("rbind", lapply(joined_files, FUN=read_joined_file))
	# get only relevant samples
	relevant.samples.idx <- which(as.numeric(all.series.info$relevant) == 1)
	pheno <- all.series.info[relevant.samples.idx, ]
  
	# Fix pheno values
	col_vec <- c('series_id', 'title', 'cell_type', 'tissue', 'disease')
	missing_cond <- (is.na(pheno$tissue) | pheno$tissue=='') & (is.na(pheno$cell_type) | pheno$cell_type=='')
	duplicate_cond <- !is.na(pheno$tissue) & pheno$tissue!='' & !is.na(pheno$cell_type) & pheno$cell_type!=''
	#missing_both <- subset(pheno, missing_cond)
	#duplicate_names <- subset(pheno, duplicate_cond)
	#write.csv(missing_both[,col_vec], file='missing_both.csv')
	#write.csv(duplicate_names[,col_vec], file='duplicate_names.csv')
	
	pheno <- subset(pheno, !(missing_cond | duplicate_cond))
	pheno$tissue_or_cell_type <- paste3(pheno$tissue, pheno$cell_type)
  
	splited_targets <- split(pheno, list(pheno$disease, pheno$tissue_or_cell_type), drop=TRUE)
	geo_data_folder <- file.path(external_disk_data_path, 'GEO')
	indices <- get_indices_to_runon(splited_targets, args)
	#indices <- c(3)
	logger.start(fname=NA)
	#num.cores <- detectCores()/2
	#parallel.setup(num.cores)
	for (i in indices) {
	  if(i <= length(splited_targets)) {
	    print(sprintf('working on %d/%d', i, length(splited_targets)))
	    workOnGEOTargets(splited_targets[[i]], all.series.info, geo_data_folder)
	  } else {
	    print(sprintf("skipping %d/%d, index out of range", i, length(splited_targets)))
	  }
	}
	#parallel.disable()
  
	print("DONE")  
}

run_organize_geo()
