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

#Known issues:
#-Change the logic for obstacles to find nearest tittbox to icon and not vice versa (the current method)
#-Relies on icons being drawn very specific ways, it won't work if these ever change
#-Relies on text being in PDF.  It seems that most, if not all, military plates have no text in them
#-There has been no attempt to optimize anything yet or make code modular
#-Investigate not creating the intermediate PNG
#-Accumulate GCPs across the streams
#-The biggest issue now is matching icons with their identifying textboxes
#  How  best to guess right most of the time?
#  and when we guess wrong, how to detect and discard invalid guesses?
#  -Could check that aspect ratio using our ULLR matches the original image?  This has been done but the ratio seems to be always slightly different
# The PDFs are .65 X/Y and the resulting mapped images seem to be in the .75 - .83 range.
#The value of our xyratios needs to take into account latitude!
#                                                        X-SCALE                                       Y-SCALE                                   ULX                                              ULY
#Bangor, Maine          BGR     0.0005318785634374              -0.00038261152266649       -69.15670802663277072        45.10829970174832226
#St. Croix, USVI           STX
#BGR (me)		                        (program)
#0.0005318785634374	        5.3540828516360651e-04
#0
#0
#-0.00038261152266649	-3.8172963796815988e-04
#-69.15670802663277072	-6.9160278323393101e+01
#45.10829970174832226	4.5107633174318899e+01          .5
#
#STX (me)                                       Program
#0.00040122417555102	        4.0165290291643130e-04
#0
#0
#-0.00038355580703	        -3.8833730722177823e-04
#-65.21300867172351445	-6.5213436665224805e+01
#18.08436892351955549	1.8089189935643901e+01          .90
#
#ANC (me)                                       (program)
#0.00078335235550085            7.7601481323124482e-04
#0
#0
#-0.00037893900966343           -3.8242274703357643e-04
#-150.8658748280883799          -1.5084643779054099e+02
#61.54208634064045924           6.1555378096972902e+01          .23c


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

#PDF constants
use constant mm => 25.4 / 72;
use constant in => 1 / 72;
use constant pt => 1;

#Some subroutines
use GeoReferencePlatesSubroutines;

#Some other constants
#----------------------------------------------------------------------------------------------
#Max allowed radius in PDF units from an icon (obstacle, fix, gps) to it's associated textbox's center
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

my ( $output, $targetPdf );

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

#Open the input PDF
open my $file, '<', $targetPdf
  or croak "can't open '$targetPdf' for reading : $!";
close $file;

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

my $fudge = ( cos( deg2rad($airportLatitudeDec) ) )**2;
say "Fudge $fudge at Latitude $airportLatitudeDec";

# $cosine =  cos($radians);
# $fudge = $cosine**2;
# #$fudge = Math.pow(Math.cos(Math.toRadians(<lat>)),2);

#Get the mediabox size and other variables from the PDF
my ( $pdfXSize, $pdfYSize, $pdfCenterX, $pdfCenterY, $pdfXYRatio ) =
  getMediaboxSize();

#---------------------------------------------------
#Convert the PDF to a PNG
my $pdfToPpmOutput;

$pdfToPpmOutput = qx(pdftoppm -png -r $pngDpi $targetPdf > $targetpng);

$retval = $? >> 8;
die "Error from pdftoppm.   Return code is $retval" if $retval != 0;

#Get PNG dimensions and the PDF->PNG scale factors
my ( $pngXSize, $pngYSize, $scaleFactorX, $scaleFactorY, $pngXYRatio ) =
  getPngSize();

#--------------------------------------------------------------------------------------------------------------
#Get number of objects/streams in the targetpdf
my $objectstreams = getNumberOfStreams();

# #Some regex building blocks to be used elsewhere
# my $transformReg = qr/
# \A
# q 1 0 0 1 (?<transformRegX>[\.0-9]+) (?<transformRegY>[\.0-9]+) cm
# \Z
# /x;
# my $originReg = qr/\A0 0 m\Z/;
# my $coordinateReg =qr/[\.0-9]+ [\.0-9]+/;
#
# my $lineReg = qr/\A$coordinateReg l\Z/;
# my $bezierReg = qr/\A$coordinateReg $coordinateReg $coordinateReg c\Z/;
my $obstacleHeightRegex = qr/[1-9]\d{2,}/;

#Finding each of these icon types can be rolled into one loop per stream instead of separate one for each type
#----------------------------------------------------------------------------------------------------------
#Find obstacle icons in the pdf
#F*  Fill path
#S     Stroke path
#cm Scale and translate coordinate space
#c      Bezier curve
#q     Save graphics state
#Q     Restore graphics state
# my $obstacleregex =
# qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([\.0-9]+) ([\.0-9]+) l [\.0-9]+ [\.0-9]+ l S Q q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c f\* Q/;

#                           0x               1y                                     2+x         3+y                                                                               4dotX     5dotY

my %obstacleIcons = ();
my $obstacleCount = 0;
#%obstacleIcons = findObstacleIcons ($streamText, \@array, $scalar);
findObstacleIcons();

#Find all of the FIX icons
my %fixIcons = ();
my $fixCount = 0;
findFixIcons();

#Find all of the GPS waypoint icons
my %gpsWaypointIcons = ();
my $gpsCount         = 0;
findGpsWaypointIcons();

#Find Final Approach Fix icons
my %finalApproachFixIcons = ();
my $finalApproachFixCount = 0;
findFinalApproachFixIcons();


# #--------------------------------------------------------------------------------------------------------

#Find Visual Descent Point icons
my %visualDescentPointIcons = ();
my $visualDescentPointCount =0;
findVisualDescentPointIcons();


#Get all of the text and respective bounding boxes in the PDF
my @pdfToTextBbox = qx(pdftotext $targetPdf -bbox - );
$retval = $? >> 8;
die "No output from pdftotext -bbox.  Is it installed? Return code was $retval"
  if ( @pdfToTextBbox eq "" || $retval != 0 );

#-----------------------------------------------------------------------------------------------------------
#Get list of potential obstacle height textboxes
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#Look for 3+ digit numbers not starting or ending in 0
my $obstacletextboxregex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($obstacleHeightRegex)</;

my %obstacleTextBoxes = ();

foreach my $line (@pdfToTextBbox) {
    if ( $line =~ m/$obstacletextboxregex/ ) {
        $obstacleTextBoxes{ $1 . $2 }{"RasterX"} = $1 * $scaleFactorX; #BUG TODO
        $obstacleTextBoxes{ $1 . $2 }{"RasterY"} = $2 * $scaleFactorY; #BUG TODO
        $obstacleTextBoxes{ $1 . $2 }{"Width"}   = $3 - $1;
        $obstacleTextBoxes{ $1 . $2 }{"Height"}  = $4 - $2;
        $obstacleTextBoxes{ $1 . $2 }{"Text"}    = $5;
        $obstacleTextBoxes{ $1 . $2 }{"PdfX"}    = $1;
        $obstacleTextBoxes{ $1 . $2 }{"PdfY"}    = $pdfYSize - $2;
        $obstacleTextBoxes{ $1 . $2 }{"boxCenterXPdf"} =
          $1 + ( ( $3 - $1 ) / 2 );
        $obstacleTextBoxes{ $1 . $2 }{"boxCenterYPdf"}      = $pdfYSize - $2;
        $obstacleTextBoxes{ $1 . $2 }{"IconsThatPointToMe"} = 0;
    }

}

#print Dumper ( \%obstacleTextBoxes );
say "Found " . keys(%obstacleTextBoxes) . " Potential obstacle text boxes";
say "";

#--------------------------------------------------------------------------
#Get list of potential fix/intersection/GPS waypoint  textboxes
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#We'll convert them to PDF coordinates
my $fixtextboxregex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([A-Z]{5})</;

my $invalidfixnamesregex = qr/tower|south|radar/i;
my %fixtextboxes         = ();

foreach my $line (@pdfToTextBbox) {
    if ( $line =~ m/$fixtextboxregex/ ) {
        my $_fixXMin = $1;
        my $_fixYMin = $2;
        my $_fixXMax = $3;
        my $_fixYMax = $4;
        my $_fixName = $5;

#Exclude invalid fix names.  A smarter way to do this would be to use the DB lookup to limit to local fix names
        next if $_fixName =~ m/$invalidfixnamesregex/;

        $fixtextboxes{ $_fixXMin . $_fixYMin }{"RasterX"} =
          $_fixXMin * $scaleFactorX;    #BUG TODO;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"RasterY"} =
          $_fixYMin * $scaleFactorY;    #BUG TODO;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"Width"} = $_fixXMax - $_fixXMin;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"Height"} =
          $_fixYMax - $_fixYMin;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"Text"} = $_fixName;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"PdfX"} = $_fixXMin;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"PdfY"} = $pdfYSize - $_fixYMin;
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"boxCenterXPdf"} =
          $_fixXMin + ( ( $_fixXMax - $_fixXMin ) / 2 );
        $fixtextboxes{ $_fixXMin . $_fixYMin }{"boxCenterYPdf"} =
          $pdfYSize - $_fixYMin;
    }

}

#print Dumper ( \%fixtextboxes );
say "Found " . keys(%fixtextboxes) . " Potential Fix/GPS Waypoint text boxes";
say "";

#----------------------------------------------------------------------------------------------------------
#Modify the PDF
my $pdf = PDF::API2->open($targetPdf);

#Set up the various types of boxes to draw on the output PDF
my $page = $pdf->openpage(1);

#Draw boxes around what we've found so far
outlineEverythingWeFound();

#Try to find closest obstacleTextBox center to each obstacleIcon
foreach my $key ( sort keys %obstacleIcons ) {
    my $distance_to_closest_obstacletextbox = 999999999999
      ;    #Start with a very high number so initially is closer than it

    foreach my $key2 ( keys %obstacleTextBoxes ) {
        my $distanceToObstacletextboxX;
        my $distanceToObstacletextboxY;

        $distanceToObstacletextboxX =
          $obstacleTextBoxes{$key2}{"boxCenterXPdf"} -
          $obstacleIcons{$key}{"X"};
        $distanceToObstacletextboxY =
          $obstacleTextBoxes{$key2}{"boxCenterYPdf"} -
          $obstacleIcons{$key}{"Y"};

        my $hypotenuse = sqrt(
            $distanceToObstacletextboxX**2 + $distanceToObstacletextboxY**2 );

       #Ignore this textbox if it's further away than our max distance variables
        next if ( !( $hypotenuse < $maxDistanceFromObstacleIconToTextBox ) );

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

            $obstacleIcons{$key}{"Name"} = $obstacleTextBoxes{$key2}{"Text"};

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

#Draw a line from obstacle icon to closest text boxes
drawLineFromEachObstacleToClosestTextBox();

#--------------------------------------------------------------------------
#Get a list of potential obstacle heights from the PDF text array
my @obstacle_heights = findObstacleHeightTexts(@pdftotext);

#Remove any duplicates
onlyuniq(@obstacle_heights);

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Find obstacles with a certain height in the DB
my $radius = ".3";    # +/- degrees of longitude or latitude (~15 miles)

my %unique_obstacles_from_db = ();
my $unique_obstacles_from_dbCount;
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

if ($debug) {
    say
"Found $unique_obstacles_from_dbCount OBSTACLES with unique heights within $radius degrees of airport from database";
    say "unique_obstacles_from_db:";
    print Dumper ( \%unique_obstacles_from_db );
    say "";
}

#Find a obstacle icon with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates its closest height text box to unique_obstacles_from_db hash
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

#Find a text box with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates of that box to unique_obstacles_from_db hash
#TODO BUG:  If there are multiple textboxes with the same "text" as the height of our obstacle then TextBoxX and TextBoxY
# may be overwritten with bad values (eg GA-SSI-VOR-RWY-04.pdf)
#
#The key for %unique_obstacles_from_db is the height of each obstacle
#This is working, uncomment if the above routine causes havoc
# foreach my $key ( keys %unique_obstacles_from_db ) {
# foreach my $key2 ( keys %obstacleTextBoxes ) {

# if ( $obstacleTextBoxes{$key2}{"Text"} eq $key ) {
# #print $obstacleTextBoxes{$key2}{"Text"} . "$key\n";
# $unique_obstacles_from_db{$key}{"Label"} =
# $obstacleTextBoxes{$key2}{"Text"};
# $unique_obstacles_from_db{$key}{"TextBoxX"} =
# $obstacleTextBoxes{$key2}{"boxCenterXPdf"};
# $unique_obstacles_from_db{$key}{"TextBoxY"} =
# $obstacleTextBoxes{$key2}{"boxCenterYPdf"};

# }

# }
# }

#Only outline our unique potential obstacle_heights with green
foreach my $key ( sort keys %obstacleTextBoxes ) {

    #Is there a obstacletextbox with the same text as our obstacle's height?
    if ( exists $unique_obstacles_from_db{ $obstacleTextBoxes{$key}{"Text"} } )
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

#Find entries that share an ObsIconX and ObsIconY with another entry and create an array of them
my @a;
foreach my $key ( sort keys %unique_obstacles_from_db ) {

    foreach my $key2 ( sort keys %unique_obstacles_from_db ) {
        if (
            ( $key ne $key2 )
            && ( $unique_obstacles_from_db{$key}{"ObsIconX"} ==
                $unique_obstacles_from_db{$key2}{"ObsIconX"} )
            && ( $unique_obstacles_from_db{$key}{"ObsIconY"} ==
                $unique_obstacles_from_db{$key2}{"ObsIconY"} )
          )
        {
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

#If we have more than 2 obstacles that have only 1 potentialTextBoxes then remove all that have potentialTextBoxes > 1
my $countOfObstaclesWithOnePotentialTextbox = 0;
foreach my $key ( sort keys %unique_obstacles_from_db ) {
    if ( $unique_obstacles_from_db{$key}{"potentialTextBoxes"} == 1 ) {
        $countOfObstaclesWithOnePotentialTextbox++;
    }
}
say
"$countOfObstaclesWithOnePotentialTextbox Obtacles that have only 1 potentialTextBoxes";

if ( $countOfObstaclesWithOnePotentialTextbox > 2 ) {
    say "Gleefully deleting objects that have more than one potentialTextBoxes";

    # foreach my $key ( sort keys %unique_obstacles_from_db ) {
    # if  (!($unique_obstacles_from_db{$key}{"potentialTextBoxes"} == 1))
    # {
    # delete $unique_obstacles_from_db{$key};
    # }
    #}
}

#Draw a line from obstacle icon to closest text boxes
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

if ($debug) {
    say
      "Unique obstacles from database lookup that match with textboxes in PDF";
    print Dumper ( \%unique_obstacles_from_db );
    say "";
}

#------------------------------------------------------------------------------------------------------------------------------------------
#Find fixes near the airport
my %fixes_from_db = ();

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

#Orange outline fixtextboxes that have a valid fix name in them
#Delete fixtextboxes that don't have a valid nearby fix in them
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
            $fixIcons{$key}{"TextBoxX"} = $fixtextboxes{$key2}{"boxCenterXPdf"};
            $fixIcons{$key}{"TextBoxY"} = $fixtextboxes{$key2}{"boxCenterYPdf"};
            $fixIcons{$key}{"Lat"} =
              $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lat"};
            $fixIcons{$key}{"Lon"} =
              $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lon"};
        }

    }

}

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

#Draw a line from fix icon to closest text boxes
my $fix_line = $page->gfx;

foreach my $key ( sort keys %fixIcons ) {
    $fix_line->move( $fixIcons{$key}{"X"}, $fixIcons{$key}{"Y"} );
    $fix_line->line( $fixIcons{$key}{"TextBoxX"}, $fixIcons{$key}{"TextBoxY"} );
    $fix_line->strokecolor('blue');
    $fix_line->stroke;
}

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Find GPS waypoints near the airport
my %gpswaypoints_from_db = ();
$radius = .3;

#What type of fixes to look for
$type = "%";

#Query the database for fixes within our $radius
$sth = $dbh->prepare(
"SELECT * FROM fixes WHERE  (Latitude >  $airportLatitudeDec - $radius ) and 
                                (Latitude < $airportLatitudeDec +$radius ) and 
                                (Longitude >  $airportLongitudeDec - $radius ) and 
                                (Longitude < $airportLongitudeDec +$radius ) and
                                (Type like '$type')"
);
$sth->execute();
$allSqlQueryResults = $sth->fetchall_arrayref();

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
              $gpswaypoints_from_db{ $gpsWaypointIcons{$key}{"Name"} }{"Lat"};
            $gpsWaypointIcons{$key}{"Lon"} =
              $gpswaypoints_from_db{ $gpsWaypointIcons{$key}{"Name"} }{"Lon"};
        }

    }

}

#gpswaypoints_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {

    # say "gpswaypoints_from_db";
    # print Dumper ( \%gpswaypoints_from_db );
    say "";
    say "gps waypoint icons";
    print Dumper ( \%gpsWaypointIcons );
    say "";

    # say "fixtextboxes";
    # print Dumper ( \%fixtextboxes );
    say "";
}

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
            say "A ha, I found a duplicate GPS waypoint name: $name";
            my $distance_to_pdf_center_x1 =
              abs( $pdfCenterX - $gpsWaypointIcons{$key}{"iconCenterXPdf"} );
            my $distance_to_pdf_center_y1 =
              abs( $pdfCenterY - $gpsWaypointIcons{$key}{"iconCenterYPdf"} );
            say $distance_to_pdf_center_y1;
            my $distance_to_pdf_center_x2 =
              abs( $pdfCenterX - $gpsWaypointIcons{$key2}{"iconCenterXPdf"} );
            my $distance_to_pdf_center_y2 =
              abs( $pdfCenterY - $gpsWaypointIcons{$key2}{"iconCenterYPdf"} );
            say $distance_to_pdf_center_y2;

            if ( $distance_to_pdf_center_y1 < $distance_to_pdf_center_y2 ) {
                delete $gpsWaypointIcons{$key2};
                say "Deleting the 2nd entry";
                goto OUTER;
            }
            else {
                delete $gpsWaypointIcons{$key};
                say "Deleting the first entry";
                goto OUTER;
            }
        }

    }

}

#Draw a line from fix icon to closest text boxes
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

#Save our new PDF since we're done with it
if ($saveMarkedPdf) {
    $pdf->saveas($outputPdf);
}

#Close the database
$sth->finish();
$dbh->disconnect();

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Create the list of Ground Control Points
my %gcps;
say "";
say "Obstacle Ground Control Points" if $debug;

if ( !$rnavPlate ) {

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
            $gcps{ "obstacle" . $key }{"lon"}  = $lon;
            $gcps{ "obstacle" . $key }{"lat"}  = $lat;
        }
    }
}

if ( !$rnavPlate ) {

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
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"lon"}  = $lon;
            $gcps{ "fix" . $fixIcons{$key}{"Name"} }{"lat"}  = $lat;
        }
    }
}

#Add GPS waypoints to Ground Control Points hash
say "";
say "GPS waypoint Ground Control Points" if $debug;
foreach my $key ( sort keys %gpsWaypointIcons ) {

    my $_waypointRasterX =
      $gpsWaypointIcons{$key}{"iconCenterXPdf"} * $scaleFactorX;
    my $_waypointRasterY =
      $pngYSize - ( $gpsWaypointIcons{$key}{"iconCenterYPdf"} * $scaleFactorY );
    my $lon = $gpsWaypointIcons{$key}{"Lon"};
    my $lat = $gpsWaypointIcons{$key}{"Lat"};

    #Make sure all of these variables are defined before we use them as GCP
    if ( $_waypointRasterX && $_waypointRasterY && $lon && $lat ) {

        say "$_waypointRasterX , $_waypointRasterY , $lon , $lat" if $debug;
        $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"pngx"} =
          $_waypointRasterX;
        $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"pngy"} =
          $_waypointRasterY;
        $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"lon"} = $lon;
        $gcps{ "gps" . $gpsWaypointIcons{$key}{"Name"} }{"lat"} = $lat;
    }
}
if ($debug) {
    say "";
    say "GCPs";
    print Dumper ( \%gcps );
    say "";
}

my $gcpstring = "";
foreach my $key ( keys %gcps ) {

    #build the GCP portion of the command line parameters
    $gcpstring =
        $gcpstring
      . " -gcp "
      . $gcps{$key}{"pngx"} . " "
      . $gcps{$key}{"pngy"} . " "
      . $gcps{$key}{"lon"} . " "
      . $gcps{$key}{"lat"};
}
if ($debug) {
    say "Ground Control Points command line string";
    say $gcpstring;
    say "";
}

#Make sure we have enough GCPs
my $gcpCount = scalar( keys(%gcps) );
say "Found $gcpCount potential Ground Control Points";
die "Need more Ground Control Points" if ( $gcpCount < 2 );

#----------------------------------------------------------------------------------------------------------------------------------------------------
# #Try to georeference based on the list of Ground Control Points

# #my $gdal_translateCommand =  "gdal_translate -of VRT -strict  -a_srs \"+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs\" -co worldfile=yes  $gcpstring $targetpng  $targetvrt ";

# #If we ever want to try gdalwarp : "gdalwarp -of VRT -t_srs \"+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs\" -dstalpha -order 1  -overwrite  -r bilinear $gcpstring $targetpng $targetvrt";

# if ($debug) {
# say $gdal_translateCommand;
# say "";
# }

# #Run gdal_translate
# #Really we're just doing this for the worldfile.  I bet we could create it ourselves quicker
# my $gdal_translateoutput = qx($gdal_translateCommand);

# # $gdal_translateoutput =
# # qx(gdal_translate  -strict -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpng $targetvrt);
# $retval = $? >> 8;
# croak "No output from gdal_translate  Is it installed? Return code was $retval"
# if ( $gdal_translateoutput eq "" || $retval != 0 );
# say $gdal_translateoutput;

#Print a header so you could paste the following output into a spreadsheet to analyze
say
'$object1,$object2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2'
  if $debug;

#------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Calculate the X and Y scale values
my @xScaleAvg;
my @yScaleAvg;
my @ulXAvg;
my @ulYAvg;
my @lrXAvg;
my @lrYAvg;
my $scaleCounter = 0;

foreach my $key ( sort keys %gcps ) {

#This code is for calculating the PDF x/y and lon/lat differences between every object
#to calculate the ratio between the two
    foreach my $key2 ( sort keys %gcps ) {
        next if $key eq $key2;

        #X pixels between points
        my $pixelDistanceX = abs( $gcps{$key}{"pngx"} - $gcps{$key2}{"pngx"} );

        #Y pixels between points
        my $pixelDistanceY = abs( $gcps{$key}{"pngy"} - $gcps{$key2}{"pngy"} );

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
          $gcps{$key}{"lon"} - ( $gcps{$key}{"pngx"} * $longitudeToPixelRatio );

#For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
        my $ulY =
          $gcps{$key}{"lat"} + ( $gcps{$key}{"pngy"} * $latitudeToPixelRatio );

#For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
        my $lrX =
          $gcps{$key}{"lon"} +
          ( abs( $pngXSize - $gcps{$key}{"pngx"} ) * $longitudeToPixelRatio );

#For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
        my $lrY =
          $gcps{$key}{"lat"} -
          ( abs( $pngYSize - $gcps{$key}{"pngy"} ) * $latitudeToPixelRatio );

   #Go to next object pair if we've somehow gotten zero for any of these numbers
        next
          if ( $pixelDistanceX == 0
            || $pixelDistanceY == 0
            || $longitudeDiff == 0
            || $latitudeDiff == 0 );

#The X/Y (or Longitude/Latitude) ratio that would result from using this particular pair
#It should be very close to the XY ratio of the input PDF if we marked all GCPs correctly (I think?)
        my $longitudeToLatitudeRatio = abs( ( $ulX - $lrX ) / ( $ulY - $lrY ) );
        my $longitudeToLatitudeRatio2 =
          abs( ( ( $ulX - $lrX ) / $fudge ) / ( $ulY - $lrY ) );

        say
"$key,$key2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio,$longitudeToLatitudeRatio2"
          if $debug;

#If our XYRatio seems to be out of whack for this object pair then don't use the info we derived
#Currently we're just silently ignoring this, should we try to figure out the bad objects and remove?
        if (   $longitudeToLatitudeRatio < .65
            || $longitudeToLatitudeRatio > 1.45 )
        {
            say "Bad xYRatio $longitudeToLatitudeRatio on $key-$key2 pair";
            next;
        }

        if ( $latitudeToPixelRatio < .0003 || $latitudeToPixelRatio > .0008 ) {
            say
"Bad latitudeToPixelRatio $latitudeToPixelRatio on $key-$key2 pair";
            next;
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

#X-scale average and standard deviation
my ( $xAvg, $xMedian, $xStdDev ) = 0;
calculateXScale();

#Y-scale average and standard deviation
my ( $yAvg, $yMedian, $yStdDev ) = 0;
calculateYScale();

#ulX average and standard deviation
my ( $ulXAvrg, $ulXmedian, $ulXStdDev ) = 0;
calculateULX();

#uly average and standard deviation
my ( $ulYAvrg, $ulYmedian, $ulYStdDev ) = 0;
calculateULY();

#lrX average and standard deviation
my ( $lrXAvrg, $lrXmedian, $lrXStdDev ) = 0;
calculateLRX();

#lrY average and standard deviation
my ( $lrYAvrg, $lrYmedian, $lrYStdDev ) = 0;
calculateLRY();

#----------------------------------------------------------------------------------------------------------------------------------------------------
#Try to georeference based on Upper Left and Lower Right extents

# my $upperLeftLon  = $ulXAvrg;
# my $upperLeftLat  = $ulYAvrg;
# my $lowerRightLon = $lrXAvrg;
# my $lowerRightLat = $lrYAvrg;
my $upperLeftLon  = $ulXmedian;
my $upperLeftLat  = $ulYmedian;
my $lowerRightLon = $lrXmedian;
my $lowerRightLat = $lrYmedian;

my $medianLonDiff = $ulXmedian - $lrXmedian;
my $medianLatDiff = $ulYmedian - $lrYmedian;
my $lonLatRatio   = abs( $medianLonDiff / $medianLatDiff );
say "Output Longitude/Latitude Ratio: " . $lonLatRatio;
say "Input PDF ratio: " . $pdfXYRatio;
say "";

#Check that our determined scales and x/y ratios seem to make sense.  A
#if (abs($pdfXYRatio - $lonLatRatio) > .25) {
if ( abs($lonLatRatio) < .65 || abs($lonLatRatio) > 1.45 ) {
    say
"Longitude/Latitude output ratio is  out of whack ($lonLatRatio), we probably picked bad ground control points";
}

if ( abs($xMedian) < .0002 || abs($xMedian) > .0008) {

    #These test values are based on 300 dpi
    say
"X scale is out of whack ($xMedian), we probably picked bad ground control points";
}

if ( abs($yMedian) < .0003 || abs($yMedian) > .0004 ) {

    #These test values are based on 300 dpi
    say
"Y scale is out of whack ($yMedian), we probably picked bad ground control points";
}

my $xYMedianScaleRatio = $xMedian / $yMedian;

if ( abs($xYMedianScaleRatio) < 1.15 || abs($xYMedianScaleRatio) > 1.6 ) {

    #These test values are based on 300 dpi
    say
"pixel to real-world XY scale is out of whack ($xYMedianScaleRatio), we probably picked bad ground control points";
}

my $gdal_translateCommand =
"gdal_translate -of VRT -strict -a_srs \"+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs\" -co worldfile=yes  -a_ullr $upperLeftLon $upperLeftLat $lowerRightLon $lowerRightLat $targetpng  $targetvrt ";

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
croak "No output from gdal_translate  Is it installed? Return code was $retval"
  if ( $gdal_translateoutput eq "" || $retval != 0 );
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

if ($outputStatistics) {
    open my $file, '>>', $targetStatistics
      or croak "can't open '$targetStatistics' for writing : $!";

    say {$file}
'$dir$filename,$objectstreams,$obstacleCount,$fixCount,$gpsCount,$finalApproachFixCount,$visualDescentPointCount,$gcpCount,$unique_obstacles_from_dbCount,$pdfXYRatio,$lonLatRatio,$xAvg,$xMedian,$yAvg,$yMedian';

    say {$file}
"$dir$filename,$objectstreams,$obstacleCount,$fixCount,$gpsCount,$finalApproachFixCount,$visualDescentPointCount,$gcpCount,$unique_obstacles_from_dbCount,$pdfXYRatio,$lonLatRatio,$xAvg,$xMedian,$yAvg,$yMedian,$fudge"
      or croak "Cannot write to $targetStatistics: ";    #$OS_ERROR

    close $file;
}

#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------
sub findObstacleHeightTexts {

    #The text from the PDF
    my @pdftotext = @_;
    my @_obstacle_heights;

    foreach my $line (@pdftotext) {

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
        print join( " ", @obstacle_heights ), "\n";

        #Remove all entries that aren't unique
        @obstacle_heights = onlyuniq(@obstacle_heights);
        say "Unique potential obstacle heights from PDF";
        print join( " ", @obstacle_heights ), "\n";
    }
    return @_obstacle_heights;
}

sub findAirportLatitudeAndLongitude {

    #Get the lat/lon of the airport for the plate we're working on

    my $airportLatitudeDec  = "";
    my $airportLongitudeDec = "";

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

            $airportLatitudeDec =
              &coordinatetodecimal(
                $aptlatdeg . "-" . $aptlatmin . "-00" . $aptlatd );

            $airportLongitudeDec =
              &coordinatetodecimal(
                $aptlondeg . "-" . $aptlonmin . "-00" . $aptlond );

            say
"Airport LAT/LON from plate: $aptlatdeg-$aptlatmin-$aptlatd, $aptlondeg-$aptlonmin-$aptlond->$airportLatitudeDec $airportLongitudeDec"
              if $debug;
            return ( $airportLatitudeDec, $airportLongitudeDec );
        }

    }

    if ( $airportLongitudeDec eq "" or $airportLatitudeDec eq "" ) {

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
        my $allSqlQueryResults = $sth->fetchall_arrayref();

        foreach my $row (@$allSqlQueryResults) {
            my ( $airportFaaId, $airportname );
            (
                $airportFaaId, $airportLatitudeDec, $airportLongitudeDec,
                $airportname
            ) = @$row;
            say "Airport ID: $airportFaaId";
            say "Airport Latitude: $airportLatitudeDec";
            say "Airport Longitude: $airportLongitudeDec";
            say "Airport Name: $airportname";
        }
        if ( $airportLongitudeDec eq "" or $airportLatitudeDec eq "" ) {
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
    my $retval     = $? >> 8;
    die "No output from file.  Is it installed? Return code was $retval"
      if ( $fileoutput eq "" || $retval != 0 );

    foreach my $line ( split /[\r\n]+/, $fileoutput ) {
        ## Regular expression magic to grab what you want
        if ( $line =~ /([-\.0-9]+)\s+x\s+([-\.0-9]+)/ ) {
            $pngXSize = $1;
            $pngYSize = $2;
        }
    }

    #Calculate the ratios of the PNG/PDF coordinates
    my $scaleFactorX = $pngXSize / $pdfXSize;
    my $scaleFactorY = $pngYSize / $pdfYSize;
    my $pngXYRatio   = $pngXSize / $pngYSize;

    if ($debug) {
        say "PNG size: " . $pngXSize . "x" . $pngYSize;
        say "Scalefactor PDF->PNG X:  " . $scaleFactorX;
        say "Scalefactor PDF->PNG Y:  " . $scaleFactorY;
        say "PNG X/Y Ratio:  " . $pngXYRatio;
    }
    return ( $pngXSize, $pngYSize, $scaleFactorX, $scaleFactorY, $pngXYRatio );

}

sub getNumberOfStreams {

    #Get number of objects/streams in the targetpdf

    my $mutoolshowoutput = qx(mutool show $targetPdf x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $mutoolshowoutput eq "" || $retval != 0 );

    my $objectstreams;

    foreach my $line ( split /[\r\n]+/, $mutoolshowoutput ) {
        ## Regular expression magic to grab what you want
        if ( $line =~ /^(\d+)\s+(\d+)$/ ) {
            $objectstreams = $2;
        }
    }
    say "Object streams: " . $objectstreams;
    return $objectstreams;
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
        $obstacle_box->circle(
            $obstacleIcons{$key}{X},
            $obstacleIcons{$key}{Y},
            $maxDistanceFromObstacleIconToTextBox
        );
        $obstacle_box->strokecolor('pink');
        $obstacle_box->linewidth(.1);
        $obstacle_box->stroke;

    }

    foreach my $key ( sort keys %fixIcons ) {
        my $fix_box = $page->gfx;
        $fix_box->rect( $fixIcons{$key}{X} - 4, $fixIcons{$key}{Y} - 4, 9, 9 );
        $fix_box->strokecolor('yellow');
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
        $fix_box->stroke;
    }
    foreach my $key ( sort keys %gpsWaypointIcons ) {
        my $gpswaypoint_box = $page->gfx;
        $gpswaypoint_box->rect(
            $gpsWaypointIcons{$key}{X} - 1,
            $gpsWaypointIcons{$key}{Y} - 8,
            17, 16
        );
        $gpswaypoint_box->strokecolor('blue');
        $gpswaypoint_box->stroke;
    }

    foreach my $key ( sort keys %finalApproachFixIcons ) {
        my $faf_box = $page->gfx;
        $faf_box->rect(
            $finalApproachFixIcons{$key}{X} - 5,
            $finalApproachFixIcons{$key}{Y} - 5,
            10, 10
        );
        $faf_box->strokecolor('purple');
        $faf_box->stroke;
    }

    foreach my $key ( sort keys %visualDescentPointIcons ) {
        my $vdp_box = $page->gfx;
        $vdp_box->rect(
            $visualDescentPointIcons{$key}{X} - 3,
            $visualDescentPointIcons{$key}{Y} - 7,
            8, 8
        );
        $vdp_box->strokecolor('green');
        $vdp_box->stroke;
    }
    return;
}

sub drawLineFromEachObstacleToClosestTextBox {

    #Draw a line from obstacle icon to closest text boxes
    my $obstacle_line = $page->gfx;
    $obstacle_line->strokecolor('blue');
    foreach my $key ( sort keys %obstacleIcons ) {
        $obstacle_line->move( $obstacleIcons{$key}{"X"},
            $obstacleIcons{$key}{"Y"} );
        $obstacle_line->line(
            $obstacleIcons{$key}{"TextBoxX"},
            $obstacleIcons{$key}{"TextBoxY"}
        );
        $obstacle_line->stroke;
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

sub findGpsWaypointIcons {
    for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {

#Find first half of gps waypoint icons
# my $gpswaypointregex =
# qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+0 0 l\s+f\*\s+Q/;
        my $gpswaypointregex = qr/^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
^0 0 m$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ l$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ l$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c$
^0 0 l$
^f\*$
^Q$/m;

        $output = qx(mutool show $targetPdf $i x);
        $retval = $? >> 8;
        die
"No output from mutool show.  Is it installed? Return code was $retval"
          if ( $output eq "" || $retval != 0 );

        #Remove new lines
        #$output =~ s/\n/ /g;
        my @tempgpswaypoints        = $output =~ /$gpswaypointregex/ig;
        my $tempgpswaypoints_length = 0 + @tempgpswaypoints;
        my $tempgpswaypoints_count  = $tempgpswaypoints_length / 2;

        if ( $tempgpswaypoints_length >= 2 ) {
            say "Found $tempgpswaypoints_count GPS waypoints in stream $i";
            for ( my $i = 0 ; $i < $tempgpswaypoints_length ; $i = $i + 2 ) {

                #put them into a hash
                $gpsWaypointIcons{$i}{"X"} = $tempgpswaypoints[$i];
                $gpsWaypointIcons{$i}{"Y"} = $tempgpswaypoints[ $i + 1 ];
                $gpsWaypointIcons{$i}{"iconCenterXPdf"} =

                  #TODO Calculate this properly, this number is an estimation
                  $tempgpswaypoints[$i] + 7.5;
                $gpsWaypointIcons{$i}{"iconCenterYPdf"} =
                  $tempgpswaypoints[ $i + 1 ];
                $gpsWaypointIcons{$i}{"Name"} = "none";
            }

        }
    }
    $gpsCount = keys(%gpsWaypointIcons);
    say "Found $gpsCount GPS waypoint icons";
    say "";
    return;
}

sub findObstacleIcons {
    for ( my $stream = 0 ; $stream < ( $objectstreams - 1 ) ; $stream++ ) {

        #A regex that matches how an obstacle is drawn in the PDF
        my $obstacleregex = qr/^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm$
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
        $output = qx(mutool show $targetPdf $stream x);
        $retval = $? >> 8;
        die
"No output from mutool show.  Is it installed? Return code was $retval"
          if ( $output eq "" || $retval != 0 );

        #Remove new lines
        # $output =~ s/\n/ /g;

#each entry in @tempobstacles will have the numbered captures from the regex, 6 for each one
        my @tempobstacles = $output =~ /$obstacleregex/ig;
        my $tempobstacles_length = 0 + @tempobstacles;

#Divide length of array by 6 data points for each obstacle to get count of obstacles
        my $tempobstacles_count = $tempobstacles_length / 6;

        if ( $tempobstacles_length >= 6 ) {
            say "Found $tempobstacles_count obstacles in stream $stream";

            for ( my $i = 0 ; $i < $tempobstacles_length ; $i = $i + 6 ) {

#Note: this code does not accumulate the objects across streams but rather overwrites existing ones
#This works fine as long as the stream with all of the obstacles in the main section of the drawing comes after the streams
#with obstacles for the airport diagram (which is a separate scale)
#Put the info for each obstscle icon into a hash
#This finds the midpoint X of the obstacle triangle (basically the X,Y of the dot but the X,Y of the dot itself was too far right)
#For each icon: Offset      0: Starting X
#                                               1: Starting Y
#                                               2: X of top of triangle
#                                               3: Y of top of triangle
#                                               4: X of dot
#                                               5: Y of dot
                $obstacleIcons{$i}{"X"} =
                  $tempobstacles[$i] + $tempobstacles[ $i + 2 ];
                $obstacleIcons{$i}{"Y"} =
                  $tempobstacles[ $i + 1 ];    #+ $tempobstacles[ $i + 3 ];
                $obstacleIcons{$i}{"Height"} = "unknown";
                $obstacleIcons{$i}{"ObstacleTextBoxesThatPointToMe"} = 0;
                $obstacleIcons{$i}{"potentialTextBoxes"}             = 0;
            }

        }
    }

    #print Dumper ( \%obstacleIcons );
    $obstacleCount = keys(%obstacleIcons);

    say "Found $obstacleCount obstacle icons";
    say "";

}

sub findFixIcons {
    for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {

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
        $output = qx(mutool show $targetPdf $i x);
        $retval = $? >> 8;
        die
"No output from mutool show.  Is it installed? Return code was $retval"
          if ( $output eq "" || $retval != 0 );

        #Remove new lines
        # $output =~ s/\n/ /g;
        my @tempfixes = $output =~ /$fixregex/ig;
        my $tempfixes_length = 0 + @tempfixes;

        #4 data points for each fix
        #$1 = x
        #$2 = y
        #$3 = delta x (will be negative)
        #$4 = delta y (will be negative)
        my $tempfixes_count = $tempfixes_length / 4;

        if ( $tempfixes_length >= 4 ) {
            say "Found $tempfixes_count fix icons in stream $i";
            for ( my $i = 0 ; $i < $tempfixes_length ; $i = $i + 4 ) {

                #put them into a hash
                #code here is making the x/y the center of the triangle
                $fixIcons{$i}{"X"} =
                  $tempfixes[$i] + ( $tempfixes[ $i + 2 ] / 2 );
                $fixIcons{$i}{"Y"} =
                  $tempfixes[ $i + 1 ] + ( $tempfixes[ $i + 3 ] / 2 );
                $fixIcons{$i}{"Name"} = "none";
            }

        }
    }
    $fixCount = keys(%fixIcons);
    say "Found $fixCount fix icons";
    say "";
}

sub findFinalApproachFixIcons {
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {

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

    $output = qx(mutool show $targetPdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    #$output =~ s/\n/ /g;
    my @tempfinalApproachFixIcons = $output =~ /$fafRegex/ig;
    my $tempfinalApproachFixIcons_length = 0 + @tempfinalApproachFixIcons;
    my $tempfinalApproachFixIcons_count = $tempfinalApproachFixIcons_length / 2;

    if ( $tempfinalApproachFixIcons_length >= 2 ) {
        say "Found $tempfinalApproachFixIcons_count FAFs in stream $i";
        for ( my $i = 0 ; $i < $tempfinalApproachFixIcons_length ; $i = $i + 2 )
        {

            #put them into a hash
            $finalApproachFixIcons{$i}{"X"} = $tempfinalApproachFixIcons[$i];
            $finalApproachFixIcons{$i}{"Y"} =
              $tempfinalApproachFixIcons[ $i + 1 ];
            $finalApproachFixIcons{$i}{"Name"} = "none";
        }

    }
}
$finalApproachFixCount = keys(%finalApproachFixIcons);
say "Found $finalApproachFixCount Final Approach Fix icons";
say "";
}

sub findVisualDescentPointIcons {
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {

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

    $output = qx(mutool show $targetPdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempvisualDescentPointIcons = $output =~ /$vdpRegex/ig;
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
}
$visualDescentPointCount = keys(%visualDescentPointIcons);
say "Found $visualDescentPointCount Visual Descent Point icons";
say "";
}
