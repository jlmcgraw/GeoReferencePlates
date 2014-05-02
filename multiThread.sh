#!/bin/bash
set -eu                # Always put this in Bourne shell scripts
IFS="`printf '\n\t'`"  # Always put this in Bourne shell scripts

# This script assumes all of the plates are in a "./plates" subdirectory with a separate directory for each airport
mainPlatesDirectory=./plates

desirablePdf() {
  #Output a list of PDFs we should be able to georeference
     find $mainPlatesDirectory/$target -type f \
     \( \
        -iname "*.pdf" -a \
      ! -iname "marked*" -a\
      ! -iname "outlines*" -a \
         ! -iname "*-lahso*" -a \
         ! -iname "*-hot-spot*" -a \
         ! -iname "*-airport-diagram*" -a \
         ! -iname "*-aaup*" -a \
         ! -iname "*-one*" -a \
         ! -iname "*-two*" -a \
         ! -iname "*-three*" -a \
         ! -iname "*-four*" -a \
         ! -iname "*-five*" -a \
         ! -iname "*-six*" -a \
         ! -iname "*-seven*" -a \
         ! -iname "*-eight*" -a \
         ! -iname "*-nine*" -a \
         ! -iname "*-cont*" \
      \) \
      -print0
   }
  
#Get the number of online CPUs
cpus=$(getconf _NPROCESSORS_ONLN)

# Use this if you would like to hard code the number of CPUs being used
# cpus=1
echo "Using $cpus CPUS"

statfile=./statistics-$(date +%F-%T).csv
echo $statfile

if  [ -e ./statistics.csv ]
 then 
    rm ./statistics.csv
fi

#Uncomment this to do a list of airports
#for target in IAH ATL DCA IAD BOS EWR JFK SFO DEN RIC OFP CHO JGG ORD ORF PHF PHL BWI SEA EDU VCB SMF SAC APN LAX SAN SLC CLE CVG CAE CLT LGA LAS ANC MSP MCO DTW FLL MDW STL MEM HNL PDX OAK HOU IND AUS MCI SAT MSY SDF BNA DAL SJC SJU PIT MKE BUF RSW JAX RDU SSI

#Uncomment this to do all plates in $mainPlatesDirectory (./plates by default)
for target in .

# for target in I22 MYU AKP IXD ENM PNI DEN
do
  echo Target: $target
  
  #Remove old .VRTs in our target
  find $mainPlatesDirectory/$target -iname "*.vrt" -delete

  #Don't stop executing on  error return codes
  set +e

  #Georeference all of the plates in the "./plates" subdirectory and below using $cpus processes
  #Ignore airport diagrams, hotspots, lahso, and sids/stars
  #Change the options here to create statistics or marked PDFs
   desirablePdf | xargs --null --max-args=1 --max-procs=$cpus  ./georeferencePlates.pl -s
   
   #Use this command if you have a file "args.txt" containing a specific list of PDFs to process (eg a list of plates that didn't work properly)
  #xargs --arg-file=args.txt --max-args=1 --max-procs=$cpus  ./georeferencePlates.pl -s -p

  #Now do stop executing on  error return codes

  
  #Get a count of expected/actual plates and show the differences in the two lists
  ./countAndDiff.sh $target
  set -e
done

#Copy the statistics to a new file based on date and time
cat statistics.csv | sort -r | uniq > $statfile

#Pull out the vital stats about each processed plate
#find ./plates/ -iname "*.vrt" ! -iname "marked*" -type f -exec sh -c 'gdalinfo "{}" | ./getVrtInfo.pl' \; > stats.csv

