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
REQUIRED_VARS=('KERNEL_REPO' 'KERNEL_BUILD_ARCH', 'CONFIG_TYPE')
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

# Check to see if merge completed properly
MERGE_OUTPUT_DIR=${OUTPUT_DIR}/merge
PATCH_RESULTS_CSV= ${MERGE_OUTPUT_DIR}/patch_results.csv
if [ ! -f "${PATCH_RESULTS_CSV}" ]; then
    echo "The patch_results.csv is missing from ${MERGE_OUTPUT_DIR}."
    echo "Have you run merge.sh?"
    exit 1
fi
if grep 'FAIL$' "${PATCH_RESULTS_CSV}"; then
    echo "At least one of the patches from the merge operation has failed."
    echo "Ensure that ${PATCH_RESULTS_CSV} has no lines with 'FAIL' before"
    echo "building the kernel."
    exit 1
fi

# Create the output directories if they do not exist
BUILD_OUTPUT_DIR=${OUTPUT_DIR}/build/${KERNEL_BUILD_ARCH}
mkdir -vp $BUILD_OUTPUT_DIR

# Ensure the repository is ready
setup_repository
merge_patchwork_patches

# Get the number of CPU cores available
CPU_COUNT=$(nproc)

# Set up a default set of make options.
DEFAULT_MAKE_OPTS="make -C ${KERNEL_DIR} O=${BUILD_OUTPUT_DIR}"
DEFAULT_BUILD_MAKE_OPTS="${DEFAULT_MAKE_OPTS} INSTALL_MOD_STRIP=1 -j${CPU_COUNT} ${MAKE_OPTS}"

# Prepare the kernel output file
get_kernel_config ${BUILD_OUTPUT_DIR}/.config
$DEFAULT_MAKE_OPTS olddefconfig

# Build the kernel
$DEFAULT_BUILD_MAKE_OPTS targz-pkg
