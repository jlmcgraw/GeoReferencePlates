#!/bin/bash
set -eu                # Always put this in Bourne shell scripts
IFS="`printf '\n\t'`"  # Always put this in Bourne shell scripts


#Check count of command line parameters
if [ "$#" -ne 2 ] ; then
  echo "Usage: $0 previousCycle latestCycle" >&2
  exit 1
fi

#Get command line parameters
previousCycle="$1"
latestCycle="$2"

#Where dtpp files will be unzipped to
latestDtppDir=dtpp-$latestCycle


#Unzip all of the latest charts
#Should abort on any errors
echo Unzipping DTPP $latestCycle files
unzip -u -j "DDTPP?_20$latestCycle.zip"  -d "$latestDtppDir"

if [ ! -d $latestDtppDir ]; then
    echo "$latestDtppDir doesn't exist"
    exit 1
fi

# #Create the new cycle db and download IAP,APD charts
# ./load_dtpp_metadata.pl . $latestCycle
# 
# #This hasn't been implemented yet  
# #Run autogeoref for added/changed plates
# #  ./verifyGeoreference.pl -c "./dtpp-$latestCycle"
#   
# #Move the old georeference database data to the new cycle db (overwriting auto data) along with hashes of GCPs
# ./moveOldCycleDataToNewCycle.pl $previousCycle $latestCycle
#   
# #Manually verify everything
# ./verifyGeoreference.pl $latestCycle