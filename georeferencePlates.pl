#!/usr/bin/perl

# GeoRerencePlates - a utility to automatically georeference FAA Instrument Approach Plates / Terminal Procedures
# Copyright (C) 2013  Jesse McGraw (jlmcgraw@gmail.com)
#
#You MAY NOT use the output of this program, or any modifed versions ,for commercial use without prior arrangement with the original author
#You MAY use the output in non-commercial applications


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
#-Relies on text being in PDF.  It seems that most, if not all, military plates have no text in them
#       We may be able to get around this with tesseract OCR but that will take some work
#
#Known issues:
#---------------------
#-Investigate not creating the intermediate PNG (guessing at dimensions)
#Our pixel/RealWorld ratios are hardcoded now for 300dpi, need to make dynamic per our DPI setting
#
#TODO
#Generate the text, text w/ bounding box, and pdfdump output once and re-use in future runs (like we're doing with the masks)
#Generate the mask bitmap totally in memory instead of via pdf->png
#
#Find some way to use the hint of the bubble icon for NAVAID names
#       Maybe find a line of X length within X radius of the textbox and see if it intersects with a navaid
#
#Integrate OCR so we can process miltary plates too
#       The miltary plates are not rendered the same as the civilian ones, it will require full on image processing to do those
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
use POSIX;

# use Math::Round;
use Time::HiRes q/gettimeofday/;
use Math::Polygon;
use Acme::Tools qw(between);
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
#Max allowed radius in PDF points from an icon (obstacle, fix, gps) to it's associated textbox's center
my $maxDistanceFromObstacleIconToTextBox = 20;

#DPI of the output PNG
my $pngDpi = 300;

#A hash to collect statistics
my %statistics = (
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
     '$upperLeftLon'                     => "0",
     '$upperLeftLat'                     => "0",
     '$lowerRightLon'                     => "0",
     '$lowerRightLat'                     => "0"

);

use vars qw/ %opt /;
my $opt_string = 'cspva:';
my $arg_num    = scalar @ARGV;

#This will fail if we receive an invalid option
unless ( getopts( "$opt_string", \%opt ) ) {
usage();
    exit(1);
}

#We need at least one argument (the name of the PDF to process)
if ( $arg_num < 1 ) {
usage();
    exit(1);
}

sub usage{
     say "Usage: $0 <pdf_file>";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
     say "-c Don't overwrite existing .vrt";
    
    }
my $debug                  = $opt{v};
my $shouldSaveMarkedPdf    = $opt{p};
my $shouldOutputStatistics = $opt{s};

#Get the airport ID in case we can't guess it from PDF (KSSC is an example)
my $airportId = $opt{a};

my $shouldOverwriteVrt = $opt{c};

#Get the target PDF file from command line options
my ($targetPdf) = $ARGV[0];

my $retval;

if ($airportId) {
    say "Supplied airport ID: $airportId";
}

#Say what our input PDF is
say $targetPdf;

#Pull out the various filename components of the input file from the command line
my ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

($airportId) = $filename =~ m/^\w\w-(\w\w\w)-/;


#Set some output file names based on the input filename
my $outputPdf         = $dir . "marked-" . $filename . ".pdf";
my $outputPdfOutlines = $dir . "outlines-" . $filename . ".pdf";
my $outputPdfRaw      = $dir . "raw-" . $filename . ".txt";
my $targetpng         = $dir . $filename . ".png";
my $gcpPng         = $dir . "gcp-" . $filename . ".png";
my $targettif         = $dir . $filename . ".tif";
my $targetvrt         = $dir . $filename . ".vrt";
my $targetStatistics  = "./statistics.csv";

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

$statistics{'$targetPdf'} = $targetPdf;

#This is a quick hack to abort if we've already created a .vrt for this plate
if ($shouldOverwriteVrt && -e $targetvrt){
say "$targetvrt exists, exiting";
exit(1)};

#Pull all text out of the PDF
my @pdftotext;
@pdftotext = qx(pdftotext $targetPdf  -enc ASCII7 -);
$retval    = $? >> 8;

if ( @pdftotext eq "" || $retval != 0 ) {
    say "No output from pdftotext.  Is it installed?  Return code was $retval";
    exit(1);
}
$statistics{'$pdftotext'} = scalar(@pdftotext);

if ( scalar(@pdftotext) < 5 ) {
    say "Not enough pdftotext output for $targetPdf";
    writeStatistics() if $shouldOutputStatistics;
    exit(1);
}

#Abort if the chart says it's not to scale
foreach my $line (@pdftotext) {
    $line =~ s/\s//gx;
    if ( $line =~ m/chartnott/i ) {
        say "$targetPdf not to scale, can't georeference";
        writeStatistics() if $shouldOutputStatistics;
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
# #Some regex building blocks to be used elsewhere
#numbers that start with 1-9 followed by 2 or more digits
my $obstacleHeightRegex = qr/[1-9]\d{1,}/x;

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
my ($lineRegex)          = qr/$numberRegex\s+$numberRegex\s+l/x;
my ($lineRegexCaptureXY) = qr/($numberRegex)\s+($numberRegex)\s+l/x;

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

# my $obstacleCount = 0;

my %fixIcons = ();

# my $fixCount = 0;

my %gpsWaypointIcons = ();

# my $gpsCount         = 0;

my %navaidIcons = ();

# my $navaidCount = 0;

# my %finalApproachFixIcons = ();
# my $finalApproachFixCount = 0;

# my %visualDescentPointIcons = ();
# my $visualDescentPointCount = 0;

my %horizontalAndVerticalLines = ();

# my $horizontalAndVerticalLinesCount = 0;

my %insetBoxes = ();

# my $insetBoxesCount = 0;

my %largeBoxes = ();

# my $largeBoxesCount = 0;

my %insetCircles = ();

# my $insetCirclesCount = 0;

my %notToScaleIndicator = ();

# my $notToScaleIndicatorCount = 0;

# #Get number of objects/streams in the targetpdf
my $objectstreams = getNumberOfStreams();

# #Loop through each of the streams in the PDF and find all of the icons we're interested in
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
# findHorizontalLines($$rawPdf);
# findInsetBoxes($$rawPdf);
# findLargeBoxes($$rawPdf);
# findInsetCircles($$rawPdf);
# findNotToScaleIndicator($$rawPdf);

#Find navaids near the airport
my %navaids_from_db = ();
findNavaidsNearAirport();

my @validNavaidNames = keys %navaids_from_db;
my $validNavaidNames = join( " ", @validNavaidNames );

my @pdfToTextBbox     = ();
my %fixTextboxes      = ();
my %obstacleTextBoxes = ();
my %vorTextboxes      = ();
#
findAllTextboxes();

#----------------------------------------------------------------------------------------------------------
#Modify the PDF
#Don't do anything PDF related unless we've asked to create one on the command line

my ( $pdf, $page );

if ($shouldSaveMarkedPdf) {
    $pdf = PDF::API2->open($targetPdf);

    #Set up the various types of boxes to draw on the output PDF
    $page = $pdf->openpage(1);

    #Draw boxes around the icons and textboxes we've found so far
    outlineEverythingWeFound();
}

my ( $pdfOutlines,  $pageOutlines );
my ( $lowerYCutoff, $upperYCutoff );

#Don't recreate the outlines PDF if it already exists

if ( !-e $outputPdfOutlines ) {

    #Make our masking PDF

    $pdfOutlines = PDF::API2->new();

    #Set up the various types of boxes to draw on the output PDF
    $pageOutlines = $pdfOutlines->page();

    # Set the page size
    $pageOutlines->mediabox( $pdfXSize, $pdfYSize );
    ( $lowerYCutoff, $upperYCutoff ) = findHorizontalCutoff();

    #Draw black lines and boxes around the icons and textboxes we've found so far
    outlines();

    #and save to a PDF to use for a mask
    $pdfOutlines->saveas($outputPdfOutlines);
}

#---------------------------------------------------
#Convert the outlines PDF to a PNG
#TODO Let's make this a uncompressed mono bitmap so we can save the output to an array
#qx(pdftoppm -png -mono -r $pngDpi $outputPdfOutlines > $outputPdfOutlines.png);
# my $halfPngX1 = $pngXSize / 2 + 5;
# my $halfPngY1 = $pngYSize / 2 + 5;
# my $halfPngX2 = $pngXSize / 2 - 5;
# my $halfPngY2 = $pngXSize / 2 - 5;

#Do a flood fill on that png with starting points around the middle
# qx(convert $outputPdfOutlines.png -fill black -draw 'color $halfPngX1,$halfPngY1 floodfill' $outputPdfOutlines.png);
# qx(convert $outputPdfOutlines.png -fill black -draw 'color $halfPngX2,$halfPngY2 floodfill' $outputPdfOutlines.png);

#testing out using perlMagick
my ( $image, $perlMagickStatus );
$image = Image::Magick->new;

if ( !-e "$outputPdfOutlines.png" ) {

    #If the masking PNG doesn't already exist, read in the outlines PDF, floodfill and then save

    #Read in the .pdf maskfile
    # $image->Set(units=>'1');
    $image->Set( units      => 'PixelsPerInch' );
    $image->Set( density    => '300' );
    $image->Set( depth      => 1 );
    $image->Set( background => 'white' );
    $image->Set( alpha      => 'off' );
    $perlMagickStatus = $image->Read("$outputPdfOutlines");

    #Now do two fills from just around the middle of the inner box, just in case there's something in the middle of the box blocking the fill
    #I've only seen this be an issue once
    # $image->Draw(primitive=>'color',method=>'Replace',fill=>'black',x=>1,y=>1,color => 'black');
    $image->Set( depth      => 1 );
    $image->Set( background => 'white' );
    $image->Set( alpha      => 'off' );
    $image->ColorFloodfill(
        fill        => 'black',
        x           => $pngXSize / 2 - 50,
        y           => $pngYSize / 2 - 50,
        bordercolor => 'black'
    );
    $image->ColorFloodfill(
        fill        => 'black',
        x           => $pngXSize / 2 + 50,
        y           => $pngYSize / 2 + 50,
        bordercolor => 'black'
    );

    #Write out to a .png do we don't have to do this work again
    $perlMagickStatus = $image->write("$outputPdfOutlines.png");
    warn "$perlMagickStatus" if "$perlMagickStatus";
}
else {
    # $image->Set( units      => 'PixelsPerInch' );
    # $image->Set( density    => '300' );
    # $image->Set( depth      => 1 );
    # $image->Set( background => 'white' );
    # $image->Set( alpha      => 'off' );

    #Use the already created mask image
    $perlMagickStatus = $image->Read("$outputPdfOutlines.png");
    warn "$perlMagickStatus" if "$perlMagickStatus";
}

# $image->Draw(primitive=>'rectangle',method=>'Floodfill',fill=>'black',points=>"$halfPngX1,$halfPngY1,5,100",color=>'black');
# $image->Draw(fill=>'black',points=>'$halfPngX2,$halfPngY2',floodfill=>'yes',color => 'black');
#warn "$perlMagickStatus" if "$perlMagickStatus";
#Uncomment these lines to write out the mask file so you can see what it looks like
#Black pixel represent areas to keep, what is what to ignore
# $perlMagickStatus = $image->Write("$outputPdfOutlines.png");
# warn "$perlMagickStatus" if "$perlMagickStatus";

#We should eliminate icons and textboxes here

#----------------------------------------------------------------------------------------------------------------------------------
#Everything to do with obstacles
#Get a list of unique potential obstacle heights from the pdftotext array
#my @obstacle_heights = findObstacleHeightTexts(@pdftotext);
my @obstacle_heights = testfindObstacleHeightTexts(@pdfToTextBbox);

#Find all obstacles within our defined distance from the airport that have a height in the list of potential obstacleTextBoxes and are unique
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
  joinIconTextboxAndDatabaseHashes( \%obstacleIcons, \%obstacleTextBoxes,
    \%unique_obstacles_from_db );

if ($debug) {
    say "matchedObstacleIconsToTextBoxes";
    print Dumper ($matchedObstacleIconsToTextBoxes);
}

#Draw a line from obstacle icon to closest text boxes
drawLineFromEachIconToMatchedTextBox( \%obstacleIcons, \%obstacleTextBoxes )
  if $shouldSaveMarkedPdf;

outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb()
  if $shouldSaveMarkedPdf;

#------------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with fixes
#
#Find fixes near the airport
#Updates %fixes_from_db
my %fixes_from_db = ();
findFixesNearAirport();

#Orange outline fixTextboxes that have a valid fix name in them
outlineValidFixTextBoxes() if $shouldSaveMarkedPdf;

#Delete an icon if the squiggly is too close to it
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

# drawLineFromEachFixToClosestTextBox() if $shouldSaveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with GPS waypoints
#
#Find GPS waypoints near the airport
my %gpswaypoints_from_db = ();
findGpsWaypointsNearAirport();

#Orange outline fixTextboxes that have a valid GPS waypoint name in them
outlineValidGpsWaypointTextBoxes() if $shouldSaveMarkedPdf;

#Delete an icon if the squiggly is too close to it
say 'findClosestSquigglyToA( \%gpsWaypointIcons,     \%notToScaleIndicator )'
  if $debug;
findClosestSquigglyToA( \%gpsWaypointIcons, \%notToScaleIndicator );

#Try to find closest TextBox center to each Icon center and then do the reverse
say 'findClosestBToA( \%gpsWaypointIcons, \%fixTextboxes )' if $debug;
findClosestBToA( \%gpsWaypointIcons, \%fixTextboxes );

say 'findClosestBToA( \%fixTextboxes,     \%gpsWaypointIcons )' if $debug;
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

drawLineFromEachIconToMatchedTextBox( \%gpsWaypointIcons, \%fixTextboxes )
  if $shouldSaveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with navaids
#

#Orange outline navaid textboxes that have a valid navaid name in them
outlineValidNavaidTextBoxes() if $shouldSaveMarkedPdf;

#Delete an icon if the squiggly is too close to it
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
my %gcps = ();

#Add Obstacles to Ground Control Points hash
addCombinedHashToGroundControlPoints( "obstacle",
    $matchedObstacleIconsToTextBoxes );

#Add Fixes to Ground Control Points hash
addCombinedHashToGroundControlPoints( "fix", $matchedFixIconsToTextBoxes );

#Add Navaids to Ground Control Points hash
addCombinedHashToGroundControlPoints( "navaid",
    $matchedNavaidIconsToTextBoxes );

#Add GPS waypoints to Ground Control Points hash
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

#Remove GCPs which are inside insetBoxes or outside the horizontal bounds
#Commented out since we're using  image mask code now
#deleteBadGCPs();

# $gcpCount = scalar( keys(%gcps) );
# say "Using $gcpCount Ground Control Points" if $debug;

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

#Can't do anything if we didn't find any valid ground control points
if ( $gcpCount < 2 ) {
    say "Didn't find 2 or more ground control points in $targetPdf";

    writeStatistics() if $shouldOutputStatistics;
    exit(1);
}

#----------------------------------------------------------------------------------------------------------------------------------------------------
#Now some math
my ( @xScaleAvg, @yScaleAvg, @ulXAvg, @ulYAvg, @lrXAvg, @lrYAvg ) = ();

#Print a header so you could paste the following output into a spreadsheet to analyze
say
  '$object1,$object2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2'
  if $debug;

#Calculate the rough X and Y scale values
if ( $gcpCount == 1 ) {

    #Is it better to guess or do nothing?  I think we should do nothing
    #calculateRoughRealWorldExtentsOfRasterWithOneGCP();
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

if ( @xScaleAvg && @yScaleAvg ) {

    #Smooth out the X and Y scales we previously calculated
    calculateSmoothedRealWorldExtentsOfRaster();

    #Actually produce the georeferencing data via GDAL
    georeferenceTheRaster();

    #Count of entries in this array
    my $xScaleAvgSize = @xScaleAvg;

    #Count of entries in this array
    my $yScaleAvgSize = @yScaleAvg;

    #Save statistics
    $statistics{'$xAvg'}          = $xAvg;
    $statistics{'$xMedian'}       = $xMedian;
    $statistics{'$xScaleAvgSize'} = $xScaleAvgSize;
    $statistics{'$yAvg'}          = $yAvg;
    $statistics{'$yMedian'}       = $yMedian;
    $statistics{'$yScaleAvgSize'} = $yScaleAvgSize;
    $statistics{'$lonLatRatio'} = $lonLatRatio;
}
else {
    say "No points actually added to the scale arrays for $targetPdf";
}

#Write out the statistics of this file if requested
writeStatistics() if $shouldOutputStatistics;

#Since we've calculated our extents, try drawing some features on the outputPdf to see if they align
#With our work
drawFeaturesOnPdf() if $shouldSaveMarkedPdf;

# #Save our new PDF since we're done with it
# if ($shouldSaveMarkedPdf) {
# $pdf->saveas($outputPdf);
# }

#Close the database
$sth->finish();
$dbh->disconnect();

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------
sub drawFeaturesOnPdf {


    if ( -e "$targetpng" ) {
    #say $airportLatitudeDec;
    my $y1 = latitudeToPixel($airportLatitudeDec) - 2;
    my $x1 = longitudeToPixel($airportLongitudeDec) -2 ; 
    my $x2 = $x1 + 4;
    my $y2 = $y1 + 4;
    my ( $image, $perlMagickStatus );
    $image = Image::Magick->new;
    
        $perlMagickStatus = $image->Read("$targetpng");
 warn $perlMagickStatus if $perlMagickStatus;
        # $image->Draw(
            # fill        => 'red',
            # x           => $x1,
            # y           => $y1,
            # stroke      => 'red',
            # strokewidth => '50',
            # primitive   => 'circle',
            # opacity     => '100'

        # );

        # $image->Draw(primitive=>'RoundRectangle',fill=>'blue',stroke=>'maroon',
        # strokewidth=>4,points=>"$x1,$y1 30,30 10,10");

        $image->Draw(primitive=>'circle',
                                        stroke=>'none',
                                        fill=>'green',
                                        points=>"$x1,$y1 $x2,$y2",
                                        alpha=>'100');

        # $image->Draw(
            # primitive   => 'line',
            # stroke      => 'none',
            # fill        => 'yellow',
            # points      => "$x1,$y1 $x2,$y2",
            # strokewidth => '50',
            # alpha       => '100'
        # );
       

        foreach my $key ( sort keys %gcps ) {

            my $lon = $gcps{$key}{"lon"};
            my $lat = $gcps{$key}{"lat"};
            my $y1  = latitudeToPixel($lat) - 1;
            my $x1  = longitudeToPixel($lon) - 1;
            my $x2  = $x1 + 2;
            my $y2  = $y1 + 2;
            $image->Draw(
                                primitive => 'circle',
                                stroke    => 'none',
                                fill      => 'red',
                                points    => "$x1,$y1 $x2,$y2",
                                alpha     => '100'            );

        }
         $perlMagickStatus = $image->write("$gcpPng");
        warn $perlMagickStatus if $perlMagickStatus;
        return;
    }
}

sub latitudeToPixel {
    my ($_latitude) = @_;
    # say $_latitude;
    #say "$ulYmedian, $yMedian";
    my $_pixel = abs( ( $ulYmedian - $_latitude ) / $yMedian );
    #say "$_latitude to $_pixel";

    return $_pixel;
}

sub longitudeToPixel {
    my ($_longitude) = @_;
    # say $_longitude;
    #say "$ulXmedian, $xMedian";
    my $_pixel = abs( ( $ulXmedian - $_longitude ) / $xMedian );
    #say "$_longitude to $_pixel";

    return $_pixel;
}

sub findObstacleHeightTexts {

    #The text from the PDF
    my @_pdftotext = @_;
    my @_obstacle_heights;

    foreach my $line (@_pdftotext) {

        #Find numbers that match our obstacle height regex
        if ( $line =~ m/^($obstacleHeightRegex)$/ ) {

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
            m/xMin="[\d\.]+" yMin="[\d\.]+" xMax="[\d\.]+" yMax="[\d\.]+">($obstacleHeightRegex)</
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
              "You must specify an airport ID (eg. -a SMF) since there was no info found in $targetPdf";
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
              "No airport coordinate information found in $targetPdf  or database, try   -a <airport> ";
            exit(1);
        }

    }

    #Save statistics
    $statistics{'$airportLatitude'}  = $_airportLatitudeDec;
    $statistics{'$airportLongitude'} = $_airportLongitudeDec;

    return ( $_airportLatitudeDec, $_airportLongitudeDec );
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

    #Calculate the raster size ourselves
    my $_pngXSize = ceil( ( $pdfXSize / 72 ) * $pngDpi );
    my $_pngYSize = ceil( ( $pdfYSize / 72 ) * $pngDpi );

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
    my $_scaleFactorX = $_pngXSize / $pdfXSize;
    my $_scaleFactorY = $_pngYSize / $pdfYSize;
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
        $lines->strokecolor('yellow');
        $lines->linewidth(5);
        $lines->move(
            $horizontalAndVerticalLines{$key}{"X"},
            $horizontalAndVerticalLines{$key}{"Y"}
        );
        $lines->line(
            $horizontalAndVerticalLines{$key}{"X2"},
            $horizontalAndVerticalLines{$key}{"Y2"}
        );

        $lines->stroke;
    }
    foreach my $key ( sort keys %insetBoxes ) {

        my ($insetBox) = $page->gfx;
        $insetBox->strokecolor('cyan');
        $insetBox->linewidth(.1);
        $insetBox->rect(
            $insetBoxes{$key}{X},
            $insetBoxes{$key}{Y},
            $insetBoxes{$key}{Width},
            $insetBoxes{$key}{Height},

        );

        $insetBox->stroke;
    }
    foreach my $key ( sort keys %largeBoxes ) {

        my ($largeBox) = $page->gfx;
        $largeBox->strokecolor('yellow');
        $largeBox->linewidth(5);
        $largeBox->rect(
            $largeBoxes{$key}{X},     $largeBoxes{$key}{Y},
            $largeBoxes{$key}{Width}, $largeBoxes{$key}{Height},
        );

        $largeBox->stroke;
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
        $fixTextBox->strokecolor('red');
        $fixTextBox->linewidth(1);
        $fixTextBox->rect(
            $fixTextboxes{$key}{"CenterX"} -
              ( $fixTextboxes{$key}{"Width"} / 2 ),
            $fixTextboxes{$key}{"CenterY"} -
              ( $fixTextboxes{$key}{"Height"} / 2 ),
            $fixTextboxes{$key}{"Width"},
            $fixTextboxes{$key}{"Height"}
        );

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
            $vorTextboxes{$key}{"CenterY"} +
              ( $vorTextboxes{$key}{"Height"} / 2 ),
            $vorTextboxes{$key}{"Width"},
            -( $vorTextboxes{$key}{"Height"} )
        );
        $navaidTextBox->strokecolor('red');
        $navaidTextBox->linewidth(1);
        $navaidTextBox->stroke;
    }
    foreach my $key ( sort keys %notToScaleIndicator ) {
        my ($navaidTextBox) = $page->gfx;
        $navaidTextBox->rect(
            $notToScaleIndicator{$key}{"CenterX"},
            $notToScaleIndicator{$key}{"CenterY"},
            4, 10
        );
        $navaidTextBox->strokecolor('red');
        $navaidTextBox->linewidth(1);
        $navaidTextBox->stroke;
    }
    return;
}

sub calculateXScale {
    my ($targetArrayRef) = @_;
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
    return ( $xAvg, $xMedian, $xStdDev );
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
    if ($debug) {
        say "Remove data outside 1st standard deviation";
        say
          "Lower Right X: average:  $lrXAvrg\tstdev: $lrXStdDev\tmedian: $lrXmedian";
    }
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

        # findGpsWaypointIcons($_output);
        findGpsWaypointIcons($_output);
        findNavaidIcons($_output);

        #findFinalApproachFixIcons($_output);
        #findVisualDescentPointIcons($_output);
        findHorizontalLines($_output);
        findInsetBoxes($_output);
        findLargeBoxes($_output);
        findInsetCircles($_output);
        findNotToScaleIndicator($_output);

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
    # }

    return;
}

sub returnRawPdf {

    #Returns the raw commands of a PDF
    say ":returnRawPdf" if $debug;
    my ($_output);

    if ( -e $outputPdfRaw ) {

        #If the raw output already exists just read it and return
        $_output = read_file($outputPdfRaw);
    }
    else {
        #create, save for future use, and return raw PDF outputPdf
        open( my $fh, '>', $outputPdfRaw )
          or die "Could not open file '$outputPdfRaw' $!";

        #Get number of objects/streams in the targetpdf
        my $_objectstreams = getNumberOfStreams();

        #Loop through each "stream" in the pdf and get the raw commands
        for ( my $i = 0 ; $i < ( $_objectstreams - 1 ) ; $i++ ) {
            $_output = $_output . qx(mutool show $targetPdf $i x);
            $retval  = $? >> 8;
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

sub findObstaclesInDatabase {

    # my $radius     = ".2";
    my $minimumAgl = "0";

    #How far away from the airport to look for feature
    my $radiusNm = 20;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport

    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      ( $radiusNm / 60 ) / cos( deg2rad($airportLatitudeDec) );

    #---------------------------------------------------------------------------------------------------------------------------------------------------
    #Find obstacles with a certain height in the database

    foreach my $heightmsl (@obstacle_heights) {

        #@obstacle_heights only contains unique potential heights mentioned on the plate
        #Query the database for obstacles of $heightmsl within our $radius
        $sth = $dbh->prepare(
            "SELECT * FROM obstacles WHERE 
                                       (HeightMsl=$heightmsl) and 
                                       (HeightAgl > $minimumAgl) and 
                                       (Latitude >  $airportLatitudeDec - $radiusDegreesLatitude ) and 
                                       (Latitude < $airportLatitudeDec +$radiusDegreesLatitude ) and 
                                       (Longitude >  $airportLongitudeDec - $radiusDegreesLongitude ) and 
                                       (Longitude < $airportLongitudeDec +$radiusDegreesLongitude )"
        );
        $sth->execute();

        my $all  = $sth->fetchall_arrayref();
        my $rows = $sth->rows();
        say "Found $rows objects of height $heightmsl" if $debug;

        #This may be complete shit but I'm testing the theory that if an obstacle is mentioned only once on the PDF that even if that height is not unique in the real world within the bounding box
        #that the designer is going to show the one that's closest to the airport.  I could be totally wrong here and am probably causing more mismatches than I'm solving
        my $bestDistanceToAirport = 9999;
        foreach my $row (@$all) {
            my ( $lat, $lon, $heightmsl, $heightagl ) = @$row;
            my $distanceToAirport =
              sqrt( ( $lat - $airportLatitudeDec )**2 +
                  ( $lon - $airportLongitudeDec )**2 );

            #say    "current distance $distanceToAirport, best distance for object of height $heightmsl msl is now $bestDistanceToAirport";
            next if ( $distanceToAirport > $bestDistanceToAirport );

            $bestDistanceToAirport = $distanceToAirport;

            #say "closest distance for object of height $heightmsl msl is now $bestDistanceToAirport";

            $unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
            $unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
        }

        # #Don't show results of searches that have more than one result, ie not unique
        # next if ( $rows != 1 );

        # foreach my $row (@$all) {

        # #Populate variables from our database lookup
        # my ( $lat, $lon, $heightmsl, $heightagl ) = @$row;
        # foreach my $pdf_obstacle_height (@obstacle_heights) {
        # if ( $pdf_obstacle_height == $heightmsl ) {
        # $unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
        # $unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
        # }
        # }
        # }

    }

    #How many obstacles with unique heights did we find
    $unique_obstacles_from_dbCount = keys(%unique_obstacles_from_db);

    #Save statistics
    $statistics{'$unique_obstacles_from_dbCount'} =
      $unique_obstacles_from_dbCount;

    if ($debug) {
        say
          "Found $unique_obstacles_from_dbCount OBSTACLES with unique heights within $radiusNm nm of airport from database";
        say "unique_obstacles_from_db:";
        print Dumper ( \%unique_obstacles_from_db );
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
^$lineRegexCaptureXY$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$lineRegexCaptureXY$
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
^$lineRegexCaptureXY$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$lineRegexCaptureXY$
^$bezierCurveRegex$
^$bezierCurveRegex$
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
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            $gpsWaypointIcons{ $i . $rand }{"CenterX"}       = $x + $xOffset;
            $gpsWaypointIcons{ $i . $rand }{"CenterY"}       = $y + $yOffset;
            $gpsWaypointIcons{ $i . $rand }{"Width"}         = $width;
            $gpsWaypointIcons{ $i . $rand }{"Height"}        = $height;
            $gpsWaypointIcons{ $i . $rand }{"GeoreferenceX"} = $x + $xOffset;
            $gpsWaypointIcons{ $i . $rand }{"GeoreferenceY"} = $y + $yOffset;
            $gpsWaypointIcons{ $i . $rand }{"Type"}          = "gps";

            # $gpsWaypointIcons{$i}{"Name"} = "none";
        }

    }

    my $gpsCount = keys(%gpsWaypointIcons);

    #Save statistics
    $statistics{'$gpsCount'} = $gpsCount;
    if ($debug) {
        print "$merged_count GPS ";

    }
    return;
}

#--------------------------------------------------------------------------------------------------------------------------------------
sub findNavaidIcons {

    #TODO Add VOR icon, see IN-ASW-ILS-OR-LOC-DME-RWY-27.pdf_obstacle_height
    #I'm going to lump finding all of the navaid icons into here for now
    #Before I clean it up
    my ($_output) = @_;

    #REGEX building blocks

    #Find VOR icons
    #Change the 3rd line here back to just a lineRegex if there are problems with finding vortacs
    my $vortacRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
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

    my $vortacRegex2 = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
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

    my $vortacRegex3 = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
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
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
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
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
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
            #Could use $length/2 here for X center offset
            $navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x + 2;
            $navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y - 3;
            $navaidIcons{ $i . $rand }{"CenterX"}       = $x + 2;
            $navaidIcons{ $i . $rand }{"CenterY"}       = $y - 3;
            $navaidIcons{ $i . $rand }{"Width"}         = $width;
            $navaidIcons{ $i . $rand }{"Height"}        = $height;

            # $navaidIcons{ $i . $rand }{"Name"}           = "none";
            $navaidIcons{ $i . $rand }{"Type"} = "VORTAC";
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

            $navaidIcons{ $i . $rand }{"CenterX"}       = $x + $width / 2;
            $navaidIcons{ $i . $rand }{"CenterY"}       = $y + $height / 2;
            $navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x + $width / 2;
            $navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y + $height / 2;
            $navaidIcons{ $i . $rand }{"Width"}         = $width;
            $navaidIcons{ $i . $rand }{"Height"}        = $height;
            $navaidIcons{ $i . $rand }{"Type"}          = "VOR/DME";
        }

    }

    #Re-run for NDB
    my $ndbRegex = qr/^$transformCaptureXYRegex$
^0 0 m$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^f\*$
^Q$
^$numberRegex w $
^$transformNoCaptureXYRegex$
^0 0 m$
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

    my $ndbRegex2 = qr/^$transformCaptureXYRegex$
^0 0 m$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^$bezierCurveRegex$
^f\*$
^Q$
^$transformNoCaptureXYRegex$
^0 0 m$
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

            #TODO Test that the length of the first line is less than ~6 (one sample value is 3.17, so that's plenty of margin)
            my $x = $merged[$i];
            my $y = $merged[ $i + 1 ];

            # my $length = $merged[ $i + 2 ];
            my $height = 10;
            my $width  = 10;

            # next if ( $length > 6 || $length < 1 );

            #put them into a hash
            #TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            #Could use $length/2 here for X center offset
            $navaidIcons{ $i . $rand }{"GeoreferenceX"} = $x;
            $navaidIcons{ $i . $rand }{"GeoreferenceY"} = $y;
            $navaidIcons{ $i . $rand }{"CenterX"}       = $x;
            $navaidIcons{ $i . $rand }{"CenterY"}       = $y;
            $navaidIcons{ $i . $rand }{"Width"}         = $width;
            $navaidIcons{ $i . $rand }{"Height"}        = $height;
            $navaidIcons{ $i . $rand }{"Type"}          = "ndb";
        }

    }

    my $navaidCount = keys(%navaidIcons);

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
    my $insetBoxRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
^$numberRegex\s+$numberRegex\s+l$
^0\s+($numberRegex)\s+l$
^0\s+0\s+l$
^S$
^Q$/m;

    #A series of 2 lines (iow: part of a box)
    my $halfBoxRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
^$numberRegex\s+($numberRegex)\s+l$
^S$
^Q$/m;

    #A series of 3 lines (iow: part of a box)
    my $almostBoxRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex)\s+0\s+l$
^$numberRegex\s+($numberRegex)\s+l$
^0\s+$numberRegex\s+l$
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
            $insetBoxes{ $i . $random }{"X"}      = $x;
            $insetBoxes{ $i . $random }{"Y"}      = $y;
            $insetBoxes{ $i . $random }{"X2"}     = $x + $width;
            $insetBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $insetBoxes{ $i . $random }{"Width"}  = $width;
            $insetBoxes{ $i . $random }{"Height"} = $height;
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
            $insetBoxes{ $i . $random }{"X"}      = $x;
            $insetBoxes{ $i . $random }{"Y"}      = $y;
            $insetBoxes{ $i . $random }{"X2"}     = $x + $width;
            $insetBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $insetBoxes{ $i . $random }{"Width"}  = $width;
            $insetBoxes{ $i . $random }{"Height"} = $height;
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
            $insetBoxes{ $i . $random }{"X"}      = $x;
            $insetBoxes{ $i . $random }{"Y"}      = $y;
            $insetBoxes{ $i . $random }{"X2"}     = $x + $width;
            $insetBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $insetBoxes{ $i . $random }{"Width"}  = $width;
            $insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    $insetBoxCount = keys(%insetBoxes);

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

            #Let's only save large boxes
            #  say "$height $pdfYSize $width $pdfXSize";
            next
              if ( ( abs($height) < ( $pdfYSize / 2 ) )
                || ( abs($width) < ( $pdfXSize / 2 ) ) );

            #put them into a hash
            $largeBoxes{ $i . $random }{"X"}      = $x;
            $largeBoxes{ $i . $random }{"Y"}      = $y;
            $largeBoxes{ $i . $random }{"X2"}     = $x + $width;
            $largeBoxes{ $i . $random }{"Y2"}     = $y + $height;
            $largeBoxes{ $i . $random }{"Width"}  = $width;
            $largeBoxes{ $i . $random }{"Height"} = $height;
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
^($numberRegex\s+)(?:$numberRegex\s+){5}c$
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
            $insetCircles{ $i . $random }{"X"}      = $x - $width / 2;
            $insetCircles{ $i . $random }{"Y"}      = $y;
            $insetCircles{ $i . $random }{"Radius"} = $width / 2;

            # $insetBoxes{ $i . $random }{"X2"} = $x + $width;

            # $insetBoxes{ $i . $random }{"Y2"} = $y + $height;

            # $insetBoxes{ $i . $random }{"Width"} = $width;

            # $insetBoxes{ $i . $random }{"Height"} = $height;
        }

    }

    $insetCircleCount = keys(%insetCircles);

    #Save statistics
    $statistics{'$insetCircleCount'} = $insetCircleCount;

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
^$originRegex$
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
            next if ( abs( $tempHorizontalLine[ $i + 2 ] ) < 5 );

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

    #A purely vertical line
    my $verticalLineRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^0\s+($numberRegex)\s+l$
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
            $horizontalAndVerticalLines{ $i . $random }{"X"}  = $x;
            $horizontalAndVerticalLines{ $i . $random }{"Y"}  = $y;
            $horizontalAndVerticalLines{ $i . $random }{"X2"} = $x;
            $horizontalAndVerticalLines{ $i . $random }{"Y2"} = $y + $y2;
        }

    }

    my $horizontalAndVerticalLinesCount = keys(%horizontalAndVerticalLines);

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

    my $obstacleCount = keys(%obstacleIcons);

    #Save statistics
    $statistics{'$obstacleCount'} = $obstacleCount;
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
    my $fixregex = qr/^$transformCaptureXYRegex$
^$originRegex$
^($numberRegex) $numberRegex l$
^$numberRegex ($numberRegex) l$
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

            #TODO FIX icons are probably all at least >4 but I'll use this for now
            next if ( abs($height) < 3 );

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

    my $fixCount = keys(%fixIcons);

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

            #I don't know why but these values need to be adjusted a bit to enclose the text properly
            my $yMin = $2 - 2;
            my $xMax = $3 - 1;
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

            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterX"} =
            # $_fixXMin * $scaleFactorX;
            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterY"} =
            # $_fixYMin * $scaleFactorY;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"Width"} =
              $_fixXMax - $_fixXMin;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"Height"} =
              $_fixYMax - $_fixYMin;
            $fixTextboxes{ $_fixXMin . $_fixYMin }{"Text"} = $_fixName;

            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"PdfX"} = $_fixXMin;
            # $fixTextboxes{ $_fixXMin . $_fixYMin }{"PdfY"} =
            # $pdfYSize - $_fixYMin;
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

sub findNavaidTextboxes {
    say ":findNavaidTextboxes" if $debug;

    #--------------------------------------------------------------------------
    #Get list of potential VOR (or other ground based nav)  textboxes
    #For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
    #We'll convert them to PDF coordinates
    my $frequencyRegex = qr/\d\d\d(?:\.[\d]{1,3})?/m;

    #my $frequencyRegex = qr/116.3/m;

    # my $vorTextBoxRegex =
    # qr/^\s+<word xMin="($numberRegex)" yMin="($numberRegex)" xMax="$numberRegex" yMax="$numberRegex">($frequencyRegex)<\/word>$
    # ^\s+<word xMin="$numberRegex" yMin="$numberRegex" xMax="($numberRegex)" yMax="($numberRegex)">([A-Z]{3})<\/word>$/m;

    my $vorTextBoxRegex =
      qr/^\s+<word xMin="($numberRegex)" yMin="($numberRegex)" xMax="($numberRegex)" yMax="($numberRegex)">([A-Z]{3})<\/word>$/m;

    #We can get away with not allowing "see" because it's a VOT
    #my $invalidVorNamesRegex = qr/app|dep|arr|see|ils/i;

    my $scal = join( "", @pdfToTextBbox );

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
            next unless $validNavaidNames =~ m/$_vorName/;

            #Check that the box isn't too big
            #This is a workaround for "CO-DEN-ILS-RWY-34L-CAT-II---III.pdf" where it finds a bad box due to ordering of text in PDF
            next if ( abs($width) > 50 );

            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterX"} =
            # $_vorXMin * $scaleFactorX;
            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterY"} =
            # $_vorYMin * $scaleFactorY;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Width"}  = $width;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Height"} = $height;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Text"}   = $_vorName;

            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfX"} = $_vorXMin;
            # $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfY"} =              $pdfYSize - $_vorYMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"CenterX"} =
              $_vorXMin + ( $width / 2 );
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

            my ( $ulX, $ulY, $lrX, $lrY, $longitudeToPixelRatio,
                $latitudeToPixelRatio, $longitudeToLatitudeRatio );

            #TODO: Should make sure that the signs of the differences agree

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

            #my $targetLongitudeToPixelRatio1 = 0.000000002*($ulY**3) - 0.00000008*($ulY**2) + 0.000002*$ulY + 0.0004;

            # if ( $latitudeToPixelRatio < .0003 || $latitudeToPixelRatio > .0006 ) {
            #was .00037 < x < .00039 and .00055 < x < .00059

            #TODO Change back to .00037 and .00039?
            #There seem to be three bands of scales

            #Do some basic sanity checking on the $latitudeToPixelRatio
            if ( $pixelDistanceY > 10 && $latitudeDiff ) {
                $latitudeToPixelRatio = $latitudeDiff / $pixelDistanceY;
                if (
                       not( between( $latitudeToPixelRatio, .00011, .00024 ) )
                    && not( between( $latitudeToPixelRatio, .00028, .00031 ) )
                    && not( between( $latitudeToPixelRatio, .00034, .00046 ) )
                    && not( between( $latitudeToPixelRatio, .00056, .00060 ) )

                    #&& not( between( $latitudeToPixelRatio, .00084, .00085 ) )

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

                    #   next;
                }
                else {
                    #For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
                    $ulY =
                      $gcps{$key}{"lat"} +
                      ( $gcps{$key}{"pngy"} * $latitudeToPixelRatio );

                    #For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
                    $lrY =
                      $gcps{$key}{"lat"} -
                      (
                        abs( $pngYSize - $gcps{$key}{"pngy"} ) *
                          $latitudeToPixelRatio );

                    #Save this ratio if it seems nominally valid
                    push @yScaleAvg, $latitudeToPixelRatio;
                    push @ulYAvg,    $ulY;
                    push @lrYAvg,    $lrY;
                }
            }

            if ( $pixelDistanceX > 10 && $longitudeDiff ) {
                $longitudeToPixelRatio = $longitudeDiff / $pixelDistanceX;

                #Do some basic sanity checking on the $longitudeToPixelRatio
                if ( $longitudeToPixelRatio > .0012 ) {
                    if ($debug) {

                        $gcps{$key}{"Mismatches"} =
                          ( $gcps{$key}{"Mismatches"} ) + 1;
                        $gcps{$key2}{"Mismatches"} =
                          ( $gcps{$key2}{"Mismatches"} ) + 1;
                        say
                          "Bad longitudeToPixelRatio $longitudeToPixelRatio on $key-$key2 pair"
                          if $debug;
                    }

                    #   next;
                }
                else {
                    #For the raster, calculate the Longitude of the upper-left corner based on this object's longitude and the degrees per pixel
                    $ulX =
                      $gcps{$key}{"lon"} -
                      ( $gcps{$key}{"pngx"} * $longitudeToPixelRatio );

                    #For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
                    $lrX =
                      $gcps{$key}{"lon"} +
                      (
                        abs( $pngXSize - $gcps{$key}{"pngx"} ) *
                          $longitudeToPixelRatio );
                    push @xScaleAvg, $longitudeToPixelRatio;
                    push @ulXAvg,    $ulX;
                    push @lrXAvg,    $lrX;
                }
            }

            if ( $ulX && $ulY && $lrX && $lrY ) {

                #The X/Y (or Longitude/Latitude) ratio that would result from using this particular pair

                $longitudeToLatitudeRatio =
                  abs( ( $ulX - $lrX ) / ( $ulY - $lrY ) );

                #TODO BUG Is this a good idea?
                #This is a hack to weight pairs that have both X and Y scales defined more heavily
                push @xScaleAvg, $longitudeToPixelRatio;
                push @ulXAvg,    $ulX;
                push @lrXAvg,    $lrX;
                push @yScaleAvg, $latitudeToPixelRatio;
                push @ulYAvg,    $ulY;
                push @lrYAvg,    $lrY;
            }
            say
              "$key,$key2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio"
              if $debug;

            #If our XYRatio seems to be out of whack for this object pair then don't use the info we derived
            #Currently we're just silently ignoring this, should we try to figure out the bad objects and remove?
            # my $targetLonLatRatio =
            # 0.000004 * ( $ulY**3 ) -
            # 0.0001 *   ( $ulY**2 ) +
            # 0. * $ulY + 0.6739;

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

    my $medianLonDiff = $upperLeftLon - $lowerRightLon;
    my $medianLatDiff = $upperLeftLat - $lowerRightLat;
    $lonLatRatio = abs( $medianLonDiff / $medianLatDiff );
    
 $statistics{'$upperLeftLon'} = $upperLeftLon;
 $statistics{'$upperLeftLat'} = $upperLeftLat;
 $statistics{'$lowerRightLon'} = $lowerRightLon;
 $statistics{'$lowerRightLat'} = $lowerRightLat;
  $statistics{'$lonLatRatio'} = $lonLatRatio;
 
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

    # say
    # "Found only one Ground Control Point.  Let's try a wild guess on $targetPdf";

    # my $guessAtLatitudeToPixelRatio = .00038;
    # my $targetXyRatio =
    # 0.000007 * ( $airportLatitudeDec**3 ) -
    # 0.0002 *   ( $airportLatitudeDec**2 ) +
    # 0.0037 *   ($airportLatitudeDec) + 1.034;

    # my $guessAtLongitudeToPixelRatio =
    # $targetXyRatio * $guessAtLatitudeToPixelRatio;

    # #my $targetLonLatRatio = 0.000004*($airportLatitudeDec**3) - 0.0001*($airportLatitudeDec**2) + 0.0024*$airportLatitudeDec + 0.6739;
    # #my $targetLongitudeToPixelRatio1 = 0.000000002*($airportLatitudeDec**3) - 0.00000008*($airportLatitudeDec**2) + 0.000002*$airportLatitudeDec + 0.0004;

    # foreach my $key ( sort keys %gcps ) {

    # #For the raster, calculate the Longitude of the upper-left corner based on this object's longitude and the degrees per pixel
    # my $ulX =
    # $gcps{$key}{"lon"} -
    # ( $gcps{$key}{"pngx"} * $guessAtLongitudeToPixelRatio );

    # #For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
    # my $ulY =
    # $gcps{$key}{"lat"} +
    # ( $gcps{$key}{"pngy"} * $guessAtLatitudeToPixelRatio );

    # #For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
    # my $lrX =
    # $gcps{$key}{"lon"} +
    # (
    # abs( $pngXSize - $gcps{$key}{"pngx"} ) *
    # $guessAtLongitudeToPixelRatio );

    # #For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
    # my $lrY =
    # $gcps{$key}{"lat"} -
    # (
    # abs( $pngYSize - $gcps{$key}{"pngy"} ) *
    # $guessAtLatitudeToPixelRatio );

    # push @xScaleAvg, $guessAtLongitudeToPixelRatio;
    # push @yScaleAvg, $guessAtLatitudeToPixelRatio;
    # push @ulXAvg,    $ulX;
    # push @ulYAvg,    $ulY;
    # push @lrXAvg,    $lrX;
    # push @lrYAvg,    $lrY;
    # }
    # return;
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

    my $_header = join ",", keys %statistics;
    my $_data   = join ",", values %statistics;

    say {$file} "$_header" or croak "Cannot write to $targetStatistics: ";
    say {$file} "$_data"   or croak "Cannot write to $targetStatistics: ";

    # #Count of entries in this array
    # my $xScaleAvgSize = @xScaleAvg;

    # #Count of entries in this array
    # my $yScaleAvgSize = @yScaleAvg;
    # say {$file}
    # '$dir$filename,$airportLatitudeDec,$airportLongitudeDec,$obstacleCount,$fixCount,$gpsCount,$finalApproachFixCount,$visualDescentPointCount,$gcpCount,$unique_obstacles_from_dbCount,$pdfXYRatio,$lonLatRatio,$xScaleAvgSize,$xAvg,$xMedian,$yScaleAvgSize,$yAvg,$yMedian';

    # say {$file}
    # "$dir$filename$ext,$airportLatitudeDec,$airportLongitudeDec,$obstacleCount,$fixCount,$gpsCount,$finalApproachFixCount,$visualDescentPointCount,$gcpCount,$unique_obstacles_from_dbCount,$pdfXYRatio,$lonLatRatio,$xScaleAvgSize,$xAvg,$xMedian,$yScaleAvgSize,$yAvg,$yMedian"
    # or croak "Cannot write to $targetStatistics: ";    #$OS_ERROR

    close $file;
    return;
}

sub outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb {

    #Only outline our unique potential obstacle_heights with green
    foreach my $key ( sort keys %obstacleTextBoxes ) {

        #Is there a obstacletextbox with the same text as our obstacle's height?
        if (
            exists
            $unique_obstacles_from_db{ $obstacleTextBoxes{$key}{"Text"} } )
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

sub findFixesNearAirport {

    # my $radius = .5;
    my $radiusNm = 50;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport

    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      ( $radiusNm / 60 ) / cos( deg2rad($airportLatitudeDec) );

    #What type of fixes to look for
    my $type = "%REP-PT";

    #Query the database for fixes within our $radius
    $sth = $dbh->prepare(
        "SELECT * FROM fixes WHERE  (Latitude >  $airportLatitudeDec - $radiusDegreesLatitude ) and 
                                (Latitude < $airportLatitudeDec + $radiusDegreesLatitude ) and 
                                (Longitude >  $airportLongitudeDec - $radiusDegreesLongitude ) and 
                                (Longitude < $airportLongitudeDec +$radiusDegreesLongitude ) and
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

    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    if ($debug) {
        my $rows   = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
          "Found $rows FIXES within $radiusNm nm of airport  ($airportLongitudeDec, $airportLatitudeDec) from database";

        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

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

    if ($debug) {
        my $nmLatitude  = 60 * $radius;
        my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

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

    # my $radius      = .5;
    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    #How far away from the airport to look for feature
    my $radiusNm = 40;

    #Convert to degrees of Longitude and Latitude for the latitude of our airport
    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      abs( ( $radiusNm / 60 ) / cos( deg2rad($airportLatitudeDec) ) );

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
                                (Latitude >  $airportLatitudeDec - $radiusDegreesLatitude ) and 
                                (Latitude < $airportLatitudeDec +$radiusDegreesLatitude ) and 
                                (Longitude >  $airportLongitudeDec - $radiusDegreesLongitude ) and 
                                (Longitude < $airportLongitudeDec +$radiusDegreesLongitude ) and
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
          "Found $rows GPS waypoints within $radiusNm NM of airport  ($airportLongitudeDec, $airportLatitudeDec) from database";
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

        print Dumper ( \%gpswaypoints_from_db );
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
      ( $radiusNm / 60 ) / cos( deg2rad($airportLatitudeDec) );

    #What type of fixes to look for
    my $type = "%VOR%";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
        "SELECT * FROM navaids WHERE  
                                (Latitude >  $airportLatitudeDec - $radiusDegreesLatitude ) and 
                                (Latitude < $airportLatitudeDec +$radiusDegreesLatitude ) and 
                                (Longitude >  $airportLongitudeDec - $radiusDegreesLongitude ) and 
                                (Longitude < $airportLongitudeDec +$radiusDegreesLongitude ) and
                                (Type like '$type' OR  Type like '%NDB%')"
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
          "Found $rows Navaids within $radiusNm nm of airport  ($airportLongitudeDec, $airportLatitudeDec) from database"
          if $debug;
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

        print Dumper ( \%navaids_from_db );
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
        my $_rasterX = $_pdfX * $scaleFactorX;
        my $_rasterY = $pngYSize - ( $_pdfY * $scaleFactorY );
        my $rand     = rand();

        #Make sure all our info is defined
        if ( $_rasterX && $_rasterY && $lon && $lat ) {

            #Get the color value of the pixel at the x,y of the GCP
            # my $pixelTextOutput;
            # qx(convert $outputPdfOutlines.png -format '%[pixel:p{$_rasterX,$_rasterY}]' info:-);
            @pixels = $image->GetPixel( x => $_rasterX, y => $_rasterY );
            say "perlMagick $pixels[0]" if $debug;

            # say $pixelTextOutput if $debug;
            #srgb\(149,149,0\)|yellow
            # if ( $pixelTextOutput =~ /black|gray\(0,0,0\)/i  ) {
            if ( $pixels[0] eq 0 ) {

                #If it's any of the above strings then it's valid
                say "$_rasterX $_rasterY $lon $lat" if $debug;
                $gcps{ "$type" . $text . '-' . $rand }{"pngx"} = $_rasterX;
                $gcps{ "$type" . $text . '-' . $rand }{"pngy"} = $_rasterY;
                $gcps{ "$type" . $text . '-' . $rand }{"pdfx"} = $_pdfX;
                $gcps{ "$type" . $text . '-' . $rand }{"pdfy"} = $_pdfY;
                $gcps{ "$type" . $text . '-' . $rand }{"lon"}  = $lon;
                $gcps{ "$type" . $text . '-' . $rand }{"lat"}  = $lat;
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

sub outlineValidFixTextBoxes {
    foreach my $key ( keys %fixTextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $fixes_from_db{ $fixTextboxes{$key}{"Text"} } ) {
            my $fix_box = $page->gfx;
            $fix_box->strokecolor('orange');

            #Yes, draw an orange box around it
            $fix_box->rect(
                $fixTextboxes{$key}{"CenterX"} -
                  ( $fixTextboxes{$key}{"Width"} / 2 ),
                $fixTextboxes{$key}{"CenterY"} -
                  ( $fixTextboxes{$key}{"Height"} / 2 ),
                $fixTextboxes{$key}{"Width"},
                $fixTextboxes{$key}{"Height"}
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
    foreach my $key ( keys %vorTextboxes ) {

        #Is there a vorTextbox with the same text as our navaid?
        if ( exists $navaids_from_db{ $vorTextboxes{$key}{"Text"} } ) {
            my $navBox = $page->gfx;
            $navBox->strokecolor('orange');

            #Yes, draw an orange box around it
            $navBox->rect(
                $vorTextboxes{$key}{"CenterX"} -
                  ( $vorTextboxes{$key}{"Width"} / 2 ),
                $vorTextboxes{$key}{"CenterY"} +
                  ( $vorTextboxes{$key}{"Height"} / 2 ),
                $vorTextboxes{$key}{"Width"},
                -( $vorTextboxes{$key}{"Height"} )

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
    my $_upperYCutoff = $pdfYSize;
    my $_lowerYCutoff = 0;

    #Find the highest purely horizonal line below the midpoint of the page
    foreach my $key ( sort keys %horizontalAndVerticalLines ) {

        my $x      = $horizontalAndVerticalLines{$key}{"X"};
        my $x2     = $horizontalAndVerticalLines{$key}{"X2"};
        my $length = abs( $x - $x2 );
        my $y2     = $horizontalAndVerticalLines{$key}{"Y2"};
        my $yCoord = $horizontalAndVerticalLines{$key}{"Y"};

        #Check that this is a horizonal line since we're also currently storing vertical ones in this hash too
        #TODO separate hashes for horz and vertical
        next unless ( $yCoord == $y2 );

        if (   ( $yCoord > $_lowerYCutoff )
            && ( $yCoord < .5 * $pdfYSize )
            && ( $length > .5 * $pdfXSize ) )
        {

            $_lowerYCutoff = $yCoord;
        }
    }

    #Find the lowest purely horizonal line above the midpoint of the page
    foreach my $key ( sort keys %horizontalAndVerticalLines ) {
        my $y2     = $horizontalAndVerticalLines{$key}{"Y2"};
        my $yCoord = $horizontalAndVerticalLines{$key}{"Y"};

        #Check that this is a horizonal line since we're also currently storing vertical ones in this hash too
        #TODO separate hashes for horz and vertical
        next unless ( $yCoord == $y2 );

        if ( ( $yCoord < $_upperYCutoff ) && ( $yCoord > .5 * $pdfYSize ) ) {

            $_upperYCutoff = $yCoord;
        }
    }
    say "Returning $_upperYCutoff and $_lowerYCutoff  as horizontal cutoffs"
      if $debug;
    return ( $_lowerYCutoff, $_upperYCutoff );
}

sub outlineValidGpsWaypointTextBoxes {

    #Orange outline fixTextboxes that have a valid fix name in them
    #Delete fixTextboxes that don't have a valid nearby fix in them
    foreach my $key ( keys %fixTextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $gpswaypoints_from_db{ $fixTextboxes{$key}{"Text"} } ) {
            my $fix_box = $page->gfx;

            #Yes, draw an orange box around it
            $fix_box->rect(
                $fixTextboxes{$key}{"CenterX"} -
                  ( $fixTextboxes{$key}{"Width"} / 2 ),
                $fixTextboxes{$key}{"CenterY"} -
                  ( $fixTextboxes{$key}{"Height"} / 2 ),
                $fixTextboxes{$key}{"Width"},
                $fixTextboxes{$key}{"Height"}

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
    foreach my $key ( sort keys %gcps ) {

        my $gcpCircle = $page->gfx;
        $gcpCircle->circle( $gcps{$key}{pdfx}, $gcps{$key}{pdfy}, 5 );
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
    @pdfToTextBbox = qx(pdftotext $targetPdf -layout -bbox - );
    $retval        = $? >> 8;
    die
      "No output from pdftotext -bbox.  Is it installed? Return code was $retval"
      if ( @pdfToTextBbox eq "" || $retval != 0 );

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

        #The key of who this icon is matched to
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

sub outlines {
    say ":outlines" if $debug;
    my $outlineWidth = 1;

    #Draw the various types of boxes on the output PDF

    my %font = (
        Helvetica => {
            Bold =>
              $pdfOutlines->corefont( 'Helvetica-Bold', -encoding => 'latin1' ),

            #      Roman  => $pdfOutlines->corefont('Helvetica',         -encoding => 'latin1'),
            #      Italic => $pdfOutlines->corefont('Helvetica-Oblique', -encoding => 'latin1'),
        },
        Times => {

            #      Bold   => $pdfOutlines->corefont('Times-Bold',        -encoding => 'latin1'),
            Roman => $pdfOutlines->corefont( 'Times', -encoding => 'latin1' ),

            #      Italic => $pdfOutlines->corefont('Times-Italic',      -encoding => 'latin1'),
        },
    );

    #TODO This was yellow just for testing
    my ($bigOleBox) = $pageOutlines->gfx;

    #Draw a big box to stop the flood because we can't always find the main box in the PDF
    $bigOleBox->strokecolor('black');
    $bigOleBox->linewidth(5);
    $bigOleBox->rect( 20, 40, 350, 500 );
    $bigOleBox->stroke;

    #Draw a horizontal line at the $lowerYCutoff to stop the flood in case we don't findNavaidTextboxes
    #all of the lines
    $bigOleBox->move( 20, $lowerYCutoff );
    $bigOleBox->line( 500, $lowerYCutoff );
    $bigOleBox->stroke;

    foreach my $key ( sort keys %horizontalAndVerticalLines ) {

        my ($lines) = $pageOutlines->gfx;
        $lines->strokecolor('black');
        $lines->linewidth($outlineWidth);
        $lines->move(
            $horizontalAndVerticalLines{$key}{"X"},
            $horizontalAndVerticalLines{$key}{"Y"}
        );
        $lines->line(
            $horizontalAndVerticalLines{$key}{"X2"},
            $horizontalAndVerticalLines{$key}{"Y2"}
        );

        $lines->stroke;
    }
    foreach my $key ( sort keys %insetBoxes ) {

        my ($insetBox) = $pageOutlines->gfx;
        $insetBox->strokecolor('black');
        $insetBox->linewidth($outlineWidth);
        $insetBox->rect(
            $insetBoxes{$key}{X},
            $insetBoxes{$key}{Y},
            $insetBoxes{$key}{Width},
            $insetBoxes{$key}{Height},

        );

        $insetBox->stroke;
    }
    foreach my $key ( sort keys %largeBoxes ) {

        my ($largeBox) = $pageOutlines->gfx;
        $largeBox->strokecolor('black');
        $largeBox->linewidth($outlineWidth);
        $largeBox->rect(
            $largeBoxes{$key}{X},     $largeBoxes{$key}{Y},
            $largeBoxes{$key}{Width}, $largeBoxes{$key}{Height},
        );

        $largeBox->stroke;
    }

    foreach my $key ( sort keys %insetCircles ) {

        my ($insetCircle) = $pageOutlines->gfx;
        $insetCircle->strokecolor('black');
        $insetCircle->linewidth($outlineWidth);
        $insetCircle->circle(
            $insetCircles{$key}{X},
            $insetCircles{$key}{Y},
            $insetCircles{$key}{Radius},
        );

        $insetCircle->stroke;
    }

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
    my $notToScaleIndicatorRegex = qr/^$transformCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^$originRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
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

            $notToScaleIndicator{ $i . $random }{"CenterX"} = $x;
            $notToScaleIndicator{ $i . $random }{"CenterY"} = $y;

        }

    }

    $notToScaleIndicatorCount = keys(%notToScaleIndicator);

    #Save statistics
    $statistics{'$notToScaleIndicatorCount'} = $notToScaleIndicatorCount;

    # if ($debug) {
    # print "$notToScaleIndicatorCount notToScaleIndicator(s) ";

    # print Dumper ( \%notToScaleIndicator );

    # }

    return;
}
