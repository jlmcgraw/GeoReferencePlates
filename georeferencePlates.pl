#!/usr/bin/perl

# GeoReferencePlates - a utility to automatically georeference FAA Instrument Approach Plates / Terminal Procedures
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

#Unavoidable problems:
#-Relies on icons being drawn very specific ways, it won't work if these ever change
#-Relies on text being in PDF.  It seems that most, if not all, military plates have no text in them


#Known issues:
#Have a two-way check for icon to textbox matching
#-Investigate not creating the intermediate PNG (guessing at dimensions)
#-Accumulate GCPs across the streams (possibly more trouble than it's worth due to inset airport diagram)
#Our pixel/RealWorld ratios are hardcoded now for 300dpi, need to make dynamic per our DPI setting

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
    say "Usage: $0 <pdf_file>\n";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
    exit(1);
}

#We need at least one argument (the name of the PDF to process)
if ( $arg_num < 1 ) {
    say "Usage: $0 <pdf_file>\n";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
    exit(1);
}

my $debug            = $opt{v};
my $saveMarkedPdf    = $opt{p};
my $outputStatistics = $opt{s};

my ($targetPdf);

my $retval;

#Get the target PDF file from command line options
$targetPdf = $ARGV[0];

#Get the airport ID in case we can't guess it from PDF (KSSC is an example)
my $airportId = $opt{a};

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

#Non-zero if we only want to use GPS waypoints for GCPs on this plate
my $rnavPlate = 0;

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

# #Open the input PDF
# open my $file, '<', $targetPdf
# or croak "can't open '$targetPdf' for reading : $!";
# close $file;

#Pull all text out of the PDF
my @pdftotext;
@pdftotext = qx(pdftotext $targetPdf  -enc ASCII7 -);
$retval    = $? >> 8;

if ( @pdftotext eq "" || $retval != 0 ) {
    say "No output from pdftotext.  Is it installed?  Return code was $retval";
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

#Testing a way to normalize scales by latitude
my $fudge = ( cos( deg2rad($airportLatitudeDec) ) )**2;

#say "Fudge $fudge at Latitude $airportLatitudeDec";

#Get the mediabox size and other variables from the PDF
my ( $pdfXSize, $pdfYSize, $pdfCenterX, $pdfCenterY, $pdfXYRatio ) =
  getMediaboxSize();

convertPdfToPng();

#Get PNG dimensions and the PDF->PNG scale factors
my ( $pngXSize, $pngYSize, $scaleFactorX, $scaleFactorY, $pngXYRatio ) =
  getPngSize();

#--------------------------------------------------------------------------------------------------------------
#Get number of objects/streams in the targetpdf
my $objectstreams = getNumberOfStreams();

# #Some regex building blocks to be used elsewhere
#numbers that start with 1-9 followed by 2 or more digits
my $obstacleHeightRegex = qr/[1-9]\d{2,}/;
my $numberRegex         = qr/[-\.0-9]+/;
my ($transformCaptureXYRegex) =
  qr/q 1 0 0 1\s($numberRegex)\s($numberRegex)\s+cm/;
my ($transformNoCaptureXYRegex) =
  qr/q 1 0 0 1\s$numberRegex\s$numberRegex\s+cm/;

#F*  Fill path
#S     Stroke path
#cm Scale and translate coordinate space
#c      Bezier curve
#q     Save graphics state
#Q     Restore graphics state
# my $obstacleregex =
# qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([\.0-9]+) ([\.0-9]+) l [\.0-9]+ [\.0-9]+ l S Q q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c f\* Q/;

#                           0x               1y                                     2+x         3+y                                                                               4dotX     5dotY

#Global variables filled in by the "findAllIcons" subroutine.  At somepoint I'll convert the subroutines to return values instead
my %obstacleIcons    = ();
my $obstacleCount    = 0;
my %fixIcons         = ();
my $fixCount         = 0;
my %gpsWaypointIcons = ();
my $gpsCount         = 0;
my %vortacIcons      = ();
my $vortacCount      = 0;

my %finalApproachFixIcons   = ();
my $finalApproachFixCount   = 0;
my %visualDescentPointIcons = ();
my $visualDescentPointCount = 0;

#Loop through each of the streams in the PDF and find all of the icons we're interested in
findAllIcons();

#Get all of the text and respective bounding boxes in the PDF
my @pdfToTextBbox = qx(pdftotext $targetPdf -bbox - );
$retval = $? >> 8;
die "No output from pdftotext -bbox.  Is it installed? Return code was $retval"
  if ( @pdfToTextBbox eq "" || $retval != 0 );

#Find potential obstacle height textboxes
my %obstacleTextBoxes = ();
findObstacleHeightTextBoxes();

#Find textboxes that are valid for both fix and GPS waypoints
my %fixtextboxes = ();
findFixTextboxes();

#Find textboxes that are valid for navaids
my %vorTextboxes = ();
findVorTextboxes();

#----------------------------------------------------------------------------------------------------------
#Modify the PDF
#Don't do anything PDF related unless we've asked to create one on the command line

my ( $pdf, $page );
$pdf = PDF::API2->open($targetPdf) if $saveMarkedPdf;

#Set up the various types of boxes to draw on the output PDF
$page = $pdf->openpage(1) if $saveMarkedPdf;

#Draw boxes around what we've found so far
outlineEverythingWeFound() if $saveMarkedPdf;

#----------------------------------------------------------------------------------------------------------------------------------
#Everything to do with obstacles
#
#Try to find closest obstacleTextBox center to each obstacleIcon
findClosestObstacleTextBoxToObstacleIcon();

#Draw a line from obstacle icon to closest text boxes
drawLineFromEachObstacleToClosestTextBox() if $saveMarkedPdf;

#Get a list of potential obstacle heights from the PDF text array
my @obstacle_heights = findObstacleHeightTexts(@pdftotext);

#Remove any duplicates
onlyuniq(@obstacle_heights);

#Find all obstacles within our defined distance from the airport that have a height in the list of potential obstacleTextBoxes and are unique
my $radius = ".35"
  ; # +/- degrees of longitude or latitude (~15 miles) from airport to limit our search for objects  to
my %unique_obstacles_from_db = ();
my $unique_obstacles_from_dbCount;
findObstaclesInDatabase();

#Find a obstacle icon with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates of its closest height text box to unique_obstacles_from_db hash
#Updates %unique_obstacles_from_db
matchObstacleIconToUniqueObstaclesFromDb();

outlineObstacleTextboxIfTheNumberExistsInUniqueObstaclesInDb()
  if $saveMarkedPdf;

#Link the obstacles from the database lookup to the icons and the textboxes
matchDatabaseResultsToIcons();

removeUniqueObstaclesFromDbThatAreNotMatchedToIcons();

removeUniqueObstaclesFromDbThatShareIcons();

#If we have more than 2 obstacles that have only 1 potentialTextBoxes then remove all that have potentialTextBoxes > 1
my $countOfObstaclesWithOnePotentialTextbox =
  countObstacleIconsWithOnePotentialTextbox();

if ( $countOfObstaclesWithOnePotentialTextbox > 2 ) {

   #say "Gleefully deleting objects that have more than one potentialTextBoxes";

    # foreach my $key ( sort keys %unique_obstacles_from_db ) {
    # if  (!($unique_obstacles_from_db{$key}{"potentialTextBoxes"} == 1))
    # {
    # delete $unique_obstacles_from_db{$key};
    # }
    #}
}
if ($saveMarkedPdf) {
    drawLineFromEachToUniqueObstaclesFromDbToClosestTextBox();

}
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

#Orange outline fixtextboxes that have a valid fix name in them
outlineValidFixTextBoxes() if $saveMarkedPdf;

#Try to find closest fixtextbox to each fix icon
#Updates %fixIcons
findClosestFixTextBoxToFixIcon();

#fixes_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {

    # say "fixes_from_db";
    # print Dumper ( \%fixes_from_db );
    say "";
    say "fix icons";
    print Dumper ( \%fixIcons );
    say "";

    # say "fixtextboxes";
    # print Dumper ( \%fixtextboxes );
    say "";
}

#remove entries that have no name
#updates %fixIcons
deleteFixIconsWithNoName();

drawLineFromEacFixToClosestTextBox() if $saveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with GPS waypoints
#
#Find GPS waypoints near the airport
my %gpswaypoints_from_db = ();
findGpsWaypointsNearAirport();

#Orange outline fixtextboxes that have a valid GPS waypoint name in them
outlineValidGpsWaypointTextBoxes() if $saveMarkedPdf;

#Pair up each waypoint to it's closest textbox
matchClosestFixTextBoxToEachGpsWaypointIcon();

#gpswaypoints_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {

    # say "gpswaypoints_from_db";
    # print Dumper ( \%gpswaypoints_from_db );
    say "";
    say "GPS waypoint icons";
    print Dumper ( \%gpsWaypointIcons );
    say "";

    # say "fixtextboxes";
    # print Dumper ( \%fixtextboxes );
    say "";
}

deleteGpsWaypointsWithNoName();

#Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
deleteDuplicateGpsWaypoints();

#Draw a line from GPS waypoint icon to closest text boxes
drawLineFromEachGpsWaypointToMatchedTextbox() if $saveMarkedPdf;

#---------------------------------------------------------------------------------------------------------------------------------------
#Everything to do with navaids
#
#Find navaids near the airport
my %navaids_from_db = ();
findNavaidsNearAirport();

#Orange outline navaid textboxes that have a valid navaid name in them
outlineValidNavaidTextBoxes() if $saveMarkedPdf;

#Pair up each waypoint to it's closest textbox
matchClosestNavaidTextBoxToNavaidIcon();

#navaids_from_db should now only have navaids that are mentioned on the PDF
if ($debug) {

    # say "navaids_from_db";
    # print Dumper ( \%navaids_from_db );
    say "";
    say "Navaid icons";
    print Dumper ( \%vortacIcons );
    say "";
}

#deleteNavaidsWithNoName();

#Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
#deleteDuplicateNavaids();

#Draw a line from GPS waypoint icon to closest text boxes
drawLineFromNavaidToMatchedTextbox() if $saveMarkedPdf;
#---------------------------------------------------------------------------------------------------------------------------------------------------
#Create the combined hash of Ground Control Points
my %gcps = ();
say "";
say "Obstacle Ground Control Points" if $debug;

if ( !$rnavPlate ) {

    #Add Obstacles to Ground Control Points hash
    addObstaclesToGroundControlPoints();
    #Add Fixes to Ground Control Points hash
    addFixesToGroundControlPoints();
    #Add Navaids to Ground Control Points hash
    addNavaidsToGroundControlPoints();
}

#Add GPS waypoints to Ground Control Points hash
addGpsWaypointsToGroundControlPoints();

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
say "Found $gcpCount potential Ground Control Points";

#Can't do anything if we didn't find any valid ground control points
if ( $gcpCount < 1 ) {
    say "Didn't find any ground control points.";
    exit(1);
}

drawCircleAroundGCPs() if $saveMarkedPdf;

#-------------------------------------------------------------------------------------------------------------------------------------------------------
#We're done with finding icons so let's close the PDF (if it exists) and the database
#Save our new PDF since we're done with it
if ($saveMarkedPdf) {
    $pdf->saveas($outputPdf);
}

#Close the database
$sth->finish();
$dbh->disconnect();

#----------------------------------------------------------------------------------------------------------------------------------------------------
#Now some math
my ( @xScaleAvg, @yScaleAvg, @ulXAvg, @ulYAvg, @lrXAvg, @lrYAvg ) = ();

#Print a header so you could paste the following output into a spreadsheet to analyze
say
'$object1,$object2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2'
  if $debug;

#Calculate the rough X and Y scale values
calculateRoughRealWorldExtentsOfRaster();

if ( $gcpCount == 1 ) {
    calculateRoughRealWorldExtentsOfRasterWithOneGCP();
}

my ( $xAvg,    $xMedian,   $xStdDev )   = 0;
my ( $yAvg,    $yMedian,   $yStdDev )   = 0;
my ( $ulXAvrg, $ulXmedian, $ulXStdDev ) = 0;
my ( $ulYAvrg, $ulYmedian, $ulYStdDev ) = 0;
my ( $lrXAvrg, $lrXmedian, $lrXStdDev ) = 0;
my ( $lrYAvrg, $lrYmedian, $lrYStdDev ) = 0;
my ($lonLatRatio) = 0;

#Smooth out the X and Y scales we previously calculated
calculateSmoothedRealWorldExtentsOfRaster();

#Actually produce the georeferencing data via GDAL
georeferenceTheRaster();

#Write out the statistics of this file if requested
writeStatistics() if $outputStatistics;

#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------
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

    foreach my $key ( sort keys %obstacleIcons ) {

        my $obstacle_box = $page->gfx;
        $obstacle_box->rect(
            $obstacleIcons{$key}{X} - 4,
            $obstacleIcons{$key}{Y} - 2,
            7, 8
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
        my $fix_box = $page->gfx;
        $fix_box->rect( $fixIcons{$key}{X} - 4, $fixIcons{$key}{Y} - 4, 9, 9 );
        $fix_box->strokecolor('red');
        $fix_box->linewidth(.1);
        $fix_box->stroke;
    }
    foreach my $key ( sort keys %fixtextboxes ) {
        my $fix_box = $page->gfx;
        $fix_box->rect(
            $fixtextboxes{$key}{PdfX},
            $fixtextboxes{$key}{PdfY} + 2,
            $fixtextboxes{$key}{"Width"},
            -( $fixtextboxes{$key}{"Height"} + 2 )
        );
        $fix_box->linewidth(.1);
        $fix_box->stroke;
    }
    foreach my $key ( sort keys %gpsWaypointIcons ) {
        my $gpswaypoint_box = $page->gfx;
        $gpswaypoint_box->rect(
            $gpsWaypointIcons{$key}{X} - 1,
            $gpsWaypointIcons{$key}{Y} - 8,
            17, 16
        );
        $gpswaypoint_box->strokecolor('red');
        $gpswaypoint_box->linewidth(.1);
        $gpswaypoint_box->stroke;
    }

    foreach my $key ( sort keys %finalApproachFixIcons ) {
        my $faf_box = $page->gfx;
        $faf_box->rect(
            $finalApproachFixIcons{$key}{X} - 5,
            $finalApproachFixIcons{$key}{Y} - 5,
            10, 10
        );
        $faf_box->strokecolor('red');
        $faf_box->linewidth(.1);
        $faf_box->stroke;
    }

    foreach my $key ( sort keys %visualDescentPointIcons ) {
        my $vdp_box = $page->gfx;
        $vdp_box->rect(
            $visualDescentPointIcons{$key}{X} - 3,
            $visualDescentPointIcons{$key}{Y} - 7,
            8, 8
        );
        $vdp_box->strokecolor('red');
        $vdp_box->linewidth(.1);
        $vdp_box->stroke;
    }

    foreach my $key ( sort keys %vortacIcons ) {
        my $vortacBox = $page->gfx;
        $vortacBox->rect( $vortacIcons{$key}{X}, $vortacIcons{$key}{Y}, 8, 8 );
        $vortacBox->strokecolor('red');
        $vortacBox->linewidth(.1);
        $vortacBox->stroke;
    }
    foreach my $key ( sort keys %vorTextboxes ) {
        my $vortacBox = $page->gfx;
        $vortacBox->rect(
            $vorTextboxes{$key}{PdfX},
            $vorTextboxes{$key}{PdfY} + 2,
            $vorTextboxes{$key}{"Width"},
            -( $vorTextboxes{$key}{"Height"} + 2 )
        );
        $vortacBox->strokecolor('red');
        $vortacBox->linewidth(.1);
        $vortacBox->stroke;
    }
    return;
}

sub drawLineFromEachObstacleToClosestTextBox {

    #Draw a line from obstacle icon to closest text boxes
    my $_obstacle_line = $page->gfx;
    $_obstacle_line->strokecolor('blue');
    foreach my $key ( sort keys %obstacleIcons ) {
        $_obstacle_line->move( $obstacleIcons{$key}{"X"},
            $obstacleIcons{$key}{"Y"} );
        $_obstacle_line->line(
            $obstacleIcons{$key}{"TextBoxX"},
            $obstacleIcons{$key}{"TextBoxY"}
        );
        $_obstacle_line->stroke;
    }
    return;
}

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
    say say
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
    say "";
    return;
}

sub findAllIcons {
    say "findAllIcons" if $debug;

    #Loop through each "stream" in the pdf looking for our various icons
    my ($_output);

    for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
        $_output = qx(mutool show $targetPdf $i x);
        $retval  = $? >> 8;
        die
"No output from mutool show.  Is it installed? Return code was $retval"
          if ( $_output eq "" || $retval != 0 );

        print "Stream $i: " if $debug;

        findObstacleIcons($_output);
        findFixIcons($_output);
        findGpsWaypointIcons($_output);
        findVortacIcons($_output);
        findFinalApproachFixIcons($_output);
        findVisualDescentPointIcons($_output);
        say "" if $debug;
    }

    # say "%obstacleIcons:";
    # print Dumper ( \%obstacleIcons );
    return;
}

sub findClosestObstacleTextBoxToObstacleIcon {
    say "findClosestObstacleTextBoxToObstacleIcon" if $debug;
    foreach my $key ( sort keys %obstacleIcons ) {

        #Start with a very high number so initially is closer than it
        my $distance_to_closest_obstacletextbox = 999999999999;

        foreach my $key2 ( keys %obstacleTextBoxes ) {
            my $distanceToObstacletextboxX;
            my $distanceToObstacletextboxY;

            $distanceToObstacletextboxX =
              $obstacleTextBoxes{$key2}{"boxCenterXPdf"} -
              $obstacleIcons{$key}{"X"};
            $distanceToObstacletextboxY =
              $obstacleTextBoxes{$key2}{"boxCenterYPdf"} -
              $obstacleIcons{$key}{"Y"};

            my $hypotenuse = sqrt( $distanceToObstacletextboxX**2 +
                  $distanceToObstacletextboxY**2 );

       #Ignore this textbox if it's further away than our max distance variables
            next
              if ( !( $hypotenuse < $maxDistanceFromObstacleIconToTextBox ) );

#Count the number of potential textbox matches.  If this is > 1 then we should consider this matchup to be less reliable
            $obstacleIcons{$key}{"potentialTextBoxes"} =
              $obstacleIcons{$key}{"potentialTextBoxes"} + 1;

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
#say "Hypotenuse: $hyp" if $debug;
            if ( ( $hypotenuse < $distance_to_closest_obstacletextbox ) ) {

                #Update the distance to the closest obstacleTextBox center
                $distance_to_closest_obstacletextbox = $hypotenuse;

#Set the "name" of this obstacleIcon to the text from obstacleTextBox
#This is where we kind of guess (and can go wrong) since the closest height text is often not what should be associated with the icon

                $obstacleIcons{$key}{"Name"} =
                  $obstacleTextBoxes{$key2}{"Text"};

                $obstacleIcons{$key}{"TextBoxX"} =
                  $obstacleTextBoxes{$key2}{"boxCenterXPdf"};

                $obstacleIcons{$key}{"TextBoxY"} =
                  $obstacleTextBoxes{$key2}{"boxCenterYPdf"};

                # $obstacleTextBoxes{$key2}{"IconsThatPointToMe"} =
                # $obstacleTextBoxes{$key2}{"IconsThatPointToMe"} + 1;
            }

        }

        #$obstacleIcons{$key}{"ObstacleTextBoxesThatPointToMe"} =
        # $obstacleIcons{$key}{"ObstacleTextBoxesThatPointToMe"} + 1;
    }
    if ($debug) {
        say "obstacleIcons";
        print Dumper ( \%obstacleIcons );
        say "";
        say "obstacleTextBoxes";
        print Dumper ( \%obstacleTextBoxes );
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
    my $bezierCurveRegex = qr/(?:$numberRegex\s){6}c/;
    my $lineRegex        = qr/$numberRegex\s$numberRegex\sl/;

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

        #say "Found $tempgpswaypoints_count GPS waypoints in stream $i";
        for ( my $i = 0 ; $i < $tempgpswaypoints_length ; $i = $i + 2 ) {

            #put them into a hash
            $gpsWaypointIcons{$i}{"X"} = $tempgpswaypoints[$i];
            $gpsWaypointIcons{$i}{"Y"} = $tempgpswaypoints[ $i + 1 ];
            $gpsWaypointIcons{$i}{"iconCenterXPdf"} =

#TODO Calculate the midpoint properly, this number is an estimation (although a good one)
              $tempgpswaypoints[$i] + 7.5;
            $gpsWaypointIcons{$i}{"iconCenterYPdf"} =
              $tempgpswaypoints[ $i + 1 ];
            $gpsWaypointIcons{$i}{"Name"} = "none";
        }

    }

    $gpsCount = keys(%gpsWaypointIcons);
    if ($debug) {
        print "$tempgpswaypoints_count GPS ";

    }
    return;
}

#--------------------------------------------------------------------------------------------------------------------------------------
sub findVortacIcons {
    #I'm going to lump finding all of the navaid icons into here for now
    #Before I clean it up
    my ($_output) = @_;

    #REGEX building blocks

    my ($bezierCurveRegex) = qr/(?:$numberRegex\s){6}c/;
    my ($lineRegex)        = qr/$numberRegex\s$numberRegex\sl/;

    #^$numberRegex\sw\s$
    #Find VOR icons
    my $vortacRegex = qr/^$transformCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^f\*$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^f\*$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^f\*$
^Q$/m;

    my $vorDmeRegex = qr/^$transformCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^$lineRegex$
^S$
^Q$
^$transformNoCaptureXYRegex$
^0\s0\sm$
^$lineRegex$
^$lineRegex$
^S$
^Q$/m;

    my @tempVortac = $_output =~ /$vortacRegex/ig;

    #say @tempVortac;

    # say $&;
    my $tempVortacLength = 0 + @tempVortac;
    my $tempVortacCount  = $tempVortacLength / 2;

    if ( $tempVortacLength >= 2 ) {

        for ( my $i = 0 ; $i < $tempVortacLength ; $i = $i + 2 ) {

            #put them into a hash
            $vortacIcons{$i}{"X"} = $tempVortac[$i];
            $vortacIcons{$i}{"Y"} = $tempVortac[ $i + 1 ];
            $vortacIcons{$i}{"iconCenterXPdf"} =

#TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            $tempVortac[$i] + 2;
            $vortacIcons{$i}{"iconCenterYPdf"} = $tempVortac[ $i + 1 ]-3;
            $vortacIcons{$i}{"Name"}           = "none";
        }

    }

#Re-run for VORDME
@tempVortac = $_output =~ /$vorDmeRegex/ig;

    #say @tempVortac;

    # say $&;
    $tempVortacLength = 0 + @tempVortac;
    $tempVortacCount  = $tempVortacLength / 2;

    if ( $tempVortacLength >= 2 ) {

        for ( my $i = 0 ; $i < $tempVortacLength ; $i = $i + 2 ) {

            #put them into a hash
            $vortacIcons{$i}{"X"} = $tempVortac[$i];
            $vortacIcons{$i}{"Y"} = $tempVortac[ $i + 1 ];
#TODO Calculate the midpoint properly, this number is an estimation (although a good one)
            $vortacIcons{$i}{"iconCenterXPdf"} = $tempVortac[$i] + 5;
            $vortacIcons{$i}{"iconCenterYPdf"} = $tempVortac[ $i + 1 ]+4;
            $vortacIcons{$i}{"Name"}           = "none";
        }

    }
    $vortacCount = keys(%vortacIcons);
    if ($debug) {
        print "$tempVortacCount VOR ";
    }
    
    #-----------------------------------
    
    return;
}

sub findObstacleIcons {

    #The uncompressed text of this stream
    my ($_output) = @_;

    #A regex that matches how an obstacle is drawn in the PDF
    my ($obstacleregex) = qr/^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
^0 0 m$
^([\.0-9]+) [\.0-9]+ l$
^([\.0-9]+) [\.0-9]+ l$
^S$
^Q$
^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^f\*$
^Q$/m;

#each entry in @tempobstacles will have the numbered captures from the regex, 6 for each one
    my (@tempobstacles) = $_output =~ /$obstacleregex/ig;
    my ($tempobstacles_length) = 0 + @tempobstacles;

#Divide length of array by 6 data points for each obstacle to get count of obstacles
    my ($tempobstacles_count) = $tempobstacles_length / 6;

    if ( $tempobstacles_length >= 6 ) {

        #say "Found $tempobstacles_count obstacles in stream $stream";

        for ( my $i = 0 ; $i < $tempobstacles_length ; $i = $i + 6 ) {

#Note: this code does not accumulate the objects across streams but rather overwrites existing ones
#This works fine as long as the stream with all of the obstacles in the main section of the drawing comes after the streams
#with obstacles for the airport diagram (which is a separate scale)
#A hack to allow icon accumulation across streams
#Comment this out to only find obstacles in the last scanned stream
#
#my $epoc = rand();
            my $epoc = "";

#Put the info for each obstscle icon into a hash
#This finds the midpoint X of the obstacle triangle (basically the X,Y of the dot but the X,Y of the dot itself was too far right)
#For each icon: Offset             0: Starting X
#                                               1: Starting Y
#                                               2: X of top of triangle
#                                               3: Y of top of triangle
#                                               4: X of dot
#                                               5: Y of dot
            $obstacleIcons{ $i . $epoc }{"X"} =
              $tempobstacles[$i] + $tempobstacles[ $i + 2 ];
            $obstacleIcons{ $i . $epoc }{"Y"} =
              $tempobstacles[ $i + 1 ];    #+ $tempobstacles[ $i + 3 ];
            $obstacleIcons{ $i . $epoc }{"Height"} = "unknown";
            $obstacleIcons{ $i . $epoc }{"ObstacleTextBoxesThatPointToMe"} = 0;
            $obstacleIcons{ $i . $epoc }{"potentialTextBoxes"}             = 0;
        }

    }

    #print Dumper ( \%obstacleIcons );
    $obstacleCount = keys(%obstacleIcons);
    if ($debug) {
        print "$tempobstacles_count obstacle ";

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

    if ( $tempfixes_length >= 4 ) {

        #say "Found $tempfixes_count fix icons in stream $i";
        for ( my $i = 0 ; $i < $tempfixes_length ; $i = $i + 4 ) {

            #put them into a hash
            #code here is making the x/y the center of the triangle
            $fixIcons{$i}{"X"} = $tempfixes[$i] + ( $tempfixes[ $i + 2 ] / 2 );
            $fixIcons{$i}{"Y"} =
              $tempfixes[ $i + 1 ] + ( $tempfixes[ $i + 3 ] / 2 );
            $fixIcons{$i}{"Name"} = "none";
        }

    }

    $fixCount = keys(%fixIcons);
    if ($debug) {
        print "$tempfixes_count fix ";

    }
    return;
}

sub findFinalApproachFixIcons {
    my ($_output) = @_;

#Find Final Approach Fix icon
#my $fafRegex =
#qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q/;
    my $fafRegex = qr/^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^f\*$
^Q$
^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ l$
^[-\.0-9]+ [-\.0-9]+ l$
^0 0 l$
^f\*$
^Q$
^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ l$
^[-\.0-9]+ [-\.0-9]+ l$
^0 0 l$
^f\*$
^Q$
^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ l$
^[-\.0-9]+ [-\.0-9]+ l$
^0 0 l$
^f\*$
^Q$
^q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ l$
^[-\.0-9]+ [-\.0-9]+ l$
^0 0 l$
^f\*$
^Q$/m;

    my @tempfinalApproachFixIcons = $_output =~ /$fafRegex/ig;
    my $tempfinalApproachFixIcons_length = 0 + @tempfinalApproachFixIcons;
    my $tempfinalApproachFixIcons_count = $tempfinalApproachFixIcons_length / 2;

    if ( $tempfinalApproachFixIcons_length >= 2 ) {

        #say "Found $tempfinalApproachFixIcons_count FAFs in stream $i";
        for ( my $i = 0 ; $i < $tempfinalApproachFixIcons_length ; $i = $i + 2 )
        {

            #put them into a hash
            $finalApproachFixIcons{$i}{"X"} = $tempfinalApproachFixIcons[$i];
            $finalApproachFixIcons{$i}{"Y"} =
              $tempfinalApproachFixIcons[ $i + 1 ];
            $finalApproachFixIcons{$i}{"Name"} = "none";
        }

    }

    $finalApproachFixCount = keys(%finalApproachFixIcons);

    # if ($debug) {
    # say "Found $tempfinalApproachFixIcons_count Final Approach Fix icons";
    # say "";
    # }
    return;
}

sub findVisualDescentPointIcons {
    my ($_output) = @_;

    #Find Visual Descent Point icon
    my $vdpRegex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+0.72 w \[\]0 d/;

    #my $vdpRegex =
    #qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+
    #0 0 m\s+
    #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    #[-\.0-9]+\s+[-\.0-9]+\s+l\s+
    #0 0 l\s+
    #f\*\s+
    #Q\s+
    #0.72 w \[\]0 d/m;

    my @tempvisualDescentPointIcons = $_output =~ /$vdpRegex/ig;
    my $tempvisualDescentPointIcons_length = 0 + @tempvisualDescentPointIcons;
    my $tempvisualDescentPointIcons_count =
      $tempvisualDescentPointIcons_length / 2;

    if ( $tempvisualDescentPointIcons_length >= 2 ) {
        for (
            my $i = 0 ;
            $i < $tempvisualDescentPointIcons_length ;
            $i = $i + 2
          )
        {

            #put them into a hash
            $visualDescentPointIcons{$i}{"X"} =
              $tempvisualDescentPointIcons[$i];
            $visualDescentPointIcons{$i}{"Y"} =
              $tempvisualDescentPointIcons[ $i + 1 ];
            $visualDescentPointIcons{$i}{"Name"} = "none";
        }

    }
    $visualDescentPointCount = keys(%visualDescentPointIcons);

    # if ($debug) {
    # say "Found $tempvisualDescentPointIcons_count Visual Descent Point icons";
    # say "";
    # }
    return;
}

sub convertPdfToPng {

    #---------------------------------------------------
    #Convert the PDF to a PNG
    my $pdfToPpmOutput;
    if ( -e $targetpng ) {
        say "$targetpng already exists";
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
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
    my $obstacleTextBoxRegex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($obstacleHeightRegex)</;

    foreach my $line (@pdfToTextBbox) {
        if ( $line =~ m/$obstacleTextBoxRegex/ ) {
            $obstacleTextBoxes{ $1 . $2 }{"RasterX"} =
              $1 * $scaleFactorX;    #BUG TODO
            $obstacleTextBoxes{ $1 . $2 }{"RasterY"} =
              $2 * $scaleFactorY;    #BUG TODO
            $obstacleTextBoxes{ $1 . $2 }{"Width"}  = $3 - $1;
            $obstacleTextBoxes{ $1 . $2 }{"Height"} = $4 - $2;
            $obstacleTextBoxes{ $1 . $2 }{"Text"}   = $5;
            $obstacleTextBoxes{ $1 . $2 }{"PdfX"}   = $1;
            $obstacleTextBoxes{ $1 . $2 }{"PdfY"}   = $pdfYSize - $2;
            $obstacleTextBoxes{ $1 . $2 }{"boxCenterXPdf"} =
              $1 + ( ( $3 - $1 ) / 2 );
            $obstacleTextBoxes{ $1 . $2 }{"boxCenterYPdf"} = $pdfYSize - $2;
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

            $fixtextboxes{ $_fixXMin . $_fixYMin }{"RasterX"} =
              $_fixXMin * $scaleFactorX;    #BUG TODO;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"RasterY"} =
              $_fixYMin * $scaleFactorY;    #BUG TODO;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"Width"} =
              $_fixXMax - $_fixXMin;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"Height"} =
              $_fixYMax - $_fixYMin;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"Text"} = $_fixName;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"PdfX"} = $_fixXMin;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"PdfY"} =
              $pdfYSize - $_fixYMin;
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"boxCenterXPdf"} =
              $_fixXMin + ( ( $_fixXMax - $_fixXMin ) / 2 );
            $fixtextboxes{ $_fixXMin . $_fixYMin }{"boxCenterYPdf"} =
              $pdfYSize - $_fixYMin;
        }

    }
    if ($debug) {

        #print Dumper ( \%fixtextboxes );
        say "Found " .
          keys(%fixtextboxes) . " Potential Fix/GPS Waypoint text boxes";
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
 my $frequencyRegex = qr/\d\d\d\.[\d+]{1,3}/m;
    #my $frequencyRegex = qr/116.3/m;
    
    my $vorTextBoxRegex =
qr/^\s+<word xMin="($numberRegex)" yMin="($numberRegex)" xMax="$numberRegex" yMax="$numberRegex">($frequencyRegex)<\/word>$
^\s+<word xMin="$numberRegex" yMin="$numberRegex" xMax="($numberRegex)" yMax="($numberRegex)">([A-Z]{3})<\/word>$/m;
    
    my $invalidVorNamesRegex = qr/app|dep/i;

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
            ;
            my $_vorName = $tempVortac[ $i + 5 ];

            next if $_vorName =~ m/$invalidVorNamesRegex/;

            $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterX"} =
              $_vorXMin * $scaleFactorX;    #BUG TODO;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"RasterY"} =
              $_vorYMin * $scaleFactorY;    #BUG TODO;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Width"} =
              $_vorXMax - $_vorXMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Height"} =
              $_vorYMax - $_vorYMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"Text"} = $_vorName;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfX"} = $_vorXMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"PdfY"} =
              $pdfYSize - $_vorYMin;
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"boxCenterXPdf"} =
              $_vorXMin + ( ( $_vorXMax - $_vorXMin ) / 2 );
            $vorTextboxes{ $_vorXMin . $_vorYMin }{"boxCenterYPdf"} =
              $pdfYSize - $_vorYMin;
        }
    }
    if ($debug) {
        print Dumper ( \%vorTextboxes );
        say "Found " . keys(%vorTextboxes) . " Potential NAVAID text boxes";
        say "";
    }
    return;
}

sub matchObstacleIconToUniqueObstaclesFromDb {
    say ":matchObstacleIconToUniqueObstaclesFromDb" if $debug;

#Find a obstacle icon with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates of its closest height text box to unique_obstacles_from_db hash
#
#The key for %unique_obstacles_from_db is the height of each obstacle
    foreach my $key ( keys %unique_obstacles_from_db ) {

        foreach my $key2 ( keys %obstacleIcons ) {
            next unless ( $obstacleIcons{$key2}{"Name"} );

            if ( $obstacleIcons{$key2}{"Name"} eq $key ) {

                #print $obstacleTextBoxes{$key2}{"Text"} . "$key\n";
                $unique_obstacles_from_db{$key}{"Label"} =
                  $obstacleIcons{$key2}{"Name"};

                $unique_obstacles_from_db{$key}{"TextBoxX"} =
                  $obstacleIcons{$key2}{"TextBoxX"};

                $unique_obstacles_from_db{$key}{"TextBoxY"} =
                  $obstacleIcons{$key2}{"TextBoxY"};

            }

        }
    }
    return;
}

sub calculateRoughRealWorldExtentsOfRaster {

    #This is where we finally generate the real information for each plate
    foreach my $key ( sort keys %gcps ) {

#This code is for calculating the PDF x/y and lon/lat differences between every object
#to calculate the ratio between the two
        foreach my $key2 ( sort keys %gcps ) {
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
            if (
                (
                       $latitudeToPixelRatio < .00019
                    || $latitudeToPixelRatio > .00041
                )
                && (   $latitudeToPixelRatio < .00056
                    || $latitudeToPixelRatio > .00059 )
              )
            {
                if ($debug) {
                    say
"Bad latitudeToPixelRatio $latitudeToPixelRatio on $key-$key2 pair";
                }

                next;
            }

            # if (   $longitudeToLatitudeRatio < .65
            # || $longitudeToLatitudeRatio > 1.6 )
            if ( abs( $targetLonLatRatio - $longitudeToLatitudeRatio ) >= .125 )
            {
#At this point, we know our latitudeToPixelRatio is reasonably good but our longitudeToLatitudeRatio seems bad (so longitudeToPixelRatio is bad)
#Recalculate the longitudes of our upper left and lower right corners with something about right for this latitude
                say
"Bad longitudeToLatitudeRatio $longitudeToLatitudeRatio on $key-$key2 pair.  Target was $targetLonLatRatio";
                my $targetXyRatio =
                  0.000007 * ( $ulY**3 ) -
                  0.0002 *   ( $ulY**2 ) +
                  0.0037 *   ($ulY) + 1.034;
                my $guessAtLongitudeToPixelRatio =
                  $targetXyRatio * $latitudeToPixelRatio;
                say
"Setting longitudeToPixelRatio to $guessAtLongitudeToPixelRatio";
                $longitudeToPixelRatio = $guessAtLongitudeToPixelRatio;

                $ulX =
                  $gcps{$key}{"lon"} -
                  ( $gcps{$key}{"pngx"} * $longitudeToPixelRatio );
                $lrX =
                  $gcps{$key}{"lon"} +
                  (
                    abs( $pngXSize - $gcps{$key}{"pngx"} ) *
                      $longitudeToPixelRatio );

                #next;
            }

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
    say $gdal_translateoutput;

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
            $obstacle_box->rect(
                $obstacleTextBoxes{$key}{"PdfX"},
                $obstacleTextBoxes{$key}{"PdfY"} + 2,
                $obstacleTextBoxes{$key}{"Width"},
                -( $obstacleTextBoxes{$key}{"Height"} + 1 )
            );
            $obstacle_box->stroke;
        }
    }
    return;
}

sub removeUniqueObstaclesFromDbThatAreNotMatchedToIcons {

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
"unique_obstacles_from_db before deleting entries that share ObsIconX or Y:";
        print Dumper ( \%unique_obstacles_from_db );
        say "";
    }
    return;
}

sub removeUniqueObstaclesFromDbThatShareIcons {

#Find entries that share an ObsIconX and ObsIconY with another entry and create an array of them
    my @a;
    foreach my $key ( sort keys %unique_obstacles_from_db ) {

        foreach my $key2 ( sort keys %unique_obstacles_from_db ) {
            if (
                #Don't test an entry against itself
                ( $key ne $key2 )
                && ( $unique_obstacles_from_db{$key}{"ObsIconX"} ==
                    $unique_obstacles_from_db{$key2}{"ObsIconX"} )
                && ( $unique_obstacles_from_db{$key}{"ObsIconY"} ==
                    $unique_obstacles_from_db{$key2}{"ObsIconY"} )
              )
            {
                #Save the key to our array of keys to delete
                push @a, $key;

                # push @a, $key2;
                say "Duplicate obstacle" if $debug;
            }

        }
    }

    #Actually delete the entries
    foreach my $entry (@a) {
        delete $unique_obstacles_from_db{$entry};
    }
    return;
}

sub findFixesNearAirport {

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
        my $rows   = $sth->rows();
        my $fields = $sth->{NUM_OF_FIELDS};
        say
"Found $rows FIXES within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) from database";

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
"SELECT * FROM fixes WHERE  (Latitude >  $airportLatitudeDec - $radius ) and 
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
"Found $rows GPS waypoints within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) from database"
          if $debug;
        say "All $type fixes from database";
        say "We have selected $fields field(s)";
        say "We have selected $rows row(s)";

        #print Dumper ( \%gpswaypoints_from_db );
        say "";
    }
    return;
}
sub findNavaidsNearAirport {
    $radius = .3;

    #What type of fixes to look for
    my $type = "%";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
"SELECT * FROM navaids WHERE  (Latitude >  $airportLatitudeDec - $radius ) and 
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
        foreach my $key2 ( keys %fixtextboxes ) {
            $distance_to_closest_fixtextbox_x =
              $fixtextboxes{$key2}{"boxCenterXPdf"} -
              $gpsWaypointIcons{$key}{"iconCenterXPdf"};
            $distance_to_closest_fixtextbox_y =
              $fixtextboxes{$key2}{"boxCenterYPdf"} -
              $gpsWaypointIcons{$key}{"iconCenterYPdf"};

            my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
                  $distance_to_closest_fixtextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
#say "Hypotenuse: $hyp" if $debug;
            if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
                $distance_to_closest_fixtextbox = $hyp;
                $gpsWaypointIcons{$key}{"Name"} = $fixtextboxes{$key2}{"Text"};
                $gpsWaypointIcons{$key}{"TextBoxX"} =
                  $fixtextboxes{$key2}{"boxCenterXPdf"};
                $gpsWaypointIcons{$key}{"TextBoxY"} =
                  $fixtextboxes{$key2}{"boxCenterYPdf"};
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

sub deleteGpsWaypointsWithNoName {

    #clean up gpswaypoints
    #remove entries that have no name
    foreach my $key ( sort keys %gpsWaypointIcons ) {
        if ( $gpsWaypointIcons{$key}{"Name"} eq "none" )

        {
            delete $gpsWaypointIcons{$key};
        }
    }

    if ($debug) {
        say "gpswaypoints after deleting entries with no name";
        print Dumper ( \%gpsWaypointIcons );
        say "";
    }
    return;
}

sub deleteDuplicateGpsWaypoints {

#Remove duplicate gps waypoints, preferring the one closest to the Y center of the PDF
  OUTER:
    foreach my $key ( sort keys %gpsWaypointIcons ) {

 #my $hyp = sqrt( $distance_to_pdf_center_x**2 + $distance_to_pdf_center_y**2 );
        foreach my $key2 ( sort keys %gpsWaypointIcons ) {

            if (
                (
                    $gpsWaypointIcons{$key}{"Name"} eq
                    $gpsWaypointIcons{$key2}{"Name"}
                )
                && ( $key ne $key2 )
              )
            {
                my $name = $gpsWaypointIcons{$key}{"Name"};
                say "A ha, I found a duplicate GPS waypoint name: $name"
                  if $debug;
                my $distance_to_pdf_center_x1 =
                  abs(
                    $pdfCenterX - $gpsWaypointIcons{$key}{"iconCenterXPdf"} );
                my $distance_to_pdf_center_y1 =
                  abs(
                    $pdfCenterY - $gpsWaypointIcons{$key}{"iconCenterYPdf"} );
                say $distance_to_pdf_center_y1;
                my $distance_to_pdf_center_x2 =
                  abs(
                    $pdfCenterX - $gpsWaypointIcons{$key2}{"iconCenterXPdf"} );
                my $distance_to_pdf_center_y2 =
                  abs(
                    $pdfCenterY - $gpsWaypointIcons{$key2}{"iconCenterYPdf"} );
                say $distance_to_pdf_center_y2;

                if ( $distance_to_pdf_center_y1 < $distance_to_pdf_center_y2 ) {
                    delete $gpsWaypointIcons{$key2};
                    say "Deleting the 2nd entry" if $debug;
                    goto OUTER;
                }
                else {
                    delete $gpsWaypointIcons{$key};
                    say "Deleting the first entry" if $debug;
                    goto OUTER;
                }
            }

        }

    }
    return;
}

sub drawLineFromEachGpsWaypointToMatchedTextbox {

    #Draw a line from GPS waypoint icon to closest text boxes
    my $gpswaypoint_line = $page->gfx;

    foreach my $key ( sort keys %gpsWaypointIcons ) {
        $gpswaypoint_line->move(
            $gpsWaypointIcons{$key}{"iconCenterXPdf"},
            $gpsWaypointIcons{$key}{"iconCenterYPdf"}
        );
        $gpswaypoint_line->line(
            $gpsWaypointIcons{$key}{"TextBoxX"},
            $gpsWaypointIcons{$key}{"TextBoxY"}
        );
        $gpswaypoint_line->strokecolor('blue');
        $gpswaypoint_line->stroke;
    }
    return;
}

sub drawLineFromNavaidToMatchedTextbox {

    #Draw a line from NAVAID icon to closest text boxes
    my $navaidLine = $page->gfx;

    foreach my $key ( sort keys %vortacIcons ) {
        $navaidLine->move(
            $vortacIcons{$key}{"iconCenterXPdf"},
            $vortacIcons{$key}{"iconCenterYPdf"}
        );
        $navaidLine->line(
            $vortacIcons{$key}{"TextBoxX"},
            $vortacIcons{$key}{"TextBoxY"}
        );
        $navaidLine->strokecolor('blue');
        $navaidLine->stroke;
    }
    return;
}

sub addObstaclesToGroundControlPoints {

    #Add obstacles to Ground Control Points hash
    foreach my $key ( sort keys %unique_obstacles_from_db ) {
        my $_obstacleRasterX =
          $unique_obstacles_from_db{$key}{"ObsIconX"} * $scaleFactorX;

        my $_obstacleRasterY =
          $pngYSize -
          ( $unique_obstacles_from_db{$key}{"ObsIconY"} * $scaleFactorY );

        my $lon = $unique_obstacles_from_db{$key}{"Lon"};

        my $lat = $unique_obstacles_from_db{$key}{"Lat"};

        if ( $_obstacleRasterX && $_obstacleRasterY && $lon && $lat ) {
            say "$_obstacleRasterX $_obstacleRasterY $lon $lat" if $debug;
            $gcps{ "obstacle" . $key }{"pngx"} = $_obstacleRasterX;
            $gcps{ "obstacle" . $key }{"pngy"} = $_obstacleRasterY;
            $gcps{ "obstacle" . $key }{"pdfx"} =
              $unique_obstacles_from_db{$key}{"ObsIconX"};
            $gcps{ "obstacle" . $key }{"pdfy"} =
              $unique_obstacles_from_db{$key}{"ObsIconY"};
            $gcps{ "obstacle" . $key }{"lon"} = $lon;
            $gcps{ "obstacle" . $key }{"lat"} = $lat;
        }
    }
    return;
}

sub addFixesToGroundControlPoints {

    #Add fixes to Ground Control Points hash
    say "";
    say "Fix Ground Control Points" if $debug;
    foreach my $key ( sort keys %fixIcons ) {
        my $_fixRasterX = $fixIcons{$key}{"X"} * $scaleFactorX;
        my $_fixRasterY = $pngYSize - ( $fixIcons{$key}{"Y"} * $scaleFactorY );
        my $lon         = $fixIcons{$key}{"Lon"};
        my $lat         = $fixIcons{$key}{"Lat"};

        if ( $_fixRasterX && $_fixRasterY && $lon && $lat ) {
            say "$_fixRasterX ,  $_fixRasterY , $lon , $lat" if $debug;
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"pngx"} = $_fixRasterX;
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"pngy"} = $_fixRasterY;
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"pdfx"} =
              $fixIcons{$key}{"X"};
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"pdfy"} =
              $fixIcons{$key}{"Y"};
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"lon"} = $lon;
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"lat"} = $lat;
        }
    }
    return;
}

sub addNavaidsToGroundControlPoints {

    #Add navaids to Ground Control Points hash
    say "";
    say "Navaid Ground Control Points" if $debug;
    foreach my $key ( sort keys %vortacIcons ) {
        my $_navaidRasterX = $vortacIcons{$key}{"iconCenterXPdf"} * $scaleFactorX;
        my $_navaidRasterY = $pngYSize - ( $vortacIcons{$key}{"iconCenterYPdf"} * $scaleFactorY );
        my $lon         = $vortacIcons{$key}{"Lon"};
        my $lat         = $vortacIcons{$key}{"Lat"};

        if ( $_navaidRasterX && $_navaidRasterY && $lon && $lat ) {
            say "$_navaidRasterX ,  $_navaidRasterY , $lon , $lat" if $debug;
            $gcps{ "navaid" . $vortacIcons{$key}{"Name"} }{"pngx"} = $_navaidRasterX;
            $gcps{ "navaid" . $vortacIcons{$key}{"Name"} }{"pngy"} = $_navaidRasterY;
            $gcps{ "navaid" . $vortacIcons{$key}{"Name"} }{"pdfx"} =
              $vortacIcons{$key}{"iconCenterXPdf"};
            $gcps{ "navaid" . $vortacIcons{$key}{"Name"} }{"pdfy"} =
              $vortacIcons{$key}{"iconCenterYPdf"};
            $gcps{ "navaid" . $vortacIcons{$key}{"Name"} }{"lon"} = $lon;
            $gcps{ "navaid" . $vortacIcons{$key}{"Name"} }{"lat"} = $lat;
        }
    }
    return;
}

sub addGpsWaypointsToGroundControlPoints {

    #Add GPS waypoints to Ground Control Points hash
    say "";
    say "GPS waypoint Ground Control Points" if $debug;
    foreach my $key ( sort keys %gpsWaypointIcons ) {

        my $_waypointRasterX =
          $gpsWaypointIcons{$key}{"iconCenterXPdf"} * $scaleFactorX;
        my $_waypointRasterY =
          $pngYSize -
          ( $gpsWaypointIcons{$key}{"iconCenterYPdf"} * $scaleFactorY );
        my $lon = $gpsWaypointIcons{$key}{"Lon"};
        my $lat = $gpsWaypointIcons{$key}{"Lat"};

        #Make sure all of these variables are defined before we use them as GCP
        if ( $_waypointRasterX && $_waypointRasterY && $lon && $lat ) {

            say "$_waypointRasterX , $_waypointRasterY , $lon , $lat" if $debug;
            $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"pngx"} =
              $_waypointRasterX;
            $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"pngy"} =
              $_waypointRasterY;
            $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"pdfx"} =
              $gpsWaypointIcons{$key}{"iconCenterXPdf"};
            $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"pdfy"} =
              $gpsWaypointIcons{$key}{"iconCenterYPdf"};
            $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"lon"} = $lon;
            $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"lat"} = $lat;
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

sub matchDatabaseResultsToIcons {

#Updates unique_obstacles_from_db
#Try to find closest obstacle icon to each text box for the obstacles in unique_obstacles_from_db
    foreach my $key ( sort keys %unique_obstacles_from_db ) {
        my $distance_to_closest_obstacle_icon_x;
        my $distance_to_closest_obstacle_icon_y;
        my $distance_to_closest_obstacle_icon = 999999999999;

        foreach my $key2 ( keys %obstacleIcons ) {
            next
              unless ( ( $unique_obstacles_from_db{$key}{"TextBoxX"} )
                && ( $unique_obstacles_from_db{$key}{"TextBoxY"} )
                && ( $obstacleIcons{$key2}{"X"} )
                && ( $obstacleIcons{$key2}{"Y"} ) );

            $distance_to_closest_obstacle_icon_x =
              $unique_obstacles_from_db{$key}{"TextBoxX"} -
              $obstacleIcons{$key2}{"X"};

            $distance_to_closest_obstacle_icon_y =
              $unique_obstacles_from_db{$key}{"TextBoxY"} -
              $obstacleIcons{$key2}{"Y"};

  #Calculate the straight line distance between the text box center and the icon
            my $hyp = sqrt( $distance_to_closest_obstacle_icon_x**2 +
                  $distance_to_closest_obstacle_icon_y**2 );

            if (   ( $hyp < $distance_to_closest_obstacle_icon )
                && ( $hyp < $maxDistanceFromObstacleIconToTextBox ) )
            {
                #Update the distsance to the closest icon
                $distance_to_closest_obstacle_icon = $hyp;

              #Tie the parameters of that icon to our obstacle found in database
                $unique_obstacles_from_db{$key}{"ObsIconX"} =
                  $obstacleIcons{$key2}{"X"};
                $unique_obstacles_from_db{$key}{"ObsIconY"} =
                  $obstacleIcons{$key2}{"Y"};
                $unique_obstacles_from_db{$key}{"potentialTextBoxes"} =
                  $obstacleIcons{$key2}{"potentialTextBoxes"};
            }

        }

    }

    if ($debug) {
        say
"unique_obstacles_from_db before deleting entries with no ObsIconX or Y:";
        print Dumper ( \%unique_obstacles_from_db );
        say "";
    }
    return;
}

sub outlineValidFixTextBoxes {
    foreach my $key ( keys %fixtextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $fixes_from_db{ $fixtextboxes{$key}{"Text"} } ) {
            my $fix_box = $page->gfx;

            #Yes, draw an orange box around it
            $fix_box->rect(
                $fixtextboxes{$key}{"PdfX"},
                $fixtextboxes{$key}{"PdfY"} + 2,
                $fixtextboxes{$key}{"Width"},
                -( $fixtextboxes{$key}{"Height"} + 1 )
            );
            $fix_box->strokecolor('orange');
            $fix_box->stroke;
        }
        else {
            #delete $fixtextboxes{$key};
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
            #delete $fixtextboxes{$key};
        }
    }
    return;
}
sub findClosestFixTextBoxToFixIcon {

    #Try to find closest fixtextbox to each fix icon
    foreach my $key ( sort keys %fixIcons ) {
        my $distance_to_closest_fixtextbox_x;
        my $distance_to_closest_fixtextbox_y;

        #Initialize this to a very high number so everything is closer than it
        my $distance_to_closest_fixtextbox = 999999999999;
        foreach my $key2 ( keys %fixtextboxes ) {
            $distance_to_closest_fixtextbox_x =
              $fixtextboxes{$key2}{"boxCenterXPdf"} - $fixIcons{$key}{"X"};
            $distance_to_closest_fixtextbox_y =
              $fixtextboxes{$key2}{"boxCenterYPdf"} - $fixIcons{$key}{"Y"};

            my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
                  $distance_to_closest_fixtextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
#say "Hypotenuse: $hyp" if $debug;
            if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
                $distance_to_closest_fixtextbox = $hyp;
                $fixIcons{$key}{"Name"} = $fixtextboxes{$key2}{"Text"};
                $fixIcons{$key}{"TextBoxX"} =
                  $fixtextboxes{$key2}{"boxCenterXPdf"};
                $fixIcons{$key}{"TextBoxY"} =
                  $fixtextboxes{$key2}{"boxCenterYPdf"};
                $fixIcons{$key}{"Lat"} =
                  $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lat"};
                $fixIcons{$key}{"Lon"} =
                  $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lon"};
            }

        }

    }
    return;
}

sub matchClosestNavaidTextBoxToNavaidIcon {

    #Try to find closest vorTextbox to each navaid icon
    foreach my $key ( sort keys %vortacIcons ) {
        my $distanceToClosestNavaidTextbox_X;
        my $distanceToClosestNavaidTextbox_Y;

        #Initialize this to a very high number so everything is closer than it
        my $distanceToClosestNavaidTextbox = 999999999999;
        foreach my $key2 ( keys %vorTextboxes ) {
            $distanceToClosestNavaidTextbox_X =
              $vorTextboxes{$key2}{"boxCenterXPdf"} - $vortacIcons{$key}{"X"};
            $distanceToClosestNavaidTextbox_Y =
              $vorTextboxes{$key2}{"boxCenterYPdf"} - $vortacIcons{$key}{"Y"};

            my $hyp = sqrt( $distanceToClosestNavaidTextbox_X**2 +
                  $distanceToClosestNavaidTextbox_Y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
#say "Hypotenuse: $hyp" if $debug;
            if ( ( $hyp < $distanceToClosestNavaidTextbox ) && ( $hyp < 150 ) ) {
                $distanceToClosestNavaidTextbox = $hyp;
                $vortacIcons{$key}{"Name"} = $vorTextboxes{$key2}{"Text"};
                $vortacIcons{$key}{"TextBoxX"} =
                  $vorTextboxes{$key2}{"boxCenterXPdf"};
                $vortacIcons{$key}{"TextBoxY"} =
                  $vorTextboxes{$key2}{"boxCenterYPdf"};
                $vortacIcons{$key}{"Lat"} =
                  $navaids_from_db{ $vortacIcons{$key}{"Name"} }{"Lat"};
                $vortacIcons{$key}{"Lon"} =
                  $navaids_from_db{ $vortacIcons{$key}{"Name"} }{"Lon"};
            }

        }

    }
    return;
}

sub deleteFixIconsWithNoName {

    #clean up fixicons
    #remove entries that have no name
    foreach my $key ( sort keys %fixIcons ) {
        if ( $fixIcons{$key}{"Name"} eq "none" )

        {
            delete $fixIcons{$key};
        }
    }

    if ($debug) {
        say "fixicons after deleting entries with no name";
        print Dumper ( \%fixIcons );
        say "";
    }
    return;
}

sub drawLineFromEacFixToClosestTextBox {

    #Draw a line from fix icon to closest text boxes
    my $fix_line = $page->gfx;
    foreach my $key ( sort keys %fixIcons ) {
        $fix_line->move( $fixIcons{$key}{"X"}, $fixIcons{$key}{"Y"} );
        $fix_line->line( $fixIcons{$key}{"TextBoxX"},
            $fixIcons{$key}{"TextBoxY"} );
        $fix_line->strokecolor('blue');
        $fix_line->stroke;
    }
    return;
}

sub outlineValidGpsWaypointTextBoxes {

    #Orange outline fixtextboxes that have a valid fix name in them
    #Delete fixtextboxes that don't have a valid nearby fix in them
    foreach my $key ( keys %fixtextboxes ) {

        #Is there a fixtextbox with the same text as our fix?
        if ( exists $gpswaypoints_from_db{ $fixtextboxes{$key}{"Text"} } ) {
            my $fix_box = $page->gfx;

            #Yes, draw an orange box around it
            $fix_box->rect(
                $fixtextboxes{$key}{"PdfX"},
                $fixtextboxes{$key}{"PdfY"} + 2,
                $fixtextboxes{$key}{"Width"},
                -( $fixtextboxes{$key}{"Height"} + 1 )
            );
            $fix_box->strokecolor('orange');
            $fix_box->stroke;
        }
        else {
            #delete $fixtextboxes{$key};

        }
    }
    return;
}

sub countObstacleIconsWithOnePotentialTextbox {
    my $_countOfObstaclesWithOnePotentialTextbox = 0;
    foreach my $key ( sort keys %unique_obstacles_from_db ) {

        if ( $unique_obstacles_from_db{$key}{"potentialTextBoxes"} == 1 ) {
            $_countOfObstaclesWithOnePotentialTextbox++;
        }
    }

    if ($debug) {
        say
"$_countOfObstaclesWithOnePotentialTextbox Obtacles that have only 1 potentialTextBoxes";
    }
    return $_countOfObstaclesWithOnePotentialTextbox;
}

sub drawLineFromEachToUniqueObstaclesFromDbToClosestTextBox {

    #Draw a line from obstacle icon to closest text boxes
    #These will be what we use for GCPs
    my $obstacle_line = $page->gfx;
    $obstacle_line->strokecolor('blue');
    foreach my $key ( sort keys %unique_obstacles_from_db ) {
        $obstacle_line->move(
            $unique_obstacles_from_db{$key}{"ObsIconX"},
            $unique_obstacles_from_db{$key}{"ObsIconY"}
        );
        $obstacle_line->line(
            $unique_obstacles_from_db{$key}{"TextBoxX"},
            $unique_obstacles_from_db{$key}{"TextBoxY"}
        );
        $obstacle_line->stroke;
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
}

