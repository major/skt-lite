#!/bin/bash
# Copyright (c) 2017 Red Hat, Inc. All rights reserved. This copyrighted
# material is made available to anyone wishing to use, modify, copy, or
# redistribute it subject to the terms and conditions of the GNU General
# Public License v.2 or later.

# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

# Include common functions
BASEDIR="$(dirname "$0")"
. "${BASEDIR}/includes.sh"

## Check for unset variables that are required
REQUIRED_VARS=('KERNEL_REPO')
for var in "${REQUIRED_VARS[@]}"; do
    variables_ok='yes'
    if [ -n "${!var}" ]; then;
        echo "Required variable is not set: ${var}"
        variables_ok='no'
    fi
    if [ "${variables_ok}" == 'no']; then
        exit 1
    fi
done

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
