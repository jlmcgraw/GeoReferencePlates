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
#-Relies on icons being drawn very specific ways, it won't work if these ever change
#-Relies on actual text being in PDF.  It seems that most, if not all, military plates have no text in them
#       We may be able to get around this with tesseract OCR but that will take some work
#
#Known issues:
#---------------------
#-Investigate not creating the intermediate PNG (guessing at dimensions)
#Our pixel/RealWorld ratios are hardcoded now for 300dpi, need to make dynamic per our DPI setting
#
#TODO
#Instead of only matching on closest, iterate over every icon making sure it's matched to some textbox
#    (eg if one icon <-> textbox pair does match as closest to each other, remove that textbox from consideration for the rest of the icons, loop until all icons have a match)
#
#Try with both unique and non-unique obstacles, save whichever has closest lon/lat ratio to targetLonLatRatio
#
#Iterate over a list of files from command line or stdin
#
#Generate the text, text w/ bounding box, and pdfdump output once and re-use in future runs (like we're doing with the masks)
#Generate the mask bitmap totally in memory instead of via pdf->png
#
#Find some way to use the hint of the bubble icon for NAVAID names
#       Maybe find a line of X length within X radius of the textbox and see if it intersects with a navaid
#
#Integrate OCR so we can process miltary plates too
#       The miltary plates are not rendered the same as the civilian ones, it will require full on image processing to do those
#
#Try to find the runways themselves to use as GCPs (DONE)

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
    say "$completedCount" . "/" . "$_rows";
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
    our $touchFile         = $dir . "noPoints-" . $targetVrtFile . ".vrt";
    our $targetvrt         = $dir . $targetVrtFile . ".vrt";
our $targetvrt2         = $dir . $targetVrtFile2. ".vrt";
    our $targetStatistics = "./statistics.csv";

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
    say "Not enough pdftotext output for $targetPdf";
    writeStatistics() if $shouldOutputStatistics;
    return(1);
    }

    #Pull airport location from chart text or, if a name was supplied on command line, from database
    our ( $airportLatitudeDec, $airportLongitudeDec ) =
      findAirportLatitudeAndLongitude();

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

    our $latitudeRegex  = qr/($numberRegex)’[N|S]/x;
    our $longitudeRegex = qr/($numberRegex)’[E|W]/x;

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

    #Loop through each of the streams in the PDF and find all of the icons we're interested in
    findAllIcons();

    # my $rawPdf = returnRawPdf();
    # # findIlsIcons( \%icons, $_output );
    # findObstacleIcons($$rawPdf);
    # findFixIcons($$rawPdf);

    # # findGpsWaypointIcons($_output);
    # findGpsWaypointIcons($$rawPdf);
    # findNavaidIcons($$rawPdf);

    # #findFinalApproachFixIcons($_output);
    # #findVisualDescentPointIcons($_output);
    # findHorizontalAndVerticalLines($$rawPdf);
    # findInsetBoxes($$rawPdf);
    # findLargeBoxes($$rawPdf);
    # findInsetCircles($$rawPdf);
    # findNotToScaleIndicator($$rawPdf);

    #Find navaids near the airport
    our %navaids_from_db = ();

    # findNavaidsNearAirport();

    our @validNavaidNames = keys %navaids_from_db;
    our $validNavaidNames = join( " ", @validNavaidNames );

    #Find all of the text boxes in the PDF
    our @pdfToTextBbox = ();

    # our %fixTextboxes      = ();
    our %latitudeTextBoxes  = ();
    our %longitudeTextBoxes = ();

    # our %vorTextboxes      = ();

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
    #----------------------------------------------------------------------------------------------------------------------------------
    #Everything to do with latitude

    #Try to find closest obstacleTextBox center to each obstacleIcon center and then do the reverse
    # findClosestBToA( \%latitudeAndLongitudeLines,     \%latitudeTextBoxes );
    findClosestLineToTextBox( \%latitudeTextBoxes, \%latitudeAndLongitudeLines, "horizontal"    );

    #Make sure there is a bi-directional match between icon and textbox
    #Returns a reference to a hash which combines info from icon, textbox and database
    # my $matchedObstacleIconsToTextBoxes =
    # joinIconTextboxAndDatabaseHashes( \%latitudeAndLongitudeLines, \%latitudeTextBoxes,
    # \%unique_obstacles_from_db );

    if ($debug) {
        say "latitudeTextBoxes";

        # print Dumper ( \%latitudeAndLongitudeLines );
        print Dumper ( \%latitudeTextBoxes );
    }

    #Draw a line from obstacle icon to closest text boxes
    if ($shouldSaveMarkedPdf) {
        drawLineFromEachIconToMatchedTextBox(  \%latitudeTextBoxes, \%latitudeAndLongitudeLines            );

    }

    #----------------------------------------------------------------------------------------------------------------------------------
    #Everything to do with longitude

    #Try to find closest obstacleTextBox center to each obstacleIcon center and then do the reverse
    # findClosestBToA( \%latitudeAndLongitudeLines,     \%longitudeTextBoxes );
    findClosestLineToTextBox( \%longitudeTextBoxes,        \%latitudeAndLongitudeLines, "vertical");



    if ($debug) {
        say "longitudeTextBoxes";

        # print Dumper ( \%latitudeAndLongitudeLines );
        print Dumper ( \%longitudeTextBoxes );
    }

    #Draw a line from obstacle icon to closest text boxes
    if ($shouldSaveMarkedPdf) {
        drawLineFromEachIconToMatchedTextBox(  \%longitudeTextBoxes, \%latitudeAndLongitudeLines
            );
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
        say "Touching $touchFile";
        open( my $fh, ">", "$touchFile" )
          or die "cannot open > $touchFile: $!";
        close($fh);
        say
          "xScaleAvgSize: $statistics{'$xScaleAvgSize'}, yScaleAvgSize: $statistics{'$yScaleAvgSize'}";

        #touch($touchFile);
        writeStatistics() if $shouldOutputStatistics;
        return (1);
    }

    # #Calculate the rough X and Y scale values
    # if ( $gcpCount == 1 ) {
        # say "Found 1 ground control points in $targetPdf";
        # say "Touching $touchFile";
        # open( my $fh, ">", "$touchFile" )
          # or die "cannot open > $touchFile: $!";
        # close($fh);

        # #Is it better to guess or do nothing?  I think we should do nothing
        # #calculateRoughRealWorldExtentsOfRasterWithOneGCP();
        # writeStatistics() if $shouldOutputStatistics;
        # return (1);
    # }
    # else {
        # calculateRoughRealWorldExtentsOfRaster();
    # }

    # #Print a header so you could paste the following output into a spreadsheet to analyze
    # say
      # '$object1,$object2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2'
      # if $debug;

    # # if ($debug) {
    # # say "";
    # # say "Ground Control Points showing mismatches";
    # # print Dumper ( \%gcps );
    # # say "";
    # # }

    # if ( @xScaleAvg && @yScaleAvg ) {

        # #Smooth out the X and Y scales we previously calculated
        # calculateSmoothedRealWorldExtentsOfRaster();

        #Actually produce the georeferencing data via GDAL
        georeferenceTheRaster();

        #Count of entries in this array
        my $xScaleAvgSize = 0 + @xScaleAvg;

        #Count of entries in this array
        my $yScaleAvgSize = 0 + @yScaleAvg;

        say "xScaleAvgSize: $xScaleAvgSize, yScaleAvgSize: $yScaleAvgSize";

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

        # say "Touching $touchFile";

        # open( my $fh, ">", "$touchFile" )
          # or die "cannot open > $touchFile: $!";
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
        die
          "No output from mutool show.  Is it installed? Return code was $retval"
          if ( $_output eq "" || $retval != 0 );

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

sub returnRawPdf {

    #Returns the raw commands of a PDF
    say ":returnRawPdf" if $debug;
    my ($_output);

    if ( -e $main::outputPdfRaw ) {

        #If the raw output already exists just read it and return
        $_output = read_file($main::outputPdfRaw);
    }
    else {
        #create, save for future use, and return raw PDF output
        open( my $fh, '>', $main::outputPdfRaw )
          or die "Could not open file '$main::outputPdfRaw' $!";

        #Get number of objects/streams in the targetpdf
        my $_objectstreams = getNumberOfStreams();

        #Loop through each "stream" in the pdf and get the raw commands
        for ( my $i = 0 ; $i < ( $_objectstreams - 1 ) ; $i++ ) {
            $_output = $_output . qx(mutool show $main::targetPdf $i x);
            my $retval = $? >> 8;
            die
              "No output from mutool show.  Is it installed? Return code was $retval"
              if ( $_output eq "" || $retval != 0 );
        }

        #Write it out for future use
        print $fh $_output;
        close $fh;

    }

    #Return a reference to the output
    return \$_output;
}

sub findClosestBToA {

    #Find the closest B icon to each A

    my ( $hashRefA, $hashRefB ) = @_;

    #Maximum distance in points between centers
    my $maxDistance = 115;

    # say "findClosest $hashRefB to each $hashRefA" if $debug;

    foreach my $key ( sort keys %$hashRefA ) {

        #Start with a very high number so initially is closer than it
        my $distanceToClosest = 999999999999;

        # #Ignore entries that already have a bidir match
        # next if  $hashRefA->{$key}{"BidirectionalMatch"}= "True";

        foreach my $key2 ( sort keys %$hashRefB ) {

            # #Ignore entries that already have a bidir match
            # next if $hashRefB->{$key2}{"BidirectionalMatch"}= "True";

            my $distanceToBX =
              $hashRefB->{$key2}{"CenterX"} - $hashRefA->{$key}{"CenterX"};
            my $distanceToBY =
              $hashRefB->{$key2}{"CenterY"} - $hashRefA->{$key}{"CenterY"};

            my $hypotenuse = sqrt( $distanceToBX**2 + $distanceToBY**2 );

            #Ignore this textbox if it's further away than our max distance variables
            next
              if (
                (
                       $hypotenuse > $maxDistance
                    || $hypotenuse > $distanceToClosest
                )
              );

            #Update the distance to the closest obstacleTextBox center
            $distanceToClosest = $hypotenuse;

            #Set the "name" of this obstacleIcon to the text from obstacleTextBox
            #This is where we kind of guess (and can go wrong) since the closest height text is often not what should be associated with the icon
            # $hashRefA->{$key}{"Name"}     = $hashRefB->{$key2}{"Text"};
            #$hashRefA->{$key}{"TextBoxX"} = $hashRefB->{$key2}{"CenterX"};
            #$hashRefA->{$key}{"TextBoxY"} = $hashRefB->{$key2}{"CenterY"};
            $hashRefA->{$key}{"MatchedTo"} = $key2;
        }

    }
    if ($debug) {
        say "$hashRefA";
        print Dumper ($hashRefA);
        say "";
        say "$hashRefB";
        print Dumper ($hashRefB);
    }

    return;
}

sub findClosestLineToTextBox {

    #Find the closest B icon to each A

    my ( $hashRefTextBox, $hashRefLine, $preferredOrientation ) = @_;

    #Maximum distance in points between centers
    my $maxDistance = 70;

    # say "findClosest $hashRefLine to each $hashRefTextBox" if $debug;

    foreach my $key ( sort keys %$hashRefTextBox ) {

        #Start with a very high number so initially is closer than it
        my $distanceToClosest = 999999999999;

        # #Ignore entries that already have a bidir match
        # next if  $hashRefTextBox->{$key}{"BidirectionalMatch"}= "True";

        foreach my $key2 ( sort keys %$hashRefLine ) {

            # #Ignore entries that already have a bidir match
            # next if $hashRefLine->{$key2}{"BidirectionalMatch"}= "True";

            my $distanceToLineX =
              $hashRefLine->{$key2}{"X"} - $hashRefTextBox->{$key}{"CenterX"};
            my $distanceToLineX2 =
              $hashRefLine->{$key2}{"X2"} - $hashRefTextBox->{$key}{"CenterX"};

            my $distanceToLineY =
              $hashRefLine->{$key2}{"Y"} - $hashRefTextBox->{$key}{"CenterY"};
            my $distanceToLineY2 =
              $hashRefLine->{$key2}{"Y2"} - $hashRefTextBox->{$key}{"CenterY"};

            my $hypotenuse = sqrt( $distanceToLineX**2 + $distanceToLineY**2 );
            my $hypotenuse2 =
              sqrt( $distanceToLineX2**2 + $distanceToLineY2**2 );

            if ( $hypotenuse2 < $hypotenuse ) {
                $hypotenuse = $hypotenuse2;
            }

            #Ignore this textbox if it's further away than our max distance variables
            next
              if (
                (
                       $hypotenuse > $maxDistance
                    || $hypotenuse > $distanceToClosest
                )
              );

            if ($preferredOrientation =~ m/vertical/) {
                #Prefer more vertical lines
                next if ($hashRefLine->{$key2}{"Slope"} < 45);
}
            elsif ($preferredOrientation =~ m/horizontal/){
                next if ($hashRefLine->{$key2}{"Slope"} > 45);}
            #Update the distance to the closest obstacleTextBox center
            $distanceToClosest = $hypotenuse;

            #Set the "name" of this obstacleIcon to the text from obstacleTextBox
            #This is where we kind of guess (and can go wrong) since the closest height text is often not what should be associated with the icon
            # $hashRefTextBox->{$key}{"Name"}     = $hashRefLine->{$key2}{"Text"};
            #$hashRefTextBox->{$key}{"TextBoxX"} = $hashRefLine->{$key2}{"CenterX"};
            #$hashRefTextBox->{$key}{"TextBoxY"} = $hashRefLine->{$key2}{"CenterY"};
            $hashRefTextBox->{$key}{"MatchedTo"} = $key2;
            # $hashRefLine->{$key2}{"MatchedTo"}   = $key;
        }

    }
    if ($debug) {
        say "$hashRefTextBox";
        print Dumper ($hashRefTextBox);
        say "";

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
            next if ( abs( $hypotenuse < 5 ) );

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
        $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} = round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
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
            my $distanceHorizontal =  $tempLine[ $i + 4 ];
            my $distanceVertical      =  $tempLine[ $i + 5 ];

            my $hypotenuse =
              sqrt( $distanceHorizontal**2 + $distanceVertical**2 );

            # say "$distanceHorizontal,$distanceVertical,$hypotenuse";
            next if ( abs( $hypotenuse < 100 ) );

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
                    $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} = round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
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
          my $distanceHorizontal =  $tempLine[ $i + 6 ];
            my $distanceVertical      =  $tempLine[ $i + 7 ];

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
                    $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} = round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
        }

    }
    print Dumper ( \%main::latitudeAndLongitudeLines ) if $debug;

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

sub findLatitudeTextBoxes {
    say ":findLatitudeTextBoxes" if $debug;

    #-----------------------------------------------------------------------------------------------------------
    #Get list of potential latitude textboxes
    #For whatever dumb reason they're in raster axes (0,0 is top left, Y increases downwards)
    #   but in points coordinates
    my $latitudeTextBoxRegex =
      qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::latitudeRegex)</;

    foreach my $line (@main::pdfToTextBbox) {
        if ( $line =~ m/$latitudeTextBoxRegex/ ) {
            my $xMin = $1;

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $yMin = $2 - 2;
            my $xMax = $3 - 1;
            my $yMax = $4;
            my $text = $5;

            my $height = $yMax - $yMin;
            my $width  = $xMax - $xMin;

            my $rand = rand();

            my @tempText    = $text =~ m/(\d{2,})(\d\d\.?\d?).+(\w)$/ig;
            my $degrees     = $tempText[0];
            my $minutes     = $tempText[1];
            my $declination = $tempText[2];
            say "Degrees: $degrees, Minutes $minutes, declination:$declination" if $debug;
            my $decimal =
              coordinatetodecimal2( $degrees, $minutes, 0, $declination );
            # say $decimal;

            # say $seconds;
            # my $decimal = coordinatetodecimal($text);
            # $latitudeTextBoxes{ $1 . $2 }{"RasterX"} = $1 * $scaleFactorX;
            # $latitudeTextBoxes{ $1 . $2 }{"RasterY"} = $2 * $scaleFactorY;
            $main::latitudeTextBoxes{$rand}{"Width"}  = $width;
            $main::latitudeTextBoxes{$rand}{"Height"} = $height;
            $main::latitudeTextBoxes{$rand}{"Text"}   = $text;

            $main::latitudeTextBoxes{$rand}{"Decimal"} = $decimal;

            # $latitudeTextBoxes{ $rand }{"PdfX"}    = $xMin;
            # $latitudeTextBoxes{ $rand }{"PdfY"}    = $pdfYSize - $2;
            $main::latitudeTextBoxes{$rand}{"CenterX"} = $xMin + ( $width / 2 );

            # $latitudeTextBoxes{ $rand }{"CenterY"} = $pdfYSize - $2;
            $main::latitudeTextBoxes{$rand}{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::latitudeTextBoxes{$rand}{"IconsThatPointToMe"} = 0;
        }

    }

#TODO for portait oriented diagrams
   # my $latitudeTextBoxLandscapeRegex = qr/^xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex)<$
# ^xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex)<$
# ^xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::numberRegex)<$
# /m;


    # my @tempLine = $_output =~ /$latitudeTextBoxLandscapeRegex/ig;

    # my $tempLineLength = 0 + @tempLine;
    # my $tempLineCount  = $tempLineLength / 4;

    # if ( $tempLineLength >= 4 ) {
        # my $random = rand();
        # for ( my $i = 0 ; $i < $tempLineLength ; $i = $i + 4 ) {

            # #Let's only save long lines
            # my $distanceHorizontal = $tempLine[ $i + 2 ];
            # my $distanceVertical   = $tempLine[ $i + 3 ];

            # my $hypotenuse =
              # sqrt( $distanceHorizontal**2 + $distanceVertical**2 );

            # # say "$distanceHorizontal,$distanceVertical,$hypotenuse";
            # next if ( abs( $hypotenuse < 5 ) );

            # my $_X  = $tempLine[$i];
            # my $_Y  = $tempLine[ $i + 1 ];
            # my $_X2 = $_X + $tempLine[ $i + 2 ];
            # my $_Y2 = $_Y + $tempLine[ $i + 3 ];

            # #put them into a hash
            # $main::latitudeAndLongitudeLines{ $i . $random }{"X"}  = $_X;
            # $main::latitudeAndLongitudeLines{ $i . $random }{"Y"}  = $_Y;
            # $main::latitudeAndLongitudeLines{ $i . $random }{"X2"} = $_X2;
            # $main::latitudeAndLongitudeLines{ $i . $random }{"Y2"} = $_Y2;
            # $main::latitudeAndLongitudeLines{ $i . $random }{"CenterX"} =
              # ( $_X + $_X2 ) / 2;
            # $main::latitudeAndLongitudeLines{ $i . $random }{"CenterY"} =
              # ( $_Y + $_Y2 ) / 2;
        # $main::latitudeAndLongitudeLines{ $i . $random }{"Slope"} = round( slopeAngle( $_X, $_Y, $_X2, $_Y2 ) );
        # }

    # }
    print Dumper ( \%main::latitudeTextBoxes ) if $debug;

    if ($debug) {
        say "Found " .
          keys(%main::latitudeTextBoxes) . " Potential latitude text boxes";
        say "";
    }
    return;
}

sub findLongitudeTextBoxes {
    say ":findLongitudeTextBoxes" if $debug;

    #-----------------------------------------------------------------------------------------------------------
    #Get list of potential longitude textboxes
    #For whatever dumb reason they're in raster axes (0,0 is top left, Y increases downwards)
    #   but in points coordinates
    my $longitudeTextBoxRegex =
      qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::longitudeRegex)</;

    foreach my $line (@main::pdfToTextBbox) {
        if ( $line =~ m/$longitudeTextBoxRegex/ ) {
            my $xMin = $1;

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $yMin = $2 - 2;
            my $xMax = $3 - 1;
            my $yMax = $4;
            my $text = $5;

            my $height = $yMax - $yMin;
            my $width  = $xMax - $xMin;

            my $rand = rand();

            my @tempText    = $text =~ m/(\d{2,})(\d\d\.?\d?).+(\w)$/ig;
            my $degrees     = $tempText[0];
            my $minutes     = $tempText[1];
            my $declination = $tempText[2];
            # say "Degrees: $degrees, Minutes $minutes, declination:$declination";
            my $decimal =
              coordinatetodecimal2( $degrees, $minutes, 0, $declination );
            # say $decimal;

            # $longitudeTextBoxes{ $rand }{"RasterX"} = $1 * $scaleFactorX;
            # $longitudeTextBoxes{ $rand }{"RasterY"} = $2 * $scaleFactorY;
            $main::longitudeTextBoxes{$rand}{"Width"}  = $width;
            $main::longitudeTextBoxes{$rand}{"Height"} = $height;
            $main::longitudeTextBoxes{$rand}{"Text"}   = $text;

            $main::longitudeTextBoxes{$rand}{"Decimal"} = $decimal;

            # $longitudeTextBoxes{ $rand }{"PdfX"}    = $xMin;
            # $longitudeTextBoxes{ $rand }{"PdfY"}    = $pdfYSize - $2;
            $main::longitudeTextBoxes{$rand}{"CenterX"} =
              $xMin + ( $width / 2 );

            # $longitudeTextBoxes{ $rand }{"CenterY"} = $pdfYSize - $2;
            $main::longitudeTextBoxes{$rand}{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::longitudeTextBoxes{$rand}{"IconsThatPointToMe"} = 0;
        }

    }

    print Dumper ( \%main::longitudeTextBoxes ) if $debug;

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
            say "$textA  ($decimalA) intersects $textB ($decimalB) at $px,$py" if $debug;
           
            if ($px < 0 || $px > $main::pdfXSize || $py < 0 || $py > $main::pdfYSize) {
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
    my $d = ( $ax - $bx ) * ( $cy - $dy ) - ( $ay - $by ) * ( $cx - $dx );
    if (0 == $d) {
        return(0,0);
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
    }
    say $gdal_translateoutput if $debug;
    
    
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
    }
    say $gdalwarpCommandOutput if $debug;

  
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



sub addCombinedHashToGroundControlPoints {

    #Make a hash of all the GCPs to use, filtering them by using our mask bitmap
    my ( $type, $combinedHashRef ) = @_;

    #Add obstacles to Ground Control Points hash
    foreach my $key ( sort keys %$combinedHashRef ) {

        my $_pdfX = $combinedHashRef->{$key}{"GeoreferenceX"};
        my $_pdfY = $combinedHashRef->{$key}{"GeoreferenceY"};
        my $lon   = $combinedHashRef->{$key}{"Lon"};
        my $lat   = $combinedHashRef->{$key}{"Lat"};
        my $text  = $combinedHashRef->{$key}{"Text"};
        next unless ( $_pdfX && $_pdfY && $lon && $lat );
        my @pixels;
        my $_rasterX = $_pdfX * $main::scaleFactorX;
        my $_rasterY = $main::pngYSize - ( $_pdfY * $main::scaleFactorY );
        my $rand     = rand();

        #Make sure all our info is defined
        if ( $_rasterX && $_rasterY && $lon && $lat ) {

            #Get the color value of the pixel at the x,y of the GCP
            # my $pixelTextOutput;
            # qx(convert $outputPdfOutlines.png -format '%[pixel:p{$_rasterX,$_rasterY}]' info:-);
            #TODO Delete this since it's being done earlier already
            @pixels = $main::image->GetPixel( x => $_rasterX, y => $_rasterY );
            say "perlMagick $pixels[0]" if $debug;

            # say $pixelTextOutput if $debug;
            #srgb\(149,149,0\)|yellow
            # if ( $pixelTextOutput =~ /black|gray\(0,0,0\)/i  ) {
            if ( $pixels[0] eq 0 ) {

                #If it's any of the above strings then it's valid
                say "$_rasterX $_rasterY $lon $lat" if $debug;
                $main::gcps{ "$type" . $text . '-' . $rand }{"pngx"} =
                  $_rasterX;
                $main::gcps{ "$type" . $text . '-' . $rand }{"pngy"} =
                  $_rasterY;
                $main::gcps{ "$type" . $text . '-' . $rand }{"pdfx"} = $_pdfX;
                $main::gcps{ "$type" . $text . '-' . $rand }{"pdfy"} = $_pdfY;
                $main::gcps{ "$type" . $text . '-' . $rand }{"lon"}  = $lon;
                $main::gcps{ "$type" . $text . '-' . $rand }{"lat"}  = $lat;
            }
            else {
                say "$type $text is being ignored" if $debug;
            }

        }
    }
    return;
}

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

    #Get all of the text and respective bounding boxes in the PDF
    @main::pdfToTextBbox = qx(pdftotext $main::targetPdf -layout -bbox - );
    $main::retval        = $? >> 8;
    die
      "No output from pdftotext -bbox.  Is it installed? Return code was $main::retval"
      if ( @main::pdfToTextBbox eq "" || $main::retval != 0 );

    #Find potential latitude textboxes
    findLatitudeTextBoxes();

    #Find potential longitude textboxes
    findLongitudeTextBoxes();

    # #Find textboxes that are valid for both fix and GPS waypoints
    # findFixTextboxes();

    # #Find textboxes that are valid for navaids
    # findNavaidTextboxes();
    return;
}

sub joinIconTextboxAndDatabaseHashes {

    #Pass in references to hashes of icons, their textboxes, and their associated database info
    my ( $iconHashRef, $textboxHashRef, $databaseHashRef ) = @_;

    #A new hash of JOIN'd information
    my %hashOfMatchedPairs = ();
    my $key3               = 1;

    foreach my $key ( sort keys %$iconHashRef ) {

        #The key of the textboxHashRef this icon is matched to
        my $keyOfMatchedTextbox = $iconHashRef->{$key}{"MatchedTo"};

        #Don't do anything if it doesn't exist
        next unless $keyOfMatchedTextbox;

        #Check that the "MatchedTo" textboxHashRef points back to this icon
        #Clear the match  for the iconHashRef if it doesn't (ie isn't a two-way match)

        if ( ( $textboxHashRef->{$keyOfMatchedTextbox}{"MatchedTo"} ne $key ) )
        {
            #Clear the icon's matching since it isn't reciprocated
            say
              "Non-reciprocal match of textbox $keyOfMatchedTextbox to icon $key.  Clearing"
              if $debug;
            $iconHashRef->{$key}{"MatchedTo"} = "";
        }
        else {
            $iconHashRef->{$key}{"BidirectionalMatch"} = "True";
            $textboxHashRef->{$keyOfMatchedTextbox}{"BidirectionalMatch"} =
              "True";

            my $textOfMatchedTextbox =
              $textboxHashRef->{$keyOfMatchedTextbox}{"Text"};
            my $georeferenceX = $iconHashRef->{$key}{"GeoreferenceX"};
            my $georeferenceY = $iconHashRef->{$key}{"GeoreferenceY"};
            my $lat = $databaseHashRef->{$textOfMatchedTextbox}{"Lat"};
            my $lon = $databaseHashRef->{$textOfMatchedTextbox}{"Lon"};

            next
              unless ( $textOfMatchedTextbox
                && $georeferenceX
                && $georeferenceY
                && $lat
                && $lon );

            #This little section is to keep from using a navaid icon matched to a textbox containing the name
            #of a different type of navaid as a GCP
            my $iconType = $iconHashRef->{$key}{"Type"};
            my $databaseType =
              $databaseHashRef->{$textOfMatchedTextbox}{"Type"};

            if ( $iconType && $iconType =~ m/VOR/ ) {

                # say
                # "We've found a *VOR*, let's see if type of icon matches type of database entry";
                # say "$iconType";
                # say $keyOfMatchedTextbox;
                # say "$databaseType";
                next unless ( $iconType eq $databaseType );

                #TODO Check for nearby notToScaleIndicator icon (<30pt radius)
            }

            #Populate the values of our new combined hash
            $hashOfMatchedPairs{$key3}{"GeoreferenceX"} = $georeferenceX;
            $hashOfMatchedPairs{$key3}{"GeoreferenceY"} = $georeferenceY;
            $hashOfMatchedPairs{$key3}{"Lat"}           = $lat;
            $hashOfMatchedPairs{$key3}{"Lon"}           = $lon;
            $hashOfMatchedPairs{$key3}{"Text"}          = $textOfMatchedTextbox;
            $key3++;

        }

    }

    # if ($debug) {
    # say "";
    # say "hashOfMatchedPairs";
    # print Dumper (\%hashOfMatchedPairs);
    # }

    return ( \%hashOfMatchedPairs );
}

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



