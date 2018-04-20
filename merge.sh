#!/bin/bash -x
# Required environment variables:
#  KERNEL_REPO - URL or filesystem path to the kernel to clone
#  KERNEL_DIR - path to where the KERNEL_REPO should be cloned
#  KERNEL_DEPTH - depth of kernel repo to clone
#    * default is '1' for faster cloning
#    * set to '0' to get all git history (very slow)
#  KERNEL_REF - ref/tag/branch to checkout within the kernel source
#  OUTPUT_DIR - path to desired kernel output
#  PATCHWORK_URLS - space-delimited list of patchwork URLs to merge (in order)
#  LOCAL_PATCHES - space-delimited list of paths to local patches
#
# Note: Local patches will be applied after patchwork patches.

# Use a shallow clone depth of 1 unless the user specified a deeper clone.
KERNEL_DEPTH="${KERNEL_DEPTH:=1}"

# Clone the repository
if [ "$KERNEL_DEPTH" == '0' ]; then
    git clone $KERNEL_REPO $KERNEL_DIR --ref $KERNEL_REF
else
    git clone $KERNEL_REPO $KERNEL_DIR --depth $KERNEL_DEPTH --ref $KERNEL_REF
fi

# Set up a name/email configuration for git
pushd $KERNEL_DIR
    git init
    git remote add origin $KERNEL_REPO
    if [ "$KERNEL_DEPTH" == '0' ]; then
        git fetch origin $KERNEL_REF
    else
        git fetch origin --depth $KERNEL_DEPTH $KERNEL_REF
    fi
    git config --global user.name "SKT"
    git config --global user.email "noreply@redhat.com"
popd

MERGE_LOG=${OUTPUT_DIR}/merge.log
:>$MERGE_LOG

# Attempt to merge the patchwork patches into the repository
if [ ! -z "$PATCHWORK_URLS" ]; then
    # Create a temporary directory to hold our patchwork patches.
    TEMPDIR=$(mktemp -d)
    PATCH_COUNTER=0
    # Loop through the patches and download them.
    for PATCHWORK_URL in $PATCHWORK_URLS; do
        MBOX_URL=${PATCHWORK_URL%/}/mbox/
        PATCH_FILENAME=${TEMPDIR}/$(printf "%03d" ${PATCH_COUNTER}).patch
        curl -# -o $PATCH_FILENAME $MBOX_URL

        pushd $KERNEL_DIR
            echo "Applying $PATCHWORK_URL ..." | tee -a $MERGE_LOG
            git am $PATCH_FILENAME | tee -a $MERGE_LOG
        popd

        PATCH_COUNTER=$((PATCH_COUNTER+1))
    done
fi
