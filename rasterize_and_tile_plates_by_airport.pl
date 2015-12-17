#!/usr/bin/perl

# Given a database of charts and georef data, create a directory of IAP and APD .PNGs and
# associated world files
#
# Copyright (C) 2013  Jesse McGraw (jlmcgraw@gmail.com)
#
#-------------------------------------------------------------------------------
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see [http://www.gnu.org/licenses/].

#-------------------------------------------------------------------------------
#TODO
# Finding 12826 vs 12837 airports when joining on CIFP id
# Make sure upperLeftLon/upperLeftLat are used if no CIFP airport coordinate

use 5.010;
use strict;
use warnings;
use autodie;

#Standard libraries
use Carp;
use File::Copy;
use File::Slurp qw(read_file write_file read_dir);
use File::Path qw(make_path remove_tree);
use Getopt::Std;
use vars qw/ %opt /;
use DBI;

#Allow use of locally installed libraries in conjunction with Carton
use FindBin '$Bin';
use lib "$FindBin::Bin/local/lib/perl5";

#Non-standard libraries
use Params::Validate qw(:all);
use Parse::FixedLength;

#Call the main routine and exit with its return code
exit main(@ARGV);

#-------------------------------------------------------------------------------
sub main {

    #Define the valid command line options
    my $opt_string = 'tmoa:s:';
    my $arg_num    = scalar @ARGV;

    if ( $arg_num < 1 ) {
        usage();
    }

    #This will fail if we receive an invalid option
    unless ( getopts( "$opt_string", \%opt ) ) {
        usage();
    }

    #Whether to perform various functions
    my $shouldCreateTiles   = $opt{t};
    my $shouldCreateMbtiles = $opt{m};
    my $shouldOptimizeTiles = $opt{o};

    #Either of these options implies making tiles first
    if ( $shouldCreateMbtiles || $shouldOptimizeTiles ) {
        $shouldCreateTiles = 'True';
    }

    #Default to all airports for the SQL query
    my $airportId = "%";
    if ( $opt{a} ) {

        #If something  provided on the command line use it instead
        $airportId = $opt{a};
        say "Supplied airport ID: $airportId";
    }

    #Default to all states for the SQL query
    my $stateId = "%";

    if ( $opt{s} ) {

        #If something  provided on the command line use it instead
        $stateId = $opt{s};
        say "Supplied state ID: $stateId";
    }

    #Get the cycle from command line options
    my $cycle = $ARGV[0];

    if ( !( $cycle =~ /^\d\d\d\d$/ ) ) {
        say "Cycle must be a 4 digit number";
        say "eg: $0 1413";
        exit(1);
    }

    say "Cycle: $cycle";

    #Connect to our databases
    my $dtppDatabase = "./dtpp-$cycle.db";
    my $cifpDatabase = "./cifp-$cycle.db";

    #database of metadata for dtpp
    my $dtppDbh = DBI->connect( "dbi:SQLite:dbname=$dtppDatabase",
        "", "", { RaiseError => 1 } )
      or croak $DBI::errstr;

    $dtppDbh->do("PRAGMA page_size=4096");
    $dtppDbh->do("PRAGMA synchronous=OFF");

    #Also attach our CIFP database
    $dtppDbh->do("attach database '$cifpDatabase' as cifp");

    #Query the dtpp database for charts
    my $dtppSth = $dtppDbh->prepare(
        "SELECT 
	D.PDF_NAME
	,D.FAA_CODE
	,D.CHART_NAME
	,D.MILITARY_USE
	,DG.upperLeftLon
	,DG.upperLeftLat
	,DG.xMedian
	,DG.yMedian
	,DG.xPixelSkew
	,DG.yPixelSkew
	,C.AirportReferencePtLongitude
	,C.AirportReferencePtLatitude
      FROM 
	dtpp as D 
      JOIN 
	dtppGeo as DG 
	,cifp.'primary_P_A_base_Airport - Reference Points' as C
      ON 
	D.PDF_NAME=DG.PDF_NAME
            and
        D.FAA_CODE=C.ATAIATADesignator
      WHERE
        ( 
        CHART_CODE = 'IAP'
            OR 
        CHART_CODE = 'APD' 
        )
            AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
            AND
        DG.STATUS LIKE '%MANUALGOOD%'
            AND
        D.FAA_CODE LIKE  '$airportId'
            AND
        D.STATE_ID LIKE  '$stateId'
        ;"
    );
    $dtppSth->execute();

    my $_allSqlQueryResults = $dtppSth->fetchall_arrayref();
    my $_rows               = $dtppSth->rows;

    unless ($_rows) {
        say "No charts found in database";
        exit(1);
    }

    say "Processing $_rows charts";
    my $completedCount = 0;

    #Where the PDFs are for this cycle
    my $inputPathRoot = "./dtpp-$cycle/";

    #Where to store output
    my $outputPathRoot = "./byAirportWorldFile-$cycle/";

    #Make the output directory if it doesn't already exist
    if ( !-e "$outputPathRoot" ) {
        make_path("$outputPathRoot");
    }

    #Process each plate returned by our query
    foreach my $_row (@$_allSqlQueryResults) {

        my (
            $PDF_NAME,                    $FAA_CODE,
            $CHART_NAME,                  $MILITARY_USE,
            $upperLeftLon,                $upperLeftLat,
            $xPixelSize,                  $yPixelSize,
            $xPixelSkew,                  $yPixelSkew,
            $AirportReferencePtLongitude, $AirportReferencePtLatitude
        ) = @$_row;

        say "$FAA_CODE ----------------------------------------------------";

        #Make the airport directory if it doesn't already exist
        if ( !-e "$outputPathRoot" . "$FAA_CODE/" ) {
            make_path( "$outputPathRoot" . "$FAA_CODE/" );
        }

        my ($chartBasename) = $PDF_NAME =~ m/(\w+)\.PDF/i;
        my $pngName         = $chartBasename . '.png';
        my $worldFileName   = $chartBasename . '.wld';
        my $vrtFileName     = $chartBasename . '.vrt';
        my $numberFormat    = "%.10f";

        #Create the .png for this procedure if it doesn't already exist
        if ( !-e "$outputPathRoot" . "$FAA_CODE/" . $pngName ) {

            #say "No .png ($pngName) found for $FAA_CODE";

            say "Create PNG: "
              . $inputPathRoot
              . $PDF_NAME . "->"
              . $outputPathRoot
              . "$FAA_CODE/"
              . $pngName;

            convertPdfToPng( $inputPathRoot . $PDF_NAME,
                $outputPathRoot . "$FAA_CODE/" . $pngName );

            say "Optimize: $outputPathRoot" . "$FAA_CODE/" . $pngName;

            my $pngQuantCommand =
                "pngquant -s2 -q 100 --ext=.png --force $outputPathRoot"
              . "$FAA_CODE/"
              . $pngName;

            executeAndReport($pngQuantCommand);
        }

        #If this plate is georeferenced (which it should be due to our query parameters
        if ( $upperLeftLon && $upperLeftLat ) {

            my $worldfilePath =
              "$outputPathRoot" . "$FAA_CODE/" . "$worldFileName";

            #Create the world file
            open( my $fh, '>', $worldfilePath )
              or die "Could not open file '$worldfilePath' $!";

            if ( $yPixelSize > 0 ) {

                say "Converting $yPixelSize to negative";
                $yPixelSize = -($yPixelSize);
            }

            #Write out the world file parameters
            say $fh sprintf( $numberFormat, $xPixelSize );
            say $fh sprintf( $numberFormat, $yPixelSkew );
            say $fh sprintf( $numberFormat, $xPixelSkew );
            say $fh sprintf( $numberFormat, $yPixelSize );
            say $fh sprintf( $numberFormat, $upperLeftLon );
            say $fh sprintf( $numberFormat, $upperLeftLat );
            close $fh;

            #Make a .vrt for this .png, using the .wld file we just created
            say "Translate: $outputPathRoot$FAA_CODE/$pngName";

            my $gdal_translateCommand =
                "gdal_translate -of VRT -strict -a_srs EPSG:4326"
              . " $outputPathRoot$FAA_CODE/$pngName"
              . " $outputPathRoot$FAA_CODE/$vrtFileName";

            executeAndReport($gdal_translateCommand);

            #Create tiles if the user asked to
            if ($shouldCreateTiles) {
                say "Tile: $outputPathRoot$FAA_CODE/$vrtFileName";

                my $tileCommand =
                    "./tilers_tools/gdal_tiler.py "
                  . ' --profile=tms'
                  . ' --release'
                  . ' --paletted'
                  . ' --dest-dir="'
                  . $outputPathRoot
                  . $FAA_CODE . '"'
                  . " $outputPathRoot"
                  . $FAA_CODE . '/'
                  . $vrtFileName;

                executeAndReport($tileCommand);

                #Copy the viewer
                copy( "./leaflet_template.html",
                    "$outputPathRoot$FAA_CODE/$chartBasename.tms/leaflet.html"
                );

                #Get the sort list of directories in the tiles folder and use first entry as min zoom
                #and last as maxZoom
                # TODO HACK
                my $tilesDirectory =
                  "$outputPathRoot$FAA_CODE/$chartBasename.tms";
                my @zoom_levels =
                  sort { $a <=> $b }
                  grep { -d "$tilesDirectory/$_" } read_dir($tilesDirectory);
                my $minNativeZoom = $zoom_levels[0];
                my $maxNativeZoom = $zoom_levels[-1];

                #Calculate WGS84 decimal coordinates of the airport
                my $airportLongitudeWgs84 =
                  coordinateToDecimalCifpFormat($AirportReferencePtLongitude);
                my $airportLatitudeWgs84 =
                  coordinateToDecimalCifpFormat($AirportReferencePtLatitude);

                #If these coordinates aren't defined use the upper left ones
                $airportLongitudeWgs84 //= $upperLeftLon;
                $airportLatitudeWgs84  //= $upperLeftLat;

                #Adjust the template for this particular plate
                #Fix up the parameters in the leaflet
                #These are simple hacks for now
                my $filename =
                  "$outputPathRoot$FAA_CODE/$chartBasename.tms/leaflet.html";
                my $data = read_file $filename, { binmode => ':utf8' };

                $data =~
                  s|<title>Tiled Chart</title>|<title>$FAA_CODE $CHART_NAME</title>|ig;
                $data =~
                  s|this._div.innerHTML = "Merged Chart";|this._div.innerHTML = "$FAA_CODE $CHART_NAME";|ig;
                $data =~
                  s|center: \[44.966667,-103.766667\],|center: [$airportLatitudeWgs84, $airportLongitudeWgs84],|ig;
                $data =~ s|zoom: 4,|zoom: $minNativeZoom,|ig;
                $data =~
                  s|maxNativeZoom: 12345|maxNativeZoom: $maxNativeZoom|ig;

                write_file $filename, { binmode => ':utf8' }, $data;

            }

            #Optimize all of the tiles if the user asked to
            if ($shouldOptimizeTiles) {
                say "Optimize: $outputPathRoot$FAA_CODE/$chartBasename.tms";

                my $pngQuantCommand =
                  "./pngquant_all_files_in_directory.sh $outputPathRoot$FAA_CODE/$chartBasename.tms";

                executeAndReport($pngQuantCommand);
            }

            #Create mbtiles if the user asked to
            if ($shouldCreateMbtiles) {
                say "Mbtile: $outputPathRoot$FAA_CODE/$chartBasename.tms";
                my $mbtileCommand =
                    "python ./mbutil/mb-util"
                  . ' --scheme=tms'
                  . " $outputPathRoot$FAA_CODE/$chartBasename.tms"
                  . " $outputPathRoot$FAA_CODE/$chartBasename.mbtiles";

                executeAndReport($mbtileCommand);
            }

            ++$completedCount;
        }

    }

}

sub executeAndReport {

    #Validate and set input parameters to this function
    my ($command) =
      validate_pos( @_, { type => SCALAR } );

    my $output = qx($command);

    my $retval = $? >> 8;

    #Did we succeed?
    if ( $retval != 0 ) {
        say $output;
        carp "Error from $command.   Return code is $retval";
    }
    return $retval;
}

sub convertPdfToPng {

    #Validate and set input parameters to this function
    my ( $targetPdf, $targetPng ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR } );

    #DPI of the output PNG
    my $pngDpi = 300;

    #Convert the PDF to a PNG
    my $pdfToPpmOutput;

    #Return if the png already exists
    if ( -e $targetPng ) {
        return;
    }

    $pdfToPpmOutput = qx(pdftoppm -png -r $pngDpi $targetPdf > $targetPng);

    my $retval = $? >> 8;

    #Did we succeed?
    if ( $retval != 0 ) {

        #Delete the possibly bad png
        unlink $targetPng;
        carp "Error from pdftoppm.   Return code is $retval";
    }

    return $retval;
}

sub usage {
    say "Usage: $0 <options> <cycle>";
    say " <cycle> The cycle number, eg. 1513";
    say "   -t Make tiles";
    say "   -m Make mbtiles";
    say "   -o Optimze tile size";
    say "   -a FAA airport ID";
    say "   -s Two letter state code";

    exit 1;
}

sub coordinateToDecimalCifpFormat {

    #Convert a latitude or longitude in CIFP format to its decimal equivalent
    my ($coordinate) = shift;
    my ( $deg, $min, $sec, $signedDegrees, $declination, $secPostDecimal );
    my $data;

    #First parse the common information for a record to determine which more specific parser to use
    my $parser_latitude = Parse::FixedLength->new(
        [
            qw(
              Declination:1
              Degrees:2
              Minutes:2
              Seconds:2
              SecondsPostDecimal:2
              )
        ]
    );
    my $parser_longitude = Parse::FixedLength->new(
        [
            qw(
              Declination:1
              Degrees:3
              Minutes:2
              Seconds:2
              SecondsPostDecimal:2
              )
        ]
    );

    #Get the first character of the coordinate and parse accordingly
    $declination = substr( $coordinate, 0, 1 );

    given ($declination) {
        when (/[NS]/) {
            $data = $parser_latitude->parse_newref($coordinate);
            die "Bad input length on parser_latitude"
              if ( $parser_latitude->length != 9 );

            #Latitude is invalid if less than -90  or greater than 90
            # $signedDegrees = "" if ( abs($signedDegrees) > 90 );
        }
        when (/[EW]/) {
            $data = $parser_longitude->parse_newref($coordinate);
            die "Bad input length on parser_longitude"
              if ( $parser_longitude->length != 10 );

            #Longitude is invalid if less than -180 or greater than 180
            # $signedDegrees = "" if ( abs($signedDegrees) > 180 );
        }
        default {
            return 0;

        }
    }

    $declination    = $data->{Declination};
    $deg            = $data->{Degrees};
    $min            = $data->{Minutes};
    $sec            = $data->{Seconds};
    $secPostDecimal = $data->{SecondsPostDecimal};

    # print Dumper($data);

    $deg = $deg / 1;
    $min = $min / 60;

    #Concat the two portions of the seconds field with a decimal between
    $sec = ( $sec . "." . $secPostDecimal );

    # say "Sec: $sec";
    $sec           = ($sec) / 3600;
    $signedDegrees = ( $deg + $min + $sec );

    #Make coordinate negative if necessary
    if ( ( $declination eq "S" ) || ( $declination eq "W" ) ) {
        $signedDegrees = -($signedDegrees);
    }

    # say "Coordinate: $coordinate to $signedDegrees";           #if $debug;
    # say "Decl:$declination Deg: $deg, Min:$min, Sec:$sec";    #if $debug;

    return ($signedDegrees);
}
