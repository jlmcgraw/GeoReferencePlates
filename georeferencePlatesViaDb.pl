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
#-Relies on icons being drawn very specific ways
#    It won't work if these ever change
#-Relies on actual text being in PDF.
#    It seems that most, if not all, military plates have no text in them
#    We may be able to get around this with tesseract OCR but that will take some work
#
#Known issues:
#---------------------
#-Investigate not creating the intermediate PNG (guessing at dimensions)
#Our pixel/RealWorld ratios are hardcoded now for 300dpi, need to make dynamic per our DPI setting (or just base checks on PDF
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
use Params::Validate qw(:all);

# use Math::Round;
use Time::HiRes q/gettimeofday/;

#use Math::Polygon;
# use Acme::Tools qw(between);
use Image::Magick;
use File::Slurp;
use Storable;

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
our %statistics = ();

use vars qw/ %opt /;

#Define the valid command line options
my $opt_string = 'ntcspvobma:i:';
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

#Default to all plates for the SQL query
our $plateId = "%";

if ( $opt{t} ) {

    #If something  provided on the command line use it instead
    $plateId = $opt{t};
    say "Supplied plate ID: $plateId";
}

#Default to all statuses for the SQL query
our $plateStatus = "%";

if ( $opt{n} ) {

    #If something  provided on the command line use it instead
    $plateStatus = "ADDEDCHANGED";
    say "Doing only ADDEDCHANGED charts: $plateStatus";
}

our $shouldNotOverwriteVrt           = $opt{c};
our $shouldOutputStatistics          = $opt{s};
our $shouldSaveMarkedPdf             = $opt{p};
our $debug                           = $opt{v};
our $shouldRecreateOutlineFiles      = $opt{o};
our $shouldSaveBadRatio              = $opt{b};
our $shouldUseMultipleObstacles      = $opt{m};
our $shouldOnlyProcessAddedOrChanged = $opt{n};

#database of metadata for dtpp
my $dtppDbh =
     DBI->connect( "dbi:SQLite:dbname=./dtpp.db", "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

#-----------------------------------------------
#Open the locations database
our $dbh;
my $sth;

$dbh = DBI->connect( "dbi:SQLite:dbname=./locationinfo.db",
    "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

our (
    $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    $MILITARY_USE, $COPTER_USE,  $STATE_ID
);

$dtppDbh->do("PRAGMA page_size=4096");
$dtppDbh->do("PRAGMA synchronous=OFF");

my $selectStatement = "SELECT  
      D.TPP_VOLUME, D.FAA_CODE, D.CHART_SEQ, D.CHART_CODE, 
      D.CHART_NAME, D.USER_ACTION, D.PDF_NAME, D.FAANFD18_CODE, 
      D.MILITARY_USE, D.COPTER_USE, D.STATE_ID,
      DG.STATUS
    FROM 
      dtpp AS D 
    JOIN 
      dtppGeo AS DG 
    ON 
      D.PDF_NAME=DG.PDF_NAME
    WHERE  
      D.CHART_CODE = 'IAP'
        AND 
      DG.STATUS LIKE  '$plateStatus' 
        AND 
      D.PDF_NAME LIKE  '$plateId' 
        AND 
      D.FAA_CODE LIKE  '$airportId' 
        AND
      D.STATE_ID LIKE  '$stateId'
      ";

#Alter SQL query if  we only want to do added/changed charts
if ($shouldOnlyProcessAddedOrChanged) {
    $selectStatement = "SELECT  
      D.TPP_VOLUME, D.FAA_CODE, D.CHART_SEQ, D.CHART_CODE, 
      D.CHART_NAME, D.USER_ACTION, D.PDF_NAME, D.FAANFD18_CODE, 
      D.MILITARY_USE, D.COPTER_USE, D.STATE_ID,
      DG.STATUS
    FROM 
      dtpp AS D 
    JOIN 
      dtppGeo AS DG 
    ON 
      D.PDF_NAME=DG.PDF_NAME
    WHERE  
      D.CHART_CODE = 'IAP' 
        AND 
      D.FAA_CODE LIKE  '$airportId' 
        AND
      D.STATE_ID LIKE  '$stateId'
       AND
      (
      D.USER_ACTION = 'A'
      OR
      D.USER_ACTION = 'C'
      )
      ";

}

#Query the dtpp database for desired charts
my $dtppSth = $dtppDbh->prepare($selectStatement);
$dtppSth->execute();

my $_allSqlQueryResults = $dtppSth->fetchall_arrayref();
my $_rows               = $dtppSth->rows;
say "Processing $_rows charts";
my $completedCount = 0;

#Process each plate returned by our query
foreach my $_row (@$_allSqlQueryResults) {

    (
        $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
        $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
        $MILITARY_USE, $COPTER_USE,  $STATE_ID
    ) = @$_row;

    say
      "$TPP_VOLUME, $FAA_CODE, $CHART_SEQ, $CHART_CODE, $CHART_NAME, $USER_ACTION, $PDF_NAME, $FAANFD18_CODE, $MILITARY_USE, $COPTER_USE, $STATE_ID";

    #Execute the main loop for this plate
    doAPlate();    #PDF_NAME, $dtppDirectory
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

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------
#The main loop
sub doAPlate {

    #     #Validate and set input parameters to this function
    #     my ( $_airportTextboxHashReference, $_lineHashReference, $_upperYCutoff ) =
    #       validate_pos(
    #         @_,
    #         { type => HASHREF },
    #         { type => HASHREF },
    #         { type => SCALAR },
    #       );

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
        '$runwayIconsCount'                => "0",
        'isPortraitOrientation'            => "0",
        '$xPixelSkew'                      => "0",
        '$yPixelSkew'                      => "0",
        '$status'                          => "0"
    );

    #FQN of the PDF for this chart
    our $targetPdf = $dtppDirectory . $PDF_NAME;

    my $retval;

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
    our $storedGcpHash     = $dir . "gcp-" . $filename . "-hash.txt";

    # our $targetvrt         = $dir . $filename . ".vrt";
    our $targetVrtFile =
      $STATE_ID . "-" . $FAA_CODE . "-" . $PDF_NAME . "-" . $CHART_NAME;

    # convert spaces, ., and slashes to dash
    $targetVrtFile =~ s/[\s \/ \\ \. \( \)]/-/xg;
    our $targetVrtBadRatio = $dir . "badRatio-" . $targetVrtFile . ".vrt";
    our $touchFile         = $dir . "noPoints-" . $targetVrtFile . ".vrt";
    our $targetvrt         = $dir . $targetVrtFile . ".vrt";
    our $targetVrtFile2    = "warped" . $targetVrtFile;
    our $targetvrt2        = $dir . $targetVrtFile2 . ".vrt";
    our $targetStatistics  = "./statistics.csv";

    #Say what our input PDF and output VRT are
    say $targetPdf;
    say $targetvrt;

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
        return (1);
    }

    #Abort if the chart says it's not to scale
    foreach my $line (@pdftotext) {
        $line =~ s/\s//gx;
        if ( $line =~ m/chartnott/i ) {
            say "$targetPdf not to scale, can't georeference";
            $statistics{'$status'} = "AUTOBAD";
            writeStatistics() if $shouldOutputStatistics;
            return (1);
        }

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
    our %icons                      = ();
    our %obstacleIcons              = ();
    our %fixIcons                   = ();
    our %gpsWaypointIcons           = ();
    our %navaidIcons                = ();
    our %horizontalAndVerticalLines = ();
    our %insetBoxes                 = ();
    our %largeBoxes                 = ();
    our %insetCircles               = ();
    our %notToScaleIndicator        = ();
    our %runwayIcons                = ();
    our %runwaysFromDatabase        = ();
    our %runwaysToDraw              = ();
    our @validRunwaySlopes          = ();
    our %gcps                       = ();

    #Don't do anything PDF related unless we've asked to create one on the command line

    our ( $pdf, $page );

    if ($shouldSaveMarkedPdf) {
        $pdf = PDF::API2->open($targetPdf);

        #Set up the various types of boxes to draw on the output PDF
        $page = $pdf->openpage(1);

    }

    if ( !-e $storedGcpHash ) {

        #Look up runways for this airport from the database and populate the array of slopes we're looking for for runway lines
        #(airportId,%runwaysFromDatabase,runwaysToDraw)
        findRunwaysInDatabase();

        # say "runwaysFromDatabase";
        # print Dumper ( \%runwaysFromDatabase );
        # say "";

        # #Get number of objects/streams in targetPdf
        our $objectstreams = getNumberOfStreams();    #(targetPdf)

        # #Loop through each of the streams in the PDF and find all of the icons we're interested in
        findAllIcons();                               #(objectstreams,$targetPdf

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
        findNavaidsNearAirport();

        #A list of valid navaid names around the airport
        our @validNavaidNames = keys %navaids_from_db;
        our $validNavaidNames = join( " ", @validNavaidNames );

        #Find all of the text boxes in the PDF
        our @pdfToTextBbox     = ();
        our %fixTextboxes      = ();
        our %obstacleTextBoxes = ();
        our %vorTextboxes      = ();

        findAllTextboxes();

        #----------------------------------------------------------------------------------------------------------
        #Modify the PDF

        our ( $pdfOutlines,  $pageOutlines );
        our ( $lowerYCutoff, $upperYCutoff );

        #Don't recreate the outlines PDF if it already exists unless the user specifically wants to
        if ( !-e $outputPdfOutlines || $shouldRecreateOutlineFiles ) {
            createOutlinesPdf();
        }

        #---------------------------------------------------
        #Convert the outlines PDF to a PNG
        our ( $image, $perlMagickStatus );
        $image = Image::Magick->new;

        #Either create or load the masking file for determining which portions of the image to use for GCPs
        processMaskingFile();

        #Using the created mask file, eliminate icons and textboxes from further consideration
        removeIconsAndTextboxesInMaskedAreas( "Obstacle Icon",
            \%obstacleIcons );
        removeIconsAndTextboxesInMaskedAreas( "Obstacle TextBox",
            \%obstacleTextBoxes );
        removeIconsAndTextboxesInMaskedAreas( "Fix Icon",    \%fixIcons );
        removeIconsAndTextboxesInMaskedAreas( "Fix TextBox", \%fixTextboxes );
        removeIconsAndTextboxesInMaskedAreas( "Navaid Icon", \%navaidIcons );
        removeIconsAndTextboxesInMaskedAreas( "Navaid TextBox",
            \%vorTextboxes );
        removeIconsAndTextboxesInMaskedAreas( "GPS Icon", \%gpsWaypointIcons );
        removeIconsAndTextboxesInMaskedAreas( "Runway Lines", \%runwayIcons );

        if ($debug) {
            say "runwayIcons";
            print Dumper ( \%runwayIcons );
            say "runwaysFromDatabase";
            print Dumper ( \%runwaysFromDatabase );
        }

        #Draw boxes around the icons and textboxes we've found so far
        outlineEverythingWeFound() if $shouldSaveMarkedPdf;

        #------------------------------------------------------------------------------------------------------------------------------------------
        #Runways
        our %matchedRunIconsToDatabase = ();

        #If we have the same number of icons as unique runways
        #if ( scalar keys %runwayIcons == scalar keys %runwaysFromDatabase ) {
        foreach my $key ( keys %runwayIcons ) {
            foreach my $key2 ( keys %runwaysFromDatabase ) {

                #Find an icon and database entry that match slopes
                #Margin of error here is +- 2 degrees,
                #TODO: Narrow this as much as possible
                if (
                    abs(
                        $runwayIcons{$key}{Slope} -
                          $runwaysFromDatabase{$key2}{Slope}
                    ) <= 2
                  )
                {
                    my $x  = $runwayIcons{$key}{"X"};
                    my $y  = $runwayIcons{$key}{"Y"};
                    my $x2 = $runwayIcons{$key}{"X2"};
                    my $y2 = $runwayIcons{$key}{"Y2"};

                    my $HEHeading   = $runwaysFromDatabase{$key2}{HEHeading};
                    my $HELatitude  = $runwaysFromDatabase{$key2}{HELatitude};
                    my $HELongitude = $runwaysFromDatabase{$key2}{HELongitude};
                    my $LEHeading   = $runwaysFromDatabase{$key2}{LEHeading};
                    my $LELatitude  = $runwaysFromDatabase{$key2}{LELatitude};
                    my $LELongitude = $runwaysFromDatabase{$key2}{LELongitude};

                    #If the line matches the LEHeading vector
                    if (
                        abs(
                            $runwayIcons{$key}{TrueHeading} -
                              $runwaysFromDatabase{$key2}{LEHeading}
                        ) <= 1
                      )
                    {
                        #TODO: Simplify these two choices more
                        say "Matched LE" if $debug;

                        $matchedRunIconsToDatabase{$LEHeading}{"GeoreferenceX"}
                          = $x;
                        $matchedRunIconsToDatabase{$LEHeading}{"GeoreferenceY"}
                          = $y;

                        $matchedRunIconsToDatabase{$HEHeading}{"GeoreferenceX"}
                          = $x2;
                        $matchedRunIconsToDatabase{$HEHeading}{"GeoreferenceY"}
                          = $y2;

                    }
                    else {
                        #It has to match the HEHeading vector
                        #Line starts from the High End (HE()
                        say "Matched HE" if $debug;
                        $matchedRunIconsToDatabase{$LEHeading}{"GeoreferenceX"}
                          = $x2;
                        $matchedRunIconsToDatabase{$LEHeading}{"GeoreferenceY"}
                          = $y2;

                        $matchedRunIconsToDatabase{$HEHeading}{"GeoreferenceX"}
                          = $x;
                        $matchedRunIconsToDatabase{$HEHeading}{"GeoreferenceY"}
                          = $y;

                    }
                    $matchedRunIconsToDatabase{$LEHeading}{"Lon"} =
                      $LELongitude;
                    $matchedRunIconsToDatabase{$LEHeading}{"Lat"} = $LELatitude;
                    $matchedRunIconsToDatabase{$LEHeading}{"Text"} =
                      "Runway" . $LEHeading;
                    $matchedRunIconsToDatabase{$LEHeading}{"Name"} = $key2;

                    $matchedRunIconsToDatabase{$HEHeading}{"Lon"} =
                      $HELongitude;
                    $matchedRunIconsToDatabase{$HEHeading}{"Lat"} = $HELatitude;
                    $matchedRunIconsToDatabase{$HEHeading}{"Text"} =
                      "Runway" . $HEHeading;
                    $matchedRunIconsToDatabase{$HEHeading}{"Name"} = $key2;
                }
            }
        }

        if ($debug) {
            say "matchedRunIconsToDatabase";
            print Dumper ( \%matchedRunIconsToDatabase );
        }

        #----------------------------------------------------------------------------------------------------------------------------------
        #Everything to do with obstacles
        #Get a list of unique potential obstacle heights from the pdftotext array
        #my @obstacle_heights = findObstacleHeightTexts(@pdftotext);
        our @obstacle_heights = testfindObstacleHeightTexts(@pdfToTextBbox);

        #Find all obstacles within our defined distance from the airport that have a height in the list of potential obstacleTextBoxes and are unique
        our %unique_obstacles_from_db = ();
        our $unique_obstacles_from_dbCount;
        findObstaclesNearAirport( \%unique_obstacles_from_db );

        #Try to find closest obstacleTextBox center to each obstacleIcon center and then do the reverse
        findClosestBToA( \%obstacleIcons,     \%obstacleTextBoxes );
        findClosestBToA( \%obstacleTextBoxes, \%obstacleIcons, );

        #Make sure there is a bi-directional match between icon and textbox
        #Returns a reference to a hash which combines info from icon, textbox and database
        my $matchedObstacleIconsToTextBoxes =
          joinIconTextboxAndDatabaseHashes( \%obstacleIcons,
            \%obstacleTextBoxes, \%unique_obstacles_from_db );

        if ($debug) {
            say "matchedObstacleIconsToTextBoxes";
            print Dumper ($matchedObstacleIconsToTextBoxes);
        }

        #Draw a line from obstacle icon to matched text boxes
        if ($shouldSaveMarkedPdf) {
            drawLineFromEachIconToMatchedTextBox( \%obstacleIcons,
                \%obstacleTextBoxes );
            outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb();
        }

        #------------------------------------------------------------------------------------------------------------------------------------------
        #Everything to do with fixes
        #
        #Find fixes near the airport
        #Updates %fixes_from_db
        our %fixes_from_db = ();
        findFixesNearAirport();

        #Orange outline fixTextboxes that have a valid fix name in them
        outlineValidFixTextBoxes() if $shouldSaveMarkedPdf;

        #Delete an icon if the not-to-scale squiggly is too close to it
        findClosestSquigglyToA( \%fixIcons, \%notToScaleIndicator );

        #Try to find closest TextBox center to each Icon center
        #and then do the reverse
        findClosestBToA( \%fixIcons,     \%fixTextboxes );
        findClosestBToA( \%fixTextboxes, \%fixIcons, );

        #Make sure there is a bi-directional match between icon and textbox
        #Returns a reference to a hash of matched pairs
        my $matchedFixIconsToTextBoxes =
          joinIconTextboxAndDatabaseHashes( \%fixIcons, \%fixTextboxes,
            \%fixes_from_db );

        if ($debug) {

            say "matchedFixIconsToTextBoxes";
            print Dumper ($matchedFixIconsToTextBoxes);
            say "";

            # say "fix icons";
            # print Dumper ( \%fixIcons );
            # say "";
            # say "fixTextboxes";
            # print Dumper ( \%fixTextboxes );
            # say "";
        }

        #Indicate which textbox we matched to
        drawLineFromEachIconToMatchedTextBox( \%fixIcons, \%fixTextboxes )
          if $shouldSaveMarkedPdf;

        #---------------------------------------------------------------------------------------------------------------------------------------
        #Everything to do with GPS waypoints
        #
        #Find GPS waypoints near the airport
        our %gpswaypoints_from_db = ();
        findGpsWaypointsNearAirport();

        #Orange outline fixTextboxes that have a valid GPS waypoint name in them
        outlineValidGpsWaypointTextBoxes() if $shouldSaveMarkedPdf;

        #Delete an icon if the not-to-scale squiggly is too close to it
        say
          'findClosestSquigglyToA( \%gpsWaypointIcons,     \%notToScaleIndicator )'
          if $debug;
        findClosestSquigglyToA( \%gpsWaypointIcons, \%notToScaleIndicator );

        #Try to find closest TextBox center to each Icon center and then do the reverse
        say 'findClosestBToA( \%gpsWaypointIcons, \%fixTextboxes )' if $debug;
        findClosestBToA( \%gpsWaypointIcons, \%fixTextboxes );

        say 'findClosestBToA( \%fixTextboxes,     \%gpsWaypointIcons )'
          if $debug;
        findClosestBToA( \%fixTextboxes, \%gpsWaypointIcons );

        say 'my $matchedGpsWaypointIconsToTextBoxes =
  joinIconTextboxAndDatabaseHashes( \%gpsWaypointIcons, \%fixTextboxes,
    \%gpswaypoints_from_db )' if $debug;

        my $matchedGpsWaypointIconsToTextBoxes =
          joinIconTextboxAndDatabaseHashes( \%gpsWaypointIcons, \%fixTextboxes,
            \%gpswaypoints_from_db );

        if ($debug) {

            # say "gpswaypoints_from_db";
            # print Dumper ( \%gpswaypoints_from_db );
            say "";
            say "matchedGpsWaypointIconsToTextBoxes";
            print Dumper ($matchedGpsWaypointIconsToTextBoxes);
            say "";

            # say "fixTextboxes";
            # print Dumper ( \%fixTextboxes );
            # say "";
        }

        drawLineFromEachIconToMatchedTextBox( \%gpsWaypointIcons,
            \%fixTextboxes )
          if $shouldSaveMarkedPdf;

        #---------------------------------------------------------------------------------------------------------------------------------------
        #Everything to do with navaids
        #

        #Orange outline navaid textboxes that have a valid navaid name in them
        outlineValidNavaidTextBoxes() if $shouldSaveMarkedPdf;

        #Delete an icon if the not-to-scale squiggly is too close to it
        findClosestSquigglyToA( \%navaidIcons, \%notToScaleIndicator );

        #Try to find closest TextBox center to each Icon center and then do the reverse
        say 'findClosestBToA( \%navaidIcons,  \%vorTextboxes )' if $debug;
        findClosestBToA( \%navaidIcons, \%vorTextboxes );
        say 'findClosestBToA( \%vorTextboxes, \%navaidIcons )' if $debug;
        findClosestBToA( \%vorTextboxes, \%navaidIcons );

        say
          'joinIconTextboxAndDatabaseHashes( \%navaidIcons, \%vorTextboxes, \%navaids_from_db )'
          if $debug;
        my $matchedNavaidIconsToTextBoxes =
          joinIconTextboxAndDatabaseHashes( \%navaidIcons, \%vorTextboxes,
            \%navaids_from_db );

        #navaids_from_db should now only have navaids that are mentioned on the PDF
        if ($debug) {
            say "";
            say "matchedNavaidIconsToTextBoxes";
            print Dumper ($matchedNavaidIconsToTextBoxes);
            say "";

            # say "navaids_from_db";
            # print Dumper ( \%navaids_from_db );
            # say "";
            # say "Navaid icons";
            # print Dumper ( \%navaidIcons );
            # say "";
        }

        #Draw a line from icon to closest text box
        drawLineFromEachIconToMatchedTextBox( \%navaidIcons, \%vorTextboxes )
          if $shouldSaveMarkedPdf;

        #---------------------------------------------------------------------------------------------------------------------------------------------------
        #Create the combined hash of Ground Control Points

        #Add Runway endpoints to Ground Control Points hash
        addCombinedHashToGroundControlPoints( "runway",
            \%matchedRunIconsToDatabase );

        #Add Obstacles to Ground Control Points hash
        addCombinedHashToGroundControlPoints( "obstacle",
            $matchedObstacleIconsToTextBoxes );

        #Add Fixes to Ground Control Points hash
        addCombinedHashToGroundControlPoints( "fix",
            $matchedFixIconsToTextBoxes );

        #Add Navaids to Ground Control Points hash
        addCombinedHashToGroundControlPoints( "navaid",
            $matchedNavaidIconsToTextBoxes );

        #Add GPS waypoints to Ground Control Points hash
        addCombinedHashToGroundControlPoints( "gps",
            $matchedGpsWaypointIconsToTextBoxes );
    }
    else {
        say "Loading existing hash table $storedGcpHash";
        my $gcpHashref = retrieve($storedGcpHash);

        #Copy to GCP hash
        %gcps = %{$gcpHashref};

    }
    if ($debug) {
        say "";
        say "Combined Ground Control Points";
        print Dumper ( \%gcps );
        say "";
    }

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

        $statistics{'$status'} = "AUTOBAD";
        writeStatistics() if $shouldOutputStatistics;
        return (1);
    }

    #Calculate the rough X and Y scale values
    if ( $gcpCount == 1 ) {
        say "Found 1 ground control points in $targetPdf";
        say "Touching $touchFile";
        open( my $fh, ">", "$touchFile" )
          or die "cannot open > $touchFile: $!";
        close($fh);

        #Is it better to guess or do nothing?  I think we should do nothing
        #calculateRoughRealWorldExtentsOfRasterWithOneGCP();
        $statistics{'$status'} = "AUTOBAD";
        writeStatistics() if $shouldOutputStatistics;
        return (1);
    }
    else {
        calculateRoughRealWorldExtentsOfRaster();
    }

    #Print a header so you could paste the following output into a spreadsheet to analyze
    say
      '$object1,$object2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2'
      if $debug;

    # if ($debug) {
    # say "";
    # say "Ground Control Points showing mismatches";
    # print Dumper ( \%gcps );
    # say "";
    # }

    #Did we find come valid GCPs?
    if ( @xScaleAvg && @yScaleAvg ) {

        #Smooth out the X and Y scales we previously calculated
        calculateSmoothedRealWorldExtentsOfRaster();

        #Actually produce the georeferencing data via GDAL
        georeferenceTheRaster();

        #Count of entries in this array
        my $xScaleAvgSize = 0 + @xScaleAvg;

        #Count of entries in this array
        my $yScaleAvgSize = 0 + @yScaleAvg;

        say "xScaleAvgSize: $xScaleAvgSize, yScaleAvgSize: $yScaleAvgSize"
          if $debug;

        #These are expected to be negative for affine transform
        if ( $yMedian > 0 ) { $yMedian = -($yMedian); }
        if ( $yAvg > 0 )    { $yAvg    = -($yAvg); }

        #Save statistics
        $statistics{'$xAvg'}          = $xAvg;
        $statistics{'$xMedian'}       = $xMedian;
        $statistics{'$xScaleAvgSize'} = $xScaleAvgSize;
        $statistics{'$yAvg'}          = $yAvg;
        $statistics{'$yMedian'}       = $yMedian;
        $statistics{'$yScaleAvgSize'} = $yScaleAvgSize;
        $statistics{'$lonLatRatio'}   = $lonLatRatio;

    }
    else {
        say
          "No points actually added to the scale arrays for $targetPdf, can't georeference";

        say "Touching $touchFile";
        $statistics{'$status'} = "AUTOBAD";
        open( my $fh, ">", "$touchFile" )
          or die "cannot open > $touchFile: $!";
        close($fh);
    }

    #Write out the statistics of this file if requested
    writeStatistics() if $shouldOutputStatistics;

    #Since we've calculated our extents, try drawing some features on the outputPdf to see if they align
    #With our work
    drawFeaturesOnPdf() if $shouldSaveMarkedPdf;

    say "TargetLonLatRatio: "
      . $statistics{'$targetLonLatRatio'}
      . ",  LonLatRatio: $lonLatRatio , Difference: "
      . ( $statistics{'$targetLonLatRatio'} - $lonLatRatio );

    return;
}

sub findObstacleHeightTexts {

    #The text from the PDF
    my @_pdftotext = @_;
    my @_obstacle_heights;

    foreach my $line (@_pdftotext) {

        #Find numbers that match our obstacle height regex
        if ( $line =~ m/^($main::obstacleHeightRegex)$/ ) {

            #Any height over 30000 is obviously bogus
            next if $1 > 30000;
            push @_obstacle_heights, $1;
        }

    }

    #Remove all entries that aren't unique
    @_obstacle_heights = onlyuniq(@_obstacle_heights);

    if ($debug) {
        say "Potential obstacle heights from PDF";
        print join( " ", @_obstacle_heights ), "\n";

        say "Unique potential obstacle heights from PDF";
        print join( " ", @_obstacle_heights ), "\n";
    }
    return @_obstacle_heights;
}

sub testfindObstacleHeightTexts {

    #The text from the PDF
    my @_pdftotext = @_;
    my @_obstacle_heights;

    foreach my $line (@_pdftotext) {

        # say $line;
        #Find numbers that match our obstacle height regex
        if ( $line =~
            m/xMin="[\d\.]+" yMin="[\d\.]+" xMax="[\d\.]+" yMax="[\d\.]+">($main::obstacleHeightRegex)</
          )
        {

            #Any height over 30000 is obviously bogus
            next if $1 > 30000;
            push @_obstacle_heights, $1;
        }

    }

    #Remove all entries that aren't unique
    @_obstacle_heights = onlyuniq(@_obstacle_heights);

    if ($debug) {
        say "Potential obstacle heights from PDF";
        print join( " ", @_obstacle_heights ), "\n";

        say "Unique potential obstacle heights from PDF";
        print join( " ", @_obstacle_heights ), "\n";
    }
    return @_obstacle_heights;
}

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

    foreach my $key ( sort keys %main::horizontalAndVerticalLines ) {

        my ($lines) = $main::page->gfx;
        $lines->strokecolor('yellow');
        $lines->linewidth(5);
        $lines->move(
            $main::horizontalAndVerticalLines{$key}{"X"},
            $main::horizontalAndVerticalLines{$key}{"Y"}
        );
        $lines->line(
            $main::horizontalAndVerticalLines{$key}{"X2"},
            $main::horizontalAndVerticalLines{$key}{"Y2"}
        );

        $lines->stroke;
    }
    foreach my $key ( sort keys %main::insetBoxes ) {

        my ($insetBox) = $main::page->gfx;
        $insetBox->strokecolor('cyan');
        $insetBox->linewidth(.1);
        $insetBox->rect(
            $main::insetBoxes{$key}{X},
            $main::insetBoxes{$key}{Y},
            $main::insetBoxes{$key}{Width},
            $main::insetBoxes{$key}{Height},

        );

        $insetBox->stroke;
    }
    foreach my $key ( sort keys %main::largeBoxes ) {

        my ($largeBox) = $main::page->gfx;
        $largeBox->strokecolor('yellow');
        $largeBox->linewidth(5);
        $largeBox->rect(
            $main::largeBoxes{$key}{X},     $main::largeBoxes{$key}{Y},
            $main::largeBoxes{$key}{Width}, $main::largeBoxes{$key}{Height},
        );

        $largeBox->stroke;
    }

    foreach my $key ( sort keys %main::insetCircles ) {

        my ($insetCircle) = $main::page->gfx;
        $insetCircle->circle(
            $main::insetCircles{$key}{X},
            $main::insetCircles{$key}{Y},
            $main::insetCircles{$key}{Radius},
        );
        $insetCircle->strokecolor('cyan');
        $insetCircle->linewidth(.1);
        $insetCircle->stroke;
    }
    foreach my $key ( sort keys %main::obstacleIcons ) {

        my ($obstacle_box) = $main::page->gfx;
        $obstacle_box->rect(
            $main::obstacleIcons{$key}{"CenterX"} -
              ( $main::obstacleIcons{$key}{"Width"} / 2 ),
            $main::obstacleIcons{$key}{"CenterY"} -
              ( $main::obstacleIcons{$key}{"Height"} / 2 ),
            $main::obstacleIcons{$key}{"Width"},
            $main::obstacleIcons{$key}{"Height"}
        );
        $obstacle_box->strokecolor('red');
        $obstacle_box->linewidth(.1);
        $obstacle_box->stroke;

        #Uncomment this to show the radius we're looking in for icon->text matches
        # $obstacle_box->circle(
        # $obstacleIcons{$key}{X},
        # $obstacleIcons{$key}{Y},
        # $maxDistanceFromObstacleIconToTextBox
        # );
        # $obstacle_box->strokecolor('red');
        # $obstacle_box->linewidth(.05);
        # $obstacle_box->stroke;

    }

    foreach my $key ( sort keys %main::fixIcons ) {
        my ($fix_box) = $main::page->gfx;
        $fix_box->rect(
            $main::fixIcons{$key}{"CenterX"} -
              ( $main::fixIcons{$key}{"Width"} / 2 ),
            $main::fixIcons{$key}{"CenterY"} -
              ( $main::fixIcons{$key}{"Height"} / 2 ),
            $main::fixIcons{$key}{"Width"},
            $main::fixIcons{$key}{"Height"}
        );
        $fix_box->strokecolor('red');
        $fix_box->linewidth(.1);
        $fix_box->stroke;
    }
    foreach my $key ( sort keys %main::fixTextboxes ) {
        my ($fixTextBox) = $main::page->gfx;
        $fixTextBox->strokecolor('red');
        $fixTextBox->linewidth(1);
        $fixTextBox->rect(
            $main::fixTextboxes{$key}{"CenterX"} -
              ( $main::fixTextboxes{$key}{"Width"} / 2 ),
            $main::fixTextboxes{$key}{"CenterY"} -
              ( $main::fixTextboxes{$key}{"Height"} / 2 ),
            $main::fixTextboxes{$key}{"Width"},
            $main::fixTextboxes{$key}{"Height"}
        );

        $fixTextBox->stroke;
    }
    foreach my $key ( sort keys %main::gpsWaypointIcons ) {
        my ($gpsWaypointBox) = $main::page->gfx;
        $gpsWaypointBox->rect(
            $main::gpsWaypointIcons{$key}{"CenterX"} -
              ( $main::gpsWaypointIcons{$key}{"Width"} / 2 ),
            $main::gpsWaypointIcons{$key}{"CenterY"} -
              ( $main::gpsWaypointIcons{$key}{"Height"} / 2 ),
            $main::gpsWaypointIcons{$key}{"Height"},
            $main::gpsWaypointIcons{$key}{"Width"}
        );
        $gpsWaypointBox->strokecolor('red');
        $gpsWaypointBox->linewidth(.1);
        $gpsWaypointBox->stroke;
    }

    # foreach my $key ( sort keys %finalApproachFixIcons ) {
    # my ($faf_box) = $page->gfx;
    # $faf_box->rect(
    # $finalApproachFixIcons{$key}{X} - 5,
    # $finalApproachFixIcons{$key}{Y} - 5,
    # 10, 10
    # );
    # $faf_box->strokecolor('red');
    # $faf_box->linewidth(.1);
    # $faf_box->stroke;
    # }

    # foreach my $key ( sort keys %visualDescentPointIcons ) {
    # my ($vdp_box) = $page->gfx;
    # $vdp_box->rect(
    # $visualDescentPointIcons{$key}{X} - 3,
    # $visualDescentPointIcons{$key}{Y} - 7,
    # 8, 8
    # );
    # $vdp_box->strokecolor('red');
    # $vdp_box->linewidth(.1);
    # $vdp_box->stroke;
    # }

    foreach my $key ( sort keys %main::navaidIcons ) {
        my ($navaidBox) = $main::page->gfx;
        $navaidBox->rect(
            $main::navaidIcons{$key}{"CenterX"} -
              ( $main::navaidIcons{$key}{"Width"} / 2 ),
            $main::navaidIcons{$key}{"CenterY"} -
              ( $main::navaidIcons{$key}{"Height"} / 2 ),
            $main::navaidIcons{$key}{"Width"},
            $main::navaidIcons{$key}{"Height"}
        );
        $navaidBox->strokecolor('red');
        $navaidBox->linewidth(.1);
        $navaidBox->stroke;
    }
    foreach my $key ( sort keys %main::vorTextboxes ) {
        my ($navaidTextBox) = $main::page->gfx;
        $navaidTextBox->rect(
            $main::vorTextboxes{$key}{"CenterX"} -
              ( $main::vorTextboxes{$key}{"Width"} / 2 ),
            $main::vorTextboxes{$key}{"CenterY"} +
              ( $main::vorTextboxes{$key}{"Height"} / 2 ),
            $main::vorTextboxes{$key}{"Width"},
            -( $main::vorTextboxes{$key}{"Height"} )
        );
        $navaidTextBox->strokecolor('red');
        $navaidTextBox->linewidth(1);
        $navaidTextBox->stroke;
    }
    foreach my $key ( sort keys %main::notToScaleIndicator ) {
        my ($navaidTextBox) = $main::page->gfx;
        $navaidTextBox->rect(
            $main::notToScaleIndicator{$key}{"CenterX"},
            $main::notToScaleIndicator{$key}{"CenterY"},
            4, 10
        );
        $navaidTextBox->strokecolor('red');
        $navaidTextBox->linewidth(1);
        $navaidTextBox->stroke;
    }
    return;
}

sub calculateSmootherValuesOfArray {
    my ($targetArrayRef)    = @_;
    my $avg                 = &average($targetArrayRef);
    my $median              = &median($targetArrayRef);
    my $stdDev              = &stdev($targetArrayRef);
    my $lengthOfTargetArray = $#$targetArrayRef;

    if ($debug) {
        say "";
        say "Initial length of array: $lengthOfTargetArray";
        say "Smoothed values: average: "
          . sprintf( "%.10g", $avg )
          . "\tstdev: "
          . sprintf( "%.10g", $stdDev )
          . "\tmedian: "
          . sprintf( "%.10g", $median );
        say "Removing data outside 1st standard deviation";
    }

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#$targetArrayRef ; $i++ ) {
        splice( @$targetArrayRef, $i, 1 )
          if ( @$targetArrayRef[$i] < ( $median - $stdDev )
            || @$targetArrayRef[$i] > ( $median + $stdDev ) );
    }
    $lengthOfTargetArray = $#$targetArrayRef;
    $avg                 = &average($targetArrayRef);
    $median              = &median($targetArrayRef);
    $stdDev              = &stdev($targetArrayRef);

    if ($debug) {
        say "lengthOfTargetArray: $lengthOfTargetArray";
        say "Smoothed values: average: "
          . sprintf( "%.10g", $avg )
          . "\tstdev: "
          . sprintf( "%.10g", $stdDev )
          . "\tmedian: "
          . sprintf( "%.10g", $median );
        say "";
    }

    return ( $avg, $median, $stdDev );
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
        findObstacleIcons($_output);
        findFixIcons($_output);

        # findGpsWaypointIcons($_output);
        findGpsWaypointIcons($_output);
        findNavaidIcons($_output);

        #findFinalApproachFixIcons($_output);
        #findVisualDescentPointIcons($_output);
        findHorizontalAndVerticalLines($_output);
        findInsetBoxes($_output);
        findLargeBoxes($_output);
        findInsetCircles($_output);
        findNotToScaleIndicator($_output);
        findRunwayIcons($_output);
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

sub findClosestSquigglyToA {

    #Find the closest B icon to each A

    my ( $hashRefA, $hashRefB ) = @_;

    #Maximum distance in points between centers
    my $maxDistance = 30;
    my @unwanted;

    # say "findClosest $hashRefB to each $hashRefA" if $debug;

    foreach my $key ( sort keys %$hashRefA ) {

        #Start with a very high number so initially is closer than it
        my $distanceToClosest = 999999999999;

        foreach my $key2 ( sort keys %$hashRefB ) {

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
            say "deleting $key from potential icons" if $debug;
            push @unwanted, $key;

            # delete $hashRefA->{$key}
        }

    }

    #TODO: This seems sloppy but it works
    foreach my $key3 (@unwanted) {
        delete $hashRefA->{$key3};
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

sub findObstaclesNearAirport {

    # my $radius     = ".2";
    my $minimumAgl = "0";

    #How far away from the airport to look for feature
    my $radiusNm = 20;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport

    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      ( $radiusNm / 60 ) / cos( deg2rad($main::airportLatitudeDec) );

    #---------------------------------------------------------------------------------------------------------------------------------------------------
    #Find obstacles with a certain height in the database

    foreach my $heightmsl (@main::obstacle_heights) {

        #@obstacle_heights only contains unique potential heights mentioned on the plate
        #Query the database for obstacles of $heightmsl within our $radius
        my $sth = $dbh->prepare(
            "SELECT * FROM obstacles WHERE 
                                       (HeightMsl=$heightmsl) and 
                                       (HeightAgl > $minimumAgl) and 
                                       (Latitude >  $main::airportLatitudeDec - $radiusDegreesLatitude ) and 
                                       (Latitude < $main::airportLatitudeDec +$radiusDegreesLatitude ) and 
                                       (Longitude >  $main::airportLongitudeDec - $radiusDegreesLongitude ) and 
                                       (Longitude < $main::airportLongitudeDec +$radiusDegreesLongitude )"
        );
        $sth->execute();

        my $all   = $sth->fetchall_arrayref();
        my $_rows = $sth->rows();
        say "Found $_rows objects of height $heightmsl" if $debug;

        #This may be a terrible idea but I'm testing the theory that if an obstacle is mentioned only once on the PDF that even if that height is not unique in the real world within the bounding box
        #that the designer is going to show the one that's closest to the airport.  I could be totally wrong here and causing more mismatches than I'm solving
        my $bestDistanceToAirport = 9999;

        if ($shouldUseMultipleObstacles) {
            foreach my $_row (@$all) {
                my ( $lat, $lon, $heightmsl, $heightagl ) = @$_row;
                my $distanceToAirport =
                  sqrt( ( $lat - $main::airportLatitudeDec )**2 +
                      ( $lon - $main::airportLongitudeDec )**2 );

                #say    "current distance $distanceToAirport, best distance for object of height $heightmsl msl is now $bestDistanceToAirport";
                next if ( $distanceToAirport > $bestDistanceToAirport );

                $bestDistanceToAirport = $distanceToAirport;

                #say "closest distance for object of height $heightmsl msl is now $bestDistanceToAirport";

                $main::unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
                $main::unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
            }
        }
        else {
            #Don't show results of searches that have more than one result, ie not unique
            next if ( $_rows != 1 );

            foreach my $_row (@$all) {

                #Populate variables from our database lookup
                my ( $lat, $lon, $heightmsl, $heightagl ) = @$_row;
                foreach my $pdf_obstacle_height (@main::obstacle_heights) {
                    if ( $pdf_obstacle_height == $heightmsl ) {
                        $main::unique_obstacles_from_db{$heightmsl}{"Lat"} =
                          $lat;
                        $main::unique_obstacles_from_db{$heightmsl}{"Lon"} =
                          $lon;
                    }
                }
            }
        }

    }

    #How many obstacles with unique heights did we find
    $main::unique_obstacles_from_dbCount =
      keys(%main::unique_obstacles_from_db);

    #Save statistics
    $statistics{'$unique_obstacles_from_dbCount'} =
      $main::unique_obstacles_from_dbCount;

    if ($debug) {
        say
          "Found $main::unique_obstacles_from_dbCount OBSTACLES with unique heights within $radiusNm nm of airport from database";
        say "unique_obstacles_from_db:";
        print Dumper ( \%main::unique_obstacles_from_db );
        say "";
    }
    return;
}

sub findGpsWaypointIcons {
    my ($_output) = @_;

    #REGEX building blocks

    #my $transformCaptureXYRegex = qr/q 1 0 0 1 ($numberRegex) ($numberRegex)\s+cm/;

    #Find first half of gps waypoint icons
    #Usually this is the upper left half but I've seen at least one instance where it matches the upper right,
    #which throws off the determination of the center point (SSI GPS 22)
    my $gpswaypointregex = qr/^$main::transformCaptureXYRegex$
^0 0 m$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::lineRegexCaptureXY$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::lineRegexCaptureXY$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^0 0 l$
^f\*$
^Q$/m;

    my $gpswaypointregex2 = qr/^$main::transformCaptureXYRegex$
^0 0 m$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::lineRegexCaptureXY$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::lineRegexCaptureXY$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^0 0 l$
^f\*$
^Q$/m;

    #Found at least one example of the waypoint icon being drawn like this (2 extra curves)
    my $gpsWaypointDataPoints = 6;

    my @regex1 = $_output =~ /$gpswaypointregex/ig;
    my @regex2 = $_output =~ /$gpswaypointregex2/ig;

    my @merged = ( @regex1, @regex2 );

    my $merged_length = 0 + @merged;
    my $merged_count  = $merged_length / $gpsWaypointDataPoints;

    if ( $merged_length >= $gpsWaypointDataPoints ) {
        my $rand = rand();

        #say "Found $merged_count GPS waypoints in stream $i";
        for (
            my $i = 0 ;
            $i < $merged_length ;
            $i = $i + $gpsWaypointDataPoints
          )
        {
            my $width   = 10;
            my $height  = 10;
            my $x       = $merged[$i];
            my $y       = $merged[ $i + 1 ];
            my $x1      = $merged[ $i + 2 ];
            my $y1      = $merged[ $i + 3 ];
            my $x2      = $merged[ $i + 4 ];
            my $y2      = $merged[ $i + 5 ];
            my $xOffset = abs($x1) - abs($x2);
            my $yOffset = abs($y1) - abs($y2);

            if ( $x1 > 0 && $x2 > 0 ) {
                say "GPS icon type 1" if $debug;
                $yOffset = 0;
                $xOffset = 8;    #TODO floor($xOffset*2);
            }
            elsif ( $xOffset < 4 ) {
                say "GPS icon type 2" if $debug;
                $xOffset = 0;
                $yOffset = 8;    #TODO should be floor($yOffset*2);

            }
            elsif ( $x1 < 0 && $x2 < 0 ) {
                say "GPS icon type 3" if $debug;
                $yOffset = 0;
                $xOffset = -8;    #TODO floor($xOffset*2);}
            }

            say "$x\t$y\t$x1\t$y1\t$x2\t$y2\t$xOffset\t$yOffset" if $debug;

            #put them into a hash
            $main::gpsWaypointIcons{ $i . $rand }{"CenterX"} = $x + $xOffset;
            $main::gpsWaypointIcons{ $i . $rand }{"CenterY"} = $y + $yOffset;
            $main::gpsWaypointIcons{ $i . $rand }{"Width"}   = $width;
            $main::gpsWaypointIcons{ $i . $rand }{"Height"}  = $height;
            $main::gpsWaypointIcons{ $i . $rand }{"GeoreferenceX"} =
              $x + $xOffset;
            $main::gpsWaypointIcons{ $i . $rand }{"GeoreferenceY"} =
              $y + $yOffset;
            $main::gpsWaypointIcons{ $i . $rand }{"Type"} = "gps";
        }

    }

    my $gpsCount = keys(%main::gpsWaypointIcons);

    #Save statistics
    $statistics{'$gpsCount'} = $gpsCount;
    if ($debug) {
        print "$merged_count GPS ";

    }
    return;
}

#--------------------------------------------------------------------------------------------------------------------------------------
sub findNavaidIcons {

    #TODO Add VOR icon, see IN-ASW-ILS-OR-LOC-DME-RWY-27.pdf
    #I'm going to lump finding all of the navaid icons into here for now
    #Before I clean it up
    my ($_output) = @_;

    #REGEX building blocks

    #Find VOR icons
    #Change the 3rd line here back to just a lineRegex if there are problems with finding vortacs
    my $vortacRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$/m;

    my $vortacRegex2 = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$/m;

    my $vortacRegex3 = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^f\*$
^Q$/m;

    my @merged           = ();
    my $vortacDatapoints = 3;

    #Capture data points for the various regexes
    my @regex1 = $_output =~ /$vortacRegex/ig;
    my @regex2 = $_output =~ /$vortacRegex2/ig;
    my @regex3 = $_output =~ /$vortacRegex3/ig;

    @merged = ( @regex1, @regex2, @regex3 );

    #say @merged;

    # say $&;
    my $mergedLength = 0 + @merged;
    my $mergedCount  = $mergedLength / $vortacDatapoints;

    if ( $mergedLength >= $vortacDatapoints ) {
        my $rand = rand();
        for ( my $i = 0 ; $i < $mergedLength ; $i = $i + $vortacDatapoints ) {

            #TODO Test that the length of the first line is less than ~6 (one sample value is 3.17, so that's plenty of margin)
            my $x      = $merged[$i];
            my $y      = $merged[ $i + 1 ];
            my $length = $merged[ $i + 2 ];
            my $height = 10;
            my $width  = 10;

            next if ( $length > 6 || $length < 1 );

            #put them into a hash
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            $main::navaidIcons{ $i . $rand }{"GeoreferenceX"} =
              $x + ( $length / 2 );
            $main::navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y - 3;
            $main::navaidIcons{ $i . $rand }{"CenterX"} =
              $x + ( $length / 2 );
            $main::navaidIcons{ $i . $rand }{"CenterY"} = $y - 3;
            $main::navaidIcons{ $i . $rand }{"Width"}   = $width;
            $main::navaidIcons{ $i . $rand }{"Height"}  = $height;
            $main::navaidIcons{ $i . $rand }{"Type"}    = "VORTAC";
        }

    }
    my $vorDmeRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^$main::lineRegex$
^0\s+($main::numberRegex)\s+l$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^S$
^Q$/m;

    #Re-run for VORDME
    @merged = $_output =~ /$vorDmeRegex/ig;
    my $vorDmeDatapoints = 4;

    # say @merged;

    # say $&;
    $mergedLength = 0 + @merged;
    $mergedCount  = $mergedLength / $vorDmeDatapoints;

    if ( $mergedLength >= $vorDmeDatapoints ) {
        my $rand = rand();
        for ( my $i = 0 ; $i < $mergedLength ; $i = $i + $vorDmeDatapoints ) {
            my ($x) = $merged[$i];
            my ($y) = $merged[ $i + 1 ];

            my ($width)  = $merged[ $i + 2 ];
            my ($height) = $merged[ $i + 3 ];

            #TODO because it seems something else is matching this regex choose one with long lines
            next if ( abs( $width < 7 ) || abs( $height < 7 ) );

            #put them into a hash
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            # $navaidIcons{ $i . $rand }{"X"} = $x;
            # $navaidIcons{ $i . $rand }{"Y"} = $y;

            $main::navaidIcons{ $i . $rand }{"CenterX"} = $x + $width / 2;
            $main::navaidIcons{ $i . $rand }{"CenterY"} = $y + $height / 2;
            $main::navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x + $width / 2;
            $main::navaidIcons{ $i . $rand }{"GeoreferenceY"} =
              $y + $height / 2;
            $main::navaidIcons{ $i . $rand }{"Width"}  = $width;
            $main::navaidIcons{ $i . $rand }{"Height"} = $height;
            $main::navaidIcons{ $i . $rand }{"Type"}   = "VOR/DME";
        }

    }

    #Re-run for NDB
    my $ndbRegex = qr/^$main::transformCaptureXYRegex$
^0 0 m$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^f\*$
^Q$
^$main::numberRegex w $
^$main::transformNoCaptureXYRegex$
^0 0 m$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^S$
^Q$/m;

    my $ndbRegex2 = qr/^$main::transformCaptureXYRegex$
^0 0 m$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^f\*$
^Q$
^$main::transformNoCaptureXYRegex$
^0 0 m$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^S$
^Q$/m;

    #There are a bunch of lines like this, the little circles of the NDB icons
    #Should probably include a few in the regex to reduce bad matches
    # q 1 0 0 1 27.03 328.55 cm
    # 0 0 m
    # -0.08 -0.1 -0.07 -0.25 0.03 -0.33 c
    # 0.13 -0.41 0.28 -0.4 0.37 -0.3 c
    # 0.45 -0.2 0.44 -0.05 0.34 0.04 c
    # 0.24 0.12 0.09 0.11 0 0 c
    # f*
    # Q

    @merged = ();
    my $iconDataPoints = 2;

    #Capture data points for the various regexes
    @regex1 = $_output =~ /$ndbRegex/ig;
    @regex2 = $_output =~ /$ndbRegex2/ig;

    @merged = ( @regex1, @regex2 );

    #say @merged;

    # say $&;
    $mergedLength = 0 + @merged;
    $mergedCount  = $mergedLength / $iconDataPoints;

    if ( $mergedLength >= $iconDataPoints ) {
        my $rand = rand();
        for ( my $i = 0 ; $i < $mergedLength ; $i = $i + $iconDataPoints ) {

            my $x = $merged[$i];
            my $y = $merged[ $i + 1 ];

            # my $length = $merged[ $i + 2 ];
            my $height = 10;
            my $width  = 10;

            # next if ( $length > 6 || $length < 1 );

            #put them into a hash
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            #Could use $length/2 here for X center offset
            $main::navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x;
            $main::navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y;
            $main::navaidIcons{ $i . $rand }{"CenterX"}       = $x;
            $main::navaidIcons{ $i . $rand }{"CenterY"}       = $y;
            $main::navaidIcons{ $i . $rand }{"Width"}         = $width;
            $main::navaidIcons{ $i . $rand }{"Height"}        = $height;
            $main::navaidIcons{ $i . $rand }{"Type"}          = "ndb";
        }

    }

    my $navaidCount = keys(%main::navaidIcons);

    #Save statistics
    $statistics{'$navaidCount'} = $navaidCount;

    if ($debug) {
        print "$mergedCount NAVAID ";

        #print Dumper ( \%navaidIcons);
    }

    #-----------------------------------

    return;
}

sub findInsetBoxes {
    my ($_output) = @_;

    #REGEX building blocks
    #A series of 4 lines (iow: a box)
    my $insetBoxRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^$main::numberRegex\s+$main::numberRegex\s+l$
^0\s+($main::numberRegex)\s+l$
^0\s+0\s+l$
^S$
^Q$/m;

    #A series of 2 lines (iow: part of a box)
    my $halfBoxRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^$main::numberRegex\s+($main::numberRegex)\s+l$
^S$
^Q$/m;

    #A series of 3 lines (iow: part of a box)
    my $almostBoxRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^$main::numberRegex\s+($main::numberRegex)\s+l$
^0\s+$main::numberRegex\s+l$
^S$
^Q$/m;

    my @tempInsetBox = $_output =~ /$insetBoxRegex/ig;

    my $tempInsetBoxLength = 0 + @tempInsetBox;
    my $insetBoxCount      = $tempInsetBoxLength / 4;

    if ( $tempInsetBoxLength >= 4 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempInsetBoxLength ; $i = $i + 4 ) {
            my $x      = $tempInsetBox[$i];
            my $y      = $tempInsetBox[ $i + 1 ];
            my $width  = $tempInsetBox[ $i + 2 ];
            my $height = $tempInsetBox[ $i + 3 ];

            #Let's only save large, but not too large, boxes
            next
              if ( ( abs($width) < 25 )
                || ( abs($height) < 25 )
                || ( abs($height) > 500 )
                || ( abs($width) > 300 ) );

            #put them into a hash
            $main::insetBoxes{ $i . $random }{"X"}      = $x;
            $main::insetBoxes{ $i . $random }{"Y"}      = $y;
            $main::insetBoxes{ $i . $random }{"X2"}     = $x + $width;
            $main::insetBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $main::insetBoxes{ $i . $random }{"Width"}  = $width;
            $main::insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    @tempInsetBox = $_output =~ /$halfBoxRegex/ig;

    $tempInsetBoxLength = 0 + @tempInsetBox;
    $insetBoxCount      = $tempInsetBoxLength / 4;

    if ( $tempInsetBoxLength >= 4 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempInsetBoxLength ; $i = $i + 4 ) {
            my $x      = $tempInsetBox[$i];
            my $y      = $tempInsetBox[ $i + 1 ];
            my $width  = $tempInsetBox[ $i + 2 ];
            my $height = $tempInsetBox[ $i + 3 ];

            #Let's only save large, but not too large, boxes
            next
              if ( ( abs($width) < 50 )
                || ( abs($height) < 50 )
                || ( abs($height) > 500 )
                || ( abs($width) > 300 ) );

            #put them into a hash
            $main::insetBoxes{ $i . $random }{"X"}      = $x;
            $main::insetBoxes{ $i . $random }{"Y"}      = $y;
            $main::insetBoxes{ $i . $random }{"X2"}     = $x + $width;
            $main::insetBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $main::insetBoxes{ $i . $random }{"Width"}  = $width;
            $main::insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    @tempInsetBox = $_output =~ /$almostBoxRegex/ig;

    $tempInsetBoxLength = 0 + @tempInsetBox;
    $insetBoxCount      = $tempInsetBoxLength / 4;

    if ( $tempInsetBoxLength >= 4 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempInsetBoxLength ; $i = $i + 4 ) {
            my $x      = $tempInsetBox[$i];
            my $y      = $tempInsetBox[ $i + 1 ];
            my $width  = $tempInsetBox[ $i + 2 ];
            my $height = $tempInsetBox[ $i + 3 ];

            #Let's only save large, but not too large, boxes
            next
              if ( ( abs($width) < 50 )
                || ( abs($height) < 50 )
                || ( abs($height) > 500 )
                || ( abs($width) > 300 ) );

            #put them into a hash
            $main::insetBoxes{ $i . $random }{"X"}      = $x;
            $main::insetBoxes{ $i . $random }{"Y"}      = $y;
            $main::insetBoxes{ $i . $random }{"X2"}     = $x + $width;
            $main::insetBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $main::insetBoxes{ $i . $random }{"Width"}  = $width;
            $main::insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    $insetBoxCount = keys(%main::insetBoxes);

    #Save statistics
    $statistics{'$insetBoxCount'} = $insetBoxCount;

    # if ($debug) {
    # print "$insetBoxCount Inset Boxes ";

    # print Dumper ( \%insetBoxes );

    # }

    return;
}

sub findLargeBoxes {
    my ($_output) = @_;

    #REGEX building blocks
    #A series of 4 lines (iow: a box)
    my $insetBoxRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^$main::numberRegex\s+$main::numberRegex\s+l$
^0\s+($main::numberRegex)\s+l$
^0\s+0\s+l$
^S$
^Q$/m;

    my @tempInsetBox = $_output =~ /$insetBoxRegex/ig;

    my $tempInsetBoxLength = 0 + @tempInsetBox;
    my $insetBoxCount      = $tempInsetBoxLength / 4;

    if ( $tempInsetBoxLength >= 4 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempInsetBoxLength ; $i = $i + 4 ) {
            my $x      = $tempInsetBox[$i];
            my $y      = $tempInsetBox[ $i + 1 ];
            my $width  = $tempInsetBox[ $i + 2 ];
            my $height = $tempInsetBox[ $i + 3 ];

            #Let's only save large boxes
            #  say "$height $pdfYSize $width $pdfXSize";
            next
              if ( ( abs($height) < ( $main::pdfYSize / 2 ) )
                || ( abs($width) < ( $main::pdfXSize / 2 ) ) );

            #put them into a hash
            $main::largeBoxes{ $i . $random }{"X"}      = $x;
            $main::largeBoxes{ $i . $random }{"Y"}      = $y;
            $main::largeBoxes{ $i . $random }{"X2"}     = $x + $width;
            $main::largeBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $main::largeBoxes{ $i . $random }{"Width"}  = $width;
            $main::largeBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    # my $insetBoxCount = keys(%insetBoxes);
    # #Save statistics
    # $statistics{$insetBoxCount}=$insetBoxCount;

    # if ($debug) {
    # print "$insetBoxCount Inset Boxes ";

    # print Dumper ( \%insetBoxes );

    # }

    return;
}

sub findInsetCircles {
    my ($_output) = @_;

    #This example starts at the rightmost edge of the circle
    #I bet we could pick out the lines that end with 0 as the tangents of the bounding box
    # q 1 0 0 1 359.83 270.38 cm
    # 0 0 m
    # 0 4.13 -0.81 8.22 -2.39 12.04 c
    # -3.97 15.85 -6.29 19.32 -9.21 22.24 c
    # -12.13 25.16 -15.6 27.48 -19.42 29.06 c
    # -23.23 30.64 -27.32 31.45 -31.45 31.45 c
    # -35.59 31.45 -39.68 30.64 -43.49 29.06 c
    # -47.31 27.48 -50.78 25.16 -53.7 22.24 c
    # -56.62 19.32 -58.94 15.85 -60.52 12.04 c
    # -62.1 8.22 -62.91 4.13 -62.91 0 c
## -62.1 is the -X edge of the circle from the starting X,Y so radius is ~30
    # -62.91 -4.13 -62.1 -8.23 -60.52 -12.04 c
    # -58.94 -15.86 -56.62 -19.33 -53.7 -22.25 c
    # -50.78 -25.17 -47.31 -27.49 -43.49 -29.07 c
    # -39.68 -30.65 -35.59 -31.46 -31.45 -31.46 c
    # -27.32 -31.46 -23.23 -30.65 -19.42 -29.07 c
    # -15.6 -27.49 -12.13 -25.17 -9.21 -22.25 c
    # -6.29 -19.33 -3.97 -15.86 -2.39 -12.04 c
    # -0.81 -8.23 0 -4.13 0 0 c
    # S
    # Q
    #REGEX building blocks
    #16 Bezier curves into a circle
    my $insetCircleRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^($main::numberRegex\s+)(?:$main::numberRegex\s+){5}c$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^S$
^Q$/m;

    my @tempInsetCircle       = $_output =~ /$insetCircleRegex/ig;
    my $insetCircleDataPoints = 3;

    my $tempInsetCircleLength = 0 + @tempInsetCircle;
    my $insetCircleCount      = $tempInsetCircleLength / $insetCircleDataPoints;

    if ( $tempInsetCircleLength >= $insetCircleDataPoints ) {
        my $random = rand();
        for (
            my $i = 0 ;
            $i < $tempInsetCircleLength ;
            $i = $i + $insetCircleDataPoints
          )
        {
            my $x = $tempInsetCircle[$i];
            my $y = $tempInsetCircle[ $i + 1 ];

            #Typically these are negative, meaning the circle's leftmost edge is -$width pts away from the rightmost edges
            #which is the starting points
            my $width = abs( $tempInsetCircle[ $i + 2 ] );

            # my $height = $tempInsetCircle[ $i + 3 ];

            next if $width < 50;

            # #Let's only save large, but not too large, boxes
            # next
            # if ( ( abs($width) < 50 )
            # || ( abs($height) < 50 )
            # || ( abs($height) > 500 )
            # || ( abs($width) > 300 ) );

            #put them into a hash
            #TODO: This is a cheat and will probably not always work
            $main::insetCircles{ $i . $random }{"X"}      = $x - $width / 2;
            $main::insetCircles{ $i . $random }{"Y"}      = $y;
            $main::insetCircles{ $i . $random }{"Radius"} = $width / 2;

        }

    }

    $insetCircleCount = keys(%main::insetCircles);

    #Save statistics
    $statistics{'$insetCircleCount'} = $insetCircleCount;

    # if ($debug) {
    # print "$insetCircleCount Inset Circles ";

    # print Dumper ( \%insetCircles );

    # }

    return;
}

sub findHorizontalAndVerticalLines {
    my ($_output) = @_;

    #REGEX building blocks

    #A purely horizontal line
    my $horizontalLineRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s+0\s+l$
^S$
^Q$/m;

    my @tempHorizontalLine = $_output =~ /$horizontalLineRegex/ig;

    my $tempHorizontalLineLength = 0 + @tempHorizontalLine;
    my $tempHorizontalLineCount  = $tempHorizontalLineLength / 3;

    if ( $tempHorizontalLineLength >= 3 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempHorizontalLineLength ; $i = $i + 3 ) {

            #Let's only save long lines
            next if ( abs( $tempHorizontalLine[ $i + 2 ] ) < 5 );

            #put them into a hash
            $main::horizontalAndVerticalLines{ $i . $random }{"X"} =
              $tempHorizontalLine[$i];

            $main::horizontalAndVerticalLines{ $i . $random }{"Y"} =
              $tempHorizontalLine[ $i + 1 ];

            $main::horizontalAndVerticalLines{ $i . $random }{"X2"} =
              $tempHorizontalLine[$i] + $tempHorizontalLine[ $i + 2 ];

            $main::horizontalAndVerticalLines{ $i . $random }{"Y2"} =
              $tempHorizontalLine[ $i + 1 ];
        }

    }

    #print Dumper ( \%horizontalAndVerticalLines );

    #A purely vertical line
    my $verticalLineRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^0\s+($main::numberRegex)\s+l$
^S$
^Q$/m;

    @tempHorizontalLine = $_output =~ /$verticalLineRegex/ig;

    $tempHorizontalLineLength = 0 + @tempHorizontalLine;
    $tempHorizontalLineCount  = $tempHorizontalLineLength / 3;

    if ( $tempHorizontalLineLength >= 3 ) {
        my $random = rand();

        for ( my $i = 0 ; $i < $tempHorizontalLineLength ; $i = $i + 3 ) {
            my $x      = $tempHorizontalLine[$i];
            my $y      = $tempHorizontalLine[ $i + 1 ];
            my $y2     = $tempHorizontalLine[ $i + 2 ];
            my $length = abs($y2);

            #Let's only save long lines
            next if ( $length < 5 );

            #put them into a hash
            $main::horizontalAndVerticalLines{ $i . $random }{"X"}  = $x;
            $main::horizontalAndVerticalLines{ $i . $random }{"Y"}  = $y;
            $main::horizontalAndVerticalLines{ $i . $random }{"X2"} = $x;
            $main::horizontalAndVerticalLines{ $i . $random }{"Y2"} = $y + $y2;
        }

    }

    my $horizontalAndVerticalLinesCount =
      keys(%main::horizontalAndVerticalLines);

    #Save statistics
    $statistics{'$horizontalAndVerticalLinesCount'} =
      $horizontalAndVerticalLinesCount;

    if ($debug) {
        print "$tempHorizontalLineCount Lines ";

    }

    #-----------------------------------

    return;
}

sub findObstacleIcons {

    #The uncompressed text of this stream
    my ($_output) = @_;

    #A regex that matches how an obstacle is drawn in the PDF
    #TODO Modify this to have a return to Y of zero in the regex
    my ($obstacleRegex) = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^([\.0-9]+) [\.0-9]+ l$
^([\.0-9]+) [\.0-9]+ l$
^S$
^Q$
^$main::transformCaptureXYRegex$
^$main::originRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^$main::bezierCurveRegex$
^f\*$
^Q$/m;

    #each entry in @tempObstacles will have the numbered captures from the regex, 6 for each one
    my (@tempObstacles)           = $_output =~ /$obstacleRegex/ig;
    my ($tempObstacles_length)    = 0 + @tempObstacles;
    my $dataPointsPerObstacleIcon = 6;

    #Divide length of array by 6 data points for each obstacle to get count of obstacles
    my ($tempObstacles_count) =
      $tempObstacles_length / $dataPointsPerObstacleIcon;

    if ( $tempObstacles_length >= $dataPointsPerObstacleIcon ) {

        #say "Found $tempObstacles_count obstacles in stream $stream";

        for (
            my $i = 0 ;
            $i < $tempObstacles_length ;
            $i = $i + $dataPointsPerObstacleIcon
          )
        {

            #A hack to allow icon accumulation across streams
            #Comment this out to only find obstacles in the last scanned stream
            #
            my $rand = rand();

            #Put the info for each obstscle icon into a hash
            #This finds the midpoint X of the obstacle triangle (basically the X,Y of the dot but the X,Y of the dot itself was too far right)
            #For each icon: Offset      0: Starting X
            #                                               1: Starting Y
            #                                               2: X of top of triangle
            #                                               3: Y of top of triangle
            #                                               4: X of dot
            #                                               5: Y of dot
            my $x = $tempObstacles[$i];
            my $y = $tempObstacles[ $i + 1 ];

            my $centerX = "";
            my $centerY = "";

            #Note that this is half the width of the whole icon
            my $width  = $tempObstacles[ $i + 2 ] * 2;
            my $height = $tempObstacles[ $i + 3 ];

            $main::obstacleIcons{ $i . $rand }{"GeoreferenceX"} =
              $x + $width / 2;
            $main::obstacleIcons{ $i . $rand }{"GeoreferenceY"} = $y;
            $main::obstacleIcons{ $i . $rand }{"CenterX"} = $x + $width / 2;
            $main::obstacleIcons{ $i . $rand }{"CenterY"} = $y + $height / 2;
            $main::obstacleIcons{ $i . $rand }{"Width"}   = $width;
            $main::obstacleIcons{ $i . $rand }{"Height"}  = $height;

            #$obstacleIcons{ $i . $rand }{"Height"}  = "unknown";
            $main::obstacleIcons{ $i . $rand }{"ObstacleTextBoxesThatPointToMe"}
              = 0;
            $main::obstacleIcons{ $i . $rand }{"potentialTextBoxes"} = 0;
            $main::obstacleIcons{ $i . $rand }{"type"} = "obstacle";
        }

    }

    my $obstacleCount = keys(%main::obstacleIcons);

    #Save statistics
    $statistics{'$obstacleCount'} = $obstacleCount;
    if ($debug) {
        print "$tempObstacles_count obstacles ";

        #print Dumper ( \%obstacleIcons );
    }
    return;
}

sub findFixIcons {
    my ($_output) = @_;

    #Find fixes in the PDF
    # my $fixregex =
    # qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([-\.0-9]+) [\.0-9]+ l [-\.0-9]+ ([\.0-9]+) l 0 0 l S Q/;
    my $fixregex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex) $main::numberRegex l$
^$main::numberRegex ($main::numberRegex) l$
^0 0 l$
^S$
^Q$/m;

    my @tempfixes        = $_output =~ /$fixregex/ig;
    my $tempfixes_length = 0 + @tempfixes;

    #4 data points for each fix
    #$1 = x
    #$2 = y
    #$3 = delta x (will be negative)
    #$4 = delta y (will be negative)
    my $tempfixes_count = $tempfixes_length / 4;
    my $rand            = rand();
    if ( $tempfixes_length >= 4 ) {

        for ( my $i = 0 ; $i < $tempfixes_length ; $i = $i + 4 ) {
            my $x      = $tempfixes[$i];
            my $y      = $tempfixes[ $i + 1 ];
            my $width  = $tempfixes[ $i + 2 ];
            my $height = $tempfixes[ $i + 3 ];

            #TODO FIX icons are probably all at least >4 but I'll use this for now
            next if ( abs($height) < 3 );

            #put them into a hash
            #code here is making the x/y the center of the triangle
            $main::fixIcons{ $i . $rand }{"GeoreferenceX"} =
              $x + ( $width / 2 );
            $main::fixIcons{ $i . $rand }{"GeoreferenceY"} =
              $y + ( $height / 2 );
            $main::fixIcons{ $i . $rand }{"CenterX"} = $x + ( $width / 2 );
            $main::fixIcons{ $i . $rand }{"CenterY"} = $y + ( $height / 2 );
            $main::fixIcons{ $i . $rand }{"Width"}   = $width;
            $main::fixIcons{ $i . $rand }{"Height"}  = $height;
            $main::fixIcons{ $i . $rand }{"Type"}    = "fix";

            #$fixIcons{ $i . $rand }{"Name"} = "none";
        }

    }

    my $fixCount = keys(%main::fixIcons);

    #Save statistics
    $statistics{'$fixCount'} = $fixCount;
    if ($debug) {
        print "$tempfixes_count fix ";
    }
    return;
}

sub findFinalApproachFixIcons {

    # my ($_output) = @_;

    # #Find Final Approach Fix icon
    # #my $fafRegex =
    # #qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q/;
    # my $fafRegex = qr/^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
    # ^0 0 m$
    # ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
    # ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
    # ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
    # ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
    # ^f\*$
    # ^Q$
    # ^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
    # ^0 0 m$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^0 0 l$
    # ^f\*$
    # ^Q$
    # ^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
    # ^0 0 m$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^0 0 l$
    # ^f\*$
    # ^Q$
    # ^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
    # ^0 0 m$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^0 0 l$
    # ^f\*$
    # ^Q$
    # ^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
    # ^0 0 m$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^[-\.0-9]+ [-\.0-9]+ l$
    # ^0 0 l$
    # ^f\*$
    # ^Q$/m;

    # my @tempfinalApproachFixIcons = $_output =~ /$fafRegex/ig;
    # my $tempfinalApproachFixIcons_length = 0 + @tempfinalApproachFixIcons;
    # my $tempfinalApproachFixIcons_count = $tempfinalApproachFixIcons_length / 2;

    # if ( $tempfinalApproachFixIcons_length >= 2 ) {

    # #say "Found $tempfinalApproachFixIcons_count FAFs in stream $i";
    # for ( my $i = 0 ; $i < $tempfinalApproachFixIcons_length ; $i = $i + 2 )
    # {

    # #put them into a hash
    # $finalApproachFixIcons{$i}{"GeoreferenceX"} = $tempfinalApproachFixIcons[$i];
    # $finalApproachFixIcons{$i}{"GeoreferenceY"} = $tempfinalApproachFixIcons[ $i + 1 ];
    # $finalApproachFixIcons{$i}{"Name"} = "none";
    # }

    # }

    # $finalApproachFixCount = keys(%finalApproachFixIcons);

    # # if ($debug) {
    # # say "Found $tempfinalApproachFixIcons_count Final Approach Fix icons";
    # # say "";
    # # }
    # return;
}

sub findVisualDescentPointIcons {

    # my ($_output) = @_;

    # #Find Visual Descent Point icon
    # my $vdpRegex =
    # qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+0.72 w \[\]0 d/;

    # #my $vdpRegex =
    # #qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+
    # #0 0 m\s+
    # #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    # #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    # #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    # #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    # #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    # #0 0 l\s+
    # #f\*\s+
    # #Q\s+
    # #0.72 w \[\]0 d/m;

    # my @tempvisualDescentPointIcons = $_output =~ /$vdpRegex/ig;
    # my $tempvisualDescentPointIcons_length = 0 + @tempvisualDescentPointIcons;
    # my $tempvisualDescentPointIcons_count =
    # $tempvisualDescentPointIcons_length / 2;

    # if ( $tempvisualDescentPointIcons_length >= 2 ) {
    # for (
    # my $i = 0 ;
    # $i < $tempvisualDescentPointIcons_length ;
    # $i = $i + 2
    # )
    # {

    # #put them into a hash
    # $visualDescentPointIcons{$i}{"X"} =
    # $tempvisualDescentPointIcons[$i];
    # $visualDescentPointIcons{$i}{"Y"} =
    # $tempvisualDescentPointIcons[ $i + 1 ];
    # $visualDescentPointIcons{$i}{"Name"} = "none";
    # }

    # }
    # $visualDescentPointCount = keys(%visualDescentPointIcons);

    # # if ($debug) {
    # # say "Found $tempvisualDescentPointIcons_count Visual Descent Point icons";
    # # say "";
    # # }
    # return;
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

sub findObstacleHeightTextBoxes {
    say ":findObstacleHeightTextBoxes" if $debug;

    #-----------------------------------------------------------------------------------------------------------
    #Get list of potential obstacle height textboxes
    #For whatever dumb reason they're in raster axes (0,0 is top left, Y increases downwards)
    #   but in points coordinates
    my $obstacleTextBoxRegex =
      qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::obstacleHeightRegex)</;

    foreach my $line (@main::pdfToTextBbox) {
        if ( $line =~ m/$obstacleTextBoxRegex/ ) {
            my $xMin = $1;

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $yMin = $2 - 2;
            my $xMax = $3 - 1;
            my $yMax = $4;

            my $height = $yMax - $yMin;
            my $width  = $xMax - $xMin;

            # $obstacleTextBoxes{ $1 . $2 }{"RasterX"} = $1 * $scaleFactorX;
            # $obstacleTextBoxes{ $1 . $2 }{"RasterY"} = $2 * $scaleFactorY;
            $main::obstacleTextBoxes{ $1 . $2 }{"Width"}  = $width;
            $main::obstacleTextBoxes{ $1 . $2 }{"Height"} = $height;
            $main::obstacleTextBoxes{ $1 . $2 }{"Text"}   = $5;

            # $obstacleTextBoxes{ $1 . $2 }{"PdfX"}    = $xMin;
            # $obstacleTextBoxes{ $1 . $2 }{"PdfY"}    = $pdfYSize - $2;
            $main::obstacleTextBoxes{ $1 . $2 }{"CenterX"} =
              $xMin + ( $width / 2 );

            # $obstacleTextBoxes{ $1 . $2 }{"CenterY"} = $pdfYSize - $2;
            $main::obstacleTextBoxes{ $1 . $2 }{"CenterY"} =
              ( $main::pdfYSize - $yMin ) - ( $height / 2 );
            $main::obstacleTextBoxes{ $1 . $2 }{"IconsThatPointToMe"} = 0;
        }

    }

    #print Dumper ( \%obstacleTextBoxes );

    if ($debug) {
        say "Found " .
          keys(%main::obstacleTextBoxes) . " Potential obstacle text boxes";
        say "";
    }
    return;
}

sub findFixTextboxes {
    say ":findFixTextboxes" if $debug;

    #--------------------------------------------------------------------------
    #Get list of potential fix/intersection/GPS waypoint  textboxes
    #For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
    #We'll convert them to PDF coordinates
    my $fixTextBoxRegex =
      qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([A-Z]{5})</;

    my $invalidFixNamesRegex = qr/tower|south|radar/i;

    foreach my $line (@main::pdfToTextBbox) {
        if ( $line =~ m/$fixTextBoxRegex/ ) {
            my $_fixXMin = $1;
            my $_fixYMin = $2;
            my $_fixXMax = $3;
            my $_fixYMax = $4;
            my $_fixName = $5;

            #Exclude invalid fix names.  A smarter way to do this would be to use the DB lookup to limit to local fix names
            next if $_fixName =~ m/$invalidFixNamesRegex/;

            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterX"} =
            # $_fixXMin * $scaleFactorX;
            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterY"} =
            # $_fixYMin * $scaleFactorY;
            $main::fixTextboxes{ $_fixXMin . $_fixYMin }{"Width"} =
              $_fixXMax - $_fixXMin;
            $main::fixTextboxes{ $_fixXMin . $_fixYMin }{"Height"} =
              $_fixYMax - $_fixYMin;
            $main::fixTextboxes{ $_fixXMin . $_fixYMin }{"Text"} = $_fixName;

            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"PdfX"} = $_fixXMin;
            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"PdfY"} =
            # $pdfYSize - $_fixYMin;
            $main::fixTextboxes{ $_fixXMin . $_fixYMin }{"CenterX"} =
              $_fixXMin + ( ( $_fixXMax - $_fixXMin ) / 2 );
            $main::fixTextboxes{ $_fixXMin . $_fixYMin }{"CenterY"} =
              $main::pdfYSize - $_fixYMin;
        }

    }
    if ($debug) {

        #print Dumper ( \%fixTextboxes );
        say "Found " .
          keys(%main::fixTextboxes) . " Potential Fix/GPS Waypoint text boxes";
        say "";
    }
    return;
}

sub findNavaidTextboxes {
    say ":findNavaidTextboxes" if $debug;

    #--------------------------------------------------------------------------
    #Get list of potential VOR (or other ground based nav)  textboxes
    #For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
    #We'll convert them to PDF coordinates
    my $frequencyRegex = qr/\d\d\d(?:\.[\d]{1,3})?/m;

    my $vorTextBoxRegex =
      qr/^\s+<word xMin="($main::numberRegex)" yMin="($main::numberRegex)" xMax="($main::numberRegex)" yMax="($main::numberRegex)">([A-Z]{3})<\/word>$/m;

    my $scal = join( "", @main::pdfToTextBbox );

    my @tempVortac = $scal =~ /$vorTextBoxRegex/ig;

    my $tempVortacLength        = 0 + @tempVortac;
    my $dataPointsPerVorTextbox = 5;
    my $tempVortacCount         = $tempVortacLength / $dataPointsPerVorTextbox;

    if ( $tempVortacLength >= $dataPointsPerVorTextbox ) {

        for (
            my $i = 0 ;
            $i < $tempVortacLength ;
            $i = $i + $dataPointsPerVorTextbox
          )
        {
            my $_vorXMin = $tempVortac[$i];
            my $_vorYMin = $tempVortac[ $i + 1 ];

            # my $_vorFreq = $tempVortac[ $i + 2 ];
            my $_vorXMax = $tempVortac[ $i + 2 ];
            my $_vorYMax = $tempVortac[ $i + 3 ];
            my $_vorName = $tempVortac[ $i + 4 ];
            my $width    = $_vorXMax - $_vorXMin - 1;
            my $height   = $_vorYMax - $_vorYMin;

            #say "$_vorName , $validNavaidNames";
            #This can't be a valid navaidTextBox if it doesn't contain a valid nearby navaid
            next unless $main::validNavaidNames =~ m/$_vorName/;

            #Ignore vertically oriented textboxes
            next if $height > $width;

            #Check that the box isn't too big
            #This is a workaround for "CO-DEN-ILS-RWY-34L-CAT-II---III.pdf" where it finds a bad box due to ordering of text in PDF
            next if ( abs($width) > 50 );

            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterX"} =
            # $_vorXMin * $scaleFactorX;
            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterY"} =
            # $_vorYMin * $scaleFactorY;
            $main::vorTextboxes{ $_vorXMin . $_vorYMin }{"Width"}  = $width;
            $main::vorTextboxes{ $_vorXMin . $_vorYMin }{"Height"} = $height;
            $main::vorTextboxes{ $_vorXMin . $_vorYMin }{"Text"}   = $_vorName;

            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfX"} = $_vorXMin;
            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfY"} =              $pdfYSize - $_vorYMin;
            $main::vorTextboxes{ $_vorXMin . $_vorYMin }{"CenterX"} =
              $_vorXMin + ( $width / 2 );
            $main::vorTextboxes{ $_vorXMin . $_vorYMin }{"CenterY"} =
              $main::pdfYSize - $_vorYMin;
        }
    }
    if ($debug) {

        #qprint Dumper ( \%vorTextboxes );
        say "Found " .
          keys(%main::vorTextboxes) . " Potential NAVAID text boxes";
        say "";
    }
    return;
}

sub matchIconToDatabase {
    my ( $iconHashRef, $textboxHashRef, $databaseHashRef ) = @_;

    say ":matchIconToDatabase" if $debug;

    #Find an icon with text that matches an item in a database lookup
    #Add the center coordinates of its closest text box to the database hash
    #
    foreach my $key ( keys %$databaseHashRef ) {

        foreach my $key2 ( keys %$iconHashRef ) {

            #Next icon if this one doesn't have a matching textbox
            next unless ( $iconHashRef->{$key2}{"MatchedTo"} );

            my $keyOfMatchedTextbox    = $iconHashRef->{$key2}{"MatchedTo"};
            my $thisIconsGeoreferenceX = $iconHashRef->{$key2}{"GeoreferenceX"};
            my $thisIconsGeoreferenceY = $iconHashRef->{$key2}{"GeoreferenceY"};
            my $textOfMatchedTextbox =
              $textboxHashRef->{$keyOfMatchedTextbox}{"Text"};

            if ( $textOfMatchedTextbox eq $key ) {

                #print $obstacleTextBoxes{$key2}{"Text"} . "$key\n";
                $databaseHashRef->{$key}{"Label"} = $textOfMatchedTextbox;
                $databaseHashRef->{$key}{"GeoreferenceX"} =
                  $thisIconsGeoreferenceX;
                $databaseHashRef->{$key}{"GeoreferenceY"} =
                  $thisIconsGeoreferenceY;
            }

        }
    }
    return;
}

sub calculateRoughRealWorldExtentsOfRaster {

    #Initialize a running count of scale mismatches for this object
    foreach my $key ( sort keys %main::gcps ) {
        $main::gcps{$key}{"Mismatches"} = 0;
    }

    #This is where we finally generate the real information for each plate
    foreach my $key ( sort keys %main::gcps ) {

        #This code is for calculating the PDF x/y and lon/lat differences between every object
        #to calculate the ratio between the two
        foreach my $key2 ( sort keys %main::gcps ) {

            #Don't calculate a scale with ourself
            next if $key eq $key2;

            my ( $ulX, $ulY, $lrX, $lrY, $longitudeToPixelRatio,
                $latitudeToPixelRatio, $longitudeToLatitudeRatio );

            #X pixels between points
            my $pixelDistanceX =
              ( $main::gcps{$key}{"pngx"} - $main::gcps{$key2}{"pngx"} );

            #Y pixels between points
            my $pixelDistanceY =
              ( $main::gcps{$key}{"pngy"} - $main::gcps{$key2}{"pngy"} );

            #Longitude degrees between points
            my $longitudeDiff =
              ( $main::gcps{$key}{"lon"} - $main::gcps{$key2}{"lon"} );

            #Latitude degrees between points
            my $latitudeDiff =
              ( $main::gcps{$key}{"lat"} - $main::gcps{$key2}{"lat"} );

            # unless ( $pixelDistanceX
            # && $pixelDistanceY
            # && $longitudeDiff
            # && $latitudeDiff )
            # {
            # say
            # "Something not defined for $key-$key2 pair: $pixelDistanceX, $pixelDistanceY, $longitudeDiff, $latitudeDiff"
            # if $debug;
            # next;
            # }

            # if ( $latitudeToPixelRatio < .0003 || $latitudeToPixelRatio > .0006 ) {
            #was .00037 < x < .00039 and .00055 < x < .00059

            #TODO Change back to .00037 and .00039?
            #There seem to be three bands of scales

            #Do some basic sanity checking on the $latitudeToPixelRatio
            if ( abs($pixelDistanceY) > 5 && $latitudeDiff ) {
                say
                  "pixelDistanceY: $pixelDistanceY, latitudeDiff: $latitudeDiff"
                  if $debug;

                if ( same_sign( $pixelDistanceY, $latitudeDiff ) ) {
                    say
                      "Bad: $key->$key2 pixelDistanceY and latitudeDiff have same same sign"
                      if $debug;
                    next;
                }

                $pixelDistanceY = abs($pixelDistanceY);
                $latitudeDiff   = abs($latitudeDiff);

                $latitudeToPixelRatio = $latitudeDiff / $pixelDistanceY;

                if (
                    not( is_between( .00011, .00033, $latitudeToPixelRatio ) )
                    && not(
                        is_between( .00034, .00046, $latitudeToPixelRatio ) )
                    && not(
                        is_between( .00056, .00060, $latitudeToPixelRatio, ) )

                    # not( is_between(.00008 , .00009, $latitudeToPixelRatio ) )
                    # &&
                    #&& not( is_between(  .00084, .00085, $latitudeToPixelRatio ) )

                  )
                {
                    $main::gcps{$key}{"Mismatches"} =
                      ( $main::gcps{$key}{"Mismatches"} ) + 1;
                    $main::gcps{$key2}{"Mismatches"} =
                      ( $main::gcps{$key2}{"Mismatches"} ) + 1;

                    if ($debug) {
                        say
                          "Bad latitudeToPixelRatio $latitudeToPixelRatio on $key->$key2 pair"
                          if $debug;
                    }

                    #   next;
                }
                else {
                    #For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
                    $ulY =
                      $main::gcps{$key}{"lat"} +
                      ( $main::gcps{$key}{"pngy"} * $latitudeToPixelRatio );

                    #For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
                    $lrY =
                      $main::gcps{$key}{"lat"} -
                      (
                        abs( $main::pngYSize - $main::gcps{$key}{"pngy"} ) *
                          $latitudeToPixelRatio );

                    #Save this ratio if it seems nominally valid, we'll smooth out these values later
                    push @main::yScaleAvg, $latitudeToPixelRatio;
                    push @main::ulYAvg,    $ulY;
                    push @main::lrYAvg,    $lrY;
                }
            }

            if ( abs($pixelDistanceX) > 5 && $longitudeDiff ) {
                say
                  "pixelDistanceX: $pixelDistanceX, longitudeDiff $longitudeDiff"
                  if $debug;
                if ( !( same_sign( $pixelDistanceX, $longitudeDiff ) ) ) {
                    say
                      "Bad: $key->$key2: pixelDistanceX and longitudeDiff don't have same same sign"
                      if $debug;
                    next;
                }
                $longitudeDiff  = abs($longitudeDiff);
                $pixelDistanceX = abs($pixelDistanceX);

                $longitudeToPixelRatio = $longitudeDiff / $pixelDistanceX;

                #Do some basic sanity checking on the $longitudeToPixelRatio
                if ( $longitudeToPixelRatio > .0016 ) {
                    $main::gcps{$key}{"Mismatches"} =
                      ( $main::gcps{$key}{"Mismatches"} ) + 1;

                    $main::gcps{$key2}{"Mismatches"} =
                      ( $main::gcps{$key2}{"Mismatches"} ) + 1;

                    if ($debug) {
                        say
                          "Bad longitudeToPixelRatio $longitudeToPixelRatio on $key-$key2 pair";
                    }
                }
                else {
                    #For the raster, calculate the Longitude of the upper-left corner based on this object's longitude and the degrees per pixel
                    $ulX =
                      $main::gcps{$key}{"lon"} -
                      ( $main::gcps{$key}{"pngx"} * $longitudeToPixelRatio );

                    #For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
                    $lrX =
                      $main::gcps{$key}{"lon"} +
                      (
                        abs( $main::pngXSize - $main::gcps{$key}{"pngx"} ) *
                          $longitudeToPixelRatio );
                    push @main::xScaleAvg, $longitudeToPixelRatio;
                    push @main::ulXAvg,    $ulX;
                    push @main::lrXAvg,    $lrX;
                }
            }

            #TODO BUG Is this a good idea?
            #This is a hack to weight pairs that have a valid looking longitudeToPixelRatio more heavily
            if ( $ulX && $ulY && $lrX && $lrY ) {

                #The X/Y (or Longitude/Latitude) ratio that would result from using this particular pair

                $longitudeToLatitudeRatio =
                  abs( ( $ulX - $lrX ) / ( $ulY - $lrY ) );

                #This equation comes from a polynomial regression analysis of longitudeToLatitudeRatio by airportLatitudeDec
                my $targetLonLatRatio =
                  targetLonLatRatio($main::airportLatitudeDec);

                if ( ( $longitudeToLatitudeRatio - $targetLonLatRatio ) < .09 )
                {
                    push @main::xScaleAvg, $longitudeToPixelRatio;
                    push @main::ulXAvg,    $ulX;
                    push @main::lrXAvg,    $lrX;
                    push @main::yScaleAvg, $latitudeToPixelRatio;
                    push @main::ulYAvg,    $ulY;
                    push @main::lrYAvg,    $lrY;
                }
                else {
                    say
                      "Bad longitudeToLatitudeRatio: $longitudeToLatitudeRatio, expected $targetLonLatRatio.  Pair $key - $key2"
                      if $debug;
                    $statistics{'$status'} = "AUTOBAD";
                }
            }

            $ulY                   = 0 if not defined $ulY;
            $ulX                   = 0 if not defined $ulX;
            $lrY                   = 0 if not defined $lrY;
            $lrX                   = 0 if not defined $lrX;
            $longitudeToPixelRatio = 0 if not defined $longitudeToPixelRatio;
            $latitudeToPixelRatio  = 0 if not defined $latitudeToPixelRatio;
            $longitudeToLatitudeRatio = 0
              if not defined $longitudeToLatitudeRatio;
            say
              "$key,$key2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio"
              if $debug;

            #If our XYRatio seems to be out of whack for this object pair then don't use the info we derived

            #= 0.000000000065*(B2^6) - 0.000000010206*(B2^5) + 0.000000614793*(B2^4) - 0.000014000833*(B2^3) + 0.000124430097*(B2^2) + 0.003297052219*(B2) + 0.618729977577

            # # if (   $longitudeToLatitudeRatio < .65
            # # || $longitudeToLatitudeRatio > 1.6 )
            # if (
            # abs( $targetLonLatRatio - $longitudeToLatitudeRatio ) >= .14 )
            # {
            # #At this point, we know our latitudeToPixelRatio is reasonably good but our longitudeToLatitudeRatio seems bad (so longitudeToPixelRatio is bad)
            # #Recalculate the longitudes of our upper left and lower right corners with something about right for this latitude
            # say
            # "Bad longitudeToLatitudeRatio $longitudeToLatitudeRatio on $key-$key2 pair.  Target was $targetLonLatRatio"
            # if $debug;
            # $gcps{$key}{"Mismatches"}  = ( $gcps{$key}{"Mismatches"} ) + 1;
            # $gcps{$key2}{"Mismatches"} = ( $gcps{$key2}{"Mismatches"} ) + 1;
            # my $targetXyRatio =
            # 0.000007 * ( $ulY**3 ) -
            # 0.0002 *   ( $ulY**2 ) +
            # 0.0037 *   ($ulY) + 1.034;
            # my $guessAtLongitudeToPixelRatio =
            # $targetXyRatio * $latitudeToPixelRatio;
            # say
            # "Setting longitudeToPixelRatio to $guessAtLongitudeToPixelRatio"
            # if $debug;
            # $longitudeToPixelRatio = $guessAtLongitudeToPixelRatio;

            # $ulX =
            # $gcps{$key}{"lon"} -
            # ( $gcps{$key}{"pngx"} * $longitudeToPixelRatio );
            # $lrX =
            # $gcps{$key}{"lon"} +
            # (
            # abs( $pngXSize - $gcps{$key}{"pngx"} ) *
            # $longitudeToPixelRatio );

            # #next;
            # }

            #Save the output of this iteration to average out later

        }
    }
    return;
}

sub georeferenceTheRaster {

    #----------------------------------------------------------------------------------------------------------------------------------------------------
    #Try to georeference based on Upper Left and Lower Right extents of longitude and latitude

    #Uncomment these lines to use the average values  instead of median
    # my $upperLeftLon  = $ulXAvrg;
    # my $upperLeftLat  = $ulYAvrg;
    # my $lowerRightLon = $lrXAvrg;
    # my $lowerRightLat = $lrYAvrg;

    #Uncomment these lines to use the median values instead of average
    my $upperLeftLon  = $main::ulXmedian;
    my $upperLeftLat  = $main::ulYmedian;
    my $lowerRightLon = $main::lrXmedian;
    my $lowerRightLat = $main::lrYmedian;

    my $medianLonDiff = $upperLeftLon - $lowerRightLon;
    my $medianLatDiff = $upperLeftLat - $lowerRightLat;

    $main::lonLatRatio = abs( $medianLonDiff / $medianLatDiff );

    #This equation comes from a polynomial regression analysis of longitudeToLatitudeRatio by airportLatitudeDec
    my $targetLonLatRatio = targetLonLatRatio($main::airportLatitudeDec);

    $statistics{'$upperLeftLon'}      = $upperLeftLon;
    $statistics{'$upperLeftLat'}      = $upperLeftLat;
    $statistics{'$lowerRightLon'}     = $lowerRightLon;
    $statistics{'$lowerRightLat'}     = $lowerRightLat;
    $statistics{'$lonLatRatio'}       = $main::lonLatRatio;
    $statistics{'$targetLonLatRatio'} = $targetLonLatRatio;

    #    say "lonLatRatio $lonLatRatio, targetLonLatRatio: $targetLonLatRatio, Difference: " . abs( $lonLatRatio - $targetLonLatRatio) . "$targetPdf";

    if ( abs( $main::lonLatRatio - $targetLonLatRatio ) > .1 ) {
        say
          "Bad lonLatRatio $main::lonLatRatio, expected $targetLonLatRatio, Difference: "
          . abs( $main::lonLatRatio - $targetLonLatRatio );

        $statistics{'$status'} = "AUTOBAD";

        if ($shouldSaveBadRatio) {
            $main::targetvrt = $main::targetVrtBadRatio;

        }
        else {
            say "Not georeferencing $main::targetPdf";
            return;
        }
    }

    if ($debug) {
        say "Target Longitude/Latitude ratio: " . $targetLonLatRatio;
        say "Output Longitude/Latitude Ratio: " . $main::lonLatRatio;
        say "Input PDF ratio: " . $main::pdfXYRatio;
        say "";
    }

    #---Commenting this out to try using GCP strings.  This section works
    my $gdal_translateCommand =
      "gdal_translate -q -of VRT -strict -a_srs \"+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs\" -co worldfile=yes  -a_ullr $upperLeftLon $upperLeftLat $lowerRightLon $lowerRightLat '$main::targetpng'  '$main::targetvrt' ";

    if ($debug) {
        say $gdal_translateCommand;
        say "";
    }

    #Run gdal_translate
    #Really we're just doing this for the worldfile.  I bet we could create it ourselves quicker
    my $gdal_translateoutput = qx($gdal_translateCommand);

    # $gdal_translateoutput =
    # qx(gdal_translate  -strict -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpng $targetvrt);
    my $retval = $? >> 8;

    if ( $retval != 0 ) {
        $statistics{'$status'} = "AUTOBAD";
        croak
          "Error executing gdal_translate.  Is it installed? Return code was $retval";
    }
    say $gdal_translateoutput if $debug;

    #---------
    # # # # #Comment this section out to get back to working setup
    # # # # 		my $gdal_translateCommand =
    # # # # 	      "gdal_translate -q -of VRT -strict -a_srs EPSG:4326 $main::gcpstring '$main::targetpng'  '$main::targetvrt'";
    # # # # 	    if ($debug) {
    # # # # 		say $gdal_translateCommand;
    # # # # 		say "";
    # # # # 	    }
    # # # #
    # # # # 	    #Run gdal_translate
    # # # #
    # # # # 	    my $gdal_translateoutput = qx($gdal_translateCommand);
    # # # #
    # # # # 	    my $retval = $? >> 8;
    # # # #
    # # # # 	    if ( $retval != 0 ) {
    # # # # 		carp
    # # # # 		  "Error executing gdal_translate.  Is it installed? Return code was $retval";
    # # # # 		++$main::failCount;
    # # # # 		  $statistics{'$status'} = "AUTOBAD";
    # # # # 		touchFile($main::failFile);
    # # # #
    # # # # 		# say "Touching $main::failFile";
    # # # # 		# open( my $fh, ">", "$main::failFile" )
    # # # # 		# or die "cannot open > $main::failFile $!";
    # # # # 		# close($fh);
    # # # # 		return (1);
    # # # # 	    }
    # # # # 	    say $gdal_translateoutput if $debug;
    # # # # 	    #Run gdalwarp
    # # # #
    # # # # 	    my $gdalwarpCommand =
    # # # # 	      "gdalwarp -q -of VRT -t_srs EPSG:4326 -order 1 -overwrite -refine_gcps .1  '$main::targetvrt'  '$main::targetvrt2'";
    # # # #
    # # # # 	    if ($debug) {
    # # # # 		say $gdalwarpCommand;
    # # # # 		say "";
    # # # # 	    }
    # # # #
    # # # # 	    my $gdalwarpCommandOutput = qx($gdalwarpCommand);
    # # # #
    # # # # 	    $retval = $? >> 8;
    # # # #
    # # # # 	#     if ( $retval != 0 ) {
    # # # # 	#         carp
    # # # # 	#           "Error executing gdalwarp.  Is it installed? Return code was $retval";
    # # # # 	#         ++$main::failCount;
    # # # # 	#         touchFile($main::failFile);
    # # # # 	#         $statistics{'$status'} = "AUTOBAD";
    # # # # 	#         return (1);
    # # # # 	#     }
    # # # #
    # # # # 	    say "$retval: $gdalwarpCommandOutput";
    # # # #     #---------

    # my $gdalwarpoutput;
    # $gdalwarpoutput =
    # qx(gdalwarp -t_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" -dstalpha -order 1  -overwrite  -r bilinear $targetvrt $targettif);
    # $retval = $? >> 8;
    # die "No output from gdalwarp.  Is it installed? Return code was $retval"
    # if ( $gdalwarpoutput eq "" || $retval != 0 );

    # #command line paramets to consider adding: "-r lanczos", "-order 1", "-overwrite"
    # # -refine_gcps tolerance minimum_gcps:
    # # (GDAL >= 1.9.0) refines the GCPs by automatically eliminating outliers. Outliers will be
    # # eliminated until minimum_gcps are left or when no outliers can be detected. The
    # # tolerance is passed to adjust when a GCP will be eliminated. Note that GCP refinement
    # # only works with polynomial interpolation. The tolerance is in pixel units if no
    # # projection is available, otherwise it is in SRS units. If minimum_gcps is not provided,
    # # the minimum GCPs according to the polynomial model is used.

    # say $gdalwarpoutput;

    #This version tries using the PDF directly instead of the intermediate PNG
    # say $gcpstring;
    # $output = qx(gdal_translate -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetPdf $targetPdf.vrt);
    # say $output;
    # $output = qx(gdalwarp -t_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" -dstalpha $targetPdf.vrt $targettif);
    # say $output;
    $statistics{'$status'} = "AUTOGOOD";
    return;
}

sub calculateSmoothedRealWorldExtentsOfRaster {

    #X-scale average and standard deviation
    #calculateXScale();
    say "X-Scale" if $debug;
    ( $main::xAvg, $main::xMedian, $main::xStdDev ) =
      calculateSmootherValuesOfArray( \@main::xScaleAvg );

    #Y-scale average and standard deviation
    # calculateYScale();
    say "Y-Scale" if $debug;
    ( $main::yAvg, $main::yMedian, $main::yStdDev ) =
      calculateSmootherValuesOfArray( \@main::yScaleAvg );

    #ulX average and standard deviation
    # calculateULX();
    say "ULX" if $debug;
    ( $main::ulXAvrg, $main::ulXmedian, $main::ulXStdDev ) =
      calculateSmootherValuesOfArray( \@main::ulXAvg );

    #uly average and standard deviation
    # calculateULY();
    say "ULY" if $debug;
    ( $main::ulYAvrg, $main::ulYmedian, $main::ulYStdDev ) =
      calculateSmootherValuesOfArray( \@main::ulYAvg );

    #lrX average and standard deviation
    # calculateLRX();
    say "LRX" if $debug;
    ( $main::lrXAvrg, $main::lrXmedian, $main::lrXStdDev ) =
      calculateSmootherValuesOfArray( \@main::lrXAvg );

    #lrY average and standard deviation
    # calculateLRY();
    say "LRY" if $debug;
    ( $main::lrYAvrg, $main::lrYmedian, $main::lrYStdDev ) =
      calculateSmootherValuesOfArray( \@main::lrYAvg );
    return;
}

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
      . "runwayIconsCount = ?, "
      . "isPortraitOrientation = ?, "
      . "xPixelSkew = ?, "
      . "yPixelSkew = ?,"
      . "status = ?"
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
    $dtppSth->bind_param( 28, $statistics{'$isPortraitOrientation'} );
    $dtppSth->bind_param( 29, $statistics{'$xPixelSkew'} );
    $dtppSth->bind_param( 30, $statistics{'$yPixelSkew'} );
    $dtppSth->bind_param( 31, $statistics{'$status'} );
    $dtppSth->bind_param( 32, $PDF_NAME );

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

sub outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb {

    #Only outline our unique potential obstacle_heights with green
    foreach my $key ( sort keys %main::obstacleTextBoxes ) {

        #Is there a obstacletextbox with the same text as our obstacle's height?
        if (
            exists
            $main::unique_obstacles_from_db{ $main::obstacleTextBoxes{$key}
                  {"Text"} } )
        {
            #Yes, draw a box around it
            my $obstacle_box = $main::page->gfx;
            $obstacle_box->strokecolor('green');
            $obstacle_box->linewidth(.1);
            $obstacle_box->rect(
                $main::obstacleTextBoxes{$key}{"CenterX"} -
                  $main::obstacleTextBoxes{$key}{"Width"} / 2,
                $main::obstacleTextBoxes{$key}{"CenterY"} -
                  $main::obstacleTextBoxes{$key}{"Height"} / 2,
                $main::obstacleTextBoxes{$key}{"Width"},
                $main::obstacleTextBoxes{$key}{"Height"}

            );

            $obstacle_box->stroke;
        }
    }
    return;
}

sub findFixesNearAirport {

    # my $radius = .5;
    my $radiusNm = 50;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport

    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      ( $radiusNm / 60 ) / cos( deg2rad($main::airportLatitudeDec) );

    #What type of fixes to look for
    my $type = "%REP-PT";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
        "SELECT * FROM fixes WHERE  (Latitude >  $main::airportLatitudeDec - $radiusDegreesLatitude ) and 
                                (Latitude < $main::airportLatitudeDec + $radiusDegreesLatitude ) and 
                                (Longitude >  $main::airportLongitudeDec - $radiusDegreesLongitude ) and 
                                (Longitude < $main::airportLongitudeDec + $radiusDegreesLongitude ) and
                                (Type like '$type')"
    );
    $sth->execute();

    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$_row;
        $main::fixes_from_db{$fixname}{"Name"} = $fixname;
        $main::fixes_from_db{$fixname}{"Lat"}  = $lat;
        $main::fixes_from_db{$fixname}{"Lon"}  = $lon;
        $main::fixes_from_db{$fixname}{"Type"} = $fixtype;

    }

    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    if ($debug) {
        my $_rows  = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $_rows FIXES within $radiusNm nm of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) from database";

        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $_rows row(s)";

        #print Dumper ( \%fixes_from_db );
        say "";
    }

    return;
}

sub findFeatureInDatabaseNearAirport {

    #my ($radius, $type, $table, $referenceToHash) = @_;
    my $radius = .5;

    #What type of fixes to look for
    my $type = "%REP-PT";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
        "SELECT * FROM fixes WHERE  (Latitude >  $main::airportLatitudeDec - $radius ) and 
                                (Latitude < $main::airportLatitudeDec + $radius ) and 
                                (Longitude >  $main::airportLongitudeDec - $radius ) and 
                                (Longitude < $main::airportLongitudeDec +$radius ) and
                                (Type like '$type')"
    );
    $sth->execute();

    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$_row;
        $main::fixes_from_db{$fixname}{"Name"} = $fixname;
        $main::fixes_from_db{$fixname}{"Lat"}  = $lat;
        $main::fixes_from_db{$fixname}{"Lon"}  = $lon;
        $main::fixes_from_db{$fixname}{"Type"} = $fixtype;

    }

    if ($debug) {
        my $nmLatitude = 60 * $radius;
        my $nmLongitude =
          $nmLatitude * cos( deg2rad($main::airportLatitudeDec) );

        my $_rows  = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $_rows FIXES within $radius degrees of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) ($nmLongitude x $nmLatitude nm)  from database";

        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $_rows row(s)";

        #print Dumper ( \%fixes_from_db );
        say "";
    }

    return;
}

sub findGpsWaypointsNearAirport {

    # my $radius      = .5;
    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    #How far away from the airport to look for feature
    my $radiusNm = 40;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport
    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      abs( ( $radiusNm / 60 ) / cos( deg2rad($main::airportLatitudeDec) ) );

    say
      "radiusLongitude:$radiusDegreesLongitude radiusLatitude: $radiusDegreesLatitude"
      if $debug;

    #What type of fixes to look for
    my $type = "%";

    # say " SELECT * FROM fixes WHERE
    # (Latitude BETWEEN  ($airportLatitudeDec - $radiusDegreesLatitude ) and ( $airportLatitudeDec + $radiusDegreesLatitude ) )
    # AND
    # (Longitude BETWEEN ($airportLongitudeDec - $radiusDegreesLongitude ) and ( $airportLongitudeDec + $radiusDegreesLongitude ) )
    # AND
    # (Type like '$type')";

    # # #Query the database for fixes within our $radius
    # my $sth = $dbh->prepare(
    # "SELECT * FROM fixes WHERE
    # (Latitude BETWEEN  ($airportLatitudeDec - $radiusDegreesLatitude ) and ( $airportLatitudeDec + $radiusDegreesLatitude ) )
    # AND
    # (Longitude BETWEEN ($airportLongitudeDec - $radiusDegreesLongitude ) and ( $airportLongitudeDec + $radiusDegreesLongitude ) )
    # AND
    # (Type like '$type')"
    # );
    my $sth = $dbh->prepare(
        "SELECT * FROM fixes WHERE  
                                (Latitude >  $main::airportLatitudeDec - $radiusDegreesLatitude ) and 
                                (Latitude < $main::airportLatitudeDec +$radiusDegreesLatitude ) and 
                                (Longitude >  $main::airportLongitudeDec - $radiusDegreesLongitude ) and 
                                (Longitude < $main::airportLongitudeDec +$radiusDegreesLongitude ) and
                                (Type like '$type')"
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$_row;
        $main::gpswaypoints_from_db{$fixname}{"Name"} = $fixname;
        $main::gpswaypoints_from_db{$fixname}{"Lat"}  = $lat;
        $main::gpswaypoints_from_db{$fixname}{"Lon"}  = $lon;
        $main::gpswaypoints_from_db{$fixname}{"Type"} = $fixtype;

    }

    if ($debug) {
        my $_rows  = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $_rows GPS waypoints within $radiusNm NM of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) from database";
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $_rows row(s)";

        #print Dumper ( \%gpswaypoints_from_db );
        say "";
    }
    return;
}

sub findNavaidsNearAirport {

    # my $radius      = .7;
    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    #How far away from the airport to look for feature
    my $radiusNm = 30;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport

    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      ( $radiusNm / 60 ) / cos( deg2rad($main::airportLatitudeDec) );

    #What type of fixes to look for
    my $type = "%VOR%";

    #Query the database for fixes within our $radius
    my $sth = $main::dbh->prepare(
        "SELECT * FROM navaids WHERE  
                                (Latitude >  $main::airportLatitudeDec - $radiusDegreesLatitude ) and 
                                (Latitude < $main::airportLatitudeDec +$radiusDegreesLatitude ) and 
                                (Longitude >  $main::airportLongitudeDec - $radiusDegreesLongitude ) and 
                                (Longitude < $main::airportLongitudeDec +$radiusDegreesLongitude ) and
                                (Type like '$type' OR  Type like '%NDB%')"
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$allSqlQueryResults) {
        my ( $navaidName, $lat, $lon, $navaidType ) = @$_row;
        $main::navaids_from_db{$navaidName}{"Name"} = $navaidName;
        $main::navaids_from_db{$navaidName}{"Lat"}  = $lat;
        $main::navaids_from_db{$navaidName}{"Lon"}  = $lon;
        $main::navaids_from_db{$navaidName}{"Type"} = $navaidType;

    }

    if ($debug) {
        my $_rows  = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $_rows Navaids within $radiusNm nm of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) from database"
          if $debug;
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $_rows row(s)";

        # print Dumper ( \%navaids_from_db );
        say "";
    }
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
                $main::gcps{ "$type-" . $text . '-' . $rand }{"pngx"} =
                  $_rasterX;
                $main::gcps{ "$type-" . $text . '-' . $rand }{"pngy"} =
                  $_rasterY;
                $main::gcps{ "$type-" . $text . '-' . $rand }{"pdfx"} = $_pdfX;
                $main::gcps{ "$type-" . $text . '-' . $rand }{"pdfy"} = $_pdfY;
                $main::gcps{ "$type-" . $text . '-' . $rand }{"lon"}  = $lon;
                $main::gcps{ "$type-" . $text . '-' . $rand }{"lat"}  = $lat;
            }
            else {
                say "$type $text is being ignored" if $debug;
            }

        }
    }
    store( \%main::gcps, $main::storedGcpHash );
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

sub outlineValidFixTextBoxes {
    foreach my $key ( keys %main::fixTextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $main::fixes_from_db{ $main::fixTextboxes{$key}{"Text"} } )
        {
            my $fix_box = $main::page->gfx;
            $fix_box->strokecolor('orange');

            #Yes, draw an orange box around it
            $fix_box->rect(
                $main::fixTextboxes{$key}{"CenterX"} -
                  ( $main::fixTextboxes{$key}{"Width"} / 2 ),
                $main::fixTextboxes{$key}{"CenterY"} -
                  ( $main::fixTextboxes{$key}{"Height"} / 2 ),
                $main::fixTextboxes{$key}{"Width"},
                $main::fixTextboxes{$key}{"Height"}
            );

            $fix_box->stroke;
        }
        else {
            #delete $fixTextboxes{$key};
        }
    }
    return;
}

sub outlineValidNavaidTextBoxes {
    foreach my $key ( keys %main::vorTextboxes ) {

        #Is there a vorTextbox with the same text as our navaid?
        if (
            exists $main::navaids_from_db{ $main::vorTextboxes{$key}{"Text"} } )
        {
            my $navBox = $main::page->gfx;
            $navBox->strokecolor('orange');

            #Yes, draw an orange box around it
            $navBox->rect(
                $main::vorTextboxes{$key}{"CenterX"} -
                  ( $main::vorTextboxes{$key}{"Width"} / 2 ),
                $main::vorTextboxes{$key}{"CenterY"} +
                  ( $main::vorTextboxes{$key}{"Height"} / 2 ),
                $main::vorTextboxes{$key}{"Width"},
                -( $main::vorTextboxes{$key}{"Height"} )

            );

            $navBox->stroke;
        }
        else {
            #delete $fixTextboxes{$key};
        }
    }
    return;
}

sub findHorizontalCutoff {
    my $_upperYCutoff = $main::pdfYSize;
    my $_lowerYCutoff = 0;

    #Find the highest purely horizonal line below the midpoint of the page
    foreach my $key ( sort keys %main::horizontalAndVerticalLines ) {

        #TODO separate hashes for horz and vertical?

        my $x      = $main::horizontalAndVerticalLines{$key}{"X"};
        my $x2     = $main::horizontalAndVerticalLines{$key}{"X2"};
        my $length = abs( $x - $x2 );
        my $y2     = $main::horizontalAndVerticalLines{$key}{"Y2"};
        my $yCoord = $main::horizontalAndVerticalLines{$key}{"Y"};

        #Check that this is a horizonal line since we're also currently storing vertical ones in this hash too
        next unless ( $yCoord == $y2 );

        if (   ( $yCoord > $_lowerYCutoff )
            && ( $yCoord < .5 * $main::pdfYSize )
            && ( $length > .5 * $main::pdfXSize ) )
        {

            $_lowerYCutoff = $yCoord;
        }
        if (   ( $yCoord < $_upperYCutoff )
            && ( $yCoord > .5 * $main::pdfYSize )
            && ( $length > .3 * $main::pdfXSize ) )
        {

            $_upperYCutoff = $yCoord;
        }
    }

    # #Find the lowest purely horizonal line above the midpoint of the page
    # foreach my $key ( sort keys %horizontalAndVerticalLines ) {
    # my $x      = $horizontalAndVerticalLines{$key}{"X"};
    # my $x2     = $horizontalAndVerticalLines{$key}{"X2"};
    # my $length = abs( $x - $x2 );
    # my $y2     = $horizontalAndVerticalLines{$key}{"Y2"};
    # my $yCoord = $horizontalAndVerticalLines{$key}{"Y"};

    # #Check that this is a horizonal line since we're also currently storing vertical ones in this hash too
    # #TODO separate hashes for horz and vertical
    # next unless ( $yCoord == $y2 );
    # #TODO BUG We may not always have large contiguous horizonal lines at the top, we may
    # #need to make the length check something smaller
    # if ( ( $yCoord < $_upperYCutoff ) && ( $yCoord > .5 * $pdfYSize )  && ( $length > .2 * $pdfXSize )) {

    # $_upperYCutoff = $yCoord;
    # }
    # }
    say "Returning $_upperYCutoff and $_lowerYCutoff  as horizontal cutoffs"
      if $debug;
    return ( $_lowerYCutoff, $_upperYCutoff );
}

sub outlineValidGpsWaypointTextBoxes {

    #Orange outline fixTextboxes that have a valid fix name in them
    #Delete fixTextboxes that don't have a valid nearby fix in them
    foreach my $key ( keys %main::fixTextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if (
            exists
            $main::gpswaypoints_from_db{ $main::fixTextboxes{$key}{"Text"} } )
        {
            my $fix_box = $main::page->gfx;

            #Yes, draw an orange box around it
            $fix_box->rect(
                $main::fixTextboxes{$key}{"CenterX"} -
                  ( $main::fixTextboxes{$key}{"Width"} / 2 ),
                $main::fixTextboxes{$key}{"CenterY"} -
                  ( $main::fixTextboxes{$key}{"Height"} / 2 ),
                $main::fixTextboxes{$key}{"Width"},
                $main::fixTextboxes{$key}{"Height"}

            );
            $fix_box->strokecolor('orange');
            $fix_box->stroke;
        }
        else {
            #delete $fixTextboxes{$key};

        }
    }
    return;
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

sub findIlsIcons {

    # my ( $hashRefA, $_output ) = @_;

    # say ":findIlsIcons" if $debug;

    # # #A reference to the icons hash
    # # my ($hashRefA) = $_[0];

    # # #the uncompressed contents of the PDF stream
    # # my ($_output) = $_[1];

    # #The number of data points we're collecting for each icon
    # my $iconDataPoints = 2;
    # my $iconType       = "ILS";

    # #REGEX building blocks
    # #An ILS icon
    # #The four curve section is the small dot in the middle
    # my $ilsRegex = qr/^$transformCaptureXYRegex$
    # ^$originRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^S$
    # ^Q$
    # ^1\sj\s1\sJ\s$
    # ^$transformNoCaptureXYRegex$
    # ^$originRegex$
    # ^$lineRegex$
    # ^$lineRegex$
    # ^$lineRegex$
    # ^$lineRegex$
    # ^S$
    # ^Q$
    # ^$transformNoCaptureXYRegex$
    # ^$originRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^$bezierCurveRegex$
    # ^f\*$
    # ^Q$/m;

    # my @iconData = $_output =~ /$ilsRegex/ig;

    # #say @iconData;

    # # say $&;
    # #The total length of the array of data points we collected from the regex
    # my $iconDataLength = 0 + @iconData;

    # #The total count of icons in the array
    # my $iconCount = $iconDataLength / $iconDataPoints;

    # if ( $iconDataLength >= $iconDataPoints ) {

    # # my $rand = rand();
    # for ( my $i = 0 ; $i < $iconDataLength ; $i = $i + $iconDataPoints ) {
    # my $id      = $i . rand();
    # my $x       = $iconData[$i];
    # my $y       = $iconData[ $i + 1 ];
    # my $width   = "";
    # my $height  = "";
    # my $CenterX = "";
    # my $CenterY = "";

    # #put our calculated values into a hash

    # $hashRefA->{$iconType}{$id}{"X"}              = $x;
    # $hashRefA->{$iconType}{$id}{"Y"}              = $y;
    # $hashRefA->{$iconType}{$id}{"iconCenterXPdf"} = $x + 2;
    # $hashRefA->{$iconType}{$id}{"iconCenterYPdf"} = $y - 3;
    # $hashRefA->{$iconType}{$id}{"Name"}           = "none";
    # $hashRefA->{$iconType}{$id}{"Type"}           = "$iconType";
    # }

    # }

    # #my $ilsCount = keys(%$hashRefA->{$iconType});
    # # if ($debug) {
    # # print " $iconCount $iconType ";
    # # print Dumper ( $hashRefA->{$iconType} );
    # # }

    # return;
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

    #Find potential obstacle height textboxes
    findObstacleHeightTextBoxes();

    #Find textboxes that are valid for both fix and GPS waypoints
    findFixTextboxes();

    #Find textboxes that are valid for navaids
    findNavaidTextboxes();
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

sub outlines {
    say ":outlines" if $debug;
    my $outlineWidth = 1;
    my $outlineColor = "black";

    my $EGTransparent = $main::pdfOutlines->egstate();
    my $EGNormal      = $main::pdfOutlines->egstate();
    $EGTransparent->transparency(0.5);
    $EGNormal->transparency(0);

    #Draw the various types of boxes on the output PDF

    #Uncomment this if we ever need to write text on PDF
    # my %font = (
    # Helvetica => {
    # Bold =>
    # $pdfOutlines->corefont( 'Helvetica-Bold', -encoding => 'latin1' ),

    # #      Roman  => $pdfOutlines->corefont('Helvetica',         -encoding => 'latin1'),
    # #      Italic => $pdfOutlines->corefont('Helvetica-Oblique', -encoding => 'latin1'),
    # },
    # Times => {

    # #      Bold   => $pdfOutlines->corefont('Times-Bold',        -encoding => 'latin1'),
    # Roman => $pdfOutlines->corefont( 'Times', -encoding => 'latin1' ),

    # #      Italic => $pdfOutlines->corefont('Times-Italic',      -encoding => 'latin1'),
    # },
    # );

    #TODO This was yellow just for testing
    my ($bigOleBox) = $main::pageOutlines->gfx;
    $bigOleBox->egstate($EGNormal);

    #Draw a big box to stop the flood because we can't always find the main box in the PDF
    $bigOleBox->strokecolor($outlineColor);
    $bigOleBox->linewidth(5);
    $bigOleBox->rect( 20, 40, 350, 500 );
    $bigOleBox->stroke;

    #Draw a horizontal line at the $lowerYCutoff to stop the flood in case we don't findNavaidTextboxes
    #all of the lines
    $bigOleBox->move( 0, $main::lowerYCutoff );
    $bigOleBox->line( $main::pdfXSize, $main::lowerYCutoff );
    $bigOleBox->stroke;

    foreach my $key ( sort keys %main::horizontalAndVerticalLines ) {

        my ($lines) = $main::pageOutlines->gfx;
        $lines->strokecolor($outlineColor);
        $lines->linewidth($outlineWidth);
        $lines->move(
            $main::horizontalAndVerticalLines{$key}{"X"},
            $main::horizontalAndVerticalLines{$key}{"Y"}
        );
        $lines->line(
            $main::horizontalAndVerticalLines{$key}{"X2"},
            $main::horizontalAndVerticalLines{$key}{"Y2"}
        );

        $lines->stroke;
    }
    foreach my $key ( sort keys %main::insetBoxes ) {

        my ($insetBox) = $main::pageOutlines->gfx;
        $insetBox->strokecolor($outlineColor);
        $insetBox->linewidth($outlineWidth);
        $insetBox->rect(
            $main::insetBoxes{$key}{X},     $main::insetBoxes{$key}{Y},
            $main::insetBoxes{$key}{Width}, $main::insetBoxes{$key}{Height},
        );

        $insetBox->stroke;
    }
    foreach my $key ( sort keys %main::largeBoxes ) {

        my ($largeBox) = $main::pageOutlines->gfx;
        $largeBox->strokecolor($outlineColor);
        $largeBox->linewidth($outlineWidth);
        $largeBox->rect(
            $main::largeBoxes{$key}{X},     $main::largeBoxes{$key}{Y},
            $main::largeBoxes{$key}{Width}, $main::largeBoxes{$key}{Height},
        );

        $largeBox->stroke;
    }

    foreach my $key ( sort keys %main::insetCircles ) {

        my ($insetCircle) = $main::pageOutlines->gfx;
        $insetCircle->strokecolor($outlineColor);
        $insetCircle->linewidth($outlineWidth);
        $insetCircle->circle(
            $main::insetCircles{$key}{X},
            $main::insetCircles{$key}{Y},
            $main::insetCircles{$key}{Radius},
        );

        $insetCircle->stroke;
    }

    #Draw a filled rectangle from $upperYCutoff to top of PDF
    my ($cutoffRectangles) = $main::pageOutlines->gfx;
    $cutoffRectangles->egstate($EGNormal);
    $cutoffRectangles->strokecolor('black');
    $cutoffRectangles->linewidth(5);
    $cutoffRectangles->fillcolor('white');
    $cutoffRectangles->rectxy( 0, $main::upperYCutoff, $main::pdfXSize,
        $main::pdfYSize );
    $cutoffRectangles->fillstroke;

    #Draw a filled rectangle from $upperYCutoff to bottom of PDF
    $cutoffRectangles->egstate($EGNormal);
    $cutoffRectangles->strokecolor('black');
    $cutoffRectangles->linewidth(5);
    $cutoffRectangles->fillcolor('white');
    $cutoffRectangles->rectxy( 0, $main::lowerYCutoff, $main::pdfXSize, 0 );
    $cutoffRectangles->fillstroke;

    # $bigOleBox->stroke;
    return;
}

sub findNotToScaleIndicator {
    my ($_output) = @_;

    # q 1 0 0 1 248.72 189.17 cm
    # 0 0 m
    # -2.6 3.82 l
    # 1.43 6.05 l
    # -1.16 9.79 l
    # 2.87 12.03 l
    # 0.28 15.84 l
    # 4.31 18.07 l
    # S
    # Q
    # q 1 0 0 1 246.7 189.68 cm
    # 0 0 m
    # -2.59 3.74 l
    # 1.44 5.97 l
    # -1.15 9.79 l
    # 2.88 12.02 l
    # 0.29 15.83 l
    # 4.25 18.07 l
    # S
    # Q

    #REGEX building blocks
    #Set of two squiggly lines indicating something isn't to scale
    my $notToScaleIndicatorRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^S$
^Q$
^$main::transformNoCaptureXYRegex$
^$main::originRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^$main::lineRegex$
^S$
^Q$/m;

    my @tempNotToScaleIndicator = $_output =~ /$notToScaleIndicatorRegex/ig;
    my $notToScaleIndicatorDataPoints = 2;

    my $tempNotToScaleIndicatorLength = 0 + @tempNotToScaleIndicator;
    my $notToScaleIndicatorCount =
      $tempNotToScaleIndicatorLength / $notToScaleIndicatorDataPoints;

    if ( $tempNotToScaleIndicatorLength >= $notToScaleIndicatorDataPoints ) {
        my $random = rand();
        for (
            my $i = 0 ;
            $i < $tempNotToScaleIndicatorLength ;
            $i = $i + $notToScaleIndicatorDataPoints
          )
        {
            my $x = $tempNotToScaleIndicator[$i];
            my $y = $tempNotToScaleIndicator[ $i + 1 ];

            #put them into a hash

            $main::notToScaleIndicator{ $i . $random }{"CenterX"} = $x;
            $main::notToScaleIndicator{ $i . $random }{"CenterY"} = $y;

        }

    }

    $notToScaleIndicatorCount = keys(%main::notToScaleIndicator);

    #Save statistics
    $main::statistics{'$notToScaleIndicatorCount'} = $notToScaleIndicatorCount;

    # if ($debug) {
    # print "$notToScaleIndicatorCount notToScaleIndicator(s) ";

    # print Dumper ( \%notToScaleIndicator );

    # }

    return;
}

sub findRunwayIcons {
    my ($_output) = @_;
    say ":findRunwayIcons" if $debug;

    # Military plate runways are drawn in one fell swoop like this (from SSC TACAN 22R)
    # q 1 0 0 1 152.36 347.08 cm 0 0 m
    # -9.72 -14.04 l
    # S 1 0 0 1 -6.12 -14.28 cm 0 0 m
    # 8.16 11.52 l
    # S

    #REGEX building blocks
    #A  line
    my $runwayLineRegex = qr/^$main::transformCaptureXYRegex$
^$main::originRegex$
^($main::numberRegex)\s($main::numberRegex)\s+l$
^S$
^Q$/m;

    my @tempRunwayIcon = $_output =~ /$runwayLineRegex/ig;

    my $tempRunwayIconLength = 0 + @tempRunwayIcon;
    my $tempRunwayIconCount  = $tempRunwayIconLength / 4;

    if ( $tempRunwayIconLength >= 4 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempRunwayIconLength ; $i = $i + 4 ) {
            my $_x1    = $tempRunwayIcon[$i];
            my $_y1    = $tempRunwayIcon[ $i + 1 ];
            my $_xDiff = $tempRunwayIcon[ $i + 2 ];
            my $_yDiff = $tempRunwayIcon[ $i + 3 ];
            my $_x2    = $_x1 + $_xDiff;
            my $_y2    = $_y1 + $_yDiff;

            my $runwayLineLength =
              sqrt( ( $_x1 - $_x2 )**2 + ( $_y1 - $_y2 )**2 );

            # say "$_x1 $_y1 $_x2 $_y2 $runwayLineLength";
            #Runway lines must be between these lengths in points
            # Some of the visual procedures are higher scale and the runway lines can be +57 pts
            next
              if ( abs($runwayLineLength) > 22 || abs($runwayLineLength) < 4 );

            #Calculate the true heading of a line given starting and ending points
            my $runwayLineTrueHeading =
              round( trueHeading( $_x1, $_y1, $_x2, $_y2 ) );
            my $runwayLineSlope = round( slopeAngle( $_x1, $_y1, $_x2, $_y2 ) );
            my $_midpointX      = ( $_x1 + $_x2 ) / 2;
            my $_midpointY      = ( $_y1 + $_y2 ) / 2;

            # say "Line True Heading  $runwayLineTrueHeading Length: $runwayLineLength Line X: $tempRunwayIcon[$i] Line Y: $tempRunwayIcon[$i+1]"
            # if $debug;

            #Iterate through the array of valid runway slopes that we calculated earlier
            # if ( "$runwayLineTrueHeading" ~~ @validRunwaySlopes ) {
            foreach my $validSlope (@main::validRunwaySlopes) {

                #Only match lines that are +- 1 degree of our desired slopel
                next if ( abs( $validSlope - $runwayLineTrueHeading ) > 1 );

                #put them into a hash
                $main::runwayIcons{ $i . $random }{"X"}  = $_x1;
                $main::runwayIcons{ $i . $random }{"Y"}  = $_y1;
                $main::runwayIcons{ $i . $random }{"X2"} = $_x2;
                $main::runwayIcons{ $i . $random }{"Y2"} = $_y2;
                $main::runwayIcons{ $i . $random }{"Length"} =
                  $runwayLineLength;
                $main::runwayIcons{ $i . $random }{"TrueHeading"} =
                  $runwayLineTrueHeading;
                $main::runwayIcons{ $i . $random }{"Slope"} = $runwayLineSlope;
                $main::runwayIcons{ $i . $random }{"CenterX"} = $_midpointX;
                $main::runwayIcons{ $i . $random }{"CenterY"} = $_midpointY;
            }
        }

    }

    # print Dumper ( \%runwayIcons );
    my $runwayIconsCount = keys(%main::runwayIcons);

    #Save statistics
    $main::statistics{'$runwayIconsCount'} = $runwayIconsCount;

    # if ($debug) {
    # print "$runwayIconsCount possible runway lines ";

    # }

    #-----------------------------------

    return;
}

sub findRunwaysInDatabase {
    #
    my $sth = $main::dbh->prepare(
        "SELECT * FROM runways WHERE 
                                       FaaID like \"$main::airportId\"
                                       "
    );
    $sth->execute();

    my $all = $sth->fetchall_arrayref();

    #How many rows did this search return
    my $_rows = $sth->rows();
    say "Found $_rows runways for $main::airportId" if $debug;

    foreach my $_row (@$all) {
        my (
            $FaaID,      $Length,      $Width,       $LEName,
            $LELatitude, $LELongitude, $LEElevation, $LEHeading,
            $HEName,     $HELatitude,  $HELongitude, $HEElevation,
            $HEHeading
        ) = @$_row;

        # foreach my $_row2 (@$all) {
        # my (
        # $FaaID2,      $Length2,      $Width2,       $LEName2,
        # $LELatitude2, $LELongitude2, $LEElevation2, $LEHeading2,
        # $HEName2,     $HELatitude2,  $HELongitude2, $HEElevation2,
        # $HEHeading2
        # ) = @$_row2;
        # #Don't testg
        # next if ($LEName eq $LEName2);

        # }
        #Skip helipads or waterways
        next if ( $LEName =~ /[HW]/i );
        next
          unless ( $FaaID
            && $Length
            && $Width
            && $LEName
            && $LELatitude
            && $LELongitude
            && $LEElevation
            && $LEHeading
            && $HEName
            && $HELatitude
            && $HELongitude
            && $HEElevation
            && $HEHeading );

        #Convert lon/at to EPSG 3857
        my ( $x1, $y1 ) = WGS84toGoogleBing( $LELongitude, $LELatitude );
        my ( $x2, $y2 ) = WGS84toGoogleBing( $HELongitude, $HELatitude );

        my $trueHeading = round( trueHeading( $x1, $y1, $x2, $y2 ) );
        my $slope = round( slopeAngle( $x1, $y1, $x2, $y2 ) );

        say
          "EPSG:4326 -> 3857 conversion true heading for runway $LEName: $trueHeading"
          if $debug;

        my @A = NESW( $LELongitude, $LELatitude );
        my @B = NESW( $HELongitude, $HELatitude );

        # my $km = great_circle_distance( @A, @B, 6378.137 );    # About 9600 km.
        # say "Distance: " . $km . "km";

        my $rad = great_circle_direction( @A, @B );

        say "True course for $LEName: " . round( rad2deg($rad) ) if $debug;

        #$runwaysFromDatabase{$LEName}{} = $trueHeading;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'LELatitude'} =
          $LELatitude;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'LELongitude'} =
          $LELongitude;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'LEHeading'} =
          $LEHeading;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'HELatitude'} =
          $HELatitude;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'HELongitude'} =
          $HELongitude;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'HEHeading'} =
          $HEHeading;
        $main::runwaysFromDatabase{ $LEName . $HEName }{'Slope'} = $slope;

        $main::runwaysToDraw{ $LEName . $HEName }{'LELatitude'}  = $LELatitude;
        $main::runwaysToDraw{ $LEName . $HEName }{'LELongitude'} = $LELongitude;
        $main::runwaysToDraw{ $LEName . $HEName }{'HELatitude'}  = $HELatitude;
        $main::runwaysToDraw{ $LEName . $HEName }{'HELongitude'} = $HELongitude;

        #say "$FaaID, $Length ,$Width ,$LEName ,$LELatitude ,$LELongitude ,$LEElevation , $LEHeading , $HEName ,$HELatitude ,$HELongitude ,$HEElevation ,$HEHeading";
        # $unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
        # $unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;

    }

    # print Dumper ( \%runwaysFromDatabase );
    my @runwaysToDelete = ();

    #Delete any runways that share a slope within +-5
    foreach my $key ( sort keys %main::runwaysFromDatabase ) {

        # say $key;
        my $slope1      = $main::runwaysFromDatabase{$key}{Slope};
        my $LELatitude1 = $main::runwaysFromDatabase{$key}{"LELatitude"};

        # say $slope1;
        foreach my $key2 ( sort keys %main::runwaysFromDatabase ) {

            # say $key2;
            my $slope2      = $main::runwaysFromDatabase{$key2}{Slope};
            my $LELatitude2 = $main::runwaysFromDatabase{$key2}{"LELatitude"};

            # say $slope2;
            #Don't test against ourself
            next if ( $LELatitude1 == $LELatitude2 );

            if ( abs( $slope1 - $slope2 ) < 5 ) {

                #Mark these runways for deletion if their slopes match
                push @runwaysToDelete, $key;
                push @runwaysToDelete, $key2;
            }

        }
    }

    # say @runwaysToDelete;
    foreach my $key (@runwaysToDelete) {

        #Delete the runways we marked earlier
        delete $main::runwaysFromDatabase{$key};
    }

    foreach my $key ( sort keys %main::runwaysFromDatabase ) {
        push @main::validRunwaySlopes,
          $main::runwaysFromDatabase{$key}{"LEHeading"};
        push @main::validRunwaySlopes,
          $main::runwaysFromDatabase{$key}{"HEHeading"};
    }

    return;
}

sub createOutlinesPdf {

    #Make our masking PDF
    $main::pdfOutlines = PDF::API2->new();

    #Set up the various types of boxes to draw on the output PDF
    $main::pageOutlines = $main::pdfOutlines->page();

    # Set the page size
    $main::pageOutlines->mediabox( $main::pdfXSize, $main::pdfYSize );

    #Find the upper and lower cutoff lines
    ( $main::lowerYCutoff, $main::upperYCutoff ) = findHorizontalCutoff();

    #Draw black lines and boxes around the icons and textboxes we've found so far
    outlines();

    #and save to a PDF to use for a mask
    $main::pdfOutlines->saveas($main::outputPdfOutlines);

    return;
}

sub usage {
    say "Usage: $0 <options> <directory_with_PDFs>";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-i<2 Letter state ID>  To specify a specific state";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
    say "-c Don't overwrite existing .vrt";
    say "-o Re-create outlines/mask files";
    say "-b Allow creation of vrt with known bad lon/lat ratio";
    say "-m Allow use of non-unique obstacles";
    return;
}
