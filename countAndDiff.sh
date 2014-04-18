#!/bin/bash
set -eu                # Always put this in Bourne shell scripts
IFS="`printf '\n\t'`"  # Always put this in Bourne shell scripts

# This script assumes all of the plates are in a "./plates" subdirectory with a separate directory for each airport
mainPlatesDirectory=./plates


if [ $# -eq 0 ]
  then
    echo "No arguments supplied"
    echo ""
    echo "Usage: "
    echo "$0 <subdirectory to count plates for in $mainPlatesDirectory/>"
    echo "  eg: $0 TPA SSI (process one or more specific airports"
    echo "  eg: $0 . (does all plates)"
    echo ""
    echo "This script assumes all plates are in a separate subdirectory for each airport in $mainPlatesDirectory"
    exit
fi


allPdf() {
    #Output a list of all PDFs that aren't output from geoReferencePlates.pl)
     find $mainPlatesDirectory/$target -type f \
     \( \
        -iname "*.pdf" -a \
      ! -iname "marked*" -a \
      ! -iname "outlines*" \
      \)
}
notToScalePdf() {
  #Output a list of all PDFs known not to be to scale
  find $mainPlatesDirectory/$target -type f \
   \( \
      -iname "*.pdf" -a \
    ! -iname "marked*" -a\
    ! -iname "outlines*" -a \
      \( \
       -iname "*-lahso*" -o \
       -iname "*-hot-spot*" -o \
       -iname "*-airport-diagram*" -o \
       -iname "*-aaup*" -o \
       -iname "*-one*" -o \
       -iname "*-two*" -o \
       -iname "*-three*" -o \
       -iname "*-four*" -o \
       -iname "*-five*" -o \
       -iname "*-six*" -o \
       -iname "*-seven*" -o \
       -iname "*-eight*" -o \
       -iname "*-nine*" -o \
       -iname "*-cont*" \
       \) \
    \) 
}
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
      \)
   }
   
 vrt() {
     #Output a list of all files that end in .vrt
     find $mainPlatesDirectory/$target -type f \
  \( \
          -iname "*.vrt" -a \
        ! -iname "marked*" -a \
        ! -iname "outlines*" \
   \) 
 }
 

#for the list of all arguments from command line
for target in $@
#for target in IAH ATL DCA IAD BOS EWR JFK SFO DEN RIC OFP CHO JGG ORD ORF PHF PHL BWI SEA EDU VCB SMF SAC APN LAX SAN SLC CLE CVG CAE CLT LGA LAS ANC MSP MCO DTW FLL MDW STL MEM HNL PDX OAK HOU IND AUS MCI SAT MSY SDF BNA DAL SJC SJU PIT MKE BUF RSW JAX RDU SSI
#for target in .
do
   #List of plates we expect to be able to process (this includes miltary plates which don't work)
   #The "cut" is removing the file extension
    desirablePdf \
   | rev \
   | cut -d\. -f1 --complement \
   | rev \
   | sort \
    > desirable.txt   
  
    #List of plates the process did succeed for 
    #The "cut" is removing the file extension
    vrt | rev | cut -d\. -f1 --complement| rev | sort > vrt.txt

    #Get the counts of each category
    allCount=$( allPdf| wc -l )
    notToScaleCount=$( notToScalePdf | wc -l )
    desirableCount=$( cat desirable.txt | wc -l )
    vrtCount=$( cat vrt.txt | wc -l )

    echo $target: $allCount ALL, $desirableCount Desirable, $vrtCount VRT, 
  
    #List the differences between the two lists
    set +e
    diff --suppress-common-lines desirable.txt vrt.txt
    set -e

    #Hardcoded count of known miltary plates
    let militaryCount=1093
    let possibleCount=$allCount-$notToScaleCount-$militaryCount
    let missingCount=$possibleCount-$vrtCount
    
    echo $allCount allCount, $notToScaleCount notToScale, $militaryCount military, $possibleCount possible, $desirableCount desirable, $vrtCount vrt, $missingCount missing

done