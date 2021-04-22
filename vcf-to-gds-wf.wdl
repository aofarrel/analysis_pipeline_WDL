version 1.0

# [1] vcf2gds -- converts a VCF file into a GDS file
task vcf2gds {
	input {
		File vcf
		String output_file_name = basename(sub(vcf, "\.vcf\.gz(?!.{1,})|\.vcf\.bgz(?!.{5,})|\.vcf(?!.{5,})|\.bcf(?!.{1,})", ".gds"))
		Array[String] format # vcf formats to keep
		# runtime attributes
		Int cpu
		Int disk
		Int memory
	}
	command {
		set -eux -o pipefail

		echo "Generating config file"
		python << CODE
		import os
		f = open("vcf2gds.config", "a")
		f.write("vcf_file ~{vcf}\n")
		f.write("format ")
		for py_formattokeep in ['~{sep="','" format}']:
			f.write(py_formattokeep)
		f.write("\ngds_file '~{output_file_name}'\n")
		f.close()
		exit()
		CODE

		echo "Calling R script vcfToGds.R"
		Rscript /usr/local/analysis_pipeline/R/vcf2gds.R vcf2gds.config
	}
	runtime {
		cpu: cpu
		docker: "uwgac/topmed-master:2.10.0"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
	output {
		File gds_output = output_file_name
		File config_file = "vcf2gds.config"
	}
}

# [2] uniqueVars -- attempts to give unique variant IDS
task unique_variant_id {
	input {
		Array[File] gdss
		# runtime attr
		Int cpu
		Int disk
		Int memory
	}
	command <<<
		set -eux -o pipefail

		# This is a workaround for the Python code to work correctly
		# Symlinks would be preferable, but they do not work on GCS
		echo "Copying inputs into the workdir"
		BASH_FILES=(~{sep=" " gdss})
		for BASH_FILE in ${BASH_FILES[@]};
		do
			cp ${BASH_FILE} .
		done

		echo "Generating config file"
		python << CODE
		import os

		def find_chromosome(file):
			chr_array = []
			chrom_num = split_on_chromosome(file)
			if(unicode(str(chrom_num[1][1])).isnumeric()):
				# two digit number
				chr_array.append(chrom_num[1][0])
				chr_array.append(chrom_num[1][1])
			else:
				# one digit number or Y/X/M
				chr_array.append(chrom_num[1][0])
			return "".join(chr_array)

		def split_on_chromosome(file):
			# if input is "amishchr1.gds"
			# output is ["amish", ".gds", "chr"]
			chrom_num = file
			if "chr" in chrom_num:
				chrom_num = chrom_num.split("chr")
				chrom_num.append("chr")
			else:
				return "error-invalid-inputs"
			return chrom_num

		def write_config(chr_array, precisely_one_gds_split):
			f = open("unique_variant_ids.config", "a")
			f.write("chromosomes ")
			f.write("'")
			for chr in chr_array:
				f.write(chr)
				f.write(" ")
			f.write("'")
			f.write("\ngds_file ")
			f.write("'")
			f.write(precisely_one_gds_split[0])  # first part
			f.write(precisely_one_gds_split[2])  # string "chr"
			f.write(" ")  # space where R script inserts chr number
			if(unicode(str(precisely_one_gds_split[1][1])).isnumeric()):
				# two digit number
				f.write(precisely_one_gds_split[1][2:])
			else:
				# one digit number or Y/X/M
				f.write(precisely_one_gds_split[1][1:])
			f.write("'")
			f.close()

		gds_array_fullpath = ['~{sep="','" gdss}']
		gds_array_basenames = []
		for fullpath in gds_array_fullpath:
			gds_array_basenames.append(os.path.basename(fullpath))

		# make list of all chromosomes found in input files
		chr_array = []
		for gds_file in gds_array_basenames:
			this_chr = find_chromosome(gds_file)
			if this_chr == "error-invalid-inputs":
				print("Unable to determine chromosome number from inputs.")
				print("Please ensure your files contain ''chr'' followed by")
				print("the number of letter of the chromosome (chr1, chr2, etc)")
				exit(1)
			else:
				chr_array.append(this_chr)
		
		# assuming all gds files have same pattern in filename, any one will do
		one_valid_gds_split = split_on_chromosome(gds_array_basenames[0])
		write_config(chr_array, one_valid_gds_split)
		CODE
		
		echo "Calling uniqueVariantIDs.R"
		Rscript /usr/local/analysis_pipeline/R/unique_variant_ids.R unique_variant_ids.config
	>>>
	runtime {
		cpu: cpu
		docker: "uwgac/topmed-master:2.10.0"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
	output {
		Array[File] unique_variant_id_gds_per_chr = glob("*.gds")
	}
}

# [3] checkGDS - check a GDS file against its supposed VCF input
task check_gds {
	input {
		File gds
		Array[File] vcfs
		File? sample
		String gzvcf = basename(sub(gds, "\\.gds$", ".vcf.gz"))
		String bgzvcf =  basename(sub(gds, "\\.gds$", ".vcf.bgz"))
		String uncompressed = basename(sub(gds, "\\.gds$", ".vcf"))
		String bcf = basename(sub(gds, "\\.gds$", ".bcf"))
		# runtime attr
		Int cpu
		Int disk
		Int memory
	}

	command <<<
		# triple carrot syntax is required for this command section
		set -eux -o pipefail



		echo "Searching for VCF and generating config file"
		python << CODE
		import os

		def split_components_add_space(py_splitstring):
			if(unicode(str(py_splitstring[1][1])).isnumeric()):
				# chr10 and above
				py_thisVcfWithSpace = "".join([
					py_splitstring[0],
					"chr ",
					py_splitstring[1][2:]])
				py_thisChr = py_splitstring[1][0:2]
			else:
				# chr9 and below + chrX
				py_thisVcfWithSpace = "".join([
					py_splitstring[0],
					"chr ",
					py_splitstring[1][1:]])
				py_thisChr = py_splitstring[1][0:1]
			return [py_thisVcfWithSpace, py_thisChr]

		def write_config(py_vcf, py_gds):
			f = open("check_gds.config", "a")

			# write VCF file
			f.write("vcf_file ")
			py_thisVcfSplitOnChr = py_vcf.split("chr")
			f.write("'")
			f.write(split_components_add_space(py_thisVcfSplitOnChr)[0])
			f.write("'")

			# write GDS file
			f.write("\ngds_file ")
			py_thisGdsSplitOnChr = py_gds.split("chr")
			f.write("'")
			f.write(split_components_add_space(py_thisGdsSplitOnChr)[0])
			f.write("'")

			# write the sample file
			if(~{sample}):
				f.write("sample_file ")
				f.write("'")
				f.write("~{sample}")
				f.write("'")

			# grab chr number and close file
			py_thisChr = split_components_add_space(py_thisGdsSplitOnChr)[1]
			f.close()

			# write chromosome number to new file, to be read in bash
			g = open("chr_number", "a")
			g.write(str(py_thisChr)) # already str if chrX but python won't complain
			exit()

		py_vcfarray = ['~{sep="','" vcfs}']
		py_gds = "~{gds}"
		# recall that this is a scattered task and we pass in one gds and the entire vcf array
		# therefore we have to iterate to discover which vcf matches the gds file input
		for py_vcf in py_vcfarray:
			py_base = os.path.basename(py_vcf)
			if(py_base == "~{gzvcf}" or py_base == "~{bgzvcf}" or py_base == "~{uncompressed}" or py_base == "~{bcf}"):
				write_config(py_vcf, py_gds)

		# only executes if we reach end of the array without a filename match
		print("Failed to find an associated VCF for GDS file: ~{gds}")
		exit(1)
		CODE

		echo "Setting chromosome number"
		BASH_CHR=$(<chr_number)
		echo "Chromosme number is ${BASH_CHR}"

		echo "Calling check_gds.R"
		Rscript /usr/local/analysis_pipeline/R/check_gds.R check_gds.config --chromosome ${BASH_CHR}
	>>>

	runtime {
		cpu: cpu
		docker: "uwgac/topmed-master:2.10.0"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
}

workflow a_vcftogds {
	input {
		Array[File] vcf_files
		Array[String] format = ["GT"]
		Boolean check_gds = false
		File? sample_file

		# runtime attributes
		# [1] vcf2gds
		Int vcfgds_cpu = 1
		Int vcfgds_disk
		Int vcfgds_memory = 4
		# [2] uniquevarids
		Int uniquevars_cpu = 1
		Int uniquevars_disk
		Int uniquevars_memory = 4
		# [3] checkgds
		Int checkgds_cpu = 1
		Int checkgds_disk
		Int checkgds_memory = 4
	}

	scatter(vcf_file in vcf_files) {
		call vcf2gds {
			input:
				vcf = vcf_file,
				format = format,
				cpu = vcfgds_cpu,
				disk = vcfgds_disk,
				memory = vcfgds_memory
		}
	}
	
	call unique_variant_id {
		input:
			gdss = vcf2gds.gds_output,
			cpu = uniquevars_cpu,
			disk = uniquevars_disk,
			memory = uniquevars_memory
	}
	
	if(check_gds) {
		scatter(gds in unique_variant_id.unique_variant_id_gds_per_chr) {
			call check_gds {
				input:
					gds = gds,
					vcfs = vcf_files,
					sample = sample_file,
					cpu = checkgds_cpu,
					disk = checkgds_disk,
					memory = checkgds_memory
			}
		}
	}

	meta {
		author: "Ash O'Farrell"
		email: "aofarrel@ucsc.edu"
	}
}
