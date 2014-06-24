#!/usr/bin/perl

# GeoRerencePlates - a utility to automatically georeference FAA Instrument Approach Plates / Terminal Procedures
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

#Unavoidable problems:
#-----------------------------------

#-Relies on actual text being in PDF.  It seems that most, if not all, military plates have no text in them
#       We may be able to get around this with tesseract OCR but that will take some work
#
#Known issues:
#---------------------

use 5.010;

use strict;
use warnings;

#use diagnostics;

use PDF::API2;
use DBI;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use File::Basename;
use Getopt::Std;
use Carp;
use Math::Trig;
use Math::Trig qw(great_circle_distance deg2rad great_circle_direction rad2deg);
use Math::Round;
use POSIX;

# use Math::Round;
use Time::HiRes q/gettimeofday/;

#use Math::Polygon;
# use Acme::Tools qw(between);
use Image::Magick;
use File::Slurp;

#PDF constants
use constant mm => 25.4 / 72;
use constant in => 1 / 72;
use constant pt => 1;

#Some subroutines
use GeoReferencePlatesSubroutines;

#Some other constants
#----------------------------------------------------------------------------------------------
#Max allowed radius in PDF points from an icon (obstacle, fix, gps) to its associated textbox's center
our $maxDistanceFromObstacleIconToTextBox = 20;

#DPI of the output PNG
our $pngDpi = 300;

#A hash to collect statistics
our %statistics = (
    '$airportLatitude'                 => "0",
    '$horizontalAndVerticalLinesCount' => "0",
    '$gcpCount'                        => "0",
    '$yMedian'                         => "0",
    '$gpsCount'                        => "0",
    '$targetPdf'                       => "0",
    '$yScaleAvgSize'                   => "0",
    '$airportLongitude'                => "0",
    '$notToScaleIndicatorCount'        => "0",
    '$unique_obstacles_from_dbCount'   => "0",
    '$xScaleAvgSize'                   => "0",
    '$navaidCount'                     => "0",
    '$xMedian'                         => "0",
    '$insetCircleCount'                => "0",
    '$obstacleCount'                   => "0",
    '$insetBoxCount'                   => "0",
    '$fixCount'                        => "0",
    '$yAvg'                            => "0",
    '$xAvg'                            => "0",
    '$pdftotext'                       => "0",
    '$lonLatRatio'                     => "0",
    '$upperLeftLon'                    => "0",
    '$upperLeftLat'                    => "0",
    '$lowerRightLon'                   => "0",
    '$lowerRightLat'                   => "0",
    '$targetLonLatRatio'               => "0",
    '$runwayIconsCount'                => "0"
);

use vars qw/ %opt /;

#Define the valid command line options
my $opt_string = 'cspvobma:i:';
my $arg_num    = scalar @ARGV;

#We need at least one argument (the name of the PDF to process)
if ( $arg_num < 1 ) {
    usage();
    exit(1);
}

#This will fail if we receive an invalid option
unless ( getopts( "$opt_string", \%opt ) ) {
    usage();
    exit(1);
}

#Get the target PDF file from command line options
our ($dtppDirectory) = $ARGV[0];

if ( !-e ($dtppDirectory) ) {
    say "Target dTpp directory $dtppDirectory doesn't exist";
    exit(1);
}

#Default to all airports for the SQL query
our $airportId = "%";
if ( $opt{a} ) {

    #If something  provided on the command line use it instead
    $airportId = $opt{a};
    say "Supplied airport ID: $airportId";
}

#Default to all states for the SQL query
our $stateId = "%";

if ( $opt{i} ) {

    #If something  provided on the command line use it instead
    $stateId = $opt{i};
    say "Supplied state ID: $stateId";
}

our $shouldNotOverwriteVrt      = $opt{c};
our $shouldOutputStatistics     = $opt{s};
our $shouldSaveMarkedPdf        = $opt{p};
our $debug                      = $opt{v};
our $shouldRecreateOutlineFiles = $opt{o};
our $shouldSaveBadRatio         = $opt{b};
our $shouldUseMultipleObstacles = $opt{m};

#database of metadata for dtpp
my $dtppDbh =
     DBI->connect( "dbi:SQLite:dbname=./dtpp.db", "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

#-----------------------------------------------
#Open the locations database
our $dbh;
my $sth;

$dbh = DBI->connect( "dbi:SQLite:dbname=locationinfo.db",
    "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

our (
    $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    $MILITARY_USE, $COPTER_USE,  $STATE_ID
);

$dtppDbh->do("PRAGMA page_size=4096");
$dtppDbh->do("PRAGMA synchronous=OFF");

#Query the dtpp database for charts
my $dtppSth = $dtppDbh->prepare(
    "SELECT  TPP_VOLUME, FAA_CODE, CHART_SEQ, CHART_CODE, CHART_NAME, USER_ACTION, PDF_NAME, FAANFD18_CODE, MILITARY_USE, COPTER_USE, STATE_ID
             FROM dtpp  
             WHERE  
                CHART_CODE = 'APD' 
                AND 
                FAA_CODE LIKE  '$airportId' 
                AND
                STATE_ID LIKE  '$stateId'
                "
);
$dtppSth->execute();

my $_allSqlQueryResults = $dtppSth->fetchall_arrayref();
my $_rows               = $dtppSth->rows;
say "Processing $_rows charts";
my $completedCount = 0;
our $successCount  = 0;
our $failCount     = 0;
our $noTextCount   = 0;
our $noPointsCount = 0;
foreach my $_row (@$_allSqlQueryResults) {

    (
        $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
        $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
        $MILITARY_USE, $COPTER_USE,  $STATE_ID
    ) = @$_row;

    # say      '$TPP_VOLUME, $FAA_CODE, $CHART_SEQ, $CHART_CODE, $CHART_NAME, $USER_ACTION, $PDF_NAME, $FAANFD18_CODE, $MILITARY_USE, $COPTER_USE, $STATE_ID';
    say
      "$TPP_VOLUME, $FAA_CODE, $CHART_SEQ, $CHART_CODE, $CHART_NAME, $USER_ACTION, $PDF_NAME, $FAANFD18_CODE, $MILITARY_USE, $COPTER_USE, $STATE_ID";
    say "$FAA_CODE";
    doAPlate();

    ++$completedCount;
    say
      "Success: $successCount, Fail: $failCount, No Text: $noTextCount, No Points: $noPointsCount, Chart: $completedCount"
      . "/"
      . "$_rows";
}

#Close the charts database
$dtppSth->finish();
$dtppDbh->disconnect();

#Close the locations database
# $sth->finish();
$dbh->disconnect();

exit;

#----------------------------------------------------------------------------------------------------------------

sub doAPlate {

    #Zero out the stats hash
    %statistics = (
        '$airportLatitude'                 => "0",
        '$horizontalAndVerticalLinesCount' => "0",
        '$gcpCount'                        => "0",
        '$yMedian'                         => "0",
        '$gpsCount'                        => "0",
        '$targetPdf'                       => "0",
        '$yScaleAvgSize'                   => "0",
        '$airportLongitude'                => "0",
        '$notToScaleIndicatorCount'        => "0",
        '$unique_obstacles_from_dbCount'   => "0",
        '$xScaleAvgSize'                   => "0",
        '$navaidCount'                     => "0",
        '$xMedian'                         => "0",
        '$insetCircleCount'                => "0",
        '$obstacleCount'                   => "0",
        '$insetBoxCount'                   => "0",
        '$fixCount'                        => "0",
        '$yAvg'                            => "0",
        '$xAvg'                            => "0",
        '$pdftotext'                       => "0",
        '$lonLatRatio'                     => "0",
        '$upperLeftLon'                    => "0",
        '$upperLeftLat'                    => "0",
        '$lowerRightLon'                   => "0",
        '$lowerRightLat'                   => "0",
        '$targetLonLatRatio'               => "0",
        '$runwayIconsCount'                => "0"
    );
    #
    our $targetPdf = $dtppDirectory . $PDF_NAME;

    my $retval;

    #Say what our input PDF is
    say $targetPdf;

    #Pull out the various filename components of the input file from the command line
    our ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

    $airportId = $FAA_CODE;

    #Set some output file names based on the input filename
    our $outputPdf         = $dir . "marked-" . $filename . ".pdf";
    our $outputPdfOutlines = $dir . "outlines-" . $filename . ".pdf";
    our $outputPdfRaw      = $dir . "raw-" . $filename . ".txt";
    our $targetpng         = $dir . $filename . ".png";
    our $gcpPng            = $dir . "gcp-" . $filename . ".png";
    our $targettif         = $dir . $filename . ".tif";

    # our $targetvrt         = $dir . $filename . ".vrt";
    our $targetVrtFile =
      $STATE_ID . "-" . $FAA_CODE . "-" . $PDF_NAME . "-" . $CHART_NAME;

    our $targetVrtFile2 = "warped" . $targetVrtFile;

    # convert spaces, ., and slashes to dash
    $targetVrtFile =~ s/[ |\/|\\|\.]/-/g;
    our $targetVrtBadRatio = $dir . "badRatio-" . $targetVrtFile . ".vrt";
    our $noPointsFile      = $dir . "noPoints-" . $targetVrtFile . ".vrt";
    our $failFile          = $dir . "fail-" . $targetVrtFile . ".vrt";
    our $noTextFile        = $dir . $MILITARY_USE . "noText-" . $targetVrtFile . ".vrt";
    our $targetvrt         = $dir . $targetVrtFile . ".vrt";
    our $targetvrt2        = $dir . $targetVrtFile2 . ".vrt";
    our $targetStatistics  = "./statistics.csv";

    if ($debug) {
        say "Directory: " . $dir;
        say "File:      " . $filename;
        say "Suffix:    " . $ext;
        say "";
        say "TargetPdf: $targetPdf";
        say "OutputPdf: $outputPdf";
        say "TargetPng: $targetpng";
        say "TargetTif: $targettif";
        say "TargetVrt: $targetvrt";
        say "targetStatistics: $targetStatistics";
        say "";
    }

    $statistics{'$targetPdf'} = $targetPdf;

    #This is a quick hack to abort if we've already created a .vrt for this plate
    if ( $shouldNotOverwriteVrt && -e $targetvrt ) {
        say "$targetvrt exists, exiting";
        return (1);
    }

    #Default is portait orientation
    our $isPortraitOrientation = 1;

    #Pull all text out of the PDF
    my @pdftotext;
    @pdftotext = qx(pdftotext $targetPdf  -enc ASCII7 -);
    $retval    = $? >> 8;

    if ( @pdftotext eq "" || $retval != 0 ) {
        say
          "No output from pdftotext.  Is it installed?  Return code was $retval";
        return (1);
    }
    $statistics{'$pdftotext'} = scalar(@pdftotext);

    if ( scalar(@pdftotext) < 5 ) {
        ++$main::noTextCount;

        say "Not enough pdftotext output for $targetPdf";
        writeStatistics() if $shouldOutputStatistics;
        say "Touching $main::noTextFile";
        open( my $fh, ">", "$main::noTextFile" )
          or die "cannot open > $main::noTextFile $!";
        close($fh);
        return;
        return (1);
    }

    #Pull airport location from chart text or, if a name was supplied on command line, from database
    our ( $airportLatitudeDec, $airportLongitudeDec ) =
      findAirportLatitudeAndLongitude();

    our $airportLatitudeDegrees      = floor($airportLatitudeDec);
    our $airportLongitudeDegrees     = floor($airportLongitudeDec);
    our $airportLatitudeDeclination  = $airportLatitudeDec < 0 ? "S" : "N";
    our $airportLongitudeDeclination = $airportLongitudeDec < 0 ? "W" : "E";
    $airportLatitudeDegrees  = abs($airportLatitudeDegrees);
    $airportLongitudeDegrees = abs($airportLongitudeDegrees);

    if ($debug) {
        say
          "$airportLatitudeDegrees $airportLatitudeDeclination, $airportLongitudeDegrees $airportLongitudeDeclination";
    }

    #Get the mediabox size and other variables from the PDF
    our ( $pdfXSize, $pdfYSize, $pdfCenterX, $pdfCenterY, $pdfXYRatio ) =
      getMediaboxSize();

    #Convert the PDF to a PNG if one doesn't already exist
    convertPdfToPng();

    #Get PNG dimensions and the PDF->PNG scale factors
    our ( $pngXSize, $pngYSize, $scaleFactorX, $scaleFactorY, $pngXYRatio ) =
      getPngSize();

    #--------------------------------------------------------------------------------------------------------------
    # #Some regex building blocks to be used elsewhere
    #numbers that start with 1-9 followed by 2 or more digits
    our $obstacleHeightRegex = qr/[1-9]\d{1,}/x;

    #A number with possible decimal point and minus sign
    our $numberRegex = qr/[-\.\d]+/x;

    our $latitudeRegex  = qr/$numberRegex’[N|S]/x;
    our $longitudeRegex = qr/$numberRegex’[E|W]/x;

    #A transform, capturing the X and Y
    our ($transformCaptureXYRegex) =
      qr/q\s1\s0\s0\s1\s+($numberRegex)\s+($numberRegex)\s+cm/x;

    #A transform, not capturing the X and Y
    our ($transformNoCaptureXYRegex) =
      qr/q\s1\s0\s0\s1\s+$numberRegex\s+$numberRegex\s+cm/x;

    #A bezier curve
    our ($bezierCurveRegex) = qr/(?:$numberRegex\s+){6}c/x;

    #A line or path
    our ($lineRegex)          = qr/$numberRegex\s+$numberRegex\s+l/x;
    our ($lineRegexCaptureXY) = qr/($numberRegex)\s+($numberRegex)\s+l/x;

    # my $bezierCurveRegex = qr/(?:$numberRegex\s){6}c/;
    # my $lineRegex        = qr/$numberRegex\s$numberRegex\sl/;

    #Move to the origin
    our ($originRegex) = qr/0\s+0\s+m/x;

    #F*  Fill path
    #S     Stroke path
    #cm Scale and translate coordinate space
    #c      Bezier curve
    #q     Save graphics state
    #Q     Restore graphics state

    #Global variables filled in by the "findAllIcons" subroutine.
    #TODO BUG: At some point I'll convert the subroutines to work with local variables and return values instead
    # our %icons                      = ();
    # our %obstacleIcons              = ();
    # our %fixIcons                   = ();
    # our %gpsWaypointIcons           = ();
    # our %navaidIcons                = ();
    # our %horizontalAndVerticalLines = ();
    our %latitudeAndLongitudeLines = ();

    # our %insetBoxes                 = ();
    # our %largeBoxes                 = ();
    # our %insetCircles               = ();
    # our %notToScaleIndicator        = ();
    # our %runwayIcons                = ();
    # our %runwaysFromDatabase        = ();
    # our %runwaysToDraw              = ();
    # our @validRunwaySlopes          = ();

    #Look up runways for this airport from the database and populate the array of slopes we're looking for for runway lines
    # findRunwaysInDatabase();

    # say "runwaysFromDatabase";
    # print Dumper ( \%runwaysFromDatabase );
    # say "";

    # #Get number of objects/streams in the targetpdf
    our $objectstreams = getNumberOfStreams();
    our @pdfToTextBbox = ();

    
    our %latitudeTextBoxes  = ();
    our %longitudeTextBoxes = ();

    #Loop through each of the streams in the PDF and find all of the icons we're interested in
    findAllIcons(); 
#Loop through each of the streams in the PDF and find all of the textboxes we're interested in
    findAllTextboxes();

    #----------------------------------------------------------------------------------------------------------
    #Modify the PDF
    #Don't do anything PDF related unless we've asked to create one on the command line

    our ( $pdf, $page );

    if ($shouldSaveMarkedPdf) {
        $pdf = PDF::API2->open($targetPdf);

        #Set up the various types of boxes to draw on the output PDF
        $page = $pdf->openpage(1);

    }

    our ( $pdfOutlines,  $pageOutlines );
    our ( $lowerYCutoff, $upperYCutoff );

    #Don't recreate the outlines PDF if it already exists unless the user specifically wants to
    if ( !-e $outputPdfOutlines || $shouldRecreateOutlineFiles ) {

        # createOutlinesPdf();
    }

    #---------------------------------------------------
    #Convert the outlines PDF to a PNG
    our ( $image, $perlMagickStatus );

    # #Draw boxes around the icons and textboxes we've found so far
    outlineEverythingWeFound() if $shouldSaveMarkedPdf;

    our %gcps = ();

    my $latitudeLineOrientation  = "horizontal";
    my $longitudeLineOrientation = "vertical";

    #the orientation is being determined withing the textbox finding routines for now
    if ( !$isPortraitOrientation ) {
        say "Setting orientation to landscape";
        $latitudeLineOrientation  = "vertical";
        $longitudeLineOrientation = "horizontal";
    }

    #----------------------------------------------------------------------------------------------------------------------------------
    #Everything to do with latitude
    #Match a line to a textbox
    findClosestLineToTextBox( \%latitudeTextBoxes, \%latitudeAndLongitudeLines,
        $latitudeLineOrientation );

    if ($debug) {
        say "latitudeTextBoxes";

        # print Dumper ( \%latitudeAndLongitudeLines );
        print Dumper ( \%latitudeTextBoxes );
    }

    #Draw a line from obstacle icon to closest text boxes
    if ($shouldSaveMarkedPdf) {
        drawLineFromEachIconToMatchedTextBox( \%latitudeTextBoxes,
            \%latitudeAndLongitudeLines );

    }

    #----------------------------------------------------------------------------------------------------------------------------------
    #Everything to do with longitude

    #Match a line to a textbox
    findClosestLineToTextBox( \%longitudeTextBoxes,
        \%latitudeAndLongitudeLines, $longitudeLineOrientation );

    if ($debug) {
        say "longitudeTextBoxes";

        # print Dumper ( \%latitudeAndLongitudeLines );
        print Dumper ( \%longitudeTextBoxes );
    }

    #Draw a line from obstacle icon to closest text boxes
    if ($shouldSaveMarkedPdf) {
        drawLineFromEachIconToMatchedTextBox( \%longitudeTextBoxes,
            \%latitudeAndLongitudeLines );
    }

    findIntersectionOfLatLonLines( \%latitudeTextBoxes, \%longitudeTextBoxes,
        \%latitudeAndLongitudeLines );

    #build the GCP portion of the command line parameters
    our $gcpstring = createGcpString();

    #outline the GCP points we ended up using
    drawCircleAroundGCPs() if $shouldSaveMarkedPdf;

    #Make sure we have enough GCPs
    my $gcpCount = scalar( keys(%gcps) );
    say "Found $gcpCount potential Ground Control Points" if $debug;

    #Save statistics
    $statistics{'$gcpCount'} = $gcpCount;

    if ($shouldSaveMarkedPdf) {
        $pdf->saveas($outputPdf);
    }

    #----------------------------------------------------------------------------------------------------------------------------------------------------
    #Now some math
    our ( @xScaleAvg, @yScaleAvg, @ulXAvg, @ulYAvg, @lrXAvg, @lrYAvg ) = ();

    our ( $xAvg,    $xMedian,   $xStdDev )   = 0;
    our ( $yAvg,    $yMedian,   $yStdDev )   = 0;
    our ( $ulXAvrg, $ulXmedian, $ulXStdDev ) = 0;
    our ( $ulYAvrg, $ulYmedian, $ulYStdDev ) = 0;
    our ( $lrXAvrg, $lrXmedian, $lrXStdDev ) = 0;
    our ( $lrYAvrg, $lrYmedian, $lrYStdDev ) = 0;
    our ($lonLatRatio) = 0;

    #Can't do anything if we didn't find any valid ground control points
    if ( $gcpCount < 2 ) {
        say
          "Only found $gcpCount ground control points in $targetPdf, can't georeference";
        say "Touching $noPointsFile";
        open( my $fh, ">", "$noPointsFile" )
          or die "cannot open > $noPointsFile: $!";
        close($fh);

        # say          "xScaleAvgSize: $statistics{'$xScaleAvgSize'}, yScaleAvgSize: $statistics{'$yScaleAvgSize'}";

        #touch($noPointsFile);
        ++$main::noPointsCount;
        writeStatistics() if $shouldOutputStatistics;
        return (1);
    }

    #Actually produce the georeferencing data via GDAL
    georeferenceTheRaster();

    #Count of entries in this array
    my $xScaleAvgSize = 0 + @xScaleAvg;

    #Count of entries in this array
    my $yScaleAvgSize = 0 + @yScaleAvg;

    # say "xScaleAvgSize: $xScaleAvgSize, yScaleAvgSize: $yScaleAvgSize";

    #Save statistics
    $statistics{'$xAvg'}          = $xAvg;
    $statistics{'$xMedian'}       = $xMedian;
    $statistics{'$xScaleAvgSize'} = $xScaleAvgSize;
    $statistics{'$yAvg'}          = $yAvg;
    $statistics{'$yMedian'}       = $yMedian;
    $statistics{'$yScaleAvgSize'} = $yScaleAvgSize;
    $statistics{'$lonLatRatio'}   = $lonLatRatio;

    # }
    # else {
    # say
    # "No points actually added to the scale arrays for $targetPdf, can't georeference";

    # say "Touching $noPointsFile";

    # open( my $fh, ">", "$noPointsFile" )
    # or die "cannot open > $noPointsFile: $!";
    # close($fh);
    # }

    #Write out the statistics of this file if requested
    writeStatistics() if $shouldOutputStatistics;

    #Since we've calculated our extents, try drawing some features on the outputPdf to see if they align
    #With our work
    # drawFeaturesOnPdf() if $shouldSaveMarkedPdf;

    # say "TargetLonLatRatio: "
    # . $statistics{'$targetLonLatRatio'}
    # . ",  LonLatRatio: $lonLatRatio , Difference: "
    # . ( $statistics{'$targetLonLatRatio'} - $lonLatRatio );

    return;
}

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------

sub findAirportLatitudeAndLongitude {

    #Get the lat/lon of the airport for the plate we're working on

    my $_airportLatitudeDec  = "";
    my $_airportLongitudeDec = "";

    # foreach my $line (@pdftotext) {

    # #Remove all the whitespace and non-word characters
    # $line =~ s/\s|\W//g;

    # # if ( $line =~ m/(\d+)'([NS])\s?-\s?(\d+)'([EW])/ ) {
    # #   if ( $line =~ m/([\d ]+)'([NS])\s?-\s?([\d ]+)'([EW])/ ) {
    # if ( $line =~ m/([\d]{3,4})([NS])([\d]{3,5})([EW])/ ) {
    # my (
    # $aptlat,    $aptlon,    $aptlatd,   $aptlond,
    # $aptlatdeg, $aptlatmin, $aptlondeg, $aptlonmin
    # );
    # $aptlat  = $1;
    # $aptlatd = $2;
    # $aptlon  = $3;
    # $aptlond = $4;

    # $aptlatdeg = substr( $aptlat, 0,  -2 );
    # $aptlatmin = substr( $aptlat, -2, 2 );

    # $aptlondeg = substr( $aptlon, 0,  -2 );
    # $aptlonmin = substr( $aptlon, -2, 2 );

    # $_airportLatitudeDec =
    # &coordinatetodecimal(
    # $aptlatdeg . "-" . $aptlatmin . "-00" . $aptlatd );

    # $_airportLongitudeDec =
    # &coordinatetodecimal(
    # $aptlondeg . "-" . $aptlonmin . "-00" . $aptlond );

    # say
    # "Airport LAT/LON from plate: $aptlatdeg-$aptlatmin-$aptlatd, $aptlondeg-$aptlonmin-$aptlond->$_airportLatitudeDec $_airportLongitudeDec"
    # if $debug;

    # }

    # }

    if ( $_airportLongitudeDec eq "" or $_airportLatitudeDec eq "" ) {

        #We didn't get any airport info from the PDF, let's check the database
        #Get airport from database
        if ( !$airportId ) {
            say
              "You must specify an airport ID (eg. -a SMF) since there was no info found in $main::targetPdf";
            return (1);
        }

        #Query the database for airport
        my $sth = $dbh->prepare(
            "SELECT  FaaID, Latitude, Longitude, Name  FROM airports  WHERE  FaaID = '$airportId'"
        );
        $sth->execute();
        my $_allSqlQueryResults = $sth->fetchall_arrayref();

        foreach my $_row (@$_allSqlQueryResults) {
            my ( $airportFaaId, $airportname );
            (
                $airportFaaId, $_airportLatitudeDec, $_airportLongitudeDec,
                $airportname
            ) = @$_row;
            if ($debug) {
                say "Airport ID: $airportFaaId";
                say "Airport Latitude: $_airportLatitudeDec";
                say "Airport Longitude: $_airportLongitudeDec";
                say "Airport Name: $airportname";
            }
        }
        if ( $_airportLongitudeDec eq "" or $_airportLatitudeDec eq "" ) {
            say
              "No airport coordinate information found for $airportId in $main::targetPdf  or database";
            return (1);
        }

    }

    #Save statistics
    $statistics{'$airportLatitude'}  = $_airportLatitudeDec;
    $statistics{'$airportLongitude'} = $_airportLongitudeDec;

    return ( $_airportLatitudeDec, $_airportLongitudeDec );
}

sub getMediaboxSize {

    #Get the mediabox size from the PDF
    my $mutoolinfo = qx(mutool info $main::targetPdf);
    my $retval     = $? >> 8;
    die "No output from mutool info.  Is it installed? Return code was $retval"
      if ( $mutoolinfo eq "" || $retval != 0 );

    foreach my $line ( split /[\r\n]+/, $mutoolinfo ) {
        ## Regular expression magic to grab what you want
        if ( $line =~ /([-\.0-9]+) ([-\.0-9]+) ([-\.0-9]+) ([-\.0-9]+)/ ) {
            my $_pdfXSize   = $3 - $1;
            my $_pdfYSize   = $4 - $2;
            my $_pdfCenterX = $_pdfXSize / 2;
            my $_pdfCenterY = $_pdfYSize / 2;
            my $_pdfXYRatio = $_pdfXSize / $_pdfYSize;
            if ($debug) {
                say "PDF Mediabox size: " . $_pdfXSize . "x" . $_pdfYSize;
                say "PDF Mediabox center: " . $_pdfCenterX . "x" . $_pdfCenterY;
                say "PDF X/Y Ratio: " . $_pdfXYRatio;
            }
            return (
                $_pdfXSize,   $_pdfYSize, $_pdfCenterX,
                $_pdfCenterY, $_pdfXYRatio
            );
        }
    }
    return;
}

sub getPngSize {

    #Calculate the raster size ourselves
    my $_pngXSize = ceil( ( $main::pdfXSize / 72 ) * $pngDpi );
    my $_pngYSize = ceil( ( $main::pdfYSize / 72 ) * $pngDpi );

    #This calls the file utility to determine raster size
    # #Find the dimensions of the PNG
    # my $fileoutput = qx(file $targetpng );
    # my $_retval    = $? >> 8;
    # die "No output from file.  Is it installed? Return code was $_retval"
    # if ( $fileoutput eq "" || $_retval != 0 );

    # foreach my $line ( split /[\r\n]+/, $fileoutput ) {
    # ## Regular expression magic to grab what you want
    # if ( $line =~ /([-\.0-9]+)\s+x\s+([-\.0-9]+)/ ) {
    # $_pngXSize = $1;
    # $_pngYSize = $2;
    # }
    # }

    #Calculate the ratios of the PNG/PDF coordinates
    my $_scaleFactorX = $_pngXSize / $main::pdfXSize;
    my $_scaleFactorY = $_pngYSize / $main::pdfYSize;
    my $_pngXYRatio   = $_pngXSize / $_pngYSize;

    if ($debug) {
        say "PNG size: " . $_pngXSize . "x" . $_pngYSize;
        say "Scalefactor PDF->PNG X:  " . $_scaleFactorX;
        say "Scalefactor PDF->PNG Y:  " . $_scaleFactorY;
        say "PNG X/Y Ratio:  " . $_pngXYRatio;
    }
    return ( $_pngXSize, $_pngYSize, $_scaleFactorX, $_scaleFactorY,
        $_pngXYRatio );

}

sub getNumberOfStreams {

    #Get number of objects/streams in the targetpdf

    my $_mutoolShowOutput = qx(mutool show $main::targetPdf x);
    my $retval            = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $_mutoolShowOutput eq "" || $retval != 0 );

    my $_objectstreams;

    foreach my $line ( split /[\r\n]+/, $_mutoolShowOutput ) {
        ## Regular expression magic to grab what you want
        if ( $line =~ /^(\d+)\s+(\d+)$/ ) {
            $_objectstreams = $2;
        }
    }
    if ($debug) {
        say "Object streams: " . $_objectstreams;
    }
    return $_objectstreams;
}

sub outlineEverythingWeFound {
    say ":outlineEverythingWeFound" if $debug;

    #Draw the various types of boxes on the output PDF

    my %font = (
        Helvetica => {
            Bold => $main::pdf->corefont(
                'Helvetica-Bold', -encoding => 'latin1'
            ),

            #      Roman  => $pdf->corefont('Helvetica',         -encoding => 'latin1'),
            #      Italic => $pdf->corefont('Helvetica-Oblique', -encoding => 'latin1'),
        },
        Times => {

            #      Bold   => $pdf->corefont('Times-Bold',        -encoding => 'latin1'),
            Roman => $main::pdf->corefont( 'Times', -encoding => 'latin1' ),

            #      Italic => $pdf->corefont('Times-Italic',      -encoding => 'latin1'),
        },
    );
    foreach my $key ( sort keys %main::latitudeTextBoxes ) {
        my ($latitudeTextBox) = $main::page->gfx;
        $latitudeTextBox->strokecolor('red');
        $latitudeTextBox->linewidth(1);
        $latitudeTextBox->rect(
            $main::latitudeTextBoxes{$key}{"CenterX"} -
              ( $main::latitudeTextBoxes{$key}{"Width"} / 2 ),
            $main::latitudeTextBoxes{$key}{"CenterY"} -
              ( $main::latitudeTextBoxes{$key}{"Height"} / 2 ),
            $main::latitudeTextBoxes{$key}{"Width"},
            $main::latitudeTextBoxes{$key}{"Height"}
        );
        $latitudeTextBox->stroke;
    }
    foreach my $key ( sort keys %main::longitudeTextBoxes ) {
        my ($longitudeTextBox) = $main::page->gfx;
        $longitudeTextBox->strokecolor('yellow');
        $longitudeTextBox->linewidth(1);
        $longitudeTextBox->rect(
            $main::longitudeTextBoxes{$key}{"CenterX"} -
              ( $main::longitudeTextBoxes{$key}{"Width"} / 2 ),
            $main::longitudeTextBoxes{$key}{"CenterY"} -
              ( $main::longitudeTextBoxes{$key}{"Height"} / 2 ),
            $main::longitudeTextBoxes{$key}{"Width"},
            $main::longitudeTextBoxes{$key}{"Height"}
        );
        $longitudeTextBox->stroke;
    }
    foreach my $key ( sort keys %main::latitudeAndLongitudeLines ) {

        my ($lines) = $main::page->gfx;
        $lines->strokecolor('orange');
        $lines->linewidth(2);
        $lines->move(
            $main::latitudeAndLongitudeLines{$key}{"X"},
            $main::latitudeAndLongitudeLines{$key}{"Y"}
        );
        $lines->line(
            $main::latitudeAndLongitudeLines{$key}{"X2"},
            $main::latitudeAndLongitudeLines{$key}{"Y2"}
        );

        $lines->stroke;
    }

}

sub findAllIcons {
    say ":findAllIcons" if $debug;
    my ($_output);

    #Loop through each "stream" in the pdf looking for our various icon regexes
    for ( my $i = 0 ; $i < ( $main::objectstreams - 1 ) ; $i++ ) {
        $_output = qx(mutool show $main::targetPdf $i x);
        my $retval = $? >> 8;

        if ( $_output eq "" || $retval != 0 ) {
            say
              "No output from mutool show.  Is it installed? Return code was $retval";
            return;
        }

        print "Stream $i: " if $debug;

        # findIlsIcons( \%icons, $_output );
        # findObstacleIcons($_output);
        # findFixIcons($_output);

        # findGpsWaypointIcons($_output);
        # findGpsWaypointIcons($_output);
        # findNavaidIcons($_output);

        #findFinalApproachFixIcons($_output);
        #findVisualDescentPointIcons($_output);
        findLatitudeAndLongitudeLines($_output);
        findLatitudeAndLongitudeTextBoxes($_output);

        # findHorizontalAndVerticalLines($_output);
        # findInsetBoxes($_output);
        # findLargeBoxes($_output);
        # findInsetCircles($_output);
        # findNotToScaleIndicator($_output);
        # findRunwayIcons($_output);
        say "" if $debug;
    }

    # if ($debug) {
    # say "";
    # say "obstacleIcons:";
    # print Dumper ( \%obstacleIcons );
    # say "fixIcons";
    # print Dumper ( \%fixIcons );
    # say "%gpsWaypointIcons:";
    # print Dumper ( \%gpsWaypointIcons );
    # say "navaidIcons:";
    # print Dumper ( \%navaidIcons );
    # say "notToScaleIndicators:";
    # print Dumper ( \%notToScaleIndicators );
    # say "runwayIcons";
    # print Dumper ( \%runwayIcons );
    # return;
    # }
    return;
}

# sub returnRawPdf {

# #Returns the raw commands of a PDF
# say ":returnRawPdf" if $debug;
# my ($_output);

# if ( -e $main::outputPdfRaw ) {

# #If the raw output already exists just read it and return
# $_output = read_file($main::outputPdfRaw);
# }
# else {
# #create, save for future use, and return raw PDF output
# open( my $fh, '>', $main::outputPdfRaw )
# or die "Could not open file '$main::outputPdfRaw' $!";

# #Get number of objects/streams in the targetpdf
# my $_objectstreams = getNumberOfStreams();

# #Loop through each "stream" in the pdf and get the raw commands
# for ( my $i = 0 ; $i < ( $_objectstreams - 1 ) ; $i++ ) {
# $_output = $_output . qx(mutool show $main::targetPdf $i x);
# my $retval = $? >> 8;
# die
# "No output from mutool show.  Is it installed? Return code was $retval"
# if ( $_output eq "" || $retval != 0 );
# }

# #Write it out for future use
# print $fh $_output;
# close $fh;

# }

# #Return a reference to the output
# return \$_output;
# }

# sub findClosestBToA {

# #Find the closest B icon to each A

# my ( $hashRefA, $hashRefB ) = @_;

# #Maximum distance in points between centers
# my $maxDistance = 115;

# # say "findClosest $hashRefB to each $hashRefA" if $debug;

# foreach my $key ( sort keys %$hashRefA ) {

# #Start with a very high number so initially is closer than it
# my $distanceToClosest = 999999999999;

# # #Ignore entries that already have a bidir match
# # next if  $hashRefA->{$key}{"BidirectionalMatch"}= "True";

# foreach my $key2 ( sort keys %$hashRefB ) {

# # #Ignore entries that already have a bidir match
# # next if $hashRefB->{$key2}{"BidirectionalMatch"}= "True";

# my $distanceToBX =
# $hashRefB->{$key2}{"CenterX"} - $hashRefA->{$key}{"CenterX"};
# my $distanceToBY =
# $hashRefB->{$key2}{"CenterY"} - $hashRefA->{$key}{"CenterY"};

# my $hypotenuse = sqrt( $distanceToBX**2 + $distanceToBY**2 );

# #Ignore this textbox if it's further away than our max distance variables
# next
# if (
# (
# $hypotenuse > $maxDistance
# || $hypotenuse > $distanceToClosest
# )
# );

# #Update the distance to the closest obstacleTextBox center
# $distanceToClosest = $hypotenuse;

# #Set the "name" of this obstacleIcon to the text from obstacleTextBox
# #This is where we kind of guess (and can go wrong) since the closest height text is often not what should be associated with the icon
# # $hashRefA->{$key}{"Name"}     = $hashRefB->{$key2}{"Text"};
# #$hashRefA->{$key}{"TextBoxX"} = $hashRefB->{$key2}{"CenterX"};
# #$hashRefA->{$key}{"TextBoxY"} = $hashRefB->{$key2}{"CenterY"};
# $hashRefA->{$key}{"MatchedTo"} = $key2;
# }

# }
# if ($debug) {
# say "$hashRefA";
# print Dumper ($hashRefA);
# say "";
# say "$hashRefB";
# print Dumper ($hashRefB);
# }

# return;
# }

sub findClosestLineToTextBox {

    #Find the closest line of preferredOrientation to this textbox

    my ( $hashRefTextBox, $hashRefLine, $preferredOrientation ) = @_;
    say ":findClosestLineToTextBox" if $debug;

    #Maximum distance in points between textbox center and line endpoint
    my $maxDistance = 70;

    # say "findClosest $hashRefLine to each $hashRefTextBox" if $debug;

    foreach my $key ( sort keys %$hashRefTextBox ) {

        #Start with a very high number so initially everything is closer than it
        my $distanceToClosest = 999999999999;

        foreach my $key2 ( sort keys %$hashRefLine ) {

            #The X distance from the textbox center to each endpoint X coordinate
            my $distanceToLineX =
              $hashRefLine->{$key2}{"X"} - $hashRefTextBox->{$key}{"CenterX"};
            my $distanceToLineX2 =
              $hashRefLine->{$key2}{"X2"} - $hashRefTextBox->{$key}{"CenterX"};

            #The Y distance from the textbox center to each endpoint Y coordinate
            my $distanceToLineY =
              $hashRefLine->{$key2}{"Y"} - $hashRefTextBox->{$key}{"CenterY"};
            my $distanceToLineY2 =
              $hashRefLine->{$key2}{"Y2"} - $hashRefTextBox->{$key}{"CenterY"};

            #Calculate the distance to each endpoint of the line
            my $hypotenuse = sqrt( $distanceToLineX**2 + $distanceToLineY**2 );
            my $hypotenuse2 =
              sqrt( $distanceToLineX2**2 + $distanceToLineY2**2 );

            # say "$hypotenuse, $hypotenuse2";
            #Prefer whichever endpoint is closest
            if ( $hypotenuse2 < $hypotenuse ) {
                $hypotenuse = $hypotenuse2;
            }

            my $lineSlope = $hashRefLine->{$key2}{"Slope"};
            $lineSlope = $lineSlope % 180;

            #We can adjust our tolerance to rotation here
            #I think most civilian diagrams are either True North up or rotated 90 degrees
            #I know at least one military plate, KSUU, is rotated arbitrarily
            if ( $preferredOrientation =~ m/vertical/ ) {

                #Skip this line if it's horizontal
                # if ( ( $lineSlope < 45 ) || ( $lineSlope > 135 ) ) {
                if ( ( $lineSlope < 88 ) || ( $lineSlope > 92 ) ) {
                    say
                      "Wanted vertical but this line is horizontal, lineSlope: $lineSlope, preferredOrientation: $preferredOrientation"
                      if $debug;
                    next;
                }
            }
            elsif ( $preferredOrientation =~ m/horizontal/ ) {

                #Skip this line if  it's vertical
                # if ( ( $lineSlope > 45 ) && ( $lineSlope < 135 ) ) {
                if ( ( $lineSlope > 2 ) && ( $lineSlope < 178 ) ) {
                    say
                      "Wanted horizontal but this line is vertical,lineSlope: $lineSlope, preferredOrientation: $preferredOrientation"
                      if $debug;
                    next;
                }
            }
            else {
                say "Unrecognized orientation";
                next;
            }

            #Ignore this textbox if it's further away than our max distance variables
            next
              if (
                (
                       $hypotenuse > $maxDistance
                    || $hypotenuse > $distanceToClosest
                )
              );

            #Update the distance to the closest line endpoint
            $distanceToClosest = $hypotenuse;
            $hashRefTextBox->{$key}{"MatchedTo"} = $key2;

            # $hashRefLine->{$key2}{"MatchedTo"}   = $key;
        }

    }
    if ($debug) {

        # print Dumper ($hashRefTextBox);
        # say "";
        # say "$hashRefLine";
        # print Dumper ($hashRefLine);
    }

    return;
}

sub findLatitudeAndLongitudeLines {
    my ($_output) = @_;
    say ":findLatitudeAndLongitudeLines" if $debug;

    #KRIC does this
    # q 1 0 0 1 74.5 416.44 cm
    # 0 0 m
    # -0.03 -181.62 l
    # -0.05 -362.98 l
    # S
    # Q
    #
    #REGEX building blocks

    #A line
    my $lineRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^S$
^Q$/m;

    my @tempLine = $_output =~ /$lineRegex/ig;

    my $tempLineLength = 0 + @tempLine;
    my $tempLineCount  = $tempLineLength / 4;

    if ( $tempLineLength >= 4 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempLineLength ; $i = $i + 4 ) {

            #Let's only save long lines
            my $distanceHorizontal = $tempLine[ $i + 2 ];
            my $distanceVertical   = $tempLine[ $i + 3 ];

            my $hypotenuse =
              sqrt( $distanceHorizontal**2 + $distanceVertical**2 );

            # say "$distanceHorizontal,$distanceVertical,$hypotenuse";
            #Was 3, change back if trouble TODO BUG
            next if ( abs( $hypotenuse < 3 ) );

            my $_X  = $tempLine[$i];
            my $_Y  = $tempLine[ $i + 1 ];
            my $_X2 = $_X + $tempLine[ $i + 2 ];
            my $_Y2 = $_Y + $tempLine[ $i + 3 ];

            #put them into a hash
            $main::latitudeAndLongitudeLines{ $i . $random }{"X"}  = $_X;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y"}  = $_Y;
            $main::latitudeAndLongitudeLines{ $i . $random }{"X2"} = $_X2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y2"} = $_Y2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterX"} =
              ( $_X + $_X2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterY"} =
              ( $_Y + $_Y2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} =
              round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
        }

    }
    my $lineRegex2 = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^S$
^Q$/m;

    @tempLine = $_output =~ /$lineRegex2/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / 6;

    if ( $tempLineLength >= 6 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempLineLength ; $i = $i + 6 ) {

            #Let's only save long lines
            my $distanceHorizontal = $tempLine[ $i + 4 ];
            my $distanceVertical   = $tempLine[ $i + 5 ];

            my $hypotenuse =
              sqrt( $distanceHorizontal**2 + $distanceVertical**2 );

            # say "$distanceHorizontal,$distanceVertical,$hypotenuse";
            next if ( abs( $hypotenuse < 35 ) );

            my $_X  = $tempLine[$i];
            my $_Y  = $tempLine[ $i + 1 ];
            my $_X2 = $_X + $distanceHorizontal;
            my $_Y2 = $_Y + $distanceVertical;

            #put them into a hash
            $main::latitudeAndLongitudeLines{ $i . $random }{"X"}  = $_X;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y"}  = $_Y;
            $main::latitudeAndLongitudeLines{ $i . $random }{"X2"} = $_X2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y2"} = $_Y2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterX"} =
              ( $_X + $_X2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterY"} =
              ( $_Y + $_Y2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} =
              round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
        }

    }

    my $lineRegex3 = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^S$
^Q$/m;

    @tempLine = $_output =~ /$lineRegex3/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / 8;

    if ( $tempLineLength >= 8 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempLineLength ; $i = $i + 8 ) {

            #Let's only save long lines
            my $distanceHorizontal = $tempLine[ $i + 6 ];
            my $distanceVertical   = $tempLine[ $i + 7 ];

            my $hypotenuse =
              sqrt( $distanceHorizontal**2 + $distanceVertical**2 );

            # say "$distanceHorizontal,$distanceVertical,$hypotenuse";
            next if ( abs( $hypotenuse < 10 ) );

            my $_X  = $tempLine[$i];
            my $_Y  = $tempLine[ $i + 1 ];
            my $_X2 = $_X + $distanceHorizontal;
            my $_Y2 = $_Y + $distanceVertical;

            #put them into a hash
            $main::latitudeAndLongitudeLines{ $i . $random }{"X"}  = $_X;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y"}  = $_Y;
            $main::latitudeAndLongitudeLines{ $i . $random }{"X2"} = $_X2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y2"} = $_Y2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterX"} =
              ( $_X + $_X2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterY"} =
              ( $_Y + $_Y2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} =
              round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
        }

    }

    my $lineRegex4 = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^($main::numberRegex)\s+($main::numberRegex)\s+l$
^S$
^Q$/m;

    @tempLine = $_output =~ /$lineRegex4/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / 10;

    if ( $tempLineLength >= 10 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempLineLength ; $i = $i + 10 ) {

            #Let's only save long lines
            my $distanceHorizontal = $tempLine[ $i + 8 ];
            my $distanceVertical   = $tempLine[ $i + 9 ];

            my $hypotenuse =
              sqrt( $distanceHorizontal**2 + $distanceVertical**2 );

            # say "$distanceHorizontal,$distanceVertical,$hypotenuse";
            next if ( abs( $hypotenuse < 300 ) );

            my $_X  = $tempLine[$i];
            my $_Y  = $tempLine[ $i + 1 ];
            my $_X2 = $_X + $distanceHorizontal;
            my $_Y2 = $_Y + $distanceVertical;

            #put them into a hash
            $main::latitudeAndLongitudeLines{ $i . $random }{"X"}  = $_X;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y"}  = $_Y;
            $main::latitudeAndLongitudeLines{ $i . $random }{"X2"} = $_X2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Y2"} = $_Y2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterX"} =
              ( $_X + $_X2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"CenterY"} =
              ( $_Y + $_Y2 ) / 2;
            $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} =
              round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
        }

    }

    # print Dumper ( \%main::latitudeAndLongitudeLines ) if $debug;

    my $latitudeAndLongitudeLinesCount =
      keys(%main::latitudeAndLongitudeLines);

    #Save statistics
    $statistics{'$latitudeAndLongitudeLinesCount'} =
      $latitudeAndLongitudeLinesCount;

    if ($debug) {
        print "$latitudeAndLongitudeLinesCount Lines ";

    }

    #-----------------------------------

    return;
}

sub convertPdfToPng {

    #---------------------------------------------------
    #Convert the PDF to a PNG
    my $pdfToPpmOutput;
    if ( -e $main::targetpng ) {
        say "$main::targetpng already exists" if $debug;
        return;
    }
    $pdfToPpmOutput =
      qx(pdftoppm -png -r $pngDpi $main::targetPdf > $main::targetpng);

    my $retval = $? >> 8;
    die "Error from pdftoppm.   Return code is $retval" if $retval != 0;
    return;
}

sub findLatitudeTextBoxes2 {
    # return;
    my ($_output) = @_;
    say ":findLatitudeTextBoxes2" if $debug;

    my $latitudeTextBoxRegex1 =
      qr/^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::latitudeRegex)<\/word>$/m;

    my $latitudeTextBoxRegex1DataPoints = 5;
    my @tempLine = $_output =~ /$latitudeTextBoxRegex1/ig;

    my $tempLineLength = 0 + @tempLine;
    my $tempLineCount  = $tempLineLength / $latitudeTextBoxRegex1DataPoints;

    if ( $tempLineLength >= $latitudeTextBoxRegex1DataPoints ) {

        # say "Found $tempLineCount possible latitudeTextBoxes";
        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $latitudeTextBoxRegex1DataPoints
          )
        {
            my $rand = rand();
            my $xMin = $tempLine[$i];
            my $yMin = $tempLine[ $i + 1 ];
            my $xMax = $tempLine[ $i + 2 ];
            my $yMax = $tempLine[ $i + 3 ];
            my $text = $tempLine[ $i + 4 ];

            my $height = $yMax - $yMin;
            my $width  = $xMax - $xMin;

            my @tempText    = $text =~ m/^(\d{2,})(\d\d\.?\d?).+([N|S])$/ig;
            my $degrees     = $tempText[0];
            my $minutes     = $tempText[1];
            my $seconds     = 0;
            my $declination = $tempText[2];

            my $decimal;
            next unless ( $degrees && $minutes && $declination );
            say
              "LatRegex1: Degrees: $degrees, minutes: $minutes, declination: $declination && $main::airportLongitudeDegrees, airportLongitudeDeclination, $main::airportLongitudeDeclination"
              if $debug;
            $decimal =
              coordinatetodecimal2( $degrees, $minutes, $seconds,
                $declination );
            say
              "Degrees: $degrees, Minutes $minutes, declination:$declination ->$decimal"
              if $debug;

            next unless $decimal;

            $main::latitudeTextBoxes{ $i . $rand }{"Width"}   = $width;
            $main::latitudeTextBoxes{ $i . $rand }{"Height"}  = $height;
            $main::latitudeTextBoxes{ $i . $rand }{"Text"}    = $text;
            $main::latitudeTextBoxes{ $i . $rand }{"Decimal"} = $decimal;
            $main::latitudeTextBoxes{ $i . $rand }{"CenterX"} =
              $xMin + ( $width / 2 );
            $main::latitudeTextBoxes{ $i . $rand }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );

            # $main::latitudeTextBoxes{ $i . $rand }{"IconsThatPointToMe"} = 0;
        }
    }

    # #TODO for portait oriented diagrams
    # #2 line version
    # # <word xMin="75.043300" yMin="482.701543" xMax="81.676718" yMax="486.912643">82</word>
    # # <word xMin="84.993427" yMin="482.701543" xMax="105.072785" yMax="486.912643">33.0’W</word>

    # #TODO Check against known degrees and declination
    my $latitudeTextBoxRegex2 =
      qr/^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">(\d{1,2})<\/word>$
^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex).+([N|S])<\/word>$/m;

    my $latitudeTextBoxRegex2DataPoints = 11;
    @tempLine = $_output =~ /$latitudeTextBoxRegex2/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / $latitudeTextBoxRegex2DataPoints;

    if ( $tempLineLength >= $latitudeTextBoxRegex2DataPoints ) {

        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $latitudeTextBoxRegex2DataPoints
          )
        {

            my $rand = rand();

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $xMin  = $tempLine[$i];
            my $xMin2 = $tempLine[ $i + 5 ];

            my $yMin  = $tempLine[ $i + 1 ];
            my $yMin2 = $tempLine[ $i + 6 ];

            my $xMax  = $tempLine[ $i + 2 ];
            my $xMax2 = $tempLine[ $i + 7 ];

            my $yMax  = $tempLine[ $i + 3 ];
            my $yMax2 = $tempLine[ $i + 8 ];

            my $degrees     = $tempLine[ $i + 4 ];
            my $minutes     = $tempLine[ $i + 9 ];
            my $seconds     = 0;
            my $declination = $tempLine[ $i + 10 ];

            my $decimal;

            #Is everything defined
            next unless ( $degrees && $minutes && $declination );
            say
              "LatRegex2: Degrees: $degrees, minutes: $minutes, declination: $declination && $main::airportLongitudeDegrees, airportLongitudeDeclination, $main::airportLongitudeDeclination"
              if $debug;

            #Does the number we found for degrees seem reasonable?
            next
              unless (
                abs($main::airportLatitudeDegrees) - abs($degrees) <= 1 );

            #Does the declination match?
            next unless ( $main::airportLatitudeDeclination eq $declination );

            if ( abs( $yMax - $yMax2 ) < .03 ) {
                $main::isPortraitOrientation = 1;
                say "Orientation is Portrait" if $debug;
            }
            elsif ( abs( $xMax - $xMax2 ) < .03 ) {
                $main::isPortraitOrientation = 0;
                say "Orientation is Landscape" if $debug;
            }
            else {
              next:
            }
            $decimal =
              coordinatetodecimal2( $degrees, $minutes, $seconds,
                $declination );
            say
              "Degrees: $degrees, Minutes $minutes, declination:$declination ->$decimal"
              if $debug;

            next unless $decimal;

            my $height = $yMax2 - $yMin;
            my $width  = $xMax2 - $xMin;

            $main::latitudeTextBoxes{ $i . $rand }{"Width"}  = $width;
            $main::latitudeTextBoxes{ $i . $rand }{"Height"} = $height;
            $main::latitudeTextBoxes{ $i . $rand }{"Text"} =
              $degrees . "-" . $minutes . $declination;
            $main::latitudeTextBoxes{ $i . $rand }{"Decimal"} = $decimal;
            $main::latitudeTextBoxes{ $i . $rand }{"CenterX"} =
              $xMin + ( $width / 2 );
            $main::latitudeTextBoxes{ $i . $rand }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::latitudeTextBoxes{ $i . $rand }{"IconsThatPointToMe"} = 0;
        }

    }

    #3 line version
    # <word xMin="30.927343" yMin="306.732400" xMax="35.139151" yMax="318.491400">122</word>
    # <word xMin="30.928666" yMin="293.502505" xMax="35.140943" yMax="305.259400">23’</word>
    # <word xMin="30.930043" yMin="291.806297" xMax="35.141143" yMax="296.485200">W</word>
    my $latitudeTextBoxRegex3 =
      qr/^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">(\d{1,2})<\/word>$
^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex).+<\/word>$
^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([N|S])<\/word>$/m;

    my $latitudeTextBoxRegex3DataPoints = 15;
    @tempLine = $_output =~ /$latitudeTextBoxRegex3/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / $latitudeTextBoxRegex3DataPoints;

    if ( $tempLineLength >= $latitudeTextBoxRegex3DataPoints ) {

        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $latitudeTextBoxRegex3DataPoints
          )
        {

            my $rand = rand();

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $xMin  = $tempLine[$i];
            my $xMin2 = $tempLine[ $i + 5 ];
            my $xMin3 = $tempLine[ $i + 9 ];

            my $yMin  = $tempLine[ $i + 1 ];
            my $yMin2 = $tempLine[ $i + 6 ];
            my $yMin3 = $tempLine[ $i + 11 ];

            my $xMax  = $tempLine[ $i + 2 ];
            my $xMax2 = $tempLine[ $i + 7 ];
            my $xMax3 = $tempLine[ $i + 12 ];

            my $yMax  = $tempLine[ $i + 3 ];
            my $yMax2 = $tempLine[ $i + 8 ];
            my $yMax3 = $tempLine[ $i + 13 ];

            my $degrees     = $tempLine[ $i + 4 ];
            my $minutes     = $tempLine[ $i + 9 ];
            my $seconds     = 0;
            my $declination = $tempLine[ $i + 14 ];

            my $decimal;

            #Is everything defined
            next unless ( $degrees && $minutes && $declination );
            say
              "LatRegex3: Degrees: $degrees, minutes: $minutes, declination: $declination && $main::airportLongitudeDegrees, airportLongitudeDeclination, $main::airportLongitudeDeclination"
              if $debug;

            #Does the number we found for degrees seem reasonable?
            next
              unless (
                abs($main::airportLatitudeDegrees) - abs($degrees) <= 1 );

            #Does the declination match?
            next unless ( $main::airportLatitudeDeclination eq $declination );

            if ( abs( $yMax - $yMax3 ) < .03 ) {
                $main::isPortraitOrientation = 1;
                say "Orientation is Portrait" if $debug;
            }
            elsif ( abs( $xMax - $xMax3 ) < .03 ) {
                $main::isPortraitOrientation = 0;
                say "Orientation is Landscape" if $debug;
            }
            else {
              next:
            }
            $decimal =
              coordinatetodecimal2( $degrees, $minutes, $seconds,
                $declination );
            say
              "Degrees: $degrees, Minutes $minutes, declination:$declination ->$decimal"
              if $debug;

            next unless $decimal;

            my $height = $yMax3 - $yMin;
            my $width  = $xMax3 - $xMin;

            $main::latitudeTextBoxes{ $i . $rand }{"Width"}  = $width;
            $main::latitudeTextBoxes{ $i . $rand }{"Height"} = $height;
            $main::latitudeTextBoxes{ $i . $rand }{"Text"} =
              $degrees . "-" . $minutes . $declination;
            $main::latitudeTextBoxes{ $i . $rand }{"Decimal"} = $decimal;
            $main::latitudeTextBoxes{ $i . $rand }{"CenterX"} =
              $xMin + ( $width / 2 );
            $main::latitudeTextBoxes{ $i . $rand }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::latitudeTextBoxes{ $i . $rand }{"IconsThatPointToMe"} = 0;
        }

    }

    print Dumper ( \%main::latitudeTextBoxes ) if $debug;

    if ($debug) {
        say "Found " .
          keys(%main::latitudeTextBoxes) . " Potential latitude text boxes";
        say "";
    }
    return;
}

# sub findLatitudeTextBoxes {
# say ":findLatitudeTextBoxes" if $debug;

# #-----------------------------------------------------------------------------------------------------------
# #Get list of potential latitude textboxes
# #For whatever dumb reason they're in raster axes (0,0 is top left, Y increases downwards)
# #   but in points coordinates
# my $latitudeTextBoxRegex =
# qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::latitudeRegex)</;

# foreach my $line (@main::pdfToTextBbox) {
# if ( $line =~ m/$latitudeTextBoxRegex/ ) {
# my $xMin = $1;

# #I don't know why but these values need to be adjusted a bit to enclose the text properly
# my $yMin = $2 - 2;
# my $xMax = $3 - 1;
# my $yMax = $4;
# my $text = $5;

# my $height = $yMax - $yMin;
# my $width  = $xMax - $xMin;

# my $rand = rand();

# my @tempText    = $text =~ m/(\d{2,})(\d\d\.?\d?).+(\w)$/ig;
# my $degrees     = $tempText[0];
# my $minutes     = $tempText[1];
# my $declination = $tempText[2];
# say "Degrees: $degrees, Minutes $minutes, declination:$declination"
# if $debug;
# my $decimal =
# coordinatetodecimal2( $degrees, $minutes, 0, $declination );

# # say $decimal;

# # say $seconds;
# # my $decimal = coordinatetodecimal($text);
# # $latitudeTextBoxes{ $1 . $2 }{"RasterX"} = $1 * $scaleFactorX;
# # $latitudeTextBoxes{ $1 . $2 }{"RasterY"} = $2 * $scaleFactorY;
# $main::latitudeTextBoxes{$rand}{"Width"}  = $width;
# $main::latitudeTextBoxes{$rand}{"Height"} = $height;
# $main::latitudeTextBoxes{$rand}{"Text"}   = $text;

# $main::latitudeTextBoxes{$rand}{"Decimal"} = $decimal;

# # $latitudeTextBoxes{ $rand }{"PdfX"}    = $xMin;
# # $latitudeTextBoxes{ $rand }{"PdfY"}    = $pdfYSize - $2;
# $main::latitudeTextBoxes{$rand}{"CenterX"} = $xMin + ( $width / 2 );

# # $latitudeTextBoxes{ $rand }{"CenterY"} = $pdfYSize - $2;
# $main::latitudeTextBoxes{$rand}{"CenterY"} =
# ( $main::pdfYSize - $yMin ) - ( $height / 2 );
# $main::latitudeTextBoxes{$rand}{"IconsThatPointToMe"} = 0;
# }

# }

# print Dumper ( \%main::latitudeTextBoxes ) if $debug;

# if ($debug) {
# say "Found " .
# keys(%main::latitudeTextBoxes) . " Potential latitude text boxes";
# say "";
# }
# return;
# }

# sub findLongitudeTextBoxes {
# say ":findLongitudeTextBoxes" if $debug;

# #-----------------------------------------------------------------------------------------------------------
# #Get list of potential longitude textboxes
# #For whatever dumb reason they're in raster axes (0,0 is top left, Y increases downwards)
# #   but in points coordinates
# my $longitudeTextBoxRegex =
# qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::longitudeRegex)</;

# foreach my $line (@main::pdfToTextBbox) {
# if ( $line =~ m/$longitudeTextBoxRegex/ ) {
# my $xMin = $1;

# #I don't know why but these values need to be adjusted a bit to enclose the text properly
# my $yMin = $2 - 2;
# my $xMax = $3 - 1;
# my $yMax = $4;
# my $text = $5;

# my $height = $yMax - $yMin;
# my $width  = $xMax - $xMin;

# my $rand = rand();

# my @tempText    = $text =~ m/(\d{2,})(\d\d\.?\d?).+(\w)$/ig;
# my $degrees     = $tempText[0];
# my $minutes     = $tempText[1];
# my $declination = $tempText[2];

# # say "Degrees: $degrees, Minutes $minutes, declination:$declination";
# my $decimal =
# coordinatetodecimal2( $degrees, $minutes, 0, $declination );

# # say $decimal;

# # $longitudeTextBoxes{ $rand }{"RasterX"} = $1 * $scaleFactorX;
# # $longitudeTextBoxes{ $rand }{"RasterY"} = $2 * $scaleFactorY;
# $main::longitudeTextBoxes{$rand}{"Width"}  = $width;
# $main::longitudeTextBoxes{$rand}{"Height"} = $height;
# $main::longitudeTextBoxes{$rand}{"Text"}   = $text;

# $main::longitudeTextBoxes{$rand}{"Decimal"} = $decimal;

# # $longitudeTextBoxes{ $rand }{"PdfX"}    = $xMin;
# # $longitudeTextBoxes{ $rand }{"PdfY"}    = $pdfYSize - $2;
# $main::longitudeTextBoxes{$rand}{"CenterX"} =
# $xMin + ( $width / 2 );

# # $longitudeTextBoxes{ $rand }{"CenterY"} = $pdfYSize - $2;
# $main::longitudeTextBoxes{$rand}{"CenterY"} =
# ( $main::pdfYSize - $yMin ) - ( $height / 2 );
# $main::longitudeTextBoxes{$rand}{"IconsThatPointToMe"} = 0;
# }

# }

# print Dumper ( \%main::longitudeTextBoxes ) if $debug;

# if ($debug) {
# say "Found " .
# keys(%main::longitudeTextBoxes) . " Potential longitude text boxes";
# say "";
# }
# return;
# }

sub findLongitudeTextBoxes2 {
    # return;
    my ($_output) = @_;
    say ":findLongitudeTextBoxes2" if $debug;

    my $longitudeTextBoxRegex1 =
      qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::longitudeRegex)</m;

    my $longitudeTextBoxRegex1DataPoints = 5;
    my @tempLine = $_output =~ /$longitudeTextBoxRegex1/ig;

    my $tempLineLength = 0 + @tempLine;
    my $tempLineCount  = $tempLineLength / $longitudeTextBoxRegex1DataPoints;

    if ( $tempLineLength >= $longitudeTextBoxRegex1DataPoints ) {

        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $longitudeTextBoxRegex1DataPoints
          )
        {
            my $rand = rand();

            my $xMin = $tempLine[$i];
            my $yMin = $tempLine[ $i + 1 ];
            my $xMax = $tempLine[ $i + 2 ];
            my $yMax = $tempLine[ $i + 3 ];
            my $text = $tempLine[ $i + 4 ];

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            # my $yMin = $2 - 2;
            # my $xMax = $3 - 1;
            # my $yMax = $4;
            # my $text = $5;

            my $height = $yMax - $yMin;
            my $width  = $xMax - $xMin;

            my @tempText    = $text =~ m/(\d{2,})(\d\d\.?\d?).+([E|W])$/ig;
            my $degrees     = $tempText[0];
            my $minutes     = $tempText[1];
            my $seconds     = 0;
            my $declination = $tempText[2];

            my $decimal;
            next unless ( $degrees && $minutes && $declination );

            $decimal =
              coordinatetodecimal2( $degrees, $minutes, $seconds,
                $declination );
            say
              " LonRegex1: Degrees: $degrees, Minutes $minutes, declination:$declination ->$decimal"
              if $debug;

            next unless $decimal;

            $main::longitudeTextBoxes{ $i . $rand }{"Width"}   = $width;
            $main::longitudeTextBoxes{ $i . $rand }{"Height"}  = $height;
            $main::longitudeTextBoxes{ $i . $rand }{"Text"}    = $text;
            $main::longitudeTextBoxes{ $i . $rand }{"Decimal"} = $decimal;
            $main::longitudeTextBoxes{ $i . $rand }{"CenterX"} =
              $xMin + ( $width / 2 );
            $main::longitudeTextBoxes{ $i . $rand }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::longitudeTextBoxes{ $i . $rand }{"IconsThatPointToMe"} = 0;
        }
    }

    # #TODO for portait oriented diagrams
    # #2 line version
    # # <word xMin="75.043300" yMin="482.701543" xMax="81.676718" yMax="486.912643">82</word>
    # # <word xMin="84.993427" yMin="482.701543" xMax="105.072785" yMax="486.912643">33.0’W</word>

    # #TODO Check against known degrees and declination
    my $longitudeTextBoxRegex2 =
      qr/^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">(\d{1,3})<\/word>$
^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex).+([E|W])<\/word>$/m;

    my $longitudeTextBoxRegex2DataPoints = 11;
    @tempLine = $_output =~ /$longitudeTextBoxRegex2/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / $longitudeTextBoxRegex2DataPoints;

    if ( $tempLineLength >= $longitudeTextBoxRegex2DataPoints ) {

        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $longitudeTextBoxRegex2DataPoints
          )
        {

            my $rand = rand();

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $xMin  = $tempLine[$i];
            my $xMin2 = $tempLine[ $i + 5 ];

            my $yMin  = $tempLine[ $i + 1 ];
            my $yMin2 = $tempLine[ $i + 6 ];

            my $xMax  = $tempLine[ $i + 2 ];
            my $xMax2 = $tempLine[ $i + 7 ];

            my $yMax  = $tempLine[ $i + 3 ];
            my $yMax2 = $tempLine[ $i + 8 ];

            my $degrees     = $tempLine[ $i + 4 ];
            my $minutes     = $tempLine[ $i + 9 ];
            my $seconds     = 0;
            my $declination = $tempLine[ $i + 10 ];

            my $decimal;
            say
              "LonRegex2: Degrees: $degrees, minutes: $minutes, declination: $declination && $main::airportLongitudeDegrees, airportLongitudeDeclination: $main::airportLongitudeDeclination"
              if $debug;

            #Is everything defined
            next unless ( $degrees && $minutes && $declination );

            #Does the number we found for degrees seem reasonable?
            next
              unless (
                abs($main::airportLongitudeDegrees) - abs($degrees) <= 1 );

            #Does the declination match?
            next unless ( $main::airportLongitudeDeclination eq $declination );

            if ( abs( $yMax - $yMax2 ) < .03 ) {
                $main::isPortraitOrientation = 1;
                say "Orientation is Portrait" if $debug;
            }
            elsif ( abs( $xMax - $xMax2 ) < .03 ) {
                $main::isPortraitOrientation = 0;
                say "Orientation is Landscape" if $debug;
            }
            else {
              next:
            }
            $decimal =
              coordinatetodecimal2( $degrees, $minutes, $seconds,
                $declination );
            say
              "Degrees: $degrees, Minutes $minutes, declination:$declination ->$decimal"
              if $debug;

            next unless $decimal;

            my $height = $yMax2 - $yMin;
            my $width  = $xMax2 - $xMin;

            $main::longitudeTextBoxes{ $i . $rand }{"Width"}  = $width;
            $main::longitudeTextBoxes{ $i . $rand }{"Height"} = $height;
            $main::longitudeTextBoxes{ $i . $rand }{"Text"} =
              $degrees . "-" . $minutes . $declination;
            $main::longitudeTextBoxes{ $i . $rand }{"Decimal"} = $decimal;
            $main::longitudeTextBoxes{ $i . $rand }{"CenterX"} =
              $xMin + ( $width / 2 );
            $main::longitudeTextBoxes{ $i . $rand }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::longitudeTextBoxes{ $i . $rand }{"IconsThatPointToMe"} = 0;
        }

    }

    #3 line version
    # <word xMin="30.927343" yMin="306.732400" xMax="35.139151" yMax="318.491400">122</word>
    # <word xMin="30.928666" yMin="293.502505" xMax="35.140943" yMax="305.259400">23’</word>
    # <word xMin="30.930043" yMin="291.806297" xMax="35.141143" yMax="296.485200">W</word>

    my $longitudeTextBoxRegex3 =
      qr/^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex)<\/word>$
^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex).+<\/word>$
^\s+<word xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([E|W])<\/word>$/m;
    my $longitudeTextBoxRegex3DataPoints = 15;
    @tempLine = $_output =~ /$longitudeTextBoxRegex3/ig;

    $tempLineLength = 0 + @tempLine;
    $tempLineCount  = $tempLineLength / $longitudeTextBoxRegex3DataPoints;

    if ( $tempLineLength >= $longitudeTextBoxRegex3DataPoints ) {

        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $longitudeTextBoxRegex3DataPoints
          )
        {

            my $rand = rand();

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $xMin  = $tempLine[$i];
            my $xMin2 = $tempLine[ $i + 5 ];
            my $xMin3 = $tempLine[ $i + 9 ];

            my $yMin  = $tempLine[ $i + 1 ];
            my $yMin2 = $tempLine[ $i + 6 ];
            my $yMin3 = $tempLine[ $i + 11 ];

            my $xMax  = $tempLine[ $i + 2 ];
            my $xMax2 = $tempLine[ $i + 7 ];
            my $xMax3 = $tempLine[ $i + 12 ];

            my $yMax  = $tempLine[ $i + 3 ];
            my $yMax2 = $tempLine[ $i + 8 ];
            my $yMax3 = $tempLine[ $i + 13 ];

            my $degrees     = $tempLine[ $i + 4 ];
            my $minutes     = $tempLine[ $i + 9 ];
            my $seconds     = 0;
            my $declination = $tempLine[ $i + 14 ];

            my $decimal;

            #Is everything defined
            next unless ( $degrees && $minutes && $declination );

            say
              "LonRegex3: Degrees: $degrees, minutes: $minutes, declination: $declination && $main::airportLongitudeDegrees, airportLongitudeDeclination, $main::airportLongitudeDeclination"
              if $debug;

            #Does the number we found for degrees seem reasonable?
            next
              unless (
                abs($main::airportLongitudeDegrees) - abs($degrees) <= 1 );

            #Does the declination match?
            next unless ( $main::airportLongitudeDeclination eq $declination );

            if ( abs( $yMax - $yMax3 ) < .03 ) {
                $main::isPortraitOrientation = 1;
                say "Orientation is Portrait" if $debug;
            }
            elsif ( abs( $xMax - $xMax3 ) < .03 ) {
                $main::isPortraitOrientation = 0;
                say "Orientation is Landscape" if $debug;
            }
            else {
              next:
            }
            $decimal =
              coordinatetodecimal2( $degrees, $minutes, $seconds,
                $declination );

            next unless $decimal;

            my $height = $yMax3 - $yMin;
            my $width  = $xMax3 - $xMin;

            $main::longitudeTextBoxes{ $i . $rand }{"Width"}  = $width;
            $main::longitudeTextBoxes{ $i . $rand }{"Height"} = $height;
            $main::longitudeTextBoxes{ $i . $rand }{"Text"} =
              $degrees . "-" . $minutes . $declination;
            $main::longitudeTextBoxes{ $i . $rand }{"Decimal"} = $decimal;
            $main::longitudeTextBoxes{ $i . $rand }{"CenterX"} =
              $xMin + ( $width / 2 );
            $main::longitudeTextBoxes{ $i . $rand }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::longitudeTextBoxes{ $i . $rand }{"IconsThatPointToMe"} = 0;
        }

    }

    print Dumper ( \%main::longitudeTextBoxes )
      if $debug;

    if ($debug) {
        say "Found " .
          keys(%main::longitudeTextBoxes) . " Potential longitude text boxes";
        say "";
    }
    return;
}

sub findIntersectionOfLatLonLines {
    my ( $textBoxHashRefA, $textBoxHashRefB, $linesHashRef ) = @_;

    say "findIntersectionOfLatLonLines" if $debug;

    #Find an icon with text that matches an item in a database lookup
    #Add the center coordinates of its closest text box to the database hash
    #
    foreach my $key ( keys %$textBoxHashRefA ) {

        foreach my $keyB ( keys %$textBoxHashRefB ) {

            #Next icon if this one doesn't have a matching textbox
            next
              unless ( $textBoxHashRefA->{$key}{"MatchedTo"}
                && $textBoxHashRefB->{$keyB}{"MatchedTo"} );

            my $keyOfMatchedLineA = $textBoxHashRefA->{$key}{"MatchedTo"};
            my $lineA_X1          = $linesHashRef->{$keyOfMatchedLineA}{"X"};
            my $lineA_Y1          = $linesHashRef->{$keyOfMatchedLineA}{"Y"};
            my $lineA_X2          = $linesHashRef->{$keyOfMatchedLineA}{"X2"};
            my $lineA_Y2          = $linesHashRef->{$keyOfMatchedLineA}{"Y2"};
            my $textA             = $textBoxHashRefA->{$key}{"Text"};
            my $decimalA          = $textBoxHashRefA->{$key}{"Decimal"};

            my $keyOfMatchedLineB = $textBoxHashRefB->{$keyB}{"MatchedTo"};
            my $lineB_X1          = $linesHashRef->{$keyOfMatchedLineB}{"X"};
            my $lineB_Y1          = $linesHashRef->{$keyOfMatchedLineB}{"Y"};
            my $lineB_X2          = $linesHashRef->{$keyOfMatchedLineB}{"X2"};
            my $lineB_Y2          = $linesHashRef->{$keyOfMatchedLineB}{"Y2"};
            my $textB             = $textBoxHashRefB->{$keyB}{"Text"};
            my $decimalB          = $textBoxHashRefB->{$keyB}{"Decimal"};

            # my $thisIconsGeoreferenceX = $textBoxHashRefA->{$keyB}{"GeoreferenceX"};
            # my $thisIconsGeoreferenceY = $textBoxHashRefA->{$keyB}{"GeoreferenceY"};
            # my $textOfMatchedTextbox =
            # $textBoxHashRefB->{$keyOfMatchedTextbox}{"Text"};

            my ( $px, $py ) = intersectLines(
                $lineA_X1, $lineA_Y1, $lineA_X2, $lineA_Y2,
                $lineB_X1, $lineB_Y1, $lineB_X2, $lineB_Y2
            );
            next unless $px && $py;
            say "$textA  ($decimalA) intersects $textB ($decimalB) at $px,$py"
              if $debug;

            if (   $px < 0
                || $px > $main::pdfXSize
                || $py < 0
                || $py > $main::pdfYSize )
            {
                say "Intersection off diagram, ignoring" if $debug;
                next;
            }
            if (   $keyOfMatchedLineA
                && $textA
                && $decimalA
                && $keyOfMatchedLineB
                && $textB
                && $decimalB
                && $px
                && $py )
            {

                $main::gcps{ $key . $keyB }{"pngx"} = $px * $main::scaleFactorX;
                $main::gcps{ $key . $keyB }{"pngy"} =
                  $main::pngYSize - ( $py * $main::scaleFactorY );
                $main::gcps{ $key . $keyB }{"pdfx"} = $px;
                $main::gcps{ $key . $keyB }{"pdfy"} = $py;
                $main::gcps{ $key . $keyB }{"lon"}  = $decimalB;
                $main::gcps{ $key . $keyB }{"lat"}  = $decimalA;
            }
        }
    }
    print Dumper ( \%main::gcps ) if $debug;
    return;
}

sub intersectLines {
    my ( $ax, $ay, $bx, $by, $cx, $cy, $dx, $dy ) = @_;
    my $d =
      ( $ax - $bx ) * ( $cy - $dy ) - ( $ay - $by ) * ( $cx - $dx );
    if ( 0 == $d ) {
        return ( 0, 0 );
    }
    my $p =
      ( ( $by - $dy ) * ( $cx - $dx ) - ( $bx - $dx ) * ( $cy - $dy ) ) / $d;
    my $px = $p * $ax + ( 1 - $p ) * $bx;
    my $py = $p * $ay + ( 1 - $p ) * $by;
    return ( $px, $py );
}

sub georeferenceTheRaster {

    # #----------------------------------------------------------------------------------------------------------------------------------------------------
    # #Try to georeference

    my $gdal_translateCommand =
      "gdal_translate -q -of VRT -strict -a_srs EPSG:4326 $main::gcpstring '$main::targetpng'  '$main::targetvrt'";
    if ($debug) {
        say $gdal_translateCommand;
        say "";
    }

    #Run gdal_translate

    my $gdal_translateoutput = qx($gdal_translateCommand);

    my $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gdal_translate.  Is it installed? Return code was $retval";
        ++$main::failCount;
        say "Touching $main::failFile";
        open( my $fh, ">", "$main::failFile" )
          or die "cannot open > $main::failFile $!";
        close($fh);
        return;
    }
    say $gdal_translateoutput if $debug;

    #Warp it

    my $gdalwarpCommand =
      "gdalwarp -q -of VRT -t_srs EPSG:4326 -order 1 -overwrite ''$main::targetvrt''  '$main::targetvrt2'";
    if ($debug) {
        say $gdalwarpCommand;
        say "";
    }

    #Run gdalwarp

    my $gdalwarpCommandOutput = qx($gdalwarpCommand);

    $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gdalwarp.  Is it installed? Return code was $retval";
        ++$main::failCount;
        say "Touching $main::failFile";
        open( my $fh, ">", "$main::failFile" )
          or die "cannot open > $main::failFile $!";
        close($fh);
        return;
    }

    if ( $retval == 0 ) {
        say "Sucess!";
        ++$main::successCount;
    }
    say $gdalwarpCommandOutput if $debug;

    #Get info

    my $gdalinfoCommand = "gdalinfo '$main::targetvrt2'";
    if ($debug) {
        say $gdalinfoCommand;
        say "";
    }

    #Run gdalinfo

    my $gdalinfoCommandOutput = qx($gdalinfoCommand);

    $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gdalinfo.  Is it installed? Return code was $retval";
    }
    say $gdalinfoCommandOutput if $debug;

    # #A line
    # my $lineRegex = qr/^$main::transformCaptureXYRegex$
    # ^$main::originRegex$
    # ^($main::numberRegex)\s+($main::numberRegex)\s+l$
    # ^S$
    # ^Q$/m;

    # my @tempLine = $_output =~ /$lineRegex/ig;
    # Driver: VRT/Virtual Raster

    # Files: ./apdTest/warpedSC-CAE-00089AD.PDF-AIRPORT DIAGRAM.vrt
    # /home/jlmcgraw/Documents/myPrograms/GeoReferencePlates/./apdTest/SC-CAE-00089AD-PDF-AIRPORT-DIAGRAM.vrt
    # Size is 1818, 2328
    # Coordinate System is:
    # GEOGCS["WGS 84",
    # DATUM["WGS_1984",
    # SPHEROID["WGS 84",6378137,298.257223563,
    # AUTHORITY["EPSG","7030"]],
    # AUTHORITY["EPSG","6326"]],
    # PRIMEM["Greenwich",0,
    # AUTHORITY["EPSG","8901"]],
    # UNIT["degree",0.0174532925199433,
    # AUTHORITY["EPSG","9122"]],
    # AUTHORITY["EPSG","4326"]]
    # Origin = (-81.142523952679298,33.967226302777370)
    # Pixel Size = (0.000024392260817,-0.000024392260817)
    # Corner Coordinates:
    # Upper Left  ( -81.1425240,  33.9672263) ( 81d 8'33.09"W, 33d58' 2.01"N)
    # Lower Left  ( -81.1425240,  33.9104411) ( 81d 8'33.09"W, 33d54'37.59"N)
    # Upper Right ( -81.0981788,  33.9672263) ( 81d 5'53.44"W, 33d58' 2.01"N)
    # Lower Right ( -81.0981788,  33.9104411) ( 81d 5'53.44"W, 33d54'37.59"N)
    # Center      ( -81.1203514,  33.9388337) ( 81d 7'13.26"W, 33d56'19.80"N)
    # Band 1 Block=512x128 Type=Byte, ColorInterp=Red
    # Band 2 Block=512x128 Type=Byte, ColorInterp=Green
    # Band 3 Block=512x128 Type=Byte, ColorInterp=Blue

    return;
}

#

sub writeStatistics {

    #Update the georef table
    my $update_dtpp_geo_record =
        "UPDATE dtppGeo " . "SET "
      . "airportLatitude = ?, "
      . "horizontalAndVerticalLinesCount = ?, "
      . "gcpCount = ?, "
      . "yMedian = ?, "
      . "gpsCount = ?, "
      . "targetPdf = ?, "
      . "yScaleAvgSize = ?, "
      . "airportLongitude = ?, "
      . "notToScaleIndicatorCount = ?, "
      . "unique_obstacles_from_dbCount = ?, "
      . "xScaleAvgSize = ?, "
      . "navaidCount = ?, "
      . "xMedian = ?, "
      . "insetCircleCount = ?, "
      . "obstacleCount = ?, "
      . "insetBoxCount = ?, "
      . "fixCount = ?, "
      . "yAvg = ?, "
      . "xAvg = ?, "
      . "pdftotext = ?, "
      . "lonLatRatio = ?, "
      . "upperLeftLon = ?, "
      . "upperLeftLat = ?, "
      . "lowerRightLon = ?, "
      . "lowerRightLat = ?, "
      . "targetLonLatRatio = ?, "
      . "runwayIconsCount = ? "
      . "WHERE "
      . "PDF_NAME = ?";

    $dtppSth = $dtppDbh->prepare($update_dtpp_geo_record);

    $dtppSth->bind_param( 1,  $statistics{'$airportLatitude'} );
    $dtppSth->bind_param( 2,  $statistics{'$horizontalAndVerticalLinesCount'} );
    $dtppSth->bind_param( 3,  $statistics{'$gcpCount'} );
    $dtppSth->bind_param( 4,  $statistics{'$yMedian'} );
    $dtppSth->bind_param( 5,  $statistics{'$gpsCount'} );
    $dtppSth->bind_param( 6,  $statistics{'$targetPdf'} );
    $dtppSth->bind_param( 7,  $statistics{'$yScaleAvgSize'} );
    $dtppSth->bind_param( 8,  $statistics{'$airportLongitude'} );
    $dtppSth->bind_param( 9,  $statistics{'$notToScaleIndicatorCount'} );
    $dtppSth->bind_param( 10, $statistics{'$unique_obstacles_from_dbCount'} );
    $dtppSth->bind_param( 11, $statistics{'$xScaleAvgSize'} );
    $dtppSth->bind_param( 12, $statistics{'$navaidCount'} );
    $dtppSth->bind_param( 13, $statistics{'$xMedian'} );
    $dtppSth->bind_param( 14, $statistics{'$insetCircleCount'} );
    $dtppSth->bind_param( 15, $statistics{'$obstacleCount'} );
    $dtppSth->bind_param( 16, $statistics{'$insetBoxCount'} );
    $dtppSth->bind_param( 17, $statistics{'$fixCount'} );
    $dtppSth->bind_param( 18, $statistics{'$yAvg'} );
    $dtppSth->bind_param( 19, $statistics{'$xAvg'} );
    $dtppSth->bind_param( 20, $statistics{'$pdftotext'} );
    $dtppSth->bind_param( 21, $statistics{'$lonLatRatio'} );
    $dtppSth->bind_param( 22, $statistics{'$upperLeftLon'} );
    $dtppSth->bind_param( 23, $statistics{'$upperLeftLat'} );
    $dtppSth->bind_param( 24, $statistics{'$lowerRightLon'} );
    $dtppSth->bind_param( 25, $statistics{'$lowerRightLat'} );
    $dtppSth->bind_param( 26, $statistics{'$targetLonLatRatio'} );
    $dtppSth->bind_param( 27, $statistics{'$runwayIconsCount'} );
    $dtppSth->bind_param( 28, $PDF_NAME );

    $dtppSth->execute();

    # open my $file, '>>', $main::targetStatistics
    # or croak "can't open '$main::targetStatistics' for writing : $!";

    # my $_header = join ",", sort keys %statistics;

    # # my $_data   = join ",", sort values %statistics;
    # #A basic routine for outputting CSV for our statistics hash
    # my $_data =
    # join( ",", map { "$main::statistics{$_}" } sort keys %statistics );
    # say {$file} "$_header"
    # or croak "Cannot write to $main::targetStatistics: ";
    # say {$file} "$_data"
    # or croak "Cannot write to $main::targetStatistics: ";

    # close $file;
    return;
}

# sub addCombinedHashToGroundControlPoints {

# #Make a hash of all the GCPs to use, filtering them by using our mask bitmap
# my ( $type, $combinedHashRef ) = @_;

# #Add obstacles to Ground Control Points hash
# foreach my $key ( sort keys %$combinedHashRef ) {

# my $_pdfX = $combinedHashRef->{$key}{"GeoreferenceX"};
# my $_pdfY = $combinedHashRef->{$key}{"GeoreferenceY"};
# my $lon   = $combinedHashRef->{$key}{"Lon"};
# my $lat   = $combinedHashRef->{$key}{"Lat"};
# my $text  = $combinedHashRef->{$key}{"Text"};
# next unless ( $_pdfX && $_pdfY && $lon && $lat );
# my @pixels;
# my $_rasterX = $_pdfX * $main::scaleFactorX;
# my $_rasterY = $main::pngYSize - ( $_pdfY * $main::scaleFactorY );
# my $rand     = rand();

# #Make sure all our info is defined
# if ( $_rasterX && $_rasterY && $lon && $lat ) {

# #Get the color value of the pixel at the x,y of the GCP
# # my $pixelTextOutput;
# # qx(convert $outputPdfOutlines.png -format '%[pixel:p{$_rasterX,$_rasterY}]' info:-);
# #TODO Delete this since it's being done earlier already
# @pixels = $main::image->GetPixel( x => $_rasterX, y => $_rasterY );
# say "perlMagick $pixels[0]" if $debug;

# # say $pixelTextOutput if $debug;
# #srgb\(149,149,0\)|yellow
# # if ( $pixelTextOutput =~ /black|gray\(0,0,0\)/i  ) {
# if ( $pixels[0] eq 0 ) {

# #If it's any of the above strings then it's valid
# say "$_rasterX $_rasterY $lon $lat" if $debug;
# $main::gcps{ "$type" . $text . '-' . $rand }{"pngx"} =
# $_rasterX;
# $main::gcps{ "$type" . $text . '-' . $rand }{"pngy"} =
# $_rasterY;
# $main::gcps{ "$type" . $text . '-' . $rand }{"pdfx"} = $_pdfX;
# $main::gcps{ "$type" . $text . '-' . $rand }{"pdfy"} = $_pdfY;
# $main::gcps{ "$type" . $text . '-' . $rand }{"lon"}  = $lon;
# $main::gcps{ "$type" . $text . '-' . $rand }{"lat"}  = $lat;
# }
# else {
# say "$type $text is being ignored" if $debug;
# }

# }
# }
# return;
# }

sub createGcpString {
    my $_gcpstring = "";
    foreach my $key ( keys %main::gcps ) {

        #build the GCP portion of the command line parameters
        $_gcpstring =
            $_gcpstring
          . " -gcp "
          . $main::gcps{$key}{"pngx"} . " "
          . $main::gcps{$key}{"pngy"} . " "
          . $main::gcps{$key}{"lon"} . " "
          . $main::gcps{$key}{"lat"};
    }
    if ($debug) {
        say "Ground Control Points command line string";
        say $_gcpstring;
        say "";
    }
    return $_gcpstring;
}

sub drawCircleAroundGCPs {
    foreach my $key ( sort keys %main::gcps ) {

        my $gcpCircle = $main::page->gfx;
        $gcpCircle->circle( $main::gcps{$key}{pdfx},
            $main::gcps{$key}{pdfy}, 5 );
        $gcpCircle->strokecolor('green');
        $gcpCircle->linewidth(.05);
        $gcpCircle->stroke;

    }
    return;
}

sub findAllTextboxes {
    if ($debug) {
        say "";
        say ":findAllTextboxes";
    }
    my ($_output);

    $_output = qx(pdftotext $main::targetPdf -bbox - );

    my $retval = $? >> 8;

    if ( $_output eq "" || $retval != 0 ) {
        say
          "No output from pdftotext -bbox.  Is it installed? Return code was $retval";
        return;
    }

    say $_output if $debug;

    # #Get all of the text and respective bounding boxes in the PDF
    # @main::pdfToTextBbox = qx(pdftotext $main::targetPdf -layout -bbox - );
    # $main::retval        = $? >> 8;
    # die
    # "No output from pdftotext -bbox.  Is it installed? Return code was $main::retval"
    # if ( @main::pdfToTextBbox eq "" || $main::retval != 0 );

    #Find potential latitude textboxes
    # findLatitudeTextBoxes($_output);
    findLatitudeTextBoxes2($_output);

    #Find potential longitude textboxes
    findLongitudeTextBoxes2($_output);

    return;
}

# sub joinIconTextboxAndDatabaseHashes {

# #Pass in references to hashes of icons, their textboxes, and their associated database info
# my ( $iconHashRef, $textboxHashRef, $databaseHashRef ) = @_;

# #A new hash of JOIN'd information
# my %hashOfMatchedPairs = ();
# my $key3               = 1;

# foreach my $key ( sort keys %$iconHashRef ) {

# #The key of the textboxHashRef this icon is matched to
# my $keyOfMatchedTextbox = $iconHashRef->{$key}{"MatchedTo"};

# #Don't do anything if it doesn't exist
# next unless $keyOfMatchedTextbox;

# #Check that the "MatchedTo" textboxHashRef points back to this icon
# #Clear the match  for the iconHashRef if it doesn't (ie isn't a two-way match)

# if ( ( $textboxHashRef->{$keyOfMatchedTextbox}{"MatchedTo"} ne $key ) )
# {
# #Clear the icon's matching since it isn't reciprocated
# say
# "Non-reciprocal match of textbox $keyOfMatchedTextbox to icon $key.  Clearing"
# if $debug;
# $iconHashRef->{$key}{"MatchedTo"} = "";
# }
# else {
# $iconHashRef->{$key}{"BidirectionalMatch"} = "True";
# $textboxHashRef->{$keyOfMatchedTextbox}{"BidirectionalMatch"} =
# "True";

# my $textOfMatchedTextbox =
# $textboxHashRef->{$keyOfMatchedTextbox}{"Text"};
# my $georeferenceX = $iconHashRef->{$key}{"GeoreferenceX"};
# my $georeferenceY = $iconHashRef->{$key}{"GeoreferenceY"};
# my $lat = $databaseHashRef->{$textOfMatchedTextbox}{"Lat"};
# my $lon = $databaseHashRef->{$textOfMatchedTextbox}{"Lon"};

# next
# unless ( $textOfMatchedTextbox
# && $georeferenceX
# && $georeferenceY
# && $lat
# && $lon );

# #This little section is to keep from using a navaid icon matched to a textbox containing the name
# #of a different type of navaid as a GCP
# my $iconType = $iconHashRef->{$key}{"Type"};
# my $databaseType =
# $databaseHashRef->{$textOfMatchedTextbox}{"Type"};

# if ( $iconType && $iconType =~ m/VOR/ ) {

# # say
# # "We've found a *VOR*, let's see if type of icon matches type of database entry";
# # say "$iconType";
# # say $keyOfMatchedTextbox;
# # say "$databaseType";
# next unless ( $iconType eq $databaseType );

# #TODO Check for nearby notToScaleIndicator icon (<30pt radius)
# }

# #Populate the values of our new combined hash
# $hashOfMatchedPairs{$key3}{"GeoreferenceX"} = $georeferenceX;
# $hashOfMatchedPairs{$key3}{"GeoreferenceY"} = $georeferenceY;
# $hashOfMatchedPairs{$key3}{"Lat"}           = $lat;
# $hashOfMatchedPairs{$key3}{"Lon"}           = $lon;
# $hashOfMatchedPairs{$key3}{"Text"}          = $textOfMatchedTextbox;
# $key3++;

# }

# }

# # if ($debug) {
# # say "";
# # say "hashOfMatchedPairs";
# # print Dumper (\%hashOfMatchedPairs);
# # }

# return ( \%hashOfMatchedPairs );
# }

sub drawLineFromEachIconToMatchedTextBox {

    #Draw a line from icon to matched text box
    my ( $hashRefA, $hashRefB ) = @_;

    my $_line = $main::page->gfx;

    foreach my $key ( keys %$hashRefA ) {
        my $matchedKey = $hashRefA->{$key}{"MatchedTo"};

        #Don't draw if we don't have a match
        next unless $matchedKey;

        $_line->move( $hashRefA->{$key}{"CenterX"},
            $hashRefA->{$key}{"CenterY"} );
        $_line->line(
            $hashRefB->{$matchedKey}{"CenterX"},
            $hashRefB->{$matchedKey}{"CenterY"}
        );
        $_line->linewidth(.1);
        $_line->strokecolor('blue');
        $_line->stroke;
    }
    return;
}

sub findLatitudeAndLongitudeTextBoxes {
  

    my ($_output) = @_;
    # say $_output;
      say ":findLatitudeAndLongitudeTextBoxes" if $debug;
    my $retval  = $? >> 8;

    #Capture all text between BT and ET tags
    my $textGroupRegex           = qr/^BT$(.*?)^ET$/sm;
    my $textGroupRegexDataPoints = 1;

    my @tempLine = $_output =~ /$textGroupRegex/ig;

    my $tempLineLength = 0 + @tempLine;
    my $tempLineCount  = $tempLineLength / $textGroupRegexDataPoints;

    if ( $tempLineLength >= $textGroupRegexDataPoints ) {
        my $random = rand();
        for (
            my $i = 0 ;
            $i < $tempLineLength ;
            $i = $i + $textGroupRegexDataPoints
          )
        {
            #Capture all text between BT and ET tags
            my $_text = $tempLine[$i];

            # say $_text;
            # say "**************";

            # my ( $xMin, $xMax, $yMin, $yMax ) = 999999999999;
            my  $xMin  = 99999;
            my  $yMin  = 99999;
            my  $xMax  = 0;
            my  $yMax  = 0;
            our $numberRegex = qr/[-\.\d]+/x;

            #Capture the transformation matrix
            my $textGroupRegex3 =
              qr/^$numberRegex\s+$numberRegex\s+$numberRegex\s+$numberRegex\s+($numberRegex)\s+($numberRegex)\s+Tm$/m;
            my $textGroupRegexDataPoints3 = 2;

            my @tempLine3 = $_text =~ /$textGroupRegex3/ig;

            my $tempLineLength3 = 0 + @tempLine3;
            my $tempLineCount3  = $tempLineLength3 / $textGroupRegexDataPoints3;

            if ( $tempLineLength3 >= $textGroupRegexDataPoints3 ) {
                
                for (
                    my $i = 0 ;
                    $i < $tempLineLength3 ;
                    $i = $i + $textGroupRegexDataPoints3
                  )
                {
                   # say "$xMin, $yMin, $xMax, $yMax";
                 
                    $xMin = $tempLine3[$i] < $xMin ? $tempLine3[$i] : $xMin;
                    # $xMin = $tempLine3[$i];
                    $xMax = $tempLine3[$i] > $xMax ? $tempLine3[$i] : $xMax;
                    # $xMax = $xMin + 1;
                    # $yMin = $tempLine3[ $i + 1 ];
                    # $yMax = $yMin + 1;
                    $yMin =  $tempLine3[$i+1] < $yMin  ? $tempLine3[$i+1] : $yMin;
                    $yMax = $tempLine3[$i+1] > $yMax ? $tempLine3[$i+1] : $yMax;
                    

                }

            }

            #Match any time text is drawn
            my $textGroupRegex2           = qr/^\((.*)\)\s*Tj$/m;
            my $textGroupRegexDataPoints2 = 1;

            my @tempLine2 = $_text =~ /$textGroupRegex2/ig;
            my $_textAccumulator;
            my $tempLineLength2 = 0 + @tempLine2;
            my $tempLineCount2  = $tempLineLength2 / $textGroupRegexDataPoints2;

            if ( $tempLineLength2 >= $textGroupRegexDataPoints2 ) {
                my $random = rand();
                for (
                    my $i = 0 ;
                    $i < $tempLineLength2 ;
                    $i = $i + $textGroupRegexDataPoints2
                  )
                {
                    #Accumulate each drawn piece of text
                    $_textAccumulator = $_textAccumulator . $tempLine2[$i];
                }

                #Replace the degree symbol glyph
                $_textAccumulator =~ s/\\260/-/g;

                $_textAccumulator =~ s/\s+//g;

                # say $_textAccumulator;
                if ( $_textAccumulator =~
                    m/(\d{1,3})-([-\.\d]+)[\s']*(N|E|W|S)/ )
                {

                    my $height      = $yMax - $yMin;
                    my $width       = $xMax - $xMin;
                    #Abort if we got a text block that's too big
                    if ($height > 30 || $width > 30) {
                        say "This box is too big" if $debug;}
                    my $degrees     = $1;
                    my $minutes     = $2;
                    my $seconds     = 0;
                    my $declination = $3;
                    # say "Found lat/lon text $_textAccumulator at $xMin, $yMin";
                    # say                      "Degrees: $degrees, Minutes: $minutes, Declination: $declination";
                    my $rand = rand();
                    my $decimal =
                      coordinatetodecimal2( $degrees, $minutes, $seconds,
                        $declination );
                     
                    #If the slope of the line of this text is vertical than the orientation is landscape  
                   $main::isPortraitOrientation = slopeAngle($xMin,$yMin,$xMax,$yMax) > 15 ? 0  : 1;
                   
                     if ($declination =~ m/E|W/)  {
                    $main::longitudeTextBoxes{$rand}{"Width"}  = $width;
                    $main::longitudeTextBoxes{$rand}{"Height"} = $height;
                    $main::longitudeTextBoxes{$rand}{"Text"} =                      $_textAccumulator;
                    $main::longitudeTextBoxes{$rand}{"Decimal"} = $decimal;
                    $main::longitudeTextBoxes{$rand}{"CenterX"} =                      $xMin + ( $width / 2 );
                    $main::longitudeTextBoxes{$rand}{"CenterY"} =                      $yMin + ( $height / 2 );
                  }
                  elsif ($declination =~ m/N|S/)  {
                    $main::latitudeTextBoxes{$rand}{"Width"}  = $width;
                    $main::latitudeTextBoxes{$rand}{"Height"} = $height;
                    $main::latitudeTextBoxes{$rand}{"Text"} =                      $_textAccumulator;
                    $main::latitudeTextBoxes{$rand}{"Decimal"} = $decimal;
                    $main::latitudeTextBoxes{$rand}{"CenterX"} =                      $xMin + ( $width / 2 );
                    $main::latitudeTextBoxes{$rand}{"CenterY"} =                      $yMin + ( $height / 2 );
                  }
                  else {
                      say "Bad Declination";}

                }

            }

        }

    }
    # print Dumper ( \%main::longitudeTextBoxes );
    return;
}
