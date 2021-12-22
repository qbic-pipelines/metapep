/*
 * Create database tables for input
 */
process create_db_tables {
    publishDir "${params.outdir}/db_tables", mode: params.publish_dir_mode,
        saveAs: {filename -> "$filename" }
    input:
    file input_file from Channel.value(file(params.input))

    output:
    file "microbiomes.tsv" into ch_microbiomes                    // microbiome_id, microbiome_path, microbiome_type, weights_path
    file "conditions.tsv" into ch_conditions                      // condition_id, condition_name, microbiome_id
    file "alleles.tsv"  into ch_alleles                           // allele_id, allele_name
    file "conditions_alleles.tsv" into ch_conditions_alleles      // condition_id, allele_id

    script:
    """
    create_db_tables.py -i ${input_file} \
                        -m microbiomes.tsv \
                        -c conditions.tsv \
                        -a alleles.tsv \
                        -ca conditions_alleles.tsv
    """
}

// ####################################################################################################

ch_microbiomes
    // Read microbiomes table
    .splitCsv(sep:'\t', header:true)
    // Convert paths to files
    .map {
        row ->
        row.microbiome_path = file(row.microbiome_path, checkIfExists: true)
        row
    }
    // Split into types
    .branch {
        row->
        taxa:      row.microbiome_type == 'taxa'
        proteins : row.microbiome_type == 'proteins'
        assembly:  row.microbiome_type == 'assembly'
        bins:      row.microbiome_type == 'bins'
    }
    .set{ch_microbiomes_branch}

// TAXA
ch_microbiomes_branch.taxa
    .multiMap { row ->
            ids: row.microbiome_id
            files: row.microbiome_path
        }
    .set { ch_taxa_input }

// PROTEINS
ch_microbiomes_branch.proteins
    .multiMap { row ->
            ids: row.microbiome_id
            files: row.microbiome_path
        }
    .set { ch_proteins_input }

// ASSEMBLY
ch_microbiomes_branch.assembly
    .multiMap { row ->
            ids: row.microbiome_id
            files: row.microbiome_path
            bin_basenames: false
        }
    .set { ch_assembly_input }

// BINS
ch_microbiomes_branch.bins
    .branch {
            row ->
            folders : row.microbiome_path.isDirectory()
            archives : row.microbiome_path.isFile()
            other: true
        }
    .set{ ch_microbiomes_bins }

// The file ending we expect for FASTA files
fasta_suffix = ~/(?i)[.]fa(sta)?(.gz)?$/

// BINS - LOCAL FOLDERS
ch_microbiomes_bins.folders
    .multiMap { row ->
        def bin_files = row.microbiome_path.listFiles().findAll{ it.name =~ fasta_suffix }
        ids           : Collections.nCopies((int) bin_files.size(), row.microbiome_id)
        files         : bin_files
        bin_basenames : bin_files.collect{ it.name - fasta_suffix }
    }.set { ch_bins_folders_input }

// BINS - LOCAL OR REMOTE ARCHIVES
ch_microbiomes_bins.archives
    .multiMap { row ->
        ids : row.microbiome_id
        files: row.microbiome_path
    }
    .set{ ch_microbiomes_bins_archives_packed }

/*
 * Unpack archived assembly bins
 */
process unpack_bin_archives {
    input:
    val microbiome_id from ch_microbiomes_bins_archives_packed.ids
    path microbiome_path from ch_microbiomes_bins_archives_packed.files

    output:
    tuple val(microbiome_id), file('unpacked/*') into ch_microbiomes_bins_archives_unpacked

    script:
    """
    mkdir -v unpacked
    tar -C unpacked -vxf "$microbiome_path"
    """
}

ch_bins_archives_input = Channel.empty()
ch_microbiomes_bins_archives_unpacked
    .multiMap { microbiome_id, bin_files ->
        bin_files = bin_files.findAll{ it.name =~ fasta_suffix }
        if (bin_files.isEmpty()) log.warn("WARNING - Archive provided for microbiome ID ${microbiome_id} did not yield any bin files")
        ids           : Collections.nCopies((int) bin_files.size(), microbiome_id)
        files         : bin_files
        bin_basenames : bin_files.collect{ it.name - fasta_suffix }
    }.set{ ch_bins_archives_input }

// Concatenate the channels for nucleotide based inputs
ch_nucl_input_ids           = ch_assembly_input.ids.concat(ch_bins_archives_input.ids.flatten(), ch_bins_folders_input.ids.flatten())
ch_nucl_input_files         = ch_assembly_input.files.concat(ch_bins_archives_input.files.flatten(), ch_bins_folders_input.files.flatten())
ch_nucl_input_bin_basenames = ch_assembly_input.bin_basenames.concat(ch_bins_archives_input.bin_basenames.flatten(), ch_bins_folders_input.bin_basenames.flatten())


// ####################################################################################################

ch_weights = Channel.empty()
ch_microbiomes
    .splitCsv(sep:'\t', skip: 1)
    .map { microbiome_id, microbiome_path, microbiome_type, weights_path ->
            if (microbiome_type != 'taxa' && weights_path) [microbiome_id, weights_path]
        }
    .multiMap { microbiome_id, weights_path ->
            microbiome_ids: microbiome_id
            weights_paths: weights_path
        }.set { ch_weights }

/*
 * Download proteins from entrez
 */
process download_proteins {
    publishDir "${params.outdir}", mode: params.publish_dir_mode,
        saveAs: {filename ->
                    if (filename.indexOf(".fasta.gz") == -1) "entrez_data/$filename"
                    else null
        }

    input:
    val    microbiome_ids     from   ch_taxa_input.ids.collect()
    file   microbiome_files   from   ch_taxa_input.files.collect()

    output:
    file   "proteins.entrez.tsv.gz"            into   ch_entrez_proteins
    file   "taxa_assemblies.tsv"               into   ch_entrez_assemblies
    file   "entities_proteins.entrez.tsv"      into   ch_entrez_entities_proteins  // protein_tmp_id (accessionVersion), entity_name (taxon_id)
    file   "microbiomes_entities.entrez.tsv"   into   ch_entrez_microbiomes_entities  // entity_name, microbiome_id, entity_weight

    script:
    def key = params.ncbi_key
    def email = params.ncbi_email
    def microbiome_ids = microbiome_ids.join(' ')
    """
    # provide new home dir to avoid permission errors with Docker and other artefacts
    export HOME="\${PWD}/HOME"
    download_proteins_entrez.py --email $email \
                                --key $key \
                                -t $microbiome_files \
                                -m $microbiome_ids \
                                -p proteins.entrez.tsv.gz \
                                -ta taxa_assemblies.tsv \
                                -ep entities_proteins.entrez.tsv \
                                -me microbiomes_entities.entrez.tsv
    """
}

/*
 * Predict proteins from contigs
 */
process predict_proteins {
    publishDir "${params.outdir}/prodigal", mode: params.publish_dir_mode,
        saveAs: {filename ->
                    if (filename.indexOf(".fasta") == -1) "$filename"
                    else null
        }

    input:
    val microbiome_id from ch_nucl_input_ids
    val bin_basename from ch_nucl_input_bin_basenames
    file microbiome_file from ch_nucl_input_files

    output:
    val microbiome_id into ch_pred_proteins_microbiome_ids                  // Emit microbiome ID
    val bin_basename into ch_pred_proteins_bin_basename
    file("proteins.pred_${microbiome_id}*.tsv.gz") into ch_pred_proteins     // Emit protein tsv
    file "coords.pred_${microbiome_id}*.gff"

    script:
    def mode   = params.prodigal_mode
    def name   = bin_basename ? "${microbiome_id}.${bin_basename}" : "${microbiome_id}"
    def reader = microbiome_file.name =~ ~/(?i)[.]gz$/ ? "gunzip -c" : "cat"
    """
    $reader $microbiome_file | prodigal \
                -f gff \
                -o coords.pred_${name}.gff \
                -a proteins.pred_${name}.fasta \
                -p $mode

    echo -e "protein_tmp_id\tprotein_sequence" > proteins.pred_${name}.tsv
    fasta_to_tsv.py --remove-asterisk --input proteins.pred_${name}.fasta >> proteins.pred_${name}.tsv
    gzip proteins.pred_${name}.tsv
    """
}

/*
 * Assign entity weights for input type 'assembly' and 'bins'
 */
process assign_nucl_entity_weights {
    publishDir "${params.outdir}/db_tables", mode: params.publish_dir_mode,
        saveAs: {filename -> "$filename" }

    input:
    val  microbiome_ids     from  ch_weights.microbiome_ids.collect().ifEmpty([])
    path weights_files      from  ch_weights.weights_paths.collect().ifEmpty([])

    output:
    path   "microbiomes_entities.nucl.tsv"    into   ch_nucl_microbiomes_entities  // entity_name, microbiome_id, entity_weight

    script:
    microbiome_ids = microbiome_ids.join(' ')
    """
    assign_entity_weights.py \
        --microbiome-ids $microbiome_ids \
        --weights-files $weights_files \
        --out microbiomes_entities.nucl.tsv
    """
}

/*
 * concat files and assign new, unique ids for all proteins (from different sources)
 */
process generate_protein_and_entity_ids {
    publishDir "${params.outdir}/db_tables", mode: params.publish_dir_mode,
        saveAs: {filename -> "$filename" }

    input:
    // Predicted Proteins
    path   predicted_proteins                  from       ch_pred_proteins.collect().ifEmpty([])
    val    predicted_proteins_microbiome_ids   from       ch_pred_proteins_microbiome_ids.collect().ifEmpty([])
    val    predicted_proteins_bin_basenames    from       ch_pred_proteins_bin_basename.collect().ifEmpty([])
    // Entrez Proteins
    path   entrez_proteins                     from       ch_entrez_proteins.ifEmpty([])
    path   entrez_entities_proteins            from       ch_entrez_entities_proteins.ifEmpty([])       //   protein_tmp_id (accessionVersion), entity_name (taxon_id)
    path   entrez_microbiomes_entities         from       ch_entrez_microbiomes_entities.ifEmpty([])    //   entity_name, microbiome_id, entity_weight
    // Bare Proteins
    path   bare_proteins                       from       ch_proteins_input.files.collect().ifEmpty([])
    path   bare_proteins_microbiome_ids        from       ch_proteins_input.ids.collect().ifEmpty([])

    output:
    path   "proteins.tsv.gz"                        into   ch_proteins
    path   "entities_proteins.tsv"                  into   ch_entities_proteins
    path   "entities.tsv"                           into   ch_entities
    path   "microbiomes_entities.no_weights.tsv"    into   ch_microbiomes_entities_noweights  // microbiome_id, entitiy_id  (no weights yet!)

    script:
    predicted_proteins_microbiome_ids = predicted_proteins_microbiome_ids.join(' ')
    predicted_proteins_bin_basenames  = predicted_proteins_bin_basenames.collect{ it ? it : "__ISASSEMBLY__" }.join(' ')
    """
    generate_protein_and_entity_ids.py \
        --predicted-proteins                  $predicted_proteins                  \
        --predicted-proteins-microbiome-ids   $predicted_proteins_microbiome_ids   \
        --predicted-proteins-bin-basenames    $predicted_proteins_bin_basenames    \
        --entrez-proteins                     "$entrez_proteins"                   \
        --entrez-entities-proteins            "$entrez_entities_proteins"          \
        --entrez-microbiomes-entities         "$entrez_microbiomes_entities"       \
        --bare-proteins                       $bare_proteins                       \
        --bare-proteins-microbiome-ids        $bare_proteins_microbiome_ids        \
        --out-proteins                        proteins.tsv.gz                      \
        --out-entities-proteins               entities_proteins.tsv                \
        --out-entities                        entities.tsv                         \
        --out-microbiomes-entities            microbiomes_entities.no_weights.tsv
    """
}

/*
 * Create microbiome_entities
 */
process finalize_microbiome_entities {
    publishDir "${params.outdir}/db_tables", mode: params.publish_dir_mode,
        saveAs: {filename -> "$filename" }

    input:
    path   entrez_microbiomes_entities        from       ch_entrez_microbiomes_entities.ifEmpty([])
    path   nucl_microbiomes_entities          from       ch_nucl_microbiomes_entities.ifEmpty([])
    path   microbiomes_entities_noweights     from       ch_microbiomes_entities_noweights
    path   entities                           from       ch_entities

    output:
    path   "microbiomes_entities.tsv"    into   ch_microbiomes_entities  // entity_id, microbiome_id, entity_weight

    script:

    """
    finalize_microbiome_entities.py \
        -eme $entrez_microbiomes_entities \
        -nme $nucl_microbiomes_entities \
        -menw $microbiomes_entities_noweights \
        -ent "$entities" \
        -o microbiomes_entities.tsv
    """
}

/*
 * Generate peptides
 */
process generate_peptides {
    publishDir "${params.outdir}", mode: params.publish_dir_mode,
        saveAs: {filename -> "db_tables/$filename" }

    input:
    file proteins from ch_proteins

    output:
    file "peptides.tsv.gz" into ch_peptides                // peptide_id, peptide_sequence
    file "proteins_peptides.tsv" into ch_proteins_peptides // protein_id, peptide_id, count
    //file "proteins_lengths.tsv"

    script:
    def min_pep_len = params.min_pep_len
    def max_pep_len = params.max_pep_len
    """
    generate_peptides.py -i $proteins \
                         -min $min_pep_len \
                         -max $max_pep_len \
                         -p "peptides.tsv.gz" \
                         -pp "proteins_peptides.tsv" \
                         -l "proteins_lengths.tsv"
    """
}

/*
 * Collect some numbers: proteins, peptides, unique peptides per conditon
 */
process collect_stats {
    publishDir "${params.outdir}", mode: params.publish_dir_mode,
        saveAs: {filename -> "db_tables/$filename" }

    input:
    path  peptides              from  ch_peptides
    path  proteins_peptides     from  ch_proteins_peptides
    path  entities_proteins     from  ch_entities_proteins
    path  microbiomes_entities  from  ch_microbiomes_entities
    path  conditions            from  ch_conditions

    output:
    file "stats.txt" into ch_stats

    script:
    """
    collect_stats.py --peptides "$peptides" \
                     --protein-peptide-occ "$proteins_peptides" \
                     --entities-proteins-occ "$entities_proteins" \
                     --microbiomes-entities-occ "$microbiomes_entities" \
                     --conditions "$conditions" \
                     --outfile stats.txt
    """
}

/*
 * Split prediction tasks (peptide, allele) into chunks of peptides that are to
 * be predicted against the same allele for parallel prediction
 */
process split_pred_tasks {
    input:
    path  peptides              from  ch_peptides
    path  proteins_peptides     from  ch_proteins_peptides
    path  entities_proteins     from  ch_entities_proteins
    path  microbiomes_entities  from  ch_microbiomes_entities
    path  conditions            from  ch_conditions
    path  conditions_alleles    from  ch_conditions_alleles
    path  alleles               from  ch_alleles
    // The tables are joined to map peptide -> protein -> microbiome -> condition -> allele
    // and thus to enumerate, which (peptide, allele) combinations have to be predicted.

    output:
    path "peptides_*.txt" into ch_epitope_prediction_chunks

    script:
    def pred_chunk_size       = params.pred_chunk_size
    def subsampling = params.sample_n ? "--sample_n ${params.sample_n}" : ""
    """
    gen_prediction_chunks.py --peptides "$peptides" \
                             --protein-peptide-occ "$proteins_peptides" \
                             --entities-proteins-occ "$entities_proteins" \
                             --microbiomes-entities-occ "$microbiomes_entities" \
                             --conditions "$conditions" \
                             --condition-allele-map "$conditions_alleles" \
                             --max-chunk-size $pred_chunk_size \
                             $subsampling \
                             --alleles "$alleles" \
                             --outdir .
    """
}

/*
 * Perform epitope prediction
 */
process predict_epitopes {
    input:
    path peptides from ch_epitope_prediction_chunks.flatten()

    output:
    path "*predictions.tsv" into ch_epitope_predictions
    path "*prediction_warnings.log" into ch_epitope_prediction_warnings

    script:
    def pred_method           = params.pred_method
    """

    # Extract allele name from file header
    allele_name="\$(head -n1 "$peptides" | fgrep '#' | cut -f2 -d'#')"
    allele_id="\$(head -n1 "$peptides" | fgrep '#' | cut -f3 -d'#')"

    out_basename="\$(basename "$peptides" .txt)"
    out_predictions="\$out_basename"_predictions.tsv
    out_warnings="\$out_basename"_prediction_warnings.log

    # Create output header
    echo "peptide_id	prediction_score	allele_id" >"\$out_predictions"

    # Process file
    # The --syfpeithi-norm flag enables score normalization when syfpeithi is
    # used and is ignored otherwise
    if ! epytope_predict.py --peptides "$peptides" \
                       --method "$pred_method" \
                       --method_version "$pred_method_version" \
		       --syfpeithi-norm \
                       "\$allele_name" \
                       2>stderr.log \
                       | tail -n +2 \
                       | cut -f 1,3 \
                       | sed -e "s/\$/	\$allele_id/" \
                       >>"\$out_basename"_predictions.tsv; then
        cat stderr.log >&2
        exit 1
    fi

    # Filter stderr for warnings and pass them on in the warnings channel
    fgrep WARNING stderr.log  | sort -u >"\$out_warnings" || :
    """
}

/*
 * Merge prediction results from peptide chunks into one prediction result
 */
 // gather chunks of predictions and merge them already to avoid too many input files for `merge_predictions` process
 // (causing "sbatch: error: Batch job submission failed: Pathname of a file, directory or other parameter too long")
 // sort and buffer to ensure resume will work (inefficient, since this causes waiting for all predictions)
ch_epitope_predictions_buffered = ch_epitope_predictions.toSortedList().flatten().buffer(size: 1000, remainder: true)
ch_epitope_prediction_warnings_buffered = ch_epitope_prediction_warnings.toSortedList().flatten().buffer(size: 1000, remainder: true)

process merge_predictions_buffer {

    input:
    path predictions from ch_epitope_predictions_buffered
    path prediction_warnings from ch_epitope_prediction_warnings_buffered

    output:
    path "predictions.buffer_*.tsv" into ch_predictions_merged_buffer
    path "prediction_warnings.buffer_*.log" into ch_prediction_warnings_merged_buffer

    script:
    def single = predictions instanceof Path ? 1 : predictions.size()
    def merge = (single == 1) ? 'cat' : 'csvtk concat -t'
    """
    [[ ${predictions[0]} =~  peptides_(.*)_predictions.tsv ]];
    uname="\${BASH_REMATCH[1]}"
    echo \$uname

    $merge $predictions > predictions.buffer_\$uname.tsv
    sort -u $prediction_warnings > prediction_warnings.buffer_\$uname.log
    """
}

process merge_predictions {
    publishDir "${params.outdir}", mode: params.publish_dir_mode,
        saveAs: {filename -> filename.endsWith(".log") ? "logs/$filename" : "db_tables/$filename"}

    input:
    path predictions from ch_predictions_merged_buffer.collect()
    path prediction_warnings from ch_prediction_warnings_merged_buffer.collect()

    output:
    path "predictions.tsv.gz" into ch_predictions
    path "prediction_warnings.log"

    script:
    def single = predictions instanceof Path ? 1 : predictions.size()
    def merge = (single == 1) ? 'cat' : 'csvtk concat -t'
    """
    $merge $predictions | gzip > predictions.tsv.gz
    sort -u $prediction_warnings > prediction_warnings.log
    """
}

/*
 * Generate figures
 */
process prepare_score_distribution {
    publishDir "${params.outdir}/figures/prediction_scores", mode: params.publish_dir_mode

    input:
    file predictions from ch_predictions
    file proteins_peptides from ch_proteins_peptides
    file entities_proteins from ch_entities_proteins
    file microbiomes_entities from ch_microbiomes_entities
    file conditions from  ch_conditions
    file conditions_alleles from  ch_conditions_alleles
    file alleles from ch_alleles

    output:
    file "prediction_scores.allele_*.tsv" into ch_prep_prediction_scores

    script:
    """
    prepare_score_distribution.py --predictions "$predictions" \
                            --protein-peptide-occ "$proteins_peptides" \
                            --entities-proteins-occ "$entities_proteins" \
                            --microbiomes-entities-occ "$microbiomes_entities" \
                            --conditions "$conditions" \
                            --condition-allele-map "$conditions_alleles" \
                            --alleles "$alleles" \
                            --outdir .
    """
}

process plot_score_distribution {
    publishDir "${params.outdir}/figures", mode: params.publish_dir_mode

    input:
    file prep_scores from ch_prep_prediction_scores.flatten()
    file alleles from ch_alleles
    file conditions from ch_conditions

    output:
    file "prediction_score_distribution.*.pdf"

    script:
    """
    [[ ${prep_scores} =~ prediction_scores.allele_(.*).tsv ]];
    allele_id="\${BASH_REMATCH[1]}"
    echo \$allele_id

    plot_score_distribution.R --scores $prep_scores \
                                   --alleles $alleles \
                                   --conditions $conditions \
                                   --allele_id \$allele_id \
                                   --method ${params.pred_method}
    """

}

process prepare_entity_binding_ratios {
    publishDir "${params.outdir}/figures/entity_binding_ratios", mode: params.publish_dir_mode

    input:
    file predictions from ch_predictions
    file proteins_peptides from ch_proteins_peptides
    file entities_proteins from ch_entities_proteins
    file microbiomes_entities from ch_microbiomes_entities
    file conditions from  ch_conditions
    file conditions_alleles from  ch_conditions_alleles
    file alleles from ch_alleles

    output:
    file "entity_binding_ratios.allele_*.tsv" into ch_prep_entity_binding_ratios

    script:
    """
    prepare_entity_binding_ratios.py --predictions "$predictions" \
                            --protein-peptide-occ "$proteins_peptides" \
                            --entities-proteins-occ "$entities_proteins" \
                            --microbiomes-entities-occ "$microbiomes_entities" \
                            --conditions "$conditions" \
                            --condition-allele-map "$conditions_alleles" \
                            --alleles "$alleles" \
                            --method ${params.pred_method} \
                            --outdir .
    """
}

process plot_entity_binding_ratios {
    publishDir "${params.outdir}/figures", mode: params.publish_dir_mode

    input:
    file prep_entity_binding_ratios from ch_prep_entity_binding_ratios.flatten()
    file alleles from ch_alleles

    output:
    file "entity_binding_ratios.*.pdf"

    script:
    """
    [[ ${prep_entity_binding_ratios} =~ entity_binding_ratios.allele_(.*).tsv ]];
    allele_id="\${BASH_REMATCH[1]}"
    echo \$allele_id

    plot_entity_binding_ratios.R --binding-rates $prep_entity_binding_ratios \
                                   --alleles $alleles \
                                   --allele_id \$allele_id
    """
}