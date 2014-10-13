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

    # mkdir byAirport
    # for each distinct FAA_CODE
    # mkdir FAA_CODE
    # for each DTPP that is IAP or AirportDiagram
    # santize procedure Name
    # create a .wld file from database
    # link ./byAirportWorldFile/AirportCode/procedureName.png -> ./dtpp/chartcode.png

    my $arg_num = scalar @ARGV;

    #We need at least one argument (the name of the PDF to process)
    if ( $arg_num < 1 ) {
        say "Specify cycle";
        say "eg: $0 1410";
        exit(1);
    }

    my $cycle = shift @ARGV;

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
--          AND
--        DG.STATUS LIKE '%MANUALGOOD%'
--          AND
--        CAST (DG.xPixelSkew as FLOAT) > '0'    
--        CAST (DG.upperLeftLon AS FLOAT) = '0'
--          AND
--        CAST (DG.xScaleAvgSize as FLOAT) > 1
--          AND
--        Difference  > .08
--      ORDER BY 
--        Difference ASC
;"
    );
    $dtppSth->execute();

    my $_allSqlQueryResults = $dtppSth->fetchall_arrayref();
    my $_rows               = $dtppSth->rows;
    say "Processing $_rows charts";
    my $completedCount = 0;

    my $inputDir  = "./dtpp-$cycle/";
    my $outputDir = "./byAirportWorldFile-$cycle/";

    #Process each plate returned by our query
    foreach my $_row (@$_allSqlQueryResults) {

        my (
            $PDF_NAME,     $FAA_CODE,     $CHART_NAME, $MILITARY_USE,
            $upperLeftLon, $upperLeftLat, $xPixelSize, $yPixelSize,
            $xPixelSkew,   $yPixelSkew
        ) = @$_row;

        # EC-3, ORD, 51125, IAP, ILS RWY 09L (SA CAT I), , 00166I9LSAC1.PDF, , N, , IL
        # say      '$TPP_VOLUME, $FAA_CODE, $CHART_SEQ, $CHART_CODE, $CHART_NAME, $USER_ACTION, $PDF_NAME, $FAANFD18_CODE, $MILITARY_USE, $COPTER_USE, $STATE_ID';
        #         say "$PDF_NAME,     $FAA_CODE,     $CHART_NAME,
        #             $upperLeftLon, $upperLeftLat, $xPixelSize,
        #             $yPixelSize,   $xPixelSkew,   $yPixelSkew";

        #         my $targetVrtFile =
        #           $STATE_ID . "-" . $FAA_CODE . "-" . $PDF_NAME . "-" . $CHART_NAME;
        #
        #         # convert spaces, ., and slashes to dash
        #         $targetVrtFile =~ s/[\s \/ \\ \. \( \)]/-/xg;
        #
        #         my $targetVrtBadRatio = $dir . "badRatio-" . $targetVrtFile . ".vrt";
        #         my $touchFile         = $dir . "noPoints-" . $targetVrtFile . ".vrt";

        #         my $targetvrt = $dir . $targetVrtFile . ".vrt";

        #Make the airport directory if it doesn't already exist
        if ( !-e "$outputDir" ) {
            make_path("$outputDir");
        }

        #Make the airport directory if it doesn't already exist
        if ( !-e "$outputDir" . "$FAA_CODE/" ) {
            make_path( "$outputDir" . "$FAA_CODE/" );
        }
        my ($chartBasename) = $PDF_NAME =~ m/(\w+)\.PDF/i;
        my $pngName         = $chartBasename . '.png';
        my $worldFileName   = $chartBasename . '.wld';
        my $numberFormat    = "%.10f";

        #Does the .png for this procedure exist
        if ( -e "$inputDir" . "$pngName" ) {

            #             link( "$", "$outputDir . $FAA_CODE/$targetVrtFile.vrt" );

            link( "$inputDir" . "$pngName",
                "$outputDir" . "$FAA_CODE" . "/$FAA_CODE-$pngName" );

            if ( $upperLeftLon && $upperLeftLat ) {
                my $worldfilePath =
                  "$outputDir" . "$FAA_CODE" . "/$FAA_CODE-$worldFileName";

                #Create the world file
                open( my $fh, '>', $worldfilePath )
                  or die "Could not open file '$worldfilePath' $!";

                if ( $yPixelSize > 0 ) {

                    #                 say "Converting $yPixelSize to negative";
                    $yPixelSize = -($yPixelSize);
                }

                #             if ($xPixelSkew != 0 && $yPixelSkew == 0)
                # 	      {
                # # say "Something wrong with X skew on $FAA_CODE ($PDF_NAME)";
                # }
                # 	    if ($yPixelSkew != 0 && $xPixelSkew == 0)
                # 	      {
                # # 	      say "Something wrong with Y skew on $FAA_CODE ($PDF_NAME)";
                # 	      }
                # 	    if ($yPixelSkew != 0 && $xPixelSkew != 0)
                # # 	      {say "Non-zero X and Y skew on $FAA_CODE ($PDF_NAME)";}
                #
                # 	    if (abs($yPixelSize) < 0.00001 )
                # # 	      {say " yPixelSize too small (" . sprintf($numberFormat,$yPixelSize) . ") on $FAA_CODE ($PDF_NAME)";}
                #
                # 	    if (abs($yPixelSize) > 0.00009 )
                # # 	      {say " yPixelSize too big (" . sprintf($numberFormat,$yPixelSize) . ") on $FAA_CODE ($PDF_NAME)";}
                #
                # 	    if ($xPixelSize < 0.00001 )
                # # 	      {say " xPixelSize too small (" . sprintf($numberFormat,$xPixelSize) . ") on $FAA_CODE ($PDF_NAME)";}
                #
                # 	    if ($xPixelSize > 0.00009 )
                # # 	      {say " xPixelSize too big (" . sprintf($numberFormat,$xPixelSize) . ") on $FAA_CODE ($PDF_NAME)";}

                #             say $fh $xPixelSize;
                say $fh sprintf( $numberFormat, $xPixelSize );

                #             say $fh $yPixelSkew;
                say $fh sprintf( $numberFormat, $yPixelSkew );

                #             say $fh $xPixelSkew;
                say $fh sprintf( $numberFormat, $xPixelSkew );

                #             say $fh $yPixelSize;
                say $fh sprintf( $numberFormat, $yPixelSize );

                #             say $fh $upperLeftLon;
                say $fh sprintf( $numberFormat, $upperLeftLon );

                #             say $fh $upperLeftLat;
                say $fh sprintf( $numberFormat, $upperLeftLat );
                close $fh;
            }

            #             if ( $CHART_CODE eq "APD" ) {
            #                 $targetvrt = $dir . "warped" . $targetVrtFile . ".vrt";
            # # 		say $targetvrt;
            #                 if ( -e "$targetvrt"
            #                     && !-e "./byAirportWorldFile/$FAA_CODE/warped-$targetVrtFile.vrt" )
            #                 {
            #                     link( "$targetvrt",
            #                         "./byAirportWorldFile/$FAA_CODE/warped-$targetVrtFile.vrt" );
            # #                     say $targetvrt;
            #                 }
            #             }
        }
        else {
            say "No .png ($pngName) for $FAA_CODE";
        }
        ++$completedCount;

        #         say "$completedCount" . "/" . "$_rows";
    }

}
