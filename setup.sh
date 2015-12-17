#!/bin/bash
set -eu                # Always put this in Bourne shell scripts
IFS=$(printf '\n\t')  # Always put this in Bourne shell scripts

#Install necessary software
sudo apt-get install \
                     gdal-bin \
                     mupdf-tools \
                     sqlite3 \
                     perltidy \
                     pngquant \
                     cpanminus \
                     Carton

#Install the libraries in our cpanfile locally
carton install

#Libraries that aren't working yet with Carton
sudo apt-get install \
                    libgd-perl \
                    libimage-magick-perl \
                    libgtk3-perl
                    
#Install various perl libraries
# sudo apt-get install libpdf-api2-perl
# sudo apt-get install libdbi-perl
# sudo apt-get install libdbd-sqlite3-perl 
# # sudo apt-get install libfile-slurp-perl
# sudo apt-get install libxml-xpath-perl
# sudo apt-get install libmath-round-perl
# sudo apt-get install libparams-validate-perl

# sudo apt-get install libparse-fixedlength-perl
# sudo apt-get install libxml-twig-perl
# sudo apt-get install libparallel-forkmanager-perl

#Clone some utilities locally for our use
git clone https://github.com/jlmcgraw/parallelGdal2tiles.git
git clone https://github.com/mapbox/mbutil.git
git clone https://github.com/jlmcgraw/tilers_tools.git

#Setup hooks to run perltidy on git commit
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
find . -maxdepth 1 -type f -name '*.pl' -or -name '*.pm' | \
    xargs -I{} -P0 sh -c 'perltidy -b -noll {}'
EOF

chmod +x .git/hooks/pre-commit