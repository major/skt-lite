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
REQUIRED_VARS=('KERNEL_REPO' 'KERNEL_BUILD_ARCH' 'CONFIG_TYPE')
missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    test -n "${!var:+y}" || missing_vars+=("${var}")
done
if [ ${#missing_vars[@]} -ne 0 ]; then
    echo "The following required variables are not set:" >&2
    printf ' %q\n' "${missing_vars[@]}" >&2
    exit 1
fi

# Check to see if merge completed properly
MERGE_OUTPUT_DIR=${OUTPUT_DIR}/merge
PATCH_RESULTS_CSV=${MERGE_OUTPUT_DIR}/patch_results.csv
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

# Set architecture environment variables
setup_architecture_variables

# Create the output directories if they do not exist
BUILD_OUTPUT_DIR=${OUTPUT_DIR}/build/${KERNEL_BUILD_ARCH}
KBUILD_OUTPUT_DIR=${BUILD_OUTPUT_DIR}/kbuild_output
mkdir -vp $BUILD_OUTPUT_DIR $KBUILD_OUTPUT_DIR

# Get the number of CPU cores available
CPU_COUNT=$(nproc)

# Set up a default set of make options.
DEFAULT_MAKE_OPTS="make -C ${KERNEL_DIR}"
DEFAULT_BUILD_MAKE_OPTS="${DEFAULT_MAKE_OPTS} O=${KBUILD_OUTPUT_DIR} INSTALL_MOD_STRIP=1 -j${CPU_COUNT} ${MAKE_OPTS}"

# Prepare the kernel output file
get_kernel_config ${KERNEL_DIR}/.config
$DEFAULT_MAKE_OPTS olddefconfig
${KERNEL_DIR}/scripts/config --file ${KERNEL_DIR}/.config --disable debug_info

# Log the release version number
$DEFAULT_MAKE_OPTS kernelrelease | tail -n 1 > ${BUILD_OUTPUT_DIR}/kernelrelease.txt

# Clean the output directory and put the config back in place
mv ${KERNEL_DIR}/.config config
$DEFAULT_MAKE_OPTS mrproper
mv config ${KBUILD_OUTPUT_DIR}/.config

# Build the kernel and find the tarball in the output
$DEFAULT_BUILD_MAKE_OPTS targz-pkg 2>&1 | tee -a ${BUILD_OUTPUT_DIR}/build.log
if grep "Tarball successfully created" ${BUILD_OUTPUT_DIR}/build.log; then
    GREP_PATTERN="Tarball successfully created in \.\/\K(linux.*)"
    KERNEL_TARBALL=$(grep -oP "$GREP_PATTERN" ${BUILD_OUTPUT_DIR}/build.log)
    echo $KERNEL_TARBALL > ${BUILD_OUTPUT_DIR}/kerneltarball.txt
fi

# Clean up
gzip ${BUILD_OUTPUT_DIR}/build.log
mv ${KBUILD_OUTPUT_DIR}/${KERNEL_TARBALL} ${BUILD_OUTPUT_DIR}
rm -rf ${KBUILD_OUTPUT_DIR}
