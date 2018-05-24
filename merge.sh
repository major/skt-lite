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
missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    test -n ${!var:+y} || missing_vars+=("${var}")
done
if [ ${#missing_vars[@]} -ne 0 ]; then
    echo "The following required variables are not set:" >&2
    printf ' %q\n' "${missing_vars[@]}" >&2
    exit 1
fi

# Set up the git repository
setup_repository

# Create the output directories if they do not exist
MERGE_OUTPUT_DIR=${OUTPUT_DIR}/merge
mkdir -vp $MERGE_OUTPUT_DIR

# Create a log file
if [ "${LOGGING_ENABLED}" == 'yes' ]; then
    MERGE_LOG=${OUTPUT_DIR}/merge/merge.log
    touch $MERGE_LOG
else
    MERGE_LOG=/dev/null
fi

# Log the hash of the last commit before any patches are applied
if [ "${LOGGING_ENABLED}" == 'yes' ]; then
    pushd $KERNEL_DIR
        git rev-parse HEAD > ${MERGE_OUTPUT_DIR}/sha_before_patches.txt
    popd
fi

# Attempt to merge the patchwork patches into the repository
merge_patchwork_patches

# Log the hash of the last commit including the current set of patches
if [ "${LOGGING_ENABLED}" == 'yes' ]; then
    pushd $KERNEL_DIR
        git rev-parse HEAD > ${MERGE_OUTPUT_DIR}/sha_after_patches.txt
    popd
fi

# Store the kernel in the output directory to use with the build
pushd $KERNEL_DIR
    git archive HEAD --format tgz --output ${OUTPUT_DIR}/patched_kernel_source.tgz
popd
