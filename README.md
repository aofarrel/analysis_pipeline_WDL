# TOPMed analysis pipeline

## Setup

We recommend building R with [Intel MKL](https://software.intel.com/en-us/intel-mkl) for improved performance in PC-Relate and association tests.

Run the `install_packages.R` script to install required R packages.

Additional software
- [bcftools](http://www.htslib.org/download/)
- [PLINK](https://www.cog-genomics.org/plink2/)
- [KING](http://people.virginia.edu/~wc9c/KING/Download.htm)
- [LocusZoom](https://github.com/UW-GAC/locuszoom-standalone)


## Basic outline

Each script in the `R` directory takes a config file with parameters. Look at the beginning of each script for parameter lists. Some parameters are required; others are optional with default values.

Some scripts can be run in parallel by chromosome. For these scripts, the chromosome number is given as an argument: `"--chromosome 22"` (or `"-c 22"`). If running in parallel, include a space in file names in the config file where chromosome should be inserted, e.g.,
```
gds_file "1KG_phase3_subset_chr .gds"
```

Nearly all scripts require a GDS file in SeqArray format. Phenotype files should be an AnnotatedDataFrame saved in an RData file. See `?AnnotatedDataFrame` or the SeqVarTools documentation for details. Example files are provided in `testdata`.

Python scripts are provided to run multi-step analyses on a compute cluster or cloud environment. `TopmedPipeline.py` defines cluster environment classes, currently a Sun Grid Engine (SGE) cluster, Amazon's cfncluster Son of Grid Engine (also SGE), and AWS Batch. Additional classes may be added for other environments. Default cluster options are provided in the JSON file `cluster_cfg.json`. These options may be overridden at run time by specifying a JSON file with the `--cluster_file` option in the python scripts. Only options that should be changed from the default need to be included in the file. See `custom_cluster_cfg.json` for an example.

These python scripts require a config argument `out_prefix` in addition to the arguments for each R script called. Some input and output file name parameters are overridden by the scripts in order to link jobs together. Example config files are in `testdata`.

Python script arguments are shown below. Note: not all arguments are available in all scripts, and some scripts may have additional arguments. Run with `-h` or `--help` to see details for a particular script.

argument  | default value | description
--- | --- | ---
`config_file` | | configuration file
`--cluster_type` | `UW_Cluster` | type of compute cluster environment (`UW_Cluster`, `AWS_Cluster`, `AWS_Batch`)
`--cluster_file` | `None` | JSON file containing cluster options
`-c, --chromosomes` | `1-23` | range of chromosomes (23=X)
`-n, --ncores` | `1-8` | number of cores to use; either a number (e.g, 1) or a range of numbers (e.g., 1-4)
`-e, --email` | `None` | email address to receive job completion report
`--print_only` | `False` | print job submission commands without submitting them
`--verbose` | `False` | verbose messages for debugging
`--version` | | show the version number and exit
`-h, --help` | | print help message and exit


## Conversion to GDS

Step 1 converts VCF files (one per chromosome) into GDS files, discarding non-genotype FORMAT fields. (BCF files may be used instead of VCF if [bcftools](https://samtools.github.io/bcftools/bcftools.html) is installed.) Step 2 ensures that each variant has a unique integer ID across the genome, so the variant.id field in per-chromosome files and combined files are consistent. Step 3 checks that genotypes are consistent between the converted and original files. Step 4 (optional) combines the per-chromosome files into a single GDS file. It is recommended to skip this merge and instead use the GDS file output by `ld_pruning.py` for relatedness and population strucuture analyses that require all chromosomes in a single file.

`vcf2gds.py`

1. `vcf2gds.R`
2. `unique_variant_ids.R`
3. `check_gds.R`
4. `merge_gds.R` (optional with `--merge`)
5. `check_merged_gds.R` (optional with `--merge`)

config parameter | default value | description
--- | --- | ---
`out_prefix` | | Prefix for files created by this script.
`vcf_file` | | Input VCF file. Include a space to insert chromosome.
`gds_file` | | Output GDS file. Include a space to insert chromosome.
`merged_gds_file` | `NA` | Merged genotype-only GDS file containing all chromosomes.
`format` | `GT` | FORMAT fields from the VCF to convert to GDS. Default is genotypes only.


## Relatedness and Population structure

The first step in evalulating relatedness and population structure is to select a subset of variants with LD pruning and create a GDS file containing only these variants. KING is used to get initial estimates of kinship for close relatives (using the "IBDSeg" methed) and a full matrix of population divergence estimates for all sample pairs (using the "robust" method). These two matrices are used by PC-AiR to identify a set of unrelated samples, run Principal Component Analysis on unrelated samples, and project relatives. Finally, PC-Relate estimates kinship accounting for population structure.

1. LD pruning to select variants

    `ld_pruning.py`
    1. `ld_pruning.R`
	2. `subset_gds.R`
	3. `merge_gds.R`
	4. `check_merged_gds.R`

    config parameter | default value | description
    --- | --- | ---
    `out_prefix` | | Prefix for files created by this script.
	`gds_file` | | GDS file. Include a space to insert chromosome. 
	`subset_gds_file` | | Output GDS file, to contain only LD pruned variants from all chromosomes.
	`autosome_only` | `TRUE` | Only include autosomes in LD pruning.
	`ld_r_threshold` | `0.32` | `r` threshold for LD pruning. Default is `r^2 = 0.1`.
	`ld_win_size` | `10` | Sliding window size in Mb for LD pruning.
	`maf_threshold` | `0.01` | Minimum MAF for variants used in LD pruning. 
	`missing_threshold` | `0.01` | Maximum missing call rate for variants used in LD pruning.
	`exclude_pca_corr` | `TRUE` | Exclude variants in regions with high correlation with PCs (HLA, LCT, inversions).
	`genome_build` | `hg38` | Genome build, used to define correlation regions.
	`sample_include_file` | `NA` | RData file with vector of sample.id to include.
	`variant_include_file` | `NA` | RData file with vector of variant.id to include.

2. [KING](http://www.ncbi.nlm.nih.gov/pubmed/20926424) to get initial kinship estimates

    `king.py`
    1. `gds2bed.R`
	2. `plink --make-bed`
	3. `king --ibdseg`
	    - `kinship_plots.R`
	    - `king_to_matrix.R`
	4. `ibd_king.R`

    config parameter | default value | description
    --- | --- | ---
    `out_prefix` | | Prefix for files created by this script.
    `gds_file` | | GDS file with only LD pruned variants, all chromosomes.
	`bed_file` | | Output BED file.
	`sample_include_file` | | RData file with vector of sample.id to include. Required to ensure that the two output matrices have the same dimensions. 
	`variant_include_file` | `NA` | RData file with vector of variant.id to include. 
	`sparse_threshold` | `0.01104854` | Minimum kinship to use for creating the sparse matrix from `king --ibdseg` output (default is `2^(-13/2)` or 5th degree relatives). A block diagonal matrix will be created such that any pair of samples with a kinship greater than the threshold is in the same block, and pairwise kinship between blocks is 0. Not used for the output of `king --kinship`, which is always saved as a dense GDS file.
	`phenotype_file` | `NA` | RData file with AnnotatedDataFrame of phenotypes. Used for plotting kinship estimates separately by study.
	`study` | `NA` | Name of column in `phenotype_file` containing study variable.

3. [PC-AiR](http://www.ncbi.nlm.nih.gov/pubmed/25810074) to select an informative set of unrelated samples, do PCA on unrelated, project into relatives

    `pcair.py`
    1. `find_unrelated.R`
    2. `ld_pruning.R` (optional with `--ld_pruning`)
    3. `combine_variants.R` (optional  with `--ld_pruning`)
    4. `pca_byrel.R`
	5. `pca_plots.R`
	6. `pca_corr_vars.R`
	7. `pca_corr.R`
	8. `pca_corr_plots.R`

	The LD pruning step is run if the argument `--ld_pruning` is provided; otherwise, use a GDS file with a subset of pruned variants, or set `variant_include_file` to a pre-existing set of pruned variants.

    config parameter | default value | description
    --- | --- | ---
    `out_prefix` | | Prefix for files created by this script. 
    `gds_file` | | GDS file with only LD pruned variants, all chromosomes.
	`full_gds_file` | | GDS file with all variants. Include a space to insert chromosome.
	`king_file` | | GDS (recommended) or RData file with kinship coefficients created by `king.py`. Used for ancestry divergence, and optionally for kinship if `kinship_file` is not specified.
	`kinship_file` | `NA` | File containing kinship matrix to use for defining the unrelated sample set. Multiple formats are accepted, including RData or GDS from `king.py` or `pcrelate.py`. A sparse Matrix object stored as RData is recommended.
	`kinship_threshold` | `0.04419417` | Minimum kinship estimate to use for assigning relatives (default is `2^(-9/2)` or 3rd degree relatives). 
	`divergence_threshold` | `-0.04419417` | Minimum kinship estimate to use for ancestry divergence (default is `-2^(-9/2)`).
	`sample_include_file` | `NA` | RData file with vector of sample.id to include. 
	`ld_r_threshold` | `0.32` | `r` threshold for LD pruning. Default is `r^2 = 0.1`.
	`ld_win_size` | `10` | Sliding window size in Mb for LD pruning.
	`maf_threshold` | `0.01` | Minimum MAF for variants used in LD pruning. 
	`exclude_pca_corr` | `TRUE` | Exclude variants in regions with high correlation with PCs (HLA, LCT, inversions). 
	`genome_build` | `hg38` | Genome build, used to define correlation regions. 
	`variant_include_file` | `NA` | RData file with vector of variant.id to include.
	`n_pcs` | `32` | Number of PCs to return.
	`n_pair` | `6` | Number of PCs in include in the pairs plot.
	`n_corr_vars` | `10e6` | Number of variants to sample across the genome for PC-variant correlation plots.
	`n_perpage` | `4` | Number of PC-variant correlation plots to stack in a single page. The number of png files generated will be `ceiling(n_pcs/n_perpage)`.
	`thin` | `TRUE` | Logical for whether to thin points in the PC-variant correlation plots.
	`phenotype_file` | `NA` | RData file with AnnotatedDataFrame of phenotypes. Used for color-coding PCA plots by group.
	`group` | `NA` | Name of column in `phenotype_file` containing group variable.

4. [PC-Relate](http://www.ncbi.nlm.nih.gov/pubmed/26748516) to estimate kinship coefficients adjusted for population structure and admixture using PCs

    `pcrelate.py`
    1. `pcrelate_beta.R`
	2. `pcrelate.R`
	3. `pcrelate_correct.R`
	4. `kinship_plots.R`

    config parameter | default value | description
    --- | --- | ---
    `out_prefix` | | Prefix for files created by this script. 
    `gds_file` | | GDS file with only LD pruned variants, all chromosomes.
	`pca_file` | | RData file with PCA results created by `pcair.py`.
	`n_pcs` | `3` | Number of PCs to use in adjusting for ancestry. 
	`n_sample_blocks` | `1` | Number of blocks to divide samples into for parallel computation. Adjust depending on computer memory and number of samples in the analysis.
	`sample_include_file` | `NA` | RData file with vector of sample.id to include. 
	`variant_block_size` | `1024` | Number of variants to read in a single block. 
	`variant_include_file` | `NA` | RData file with vector of variant.id to include.
	`sparse_threshold` | `0.01104854` | Minimum kinship to use for creating the sparse matrix (default is `2^(-13/2)` or 5th degree relatives). A block diagonal matrix will be created such that any pair of samples with a kinship greater than the threshold is in the same block, and pairwise kinship between blocks is 0. 
	`phenotype_file` | `NA` | RData file with AnnotatedDataFrame of phenotypes. Used for plotting kinship estimates separately by study.
	`study` | `NA` | Name of column in `phenotype_file` containing study variable.


### GRM

An as alternative to separating recent relatedness from ancestry, one can compute a Genetic Relationship Matrix (GRM).

The GRM is calculated for each chromosome separately, and then averaged to create the final GRM.

`grm.py`
1. `grm.R`
2. `grm_combine.R`

config parameter | default value | description
--- | --- | ---
`out_prefix` | | Prefix for files created by this script. 
`gds_file` | | GDS file. Include a space to insert chromosome.
`method` | `GCTA` | Method used to compute GRM. Options are `GCTA`, `EIGMIX`, and `IndivBeta`.
`maf_threshold` | `0.001` | Minimum MAF for variants used. 
`missing_threshold` | `0.01` | Maximum missing call rate for variants used.
`exclude_pca_corr` | `TRUE` | Exclude variants in regions with high correlation with PCs (HLA, LCT, inversions).
`genome_build` | `hg38` | Genome build, used to define correlation regions.
`sample_include_file` | `NA` | RData file with vector of sample.id to include.
`variant_include_file` | `NA` | RData file with vector of variant.id to include.


## Association testing

Association tests are done with a mixed model if a kinship matrix (`pcrelate_file`) or GRM (`grm_file`) is given in the config file. If `pcrelate_file` and `grm_file` are both `NA` or missing, testing is done with a fixed effects model.

When combining samples from groups with different variances for a trait (e.g., study or ancestry group), it is recommended to allow the null model to fit heterogeneous variances by group using the parameter `group_var`. The default pipeline options will then result in the following procedure:

1. Fit null mixed model with outcome variable
    - Allow heterogeneous variance by `group_var`
    - Include covariates and PCs as fixed effects
    - Include kinship as random effect
2. Inverse normal transform marginal residuals (if `inverse_normal = TRUE`)
3. Rescale variance to match original (if `rescale_variance = "marginal"` or `"varcomp"`)
4. Fit null mixed model using transformed residuals as outcome
    - Allow heterogeneous variance by `group_var`
    - Include covariates and PCs as fixed effects
    - Include kinship as random effect

The effect estimate is for the alternate alelle, and multiple alternate alelles for a single variant are treated separately.

Association tests have an additional level of parallelization: by segment within chromosome. The R scripts take an optional `"--segment"` (or `"-s"`) argument. The python script `assoc.py` uses the environment variable `SGE_TASK_ID` to submit jobs by segment for each chromosome. By default each segment is 10 Mb in length, but this may be changed by using the arguments `"--segment_length"` or `"--n_segments"`. Note that `"--n_segments"` defines the number of segments for the entire genome, so using this argument with selected chromosomes may result in fewer segments than you expect (and the minimum is one segment per chromosome).

### Parameters common to all association tests

config parameter | default value | description
--- | --- | ---
`out_prefix` | | Prefix for files created by this script.
`gds_file` | | GDS file. Include a space to insert chromosome.
`pca_file` | `NA` | RData file with PCA results created by `pcair.py`.
`pcrelate_file` | `NA` | RData file with 2*kinship created by `pcrelate.py`. 
`grm_file` | `NA` | GDS file with GRM created by `grm.py`.
`phenotype_file` | | RData file with AnnotatedDataFrame of phenotypes.
`outcome` | | Name of column in `phenotype_file` containing outcome variable.
`binary` | `FALSE` | `TRUE` if `outcome` is a binary (case/control) variable; `FALSE` if `outcome` is a continuous variable.
`covars` | `NA` | Names of columns `phenotype_file` containing covariates, quoted and separated by spaces.
`group_var` | `NA` | Name of covariate to provide groupings for heterogeneous residual error variances in the mixed model.
`inverse_normal` | `TRUE` | `TRUE` if an inverse-normal transform should be applied to the outcome variable.
`norm_bygroup` | `FALSE` | If `TRUE` and `group_var` is provided, the inverse normal transform is done on each group separately.
`rescale_variance` | `marginal` | Applies only if `inverse_normal` is `TRUE`. Controls whether to rescale the variance after inverse-normal transform, restoring it to the original variance before the transform. Options are `marginal`, `varcomp`, or `none`.
`n_pcs` | `0` | Number of PCs to include as covariates.
`conditional_variant_file` | `NA` | RData file with data frame of of conditional variants. Columns should include `chromosome` and `variant.id`. The alternate allele dosage of these variants will be included as covariates in the analysis.
`sample_include_file` | `NA` | RData file with vector of sample.id to include. 
`variant_include_file` | `NA` | RData file with vector of variant.id to include. 
`variant_block_size` | `1024` | Number of variants to read in a single block.
`pass_only` | `TRUE` | `TRUE` to select only variants with FILTER=PASS.
`genome_build` | `hg38` | Genome build for the genotypes in the GDS file (`hg19` or `hg38`). Used to divide the genome into segments for parallel processing. 
`plot_mac_threshold` | `NA` | Minimum minor allele count for variants or aggregate units to include in plots (if different from threshold used to run tests; see `mac_threshold` below).
`thin` | `TRUE` | Logical for whether to thin points in the QQ and manhattan plots. 
`thin_nbins` | `10` | Number of bins to use for thinning.
`thin_npoints` | `10000` | Number of points in each bin after thinning.


### Single-variant

`assoc.py single`

1. `null_model.R`
2. `define_segments.R`
3. `assoc_single.R`
4. `asoc_combine.R`
5. `assoc_plots.R`

config parameter | default value | description
--- | --- | ---
`mac_threshold` | `5` | Minimum minor allele count for variants to include in test. Use a higher threshold when outcome is binary.
`maf_threshold` | `0.001` | Minimum minor allele frequency for variants to include in test. Only used if `mac_threshold` is `NA`.
`test_type` | `score` | Type of test to perform. If samples are related (mixed model), options are `score` and `wald` if `binary` is `FALSE`, `score` only if `binary` is `TRUE`.
`known_hits_file` | `NA` | RData file with data.frame containing columns `chr` and `pos`. If provided, 1 Mb regions surrounding each variant listed will be omitted from the QQ and manhattan plots.


### Parameters common to aggregate and sliding window tests

config parameter | default value | description
--- | --- | ---
`alt_freq_max` | `1` | Maximum alternate allele frequency to consider.
`test` | `burden` | Test to perform. Options are `burden`, `skat`, or `smmat`.
`test_type` | `score` | Type of test to perform if `test` is `burden`. Options are `score` and `wald` if `binary` is `FALSE`, `score` if `binary` is `TRUE`.
`pval_skat` | `kuonen` | Method used to calculate p-values if `test` is `skat`. Options are `kuonen` (uses saddlepoint method), `davies` (uses numerical integration), and `liu` (uses a moment matching approximation).
`rho` | `0` | A numeric value (or quoted, space-delimited list of numeric values) in [0,1] specifying the rho parameter when `test` is `skat`. `0` is a standard SKAT test, `1` is a score burden test, and multiple values is a SKAT-O test.
`variant_weight_file` | `NA` | RData file with data frame defining variant weights. Columns should contain either `variant.id` or all of (`chr`, `pos`, `ref`, `alt`).
`weight_user` | `NA` | Name of column in `variant_weight_file` or `variant_group_file` (see aggregate test, below) containing the weight for each variant.
`weight_beta` | `"1 1"` | Parameters of the Beta distribution used to determine variant weights, quoted and space-delimited. `"1 1"` is flat weights, `"0.5 0.5"` is proportional to the Madsen-Browning weights, and `"1 25"` gives the Wu weights. This parameter is ignored if `weight_user` is provided.


### Aggregate

`assoc.py aggregate`

1. `null_model.R`
2. `aggregate_list.R`
3. `define_segments.R`
4. `assoc_aggregate.R`
5. `asoc_combine.R`
6. `assoc_plots.R`

config parameter | default value | description
--- | --- | ---
`aggregate_type` | `allele` | Type of aggregate grouping. Options are to select variants by `allele` (unique variants) or `position` (regions of interest).
`variant_group_file` | | RData file with data frame defining aggregate groups. If `aggregate_type` is `allele`, columns should be `group_id`, `chr`, `pos`, `ref`, `alt`. If `aggregate_type` is `position`, columns should be `group_id`, `chr`, `start`, `end`.
`variant_include_file` | `NA` | RData file with vector of variant.id to include. Variants used will be the intersection of this set and variants defined by `variant_group_file`.


### Sliding window

`assoc.py window`

1. `null_model.R`
2. `define_segments.R`
3. `assoc_window.R`
4. `asoc_combine.R`
5. `assoc_plots.R`

config parameter | default value | description
--- | --- | ---
`window_size` | `50` | Size of sliding window in kb.
`window_step` | `20` | Step size of sliding window in kb.


### Parallelization details

The segment file created at the start of each association test contains the chromosome, start, and end position for each segment. R scripts for association testing each take chromosome and segment as arguments.

* Single-variant: only variants within in the segment are selected.
* Aggregate: aggregate units where the first variant is within the segment are selected. This ensures that each unit is tested exactly once.
* Sliding window: the length of the segment is increased by `window.size` before selecting variants. This ensures that all possible windows are tested. When the segments are combined into a single file for each chromosome, duplicate windows are discarded. Since the `assocTestSeqWindow` function defines windows starting at position 1, the windows tested when parallelizing by segment are identical to the windows tested when running an entire chromosome in one job.

The script [`assoc.py`](assoc.py) submits a SGE array job for each chromosome, where the SGE task id is the row number of the segment in the segments file. If a segment has no requested variants, its job will exit without error. After all segments are complete, they are combined into a single file for each chromosome and the temporary per-segment output files are deleted.


### Multiple tests with the same null model

To run additional tests using the same null model as a previous test, add the config parameters `null_model_file` and `null_model_params`. `null_model_file` is the output file created by a previous association test run. `null_model_params` is the parameter file ending in `null_model.params` in the `report` directory for the previous association test. The parameter file is needed to generate the report for the new test.

If the number of samples in the initial phenotype file was less than the total number of samples in the GDS file, also provide `phenotype_file` as the output phenotype file created along with the null model file.



## LocusZoom

LocusZoom plots are created with the [LocusZoom standalone software](https://github.com/UW-GAC/locuszoom-standalone).

Loci to plot are specified in the `locus_file`, with chromosome `chr` and either `variant.id` (to specify the reference variant) or `start end` (to indicate a region to plot, in which case the variant with the smallest p-value will be the reference. Population (`pop`) is either `TOPMED` or one of the 1000 Genomes populations (`hg19`:`AFR`, `AMR`, `ASN`, `EUR`; `hg38`: `AFR`, `AMR`, `EUR`, `EAS`, `SAS`). If `pop = TOPMED`, LD is computed from the TOPMed data using the sample set in `ld_sample_include`.

Regions from sliding window or aggregate tests with p-values below a certain threshold can be displayed in a separate track. 

`locuszoom.py`
1. `locuszoom.R`

config parameter | default value | description
--- | --- | ---
`out_prefix` | | Prefix for files created by this script.
`assoc_file` | | File with single-variant association test results. Include a space to insert chromosome.
`locus_file` | | Text file with columns `chr`, `pop` and either `variant.id` (for `locus_type=variant`) or `start`, `end` (for `locus_type=region`)
`locus_type` | `variant` | Type of region to plot (`variant` with flanking region, or `region`)
`flanking_region` | `500` | Flanking region in kb
`gds_file` | `NA` | GDS file to use for calculating LD. Include a space to insert chromosome. 
`genome_build` | `hg38` | Genome build (`hg19` or `hg38`).
`ld_sample_include` | `NA` | RData file with vector of sample.id to include when calculating LD.
`track_file` | `NA` | File with aggregate or window association test results. Regions will be displayed in a track in the LocusZoom plot. Include a space to insert chromosome.
`track_file_type` | `window` | Type of association regions in `track_file` (`window` or `aggregate`).
`track_label` | `""` | Label to display to the right of the track in the plot.
`track_threshold` | `5e-8` | P-value threshold for selecting regions to display.



## Subset VCF by sample

`vcf_subset.py`
1. `vcf_subset.sh`
2. `check_gds.R`

config parameter | default value | description
--- | --- | ---
`out_prefix` | | Prefix for files created by this script.
`sample_file` | | Text file with samples to include (one per line).
`vcf_file` | | Name of the input VCF (or BCF) file. Include a space to insert chromosome number.
`out_file` | | Name of output VCF file (should end in ".vcf.gz"). Include a space to insert chromosome number.
`gds_file` | | Name of GDS file used to check genotypes. Include a space to insert chromosome number.
