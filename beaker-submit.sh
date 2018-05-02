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
REQUIRED_VARS=('BUILD_SERVER_ROUTE_HOSTNAME')
missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    test -n "${!var:+y}" || missing_vars+=("${var}")
done
if [ ${#missing_vars[@]} -ne 0 ]; then
    echo "The following required variables are not set:" >&2
    printf ' %q\n' "${missing_vars[@]}" >&2
    exit 1
fi

BUILD_ARCHES=$(echo "${KERNEL_BUILD_ARCHES}" | tr ',' '\n')
for BUILD_ARCH in $BUILD_ARCHES; do

    # The source template has variable names that will be replaced with real
    # values based on data from the build.
    BEAKER_JOB_FILE_SOURCE=${BASEDIR}/beaker-templates/beakerjob-template.xml

    # The destination template will be modified and sent to Beaker.
    BEAKER_JOB_FILE=${OUTPUT_DIR}/build/${BUILD_ARCH}/beakerjob.xml

    # Copy the architecture specific beaker job XML file into the output
    # directory.
    if [ -f $BEAKER_JOB_FILE_SOURCE ]; then
        cp $BEAKER_JOB_FILE_SOURCE $BEAKER_JOB_FILE
    else
        echo "Unable to find ${BEAKER_JOB_FILE_SOURCE}."
        exit 1
    fi

    # Assemble the URL of the build webserver
    BUILD_WEBSERVER_URL_BASE="http://${BUILD_SERVER_ROUTE_HOSTNAME}/skt-lite-pipeline/${BUILD_NUMBER}"

    # Get the git SHA of the kernel after patches were applied.
    GITSHA_URL="${BUILD_WEBSERVER_URL_BASE}/merge/sha_after_patches.txt"
    GITSHA=$(curl -s "${GITSHA_URL}")

    # Get the kernel version that was built
    KVER_URL="${BUILD_WEBSERVER_URL_BASE}/build/${BUILD_ARCH}/kernelrelease.txt"
    KVER=$(curl -s "${KVER_URL}")

    # Get the URL to the tarball of the built kernel
    TARBALL_FILENAME_URL="${BUILD_WEBSERVER_URL_BASE}/build/${BUILD_ARCH}/kerneltarball.txt"
    TARBALL_FILENAME=$(curl -s "${TARBALL_FILENAME_URL}")
    KPKG_URL="${BUILD_WEBSERVER_URL_BASE}/build/${BUILD_ARCH}/${TARBALL_FILENAME}"

    # Replace variables in the template
    sed -i "s/##ARCH##/${BUILD_ARCH}/g" $BEAKER_JOB_FILE
    sed -i "s/##KVER##/${KVER}/g" $BEAKER_JOB_FILE
    sed -i "s/##GITSHA##/${GITSHA}/g" $BEAKER_JOB_FILE
    sed -i "s/##BUILD_NAME##/${BUILD_NAME}/g" $BEAKER_JOB_FILE
    # NOTE(mhayden): The URL has forward slashes in it. That will cause issues
    # with sed, so we use a different delimiter here.
    sed -i "s^##KPKG_URL##^${KPKG_URL}^g" $BEAKER_JOB_FILE
    sed -i "s/##KVER##/${KVER}/g" $BEAKER_JOB_FILE

    # Set up the beaker job-submit command
    BKR_CMD="bkr job-submit"

    # If a delgated job owner was provided, we should add that to the Beaker
    # command line.
    if [ ! -z "${BEAKER_JOB_OWNER}" ]; then
        BKR_CMD="${BKR_CMD} --job-owner=${BEAKER_JOB_OWNER}"
    fi

    # Submit the job to beaker
    $BKR_CMD $BEAKER_JOB_FILE 2>&1 | tee -a ${OUTPUT_DIR}/build/${BUILD_ARCH}/beaker.log

done
