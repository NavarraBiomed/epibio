
library(RnBeads)

source('config.R')
source('common.R')
source("RnBeadsCommon.R")

data_folder <- '../../../../lab_data'
idat_folder <- file.path(data_folder, 'idats')
pheno_file <- file.path(data_folder, 'samples_cluster.csv')

rnb.options(identifiers.column='Sample_Name')
rnb.set <- rnb.execute.import(list(idat_folder, pheno_file))
betas.table <- process_rnb_set_to_betas(rnb.set, TRUE)

pheno <- pheno(rnb.set)
sample_groups <- unique(pheno$Sample_Group)

dir.create(generated_lab_data_folder, recursive=TRUE, showWarnings=FALSE)

for (i in 1:length(sample_groups)) {
	cols <- which(pheno$Sample_Group == sample_groups[i])
	output_file <- gzfile(file.path(generated_lab_data_folder, paste0(sample_groups[i], '.txt.gz')))
	write.table(betas.table[,cols], output_file,sep='\t',col.names=NA)
}
print('Done')
