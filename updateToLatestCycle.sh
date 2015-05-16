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

#Where dtpp files from previous cycle are
previousDtppDir=./dtpp-$previousCycle

#Where latest dtpp zip files are stored
sourceDtppZipDir="/media/sf_Shared_Folder/"

#Where latest dtpp files will be unzipped to
latestDtppDir=./dtpp-$latestCycle



#Check if directory for previousCycle exists
if [ ! -d $previousDtppDir ]; then
    echo "$previousDtppDir doesn't exist"
    exit 1
fi

#Check if database for previousCycle exists
if [ ! -e ./dtpp-$previousCycle.db ]; then
    echo "$previousCycle.db doesn't exist, unable to copy old information"
    exit 1
fi

#Check if database for current cifp cycle exists
if [ ! -e ./cifp-$latestCycle.db ]; then
    echo "cifp-$latestCycle.db doesn't exist, it's needed to process this cycle"
    exit 1
fi

#Abort if the NASR database is too old
[[ $(date +%s -r 56day.db) -lt $(date +%s --date="56 days ago") ]] && echo "NASR database is older than 56 days, please update" && exit 1

#Unzip all of the latest charts
#Should abort on any errors
echo Unzipping DTPP $latestCycle files
unzip -u -j -q "$sourceDtppZipDir/DDTPP?_20$latestCycle.zip"  -d "$latestDtppDir"

#Did the directory for latest DTPP cycle get created?
if [ ! -d $latestDtppDir ]; then
    echo "$latestDtppDir doesn't exist"
    exit 1
fi

#Create the new cycle database and download IAP,APD charts
#Also create a file with count of charts
./load_dtpp_metadata.pl . $latestCycle | tee $latestCycle-stats.txt

#Move the old georeference database data to the new cycle db (overwriting auto data) along with hashes of GCPs
./moveOldCycleDataToNewCycle.pl $previousCycle $latestCycle

#Run autogeoref for added/changed plates
./georeferencePlatesViaDb.pl -n -s $latestCycle

#Manually verify everything
./verifyGeoreference.pl $latestCycle

# #Create a copy of the database with all unneeded information removed
# ./sanitizeDtpp.sh $latestCycle
