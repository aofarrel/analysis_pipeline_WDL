version 1.0

task generateConfig {
	input {
		Array [File] vcfs
	}

	command {
		python << CODE
		import os
		f = open("megastep_A.config", "a")
		f.write("outprefix test\nvcf_file ")

		py_vcfarray = ['~{sep="','" vcfs}']
		for py_file in py_vcfarray:
			py_base = os.path.basename(py_file)
			f.write('"')
			f.write(py_file)
			f.write('",')
		f.close()
		# delete last extra comma
		theStorySoFar = open("megastep_A.config").read()
		os.remove("megastep_A.config")
		f = open("megastep_A.config", "a")
		f.write(theStorySoFar[:-1])

		# add last two lines
		f = open("megastep_A.config", "a")
		f.write("\ngds_file 'gdsfile_chr .gds'\n")
		f.write("merged_gds_file 'merged.gds'")
		f.close()
		exit()
		CODE

		#out_prefix test
		#vcf_file "testdata/1KG_phase3_subset_chr .vcf.gz"
		#gds_file "1KG_phase3_subset_chr .gds"
		#merged_gds_file "1KG_phase3_subset.gds"
	}
	runtime {
		docker: "uwgac/topmed-master:latest"
		#disks: "local-disk ${disk} SSD"
		#bootDiskSizeGb: 6
		#memory: "${memory} GB"
	}
	output {
		File config_megastep_A = "megastep_A.config"
	}
}

# [1] runGDS -- converts a VCF file into a GDS file
task runGds {
	input {
		File config
		File vcf
		String output_file_name = basename(sub(vcf, "\\.vcf.gz$", ".gds"))
		# runtime attributes
		Int disk
		Int memory
	}
	command {
		set -eux -o pipefail
		echo "Calling R script vcfToGds.R"
		Rscript /usr/local/analysis_pipeline/R/vcf2gds.R ~{config}
	}
	runtime {
		docker: "uwgac/topmed-master:latest"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
	output {
		File out = output_file_name
	}
}

# [2] uniqueVars -- attempts to give unique variant IDS
task runUniqueVars {
	input {
		Array[File] gds
		Int chr_kind = 0
		String output_file_name = "unique.gds"
		# runtime attr
		Int disk
		Int memory
	}
	command {
		set -eux -o pipefail
		echo "Doing nothing..."
		#echo "Calling uniqueVariantIDs.R"
		#R --vanilla --args "~{sep="," gds}" ~{chr_kind} < /usr/local/analysis_pipeline/R/unique_variant_ids.R
	}
	runtime {
		docker: "uwgac/topmed-master:latest"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
	output {
		Array[File] out = output_file_name
	}
}

# [3] checkGDS - check a GDS file against its supposed VCF input
task runCheckGds {
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
		echo "Searching for VCF"
		# doing this in python is probably not ideal
		# in fact, this whole block is pretty cursed
		python << CODE
		import os
		py_vcfarray = ['~{sep="','" vcfs}']
		for py_file in py_vcfarray:
			py_base = os.path.basename(py_file)
			if(py_base == "~{gzvcf}"):
				print("Yep!")
				f = open("correctvcf.txt", "a")
				f.write(py_file)
				f.close()
				exit()
		print("Failed to find a matching VCF")
		exit(1)  # if we don't find a VCF, fail
		CODE

		READFILENAME=$(head correctvcf.txt)
		#echo "Calling check_gds.R"
		#R --vanilla --args "~{gds}" ${READFILENAME} < /usr/local/analysis_pipeline/R/check_gds.R
		echo "Doing nothing else..."
	>>>

	runtime {
		docker: "uwgac/topmed-master:latest"
		disks: "local-disk ${disk} SSD"
		bootDiskSizeGb: 6
		memory: "${memory} GB"
	}
}

workflow a_vcftogds {
	input {
		Array[File] vcf_files

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

	call generateConfig {
		input:
			vcfs = vcf_files
	}

	# if reading from config file this ideally should not be 
	scatter(vcf_file in vcf_files) {
		call runGds {
			input:
				config = generateConfig.config_megastep_A,
				vcf = vcf_file,
				disk = vcfgds_disk,
				memory = vcfgds_memory
		}
	}
	
	call runUniqueVars {
		input:
			gds = runGds.out,
			disk = uniquevars_disk,
			memory = uniquevars_memory
	}
	
	scatter(gds in runUniqueVars.out) {
		call runCheckGds {
			input:
				gds = gds,
				vcfs = vcf_files,
				disk = checkgds_disk,
				memory = checkgds_memory
		}
	}

	meta {
		author: "Ash O'Farrell"
		email: "aofarrel@ucsc.edu"
	}
}