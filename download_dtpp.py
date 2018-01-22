#!/usr/bin/python3 

import json
from urllib.request import Request, urlopen
import errno, sys
from pprint import pprint
import subprocess
 
# The URL to get data from
# Change this to "next" to get next edition
url="https://soa.smext.faa.gov/apra/dtpp/chart?edition=current"

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

# Get the JSON data and return a dictionary of values from it
response_dictionary = get_jsonparsed_data(url)

# Print some of the values
if response_dictionary:
    
    # Print the whole response
    # pprint(response_dictionary)
   
    for edition in response_dictionary['edition']:
        
        # The URL of each part of the DTPP set
        url = edition['product']['url']
        # pprint(url)
        # Download it using wget
        subprocess.call (['wget', '--timestamping', url])

else:
    print("No response from server")
    sys.exit(1)
