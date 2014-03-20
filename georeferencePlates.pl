#!/usr/bin/perl

# GeilsRerencePlates - a utility to automatically georeference FAA Instrument Approach Plates / Terminal Procedures
# Copyright (C) 2013  Jesse McGraw (jlmcgraw@gmail.com)

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
#-Relies on icons being drawn very specific ways, it won't work if these ever change
#-Relies on text being in PDF.  It seems that most, if not all, military plates have no text in them
#       We may be able to get around this with tesseract OCR but that will take some work
#
#Known issues:
#-Investigate not creating the intermediate PNG (guessing at dimensions)
#Our pixel/RealWorld ratios are hardcoded now for 300dpi, need to make dynamic per our DPI setting
#
#TODO
#Have a two-way check for icon to textbox matching
#
#Try to somehow discard objects outside of our central drawing box
#       A crude way to do this would be to find largest and 2nd largest horizontal lines closest to Y center and
#       and use those as upper and lower bounds.
#       org
#       Draw all of the horizontal and vertical lines to a separate image, do a flood fill from the center and then test X,Y of
#       our test point against the color of the X,Y in that image?
#
#Draw where we think the airport is on marked PDF so we can see if we're incorrectly georeferencing
#without having to load into qgis
#
#Discard icons and textboxes  inside insetBoxes or outside the horizontal bounds early in the process
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
use Time::HiRes q/gettimeofday/;
use Math::Polygon;
use Acme::Tools qw(between);

#PDF constants
use constant mm => 25.4 / 72;
use constant in => 1 / 72;
use constant pt => 1;

#Some subroutines
use GeoReferencePlatesSubroutines;

#Some other constants
#----------------------------------------------------------------------------------------------
#Max allowed radius in PDF points from an icon (obstacle, fix, gps) to it's associated textbox's center
my $maxDistanceFromObstacleIconToTextBox = 20;

#DPI of the output PNG
my $pngDpi = 300;

use vars qw/ %opt /;
my $opt_string = 'spva:';
my $arg_num    = scalar @ARGV;

#This will fail if we receive an invalid option
unless ( getopts( "$opt_string", \%opt ) ) {
    say "Usage: $0 <pdf_file>";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
    exit(1);
}

#We need at least one argument (the name of the PDF to process)
if ( $arg_num < 1 ) {
    say "Usage: $0 <pdf_file>";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
    exit(1);
}

my $debug            = $opt{v};
my $saveMarkedPdf    = $opt{p};
my $outputStatistics = $opt{s};

#Get the airport ID in case we can't guess it from PDF (KSSC is an example)
my $airportId = $opt{a};

#Get the target PDF file from command line options
my ($targetPdf) = $ARGV[0];

my $retval;

if ($airportId) {
    say "Supplied airport ID: $airportId";
}

#Our input PDF
say $targetPdf;

#Pull out the various filename components of the input file
my ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

#Set some output file names based on the input filename
my $outputPdf        = $dir . "marked-" . $filename . ".pdf";
my $targetpng        = $dir . $filename . ".png";
my $targettif        = $dir . $filename . ".tif";
my $targetvrt        = $dir . $filename . ".vrt";
my $targetStatistics = "./statistics.csv";

# #Non-zero if we only want to use GPS waypoints for GCPs on this plate
# my $rnavPlate = 0;

#Check that the source is a PDF (or at least has that extension)
if ( !$ext =~ m/^\.pdf$/ix ) {

    #Check that suffix is PDF for input file
    say "Source file needs to be a PDF";
    exit(1);
}

# #Try using only GPS fixes on RNAV plates
# if ( $filename =~ m/^\d+R/ ) {
# say "Input is a GPS plate, using only GPS waypoints for references";
# $rnavPlate = 1;
# }
if ($debug) {
    say "Directory: " . $dir;
    say "File:      " . $filename;
    say "Suffix:    " . $ext;
    say "";
    say "OutputPdf: $outputPdf";
    say "TargetPng: $targetpng";
    say "TargetTif: $targettif";
    say "TargetVrt: $targetvrt";
    say "targetStatistics: $targetStatistics";
    say "";
}

# #This is a quick hack to abort if we've already created a .vrt for this plate
# if (-e $targetvrt){
# say "$targetvrt exists, exiting";
# exit(1)};

#Pull all text out of the PDF
my @pdftotext;
@pdftotext = qx(pdftotext $targetPdf  -enc ASCII7 -);
$retval    = $? >> 8;

if ( @pdftotext eq "" || $retval != 0 ) {
    say "No output from pdftotext.  Is it installed?  Return code was $retval";
    exit(1);
}

if ( scalar(@pdftotext) < 5 ) {
    say "Not enough pdftotext output, probably a miltary plate";
    exit(1);
}

#Abort if the chart says it's not to scale
foreach my $line (@pdftotext) {
    $line =~ s/\s//gx;
    if ( $line =~ m/chartnott/i ) {
        say "Chart not to scale, can't georeference";
        exit(1);
    }

}

#-----------------------------------------------
#Open the database
my ( $dbh, $sth );
$dbh = DBI->connect(
    "dbi:SQLite:dbname=locationinfo.db",
    "", "", { RaiseError => 1 },
) or croak $DBI::errstr;

#Pull airport location from chart text or, if a name was supplied on command line, from database
my ( $airportLatitudeDec, $airportLongitudeDec ) =
  findAirportLatitudeAndLongitude();

#Get the mediabox size and other variables from the PDF
my ( $pdfXSize, $pdfYSize, $pdfCenterX, $pdfCenterY, $pdfXYRatio ) =
  getMediaboxSize();

#Convert the PDF to a PNG if one doesn't already exist
convertPdfToPng();

#Get PNG dimensions and the PDF->PNG scale factors
my ( $pngXSize, $pngYSize, $scaleFactorX, $scaleFactorY, $pngXYRatio ) =
  getPngSize();

#--------------------------------------------------------------------------------------------------------------
#Get number of objects/streams in the targetpdf
my $objectstreams = getNumberOfStreams();

# #Some regex building blocks to be used elsewhere
#numbers that start with 1-9 followed by 2 or more digits
my $obstacleHeightRegex = qr/[1-9]\d{2,}/x;

#A number with possible decimal point and minus sign
my $numberRegex = qr/[-\.\d]+/x;

#A transform, capturing the X and Y
my ($transformCaptureXYRegex) =
  qr/q\s1\s0\s0\s1\s+($numberRegex)\s+($numberRegex)\s+cm/x;

#A transform, not capturing the X and Y
my ($transformNoCaptureXYRegex) =
  qr/q\s1\s0\s0\s1\s+$numberRegex\s+$numberRegex\s+cm/x;

#A bezier curve
my ($bezierCurveRegex) = qr/(?:$numberRegex\s+){6}c/x;

#A line or path
my ($lineRegex) = qr/$numberRegex\s+$numberRegex\s+l/x;

# my $bezierCurveRegex = qr/(?:$numberRegex\s){6}c/;
# my $lineRegex        = qr/$numberRegex\s$numberRegex\sl/;

#Move to the origin
my ($originRegex) = qr/0\s+0\s+m/x;

#F*  Fill path
#S     Stroke path
#cm Scale and translate coordinate space
#c      Bezier curve
#q     Save graphics state
#Q     Restore graphics state

#Global variables filled in by the "findAllIcons" subroutine.  At some point I'll convert the subroutines to work with local variables and return values instead
my %icons = ();

my %obstacleIcons = ();
my $obstacleCount = 0;

my %fixIcons = ();
my $fixCount = 0;

my %gpsWaypointIcons = ();
my $gpsCount         = 0;

my %navaidIcons = ();
my $navaidCount = 0;

my %finalApproachFixIcons = ();
my $finalApproachFixCount = 0;

my %visualDescentPointIcons = ();
my $visualDescentPointCount = 0;

my %horizontalAndVerticalLines      = ();
my $horizontalAndVerticalLinesCount = 0;

my %insetBoxes      = ();
my $insetBoxesCount = 0;

my %insetCircles      = ();
my $insetCirclesCount = 0;

#Loop through each of the streams in the PDF and find all of the icons we're interested in
findAllIcons();

my @pdfToTextBbox     = ();
my %fixTextboxes      = ();
my %obstacleTextBoxes = ();
my %vorTextboxes      = ();
findAllTextboxes();

#----------------------------------------------------------------------------------------------------------
#Modify the PDF
#Don't do anything PDF related unless we've asked to create one on the command line

my ( $pdf, $page );
$pdf = PDF::API2->open($targetPdf) if $saveMarkedPdf;

#Set up the various types of boxes to draw on the output PDF
$page = $pdf->openpage(1) if $saveMarkedPdf;

#Draw boxes around the icons and textboxes we've found so far
outlineEverythingWeFound() if $saveMarkedPdf;

#----------------------------------------------------------------------------------------------------------------------------------
#Everything to do with obstacles
#
#Get a list of potential obstacle heights from the pdftotext array
my @obstacle_heights = findObstacleHeightTexts(@pdftotext);

#Remove any duplicates
onlyuniq(@obstacle_heights);

#Find all obstacles within our defined distance from the airport that have a height in the list of potential obstacleTextBoxes and are unique
# A bounding box of +/- degrees of longitude and latitude (~15 miles) from airport to limit our search for objects  to
my $radius                   = ".35";
my %unique_obstacles_from_db = ();
my $unique_obstacles_from_dbCount;
findObstaclesInDatabase( \%unique_obstacles_from_db );

#Try to find closest obstacleTextBox center to each obstacleIcon center
#and then do the reverse
findClosestBToA( \%obstacleIcons,     \%obstacleTextBoxes );
findClosestBToA( \%obstacleTextBoxes, \%obstacleIcons, );

#Make sure there is a bi-directional match between icon and textbox
#Returns a reference to a hash which combines info from icon, textbox and database
my $matchedObstacleIconsToTextBoxes =
  matchBToA( \%obstacleIcons, \%obstacleTextBoxes, \%unique_obstacles_from_db );

if ($debug) {
    say "matchedObstacleIconsToTextBoxes";
    print Dumper ($matchedObstacleIconsToTextBoxes);
}

#findClosestObstacleTextBoxToObstacleIcon();

#Draw a line from obstacle icon to closest text boxes
#drawLineFromEachObstacleToClosestTextBox() if $saveMarkedPdf;
drawLineFromEachIconToMatchedTextBox( \%obstacleIcons, \%obstacleTextBoxes )
  if $saveMarkedPdf;

#Find a obstacle icon with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates of its closest height text box to unique_obstacles_from_db hash
#Updates %unique_obstacles_from_db
#matchObstacleIconToUniqueObstaclesFromDb();

outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb()
  if $saveMarkedPdf;

#Link the obstacles from the database lookup to the icons and the textboxes
#matchDatabaseResultsToIcons();

#removeUniqueObstaclesFromDbThatAreNotMatchedToIcons();

#removeUniqueObstaclesFromDbThatShareIcons();

# #If we have more than 2 obstacles that have only 1 potentialTextBoxes then remove all that have potentialTextBoxes > 1
# my $countOfObstaclesWithOnePotentialTextbox =
# countObstacleIconsWithOnePotentialTextbox();

# if ( $countOfObstaclesWithOnePotentialTextbox > 2 ) {

# #say "Gleefully deleting objects that have more than one potentialTextBoxes";

# # foreach my $key ( sort keys %unique_obstacles_from_db ) {
# # if  (!($unique_obstacles_from_db{$key}{"potentialTextBoxes"} == 1))
# # {
# # delete $unique_obstacles_from_db{$key};
# # }
# #}
# }

if ($debug) {
    say
      "Unique obstacles from database lookup that match with textboxes in PDF";
    print Dumper ( \%unique_obstacles_from_db );
    say "";
}

#------------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with fixes
#
#Find fixes near the airport
#Updates %fixes_from_db
my %fixes_from_db = ();
findFixesNearAirport();

#Orange outline fixTextboxes that have a valid fix name in them
outlineValidFixTextBoxes() if $saveMarkedPdf;

#Try to find closest fixtextbox to each fix icon
#Updates %fixIcons
#findClosestFixTextBoxToFixIcon();

#Try to find closest TextBox center to each Icon center
#and then do the reverse
findClosestBToA( \%fixIcons,     \%fixTextboxes );
findClosestBToA( \%fixTextboxes, \%fixIcons, );

#Make sure there is a bi-directional match between icon and textbox
#Returns a reference to a hash of matched pairs
my $matchedFixIconsToTextBoxes =
  matchBToA( \%fixIcons, \%fixTextboxes, \%fixes_from_db );

#matchIconToDatabase(\%fixIcons, \%fixTextboxes, \%fixes_from_db);

#fixes_from_db should now only have fixes that are mentioned on the PDF
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

#remove entries that have no name, eg they weren't matched to a text box
#updates %fixIcons
#deleteFixIconsWithNoName();

#Remove duplicate fixes, preferring the one closest to the Y center of the PDF
#deleteDuplicateFixes();

#Indicate which textbox we matched to
drawLineFromEachIconToMatchedTextBox( \%fixIcons, \%fixTextboxes )
  if $saveMarkedPdf;

# drawLineFromEachFixToClosestTextBox() if $saveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with GPS waypoints
#
#Find GPS waypoints near the airport
my %gpswaypoints_from_db = ();
findGpsWaypointsNearAirport();

#Orange outline fixTextboxes that have a valid GPS waypoint name in them
outlineValidGpsWaypointTextBoxes() if $saveMarkedPdf;

#Try to find closest fixtextbox to each fix icon
#Updates %fixIcons
#findClosestFixTextBoxToFixIcon();

#Try to find closest TextBox center to each Icon center
#and then do the reverse
findClosestBToA( \%gpsWaypointIcons, \%fixTextboxes );
findClosestBToA( \%fixTextboxes,     \%gpsWaypointIcons );

# #Pair up each waypoint to it's closest textbox
#gpswaypoints_from_db should now only have fixes that are mentioned on the PDF
# matchClosestFixTextBoxToEachGpsWaypointIcon();

my $matchedGpsWaypointIconsToTextBoxes =
  matchBToA( \%gpsWaypointIcons, \%fixTextboxes, \%gpswaypoints_from_db );

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

#remove entries that have no name, eg they weren't matched to a text box
# deleteGpsWaypointsWithNoName();

#Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
#deleteDuplicateGpsWaypoints();

#Draw a line from GPS waypoint icon to closest text box
#drawLineFromEachGpsWaypointToMatchedTextbox() if $saveMarkedPdf;
drawLineFromEachIconToMatchedTextBox( \%gpsWaypointIcons, \%fixTextboxes )
  if $saveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with navaids
#
#Find navaids near the airport
my %navaids_from_db = ();
findNavaidsNearAirport();

#Orange outline navaid textboxes that have a valid navaid name in them
outlineValidNavaidTextBoxes() if $saveMarkedPdf;

#Pair up each waypoint to it's closest textbox
#matchClosestNavaidTextBoxToNavaidIcon();

#Try to find closest TextBox center to each Icon center
#and then do the reverse
findClosestBToA( \%navaidIcons,  \%vorTextboxes );
findClosestBToA( \%vorTextboxes, \%navaidIcons );

# #Pair up each waypoint to it's closest textbox
#gpswaypoints_from_db should now only have fixes that are mentioned on the PDF
# matchClosestFixTextBoxToEachGpsWaypointIcon();

my $matchedNavaidIconsToTextBoxes =
  matchBToA( \%navaidIcons, \%vorTextboxes, \%navaids_from_db );

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

#deleteNavaidsWithNoName();

#Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
#deleteDuplicateNavaids();

#Draw a line from icon to closest text box
#drawLineFromNavaidToMatchedTextbox() if $saveMarkedPdf;
drawLineFromEachIconToMatchedTextBox( \%navaidIcons, \%vorTextboxes )
  if $saveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Create the combined hash of Ground Control Points
my %gcps = ();

#Add Obstacles to Ground Control Points hash
# addObstaclesToGroundControlPoints();
addCombinedHashToGroundControlPoints( "obstacle",
    $matchedObstacleIconsToTextBoxes );

#Add Fixes to Ground Control Points hash
# addFixesToGroundControlPoints();
addCombinedHashToGroundControlPoints( "fix", $matchedFixIconsToTextBoxes );

#Add Navaids to Ground Control Points hash
# addNavaidsToGroundControlPoints();
addCombinedHashToGroundControlPoints( "navaid",
    $matchedNavaidIconsToTextBoxes );

#Add GPS waypoints to Ground Control Points hash
# addGpsWaypointsToGroundControlPoints();
addCombinedHashToGroundControlPoints( "gps",
    $matchedGpsWaypointIconsToTextBoxes );

if ($debug) {
    say "";
    say "Combined Ground Control Points";
    print Dumper ( \%gcps );
    say "";
}

#build the GCP portion of the command line parameters
my $gcpstring = createGcpString();

#Make sure we have enough GCPs
my $gcpCount = scalar( keys(%gcps) );
say "Found $gcpCount potential Ground Control Points" if $debug;

#Can't do anything if we didn't find any valid ground control points
if ( $gcpCount < 1 ) {
    say "Didn't find any ground control points in $targetPdf";
    if ($saveMarkedPdf) {
        $pdf->saveas($outputPdf);
    }
    exit(1);
}

#Remove GCPs which are inside insetBoxes or outside the horizontal bounds
deleteBadGCPs();

#outline the GCP points we ended up using
drawCircleAroundGCPs() if $saveMarkedPdf;

# if ($saveMarkedPdf) {
# $pdf->saveas($outputPdf);
# }

#----------------------------------------------------------------------------------------------------------------------------------------------------
#Now some math
my ( @xScaleAvg, @yScaleAvg, @ulXAvg, @ulYAvg, @lrXAvg, @lrYAvg ) = ();

#Print a header so you could paste the following output into a spreadsheet to analyze
say
  '$object1,$object2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2'
  if $debug;

#Calculate the rough X and Y scale values
if ( $gcpCount == 1 ) {
    calculateRoughRealWorldExtentsOfRasterWithOneGCP();
}
else {
    calculateRoughRealWorldExtentsOfRaster();
}

my ( $xAvg,    $xMedian,   $xStdDev )   = 0;
my ( $yAvg,    $yMedian,   $yStdDev )   = 0;
my ( $ulXAvrg, $ulXmedian, $ulXStdDev ) = 0;
my ( $ulYAvrg, $ulYmedian, $ulYStdDev ) = 0;
my ( $lrXAvrg, $lrXmedian, $lrXStdDev ) = 0;
my ( $lrYAvrg, $lrYmedian, $lrYStdDev ) = 0;
my ($lonLatRatio) = 0;

# if ($debug) {
# say "";
# say "Ground Control Points showing mismatches";
# print Dumper ( \%gcps );
# say "";
# }

#Smooth out the X and Y scales we previously calculated
calculateSmoothedRealWorldExtentsOfRaster();

#Actually produce the georeferencing data via GDAL
georeferenceTheRaster();

#Write out the statistics of this file if requested
writeStatistics() if $outputStatistics;

#Since we've calculated our extents, try drawing some features on the outputPdf to see if they align
#With our work
drawFeaturesOnPdf() if $saveMarkedPdf;

#Save our new PDF since we're done with it
if ($saveMarkedPdf) {
    $pdf->saveas($outputPdf);
}

#Close the database
$sth->finish();
$dbh->disconnect();

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------
sub drawFeaturesOnPdf {
    return;
}

sub findObstacleHeightTexts {

    #The text from the PDF
    my @_pdftotext = @_;
    my @_obstacle_heights;

    foreach my $line (@_pdftotext) {

        #Find numbers that match our obstacle height regex

        #if ( $line =~ m/^([1-9][\d]{1,}[1-9])$/ ) {
        if ( $line =~ m/^($obstacleHeightRegex)$/ ) {

            #Any height over 30000 is obviously bogus
            next if $1 > 30000;
            push @_obstacle_heights, $1;
        }

    }

    if ($debug) {
        say "Potential obstacle heights from PDF";
        print join( " ", @_obstacle_heights ), "\n";

        #Remove all entries that aren't unique
        @obstacle_heights = onlyuniq(@obstacle_heights);
        say "Unique potential obstacle heights from PDF";
        print join( " ", @_obstacle_heights ), "\n";
    }
    return @_obstacle_heights;
}

sub findAirportLatitudeAndLongitude {

    #Get the lat/lon of the airport for the plate we're working on

    my $_airportLatitudeDec  = "";
    my $_airportLongitudeDec = "";

    foreach my $line (@pdftotext) {

        #Remove all the whitespace
        $line =~ s/\s//g;

        # if ( $line =~ m/(\d+)'([NS])\s?-\s?(\d+)'([EW])/ ) {
        #   if ( $line =~ m/([\d ]+)'([NS])\s?-\s?([\d ]+)'([EW])/ ) {
        if ( $line =~ m/([\d ]{3,4}).?([NS])-([\d ]{3,5}).?([EW])/ ) {
            my (
                $aptlat,    $aptlon,    $aptlatd,   $aptlond,
                $aptlatdeg, $aptlatmin, $aptlondeg, $aptlonmin
            );
            $aptlat  = $1;
            $aptlatd = $2;
            $aptlon  = $3;
            $aptlond = $4;

            $aptlatdeg = substr( $aptlat, 0,  -2 );
            $aptlatmin = substr( $aptlat, -2, 2 );

            $aptlondeg = substr( $aptlon, 0,  -2 );
            $aptlonmin = substr( $aptlon, -2, 2 );

            $_airportLatitudeDec =
              &coordinatetodecimal(
                $aptlatdeg . "-" . $aptlatmin . "-00" . $aptlatd );

            $_airportLongitudeDec =
              &coordinatetodecimal(
                $aptlondeg . "-" . $aptlonmin . "-00" . $aptlond );

            say
              "Airport LAT/LON from plate: $aptlatdeg-$aptlatmin-$aptlatd, $aptlondeg-$aptlonmin-$aptlond->$_airportLatitudeDec $_airportLongitudeDec"
              if $debug;
            return ( $_airportLatitudeDec, $_airportLongitudeDec );
        }

    }

    if ( $_airportLongitudeDec eq "" or $_airportLatitudeDec eq "" ) {

        #We didn't get any airport info from the PDF, let's check the database
        #Get airport from database
        if ( !$airportId ) {
            say
              "You must specify an airport ID (eg. -a SMF) since there was no info on the PDF";
            exit(1);
        }

        #Query the database for airport
        $sth = $dbh->prepare(
            "SELECT  FaaID, Latitude, Longitude, Name  FROM airports  WHERE  FaaID = '$airportId'"
        );
        $sth->execute();
        my $_allSqlQueryResults = $sth->fetchall_arrayref();

        foreach my $row (@$_allSqlQueryResults) {
            my ( $airportFaaId, $airportname );
            (
                $airportFaaId, $_airportLatitudeDec, $_airportLongitudeDec,
                $airportname
            ) = @$row;
            say "Airport ID: $airportFaaId";
            say "Airport Latitude: $_airportLatitudeDec";
            say "Airport Longitude: $_airportLongitudeDec";
            say "Airport Name: $airportname";
        }
        if ( $_airportLongitudeDec eq "" or $_airportLatitudeDec eq "" ) {
            say
              "No airport coordinate information on PDF or database, try   -a <airport> ";
            exit(1);
        }

    }
}

sub getMediaboxSize {

    #Get the mediabox size from the PDF
    my $mutoolinfo = qx(mutool info $targetPdf);
    $retval = $? >> 8;
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

    #Find the dimensions of the PNG
    my $fileoutput = qx(file $targetpng );
    my $_retval    = $? >> 8;
    die "No output from file.  Is it installed? Return code was $_retval"
      if ( $fileoutput eq "" || $_retval != 0 );

    foreach my $line ( split /[\r\n]+/, $fileoutput ) {
        ## Regular expression magic to grab what you want
        if ( $line =~ /([-\.0-9]+)\s+x\s+([-\.0-9]+)/ ) {
            $pngXSize = $1;
            $pngYSize = $2;
        }
    }

    #Calculate the ratios of the PNG/PDF coordinates
    my $_scaleFactorX = $pngXSize / $pdfXSize;
    my $_scaleFactorY = $pngYSize / $pdfYSize;
    my $_pngXYRatio   = $pngXSize / $pngYSize;

    if ($debug) {
        say "PNG size: " . $pngXSize . "x" . $pngYSize;
        say "Scalefactor PDF->PNG X:  " . $_scaleFactorX;
        say "Scalefactor PDF->PNG Y:  " . $_scaleFactorY;
        say "PNG X/Y Ratio:  " . $_pngXYRatio;
    }
    return ( $pngXSize, $pngYSize, $_scaleFactorX, $_scaleFactorY,
        $_pngXYRatio );

}

sub getNumberOfStreams {

    #Get number of objects/streams in the targetpdf

    my $_mutoolShowOutput = qx(mutool show $targetPdf x);
    $retval = $? >> 8;
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
            Bold => $pdf->corefont( 'Helvetica-Bold', -encoding => 'latin1' ),

            #      Roman  => $pdf->corefont('Helvetica',         -encoding => 'latin1'),
            #      Italic => $pdf->corefont('Helvetica-Oblique', -encoding => 'latin1'),
        },
        Times => {

            #      Bold   => $pdf->corefont('Times-Bold',        -encoding => 'latin1'),
            Roman => $pdf->corefont( 'Times', -encoding => 'latin1' ),

            #      Italic => $pdf->corefont('Times-Italic',      -encoding => 'latin1'),
        },
    );

    foreach my $key ( sort keys %horizontalAndVerticalLines ) {

        my ($lines) = $page->gfx;
        $lines->move(
            $horizontalAndVerticalLines{$key}{"X"},
            $horizontalAndVerticalLines{$key}{"Y"}
        );
        $lines->line(
            $horizontalAndVerticalLines{$key}{"X2"},
            $horizontalAndVerticalLines{$key}{"Y2"}
        );

        $lines->strokecolor('yellow');
        $lines->linewidth(5);
        $lines->stroke;
    }
    foreach my $key ( sort keys %insetBoxes ) {

        my ($insetBox) = $page->gfx;
        $insetBox->rect(
            $insetBoxes{$key}{X},
            $insetBoxes{$key}{Y},
            $insetBoxes{$key}{Width},
            $insetBoxes{$key}{Height},

        );
        $insetBox->strokecolor('cyan');
        $insetBox->linewidth(.1);
        $insetBox->stroke;

        #Uncomment this to show the radius we're looking in for icon->text matches
        # $insetBox->circle(
        # $obstacleIcons{$key}{X},
        # $obstacleIcons{$key}{Y},
        # $maxDistanceFromObstacleIconToTextBox
        # );
        # $insetBox->strokecolor('red');
        # $insetBox->linewidth(.05);
        # $insetBox->stroke;

    }

    foreach my $key ( sort keys %insetCircles ) {

        my ($insetCircle) = $page->gfx;
        $insetCircle->circle(
            $insetCircles{$key}{X},
            $insetCircles{$key}{Y},
            $insetCircles{$key}{Radius},
        );
        $insetCircle->strokecolor('cyan');
        $insetCircle->linewidth(.1);
        $insetCircle->stroke;
    }
    foreach my $key ( sort keys %obstacleIcons ) {

        my ($obstacle_box) = $page->gfx;
        $obstacle_box->rect(
            $obstacleIcons{$key}{"CenterX"} -
              ( $obstacleIcons{$key}{"Width"} / 2 ),
            $obstacleIcons{$key}{"CenterY"} -
              ( $obstacleIcons{$key}{"Height"} / 2 ),
            $obstacleIcons{$key}{"Width"},
            $obstacleIcons{$key}{"Height"}
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

    foreach my $key ( sort keys %fixIcons ) {
        my ($fix_box) = $page->gfx;
        $fix_box->rect(
            $fixIcons{$key}{"CenterX"} - ( $fixIcons{$key}{"Width"} / 2 ),
            $fixIcons{$key}{"CenterY"} - ( $fixIcons{$key}{"Height"} / 2 ),
            $fixIcons{$key}{"Width"},
            $fixIcons{$key}{"Height"}
        );
        $fix_box->strokecolor('red');
        $fix_box->linewidth(.1);
        $fix_box->stroke;
    }
    foreach my $key ( sort keys %fixTextboxes ) {
        my ($fixTextBox) = $page->gfx;
        $fixTextBox->rect(
            $fixTextboxes{$key}{"CenterX"} -
              ( $fixTextboxes{$key}{"Width"} / 2 ),
            $fixTextboxes{$key}{"CenterY"} -
              ( $fixTextboxes{$key}{"Height"} / 2 ),
            ,
            $fixTextboxes{$key}{"Width"},
            $fixTextboxes{$key}{"Height"}
        );
        $fixTextBox->strokecolor('red');
        $fixTextBox->linewidth(.1);
        $fixTextBox->stroke;
    }
    foreach my $key ( sort keys %gpsWaypointIcons ) {
        my ($gpsWaypointBox) = $page->gfx;
        $gpsWaypointBox->rect(
            $gpsWaypointIcons{$key}{"CenterX"} -
              ( $gpsWaypointIcons{$key}{"Width"} / 2 ),
            $gpsWaypointIcons{$key}{"CenterY"} -
              ( $gpsWaypointIcons{$key}{"Height"} / 2 ),
            $gpsWaypointIcons{$key}{"Height"},
            $gpsWaypointIcons{$key}{"Width"}
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

    foreach my $key ( sort keys %navaidIcons ) {
        my ($navaidBox) = $page->gfx;
        $navaidBox->rect(
            $navaidIcons{$key}{"CenterX"} - ( $navaidIcons{$key}{"Width"} / 2 ),
            $navaidIcons{$key}{"CenterY"} -
              ( $navaidIcons{$key}{"Height"} / 2 ),
            $navaidIcons{$key}{"Width"},
            $navaidIcons{$key}{"Height"}
        );
        $navaidBox->strokecolor('red');
        $navaidBox->linewidth(.1);
        $navaidBox->stroke;
    }
    foreach my $key ( sort keys %vorTextboxes ) {
        my ($navaidTextBox) = $page->gfx;
        $navaidTextBox->rect(
            $vorTextboxes{$key}{"CenterX"} -
              ( $vorTextboxes{$key}{"Width"} / 2 ),
            $vorTextboxes{$key}{"CenterY"} -
              ( $vorTextboxes{$key}{"Height"} / 2 ),
            $vorTextboxes{$key}{"Width"},
            -( $vorTextboxes{$key}{"Height"} )
        );
        $navaidTextBox->strokecolor('red');
        $navaidTextBox->linewidth(1);
        $navaidTextBox->stroke;
    }
    return;
}

# sub drawLineFromEachObstacleToClosestTextBox {

# #Draw a line from obstacle icon to closest text boxes
# my $_obstacle_line = $page->gfx;

# foreach my $key ( sort keys %obstacleIcons ) {
# my $matchedKey = $obstacleIcons{$key}{"MatchedTo"};

# #Don't draw if we don't have a match
# next unless $matchedKey;

# $_obstacle_line->move( $obstacleIcons{$key}{"CenterX"},
# $obstacleIcons{$key}{"CenterY"} );
# $_obstacle_line->line(
# $obstacleTextBoxes{$matchedKey}{"CenterX"},
# $obstacleTextBoxes{$matchedKey}{"CenterY"}
# );
# $_obstacle_line->linewidth(1);
# $_obstacle_line->strokecolor('blue');
# $_obstacle_line->stroke;
# }
# return;
# }

sub calculateXScale {
    $xAvg    = &average( \@xScaleAvg );
    $xMedian = &median( \@xScaleAvg );
    $xStdDev = &stdev( \@xScaleAvg );

    if ($debug) {
        say "";
        say "X-scale: average:  $xAvg\tstdev: $xStdDev\tmedian: $xMedian";
        say "Removing data outside 1st standard deviation";
    }

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#xScaleAvg ; $i++ ) {
        splice( @xScaleAvg, $i, 1 )
          if ( $xScaleAvg[$i] < ( $xAvg - $xStdDev )
            || $xScaleAvg[$i] > ( $xAvg + $xStdDev ) );
    }
    $xAvg    = &average( \@xScaleAvg );
    $xMedian = &median( \@xScaleAvg );
    $xStdDev = &stdev( \@xScaleAvg );
    say "X-scale: average:  $xAvg\tstdev: $xStdDev\tmedian: $xMedian"
      if $debug;
    return;
}

sub calculateYScale {
    $yAvg    = &average( \@yScaleAvg );
    $yMedian = &median( \@yScaleAvg );
    $yStdDev = &stdev( \@yScaleAvg );

    if ($debug) {
        say "Y-scale: average:  $yAvg\tstdev: $yStdDev\tmedian: $yMedian";
        say "Remove data outside 1st standard deviation";
    }

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#yScaleAvg ; $i++ ) {
        splice( @yScaleAvg, $i, 1 )
          if ( $yScaleAvg[$i] < ( $yAvg - $yStdDev )
            || $yScaleAvg[$i] > ( $yAvg + $yStdDev ) );
    }
    $yAvg    = &average( \@yScaleAvg );
    $yMedian = &median( \@yScaleAvg );
    $yStdDev = &stdev( \@yScaleAvg );
    say "Y-scale: average:  $yAvg\tstdev: $yStdDev\tmedian: $yMedian"
      if $debug;

    return;
}

sub calculateULX {
    $ulXAvrg   = &average( \@ulXAvg );
    $ulXmedian = &median( \@ulXAvg );
    $ulXStdDev = &stdev( \@ulXAvg );
    say
      "Upper Left X: average:  $ulXAvrg\tstdev: $ulXStdDev\tmedian: $ulXmedian"
      if $debug;

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#ulXAvg ; $i++ ) {
        splice( @ulXAvg, $i, 1 )
          if ( $ulXAvg[$i] < ( $ulXAvrg - $ulXStdDev )
            || $ulXAvg[$i] > ( $ulXAvrg + $ulXStdDev ) );
    }
    $ulXAvrg   = &average( \@ulXAvg );
    $ulXmedian = &median( \@ulXAvg );
    $ulXStdDev = &stdev( \@ulXAvg );
    if ($debug) {
        say "Remove data outside 1st standard deviation";
        say
          "Upper Left X: average:  $ulXAvrg\tstdev: $ulXStdDev\tmedian: $ulXmedian";

    }
    return;
}

sub calculateULY {
    $ulYAvrg   = &average( \@ulYAvg );
    $ulYmedian = &median( \@ulYAvg );
    $ulYStdDev = &stdev( \@ulYAvg );

    say
      "Upper Left Y: average:  $ulYAvrg\tstdev: $ulYStdDev\tmedian: $ulYmedian"
      if $debug;

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#ulYAvg ; $i++ ) {
        splice( @ulYAvg, $i, 1 )
          if ( $ulYAvg[$i] < ( $ulYAvrg - $ulYStdDev )
            || $ulYAvg[$i] > ( $ulYAvrg + $ulYStdDev ) );
    }
    $ulYAvrg   = &average( \@ulYAvg );
    $ulYmedian = &median( \@ulYAvg );
    $ulYStdDev = &stdev( \@ulYAvg );
    if ($debug) {
        say "Remove data outside 1st standard deviation";
        say
          "Upper Left Y: average:  $ulYAvrg\tstdev: $ulYStdDev\tmedian: $ulYmedian";
    }
    return;
}

sub calculateLRX {
    $lrXAvrg   = &average( \@lrXAvg );
    $lrXmedian = &median( \@lrXAvg );
    $lrXStdDev = &stdev( \@lrXAvg );
    say
      "Lower Right X: average:  $lrXAvrg\tstdev: $lrXStdDev\tmedian: $lrXmedian"
      if $debug;

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#lrXAvg ; $i++ ) {
        splice( @lrXAvg, $i, 1 )
          if ( $lrXAvg[$i] < ( $lrXAvrg - $lrXStdDev )
            || $lrXAvg[$i] > ( $lrXAvrg + $lrXStdDev ) );
    }
    $lrXAvrg   = &average( \@lrXAvg );
    $lrXmedian = &median( \@lrXAvg );
    $lrXStdDev = &stdev( \@lrXAvg );
    say
      "Lower Right X: average:  $lrXAvrg\tstdev: $lrXStdDev\tmedian: $lrXmedian"
      if $debug;
    return;
}

sub calculateLRY {
    $lrYAvrg   = &average( \@lrYAvg );
    $lrYmedian = &median( \@lrYAvg );
    $lrYStdDev = &stdev( \@lrYAvg );
    say
      "Lower Right Y: average:  $lrYAvrg\tstdev: $lrYStdDev\tmedian: $lrYmedian"
      if $debug;

    #Delete values from the array that are outside 1st dev
    for ( my $i = 0 ; $i <= $#lrYAvg ; $i++ ) {
        splice( @lrYAvg, $i, 1 )
          if ( $lrYAvg[$i] < ( $lrYAvrg - $lrYStdDev )
            || $lrYAvg[$i] > ( $lrYAvrg + $lrYStdDev ) );
    }
    $lrYAvrg   = &average( \@lrYAvg );
    $lrYmedian = &median( \@lrYAvg );
    say
      "Lower Right Y after deleting outside 1st dev: average: $lrYAvrg\tmedian: $lrYmedian"
      if $debug;
    say "" if $debug;
    return;
}

sub findAllIcons {
    say ":findAllIcons" if $debug;
    my ($_output);

    #Loop through each "stream" in the pdf looking for our various icon regexes
    for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
        $_output = qx(mutool show $targetPdf $i x);
        $retval  = $? >> 8;
        die
          "No output from mutool show.  Is it installed? Return code was $retval"
          if ( $_output eq "" || $retval != 0 );

        print "Stream $i: " if $debug;

        # findIlsIcons( \%icons, $_output );
        findObstacleIcons($_output);
        findFixIcons($_output);
        findGpsWaypointIcons($_output);
        findNavaidIcons($_output);

        #findFinalApproachFixIcons($_output);
        #findVisualDescentPointIcons($_output);
        findHorizontalLines($_output);
        findInsetBoxes($_output);
        findInsetCircles($_output);

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
    # }

    return;
}

# sub findClosestObstacleTextBoxToObstacleIcon {

    # #Find the closest obstacle textbox to each obstacle icon
    # say "findClosestObstacleTextBoxToObstacleIcon" if $debug;
    # foreach my $key ( sort keys %obstacleIcons ) {

        # #Start with a very high number so initially is closer than it
        # my $distance_to_closest_obstacletextbox = 999999999999;

        # foreach my $key2 ( keys %obstacleTextBoxes ) {
            # my $distanceToObstacletextboxX;
            # my $distanceToObstacletextboxY;

            # $distanceToObstacletextboxX =
              # $obstacleTextBoxes{$key2}{"CenterX"} -
              # $obstacleIcons{$key}{CenterX};
            # $distanceToObstacletextboxY =
              # $obstacleTextBoxes{$key2}{"CenterY"} - $obstacleIcons{$key}{"Y"};

            # my $hypotenuse = sqrt( $distanceToObstacletextboxX**2 +
                  # $distanceToObstacletextboxY**2 );

            # #Ignore this textbox if it's further away than our max distance variables
            # next
              # if ( !( $hypotenuse < $maxDistanceFromObstacleIconToTextBox ) );

            # #Count the number of potential textbox matches.  If this is > 1 then we should consider this matchup to be less reliable
            # $obstacleIcons{$key}{"potentialTextBoxes"} =
              # $obstacleIcons{$key}{"potentialTextBoxes"} + 1;

            # #The 27 here was chosen to make one particular sample work, it's not universally valid
            # #Need to improve the icon -> textbox mapping
            # #say "Hypotenuse: $hyp" if $debug;
            # if ( ( $hypotenuse < $distance_to_closest_obstacletextbox ) ) {

                # #Update the distance to the closest obstacleTextBox center
                # $distance_to_closest_obstacletextbox = $hypotenuse;

                # #Set the "name" of this obstacleIcon to the text from obstacleTextBox
                # #This is where we kind of guess (and can go wrong) since the closest height text is often not what should be associated with the icon

                # $obstacleIcons{$key}{"Name"} =
                  # $obstacleTextBoxes{$key2}{"Text"};

                # $obstacleIcons{$key}{"TextBoxX"} =
                  # $obstacleTextBoxes{$key2}{"CenterX"};

                # $obstacleIcons{$key}{"TextBoxY"} =
                  # $obstacleTextBoxes{$key2}{"CenterY"};

                # # $obstacleTextBoxes{$key2}{"IconsThatPointToMe"} =
                # # $obstacleTextBoxes{$key2}{"IconsThatPointToMe"} + 1;
            # }

        # }

        # #$obstacleIcons{$key}{"ObstacleTextBoxesThatPointToMe"} =
        # # $obstacleIcons{$key}{"ObstacleTextBoxesThatPointToMe"} + 1;
    # }
    # if ($debug) {
        # say "obstacleIcons";
        # print Dumper ( \%obstacleIcons );
        # say "";
        # say "obstacleTextBoxes";
        # print Dumper ( \%obstacleTextBoxes );
    # }

    # return;
# }

sub findClosestBToA {

    #Find the closest B icon to each A
   
    my ( $hashRefA, $hashRefB ) = @_;

    #Maximum distance in points between centers
     my $maxDistance = 100;

    say "findClosest $hashRefB to each $hashRefA" if $debug;

    foreach my $key ( sort keys %$hashRefA ) {

        # say "$key";
        #Start with a very high number so initially is closer than it
        my $distanceToClosest = 999999999999;

        foreach my $key2 ( sort keys %$hashRefB ) {

            # say $key2;
            my $distanceToBX;
            my $distanceToBY;

            $distanceToBX =
              $hashRefB->{$key2}{"CenterX"} - $hashRefA->{$key}{"CenterX"};
            $distanceToBY =
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

sub findObstaclesInDatabase {

    #---------------------------------------------------------------------------------------------------------------------------------------------------
    #Find obstacles with a certain height in the database

    foreach my $heightmsl (@obstacle_heights) {

        #Query the database for obstacles of $heightmsl within our $radius
        $sth = $dbh->prepare(
            "SELECT * FROM obstacles WHERE (HeightMsl=$heightmsl) and 
                                       (Latitude >  $airportLatitudeDec - $radius ) and 
                                       (Latitude < $airportLatitudeDec +$radius ) and 
                                       (Longitude >  $airportLongitudeDec - $radius ) and 
                                       (Longitude < $airportLongitudeDec +$radius )"
        );
        $sth->execute();

        my $all  = $sth->fetchall_arrayref();
        my $rows = $sth->rows();
        say "Found $rows objects of height $heightmsl" if $debug;

        #Don't show results of searches that have more than one result, ie not unique
        next if ( $rows != 1 );

        foreach my $row (@$all) {

            #Populate variables from our database lookup
            my ( $lat, $lon, $heightmsl, $heightagl ) = @$row;
            foreach my $pdf_obstacle_height (@obstacle_heights) {
                if ( $pdf_obstacle_height == $heightmsl ) {
                    $unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
                    $unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
                }
            }
        }

    }

    #How many obstacles with unique heights did we find
    $unique_obstacles_from_dbCount = keys(%unique_obstacles_from_db);

    my $nmLatitude  = 60 * $radius;
    my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );
    if ($debug) {
        say
          "Found $unique_obstacles_from_dbCount OBSTACLES with unique heights within $radius degrees ($nmLongitude x $nmLatitude nm) of airport from database";
        say "unique_obstacles_from_db:";
        print Dumper ( \%unique_obstacles_from_db );
        say "";
    }
    return;
}

#--------------------------------------------------------------------------------------------------------------------------------------
sub findGpsWaypointIcons {
    my ($_output) = @_;

    #REGEX building blocks

    #my $transformCaptureXYRegex = qr/q 1 0 0 1 ($numberRegex) ($numberRegex)\s+cm/;

    #Find first half of gps waypoint icons
    #Usually this is the upper left half but I've seen at least one instance where it matches the upper right,
    #which throws off the determination of the center point (SSI GPS 22)
    my $gpswaypointregex = qr/^$transformCaptureXYRegex$
^0 0 m$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$lineRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$lineRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^0 0 l$
^f\*$
^Q$/m;

    my $gpswaypointregex2 = qr/^$transformCaptureXYRegex$
^0 0 m$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$lineRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$lineRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^0 0 l$
^f\*$
^Q$/m;

    #Found at least one example of the waypoint icon being drawn like this (2 extra curves)

    my @tempgpswaypoints        = $_output =~ /$gpswaypointregex/ig;
    my $tempgpswaypoints_length = 0 + @tempgpswaypoints;
    my $tempgpswaypoints_count  = $tempgpswaypoints_length / 2;

    if ( $tempgpswaypoints_length >= 2 ) {
        my $rand = rand();

        #say "Found $tempgpswaypoints_count GPS waypoints in stream $i";
        for ( my $i = 0 ; $i < $tempgpswaypoints_length ; $i = $i + 2 ) {
            my $height = 10;
            my $width  = 15;

            #put them into a hash
            # $gpsWaypointIcons{$i}{"X"} = $tempgpswaypoints[$i];
            # $gpsWaypointIcons{$i}{"Y"} = $tempgpswaypoints[ $i + 1 ];
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            $gpsWaypointIcons{ $i . $rand }{"CenterX"} =
              $tempgpswaypoints[$i] + $height / 2;
            $gpsWaypointIcons{ $i . $rand }{"CenterY"} =
              $tempgpswaypoints[ $i + 1 ];
            $gpsWaypointIcons{ $i . $rand }{"Width"}  = $width;
            $gpsWaypointIcons{ $i . $rand }{"Height"} = $height;
            $gpsWaypointIcons{ $i . $rand }{"GeoreferenceX"} =
              $tempgpswaypoints[$i] + $width / 2;
            $gpsWaypointIcons{ $i . $rand }{"GeoreferenceY"} =
              $tempgpswaypoints[ $i + 1 ];
            $gpsWaypointIcons{ $i . $rand }{"Type"} = "gps";

            # $gpsWaypointIcons{$i}{"Name"} = "none";
        }

    }

    $gpsCount = keys(%gpsWaypointIcons);
    if ($debug) {
        print "$tempgpswaypoints_count GPS ";

    }
    return;
}

#--------------------------------------------------------------------------------------------------------------------------------------
sub findNavaidIcons {

    #I'm going to lump finding all of the navaid icons into here for now
    #Before I clean it up
    my ($_output) = @_;

    #REGEX building blocks

    #Find VOR icons
    my $vortacRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^f\*$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^f\*$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^f\*$
^Q$/m;

    my @tempVortac = $_output =~ /$vortacRegex/ig;
    my $vortacDatapoints = 2;

    #say @tempVortac;

    # say $&;
    my $tempVortacLength = 0 + @tempVortac;
    my $tempVortacCount  = $tempVortacLength / $vortacDatapoints;

    if ( $tempVortacLength >= $vortacDatapoints ) {
        my $rand = rand();
        for ( my $i = 0 ; $i < $tempVortacLength ; $i = $i + $vortacDatapoints )
        {
            my $x      = $tempVortac[$i];
            my $y      = $tempVortac[ $i + 1 ];
            my $height = 10;
            my $width  = 10;

            #put them into a hash
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            # $navaidIcons{ $i . $rand }{"X"}              = $x;
            # $navaidIcons{ $i . $rand }{"Y"}              = $y;
            $navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x + 2;
            $navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y - 3;
            $navaidIcons{ $i . $rand }{"CenterX"}       = $x + 2;
            $navaidIcons{ $i . $rand }{"CenterY"}       = $y - 3;
            $navaidIcons{ $i . $rand }{"Width"}         = $width;
            $navaidIcons{ $i . $rand }{"Height"}        = $height;

            # $navaidIcons{ $i . $rand }{"Name"}           = "none";
            $navaidIcons{ $i . $rand }{"Type"} = "vortac";
        }

    }

    my $vorDmeRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
^$lineRegex$
^0\s+($numberRegex)\s+l$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^S$
^Q$/m;

    #Re-run for VORDME
    @tempVortac = $_output =~ /$vorDmeRegex/ig;
    my $vorDmeDatapoints = 4;

    # say @tempVortac;

    # say $&;
    $tempVortacLength = 0 + @tempVortac;
    $tempVortacCount  = $tempVortacLength / $vorDmeDatapoints;

    if ( $tempVortacLength >= $vorDmeDatapoints ) {
        my $rand = rand();
        for ( my $i = 0 ; $i < $tempVortacLength ; $i = $i + $vorDmeDatapoints )
        {
            my ($x) = $tempVortac[$i];
            my ($y) = $tempVortac[ $i + 1 ];

            my ($width)  = $tempVortac[ $i + 2 ];
            my ($height) = $tempVortac[ $i + 3 ];

            #TODO because it seems something else is matching this regex choose one with long lines
            next if ( abs( $width < 7 ) || abs( $height < 7 ) );

            #put them into a hash
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            # $navaidIcons{ $i . $rand }{"X"} = $x;
            # $navaidIcons{ $i . $rand }{"Y"} = $y;

            $navaidIcons{ $i . $rand }{"CenterX"}       = $x + $width / 2;
            $navaidIcons{ $i . $rand }{"CenterY"}       = $y + $height / 2;
            $navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x + $width / 2;
            $navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y + $height / 2;
            $navaidIcons{ $i . $rand }{"Width"}         = $width;
            $navaidIcons{ $i . $rand }{"Height"}        = $height;

            #$navaidIcons{ $i . $rand }{"Name"}           = "none";
            $navaidIcons{ $i . $rand }{"Type"} = "vordme";
        }

    }
    $navaidCount = keys(%navaidIcons);
    if ($debug) {
        print "$tempVortacCount NAVAID ";

        #print Dumper ( \%navaidIcons);
    }

    #-----------------------------------

    return;
}

sub findInsetBoxes {
    my ($_output) = @_;

    #REGEX building blocks
    #A series of 4 lines (iow: a box)
    my $insetBoxRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
^$numberRegex\s+$numberRegex\s+l$
^0\s+($numberRegex)\s+l$
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

            #Let's only save large, but not too large, boxes
            next
              if ( ( abs($width) < 50 )
                || ( abs($height) < 50 )
                || ( abs($height) > 500 )
                || ( abs($width) > 300 ) );

            #put them into a hash
            $insetBoxes{ $i . $random }{"X"} = $x;

            $insetBoxes{ $i . $random }{"Y"} = $y;

            $insetBoxes{ $i . $random }{"X2"} = $x + $width;

            $insetBoxes{ $i . $random }{"Y2"} = $y + $height;

            $insetBoxes{ $i . $random }{"Width"} = $width;

            $insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    $insetBoxCount = keys(%insetBoxes);

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
    my $insetCircleRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^S$
^Q$/m;

    my @tempInsetCircle = $_output =~ /$insetCircleRegex/ig;
    my $insetCircleDataPoints = 2;

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

            # my $width  = $tempInsetCircle[ $i + 2 ];
            # my $height = $tempInsetCircle[ $i + 3 ];

            # #Let's only save large, but not too large, boxes
            # next
            # if ( ( abs($width) < 50 )
            # || ( abs($height) < 50 )
            # || ( abs($height) > 500 )
            # || ( abs($width) > 300 ) );

            #put them into a hash
            #TODO: This is a cheat and will probably not always work
            $insetCircles{ $i . $random }{"X"}      = $x - 30;
            $insetCircles{ $i . $random }{"Y"}      = $y;
            $insetCircles{ $i . $random }{"Radius"} = 30;

            # $insetBoxes{ $i . $random }{"X2"} = $x + $width;

            # $insetBoxes{ $i . $random }{"Y2"} = $y + $height;

            # $insetBoxes{ $i . $random }{"Width"} = $width;

            # $insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    $insetCircleCount = keys(%insetCircles);

    # if ($debug) {
    # print "$insetCircleCount Inset Circles ";

    # print Dumper ( \%insetCircles );

    # }

    return;
}

sub findHorizontalLines {
    my ($_output) = @_;

    #REGEX building blocks

    #A purely horizontal line
    my $horizontalLineRegex = qr/^$transformCaptureXYRegex$
^0\s0\sm$
^($numberRegex)\s+0\s+l$
^S$
^Q$/m;

    my @tempHorizontalLine = $_output =~ /$horizontalLineRegex/ig;

    my $tempHorizontalLineLength = 0 + @tempHorizontalLine;
    my $tempHorizontalLineCount  = $tempHorizontalLineLength / 3;

    if ( $tempHorizontalLineLength >= 3 ) {
        my $random = rand();
        for ( my $i = 0 ; $i < $tempHorizontalLineLength ; $i = $i + 3 ) {

            #Let's only save long lines
            next if ( abs( $tempHorizontalLine[ $i + 2 ] ) < 100 );

            #put them into a hash
            $horizontalAndVerticalLines{ $i . $random }{"X"} =
              $tempHorizontalLine[$i];

            $horizontalAndVerticalLines{ $i . $random }{"Y"} =
              $tempHorizontalLine[ $i + 1 ];

            $horizontalAndVerticalLines{ $i . $random }{"X2"} =
              $tempHorizontalLine[$i] + $tempHorizontalLine[ $i + 2 ];

            $horizontalAndVerticalLines{ $i . $random }{"Y2"} =
              $tempHorizontalLine[ $i + 1 ];
        }

    }

    #print Dumper ( \%horizontalAndVerticalLines );

    # #A purely vertical line
    # my $verticalLineRegex = qr/^$transformCaptureXYRegex$
    # ^0\s0\sm$
    # ^0\s+($numberRegex)\s+l$
    # ^S$
    # ^Q$/m;

    # @tempHorizontalLine = $_output =~ /$verticalLineRegex/ig;

    # $tempHorizontalLineLength = 0 + @tempHorizontalLine;
    # $tempHorizontalLineCount  = $tempHorizontalLineLength / 3;
    # if ( $tempHorizontalLineLength >= 3 ) {
    # my $random = rand();
    # for ( my $i = 0 ; $i < $tempHorizontalLineLength ; $i = $i + 3 ) {

    # #Let's only save long lines
    # next if ( $tempHorizontalLine[ $i + 2 ] < 100 );

    # #put them into a hash
    # $horizontalAndVerticalLines{ $i + $random }{"X"} =
    # $tempHorizontalLine[$i];

    # $horizontalAndVerticalLines{ $i + $random }{"Y"} =
    # $tempHorizontalLine[ $i + 1 ];

    # $horizontalAndVerticalLines{ $i + $random }{"X2"} =
    # $tempHorizontalLine[$i];

    # $horizontalAndVerticalLines{ $i + $random }{"Y2"} =
    # $tempHorizontalLine[ $i + 1 ] + $tempHorizontalLine[ $i + 2 ];
    # }

    # }

    $horizontalAndVerticalLinesCount = keys(%horizontalAndVerticalLines);

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
    my ($obstacleregex) = qr/^$transformCaptureXYRegex$
^$originRegex$
^([\.0-9]+) [\.0-9]+ l$
^([\.0-9]+) [\.0-9]+ l$
^S$
^Q$
^$transformCaptureXYRegex$
^$originRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^f\*$
^Q$/m;

    #each entry in @tempobstacles will have the numbered captures from the regex, 6 for each one
    my (@tempobstacles)           = $_output =~ /$obstacleregex/ig;
    my ($tempobstacles_length)    = 0 + @tempobstacles;
    my $dataPointsPerObstacleIcon = 6;

    #Divide length of array by 6 data points for each obstacle to get count of obstacles
    my ($tempobstacles_count) =
      $tempobstacles_length / $dataPointsPerObstacleIcon;

    if ( $tempobstacles_length >= $dataPointsPerObstacleIcon ) {

        #say "Found $tempobstacles_count obstacles in stream $stream";

        for (
            my $i = 0 ;
            $i < $tempobstacles_length ;
            $i = $i + $dataPointsPerObstacleIcon
          )
        {

            #Note: this code does not accumulate the objects across streams but rather overwrites existing ones
            #This works fine as long as the stream with all of the obstacles in the main section of the drawing comes after the streams
            #with obstacles for the airport diagram (which is a separate scale)
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
            my $x = $tempobstacles[$i];
            my $y = $tempobstacles[ $i + 1 ];

            my $centerX = "";
            my $centerY = "";

            #Note that this is half the width of the whole icon
            my $width  = $tempobstacles[ $i + 2 ] * 2;
            my $height = $tempobstacles[ $i + 3 ];

            $obstacleIcons{ $i . $rand }{"GeoreferenceX"} = $x + $width / 2;
            $obstacleIcons{ $i . $rand }{"GeoreferenceY"} = $y;
            $obstacleIcons{ $i . $rand }{"CenterX"}       = $x + $width / 2;
            $obstacleIcons{ $i . $rand }{"CenterY"}       = $y + $height / 2;
            $obstacleIcons{ $i . $rand }{"Width"}         = $width;
            $obstacleIcons{ $i . $rand }{"Height"}        = $height;

            #$obstacleIcons{ $i . $rand }{"Height"}  = "unknown";
            $obstacleIcons{ $i . $rand }{"ObstacleTextBoxesThatPointToMe"} = 0;
            $obstacleIcons{ $i . $rand }{"potentialTextBoxes"}             = 0;
            $obstacleIcons{ $i . $rand }{"type"} = "obstacle";
        }

    }

    $obstacleCount = keys(%obstacleIcons);
    if ($debug) {
        print "$tempobstacles_count obstacles ";

        #print Dumper ( \%obstacleIcons );
    }
    return;
}

sub findFixIcons {
    my ($_output) = @_;

    #Find fixes in the PDF
    # my $fixregex =
    # qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([-\.0-9]+) [\.0-9]+ l [-\.0-9]+ ([\.0-9]+) l 0 0 l S Q/;
    my $fixregex = qr/^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
^0 0 m$
^([-\.0-9]+) [\.0-9]+ l$
^[-\.0-9]+ ([\.0-9]+) l$
^0 0 l$
^S$
^Q$/m;

    my @tempfixes = $_output =~ /$fixregex/ig;
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

            #put them into a hash
            #code here is making the x/y the center of the triangle
            $fixIcons{ $i . $rand }{"GeoreferenceX"} = $x + ( $width / 2 );
            $fixIcons{ $i . $rand }{"GeoreferenceY"} = $y + ( $height / 2 );
            $fixIcons{ $i . $rand }{"CenterX"}       = $x + ( $width / 2 );
            $fixIcons{ $i . $rand }{"CenterY"}       = $y + ( $height / 2 );
            $fixIcons{ $i . $rand }{"Width"}         = $width;
            $fixIcons{ $i . $rand }{"Height"}        = $height;
            $fixIcons{ $i . $rand }{"Type"}          = "fix";

            #$fixIcons{ $i . $rand }{"Name"} = "none";
        }

    }

    $fixCount = keys(%fixIcons);
    if ($debug) {
        print "$tempfixes_count fix ";
    }
    return;
}

# sub findFinalApproachFixIcons {
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
# }

# sub findVisualDescentPointIcons {
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
# }

sub convertPdfToPng {

    #---------------------------------------------------
    #Convert the PDF to a PNG
    my $pdfToPpmOutput;
    if ( -e $targetpng ) {
        say "$targetpng already exists" if $debug;
        return;
    }
    $pdfToPpmOutput = qx(pdftoppm -png -r $pngDpi $targetPdf > $targetpng);

    $retval = $? >> 8;
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
      qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($obstacleHeightRegex)</;

    foreach my $line (@pdfToTextBbox) {
        if ( $line =~ m/$obstacleTextBoxRegex/ ) {
            my $xMin = $1;
            my $yMin = $2;
            my $xMax = $3;
            my $yMax = $4;

            my $height = $yMax - $yMin;
            my $width  = $xMax - $xMin;

            # $obstacleTextBoxes{ $1 . $2 }{"RasterX"} = $1 * $scaleFactorX;
            # $obstacleTextBoxes{ $1 . $2 }{"RasterY"} = $2 * $scaleFactorY;
            $obstacleTextBoxes{ $1 . $2 }{"Width"}  = $width;
            $obstacleTextBoxes{ $1 . $2 }{"Height"} = $height;
            $obstacleTextBoxes{ $1 . $2 }{"Text"}   = $5;

            # $obstacleTextBoxes{ $1 . $2 }{"PdfX"}    = $xMin;
            # $obstacleTextBoxes{ $1 . $2 }{"PdfY"}    = $pdfYSize - $2;
            $obstacleTextBoxes{ $1 . $2 }{"CenterX"} = $xMin + ( $width / 2 );

            # $obstacleTextBoxes{ $1 . $2 }{"CenterY"} = $pdfYSize - $2;
            $obstacleTextBoxes{ $1 . $2 }{"CenterY"} =
              ( $pdfYSize - $yMin ) - ( $height / 2 );
            $obstacleTextBoxes{ $1 . $2 }{"IconsThatPointToMe"} = 0;
        }

    }

    #print Dumper ( \%obstacleTextBoxes );

    if ($debug) {
        say "Found " .
          keys(%obstacleTextBoxes) . " Potential obstacle text boxes";
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

    foreach my $line (@pdfToTextBbox) {
        if ( $line =~ m/$fixTextBoxRegex/ ) {
            my $_fixXMin = $1;
            my $_fixYMin = $2;
            my $_fixXMax = $3;
            my $_fixYMax = $4;
            my $_fixName = $5;

            #Exclude invalid fix names.  A smarter way to do this would be to use the DB lookup to limit to local fix names
            next if $_fixName =~ m/$invalidFixNamesRegex/;

            $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterX"} =
              $_fixXMin * $scaleFactorX;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterY"} =
              $_fixYMin * $scaleFactorY;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"Width"} =
              $_fixXMax - $_fixXMin;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"Height"} =
              $_fixYMax - $_fixYMin;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"Text"} = $_fixName;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"PdfX"} = $_fixXMin;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"PdfY"} =
              $pdfYSize - $_fixYMin;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"CenterX"} =
              $_fixXMin + ( ( $_fixXMax - $_fixXMin ) / 2 );
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"CenterY"} =
              $pdfYSize - $_fixYMin;
        }

    }
    if ($debug) {

        #print Dumper ( \%fixTextboxes );
        say "Found " .
          keys(%fixTextboxes) . " Potential Fix/GPS Waypoint text boxes";
        say "";
    }
    return;
}

sub findVorTextboxes {
    say ":findVorTextboxes" if $debug;

    #--------------------------------------------------------------------------
    #Get list of potential VOR (or other ground based nav)  textboxes
    #For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
    #We'll convert them to PDF coordinates
    my $frequencyRegex = qr/\d\d\d\.[\d]{1,3}/m;

    #my $frequencyRegex = qr/116.3/m;

    my $vorTextBoxRegex =
      qr/^\s+<word xMin="($numberRegex)" yMin="($numberRegex)" xMax="$numberRegex" yMax="$numberRegex">($frequencyRegex)<\/word>$
^\s+<word xMin="$numberRegex" yMin="$numberRegex" xMax="($numberRegex)" yMax="($numberRegex)">([A-Z]{3})<\/word>$/m;

    #We can get away with not allowing "see" because it's a VOT
    my $invalidVorNamesRegex = qr/app|dep|arr|see|ils/i;

    my $scal = join( "", @pdfToTextBbox );

    my @tempVortac = $scal =~ /$vorTextBoxRegex/ig;

    my $tempVortacLength        = 0 + @tempVortac;
    my $dataPointsPerVorTextbox = 6;
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
            my $_vorFreq = $tempVortac[ $i + 2 ];
            my $_vorXMax = $tempVortac[ $i + 3 ];
            my $_vorYMax = $tempVortac[ $i + 4 ];
            my $_vorName = $tempVortac[ $i + 5 ];

            next if $_vorName =~ m/$invalidVorNamesRegex/;

            #Check that the box isn't too big
            #This is a workaround for "CO-DEN-ILS-RWY-34L-CAT-II---III.pdf" where it finds a bad box due to ordering of text in PDF
            next if ( abs( $_vorXMax - $_vorXMin ) > 50 );

            $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterX"} =
              $_vorXMin * $scaleFactorX;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterY"} =
              $_vorYMin * $scaleFactorY;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Width"} =
              $_vorXMax - $_vorXMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Height"} =
              $_vorYMax - $_vorYMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Text"} = $_vorName;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfX"} = $_vorXMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfY"} =
              $pdfYSize - $_vorYMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"CenterX"} =
              $_vorXMin + ( ( $_vorXMax - $_vorXMin ) / 2 );
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"CenterY"} =
              $pdfYSize - $_vorYMin;
        }
    }
    if ($debug) {

        #qprint Dumper ( \%vorTextboxes );
        say "Found " . keys(%vorTextboxes) . " Potential NAVAID text boxes";
        say "";
    }
    return;
}

# sub matchObstacleIconToUniqueObstaclesFromDb {
# say ":matchObstacleIconToUniqueObstaclesFromDb" if $debug;

# #Find a obstacle icon with text that matches the height of each of our unique_obstacles_from_db
# #Add the center coordinates of its closest height text box to unique_obstacles_from_db hash
# #
# #The key for %unique_obstacles_from_db is the height of each obstacle
# foreach my $key ( keys %unique_obstacles_from_db ) {

# foreach my $key2 ( keys %obstacleIcons ) {

# #Next icon if this one doesn't have a matching textbox
# next unless ( $obstacleIcons{$key2}{"MatchedTo"} );
# #TODO Make a new hash with all of our info, don't just update unique_obstacles_from_db
# my $keyOfMatchedTextbox =  $obstacleIcons{$key2}{"MatchedTo"};
# my $thisIconsGeoreferenceX =  $obstacleIcons{$key2}{"GeoreferenceX"};
# my $thisIconsGeoreferenceY =  $obstacleIcons{$key2}{"GeoreferenceY"};
# my $textOfMatchedTextbox = $obstacleTextBoxes{$keyOfMatchedTextbox}{"Text"};
# #$obstacleIcons{$key2}{"Name"}

# if ( $textOfMatchedTextbox eq $key ) {

# #print $obstacleTextBoxes{$key2}{"Text"} . "$key\n";
# $unique_obstacles_from_db{$key}{"Label"} =                  $textOfMatchedTextbox;
# $unique_obstacles_from_db{$key}{"GeoreferenceX"} = $thisIconsGeoreferenceX                   ;
# $unique_obstacles_from_db{$key}{"GeoreferenceY"} =$thisIconsGeoreferenceY                  ;
# # $unique_obstacles_from_db{$key}{"TextBoxX"} =
# # $obstacleIcons{$key2}{"TextBoxX"};

# # $unique_obstacles_from_db{$key}{"TextBoxY"} =
# # $obstacleIcons{$key2}{"TextBoxY"};

# }

# }
# }
# return;
# }

sub matchIconToDatabase {
    my ( $iconHashRef, $textboxHashRef, $databaseHashRef ) = @_;
    say ":matchIconToDatabase" if $debug;

    #Find an icon with text that matches an item in a database lookup
    #Add the center coordinates of its closest text box to the database hash
    #
    #The key for %unique_obstacles_from_db is the height of each obstacle
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
    foreach my $key ( sort keys %gcps ) {
        $gcps{$key}{"Mismatches"} = 0;
    }

    #This is where we finally generate the real information for each plate
    foreach my $key ( sort keys %gcps ) {

        #This code is for calculating the PDF x/y and lon/lat differences between every object
        #to calculate the ratio between the two
        foreach my $key2 ( sort keys %gcps ) {

            #Don't calculate a scale with ourself
            next if $key eq $key2;

            #X pixels between points
            my $pixelDistanceX =
              abs( $gcps{$key}{"pngx"} - $gcps{$key2}{"pngx"} );

            #Y pixels between points
            my $pixelDistanceY =
              abs( $gcps{$key}{"pngy"} - $gcps{$key2}{"pngy"} );

            #Longitude degrees between points
            my $longitudeDiff = abs( $gcps{$key}{"lon"} - $gcps{$key2}{"lon"} );

            #Latitude degrees between points
            my $latitudeDiff = abs( $gcps{$key}{"lat"} - $gcps{$key2}{"lat"} );

            unless ( $pixelDistanceX
                && $pixelDistanceY
                && $longitudeDiff
                && $latitudeDiff )
            {
                say
                  "Something not defined for $key-$key2 pair: $pixelDistanceX, $pixelDistanceY, $longitudeDiff, $latitudeDiff"
                  if $debug;
                next;
            }
            my $longitudeToPixelRatio = $longitudeDiff / $pixelDistanceX;
            my $latitudeToPixelRatio  = $latitudeDiff / $pixelDistanceY;

            #For the raster, calculate the Longitude of the upper-left corner based on this object's longitude and the degrees per pixel
            my $ulX =
              $gcps{$key}{"lon"} -
              ( $gcps{$key}{"pngx"} * $longitudeToPixelRatio );

            #For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
            my $ulY =
              $gcps{$key}{"lat"} +
              ( $gcps{$key}{"pngy"} * $latitudeToPixelRatio );

            #For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
            my $lrX =
              $gcps{$key}{"lon"} +
              (
                abs( $pngXSize - $gcps{$key}{"pngx"} ) *
                  $longitudeToPixelRatio );

            #For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
            my $lrY =
              $gcps{$key}{"lat"} -
              (
                abs( $pngYSize - $gcps{$key}{"pngy"} ) *
                  $latitudeToPixelRatio );

            #Go to next object pair if we've somehow gotten zero for any of these numbers
            next
              if ( $pixelDistanceX == 0
                || $pixelDistanceY == 0
                || $longitudeDiff == 0
                || $latitudeDiff == 0 );

            #The X/Y (or Longitude/Latitude) ratio that would result from using this particular pair

            my $longitudeToLatitudeRatio =
              abs( ( $ulX - $lrX ) / ( $ulY - $lrY ) );

            say
              "$key,$key2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio"
              if $debug;

            #If our XYRatio seems to be out of whack for this object pair then don't use the info we derived
            #Currently we're just silently ignoring this, should we try to figure out the bad objects and remove?
            my $targetLonLatRatio =
              0.000004 * ( $ulY**3 ) -
              0.0001 *   ( $ulY**2 ) +
              0. * $ulY + 0.6739;

            #my $targetLongitudeToPixelRatio1 = 0.000000002*($ulY**3) - 0.00000008*($ulY**2) + 0.000002*$ulY + 0.0004;

            # if ( $latitudeToPixelRatio < .0003 || $latitudeToPixelRatio > .0006 ) {
            #was .00037 < x < .00039 and .00055 < x < .00059

            #TODO Change back to .00037 and .00039?

            if (
                   not( between( $latitudeToPixelRatio, .00013, .00099 ) )
                && not( between( $latitudeToPixelRatio, .00055, .00099 ) )

              )
            {
                if ($debug) {

                    $gcps{$key}{"Mismatches"} =
                      ( $gcps{$key}{"Mismatches"} ) + 1;
                    $gcps{$key2}{"Mismatches"} =
                      ( $gcps{$key2}{"Mismatches"} ) + 1;
                    say
                      "Bad latitudeToPixelRatio $latitudeToPixelRatio on $key-$key2 pair"
                      if $debug;
                }

                next;
            }

            if (
                $longitudeToPixelRatio > .001

              )
            {
                if ($debug) {

                    $gcps{$key}{"Mismatches"} =
                      ( $gcps{$key}{"Mismatches"} ) + 1;
                    $gcps{$key2}{"Mismatches"} =
                      ( $gcps{$key2}{"Mismatches"} ) + 1;
                    say
                      "Bad longitudeToPixelRatio $longitudeToPixelRatio on $key-$key2 pair"
                      if $debug;
                }

                next;
            }

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
            push @xScaleAvg, $longitudeToPixelRatio;
            push @yScaleAvg, $latitudeToPixelRatio;
            push @ulXAvg,    $ulX;
            push @ulYAvg,    $ulY;
            push @lrXAvg,    $lrX;
            push @lrYAvg,    $lrY;

        }
    }
    return;
}

sub georeferenceTheRaster {

    #----------------------------------------------------------------------------------------------------------------------------------------------------
    #Try to georeference based on Upper Left and Lower Right extents of longitude and latitude

    #Uncomment these to use the average values for each
    # my $upperLeftLon  = $ulXAvrg;
    # my $upperLeftLat  = $ulYAvrg;
    # my $lowerRightLon = $lrXAvrg;
    # my $lowerRightLat = $lrYAvrg;

    #Uncomment these to use the median values for each
    my $upperLeftLon  = $ulXmedian;
    my $upperLeftLat  = $ulYmedian;
    my $lowerRightLon = $lrXmedian;
    my $lowerRightLat = $lrYmedian;

    my $medianLonDiff = $ulXmedian - $lrXmedian;
    my $medianLatDiff = $ulYmedian - $lrYmedian;
    $lonLatRatio = abs( $medianLonDiff / $medianLatDiff );

    if ($debug) {
        say "Output Longitude/Latitude Ratio: " . $lonLatRatio;
        say "Input PDF ratio: " . $pdfXYRatio;
        say "";
    }

    # #Check that our determined scales and x/y ratios seem to make sense.  A
    # #if (abs($pdfXYRatio - $lonLatRatio) > .25) {
    # if ( abs($lonLatRatio) < .65 || abs($lonLatRatio) > 1.45 ) {
    # say
    # "Longitude/Latitude output ratio is  out of whack ($lonLatRatio), we probably picked bad ground control points";
    # }

    # if ( abs($xMedian) < .0002 || abs($xMedian) > .0008 ) {

    # #These test values are based on 300 dpi
    # say
    # "X scale is out of whack ($xMedian), we probably picked bad ground control points";
    # }

    # if ( abs($yMedian) < .0003 || abs($yMedian) > .0006 ) {
    # # ($latitudeToPixelRatio < .00037 || $latitudeToPixelRatio > .00039) && ($latitudeToPixelRatio < .00056 || $latitudeToPixelRatio > .00059)
    # #These test values are based on 300 dpi
    # say
    # "Y scale is out of whack ($yMedian), we probably picked bad ground control points";
    # }

    # my $xYMedianScaleRatio = $xMedian / $yMedian;

    # if ( abs($xYMedianScaleRatio) < 1.15 || abs($xYMedianScaleRatio) > 1.6 ) {

    # #These test values are based on 300 dpi
    # say
    # "pixel to real-world XY scale is out of whack ($xYMedianScaleRatio), we probably picked bad ground control points";
    # }

    my $gdal_translateCommand =
      "gdal_translate -q -of VRT -strict -a_srs \"+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs\" -co worldfile=yes  -a_ullr $upperLeftLon $upperLeftLat $lowerRightLon $lowerRightLat $targetpng  $targetvrt ";

    if ($debug) {
        say $gdal_translateCommand;
        say "";
    }

    #Run gdal_translate
    #Really we're just doing this for the worldfile.  I bet we could create it ourselves quicker
    my $gdal_translateoutput = qx($gdal_translateCommand);

    # $gdal_translateoutput =
    # qx(gdal_translate  -strict -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpng $targetvrt);
    $retval = $? >> 8;
    croak
      "Error executing gdal_translate.  Is it installed? Return code was $retval"
      if ( $retval != 0 );
    say $gdal_translateoutput if $debug;

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
    return;
}

sub calculateRoughRealWorldExtentsOfRasterWithOneGCP {
    say
      "Found only one Ground Control Point.  Let's try a wild guess on $targetPdf";

    my $guessAtLatitudeToPixelRatio = .00038;
    my $targetXyRatio =
      0.000007 * ( $airportLatitudeDec**3 ) -
      0.0002 *   ( $airportLatitudeDec**2 ) +
      0.0037 *   ($airportLatitudeDec) + 1.034;

    my $guessAtLongitudeToPixelRatio =
      $targetXyRatio * $guessAtLatitudeToPixelRatio;

    #my $targetLonLatRatio = 0.000004*($airportLatitudeDec**3) - 0.0001*($airportLatitudeDec**2) + 0.0024*$airportLatitudeDec + 0.6739;
    #my $targetLongitudeToPixelRatio1 = 0.000000002*($airportLatitudeDec**3) - 0.00000008*($airportLatitudeDec**2) + 0.000002*$airportLatitudeDec + 0.0004;

    foreach my $key ( sort keys %gcps ) {

        #For the raster, calculate the Longitude of the upper-left corner based on this object's longitude and the degrees per pixel
        my $ulX =
          $gcps{$key}{"lon"} -
          ( $gcps{$key}{"pngx"} * $guessAtLongitudeToPixelRatio );

        #For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
        my $ulY =
          $gcps{$key}{"lat"} +
          ( $gcps{$key}{"pngy"} * $guessAtLatitudeToPixelRatio );

        #For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
        my $lrX =
          $gcps{$key}{"lon"} +
          (
            abs( $pngXSize - $gcps{$key}{"pngx"} ) *
              $guessAtLongitudeToPixelRatio );

        #For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
        my $lrY =
          $gcps{$key}{"lat"} -
          (
            abs( $pngYSize - $gcps{$key}{"pngy"} ) *
              $guessAtLatitudeToPixelRatio );

        push @xScaleAvg, $guessAtLongitudeToPixelRatio;
        push @yScaleAvg, $guessAtLatitudeToPixelRatio;
        push @ulXAvg,    $ulX;
        push @ulYAvg,    $ulY;
        push @lrXAvg,    $lrX;
        push @lrYAvg,    $lrY;
    }
    return;
}

sub calculateSmoothedRealWorldExtentsOfRaster {

    #X-scale average and standard deviation

    calculateXScale();

    #Y-scale average and standard deviation

    calculateYScale();

    #ulX average and standard deviation

    calculateULX();

    #uly average and standard deviation

    calculateULY();

    #lrX average and standard deviation

    calculateLRX();

    #lrY average and standard deviation

    calculateLRY();
    return;
}

sub writeStatistics {

    open my $file, '>>', $targetStatistics
      or croak "can't open '$targetStatistics' for writing : $!";

    say {$file}
      '$dir$filename,$objectstreams,$obstacleCount,$fixCount,$gpsCount,$finalApproachFixCount,$visualDescentPointCount,$gcpCount,$unique_obstacles_from_dbCount,$pdfXYRatio,$lonLatRatio,$xAvg,$xMedian,$yAvg,$yMedian';

    say {$file}
      "$dir$filename,$objectstreams,$obstacleCount,$fixCount,$gpsCount,$finalApproachFixCount,$visualDescentPointCount,$gcpCount,$unique_obstacles_from_dbCount,$pdfXYRatio,$lonLatRatio,$xAvg,$xMedian,$yAvg,$yMedian"
      or croak "Cannot write to $targetStatistics: ";    #$OS_ERROR

    close $file;
    return;
}

sub outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb {

    #Only outline our unique potential obstacle_heights with green
    foreach my $key ( sort keys %obstacleTextBoxes ) {

        #Is there a obstacletextbox with the same text as our obstacle's height?
        if (
            exists $unique_obstacles_from_db{ $obstacleTextBoxes{$key}{"Text"} }
          )
        {
            #Yes, draw a box around it
            my $obstacle_box = $page->gfx;
            $obstacle_box->strokecolor('green');
            $obstacle_box->linewidth(.1);
            $obstacle_box->rect(
                $obstacleTextBoxes{$key}{"CenterX"} -
                  $obstacleTextBoxes{$key}{"Width"} / 2,
                $obstacleTextBoxes{$key}{"CenterY"} -
                  $obstacleTextBoxes{$key}{"Height"} / 2,
                $obstacleTextBoxes{$key}{"Width"},
                $obstacleTextBoxes{$key}{"Height"}

            );

            $obstacle_box->stroke;
        }
    }
    return;
}

sub removeUniqueObstaclesFromDbThatAreNotMatchedToIcons {
    say ":removeUniqueObstaclesFromDbThatAreNotMatchedToIcons" if $debug;

    #clean up unique_obstacles_from_db
    #remove entries that have no ObsIconX or Y
    foreach my $key ( sort keys %unique_obstacles_from_db ) {
        unless ( ( exists $unique_obstacles_from_db{$key}{"ObsIconX"} )
            && ( exists $unique_obstacles_from_db{$key}{"ObsIconY"} ) )
        {
            delete $unique_obstacles_from_db{$key};
        }
    }

    if ($debug) {
        say
          "unique_obstacles_from_db after deleting entries that have no ObsIconX or Y:";
        print Dumper ( \%unique_obstacles_from_db );
        say "";
    }
    return;
}

# sub removeUniqueObstaclesFromDbThatShareIcons {

# #Find entries that share an ObsIconX and ObsIconY with another entry and create an array of them
# my @a;
# foreach my $key ( sort keys %unique_obstacles_from_db ) {

# foreach my $key2 ( sort keys %unique_obstacles_from_db ) {
# if (
# #Don't test an entry against itself
# ( $key ne $key2 )
# && ( $unique_obstacles_from_db{$key}{"ObsIconX"} ==
# $unique_obstacles_from_db{$key2}{"ObsIconX"} )
# && ( $unique_obstacles_from_db{$key}{"ObsIconY"} ==
# $unique_obstacles_from_db{$key2}{"ObsIconY"} )
# )
# {
# #Save the key to our array of keys to delete
# push @a, $key;

# # push @a, $key2;
# say "Duplicate obstacle" if $debug;
# }

# }
# }

# #Actually delete the entries
# foreach my $entry (@a) {
# delete $unique_obstacles_from_db{$entry};
# }
# return;
# }

sub findFixesNearAirport {
    my $radius = .5;

    #What type of fixes to look for
    my $type = "%REP-PT";

    #Query the database for fixes within our $radius
    $sth = $dbh->prepare(
        "SELECT * FROM fixes WHERE  (Latitude >  $airportLatitudeDec - $radius ) and 
                                (Latitude < $airportLatitudeDec + $radius ) and 
                                (Longitude >  $airportLongitudeDec - $radius ) and 
                                (Longitude < $airportLongitudeDec +$radius ) and
                                (Type like '$type')"
    );
    $sth->execute();

    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$row;
        $fixes_from_db{$fixname}{"Name"} = $fixname;
        $fixes_from_db{$fixname}{"Lat"}  = $lat;
        $fixes_from_db{$fixname}{"Lon"}  = $lon;
        $fixes_from_db{$fixname}{"Type"} = $fixtype;

    }
    my $nmLatitude  = 60 * $radius;
    my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    if ($debug) {
        my $rows   = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $rows FIXES within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) ($nmLongitude x $nmLatitude nm)  from database";

        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

        #print Dumper ( \%fixes_from_db );
        say "";
    }

    return;
}

sub findGpsWaypointsNearAirport {
    $radius = .3;

    #What type of fixes to look for
    my $type = "%";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
        "SELECT * FROM fixes WHERE  
                                (Latitude >  $airportLatitudeDec - $radius ) and 
                                (Latitude < $airportLatitudeDec +$radius ) and 
                                (Longitude >  $airportLongitudeDec - $radius ) and 
                                (Longitude < $airportLongitudeDec +$radius ) and
                                (Type like '$type')"
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$row;
        $gpswaypoints_from_db{$fixname}{"Name"} = $fixname;
        $gpswaypoints_from_db{$fixname}{"Lat"}  = $lat;
        $gpswaypoints_from_db{$fixname}{"Lon"}  = $lon;
        $gpswaypoints_from_db{$fixname}{"Type"} = $fixtype;

    }

    if ($debug) {
        my $rows   = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $rows GPS waypoints within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) from database";
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

        #print Dumper ( \%gpswaypoints_from_db );
        say "";
    }
    return;
}

sub findNavaidsNearAirport {
    $radius = .45;

    #What type of fixes to look for
    my $type = "%VOR%";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
        "SELECT * FROM navaids WHERE  
                                (Latitude >  $airportLatitudeDec - $radius ) and 
                                (Latitude < $airportLatitudeDec +$radius ) and 
                                (Longitude >  $airportLongitudeDec - $radius ) and 
                                (Longitude < $airportLongitudeDec +$radius ) and
                                (Type like '$type')"
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $row (@$allSqlQueryResults) {
        my ( $navaidName, $lat, $lon, $navaidType ) = @$row;
        $navaids_from_db{$navaidName}{"Name"} = $navaidName;
        $navaids_from_db{$navaidName}{"Lat"}  = $lat;
        $navaids_from_db{$navaidName}{"Lon"}  = $lon;
        $navaids_from_db{$navaidName}{"Type"} = $navaidType;

    }

    if ($debug) {
        my $rows   = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $rows Navaids within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) from database"
          if $debug;
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

        print Dumper ( \%navaids_from_db );
        say "";
    }
    return;
}

sub matchClosestFixTextBoxToEachGpsWaypointIcon {

    #Try to find closest fixtextbox to each fix icon
    foreach my $key ( sort keys %gpsWaypointIcons ) {
        my $distance_to_closest_fixtextbox_x;
        my $distance_to_closest_fixtextbox_y;

        #Initialize this to a very high number so everything is closer than it
        my $distance_to_closest_fixtextbox = 999999999999;
        foreach my $key2 ( keys %fixTextboxes ) {
            $distance_to_closest_fixtextbox_x =
              $fixTextboxes{$key2}{"CenterX"} -
              $gpsWaypointIcons{$key}{"CenterX"};
            $distance_to_closest_fixtextbox_y =
              $fixTextboxes{$key2}{"CenterY"} -
              $gpsWaypointIcons{$key}{"CenterY"};

            my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
                  $distance_to_closest_fixtextbox_y**2 );

            #The 27 here was chosen to make one particular sample work, it's not universally valid
            #Need to improve the icon -> textbox mapping
            #say "Hypotenuse: $hyp" if $debug;
            if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
                $distance_to_closest_fixtextbox = $hyp;
                $gpsWaypointIcons{$key}{"Name"} = $fixTextboxes{$key2}{"Text"};
                $gpsWaypointIcons{$key}{"TextBoxX"} =
                  $fixTextboxes{$key2}{"CenterX"};
                $gpsWaypointIcons{$key}{"TextBoxY"} =
                  $fixTextboxes{$key2}{"CenterY"};
                $gpsWaypointIcons{$key}{"Lat"} =
                  $gpswaypoints_from_db{ $gpsWaypointIcons{$key}{"Name"} }
                  {"Lat"};
                $gpsWaypointIcons{$key}{"Lon"} =
                  $gpswaypoints_from_db{ $gpsWaypointIcons{$key}{"Name"} }
                  {"Lon"};
            }

        }

    }
    return;
}

# sub deleteGpsWaypointsWithNoName {

# #clean up gpswaypoints
# #remove entries that have no name
# foreach my $key ( sort keys %gpsWaypointIcons ) {
# if ( $gpsWaypointIcons{$key}{"Name"} eq "none" )

# {
# delete $gpsWaypointIcons{$key};
# }
# }

# if ($debug) {
# say "gpswaypoints after deleting entries with no name";
# print Dumper ( \%gpsWaypointIcons );
# say "";
# }
# return;
# }

# sub deleteDuplicateGpsWaypoints {

# #Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
# OUTER:
# foreach my $key ( sort keys %gpsWaypointIcons ) {

# #my $hyp = sqrt( $distance_to_pdf_center_x**2 + $distance_to_pdf_center_y**2 );
# foreach my $key2 ( sort keys %gpsWaypointIcons ) {

# if (
# (
# $gpsWaypointIcons{$key}{"Name"} eq
# $gpsWaypointIcons{$key2}{"Name"}
# )
# && ( $key ne $key2 )
# )
# {
# my $name = $gpsWaypointIcons{$key}{"Name"};
# say "A ha, I found a duplicate GPS waypoint name: $name"
# if $debug;
# my $distance_to_pdf_center_x1 =
# abs(
# $pdfCenterX - $gpsWaypointIcons{$key}{"iconCenterXPdf"} );
# my $distance_to_pdf_center_y1 =
# abs(
# $pdfCenterY - $gpsWaypointIcons{$key}{"iconCenterYPdf"} );
# say $distance_to_pdf_center_y1;
# my $distance_to_pdf_center_x2 =
# abs(
# $pdfCenterX - $gpsWaypointIcons{$key2}{"iconCenterXPdf"} );
# my $distance_to_pdf_center_y2 =
# abs(
# $pdfCenterY - $gpsWaypointIcons{$key2}{"iconCenterYPdf"} );

# #say $distance_to_pdf_center_y2;

# if ( $distance_to_pdf_center_y1 < $distance_to_pdf_center_y2 ) {
# delete $gpsWaypointIcons{$key2};
# say "Deleting the 2nd entry" if $debug;
# goto OUTER;
# }
# else {
# delete $gpsWaypointIcons{$key};
# say "Deleting the first entry" if $debug;
# goto OUTER;
# }
# }

# }

# }
# return;
# }

sub deleteDuplicateFixes {

    #Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
  OUTER:
    foreach my $key ( sort keys %fixIcons ) {

        #my $hyp = sqrt( $distance_to_pdf_center_x**2 + $distance_to_pdf_center_y**2 );
        foreach my $key2 ( sort keys %fixIcons ) {

            if (   ( $fixIcons{$key}{"Name"} eq $fixIcons{$key2}{"Name"} )
                && ( $key ne $key2 ) )
            {
                my $name = $fixIcons{$key}{"Name"};
                say "A ha, I found a duplicated fix: $name"
                  if $debug;
                my $distance_to_pdf_center_x1 =
                  abs( $pdfCenterX - $fixIcons{$key}{"iconCenterXPdf"} );
                my $distance_to_pdf_center_y1 =
                  abs( $pdfCenterY - $fixIcons{$key}{"iconCenterYPdf"} );

                #say $distance_to_pdf_center_y1;
                my $distance_to_pdf_center_x2 =
                  abs( $pdfCenterX - $fixIcons{$key2}{"iconCenterXPdf"} );
                my $distance_to_pdf_center_y2 =
                  abs( $pdfCenterY - $fixIcons{$key2}{"iconCenterYPdf"} );

                #say $distance_to_pdf_center_y2;

                if ( $distance_to_pdf_center_y1 < $distance_to_pdf_center_y2 ) {
                    delete $fixIcons{$key2};
                    say "Deleting the 2nd entry" if $debug;
                    goto OUTER;
                }
                else {
                    delete $fixIcons{$key};
                    say "Deleting the first entry" if $debug;
                    goto OUTER;
                }
            }

        }

    }
    return;
}

# sub drawLineFromEachGpsWaypointToMatchedTextbox {

# #Draw a line from GPS waypoint icon to closest text boxes
# my $gpswaypoint_line = $page->gfx;

# foreach my $key ( sort keys %gpsWaypointIcons ) {
# $gpswaypoint_line->move(
# $gpsWaypointIcons{$key}{"iconCenterXPdf"},
# $gpsWaypointIcons{$key}{"iconCenterYPdf"}
# );
# $gpswaypoint_line->line(
# $gpsWaypointIcons{$key}{"TextBoxX"},
# $gpsWaypointIcons{$key}{"TextBoxY"}
# );
# $gpswaypoint_line->strokecolor('blue');
# $gpswaypoint_line->stroke;
# }
# return;
# }

# sub drawLineFromNavaidToMatchedTextbox {

# #Draw a line from NAVAID icon to closest text boxes
# my $navaidLine = $page->gfx;

# foreach my $key ( sort keys %navaidIcons ) {
# $navaidLine->move(
# $navaidIcons{$key}{"iconCenterXPdf"},
# $navaidIcons{$key}{"iconCenterYPdf"}
# );
# $navaidLine->line( $navaidIcons{$key}{"TextBoxX"},
# $navaidIcons{$key}{"TextBoxY"} );
# $navaidLine->strokecolor('blue');
# $navaidLine->stroke;
# }
# return;
# }

# sub addObstaclesToGroundControlPoints {
# say "Obstacle Control Points" if $debug;
# #Add obstacles to Ground Control Points hash
# foreach my $key ( sort keys %unique_obstacles_from_db ) {
# next unless
# my $_pdfX = $unique_obstacles_from_db{$key}{"GeoreferenceX"};
# my $_pdfY = $unique_obstacles_from_db{$key}{"GeoreferenceY"};
# my $lon = $unique_obstacles_from_db{$key}{"Lon"};
# my $lat = $unique_obstacles_from_db{$key}{"Lat"};

# next unless ($_pdfX && $_pdfY && $lon && $lat);

# my $_rasterX = $_pdfX * $scaleFactorX;
# my $_rasterY = $pngYSize - ( $_pdfY * $scaleFactorY );

# if ( $_rasterX && $_rasterY && $lon && $lat ) {
# say "$_rasterX $_rasterY $lon $lat" if $debug;
# $gcps{ "obstacle" . $key }{"pngx"} = $_rasterX;
# $gcps{ "obstacle" . $key }{"pngy"} = $_rasterY;
# $gcps{ "obstacle" . $key }{"pdfx"} = $_pdfX;
# $gcps{ "obstacle" . $key }{"pdfy"} = $_pdfY;
# $gcps{ "obstacle" . $key }{"lon"}  = $lon;
# $gcps{ "obstacle" . $key }{"lat"}  = $lat;
# }
# }
# return;
# }

sub addCombinedHashToGroundControlPoints {
    my ( $type, $combinedHashRef ) = @_;

    #Add obstacles to Ground Control Points hash
    foreach my $key ( sort keys %$combinedHashRef ) {

        my $_pdfX = $combinedHashRef->{$key}{"GeoreferenceX"};
        my $_pdfY = $combinedHashRef->{$key}{"GeoreferenceY"};
        my $lon   = $combinedHashRef->{$key}{"Lon"};
        my $lat   = $combinedHashRef->{$key}{"Lat"};

        next unless ( $_pdfX && $_pdfY && $lon && $lat );

        my $_rasterX = $_pdfX * $scaleFactorX;
        my $_rasterY = $pngYSize - ( $_pdfY * $scaleFactorY );
        my $rand     = rand();
        if ( $_rasterX && $_rasterY && $lon && $lat ) {
            say "$_rasterX $_rasterY $lon $lat" if $debug;
            $gcps{ "$type" . $key . $rand }{"pngx"} = $_rasterX;
            $gcps{ "$type" . $key . $rand }{"pngy"} = $_rasterY;
            $gcps{ "$type" . $key . $rand }{"pdfx"} = $_pdfX;
            $gcps{ "$type" . $key . $rand }{"pdfy"} = $_pdfY;
            $gcps{ "$type" . $key . $rand }{"lon"}  = $lon;
            $gcps{ "$type" . $key . $rand }{"lat"}  = $lat;
        }
    }
    return;
}

# sub addFixesToGroundControlPoints {

# #Add fixes to Ground Control Points hash
# say ""                          if $debug;
# say "Fix Ground Control Points" if $debug;
# foreach my $key ( sort keys %fixIcons ) {

# #Using this to allow duplicate fixes to ground control points
# #Relying on our bad lat/lat or scaling tests to find bad matches (eg ones listed in Missed aproach holds etc)
# my $rand     = rand();
# my $_pdfX    = $fixIcons{$key}{"GeoreferenceX"};
# my $_pdfY    = $fixIcons{$key}{"GeoreferenceY"};
# my $_rasterX = $_pdfX * $scaleFactorX;
# my $_rasterY = $pngYSize - ( $_pdfY * $scaleFactorY );
# my $lon      = $fixIcons{$key}{"Lon"};
# my $lat      = $fixIcons{$key}{"Lat"};

# if ( $_rasterX && $_rasterY && $lon && $lat ) {
# say "$_rasterX ,  $_rasterY , $lon , $lat" if $debug;
# $gcps{ "fix" . $fixIcons{$key}{"Name"} . $rand }{"pngx"} =
# $_rasterX;
# $gcps{ "fix" . $fixIcons{$key}{"Name"} . $rand }{"pngy"} =
# $_rasterY;
# $gcps{ "fix" . $fixIcons{$key}{"Name"} . $rand }{"pdfx"} = $_pdfX;
# $gcps{ "fix" . $fixIcons{$key}{"Name"} . $rand }{"pdfy"} = $_pdfY;
# $gcps{ "fix" . $fixIcons{$key}{"Name"} . $rand }{"lon"}  = $lon;
# $gcps{ "fix" . $fixIcons{$key}{"Name"} . $rand }{"lat"}  = $lat;
# }
# }
# return;
# }

sub deleteBadGCPs {

    #Delete GCPs that are  inside an inset box
    foreach my $key ( sort keys %gcps ) {
        my $x = $gcps{$key}{"pdfx"};
        my $y = $gcps{$key}{"pdfy"};

        #say "testing $key $x $y";

        # print $poly->nrPoints;
        # my @p    = $poly->points;

        # my ($xmin, $ymin, $xmax, $ymax) = $poly->bbox;

        # my $area   = $poly->area;
        # my $l      = $poly->perimeter;
        # if($poly->isClockwise) { ... };

        # my $rot    = $poly->startMinXY;
        # my $center = $poly->centroid;
        # if($poly->contains($point)) { ... };

        # my $boxed  = $poly->lineClip($xmin, $xmax, $ymin, $ymax);
        foreach my $key2 ( sort keys %insetBoxes ) {

            #Get the edges of the box
            my $x1 = $insetBoxes{$key2}{"X"};
            my $x2 = $insetBoxes{$key2}{"X2"};
            my $y1 = $insetBoxes{$key2}{"Y"};
            my $y2 = $insetBoxes{$key2}{"Y2"};

            #say "$x1 $x2 $y1 $y2";

            #Is this point inside that box?  (This is flaky for now since it's dependent on how the box was drawn)
            if (
                # ( $x > $x1 && $x < $x2 )
                # ($x ~~ $x1..$x2)
                between( $x, $x1, $x2 )
                &&

                # ($y ~~ $y1..$y2)
                between( $y, $y1, $y2 )

                # && (   $y < $y1
                # && $y > $y2 )
              )
            {
                #Yes, delete it
                say "$key is inside inset box $key2. Removing from GCPs";
                delete $gcps{$key};
            }
        }
    }
    say "deleteBadGCPs";

    #Delete GCPs that are  inside an inset circle
    foreach my $key ( sort keys %gcps ) {

        my $x = $gcps{$key}{"pdfx"};
        my $y = $gcps{$key}{"pdfy"};

        #say "testing $key $x $y";
        foreach my $key2 ( sort keys %insetCircles ) {

            #Get the center of the circle
            my $x1         = $insetCircles{$key2}{"X"};
            my $y1         = $insetCircles{$key2}{"Y"};
            my $radius     = $insetCircles{$key2}{"radius"};
            my $hypotenuse = sqrt( ( $x - $x1 )**2 + ( $y - $y1 )**2 );

            #say $hypotenuse;
            #Is this point inside that circle?
            #TODO: Need to programatticaly figure out the radius of the insetCircles, this hardcoded number is cheating
            if (
                $hypotenuse < 15

                # between( $x, $x1, $x2 )
              )
            {
                #Yes, delete it
                say "$key is inside inset circle $key2. Removing from GCPs";
                delete $gcps{$key};
            }
        }
    }

    my ( $lowerYCutoff, $upperYCutoff ) = findHorizontalCutoff();
    say "lowerYCutoff: $lowerYCutoff, upperYCutoff: $upperYCutoff";

    # Delete GCPs above or below certain Y values (to be determined by horizontal lines
    foreach my $key ( sort keys %gcps ) {

        my $y = $gcps{$key}{"pdfy"};
        next unless $y;
        if ( $y < $lowerYCutoff ) {

            #Yes, delete it
            say "$key is below Y cutoff of $lowerYCutoff. Removing from GCPs";
            delete $gcps{$key};
        }
    }

    return;
}

# sub addNavaidsToGroundControlPoints {

# #Using this to allow duplicate navaids
# #Relying on our bad lat/lat or scaling tests to find bad matches (eg ones listed in Missed aproach holds etc)

# #Add navaids to Ground Control Points hash
# say ""                             if $debug;
# say "Navaid Ground Control Points" if $debug;
# foreach my $key ( sort keys %navaidIcons ) {
# my $rand     = rand();
# my $_pdfX    = $navaidIcons{$key}{"GeoreferenceX"};
# my $_pdfY    = $navaidIcons{$key}{"GeoreferenceY"};
# my $lon      = $navaidIcons{$key}{"Lon"};
# my $lat      = $navaidIcons{$key}{"Lat"};

# next unless ($_pdfX && $_pdfY && $lon && $lat);

# my $_rasterX = $_pdfX * $scaleFactorX;
# my $_rasterY = $pngYSize - ( $_pdfY * $scaleFactorY );

# if ( $_rasterX && $_rasterY && $lon && $lat ) {
# say "$_rasterX ,  $_rasterY , $lon , $lat" if $debug;
# $gcps{ "navaid" . $navaidIcons{$key}{"Name"} . $rand }{"pngx"} =
# $_rasterX;
# $gcps{ "navaid" . $navaidIcons{$key}{"Name"} . $rand }{"pngy"} =
# $_rasterY;
# $gcps{ "navaid" . $navaidIcons{$key}{"Name"} . $rand }{"pdfx"} =
# $_pdfX;
# $gcps{ "navaid" . $navaidIcons{$key}{"Name"} . $rand }{"pdfy"} =
# $_pdfY;
# $gcps{ "navaid" . $navaidIcons{$key}{"Name"} . $rand }{"lon"} =
# $lon;
# $gcps{ "navaid" . $navaidIcons{$key}{"Name"} . $rand }{"lat"} =
# $lat;
# }
# }
# return;
# }

# sub addGpsWaypointsToGroundControlPoints {

# #Add GPS waypoints to Ground Control Points hash
# say ""                                   if $debug;
# say "GPS waypoint Ground Control Points" if $debug;
# foreach my $key ( sort keys %gpsWaypointIcons ) {

# #Using this to allow duplicate waypoints
# #Relying on our bad lat/lat or scaling tests to find bad matches (eg ones listed in Missed aproach holds etc)

# my $rand = rand();
# my $_waypointRasterX =    $gpsWaypointIcons{$key}{"GeoreferenceX"} * $scaleFactorX;
# my $_waypointRasterY = $pngYSize -    ( $gpsWaypointIcons{$key}{"GeoreferenceY"} * $scaleFactorY );
# my $lon = $gpsWaypointIcons{$key}{"Lon"};
# my $lat = $gpsWaypointIcons{$key}{"Lat"};

# #Make sure all of these variables are defined before we use them as GCP
# if ( $_waypointRasterX && $_waypointRasterY && $lon && $lat ) {

# say "$_waypointRasterX , $_waypointRasterY , $lon , $lat" if $debug;
# $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} . $rand }{"pngx"} =
# $_waypointRasterX;
# $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} . $rand }{"pngy"} =
# $_waypointRasterY;
# $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} . $rand }{"pdfx"} =
# $gpsWaypointIcons{$key}{"GeoreferenceX"};
# $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} . $rand }{"pdfy"} =
# $gpsWaypointIcons{$key}{"GeoreferenceY"};
# $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} . $rand }{"lon"} =
# $lon;
# $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} . $rand }{"lat"} =
# $lat;
# }
# }
# return;
# }

sub createGcpString {
    my $_gcpstring = "";
    foreach my $key ( keys %gcps ) {

        #build the GCP portion of the command line parameters
        $_gcpstring =
            $_gcpstring
          . " -gcp "
          . $gcps{$key}{"pngx"} . " "
          . $gcps{$key}{"pngy"} . " "
          . $gcps{$key}{"lon"} . " "
          . $gcps{$key}{"lat"};
    }
    if ($debug) {
        say "Ground Control Points command line string";
        say $_gcpstring;
        say "";
    }
    return $_gcpstring;
}

# sub matchDatabaseResultsToIcons {

# #Updates unique_obstacles_from_db
# #Try to find closest obstacle icon to each text box for the obstacles in unique_obstacles_from_db
# foreach my $key ( sort keys %unique_obstacles_from_db ) {
# $unique_obstacles_from_db{$key}{"GeoreferenceX"} =
# $obstacleIcons{$key2}{"X"};
# $unique_obstacles_from_db{$key}{"GeoreferenceY"} =
# $obstacleIcons{$key2}{"Y"};

# foreach my $key2 ( keys %obstacleIcons ) {
# next
# unless ( ( $unique_obstacles_from_db{$key}{"TextBoxX"} )
# && ( $unique_obstacles_from_db{$key}{"TextBoxY"} )
# && ( $obstacleIcons{$key2}{"X"} )
# && ( $obstacleIcons{$key2}{"Y"} ) );

# $distance_to_closest_obstacle_icon_x =
# $unique_obstacles_from_db{$key}{"TextBoxX"} -
# $obstacleIcons{$key2}{"X"};

# $distance_to_closest_obstacle_icon_y =
# $unique_obstacles_from_db{$key}{"TextBoxY"} -
# $obstacleIcons{$key2}{"Y"};

# #Calculate the straight line distance between the text box center and the icon
# my $hyp = sqrt( $distance_to_closest_obstacle_icon_x**2 +
# $distance_to_closest_obstacle_icon_y**2 );

# if (   ( $hyp < $distance_to_closest_obstacle_icon )
# && ( $hyp < $maxDistanceFromObstacleIconToTextBox ) )
# {
# #Update the distance to the closest icon
# $distance_to_closest_obstacle_icon = $hyp;

# #Tie the parameters of that icon to our obstacle found in database
# $unique_obstacles_from_db{$key}{"ObsIconX"} =
# $obstacleIcons{$key2}{"X"};
# $unique_obstacles_from_db{$key}{"ObsIconY"} =
# $obstacleIcons{$key2}{"Y"};
# $unique_obstacles_from_db{$key}{"potentialTextBoxes"} =
# $obstacleIcons{$key2}{"potentialTextBoxes"};
# $unique_obstacles_from_db{$key}{"matchedTo"} = $key2;
# }

# }

# }

# if ($debug) {
# say
# "unique_obstacles_from_db before deleting entries with no ObsIconX or Y:";
# print Dumper ( \%unique_obstacles_from_db );
# say "";
# }
# return;
# }
# sub matchDatabaseResultsToIcons {

# #Updates unique_obstacles_from_db
# #Try to find closest obstacle icon to each text box for the obstacles in unique_obstacles_from_db
# foreach my $key ( sort keys %unique_obstacles_from_db ) {
# my $distance_to_closest_obstacle_icon_x;
# my $distance_to_closest_obstacle_icon_y;
# my $distance_to_closest_obstacle_icon = 999999999999;

# foreach my $key2 ( keys %obstacleIcons ) {
# next
# unless ( ( $unique_obstacles_from_db{$key}{"TextBoxX"} )
# && ( $unique_obstacles_from_db{$key}{"TextBoxY"} )
# && ( $obstacleIcons{$key2}{"X"} )
# && ( $obstacleIcons{$key2}{"Y"} ) );

# $distance_to_closest_obstacle_icon_x =
# $unique_obstacles_from_db{$key}{"TextBoxX"} -
# $obstacleIcons{$key2}{"X"};

# $distance_to_closest_obstacle_icon_y =
# $unique_obstacles_from_db{$key}{"TextBoxY"} -
# $obstacleIcons{$key2}{"Y"};

# #Calculate the straight line distance between the text box center and the icon
# my $hyp = sqrt( $distance_to_closest_obstacle_icon_x**2 +
# $distance_to_closest_obstacle_icon_y**2 );

# if (   ( $hyp < $distance_to_closest_obstacle_icon )
# && ( $hyp < $maxDistanceFromObstacleIconToTextBox ) )
# {
# #Update the distance to the closest icon
# $distance_to_closest_obstacle_icon = $hyp;

# #Tie the parameters of that icon to our obstacle found in database
# $unique_obstacles_from_db{$key}{"ObsIconX"} =
# $obstacleIcons{$key2}{"X"};
# $unique_obstacles_from_db{$key}{"ObsIconY"} =
# $obstacleIcons{$key2}{"Y"};
# $unique_obstacles_from_db{$key}{"potentialTextBoxes"} =
# $obstacleIcons{$key2}{"potentialTextBoxes"};
# $unique_obstacles_from_db{$key}{"matchedTo"} = $key2;
# }

# }

# }

# if ($debug) {
# say
# "unique_obstacles_from_db before deleting entries with no ObsIconX or Y:";
# print Dumper ( \%unique_obstacles_from_db );
# say "";
# }
# return;
# }
sub outlineValidFixTextBoxes {
    foreach my $key ( keys %fixTextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $fixes_from_db{ $fixTextboxes{$key}{"Text"} } ) {
            my $fix_box = $page->gfx;

            #Yes, draw an orange box around it
            $fix_box->rect(
                $fixTextboxes{$key}{"PdfX"},
                $fixTextboxes{$key}{"PdfY"} + 2,
                $fixTextboxes{$key}{"Width"},
                -( $fixTextboxes{$key}{"Height"} + 1 )
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

sub outlineValidNavaidTextBoxes {
    foreach my $key ( keys %vorTextboxes ) {

        #Is there a vorTextbox with the same text as our navaid?
        if ( exists $navaids_from_db{ $vorTextboxes{$key}{"Text"} } ) {
            my $navBox = $page->gfx;

            #Yes, draw an orange box around it
            $navBox->rect(
                $vorTextboxes{$key}{"PdfX"},
                $vorTextboxes{$key}{"PdfY"} + 2,
                $vorTextboxes{$key}{"Width"},
                -( $vorTextboxes{$key}{"Height"} + 1 )
            );
            $navBox->strokecolor('orange');
            $navBox->stroke;
        }
        else {
            #delete $fixTextboxes{$key};
        }
    }
    return;
}

# sub findClosestFixTextBoxToFixIcon {

# #Try to find closest fixtextbox to each fix icon
# foreach my $key ( sort keys %fixIcons ) {
# my $distance_to_closest_fixtextbox_x;
# my $distance_to_closest_fixtextbox_y;

# #Furthest radius to look for a matching textbox
# my $max_hyp = 40;

# #Initialize this to a very high number so everything is closer than it
# my $distance_to_closest_fixtextbox = 999999999999;
# foreach my $key2 ( keys %fixTextboxes ) {
# $distance_to_closest_fixtextbox_x =
# $fixTextboxes{$key2}{"CenterX"} - $fixIcons{$key}{"CenterX"};
# $distance_to_closest_fixtextbox_y =
# $fixTextboxes{$key2}{"CenterY"} - $fixIcons{$key}{"CenterY"};

# my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
# $distance_to_closest_fixtextbox_y**2 );

# #say "Hypotenuse: $hyp" if $debug;
# if (   ( $hyp < $distance_to_closest_fixtextbox )
# && ( $hyp < $max_hyp ) )
# {
# $distance_to_closest_fixtextbox = $hyp;
# $fixIcons{$key}{"Name"} = $fixTextboxes{$key2}{"Text"};
# $fixIcons{$key}{"TextBoxX"} = $fixTextboxes{$key2}{"CenterX"};
# $fixIcons{$key}{"TextBoxY"} = $fixTextboxes{$key2}{"CenterY"};
# $fixIcons{$key}{"Lat"} =
# $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lat"};
# $fixIcons{$key}{"Lon"} =
# $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lon"};
# }

# }

# }
# return;
# }

sub findHorizontalCutoff {
    my $_upperYCutoff = $pdfYSize;
    my $_lowerYCutoff = 0;

    #Find the highest purely horizonal line below the midpoint of the page
    foreach my $key ( sort keys %horizontalAndVerticalLines ) {

        my $yCoord = $horizontalAndVerticalLines{$key}{"Y"};

        if ( ( $yCoord > $_lowerYCutoff ) && ( $yCoord < .5 * $pdfYSize ) ) {

            $_lowerYCutoff = $yCoord;
        }
    }

    #Find the lowest purely horizonal line above the midpoint of the page
    foreach my $key ( sort keys %horizontalAndVerticalLines ) {

        my $yCoord = $horizontalAndVerticalLines{$key}{"Y"};

        if ( ( $yCoord < $_upperYCutoff ) && ( $yCoord > .5 * $pdfYSize ) ) {

            $_upperYCutoff = $yCoord;
        }
    }
    say "Returning $_upperYCutoff and $_lowerYCutoff  as horizontal cutoffs";
    return ( $_lowerYCutoff, $_upperYCutoff );
}

sub matchClosestNavaidTextBoxToNavaidIcon {

    #Try to find closest vorTextbox to each navaid icon
    foreach my $key ( sort keys %navaidIcons ) {
        my $distanceToClosestNavaidTextbox_X;
        my $distanceToClosestNavaidTextbox_Y;

        #Initialize this to a very high number so everything is closer than it
        my $distanceToClosestNavaidTextbox = 999999999999;
        foreach my $key2 ( keys %vorTextboxes ) {
            $distanceToClosestNavaidTextbox_X =
              $vorTextboxes{$key2}{"CenterX"} - $navaidIcons{$key}{"CenterX"};
            $distanceToClosestNavaidTextbox_Y =
              $vorTextboxes{$key2}{"CenterY"} - $navaidIcons{$key}{"CenterY"};

            my $hyp = sqrt( $distanceToClosestNavaidTextbox_X**2 +
                  $distanceToClosestNavaidTextbox_Y**2 );

            #The 27 here was chosen to make one particular sample work, it's not universally valid
            #Need to improve the icon -> textbox mapping
            #say "Hypotenuse: $hyp" if $debug;
            if ( ( $hyp < $distanceToClosestNavaidTextbox ) && ( $hyp < 135 ) )
            {
                $distanceToClosestNavaidTextbox = $hyp;
                $navaidIcons{$key}{"Name"} = $vorTextboxes{$key2}{"Text"};
                $navaidIcons{$key}{"TextBoxX"} =
                  $vorTextboxes{$key2}{"CenterX"};
                $navaidIcons{$key}{"TextBoxY"} =
                  $vorTextboxes{$key2}{"CenterY"};
                $navaidIcons{$key}{"Lat"} =
                  $navaids_from_db{ $navaidIcons{$key}{"Name"} }{"Lat"};
                $navaidIcons{$key}{"Lon"} =
                  $navaids_from_db{ $navaidIcons{$key}{"Name"} }{"Lon"};
            }

        }

    }
    return;
}

# sub deleteFixIconsWithNoName {

# #clean up fixicons
# #remove entries that have no name
# foreach my $key ( sort keys %fixIcons ) {
# if ( $fixIcons{$key}{"Name"} eq "none" )

# {
# delete $fixIcons{$key};
# }
# }

# if ($debug) {
# say "fixicons after deleting entries with no name";
# print Dumper ( \%fixIcons );
# say "";
# }
# return;
# }

# sub drawLineFromEachFixToClosestTextBox {

# #Draw a line from fix icon to closest text boxes
# my $fix_line = $page->gfx;
# $fix_line->strokecolor('blue');
# $fix_line->linewidth('.1');
# foreach my $key ( sort keys %fixIcons ) {
# $fix_line->move( $fixIcons{$key}{"CenterX"}, $fixIcons{$key}{"CenterY"} );
# $fix_line->line( $fixIcons{$key}{"TextBoxX"},
# $fixIcons{$key}{"TextBoxY"} );
# $fix_line->stroke;
# }
# return;
# }

sub outlineValidGpsWaypointTextBoxes {

    #Orange outline fixTextboxes that have a valid fix name in them
    #Delete fixTextboxes that don't have a valid nearby fix in them
    foreach my $key ( keys %fixTextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $gpswaypoints_from_db{ $fixTextboxes{$key}{"Text"} } ) {
            my $fix_box = $page->gfx;

            #Yes, draw an orange box around it
            $fix_box->rect(
                $fixTextboxes{$key}{"PdfX"},
                $fixTextboxes{$key}{"PdfY"} + 2,
                $fixTextboxes{$key}{"Width"},
                -( $fixTextboxes{$key}{"Height"} + 1 )
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

# sub countObstacleIconsWithOnePotentialTextbox {
    # my $_countOfObstaclesWithOnePotentialTextbox = 0;
    # foreach my $key ( sort keys %unique_obstacles_from_db ) {

        # if ( $unique_obstacles_from_db{$key}{"potentialTextBoxes"} == 1 ) {
            # $_countOfObstaclesWithOnePotentialTextbox++;
        # }
    # }

    # if ($debug) {
        # say
          # "$_countOfObstaclesWithOnePotentialTextbox Obtacles that have only 1 potentialTextBoxes";
    # }
    # return $_countOfObstaclesWithOnePotentialTextbox;
# }

# sub drawLineFromEachToUniqueObstaclesFromDbToClosestTextBox {

# #Draw a line from obstacle icon to closest text boxes
# #These will be what we use for GCPs
# my $obstacle_line = $page->gfx;
# $obstacle_line->strokecolor('blue');
# foreach my $key ( sort keys %unique_obstacles_from_db ) {
# $obstacle_line->move(
# $unique_obstacles_from_db{$key}{"ObsIconX"},
# $unique_obstacles_from_db{$key}{"ObsIconY"}
# );
# $obstacle_line->line(
# $unique_obstacles_from_db{$key}{"TextBoxX"},
# $unique_obstacles_from_db{$key}{"TextBoxY"}
# );
# $obstacle_line->stroke;
# }
# return;
# }

sub drawCircleAroundGCPs {
    foreach my $key ( sort keys %gcps ) {

        my $gcpCircle = $page->gfx;
        $gcpCircle->circle( $gcps{$key}{pdfx}, $gcps{$key}{pdfy}, 5 );
        $gcpCircle->strokecolor('green');
        $gcpCircle->linewidth(.05);
        $gcpCircle->stroke;

    }
    return;
}

# sub findIlsIcons {
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
# }

sub findAllTextboxes {
    say "";
    say ":findAllTextboxes" if $debug;

    #Get all of the text and respective bounding boxes in the PDF
    @pdfToTextBbox = qx(pdftotext $targetPdf -bbox - );
    $retval        = $? >> 8;
    die
      "No output from pdftotext -bbox.  Is it installed? Return code was $retval"
      if ( @pdfToTextBbox eq "" || $retval != 0 );

    #Find potential obstacle height textboxes
    findObstacleHeightTextBoxes();

    #Find textboxes that are valid for both fix and GPS waypoints
    findFixTextboxes();

    #Find textboxes that are valid for navaids
    findVorTextboxes();
    return;
}

sub matchBToA {
    my ( $iconHashRef, $textboxHashRef, $databaseHashRef ) = @_;
    my %hashOfMatchedPairs = ();
    my $key3               = 1;

    # say ":matchBToA$textboxHashRef to each $iconHashRef" if $debug;

    #start:
    foreach my $key ( sort keys %$iconHashRef ) {

        my $keyOfMatchedTextbox = $iconHashRef->{$key}{"MatchedTo"};

        next unless $keyOfMatchedTextbox;

        #Check that the "MatchedTo" textboxHashRef points back to this icon
        #Clear the match  for the iconHashRef if it doesn't

        if ( ( $textboxHashRef->{$keyOfMatchedTextbox}{"MatchedTo"} ne $key ) )
        {
            #Clear the icon's matching since it isn't reciprocated
            $iconHashRef->{$key}{"MatchedTo"} = "";

            #$textboxHashRef->{$keyOfMatchedTextbox}{"MatchedTo"} = "";
        }
        else {
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

            $hashOfMatchedPairs{$key3}{"GeoreferenceX"} = $georeferenceX;
            $hashOfMatchedPairs{$key3}{"GeoreferenceY"} = $georeferenceY;
            $hashOfMatchedPairs{$key3}{"Lat"}           = $lat;
            $hashOfMatchedPairs{$key3}{"Lon"}           = $lon;
            $hashOfMatchedPairs{$key3}{"Text"}          = $textOfMatchedTextbox;

            #delete $iconHashRef->{$key};
            #delete $textboxHashRef->{$keyOfMatchedTextbox};
            $key3++;

            #goto start;
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

    my $_line = $page->gfx;

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
