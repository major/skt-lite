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


# Required environment variables:
#  KERNEL_REPO - URL or filesystem path to the kernel to clone
#  CONFIG_TYPE - kernel configuration file type
#    * 'rh-configs': build Red Hat kernel configs and choose one based on arch
#    * 'url': download a config from a URL
#
# Optional environment variables:
#  KERNEL_DEPTH - depth of kernel repo to clone
#    * default is '1' for faster cloning
#    * set to '0' to get all git history (very slow)
#  KERNEL_REF - ref/tag/branch to checkout within the kernel source
#    * default is 'master'
#    * can be set to tag, branch name, or specific commit SHA
#  KERNEL_DIR - path to where the KERNEL_REPO should be cloned
#    * default is 'source' in current directory
#  OUTPUT_DIR - path to desired kernel output
#    * default is 'output' in current directory
#  PATCHWORK_URLS - space-delimited list of patchwork URLs to merge (in order)
#  CONFIG_URL - URL to kernel config file (if CONFIG_TYPE=='url')
#  MAKE_OPTS - Additional options and arguments to pass to make


# Ensure that the script will fail if any command returns a non-zero return
# code, or if a piped command returns a non-zero return code.
set -euxo pipefail

## Defaults
export KERNEL_DEPTH=${KERNEL_DEPTH:-'1'}
export KERNEL_DIR=${KERNEL_DIR:-"source"}
export KERNEL_REF=${KERNEL_REF:-"master"}
export MAKE_OPTS=${MAKE_OPTS:-""}
export OUTPUT_DIR=${OUTPUT_DIR:-"output"}

# Set a user.name and user.email to ensure that git works properly within
# containerized environments. OpenShift uses random UIDs and this causes git
# to ask for the current user's information, which fails.
git config --global user.name "SKT"
git config --global user.email "noreply@redhat.com"

# If the output directory is a relative path, prepend the current working
# directory to make it absolute.
if [[ ! "$OUTPUT_DIR" =~ ^[/~] ]]; then
    OUTPUT_DIR=$(pwd)/${OUTPUT_DIR}
fi

# Set up the git repository
setup_repository () {
    if [ -d "$KERNEL_DIR" ]; then
        rm -rf $KERNEL_DIR
    fi
    mkdir -p $KERNEL_DIR
    pushd $KERNEL_DIR
        git init
        # If the remote 'origin' already exists, just set the URL. Otherwise
        # create the remote.
        if git remote | grep origin; then
            git remote set-url origin $KERNEL_REPO
        else
            git remote add origin $KERNEL_REPO
        fi
        # Fetch the repository contents
        GIT_FETCH_CMD="git fetch -n origin +${KERNEL_REF}:refs/remotes/origin/${KERNEL_REF}"
        if [ "$KERNEL_DEPTH" == '0' ]; then
            $GIT_FETCH_CMD
        else
            $GIT_FETCH_CMD --depth $KERNEL_DEPTH $KERNEL_REF
        fi
        # Ensure we have checked out the correct kernel ref and the directory
        # is clean.
        git checkout -q --detach refs/remotes/origin/${KERNEL_REF}
        git reset --hard refs/remotes/origin/${KERNEL_REF}
    popd
}

# Attempt to merge the patchwork patches into the repository
merge_patchwork_patches () {
    OPTIONS=${1:-''}
    if [[ $OPTIONS =~ .*no_log.* ]]; then
        # Don't log anything
        MERGE_LOG=/dev/null
    fi
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
                if [ ! "${MERGE_LOG}" == '/dev/null' ]; then
                    echo "${PATCH_COUNTER_PADDED},${PATCHWORK_URL},${PATCH_RESULT}" >> ${MERGE_OUTPUT_DIR}/patch_results.csv
                fi
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
}

# Ensure that the cross compiler exists and is executable.
check_cross_compiler () {
    echo "Checking for correct cross compiler on the system..."
    if [ ! "$ARCH" == 'x86_64' ]; then
        if [ ! -x /usr/bin/${CROSS_COMPILE}gcc ]; then
            echo "ERROR: Compiler missing > ${CROSS_COMPILE}gcc"
            exit 1
        fi
    fi
}

# Configure all of the architecture variables.
setup_architecture_variables () {
    echo "Setting up architecture variables for ${KERNEL_BUILD_ARCH}..."
    case "$KERNEL_BUILD_ARCH" in
        aarch64)
            export ARCH=arm64
            export CROSS_COMPILE=aarch64-linux-gnu-
            ;;
        ppc64le)
            export ARCH=powerpc
            export CROSS_COMPILE=powerpc64le-linux-gnu-
            # CentOS uses the standard ppc64 compiler for big and little
            # endian.
            if [ ! -x /usr/bin/${CROSS_COMPILE}gcc ]; then
                export CROSS_COMPILE=$(echo $CROSS_COMPILE | sed 's/le//')
            fi
            ;;
        s390x)
            export ARCH=s390
            export CROSS_COMPILE=s390x-linux-gnu-
            ;;
        x86_64)
            # There is no need to export a CROSS_COMPILE with x86_64 since
            # that is the native architecture in the build environment.
            export ARCH=x86_64
            ;;
        *)
            echo "The provided architecture is not supported: $KERNEL_BUILD_ARCH"
            exit 1
    esac

    echo "Arch variables:"
    echo "  - ARCH=${ARCH}"
    if [ "${KERNEL_BUILD_ARCH}" == 'x86_64' ]; then
        echo "  - CROSS_COMPILE=(not set)"
    else
        echo "  - CROSS_COMPILE=${CROSS_COMPILE}"
    fi

    check_cross_compiler
}

# Build the standard set of Red Hat configs or download a config file from a
# URL.
get_kernel_config () {
    CONFIG_DEST=$1
    if [ "${CONFIG_TYPE}" == 'rh-configs' ]; then
        build_redhat_configs $CONFIG_DEST
    elif [ "${CONFIG_TYPE}" == 'url' ]; then
        curl -# -O $CONFIG_DEST $CONFIG_URL
    fi
}

# Generate the Red Hat configuration files and copy the config that matches
# the current architecture.
build_redhat_configs () {
    CONFIG_DEST=$1
    echo "Building Red Hat configs with 'make rh-configs'..."
    make -C $KERNEL_DIR rh-configs
    cp -v $KERNEL_DIR/configs/kernel-*-${KERNEL_BUILD_ARCH}.config $CONFIG_DEST
}
