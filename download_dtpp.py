#!/usr/bin/python3
# -*- coding: utf-8 -*-

"""
Download the full set of archives of DTPP edition, either current or next
"""

import json
from urllib.request import Request, urlopen
import errno
import sys
from pprint import pprint
import subprocess
import argparse

__author__ = 'jlmcgraw@gmail.com'


def get_jsonparsed_data(url):
    # Build the request
    request = Request(url)
    request.add_header('accept', 'application/json')

    # Get the json
    try:
        json_response = urlopen(request).read().decode("utf-8")
    except:
        print("Error getting DTPP information from {}".format(url))
        return None

    # Parse it
    response_dictionary = (json.loads(json_response))

    # Return the dictionary
    return response_dictionary


if __name__ == '__main__':

    # Parse the command line options
    parser = argparse.ArgumentParser(
        description='Download a specified edition of DTPP archives from FAA')

    parser.add_argument(
        '-e',
        '--edition',
        default='current',
        metavar='edition',
        help='Which edition of the DTPP to download.  Can be \'current\' or \'next\'',
        required=False)

    parser.add_argument(
        '-d',
        '--directory',
        default='.',
        metavar='DIRECTORY',
        help='Where to store the downloaded files',
        required=False)

    parser.add_argument(
        '-v',
        '--verbose',
        help='More output',
        action='store_true',
        required=False)

    args = parser.parse_args()

    # Set variables from command line options
    edition = args.edition
    directory = args.directory

    # The URL to get data from
    url = "https://soa.smext.faa.gov/apra/dtpp/chart?edition={}".format(
        edition)

    # Get the JSON data and return a dictionary of values from it
    response_dictionary = get_jsonparsed_data(url)

    # Print some of the values
    if response_dictionary:

        if args.verbose:
            pprint(response_dictionary)

        for edition in response_dictionary['edition']:

            # The URL of each part of the DTPP set
            url = edition['product']['url']

            if args.verbose:
                pprint(url)

            # Download it using wget
            subprocess.call(['wget',
                             '--timestamping',
                             '--directory-prefix={}'.format(directory),
                             url])

    else:
        print("No response from server")
        sys.exit(1)
