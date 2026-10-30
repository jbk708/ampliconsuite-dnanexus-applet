<!-- dx-header -->
# AmpliconSuite (DNAnexus Platform App)

Applet to run PrepareAA, AmpliconArchitect, and AmpliconClassifier on the DNANexus platform.

This is the source code for an app that runs on the DNAnexus Platform.
For more information about how to run or modify it, see
https://documentation.dnanexus.com/.
<!-- /dx-header -->

## Requirements
- A DNAnexus account and a project you can write to (CONTRIBUTE access).
- `dxpy` (the `dx` command line tool): `pip install dxpy`.
- Docker, to build the two images once (any machine; on Apple silicon the build runs under amd64 emulation and is slow).
- An AA data repo for your reference, packed as a `.tar.gz` of the reference folder (e.g. `GRCh38.tar.gz` containing `GRCh38/`). See [Data repo](#data-repo).
- A Mosek license file (`mosek.lic`). Free academic licenses: https://www.mosek.com/products/academic-licenses/. See [Mosek license](#mosek-license).
- Coordinate-sorted, indexed WGS BAMs aligned to `hg19`, `GRCh37` or `GRCh38`.

## One-time setup
Do this once per DNAnexus project.

1. Log in and select the project:
   ```
   dx login
   dx select <project>
   ```
2. Build the Docker images and upload them to `/ampliconsuite_images/` in the project. Jobs load the images from this folder, so it must exist in every project you run in.
   ```
   docker/build_images.sh               # both images
   docker/build_images.sh original      # or only one: original | reanalysis
   ```
   Each build prints the tool versions it contains. A build fails if a pinned version does not match.
3. Upload the data repo and Mosek license (any folder):
   ```
   dx upload --path /refs/ GRCh38.tar.gz
   dx upload --path /refs/ mosek.lic
   ```
4. Build the applet from the repository root:
   ```
   dx build -f
   ```
   This creates the applet `ampliconsuite-dnanexus-applet` in the project root. `-f` replaces an existing applet of the same name.

## Inputs
| Input | Required | Description |
|---|---|---|
| `bam` | yes | Tumor WGS BAM (`*.bam`). Its file name without `.bam` becomes the sample name. |
| `index` | yes | Tumor BAM index (`*.bai`). |
| `normal_bam` | no | Matched-normal WGS BAM. If given, the job runs in paired mode. |
| `normal_index` | with `normal_bam` | Matched-normal BAM index. |
| `ref` | yes | `hg19`, `GRCh37` or `GRCh38`. Must match the BAMs and the data repo. |
| `data_repo` | yes | AA data repo `.tar.gz` for `ref`. |
| `mosek_lic` | yes | Mosek license file (`*.lic`). |
| `cngain` | no | Seed copy-number threshold. Default `4.5`. |
| `aa_version` | no | `original` (default) or `reanalysis`. See [Pinned versions](#pinned-versions). |

## Running
Files can be given by project path or by file ID (`file-xxxx`).

Tumor-only:
```
dx run ampliconsuite-dnanexus-applet \
    -ibam=/bams/S1.bam -iindex=/bams/S1.bam.bai \
    -iref=GRCh38 -idata_repo=/refs/GRCh38.tar.gz -imosek_lic=/refs/mosek.lic \
    --destination /results/S1 -y
```
Paired tumor/matched normal: add the normal BAM and its index.
```
dx run ampliconsuite-dnanexus-applet \
    -ibam=/bams/S1_tumor.bam -iindex=/bams/S1_tumor.bam.bai \
    -inormal_bam=/bams/S1_normal.bam -inormal_index=/bams/S1_normal.bam.bai \
    -iref=GRCh38 -idata_repo=/refs/GRCh38.tar.gz -imosek_lic=/refs/mosek.lic \
    --destination /results/S1 -y
```
Reanalysis configuration (only for the flagged samples): add `-iaa_version=reanalysis`, and use a separate `--destination` so the two runs' outputs are not mixed.

Without `-y`, `dx run` shows the inputs and asks for confirmation. Without any inputs, it prompts for each one.

### Many samples
Put one sample per line in a tab-separated file: tumor BAM, tumor index, and optionally normal BAM and normal index (paths or file IDs).
```
/bams/S1_tumor.bam	/bams/S1_tumor.bam.bai	/bams/S1_normal.bam	/bams/S1_normal.bam.bai
/bams/S2.bam	/bams/S2.bam.bai
```
Then launch one job per line:
```
while IFS=$'\t' read -r bam bai nbam nbai; do
    sample=$(basename "$bam" .bam)
    normal_args=()
    [[ -n "$nbam" ]] && normal_args=(-inormal_bam="$nbam" -inormal_index="$nbai")
    dx run ampliconsuite-dnanexus-applet -ibam="$bam" -iindex="$bai" "${normal_args[@]}" \
        -iref=GRCh38 -idata_repo=/refs/GRCh38.tar.gz -imosek_lic=/refs/mosek.lic \
        --destination "/results/$sample" --name "AmpliconSuite $sample" --brief -y < /dev/null
done < samples.tsv
```
`--brief` prints only the job ID.

### Monitoring
```
dx find jobs --name "AmpliconSuite*"     # status of recent jobs
dx watch <job-id>                        # follow a job's log
dx describe <job-id>                     # inputs, outputs, failure reason
```
Each job runs on `mem2_ssd1_x8` with a 3-day timeout. To use another instance type, pass `--instance-type <type>` to `dx run`.

## Outputs
Each job writes two files to its `--destination` folder:
- `<sample>_outputs.tar.gz` (`results`): everything for the sample.
- `<sample>_tool_versions.txt` (`tool_versions`): tool versions, commits, Docker image ID, tumor-only or paired mode, how the CNV seeds were made, `ref`, `cngain` and seed size threshold. Use it for the methods section. A copy is also in the tarball.

Download and unpack:
```
dx download -r /results/S1
tar xzf S1/S1_outputs.tar.gz
```
The tarball contains a `<sample>/` folder with:
- `cnvkit_output/`: CNVkit 0.9.6 `.cnr`/`.cns` files. In `original` mode it also has `<sample>_CNV_GAIN.bed`, the seeds passed to PrepareAA.
- `<sample>_AA_results/`: AmpliconArchitect graphs, cycles and plots.
- AmpliconClassifier results: `<sample>_classification/` in `original` mode; in `reanalysis` mode, wherever AmpliconSuite-pipeline 1.3.3 writes them.
- The PrepareAA / AmpliconSuite-pipeline logs and seed files.

## Pinned versions
The `aa_version` input selects one of two Docker images, built from `docker/`:

| | `original` (default; manuscript) | `reanalysis` (flagged samples only) |
|---|---|---|
| PrepareAA / AmpliconSuite-pipeline | PrepareAA `8284de8` (2020-04-23) | AmpliconSuite-pipeline 1.3.3 |
| AmpliconArchitect (AA) | 1.2, commit `d9aac51` (Python 2.7, Mosek 8.0.0.60) | 1.4.r2 (Python 3, Mosek 10.0.38) |
| AmpliconClassifier (AC) | v1.1.2 (Python 3, separate env) | 1.2.0 |
| CNVkit (seeding) | 0.9.6 | 0.9.6 |
| Seed CN threshold | `--cngain 4.5` | `--cngain 4.5` |

- AA has no `v1.2` tag upstream; `d9aac51` is the last commit whose `__version__` is `"1.2"`.
- `reanalysis` is `jluebeck/prepareaa:v1.3.3` pinned by digest (`sha256:568dac78…`); the build checks that it contains AA 1.4.r2, AC 1.2.0 and pipeline 1.3.3.
- Every job writes a `tool_versions` output (also inside the results tarball) with the tool versions, commits, image ID, CNV seeding path and run parameters.

### How CNV seeds are made
PrepareAA `8284de8` has no `--normal_bam` option, and its Docker runner only accepts a precomputed `--cnv_bed`. The applet therefore always runs CNVkit 0.9.6 itself and passes the result as `--cnv_bed`:
- Tumor-only: `cnvkit.py batch -m wgs -y -r <ref>_cnvkit_filtered_ref.cnn` then `cnvkit.py segment`, the same commands as PrepareAA `8284de8`.
- Paired: `cnvkit.py batch <tumor.bam> --normal <normal.bam> -m wgs --fasta <data repo FASTA, noAlt contigs>` then `cnvkit.py segment`.
- `original`: segments are converted as PrepareAA `8284de8` does (CN = 2^(log2+1); keep CN >= 4.5 and >= 50 kb; bed columns `chr start end CNVkit CN`), then PrepareAA runs AA's `amplified_intervals.py` with `--gain 4.5`.
- `reanalysis`: the unfiltered `.cns` is passed to AmpliconSuite-pipeline 1.3.3, which applies its own seed pre-filter and `--cngain 4.5`.

The flat CNVkit references and `noAlt` contig lists come from the PrepareAA `8284de8` checkout in the image. For `original`, PrepareAA's reference files are also copied into the data repo where missing, as PrepareAA requires.

## Data repo
`data_repo` is the AmpliconArchitect data repo for one reference, as a `.tar.gz` that unpacks to a single `<ref>/` folder (`hg19/`, `GRCh37/` or `GRCh38/`). The job unpacks it and adds a writable `coverage.stats` file.
- The reference FASTA must use the AA data repo name: `hg19full.fa`, `human_g1k_v37.fasta` or `hg38full.fa`. Paired mode builds the CNVkit reference from it.
- AmpliconClassifier and AmpliconSuite-pipeline 1.3.3 read `<ref>/file_list.txt`, which current AA data repo releases include.
- In `original` mode the job adds PrepareAA's own reference files (`<ref>_noAlt.fa.fai`, `dummy_ploidy.vcf` and others) where they are missing. Existing files are never overwritten.

Use the same data repo for both configurations, and test one sample in each mode before running a full batch.

## Mosek license
AmpliconArchitect needs a Mosek license file. The `original` image uses Mosek 8.0.0.60 and `reanalysis` uses Mosek 10.0.38. Check that your license covers the version you run; if it does not, AA cannot solve and produces no amplicons (see [Troubleshooting](#troubleshooting)). The file can have any name; the job copies it to `mosek.lic`.

## Troubleshooting
- **`dx download` of `/ampliconsuite_images/ampliconsuite-applet_<config>.tar.gz` fails:** the images are not in this project. Run `docker/build_images.sh` with this project selected, or copy the `/ampliconsuite_images/` folder from another project with `dx cp`.
- **`ref must be one of hg19, GRCh37, GRCh38`:** other names (e.g. `hg38`) are not supported, because the pinned CNVkit references only exist for these three.
- **`normal_bam and normal_index must be given together`:** give both or neither.
- **Job fails:** `dx watch <job-id>` shows the full log, with every command echoed. The job stops if CNVkit, PrepareAA/AmpliconSuite-pipeline or AC exits with an error.
- **Job succeeds but `<sample>_AA_results/` is empty or missing amplicons:** PrepareAA `8284de8` does not check AA's exit status, so an AA failure (for example a Mosek license error) does not fail the job. Check the AA log in `<sample>_AA_results/` and the job log. An empty seed bed (`cnvkit_output/<sample>_CNV_GAIN.bed`) means no segment reached `cngain`, and AA has nothing to run on.

## Contributors:
Owen Chapman, Shanqing Wang.
