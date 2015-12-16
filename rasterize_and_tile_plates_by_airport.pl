#!/usr/bin/perl

# Given a database of charts and georef data, create a directory of IAP and APD .PNGs and
# associated world files
#
# Copyright (C) 2013  Jesse McGraw (jlmcgraw@gmail.com)
#
#--------------------------------------------------------------------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------------------------------------------------------------------

use 5.010;

use strict;
use warnings;
use Carp;
use File::Copy;

#use diagnostics;
use DBI;
use LWP::Simple;
use XML::Twig;
use PDF::API2;
use autodie;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use POSIX;
use File::Copy qw(copy);
use Params::Validate qw(:all);
use File::Path qw(make_path remove_tree);

#Call the main routine and exit with its return code
exit main(@ARGV);

#--------------------------------------------------------------------------
sub main {

    # mkdir byAirport-$cycle
    # for each distinct FAA_CODE
    #   mkdir FAA_CODE
    #   for each DTPP that is IAP or AirportDiagram
    #   santize procedure Name
    #   create a .wld file from database
    #   link ./byAirportWorldFile$cycle/AirportCode/procedureName.png -> ./dtpp-$cycle/chartcode.png

    my $arg_num = scalar @ARGV;

    #We need at least one argument (the name of the PDF to process)
    if ( $arg_num < 1 ) {
        say "Specify cycle";
        say "eg: $0 1410";
        exit(1);
    }

    my $cycle = shift @ARGV;

    if ( !( $cycle =~ /^\d\d\d\d$/ ) ) {
        say "Cycle must be a 4 digit number";
        say "eg: $0 1413";
        exit(1);
    }

    say "Cycle: $cycle";

    #Connect to our databases
    my $dbFile = "./dtpp-$cycle.db";

    #database of metadata for dtpp
    my $dtppDbh =
      DBI->connect( "dbi:SQLite:dbname=$dbFile", "", "", { RaiseError => 1 } )
      or croak $DBI::errstr;

    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     );

    $dtppDbh->do("PRAGMA page_size=4096");
    $dtppDbh->do("PRAGMA synchronous=OFF");

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
      FROM 
	dtpp as D 
      JOIN 
	dtppGeo as DG 
      ON 
	D.PDF_NAME=DG.PDF_NAME
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

    my $inputPathRoot  = "./dtpp-$cycle/";
    my $outputPathRoot = "./byAirportWorldFile-$cycle/";

    #Process each plate returned by our query
    foreach my $_row (@$_allSqlQueryResults) {

        my (
            $PDF_NAME,     $FAA_CODE,     $CHART_NAME, $MILITARY_USE,
            $upperLeftLon, $upperLeftLat, $xPixelSize, $yPixelSize,
            $xPixelSkew,   $yPixelSkew
        ) = @$_row;

        say "$FAA_CODE ----------------------------------------------------";
        
        #Make the airport directory if it doesn't already exist
        if ( !-e "$outputPathRoot" ) {
            make_path("$outputPathRoot");
        }

        #Make the airport directory if it doesn't already exist
        if ( !-e "$outputPathRoot" . "$FAA_CODE/" ) {
            make_path( "$outputPathRoot" . "$FAA_CODE/" );
        }

        my ($chartBasename) = $PDF_NAME =~ m/(\w+)\.PDF/i;
        my $pngName         = $chartBasename . '.png';
        my $worldFileName   = $chartBasename . '.wld';
        my $vrtFileName     = $chartBasename . '.vrt';
        my $numberFormat    = "%.10f";

        #Does the .png for this procedure exist
        if ( -e "$outputPathRoot" . "$FAA_CODE/" . $pngName ) {

            #             link( "$", "$outputPathRoot . $FAA_CODE/$targetVrtFile.vrt" );

            #             link( "$inputPathRoot" . "$pngName",
            #                 "$outputPathRoot" . "$FAA_CODE" . "/$FAA_CODE-$pngName" );
        }
        else {
            #say "No .png ($pngName) found for $FAA_CODE";

            #Convert the PDF to a PNG if one doesn't already exist
            say "Create PNG: "
              . $inputPathRoot
              . $PDF_NAME . "->"
              . $outputPathRoot
              . "$FAA_CODE/"
              . $pngName;
              
            convertPdfToPng( $inputPathRoot . $PDF_NAME,
                $outputPathRoot . "$FAA_CODE/" . $pngName );
                
            say "Optimize $outputPathRoot" . "$FAA_CODE/" . $pngName;
            
            my $pngQuantCommand =
                "pngquant -s2 -q 100 --ext=.png --force $outputPathRoot" . "$FAA_CODE/" . $pngName;

            executeAndReport($pngQuantCommand);
        }

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

            say "Translate $outputPathRoot$FAA_CODE/$pngName";
            
            my $gdal_translateCommand =
              "gdal_translate -of VRT -strict -a_srs EPSG:4326"
              . " $outputPathRoot$FAA_CODE/$pngName"
              . " $outputPathRoot$FAA_CODE/$vrtFileName";
              
            executeAndReport($gdal_translateCommand);
            
            
            
            say "Tile $outputPathRoot$FAA_CODE/$vrtFileName";
            
            my $tileCommand = 
                "../mergedCharts/tilers_tools/gdal_tiler.py "
                   . ' --profile=tms'
                   . ' --release'
                   . ' --paletted'
                   . ' --dest-dir="' . $outputPathRoot . $FAA_CODE . '"'
                   . " $outputPathRoot" . $FAA_CODE . '/' . $vrtFileName;

            executeAndReport($tileCommand);

            
            
            say "Optimize $outputPathRoot$FAA_CODE/$chartBasename.tms";
            
            my $pngQuantCommand =
                "../mergedCharts/pngquant_all_files_in_directory.sh $outputPathRoot$FAA_CODE/$chartBasename.tms";

            executeAndReport($pngQuantCommand);

            
            
            say "Mbtile $outputPathRoot$FAA_CODE/$chartBasename.tms";
            my $mbtileCommand = "python ../mergedCharts/mbutil/mb-util"
                . ' --scheme=tms'
                . " $outputPathRoot$FAA_CODE/$chartBasename.tms"
                . " $outputPathRoot$FAA_CODE/$chartBasename.mbtiles";

            executeAndReport($mbtileCommand);

            #Copy the viewer
            copy(
                "../mergedCharts/leaflet.html",
                "$outputPathRoot$FAA_CODE/$chartBasename.tms"
            );
            
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
