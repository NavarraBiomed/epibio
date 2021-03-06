
source("config.R")
source("common.R")
source("RnBeadsCommon.R")
args <- commandArgs(trailingOnly = TRUE)


work_on_targets <- function(targets, idat_folder, tcga_inside_name) {
  type <- targets$histological_type[[1]]
  study <- targets$sample_type[[1]]
  output_filename <- get_output_filename(generated_TCGA_folder, tcga_inside_name, study, type)
  if(file.exists(output_filename)) {
    print(sprintf('%s already exists. skipping', basename(output_filename)))
  } else {
    tryCatch({
      targets <- head(targets, 20) # XXX
      betas.table <- workOnIdatsFolder(idat_folder, targets, 'barcode')
	  write_beta_values_table(output_filename, betas.table)
    }, error = function(err) {
      print(err)
      print(sprintf('Got error during working on %s %s %s - skipping', tcga_inside_name, type, study))
    }
    )
  }
}

work_on_tcga_folder <- function(tcga_inside_name, tcga_folder) {
  # folder structure looks like this:
  # TCGA\UCS\DNA_Methylation\JHU_USC__HumanMethylation450\Level_1
  tcga_inside_folder <- file.path(tcga_folder, tcga_inside_name)
  tcga_inside_folder <- list.files(tcga_inside_folder, full.names = TRUE)
  tcga_inside_folder <- list.files(tcga_inside_folder, full.names = TRUE)
  tcga_inside_folder <- tcga_inside_folder[grepl("450", tcga_inside_folder)]
  samples_filename <- file.path(tcga_inside_folder, paste0(tcga_inside_name, '_sample_annotation.txt'))
  idat_folder <- file.path(tcga_inside_folder, 'Level_1')
  
  targets <- read.table(samples_filename, sep='\t', header=TRUE, 
                        na.strings=c("NA", "0"), quote="\"", stringsAsFactors=FALSE)
  targets$barcode <- targets$Array.Data.File
  rownames(targets) <- targets$barcode
  splited_targets <- split(targets, list(targets$histological_type, targets$sample_type), drop=TRUE)
  print(sprintf('-> working on %s targets', length(splited_targets)))
  ret <- lapply(splited_targets, FUN=work_on_targets, idat_folder, tcga_inside_name)
}


run_organize_tcga <- function() {
	dir.create(generated_TCGA_folder, recursive=TRUE, showWarnings=FALSE)

	tcga_folder <- file.path(external_disk_data_path, 'TCGA')
	stopifnot(file.exists(tcga_folder))
	tcga_inside_folders <- list.dirs(tcga_folder)
	ignore_list <- c("Clinical", "download_2", "download_3", "download_4")
	tcga_inside_folders <- tcga_inside_folders[!(tcga_inside_folders %in% ignore_list)]
	indices <- get_indices_to_runon(tcga_inside_folders, args)
	#indices <- c(3)
	for (i in indices) {
	  if(i <= length(tcga_inside_folders)) {
	    cur <- tcga_inside_folders[[i]]
	    print(sprintf('working on %s (%d/%d)', cur, i, length(tcga_inside_folders)))
	    work_on_tcga_folder(cur, tcga_folder)
	  } else {
	    print(sprintf("skipping %d/%d, index out of range", i, length(tcga_inside_folders)))
	  }
	}
	print("DONE")
}

run_organize_tcga()
