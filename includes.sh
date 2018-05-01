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


# Ensure that the script will fail if any command returns a non-zero return
# code, or if a piped command returns a non-zero return code.
set -euxo pipefail

## Defaults
export KERNEL_DEPTH=${KERNEL_DEPTH:-'1'}
export KERNEL_REF=${KERNEL_REF:-"master"}
export OUTPUT_DIR=${OUTPUT_DIR:-"output"}
export KERNEL_DIR=${KERNEL_DIR:-"source"}

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
setup_repository() {
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
