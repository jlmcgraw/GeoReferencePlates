#!/usr/bin/perl

# Copyright (C) 2014  Jesse McGraw (jlmcgraw@gmail.com)
# Copy georef data from a previous cycle to a new one
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

use DBI;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use File::Basename;
use Getopt::Std;
use Carp;
use File::Copy;
use POSIX;
use Params::Validate qw(:all);

#Call the main routine and exit with its return code
exit main(@ARGV);

sub main {
    my $arg_num = scalar @ARGV;

    #We need at least one argument (the name of the PDF to process)
    if ( $arg_num < 2 ) {
        say "Specify old and new cycles";
        say "eg: $0 1409 1410";
        exit(1);
    }

    my $oldCycle = shift @ARGV;
    my $newCycle = shift @ARGV;

    say "Old Cycle: $oldCycle";
    say "New Cycle: $newCycle";

    #Connect to our databases
    my $oldDbFile = "./dtpp-$oldCycle.db";
    my $oldDbh    = DBI->connect( "dbi:SQLite:dbname=$oldDbFile",
        "", "", { RaiseError => 1 } )
      or croak $DBI::errstr;

    my $newDbFile = "./dtpp-$newCycle.db";
    my $newDbh    = DBI->connect( "dbi:SQLite:dbname=$newDbFile",
        "", "", { RaiseError => 1 } )
      or croak $DBI::errstr;

    #Get the old data
    my $oldDataArrayRef = getOldData($oldDbh);

    #Open an SQL transaction
    $newDbh->begin_work();

    #Copy old georef data to new table
    foreach my $_row (@$oldDataArrayRef) {
        my ( $PDF_NAME, $upperLeftLon, $upperLeftLat, $xMedian, $yMedian,
            $xPixelSkew, $yPixelSkew, $status )
          = @$_row;
        state $rowCount = 0;

        #Older databases sometimes have this as positive, let's convert to negative
        #for the affine transform
        if ( $xMedian && $yMedian > 0 ) {
            say "Converting $yMedian to negative";
            $yMedian = -($yMedian);
        }
        
        #say which row we're on every 1000 rows
        say "Copying row: $rowCount..."
          if ( $rowCount % 1000 == 0 );

        #         say
        #           "$PDF_NAME,$upperLeftLon,$upperLeftLat,$xMedian,$yMedian,$xPixelSkew,$yPixelSkew,$status";

        #Update the georef table
        my $update_dtpp_geo_record =
            "UPDATE dtppGeo " . "SET "
          . "upperLeftLon = ? "
          . ",upperLeftLat = ? "
          . ",xMedian = ? "
          . ",yMedian = ? "
          . ",xPixelSkew = ? "
          . ",yPixelSkew = ? "
          . ",status = ? "
          . "WHERE "
          . "PDF_NAME = ?";

        #In the new database
        my $newSth = $newDbh->prepare($update_dtpp_geo_record);

        $newSth->bind_param( 1, $upperLeftLon );
        $newSth->bind_param( 2, $upperLeftLat );
        $newSth->bind_param( 3, $xMedian );
        $newSth->bind_param( 4, $yMedian );
        $newSth->bind_param( 5, $xPixelSkew );
        $newSth->bind_param( 6, $yPixelSkew );
        $newSth->bind_param( 7, $status );
        $newSth->bind_param( 8, $PDF_NAME );

        $newSth->execute();
        $rowCount++;

        #Pull out the various filename components of the input file from the command line
        my ( $filename, $dir, $ext ) = fileparse( $PDF_NAME, qr/\.[^.]*/x );

        my $storedGcpHash = "gcp-" . $filename . "-hash.txt";

        #Copy existing stored GCP hash to new directory
        if ( -e "./dtpp-$oldCycle/$storedGcpHash" ) {

            copy(
                "./dtpp-$oldCycle/$storedGcpHash",
                "./dtpp-$newCycle/$storedGcpHash"
            ) or die "Copy failed: $!";

            # say "./dtpp-$oldCycle/$storedGcpHash,./dtpp-$newCycle/$storedGcpHash";
            #gcp-00655RY18C-hash.txt
        }
    }

    #Commit copied data
    $newDbh->commit or die $newDbh->errstr;

    $newDbh->begin_work();

    #Get a list of all charts that with status added or changed
    my $newDataArrayRef = getNewChangedAndAddedCharts($newDbh);

    #For each PDF listed as changed or Added set its georef status
    foreach my $_row (@$newDataArrayRef) {
        my ( $PDF_NAME, ) = @$_row;
        state $rowCount = 0;
        say "Clearing status on row: $rowCount..."
          if ( $rowCount % 1000 == 0 );

        my $status = "ADDEDCHANGED";

        # #         say
        #           "$PDF_NAME,$status";

        #Clear the georef status for all charts that are "A"dded or "C"hanged
        #Update the georef table
        my $update_dtpp_geo_record =
            "UPDATE dtppGeo " . "SET "
          . "status = ? "
          . "WHERE "
          . "PDF_NAME = ?";

        my $newSth = $newDbh->prepare($update_dtpp_geo_record);

        $newSth->bind_param( 1, $status );
        $newSth->bind_param( 2, $PDF_NAME );

        $newSth->execute();
        $rowCount++;

    }

    #Commit the cleared statuses
    $newDbh->commit or die $newDbh->errstr;

    return 0;
}

sub getOldData {
    #
    #Validate and set input parameters to this function
    my ($oldDbh) =
      validate_pos( @_, { type => HASHREF } );

    #Get the data we want to save for old IAP and APD charts.  
    #Note that will also select all IAP and APD, not just good ones
    my $oldSth = $oldDbh->prepare( "
    SELECT	
        D.PDF_NAME
       ,DG.upperLeftLon
       ,DG.upperLeftLat
       ,DG.xMedian
       ,DG.yMedian
       ,DG.xPixelSkew
       ,DG.yPixelSkew
       ,DG.status
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
      ;"
    );

    $oldSth->execute();

    #Return the arraryRef
    return ( $oldSth->fetchall_arrayref() );
}

sub getNewChangedAndAddedCharts {
    #
    #Validate and set input parameters to this function
    my ($newDbh) =
      validate_pos( @_, { type => HASHREF } );

    #Find all APD and IAP charts in new database that were changed or added
    my $newSth = $newDbh->prepare( "
     SELECT      
        PDF_NAME
     FROM 
        dtpp
     WHERE  
        ( 
        CHART_CODE = 'IAP'
         OR 
        CHART_CODE = 'APD' 
        )
       AND
       (
        USER_ACTION = 'A'
          OR
        USER_ACTION = 'C'
        )
      ;"
    );

    $newSth->execute();

    #Return the arraryRef
    return ( $newSth->fetchall_arrayref() );
}
