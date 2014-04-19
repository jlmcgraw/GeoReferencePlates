#!/bin/bash
set -eu                # Always put this in Bourne shell scripts
IFS="`printf '\n\t'`"  # Always put this in Bourne shell scripts

sudo apt-get install gdal-bin
sudo apt-get install mupdf-tools
sudo apt-get install sqlite3
sudo apt-get install libpdf-api2-perl
sudo apt-get install libdbi-perl
sudo apt-get install libdbd-sqlite3-perl 
sudo apt-get install libimage-magick-perl
sudo apt-get install libfile-slurp-perl
sudo apt-get install libxml-xpath-perl