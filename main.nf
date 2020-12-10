#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/metapep
========================================================================================
 nf-core/metapep Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/metapep
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/metapep --input '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Path to input file. Txt file containing taxon IDs or FASTA file containing proteins.
      --input_assembly [file]         Alternative input. FASTA file containing nucleotide sequences.
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --genome [str]                  Name of iGenomes reference
      --single_end [bool]             Specifies that the input is single-end reads
      --prodigal_mode [str]           Prodigal mode, 'meta' or 'single'. Default: 'meta'.
      --ncbi_key [str]                NCBI key for faster download from Entrez databases.
      --ncbi_email [str]              Email address for NCBI Entrez database access. Required if downloading proteins from NCBI.
      --min_pep_len [int]             Min. peptide length to generate.
      --max_pep_len [int]             Max. peptide length to generate.

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move (Default: copy)
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the channel below in a process, define the following:
//   input:
//   file fasta from ch_fasta
//
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if (params.fasta) { ch_fasta = file(params.fasta, checkIfExists: true) }

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_output_docs = file("$projectDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$projectDir/docs/images/", checkIfExists: true)

/*
 * Create a channel for input files
 */

if (params.input && hasExtension(params.input, "txt") ) {
    Channel
        .fromPath(params.input, checkIfExists: true)
        .ifEmpty { exit 1, "Cannot find any file matching: ${params.input}" }
        .set { ch_taxon_ids }
} else if (params.input  && (hasExtension(params.input, "fasta") || hasExtension(params.input, "fa") || hasExtension(params.input, "faa"))) {
    Channel
        .fromPath(params.input, checkIfExists: true)
        .ifEmpty { exit 1, "Cannot find any file matching: ${params.input}" }
        .set { ch_proteins }
    ch_taxon_ids = Channel.empty()
} else if (params.input_assembly ) {
    Channel
        .fromPath(params.input_assembly, checkIfExists: true)
        .ifEmpty { exit 1, "Cannot find any file matching: ${params.input_assembly}" }
        .set { ch_assembly }
    ch_taxon_ids = Channel.empty()
} else {
    exit 1, "Missing input. Please specify --input or --input_assembly."
}

ch_contig_depths = Channel.empty()
if (params.contig_depths) {
    Channel
        .fromPath(params.contig_depths, checkIfExists: true)
        .ifEmpty { exit 1, "Cannot find any file matching: ${params.contig_depths}" }
        .set { ch_contig_depths }
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Input']            = params.input
summary['Input Assembly']   = params.input_assembly
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-metapep-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/metapep Workflow Summary'
    section_href: 'https://github.com/nf-core/metapep'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}


/*
 * Download proteins from entrez
 */
if (hasExtension(params.input, "txt")) {
    process download_proteins {
        publishDir "${params.outdir}/entrez_data", mode: params.publish_dir_mode,
            saveAs: {filename -> "$filename" }

        input:
        file taxon_ids from ch_taxon_ids

        output:
        file "proteins.fasta" into ch_proteins
        file "taxa_assembly.tsv"
        file "proteinid_assemblyids.txt"

        script:
        def key = params.ncbi_key
        def email = params.ncbi_email
        """
        # provide new home dir to avoid permission errors with Docker and other artefacts
        export HOME="\${PWD}/HOME"
        download_proteins_entrez.py --email $email --key $key --taxid_input $taxon_ids
        """
    }
}

/*
 * Predict proteins from contigs
 */
if (params.input_assembly) {
    process predict_proteins {
        publishDir "${params.outdir}/prodigal", mode: params.publish_dir_mode,
            saveAs: {filename -> "$filename" }

        input:
        file assembly from ch_assembly

        output:
        file "proteins.fasta" into ch_proteins
        file "coords.gff"

        script:
        def mode = params.prodigal_mode
        """
        gzip -c -d $assembly | prodigal \
                 -f gff \
                 -o coords.gff \
                 -a proteins.fasta \
                 -p $mode
        """
    }

    (ch_proteins, ch_proteins_get_abundances) = ch_proteins.into(2)

    // only based on taxonomic abundances, not on protein expression!
    // rename, "weight"?
    process assign_protein_abundances {
        publishDir "${params.outdir}/prodigal", mode: params.publish_dir_mode,
            saveAs: {filename -> "$filename" }

        input:
        file contig_depths from ch_contig_depths
        file proteins from ch_proteins_get_abundances

        output:
        file "protein_abundances.tsv"   // place somewhere else ?

        script:
        """
        get_abundance.py --proteins $proteins --depths $contig_depths --output "protein_abundances.tsv"
        """
    }
}

/*
 * Generate peptides
 */
// TODO think about output format
process generate_peptides {
    publishDir "${params.outdir}/peptides", mode: params.publish_dir_mode,
        saveAs: {filename -> "$filename" }

    input:
    file proteins from ch_proteins

    output:
    file "peptides.tsv.gz" into ch_peptides
    file "protein_lengths.tsv"

    script:
    def min_pep_len = params.min_pep_len
    def max_pep_len = params.max_pep_len
    """
    generate_peptides.py --proteins $proteins \
                         --min_len $min_pep_len \
                         --max_len $max_pep_len \
                         --peptides "peptides.tsv.gz" \
                         --prot_lengths "protein_lengths.tsv"
    """
}


/*
 * Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    file output_docs from ch_output_docs
    file images from ch_output_docs_images

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/metapep] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/metapep] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    def mqc_report = null

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$projectDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$projectDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, projectDir: "$projectDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$projectDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/metapep] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            mail_cmd.execute() << email_html
            log.info "[nf-core/metapep] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/metapep]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/metapep]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/metapep v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

// Check file extension
def hasExtension(it, extension) {
    it.toString().toLowerCase().endsWith(extension.toLowerCase())
}
