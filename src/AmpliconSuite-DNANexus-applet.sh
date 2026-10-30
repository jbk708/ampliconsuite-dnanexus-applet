#!/bin/bash
set -e -x -o pipefail
# AmpliconSuite-pipeline 0.1.0
# Runs CNVkit seeding, PrepareAA/AmpliconSuite-pipeline + AmpliconArchitect, and AmpliconClassifier on one
# tumor BAM (optionally with a matched normal). All tools come from the Docker image selected by aa_version:
#   original    PrepareAA @ 8284de8 (Apr 2020), AA 1.2, AC 1.1.2, CNVkit 0.9.6   (docker/Dockerfile.original)
#   reanalysis  AmpliconSuite-pipeline 1.3.3, AA 1.4.r2, AC 1.2.0, CNVkit 0.9.6  (docker/Dockerfile.reanalysis)
# Images are built by docker/build_images.sh and loaded from IMAGE_FOLDER in the job's project.
#
# CNV calls are always made here with CNVkit 0.9.6 and passed as --cnv_bed. PrepareAA @ 8284de8 has no
# --normal_bam option and its Docker runner only accepts --cnv_bed, so paired mode cannot be delegated to it.
# Tumor-only commands reproduce PrepareAA @ 8284de8 run_cnvkit() and convert_cnvkit_cnv_to_seeds(). In reanalysis
# the .cns is passed unfiltered, so AmpliconSuite-pipeline 1.3.3 applies its own seed filtering with --cngain.
#
# Your job's input variables (if any) will be loaded as environment variables before this script runs.
# See https://documentation.dnanexus.com/developer for tutorials on how to modify this file.

IMAGE_FOLDER=/ampliconsuite_images   # must match docker/build_images.sh
NTHREADS=8
CNSIZE_MIN=50000                     # PrepareAA default seed size filter (bp)

# Reference FASTA names in the AA data repo, as in PrepareAA @ 8284de8 (refFnames).
declare -A REF_FASTA=([hg19]=hg19full.fa [GRCh37]=human_g1k_v37.fasta [GRCh38]=hg38full.fa)

# load_image CONFIG
#   docker load ampliconsuite-applet:CONFIG from IMAGE_FOLDER in the job's project; sets IMAGE.
load_image() {
    local archive="ampliconsuite-applet_$1.tar.gz"
    dx download --no-progress -o "$HOME/$archive" "${DX_PROJECT_CONTEXT_ID}:${IMAGE_FOLDER}/${archive}"
    docker load -i "$HOME/$archive"
    rm "$HOME/$archive"
    IMAGE="ampliconsuite-applet:$1"
}

# in_container CMD
#   Run CMD with bash in IMAGE. Mounts: inputs at /home/input (read-only), the AA data repo at /home/data_repo,
#   the Mosek license dir at /home/mosek and WORK_DIR at /home/output (the working directory).
in_container() {
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -e AA_DATA_REPO=/home/data_repo -e MOSEKLM_LICENSE_FILE=/home/mosek \
        -v "$HOME/in":/home/input:ro -v "$AA_DATA_REPO":/home/data_repo -v "$MOSEK_DIR":/home/mosek \
        -v "$WORK_DIR":/home/output -w /home/output \
        "$IMAGE" bash -c "$1"
}

# run_cnvkit TUMOR NORMAL OUTDIR
#   CNVkit 0.9.6 batch + segment (container paths); writes OUTDIR/<tumor basename>.cns.
#   NORMAL empty: flat reference from PrepareAA @ 8284de8, same commands as its run_cnvkit().
#   NORMAL set: reference built from the matched normal on the noAlt contigs of the data repo FASTA.
run_cnvkit() {
    local tumor=$1 normal=$2 outdir=$3 base
    base=$(basename "$tumor" .bam)
    local cmd="set -e -x; export PATH=\$CNVKIT_BIN:\$PATH; mkdir -p $outdir; "
    if [[ -z "$normal" ]]; then
        cmd+="cnvkit.py batch -m wgs -y -r \$PAA_REFS/$ref/${ref}_cnvkit_filtered_ref.cnn -p $NTHREADS -d $outdir $tumor; "
    else
        cmd+="samtools faidx /home/data_repo/$ref/${REF_FASTA[$ref]} \$(cut -f1 \$PAA_REFS/$ref/${ref}_noAlt.fa.fai) > /home/output/tmp/ref_noAlt.fa; "
        cmd+="cnvkit.py batch $tumor --normal $normal -m wgs --fasta /home/output/tmp/ref_noAlt.fa -p $NTHREADS -d $outdir; "
    fi
    cmd+="cnvkit.py segment $outdir/$base.cnr -p $NTHREADS -o $outdir/$base.cns"
    in_container "$cmd"
}

# cns_to_seed_bed CNS CNGAIN OUT_BED
#   PrepareAA @ 8284de8 convert_cnvkit_cnv_to_seeds(): CN = 2^(log2 + 1), keep CN >= CNGAIN and length >= CNSIZE_MIN.
#   Writes "chr start end CNVkit CN"; AA's amplified_intervals.py reads CN from column 5. %.12g matches Python 2 str().
cns_to_seed_bed() {
    awk -v gain="$2" -v min_size="$CNSIZE_MIN" 'BEGIN { OFS = "\t" }
        NR > 1 { cn = 2 ^ ($5 + 1); if (cn >= gain && $3 - $2 >= min_size) print $1, $2, $3, "CNVkit", sprintf("%.12g", cn) }' \
        "$1" > "$3"
}

# run_amplicon_suite TUMOR CNV_BED
#   PrepareAA + AA, then AC, for the loaded configuration. Results go to /home/output/$SAMPLE.
#   CNV_BED: seed bed from cns_to_seed_bed (original) or the CNVkit .cns (reanalysis).
run_amplicon_suite() {
    local tumor=$1 bed=$2 out=/home/output/$SAMPLE
    if [[ "$aa_version" == original ]]; then
        # PrepareAA @ 8284de8 expects its reference files inside the data repo; add any that are missing.
        in_container "set -e -x; cp -n \$PAA_REFS/$ref/* /home/data_repo/$ref/; cd $out; \
            python2 \$PAA_SRC/PrepareAA.py -s $SAMPLE -t $NTHREADS --ref $ref --cngain $cngain \
                --sorted_bam $tumor --cnv_bed $bed -o $out --run_AA; \
            mkdir -p $out/${SAMPLE}_classification; cd $out/${SAMPLE}_classification; \
            \$AC_PYTHON \$AC_SRC/amplicon_classifier.py --ref $ref --AA_results $out/${SAMPLE}_AA_results -o $SAMPLE"
    else
        in_container "set -e -x; cd $out; \
            python3 \$PAA_SRC/AmpliconSuite-pipeline.py -s $SAMPLE -t $NTHREADS --ref $ref --cngain $cngain \
                --bam $tumor --cnv_bed $bed -o $out --run_AA --run_AC"
    fi
}

# write_tool_versions OUT_FILE SEED_PATH
#   Tool versions from the image plus the run parameters, for the methods section.
write_tool_versions() {
    {
        echo "aa_version: $aa_version"
        echo "image: $IMAGE $(docker image inspect --format '{{.Id}}' "$IMAGE")"
        in_container "bash /opt/applet/tool_versions.sh"
        echo "mode: $([[ -n "$normal_bam" ]] && echo "paired tumor/normal" || echo "tumor-only")"
        echo "CNV seed path: $2"
        echo "ref: $ref"
        echo "cngain: $cngain"
        echo "cnsize_min: $CNSIZE_MIN"
    } > "$1"
}

main() {
    # cwd is $HOME=/home/dnanexus/
    dx-download-all-inputs
    mv $index_path $(dirname ${bam_path})     # expects .bam.bai file in same directory as .bam
    if [[ -n "$normal_bam" || -n "$normal_index" ]]; then
        [[ -n "$normal_bam" && -n "$normal_index" ]] || { echo "normal_bam and normal_index must be given together" >&2; exit 1; }
        mv $normal_index_path $(dirname ${normal_bam_path})
    fi
    if [[ -z "${REF_FASTA[$ref]}" ]]; then
        echo "ref must be one of hg19, GRCh37, GRCh38: the PrepareAA @ 8284de8 CNVkit references (got '$ref')" >&2
        exit 1
    fi

    # Set required environment variables
    export AA_DATA_REPO=$HOME/in/data_repo
    MOSEK_DIR=$HOME/mosek
    mkdir -p $MOSEK_DIR && cp $mosek_lic_path $MOSEK_DIR/mosek.lic
    SAMPLE=$bam_prefix
    WORK_DIR=$HOME/work
    mkdir -p $WORK_DIR/$SAMPLE $WORK_DIR/tmp

    # Unpack data_repo
    cd $AA_DATA_REPO
    tar zxf $data_repo_name
    rm $data_repo_name
    touch ${AA_DATA_REPO}/coverage.stats
    chmod a+rw ${AA_DATA_REPO}/coverage.stats
    cd $HOME

    load_image "$aa_version"

    local tumor=/home/input/bam/$bam_name normal="" seed_path cnv_bed
    local cnvkit_dir=/home/output/$SAMPLE/cnvkit_output
    if [[ -n "$normal_bam" ]]; then
        normal=/home/input/normal_bam/$normal_bam_name
        seed_path="CNVkit 0.9.6 batch --normal <matched normal> (PrepareAA @ 8284de8 has no --normal_bam)"
    else
        seed_path="CNVkit 0.9.6 batch -y -r <PrepareAA @ 8284de8 flat reference> (as PrepareAA run_cnvkit)"
    fi
    run_cnvkit "$tumor" "$normal" "$cnvkit_dir"
    if [[ "$aa_version" == original ]]; then
        cns_to_seed_bed "$WORK_DIR/$SAMPLE/cnvkit_output/$SAMPLE.cns" "$cngain" "$WORK_DIR/$SAMPLE/cnvkit_output/${SAMPLE}_CNV_GAIN.bed"
        cnv_bed=$cnvkit_dir/${SAMPLE}_CNV_GAIN.bed
        seed_path+="; segments with CN >= $cngain and >= $CNSIZE_MIN bp -> PrepareAA --cnv_bed"
    else
        cnv_bed=$cnvkit_dir/$SAMPLE.cns
        seed_path+="; unfiltered .cns -> AmpliconSuite-pipeline --cnv_bed (its prefilter + --cngain)"
    fi
    run_amplicon_suite "$tumor" "$cnv_bed"

    ## Export outputs
    mkdir -p $HOME/out/results $HOME/out/tool_versions
    write_tool_versions "$HOME/out/tool_versions/${SAMPLE}_tool_versions.txt" "$seed_path"
    cp "$HOME/out/tool_versions/${SAMPLE}_tool_versions.txt" "$WORK_DIR/$SAMPLE/"
    tar -C $WORK_DIR -czf $HOME/out/results/${SAMPLE}_outputs.tar.gz $SAMPLE
    dx-upload-all-outputs
}
