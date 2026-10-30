#!/bin/bash
# Print the tool versions of this image as "key: value" lines.
# Run inside either applet image; relies on the ENV paths set in its Dockerfile.
set -euo pipefail

# py_version FILE
#   Value of the module-level __version__ string in FILE.
py_version() { sed -n 's/^__version__ *= *"\(.*\)"/\1/p' "$1"; }

cat /opt/applet/BUILD_INFO
echo "AmpliconArchitect: $(py_version "$AA_SRC/AmpliconArchitect.py")"
echo "AmpliconClassifier: $(py_version "$AC_SRC/amplicon_classifier.py")"
if [[ -f "$PAA_SRC/paalib/_version.py" ]]; then
    echo "AmpliconSuite-pipeline: $(sed -n 's/.*= *"\(.*\)"/\1/p' "$PAA_SRC/paalib/_version.py")"
fi
echo "CNVkit (seeding): $("$CNVKIT_BIN/cnvkit.py" version)"
echo "AA Python: $("$AA_PYTHON" --version 2>&1)"
echo "AC Python: $("$AC_PYTHON" --version 2>&1)"
echo "Mosek: $("$AA_PYTHON" -c 'import mosek; print(".".join(str(v) for v in mosek.Env().getversion()))')"
