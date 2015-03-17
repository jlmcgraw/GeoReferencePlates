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
sudo apt-get install libmath-round-perl
sudo apt-get install libparams-validate-perl
sudo apt-get install libgtk3-perl
sudo apt-get install libgd-perl
sudo apt-get install libparse-fixedlength-perl
sudo apt-get install libxml-twig-perl
sudo apt-get install libparallel-forkmanager-perl


cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
find . -maxdepth 1 -type f -name '*.pl' -or -name '*.pm' | \
    xargs -I{} -P0 sh -c 'perltidy -b -noll {}'
EOF