#!/bin/bash
# Build the applet images and upload them to the current DNAnexus project, where the applet loads them from.
#
# Usage: docker/build_images.sh [original|reanalysis ...]   (default: both)
# Requires docker and a logged-in dx CLI (`dx login`, `dx select <project>`).
set -euo pipefail

IMAGE_FOLDER=/ampliconsuite_images   # must match IMAGE_FOLDER in src/AmpliconSuite-DNANexus-applet.sh
cd "$(dirname "$0")"

# build_and_upload CONFIG
#   Build ampliconsuite-applet:CONFIG for linux/amd64, docker save it and dx upload it to IMAGE_FOLDER.
build_and_upload() {
    local tag="ampliconsuite-applet:$1" archive="ampliconsuite-applet_$1.tar.gz"
    docker build --platform linux/amd64 -f "Dockerfile.$1" -t "$tag" .
    docker run --rm --platform linux/amd64 "$tag" bash /opt/applet/tool_versions.sh
    docker save "$tag" | gzip > "$archive"
    dx upload --parents --path "$IMAGE_FOLDER/$archive" "$archive"
    rm "$archive"
}

configs=("$@")
[[ ${#configs[@]} -gt 0 ]] || configs=(original reanalysis)
for config in "${configs[@]}"; do
    build_and_upload "$config"
done
