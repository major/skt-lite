#!/usr/bin/env python
"""Enqueue kernel CI jobs based on patchwork patches."""

# Make Python 2 code more Python 3 friendly
from __future__ import (
    absolute_import,
    division,
    print_function,
    unicode_literals
)

import argparse
import logging
import os
import re
import yaml

import requests

import six.moves.configparser as configparser

# Get the absolute path to the directory holding this script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

logging.basicConfig(level=logging.INFO)


def read_config_file(config_file):
    """Read a patchwork-ci.ini file and return a configparser object."""
    global cfg
    cfg = configparser.ConfigParser()
    cfg.read(config_file)
    return cfg


def read_state_file(state_file):
    """Read the state file."""
    logging.info("Reading state file: {}".format(state_file))
    if os.path.isfile(state_file):
        with open(state_file, 'r') as fileh:
            return yaml.load(fileh.read())
    else:
        return {}


def write_state_file(state_file, new_state):
    """Write the state file."""
    logging.info("Writing state file: {}".format(state_file))
    with open(state_file, 'w') as fileh:
        fileh.write(
            yaml.dump(new_state, default_flow_style=False)
        )


def handle_arguments():
    """Take arguments from the command line."""
    parser = argparse.ArgumentParser(description='Enqueue Kernel CI Jobs')
    parser.add_argument(
        '--config-file',
        type=str,
        help='config file (required)',
        required='True',
    )
    parser.add_argument(
        '--state-file',
        type=str,
        help='path to a file to hold state information (required)',
        required='True',
    )
    args = parser.parse_args()
    return args


def get_repos():
    """Get repository configurations from config file."""
    logging.info("Reading configuration file")
    repo_configs = (
        x for x in cfg._sections.items() if x[0].startswith('repo:')
    )
    return repo_configs


def get_patch_series(patchwork_url, patchwork_project, last_series_seen=0):
    """Retrieve a list of patch series from Patchwork server for a project."""
    page = 1
    series_list = []
    while True:
        payload = {
            "project": patchwork_project,
            "order": "-id",  # read newest patches first
            "page": page,  # page number to retrieve
        }
        url = "{}/api/series".format(patchwork_url.rstrip('/'))
        logging.info(
            "Getting page {} of patch series for {}".format(
                page,
                patchwork_project
            )
        )
        r = requests.get(url, params=payload)
        for series in r.json():
            # Skip any patch series that is incomplete
            if not series['received_all']:
                continue

            # If we reached the patch that we saw on the last run, stop and
            # return our current list.
            if int(series['id']) <= int(last_series_seen):
                logging.info(
                    "Reached last seen series: {}".format(last_series_seen)
                )
                return series_list

            # Add this series to our list
            logging.info("Adding {} to series list...".format(series['id']))
            series_list.append(series)

        # Increment the page counter to get another page
        page += 1

        # If the last series seen is 0, we only gather the first page since
        # this is a brand new repo.
        if int(last_series_seen) == 0:
            break

    return series_list


def get_patchwork_urls(patch_list):
    """
    Take a list of patches, sort them, and return patchwork urls.

    Patchwork gathers patches into series but it does not put those patches
    in order. This function sorts the patches based on the #/# counts provided
    in the patch subject line and returns the Patchwork URLs to each patch.
    """
    def get_patch_number(patch):
        # NOTE: The non-greedy modifier (?) after the first dotall in the
        # regex is critical. That ensures that we match all of the numbers
        # before the slash in the patch name.
        pattern = r"\[.*?(\d+)/\d+.*?\]"
        result = re.search(pattern, patch['name'])
        if result:
            return int(result.group(1))
        else:
            False

    if len(patch_list) > 1:
        urls = [
            x['mbox'].rstrip('/mbox/') for x in
            sorted(patch_list, key=get_patch_number)
        ]
    else:
        urls = [x['mbox'].rstrip('/mbox/') for x in patch_list]

    return urls


def get_mbox(mbox_url):
    """Retrieve an mbox file and parse it."""
    r = requests.get(mbox_url)
    return r.content


def send_to_jenkins(job_params, build_cause=None):
    """Send a job to Jenkins to build."""
    jenkins_url = "{}/job/{}/buildWithParameters".format(
        cfg.get('config', 'jenkins_url').rstrip('/'),
        cfg.get('config', 'jenkins_pipeline')
    )
    job_params['BEAKER_JOB_OWNER'] = cfg.get('config', 'beaker_job_owner')

    get_params = {
        'token': cfg.get('config', 'jenkins_pipeline_token'),
        'description': 'test'
    }
    if build_cause is not None:
        get_params['cause'] = build_cause

    logging.info(
        "Sending job to Jenkins: {}".format(job_params['DISPLAY_NAME'])
    )
    r = requests.post(
        jenkins_url,
        params=get_params,
        data=job_params,
        verify=False
    )
    return r.content


# Set up our script
args = handle_arguments()
cfg = read_config_file(args.config_file)
repos = get_repos()
state = read_state_file(args.state_file)

for repo_name, repo_data in repos:
    logging.info("Starting work for {}".format(repo_name))
    # If this is the first time we have seen this repo, ensure it exists
    # in the state file.
    if repo_name not in state.keys():
        state[repo_name] = {}

    # Get the id of the last series seen when this script last ran
    if 'last_series_seen' not in state[repo_name].keys():
        last_series_seen = 0
    else:
        last_series_seen = state[repo_name]['last_series_seen']

    # Get the list of series for this repo from Patchwork
    logging.info(
        "Retrieving new patch series list for {} (last seen: {})".format(
            repo_data['patchwork_project'],
            last_series_seen
        )
    )
    series_list = get_patch_series(
        patchwork_url=repo_data['patchwork_url'],
        patchwork_project=repo_data['patchwork_project'],
        last_series_seen=last_series_seen,
    )

    if series_list:
        # Save the last seen series in the list to the state file
        last_seen = max(series_list, key=lambda k: k['id'])
        state[repo_name]['last_series_seen'] = last_seen['id']
        write_state_file(args.state_file, state)

    for series in series_list:
        # Get a sorted list of patchwork URLs
        patchwork_urls = get_patchwork_urls(series['patches'])
        # Set a nice displayname for the job
        display_name = "{} | {} | {}".format(
            cfg.get(repo_name, 'patchwork_project'),
            series['id'],
            series['name']
        )
        # Assemble the parameters to pass to Jenkins
        jenkins_job_params = {
            'KERNEL_REPO': cfg.get(repo_name, 'repo_url'),
            'KERNEL_REF': cfg.get(repo_name, 'repo_branch'),
            'PATCHWORK_URLS': ' '.join(patchwork_urls),
            'CONFIG_TYPE': cfg.get(repo_name, 'config_type'),
            'KERNEL_BUILD_ARCHES': cfg.get(repo_name, 'build_arches'),
            'BUILDER_OS': cfg.get(repo_name, 'builder_os'),
            'DISPLAY_NAME': display_name
        }
        # Get the config_url option if the config_type is 'url'
        if cfg.get(repo_name, 'config_type') == 'url':
            jenkins_job_params['CONFIG_URL'] = cfg.get(
                repo_name,
                'config_url'
            )
        # Send the job to Jenkins to run
        jenkins_reply = send_to_jenkins(
            job_params=jenkins_job_params,
            build_cause=series['url'],
        )
