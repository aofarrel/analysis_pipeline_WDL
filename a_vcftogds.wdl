version 1.0

# [1] vcf2gds -- converts a VCF file into a GDS file
task vcf2gds {
	input {
		File vcf
		String output_file_name = basename(sub(vcf, "\\.vcf.gz$", ".gds"))
		# runtime attributes
		Int disk
		Int memory
	}
	command {
		set -eux -o pipefail

		# Generate config used by the R script
		# Must be done in this task or else this task will fail to find the inputs
		# regardless of whether we save full path or use os.path.basename

		echo "Generating config file"
		python << CODE
		import os
		f = open("megastep_A.config", "a")
		f.write("outprefix test\nvcf_file ")
		f.write("~{vcf}")
		f.write("\ngds_file '~{output_file_name}'\n")
		f.write("merged_gds_file 'merged.gds'")
		f.close()
		exit()
		CODE

		# Call R script to actually do the conversion
		set -eux -o pipefail
		echo "Calling R script vcfToGds.R"
		Rscript /usr/local/analysis_pipeline/R/vcf2gds.R "megastep_A.config"
	}
	runtime {
		docker: "uwgac/topmed-master:2.8.1"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
	output {
		File out = output_file_name
	}
}

# [2] uniqueVars -- attempts to give unique variant IDS
task unique_variant_id {
	input {
		Array[File] gdss
		Array[String] chrs = [1, 2, 3]
		# runtime attr
		Int disk
		Int memory
	}
	command <<<
		set -eux -o pipefail

		echo "Copying inputs into the workdir"
		BASH_FILES=(~{sep=" " gdss})
		for BASH_FILE in ${BASH_FILES[@]};
		do
			cp ${BASH_FILE} .
		done

		# generate config used by the R script
		# must be done in this task or else this task will fail to find the inputs
		# regardless of whether we save full path or use os.path.basename
		echo "Generating config file"
		python << CODE
		import os
		py_gdsarray = ['~{sep="','" gdss}']
		py_chrarray = ['~{sep="','" chrs}']

		# diff backends feed in files differently so we need to sort due to later assumption
		py_gdsarray.sort()

		f = open("unique_variant_ids.config", "a") # yeah yeah yeah this should be with open() I know
		f.write("outprefix test")
		f.write("\nchromosomes ")
		f.write("'")
		for py_chr in py_chrarray:
			f.write(py_chr)
			f.write(" ")
		f.write("'")
		f.write("\nvcf_file this_is_a_bogus_name.vcf")
		f.write("\ngds_file ")
		py_listicle = []

		if (len(py_gdsarray)) == 23:
			# because we sorted the array, indexes 0 and 11 should be chr1 and chr2 respectively
			# this will hopefully prevent heckery involving 1 and 10
			for charA, charB in zip(os.path.basename(py_gdsarray[0]), os.path.basename(py_gdsarray[11])):
				if charA == charB:
					py_listicle.append(charA)
				else:
					py_listicle.append(" ")
		else:
			# debug situations -- probably less than 10 chrs
			for charA, charB in zip(os.path.basename(py_gdsarray[0]), os.path.basename(py_gdsarray[1])):
				if charA == charB:
					py_listicle.append(charA)
				else:
					py_listicle.append(" ")
		
		py_name = "".join(py_listicle)
		f.write("'")
		f.write(py_name)
		f.write("'")
		f.write("\nmerged_gds_file 'merged.gds'\n")
		f.close()
		exit()
		CODE
		echo "Calling uniqueVariantIDs.R"
		Rscript /usr/local/analysis_pipeline/R/unique_variant_ids.R unique_variant_ids.config
	>>>
	runtime {
		docker: "uwgac/topmed-master:2.8.1"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
	output {
		Array[File] out = glob("*.gds")
	}
}

# [3] checkGDS - check a GDS file against its supposed VCF input
task check_gds {
	input {
		File gds
		Array[File] vcfs
		# there is a small chance that the vcf2gds sub made more than
		# one replacement but we're gonna hope that's not the case
		String gzvcf = basename(sub(gds, "\\.gds$", ".vcf.gz"))
		# runtime attr
		Int disk
		Int memory
	}

	command <<<
		# triple carrot syntax is required for this command section
		set -eux -o pipefail
		echo "Searching for VCF and generating config file"
		# doing this in python is probably not ideal
		# in fact, this whole block is pretty cursed
		python << CODE
		import os
		py_vcfarray = ['~{sep="','" vcfs}']
		for py_file in py_vcfarray:
			py_base = os.path.basename(py_file)
			print("--")
			print(py_base)
			print("~{gzvcf}")
			print("--")
			if(py_base == "~{gzvcf}"):
				f = open("checkgds.config", "a")
				f.write("outprefix test")
				f.write("\nvcf_file ")
				f.write(py_file)
				f.write("\ngds_file ")
				f.write("'~{gds}'")
				f.write("\nmerged_gds_file 'merged.gds'\n")
				f.close()
				exit()
		print("Failed to find a matching VCF")
		exit(1)  # if we don't find a VCF, fail
		CODE

		echo "Calling check_gds.R"
		Rscript /usr/local/analysis_pipeline/R/check_gds.R checkgds.config --chromosome 1
	>>>

	runtime {
		docker: "uwgac/topmed-master:2.8.1"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
}

workflow a_vcftogds {
	input {
		Array[File] vcf_files
		Boolean check_gds = false

		# debug
		Array[File] bogus_gds_inputs

		# runtime attributes
		# [1] vcf2gds
		Int vcfgds_disk
		Int vcfgds_memory
		# [2] uniquevarids
		Int uniquevars_disk
		Int uniquevars_memory
		# [3] checkgds
		Int checkgds_disk
		Int checkgds_memory
	}

	scatter(vcf_file in vcf_files) {
		call vcf2gds {
			input:
				vcf = vcf_file,
				disk = vcfgds_disk,
				memory = vcfgds_memory
		}
	}
	
	call unique_variant_id {
		input:
			gdss = vcf2gds.out,
			disk = uniquevars_disk,
			memory = uniquevars_memory
	}
	
	#if check_gds
	#scatter(gds in unique_variant_id.out) {
		#call check_gds {
			#input:
				#gds = gds,
				#vcfs = vcf_files,
				#disk = checkgds_disk,
				#memory = checkgds_memory
		#}
	#}

	meta {
		author: "Ash O'Farrell"
		email: "aofarrel@ucsc.edu"
	}
}