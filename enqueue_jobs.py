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
import json
import logging
import mailbox
import os
import yaml

import requests

import six.moves.configparser as configparser

# Get the absolute path to the directory holding this script
SCRIPT_DIR=os.path.dirname(os.path.abspath(__file__))

logging.basicConfig(level=logging.INFO)


def read_config_file(config_file):
    """Read a patchwork-ci.ini file and return a configparser object"""
    global cfg
    cfg = configparser.ConfigParser()
    cfg.read(config_file)
    return cfg


def read_state_file(state_file):
    """Read the state file"""
    if os.path.isfile(state_file):
        with open(state_file, 'r') as fileh:
            return yaml.load(fileh.read())
    else:
        return {}


def write_state_file(state_file, new_state):
    """Write the state file"""
    with open(state_file, 'w') as fileh:
        fileh.write(
            yaml.dump(new_state, default_flow_style=False)
        )


def handle_arguments():
    """Takes arguments from the command line"""
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
    """Get repository configurations from config file"""
    logging.info("Reading configuration file")
    repo_configs = (
        x for x in cfg._sections.items() if x[0].startswith('repo:')
    )
    return repo_configs


def get_patch_series(patchwork_url, patchwork_project, last_series_seen=0):
    """Retrieve a list of patch series from Patchwork server for a project"""
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


def get_mbox(mbox_url):
    """Retrieve an mbox file and parse it"""
    r = requests.get(mbox_url)
    return r.content


def send_to_jenkins(job_params, build_cause=None):
    """Sends a job to Jenkins to build"""
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
        patchwork_urls = [
            x['mbox'].rstrip('/mbox/') for x in series['patches']
        ]
        display_name = "{} | {} | {}".format(
            cfg.get(repo_name, 'patchwork_project'),
            series['id'],
            series['name']
        )
        jenkins_job_params = {
            'KERNEL_REPO': cfg.get(repo_name, 'repo_url'),
            'KERNEL_REF': cfg.get(repo_name, 'repo_branch'),
            'PATCHWORK_URLS': ' '.join(patchwork_urls),
            'CONFIG_TYPE': cfg.get(repo_name, 'config_type'),
            'CONFIG_URL': cfg.get(repo_name, 'config_url'),
            'KERNEL_BUILD_ARCHES': cfg.get(repo_name, 'build_arches'),
            'BUILDER_OS': cfg.get(repo_name, 'builder_os'),
            'DISPLAY_NAME': display_name
        }
        jenkins_reply = send_to_jenkins(
            job_params=jenkins_job_params,
            build_cause=series['url'],
        )
