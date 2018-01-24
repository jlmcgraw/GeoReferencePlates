#!/bin/bash
set -eu                # Always put this in Bourne shell scripts
IFS=$(printf '\n\t')   # Always put this in Bourne shell scripts


# Check count of command line parameters
if [ "$#" -ne 3 ] ; then
  echo "Usage: $0 <directory_where_dtpp_zip_archives_are> <previous_cycle> <latest_cycle>" >&2
  echo "   eg: $0 ~/Downloads 1510 1511" >&2
  exit 1
fi

# Get command line parameters
source_dtpp_zip_dir="$1"
previous_cycle="$2"
latest_cycle="$3"

# Where dtpp files from previous cycle are
previous_dtpp_dir="./dtpp-$previous_cycle"

# Where latest dtpp zip files are stored
# source_dtpp_zip_dir="~/Downloads/"

# Where latest dtpp files will be unzipped to
latest_dtpp_dir="./dtpp-$latest_cycle"

# Check if source directory for DTPP zip files exists
if [ ! -d "$source_dtpp_zip_dir" ]; then
    echo "Source directory $source_dtpp_zip_dir doesn't exist"
    exit 1
fi

# Check if directory for previous_cycle exists
if [ ! -d "$previous_dtpp_dir" ]; then
    echo "Previous cycle directory $previous_dtpp_dir doesn't exist"
    exit 1
fi

# Check if database for previous_cycle exists
if [ ! -e "./dtpp-$previous_cycle.sqlite" ]; then
    echo "dtpp-$previous_cycle.sqlite doesn't exist, unable to copy old information"
    exit 1
fi

# Check if database for current cifp cycle exists
if [ ! -e "./cifp-$latest_cycle.sqlite" ]; then
    echo "cifp-$latest_cycle.sqlite doesn't exist, it's needed to process this cycle"
    echo "use https://github.com/jlmcgraw/parseCifp to create it"
    exit 1
fi

#Check if database for current dtpp cycle already exists
if [ -e "./dtpp-$latest_cycle.sqlite" ]; then
    echo "dtpp-$latest_cycle.sqlite already exists, delete it if you really want to start over"
    exit 1
fi

# Abort if the NASR database is too old
[[ $(date +%s -r "nasr.sqlite") -lt $(date +%s --date="28 days ago") ]] && echo "NASR database is older than 28 days, please update" && exit 1

# Unzip all of the latest charts
# Should abort on any errors
echo "Unzipping DTPP $latest_cycle files"
unzip -u -j -q "$source_dtpp_zip_dir/DDTPP?_20$latest_cycle.zip"  -d "$latest_dtpp_dir" > "$latest_cycle-unzip.txt"

# Did the directory for latest DTPP cycle get created?
if [ ! -d "$latest_dtpp_dir" ]; then
    echo "Latest cycle directory $latest_dtpp_dir doesn't exist, did the archives extract properly?"
    exit 1
fi

# Create the new cycle database and download IAP,APD charts
# Also create a file with count of charts
./load_dtpp_metadata.pl . "$latest_cycle" | tee "$latest_cycle-stats.txt"

# Move the old georeference database data to the new cycle db (overwriting auto data) along with hashes of GCPs
./moveOldCycleDataToNewCycle.pl "$previous_cycle" "$latest_cycle"

# Run autogeoref for added/changed plates
./georeference_plates_via_db.pl -n -s "$latest_cycle"

#Manually verify everything.  Get ready to left click many, many times
./verifyGeoreference.pl "$latest_cycle"

# #Create a copy of the database with all unneeded information removed
# ./sanitizeDtpp.sh $latest_cycle
