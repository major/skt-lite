#!/bin/bash
# Required environment variables:
#  KERNEL_REPO - URL or filesystem path to the kernel to clone
#  KERNEL_DIR - path to where the KERNEL_REPO should be cloned
#  KERNEL_DEPTH - depth of kernel repo to clone
#    * default is '1' for faster cloning
#    * set to '0' to get all git history (very slow)
#  KERNEL_REF - ref/tag/branch to checkout within the kernel source
#  OUTPUT_DIR - path to desired kernel output
#  PATCHWORK_URLS - space-delimited list of patchwork URLs to merge (in order)

# Include common functions
BASEDIR="$(dirname "$0")"
. "${BASEDIR}/includes.sh"

# Set up the git repository
setup_repository

# Create the output directories if they do not exist
MERGE_OUTPUT_DIR=${OUTPUT_DIR}/merge
mkdir -vp $MERGE_OUTPUT_DIR

# Create a log file
MERGE_LOG=${OUTPUT_DIR}/merge/merge.log
touch $MERGE_LOG

# Attempt to merge the patchwork patches into the repository
if [ ! -z "$PATCHWORK_URLS" ]; then
    # Create a temporary directory to hold our patchwork patches.
    PATCH_COUNTER=0
    # Loop through the patches and download them.
    for PATCHWORK_URL in $PATCHWORK_URLS; do
        MBOX_URL=${PATCHWORK_URL%/}/mbox/
        PATCH_COUNTER_PADDED=$(printf "%03d" ${PATCH_COUNTER})
        PATCH_FILENAME=${MERGE_OUTPUT_DIR}/${PATCH_COUNTER_PADDED}.patch

        # Download the patch
        echo "Downloading $MBOX_URL to $PATCH_FILENAME..." | tee -a $MERGE_LOG
        curl -# -o $PATCH_FILENAME $MBOX_URL | tee -a $MERGE_LOG

        # Apply the patch
        pushd $KERNEL_DIR
            echo "Applying $PATCHWORK_URL ..." | tee -a $MERGE_LOG
            if git am $PATCH_FILENAME 2>&1 | tee -a $MERGE_LOG; then
                PATCH_RESULT='PASS'
            else
                PATCH_RESULT='FAIL'
            fi

            # Record the result in a CSV file
            echo "${PATCH_COUNTER_PADDED},${PATCHWORK_URL},${PATCH_RESULT}" >> ${MERGE_OUTPUT_DIR}/patch_results.csv
        popd

        # If this patch failed, then we need to exit and not try any more
        # patches.
        if [ "${PATCH_RESULT}" == 'FAIL' ]; then
            echo "The last patch failed to apply."
            exit 1
        fi

        # Increment the patch counter for the next patch
        PATCH_COUNTER=$((PATCH_COUNTER+1))
    done
fi
