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
#Output some statistics from the process to see which plates are working

#Change the logic for obstacles to find nearest text to icon and not vice versa (the current method)

#Relies on icons being drawn very specific ways, it won't work if these ever change

#Relies on text being in PDF.  I've found at least one example that doesn't use text (plates from KSSC)

#Plates from KCDN are coming out of gdalwarp way too big.  Why?  the same command line works fine elsewhere

#There has been no attempt to optimize anything yet or make code modular

#Investigate not creating the intermediate PNG

#Accumulate GCPs across the streams

#Discard outliers (eg obstacles in the airport view box, or missed approach waypoints

#Very easy to mismatch obstacles with their height text.  How to weed out false ones?

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

#PDF constants
use constant mm => 25.4 / 72;
use constant in => 1 / 72;
use constant pt => 1;

#Some subroutines
use GeoReferencePlatesSubroutines;

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

my ( $output, $targetpdf );
my ( $pdfx, $pdfy, $pdfCenterX, $pdfCenterY, $pngx, $pngy );
my $retval;

#Get the target PDF file from command line options
$targetpdf = $ARGV[0];

#Get the airport ID in case we can't guess it from PDF (KSSC is an example)
my $airportid = $opt{a};
if ($airportid) {
    say "Supplied airport ID: $airportid";
}

say $targetpdf;
my ( $filename, $dir, $ext ) = fileparse( $targetpdf, qr/\.[^.]*/ );
my $outputpdf        = $dir . "marked-" . $filename . ".pdf";
my $targetpng        = $dir . $filename . ".png";
my $targettif        = $dir . $filename . ".tif";
my $targetvrt        = $dir . $filename . ".vrt";
my $targetStatistics = $dir . $filename . ".csv";

my $rnavPlate = 0;
die "Source file needs to be a PDF" if !( $ext =~ m/^\.pdf$/i );

if ( $filename =~ m/^\d+R/ ) {
    say "Input is a GPS plate, using only GPS waypoints for references";
    $rnavPlate = 1;
}
if ($debug) {
    say "Directory: " . $dir;
    say "File:      " . $filename;
    say "Suffix:    " . $ext;

    #Check that suffix is PDF for input file
    say "OutputPdf: $outputpdf";
    say "TargetPng: $targetpng";
    say "TargetTif: $targettif";
    say "TargetVrt: $targetvrt";
}

open my $file, '<', $targetpdf
  or die "can't open '$targetpdf' for reading : $!";
close $file;

#-----------------------------------------------
#Get the lat/lon of the airport for the plate we're working on
#This line will try to pull the lat/lon at the bottom of the drawing instead of a DB query
#pdftotext  <pdf_name> - | grep -P '\b\d+’[NS]-\d+’[EW]'
my $airportLatitudeDec  = "";
my $airportLongitudeDec = "";

my @pdftotext;
@pdftotext = qx(pdftotext $targetpdf  -enc ASCII7 -);
$retval    = $? >> 8;
die "No output from pdftotext.  Is it installed?  Return code was $retval"
  if ( @pdftotext eq "" || $retval != 0 );

#Die if the chart says it's not to scale
foreach my $line (@pdftotext) {
    if ( $line =~ m/chartnott/i ) {
        die "Chart not to scale, can't georeference";
    }

}

#-----------------------------------------------
#Open the database
my ( $dbh, $sth );
$dbh = DBI->connect(
    "dbi:SQLite:dbname=locationinfo.db",
    "", "", { RaiseError => 1 },
) or die $DBI::errstr;

#Try to pull out the lat/lon at the bottom of the chart, die if can't
foreach my $line (@pdftotext) {

    # if ( $line =~ m/(\d+)'([NS])\s?-\s?(\d+)'([EW])/ ) {
    if ( $line =~ m/([\d ]+)'([NS])\s?-\s?([\d ]+)'([EW])/ ) {
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
"Airport LAT/LON from plate: $airportLatitudeDec $airportLongitudeDec";
    }

}

if ( $airportLongitudeDec eq "" or $airportLatitudeDec eq "" ) {

    #We didn't get any airport info from the PDF, let's check the database
    #Get airport from database
    die
"You must specify an airport ID (eg. -a SMF) since there was no info on the PDF"
      if $airportid eq "";

    #Query the database for airport
    $sth = $dbh->prepare(
"SELECT  FaaID, Latitude, Longitude, Name  FROM airports  WHERE  FaaID = '$airportid'"
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
    die
"No airport coordinate information on PDF or database, try   -a <airport> "
      if ( $airportLongitudeDec eq "" or $airportLatitudeDec eq "" );
}

#----------------------------------------------------------
#Get the mediabox size from the PDF
my $mutoolinfo;
$mutoolinfo = qx(mutool info $targetpdf);
$retval     = $? >> 8;
die "No output from mutool info.  Is it installed? Return code was $retval"
  if ( $mutoolinfo eq "" || $retval != 0 );

foreach my $line ( split /[\r\n]+/, $mutoolinfo ) {
    ## Regular expression magic to grab what you want
    if ( $line =~ /([-\.0-9]+) ([-\.0-9]+) ([-\.0-9]+) ([-\.0-9]+)/ ) {
        $pdfx       = $3 - $1;
        $pdfy       = $4 - $2;
        $pdfCenterX = $pdfx / 2;
        $pdfCenterY = $pdfy / 2;
        say "PDF Mediabox size: " . $pdfx . "x" . $pdfy;
        say "PDF Mediabox center: " . $pdfCenterX . "x" . $pdfCenterY;
    }
}

#---------------------------------------------------
#Convert PDF to a PNG
my $pdftoppmoutput;
$pdftoppmoutput = qx(pdftoppm -png -r 300 $targetpdf > $targetpng);

$retval = $? >> 8;
die "Error from pdftoppm.   Return code is $retval" if $retval != 0;

#---------------------------------------------------------------------------------------------------------
#Find the dimensions of the PNG
my $fileoutput;
$fileoutput = qx(file $targetpng );
$retval     = $? >> 8;
die "No output from file.  Is it installed? Return code was $retval"
  if ( $fileoutput eq "" || $retval != 0 );

foreach my $line ( split /[\r\n]+/, $fileoutput ) {
    ## Regular expression magic to grab what you want
    if ( $line =~ /([-\.0-9]+)\s+x\s+([-\.0-9]+)/ ) {
        $pngx = $1;
        $pngy = $2;
    }
}

#Calculate the ratios of the PNG/PDF coordinates
my $scalefactorx = $pngx / $pdfx;
my $scalefactory = $pngy / $pdfy;

say "PNG size: " . $pngx . "x" . $pngy;
say "Scalefactor PDF->PNG X:  " . $scalefactorx;
say "Scalefactor PDF->PNG Y:  " . $scalefactory;

#--------------------------------------------------------------------------------------------------------------
#Get number of objects/streams in the targetpdf
my $mutoolshowoutput;
$mutoolshowoutput = qx(mutool show $targetpdf x);
$retval           = $? >> 8;
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

# #Some regex building blocks
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

#Finding each of these icons can be rolled into one loop instead of separate one for each type
#----------------------------------------------------------------------------------------------------------
#Find obstacles in the pdf
#F*  Fill path
#S     Stroke path
#cm Scale and translate coordinate space
#c      Bezier curve
#q     Save graphics state
#Q     Restore graphics state
my $obstacleregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([\.0-9]+) ([\.0-9]+) l [\.0-9]+ [\.0-9]+ l S Q q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c f\* Q/;

#                           0x               1y                                     2+x         3+y                                                                               4dotX     5dotY
# my $obstacleregex =
# qr/
# ^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm
# ^0 0 m
# ^([\.0-9]+) [\.0-9]+ l
# ^([\.0-9]+) [\.0-9]+ l
# ^S
# ^Q
# ^q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm
# ^0 0 m
# ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c
# ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c
# ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c
# ^[-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c
# ^f\*
# ^Q
# /m;
my %obstacleIcons = ();

for ( my $stream = 0 ; $stream < ( $objectstreams - 1 ) ; $stream++ ) {

    $output = qx(mutool show $targetpdf $stream x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;

#each entry in @tempobstacles will have the named captures from the regex, 6 for each one
    my @tempobstacles        = $output =~ /$obstacleregex/igm;
    my $tempobstacles_length = 0 + @tempobstacles;

    #6 data points for each obstacle
    my $tempobstacles_count = $tempobstacles_length / 6;

    if ( $tempobstacles_length >= 6 ) {
        say "Found $tempobstacles_count obstacles in stream $stream";
        for ( my $i = 0 ; $i < $tempobstacles_length ; $i = $i + 6 ) {

#Note: this code does not accumulate the objects across streams but rather overwrites existing ones
#This works fine as long as the stream with all of the obstacles in the main section of the drawing comes after the streams
#with obstacles for the airport diagram (which is a separate scale)
#Put them into a hash
#This finds the midpoint X of the obstacle triangle (the X,Y of the dot itself was too far right)

            $obstacleIcons{$i}{"X"} =
              $tempobstacles[$i] + $tempobstacles[ $i + 2 ];
            $obstacleIcons{$i}{"Y"} =
              $tempobstacles[ $i + 1 ];    #+ $tempobstacles[ $i + 3 ];
            $obstacleIcons{$i}{"Height"}                         = "unknown";
            $obstacleIcons{$i}{"ObstacleTextBoxesThatPointToMe"} = 0;
        }

    }
}

#print Dumper ( \%obstacleIcons );
say "Found " . keys(%obstacleIcons) . " obstacle icons";

# exit;
# #-------------------------------------------------------------------------------------------------------
# #Find fixes in the PDF
my $fixregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([-\.0-9]+) [\.0-9]+ l [-\.0-9]+ ([\.0-9]+) l 0 0 l S Q/;
my %fixIcons = ();
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempfixes        = $output =~ /$fixregex/ig;
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
            $fixIcons{$i}{"X"} = $tempfixes[$i] + ( $tempfixes[ $i + 2 ] / 2 );
            $fixIcons{$i}{"Y"} =
              $tempfixes[ $i + 1 ] + ( $tempfixes[ $i + 3 ] / 2 );
            $fixIcons{$i}{"Name"} = "none";
        }

    }
}

say "Found " . keys(%fixIcons) . " fix icons";

#--------------------------------------------------------------------------------------------------------
#Find first half of gps waypoint icons
my $gpswaypointregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+0 0 l\s+f\*\s+Q/;

my %gpsWaypointIcons = ();

for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
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
              $tempgpswaypoints[$i] + 7.5;    #TODO Calculate this properly
            $gpsWaypointIcons{$i}{"iconCenterYPdf"} =
              $tempgpswaypoints[ $i + 1 ];
            $gpsWaypointIcons{$i}{"Name"} = "none";
        }

    }
}
say "Found " . keys(%gpsWaypointIcons) . " GPS waypoint icons";

#--------------------------------------------------------------------------------------------------------
#Find Final Approach Fix icon
my $fafregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q/;
my %finalApproachFixIcons = ();
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempfinalApproachFixIcons        = $output =~ /$fafregex/ig;
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
say "Found " . keys(%finalApproachFixIcons) . " Final Approach Fix icons";

# #--------------------------------------------------------------------------------------------------------
# #Find Visual Descent Point icon
my $vdpregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+0.72 w \[\]0 d/;

my %visualDescentPointIcons = ();
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempvisualDescentPointIcons        = $output =~ /$vdpregex/ig;
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
say "Found " . keys(%visualDescentPointIcons) . " Visual Descent Point icons";

#Get all of the text and respective bounding boxes in the PDF
my @pdftotextbbox = qx(pdftotext $targetpdf -bbox - );
$retval = $? >> 8;
die "No output from pdftotext -bbox.  Is it installed? Return code was $retval"
  if ( @pdftotextbbox eq "" || $retval != 0 );

#-----------------------------------------------------------------------------------------------------------
#Get list of potential obstacle height textboxes
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#Look for 3+ digit numbers not starting or ending in 0
my $obstacletextboxregex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($obstacleHeightRegex)</;

my %obstacleTextBoxes = ();

foreach my $line (@pdftotextbbox) {
    if ( $line =~ m/$obstacletextboxregex/ ) {
        $obstacleTextBoxes{ $1 . $2 }{"RasterX"} = $1;
        $obstacleTextBoxes{ $1 . $2 }{"RasterY"} = $2;
        $obstacleTextBoxes{ $1 . $2 }{"Width"}   = $3 - $1;
        $obstacleTextBoxes{ $1 . $2 }{"Height"}  = $4 - $2;
        $obstacleTextBoxes{ $1 . $2 }{"Text"}    = $5;
        $obstacleTextBoxes{ $1 . $2 }{"PdfX"}    = $1;
        $obstacleTextBoxes{ $1 . $2 }{"PdfY"}    = $pdfy - $2;
        $obstacleTextBoxes{ $1 . $2 }{"iconCenterXPdf"} =
          $1 + ( ( $3 - $1 ) / 2 );
        $obstacleTextBoxes{ $1 . $2 }{"iconCenterYPdf"}     = $pdfy - $2;
        $obstacleTextBoxes{ $1 . $2 }{"IconsThatPointToMe"} = 0;
    }

}

#print Dumper ( \%obstacleTextBoxes );
say "Found " . keys(%obstacleTextBoxes) . " Potential obstacle text boxes";

#--------------------------------------------------------------------------
#Get list of potential fix/intersection/GPS waypoint  textboxes
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#We'll convert them to PDF coordinates
my $fixtextboxregex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([A-Z]{5})</;

my $invalidfixnamesregex = qr/tower|south/i;
my %fixtextboxes         = ();

foreach my $line (@pdftotextbbox) {
    if ( $line =~ m/$fixtextboxregex/ ) {

#Exclude invalid fix names.  A smarter way to do this would be to use the DB lookup to limit to local fix names
        next if $5 =~ m/$invalidfixnamesregex/;

        $fixtextboxes{ $1 . $2 }{"RasterX"}        = $1;
        $fixtextboxes{ $1 . $2 }{"RasterY"}        = $2;
        $fixtextboxes{ $1 . $2 }{"Width"}          = $3 - $1;
        $fixtextboxes{ $1 . $2 }{"Height"}         = $4 - $2;
        $fixtextboxes{ $1 . $2 }{"Text"}           = $5;
        $fixtextboxes{ $1 . $2 }{"PdfX"}           = $1;
        $fixtextboxes{ $1 . $2 }{"PdfY"}           = $pdfy - $2;
        $fixtextboxes{ $1 . $2 }{"iconCenterXPdf"} = $1 + ( ( $3 - $1 ) / 2 );
        $fixtextboxes{ $1 . $2 }{"iconCenterYPdf"} = $pdfy - $2;
    }

}

#print Dumper ( \%fixtextboxes );
say "Found " . keys(%fixtextboxes) . " Potential Fix text boxes";

#----------------------------------------------------------------------------------------------------------
#Modify the PDF
my $pdf = PDF::API2->open($targetpdf);

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

#Set up the various types of boxes to draw on the output PDF
my $page = $pdf->openpage(1);

#Draw the various types of boxes on the output PDF
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
    $obstacle_box->circle( $obstacleIcons{$key}{X},
        $obstacleIcons{$key}{Y}, 18 );
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
        $fixtextboxes{$key}{PdfX},    $fixtextboxes{$key}{PdfY} + 2,
        $fixtextboxes{$key}{"Width"}, -( $fixtextboxes{$key}{"Height"} + 2 )
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

#Try to find closest obstacleTextBox to each obstacle icon
foreach my $key ( sort keys %obstacleIcons ) {
    my $distance_to_closest_obstacletextbox_x;
    my $distance_to_closest_obstacletextbox_y;

    #Initialize this to a very high number so everything is closer than it
    my $distance_to_closest_obstacletextbox = 999999999999;
    foreach my $key2 ( keys %obstacleTextBoxes ) {
        $distance_to_closest_obstacletextbox_x =
          $obstacleTextBoxes{$key2}{"iconCenterXPdf"} -
          $obstacleIcons{$key}{"X"};
        $distance_to_closest_obstacletextbox_y =
          $obstacleTextBoxes{$key2}{"iconCenterYPdf"} -
          $obstacleIcons{$key}{"Y"};

        my $hyp = sqrt( $distance_to_closest_obstacletextbox_x**2 +
              $distance_to_closest_obstacletextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
#say "Hypotenuse: $hyp" if $debug;
        if ( ( $hyp < $distance_to_closest_obstacletextbox ) && ( $hyp < 27 ) )
        {
            $distance_to_closest_obstacletextbox = $hyp;
            $obstacleIcons{$key}{"Name"} = $obstacleTextBoxes{$key2}{"Text"};
            $obstacleIcons{$key}{"TextBoxX"} =
              $obstacleTextBoxes{$key2}{"iconCenterXPdf"};
            $obstacleIcons{$key}{"TextBoxY"} =
              $obstacleTextBoxes{$key2}{"iconCenterYPdf"};
            $obstacleTextBoxes{$key2}{"IconsThatPointToMe"} =
              $obstacleTextBoxes{$key2}{"IconsThatPointToMe"} + 1;
            $obstacleIcons{$key}{"ObstacleTextBoxesThatPointToMe"} =
              $obstacleIcons{$key}{"ObstacleTextBoxesThatPointToMe"} + 1;
        }

    }

}
if ($debug) {
    say "obstacleIcons";
    print Dumper ( \%obstacleIcons );
    say "obstacleTextBoxes";
    print Dumper ( \%obstacleTextBoxes );
}

#Draw a line from obstacle icon to closest text boxes
my $obstacle_line = $page->gfx;
$obstacle_line->strokecolor('blue');
foreach my $key ( sort keys %obstacleIcons ) {
    $obstacle_line->move( $obstacleIcons{$key}{"X"},
        $obstacleIcons{$key}{"Y"} );
    $obstacle_line->line( $obstacleIcons{$key}{"TextBoxX"},
        $obstacleIcons{$key}{"TextBoxY"} );
    $obstacle_line->stroke;
}

#Save our new PDF since we're done with it
#$pdf->saveas($outputpdf);
#exit(1);
#--------------------------------------------
#--------------------------------------------------------------------------
#Get a list of potential obstacle heights from the PDF text array
#(alternately, iterate through each obstacle and find the closest text box

my @obstacle_heights;

foreach my $line (@pdftotext) {

    #Find 3+ digit numbers that don't end in 0
    if ( $line =~ m/^([1-9][\d]{1,}[1-9])$/ ) {
        next if $1 > 30000;
        push @obstacle_heights, $1;
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

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Find obstacles with a certain height in the DB
my $radius = ".2";    #~15 miles

my %unique_obstacles_from_db = ();

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

   #Don't show results of searches that have more than one result, ie not unique
    next if ( $rows != 1 );

    foreach my $row (@$all) {
        my ( $lat, $lon, $heightmsl, $heightagl ) = @$row;
        foreach my $pdf_obstacle_height (@obstacle_heights) {
            if ( $pdf_obstacle_height == $heightmsl ) {
                $unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
                $unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
            }
        }
    }

}

if ($debug) {
    my $fields = $sth->{NUM_OF_FIELDS};
    print "We have selected $fields obstacle field(s)\n";

    my $rows = $sth->rows();
    print "We have selected $rows obstacle row(s)\n";
    say
"Found $rows OBSTACLES with unique heights within $radius degrees of airport from database";
    say "Unique obstacles from database lookup";
    print Dumper ( \%unique_obstacles_from_db );

}

#Find a text box with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates of that box to unique_obstacles_from_db hash
foreach my $key ( keys %unique_obstacles_from_db ) {
    foreach my $key2 ( keys %obstacleTextBoxes ) {
        if ( $obstacleTextBoxes{$key2}{"Text"} == $key ) {
            $unique_obstacles_from_db{$key}{"Label"} =
              $obstacleTextBoxes{$key2}{"Text"};
            $unique_obstacles_from_db{$key}{"TextBoxX"} =
              $obstacleTextBoxes{$key2}{"iconCenterXPdf"};
            $unique_obstacles_from_db{$key}{"TextBoxY"} =
              $obstacleTextBoxes{$key2}{"iconCenterYPdf"};

        }

    }
}

#Only outline our unique potential obstacle_heights with orange
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
        $distance_to_closest_obstacle_icon_x =
          $unique_obstacles_from_db{$key}{"TextBoxX"} -
          $obstacleIcons{$key2}{"X"};
        $distance_to_closest_obstacle_icon_y =
          $unique_obstacles_from_db{$key}{"TextBoxY"} -
          $obstacleIcons{$key2}{"Y"};

        my $hyp = sqrt( $distance_to_closest_obstacle_icon_x**2 +
              $distance_to_closest_obstacle_icon_y**2 );
        if ( ( $hyp < $distance_to_closest_obstacle_icon ) && ( $hyp < 10 ) ) {
            $distance_to_closest_obstacle_icon = $hyp;
            $unique_obstacles_from_db{$key}{"ObsIconX"} =
              $obstacleIcons{$key2}{"X"};
            $unique_obstacles_from_db{$key}{"ObsIconY"} =
              $obstacleIcons{$key2}{"Y"};
        }

    }

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

#Remove entries that share an ObsIconX and ObsIconY with another entry
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
            say "Duplicate obstacle";
        }

    }
}
foreach my $entry (@a) {
    delete $unique_obstacles_from_db{$entry};
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
    say "Unique obstacles from database lookup";
    print Dumper ( \%unique_obstacles_from_db );
}

#------------------------------------------------------------------------------------------------------------------------------------------
#Find fixes near the airport
my %fixes_from_db = ();

#What type of fixes to look for
my $type = "%REP-PT";

#Query the database for fixes within our $radius
$sth = $dbh->prepare(
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

    print Dumper ( \%fixes_from_db );
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
          $fixtextboxes{$key2}{"iconCenterXPdf"} - $fixIcons{$key}{"X"};
        $distance_to_closest_fixtextbox_y =
          $fixtextboxes{$key2}{"iconCenterYPdf"} - $fixIcons{$key}{"Y"};

        my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
              $distance_to_closest_fixtextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
#say "Hypotenuse: $hyp" if $debug;
        if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
            $distance_to_closest_fixtextbox = $hyp;
            $fixIcons{$key}{"Name"} = $fixtextboxes{$key2}{"Text"};
            $fixIcons{$key}{"TextBoxX"} =
              $fixtextboxes{$key2}{"iconCenterXPdf"};
            $fixIcons{$key}{"TextBoxY"} =
              $fixtextboxes{$key2}{"iconCenterYPdf"};
            $fixIcons{$key}{"Lat"} =
              $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lat"};
            $fixIcons{$key}{"Lon"} =
              $fixes_from_db{ $fixIcons{$key}{"Name"} }{"Lon"};
        }

    }

}

#fixes_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {
    say "fixes_from_db";
    print Dumper ( \%fixes_from_db );
    say "fix icons";
    print Dumper ( \%fixIcons );
    say "fixtextboxes";
    print Dumper ( \%fixtextboxes );
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

    print Dumper ( \%gpswaypoints_from_db );
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
          $fixtextboxes{$key2}{"iconCenterXPdf"} -
          $gpsWaypointIcons{$key}{"iconCenterXPdf"};
        $distance_to_closest_fixtextbox_y =
          $fixtextboxes{$key2}{"iconCenterYPdf"} -
          $gpsWaypointIcons{$key}{"iconCenterYPdf"};

        my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
              $distance_to_closest_fixtextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
        say "Hypotenuse: $hyp" if $debug;
        if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
            $distance_to_closest_fixtextbox = $hyp;
            $gpsWaypointIcons{$key}{"Name"} = $fixtextboxes{$key2}{"Text"};
            $gpsWaypointIcons{$key}{"TextBoxX"} =
              $fixtextboxes{$key2}{"iconCenterXPdf"};
            $gpsWaypointIcons{$key}{"TextBoxY"} =
              $fixtextboxes{$key2}{"iconCenterYPdf"};
            $gpsWaypointIcons{$key}{"Lat"} =
              $gpswaypoints_from_db{ $gpsWaypointIcons{$key}{"Name"} }{"Lat"};
            $gpsWaypointIcons{$key}{"Lon"} =
              $gpswaypoints_from_db{ $gpsWaypointIcons{$key}{"Name"} }{"Lon"};
        }

    }

}

#gpswaypoints_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {
    say "gpswaypoints_from_db";
    print Dumper ( \%gpswaypoints_from_db );
    say "gps waypoint icons";
    print Dumper ( \%gpsWaypointIcons );
    say "fixtextboxes";
    print Dumper ( \%fixtextboxes );
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
}

#Remove duplicate gps waypoints, prefer the one closest to the Y center of the PDF
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
if ($saveMarkedPdf) { $pdf->saveas($outputpdf) }

#Close the database
$sth->finish();
$dbh->disconnect();

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Create the list of Ground Control Points
my %gcps;
say "Obstacle Ground Control Points" if $debug;

if ( !$rnavPlate ) {

    #Add obstacles to Ground Control Points hash
    foreach my $key ( sort keys %unique_obstacles_from_db ) {
        my $pngx = $unique_obstacles_from_db{$key}{"ObsIconX"} * $scalefactorx;
        my $pngy =
          $pngy -
          ( $unique_obstacles_from_db{$key}{"ObsIconY"} * $scalefactory );
        my $lon = $unique_obstacles_from_db{$key}{"Lon"};
        my $lat = $unique_obstacles_from_db{$key}{"Lat"};
        if ( $pngy && $pngx && $lon && $lat ) {
            say "$pngx $pngy $lon $lat" if $debug;
            $gcps{ "obstacle" . $key }{"pngx"} = $pngx;
            $gcps{ "obstacle" . $key }{"pngy"} = $pngy;
            $gcps{ "obstacle" . $key }{"lon"}  = $lon;
            $gcps{ "obstacle" . $key }{"lat"}  = $lat;
        }
    }
}

if ( !$rnavPlate ) {

    #Add fixes to Ground Control Points hash
    say "Fix Ground Control Points" if $debug;
    foreach my $key ( sort keys %fixIcons ) {
        my $pngx = $fixIcons{$key}{"X"} * $scalefactorx;
        my $pngy = $pngy - ( $fixIcons{$key}{"Y"} * $scalefactory );
        my $lon  = $fixIcons{$key}{"Lon"};
        my $lat  = $fixIcons{$key}{"Lat"};
        if ( $pngy && $pngx && $lon && $lat ) {
            say "$pngx $pngy $lon $lat" if $debug;
            $gcps{ "fix" . $key }{"pngx"} = $pngx;
            $gcps{ "fix" . $key }{"pngy"} = $pngy;
            $gcps{ "fix" . $key }{"lon"}  = $lon;
            $gcps{ "fix" . $key }{"lat"}  = $lat;
        }
    }
}

#Add GPS waypoints to Ground Control Points hash
say "GPS waypoint Ground Control Points" if $debug;
foreach my $key ( sort keys %gpsWaypointIcons ) {

    my $pngx = $gpsWaypointIcons{$key}{"iconCenterXPdf"} * $scalefactorx;
    my $pngy =
      $pngy - ( $gpsWaypointIcons{$key}{"iconCenterYPdf"} * $scalefactory );
    my $lon = $gpsWaypointIcons{$key}{"Lon"};
    my $lat = $gpsWaypointIcons{$key}{"Lat"};
    if ( $pngy && $pngx && $lon && $lat ) {

        say "$pngx $pngy $lon $lat" if $debug;
        $gcps{ "gps" . $key }{"pngx"} = $pngx;
        $gcps{ "gps" . $key }{"pngy"} = $pngy;
        $gcps{ "gps" . $key }{"lon"}  = $lon;
        $gcps{ "gps" . $key }{"lat"}  = $lat;
    }
}
if ($debug) {
    say "GCPs";
    print Dumper ( \%gcps );
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
}

#Make sure we have enough GCPs
say "Found " . scalar( keys(%gcps) ) . " GCPS";

die "Need more Ground Control Points" if ( scalar( keys(%gcps) ) < 2 );
say '$xdiff,$ydiff,$londiff,$latdiff,$xscale,$yscale,$ulX,$ulY,$lrX,$lrY'
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

        #$scaleCounter++;

        my $xdiff = abs( $gcps{$key}{"pngx"} - $gcps{$key2}{"pngx"} ) +
          .00000000000000001;
        my $ydiff = abs( $gcps{$key}{"pngy"} - $gcps{$key2}{"pngy"} ) +
          .00000000000000001;
        my $londiff = abs( $gcps{$key}{"lon"} - $gcps{$key2}{"lon"} );
        my $latdiff = abs( $gcps{$key}{"lat"} - $gcps{$key2}{"lat"} );
        my $xscale  = $londiff / $xdiff;
        my $yscale  = $latdiff / $ydiff;
        my $ulX     = $gcps{$key}{"lon"} - ( $gcps{$key}{"pngx"} * $xscale );
        my $ulY     = $gcps{$key}{"lat"} + ( $gcps{$key}{"pngy"} * $yscale );
        my $lrX =
          $gcps{$key}{"lon"} + ( abs( $pngx - $gcps{$key}{"pngx"} ) * $xscale );
        my $lrY =
          $gcps{$key}{"lat"} - ( abs( $pngy - $gcps{$key}{"pngy"} ) * $yscale );

        say
"$key,$key2,$xdiff,$ydiff,$londiff,$latdiff,$xscale,$yscale,$ulX,$ulY,$lrX,$lrY"
          if $debug;

        push @xScaleAvg, $xscale;
        push @yScaleAvg, $yscale;
        push @ulXAvg,    $ulX;
        push @ulYAvg,    $ulY;
        push @lrXAvg,    $lrX;
        push @lrYAvg,    $lrY;
    }
}

#X-scale average and standard deviation
my $xAvg    = &average( \@xScaleAvg );
my $xStdDev = &stdev( \@xScaleAvg ) / 2;
say "X-scale average:  $xAvg\tX-scale stdev: $xStdDev" if $debug;

#Delete values from the array that are outside 1st dev
for ( my $i = 0 ; $i <= $#xScaleAvg ; $i++ ) {
    splice( @xScaleAvg, $i, 1 )
      if ( $xScaleAvg[$i] < ( $xAvg - $xStdDev )
        || $xScaleAvg[$i] > ( $xAvg + $xStdDev ) );
}
$xAvg = &average( \@xScaleAvg );
say "X-scale average after deleting outside 1st dev: $xAvg" if $debug;

#--------------------
#Y-scale average and standard deviation
my $yAvg    = &average( \@yScaleAvg );
my $yStdDev = &stdev( \@yScaleAvg ) / 2;
say "Y-scale average:  $yAvg\tY-scale stdev: $yStdDev" if $debug;

#Delete values from the array that are outside 1st dev
for ( my $i = 0 ; $i <= $#yScaleAvg ; $i++ ) {
    splice( @yScaleAvg, $i, 1 )
      if ( $yScaleAvg[$i] < ( $yAvg - $yStdDev )
        || $yScaleAvg[$i] > ( $yAvg + $yStdDev ) );
}
$yAvg = &average( \@yScaleAvg );
say "Y-scale average after deleting outside 1st dev: $yAvg" if $debug;

#------------------------
#--------------------
#ulX average and standard deviation
my $ulXAvrg   = &average( \@ulXAvg );
my $ulXStdDev = &stdev( \@ulXAvg ) / 2;
say "Upper Left X average:  $ulXAvrg\tUpper Left X stdev: $ulXStdDev" if $debug;

#Delete values from the array that are outside 1st dev
for ( my $i = 0 ; $i <= $#ulXAvg ; $i++ ) {
    splice( @ulXAvg, $i, 1 )
      if ( $ulXAvg[$i] < ( $ulXAvrg - $ulXStdDev )
        || $ulXAvg[$i] > ( $ulXAvrg + $ulXStdDev ) );
}
$ulXAvrg = &average( \@ulXAvg );
say "Upper Left X  average after deleting outside 1st dev: $ulXAvrg" if $debug;

#------------------------
#uly average and standard deviation
my $ulYAvrg   = &average( \@ulYAvg );
my $ulYStdDev = &stdev( \@ulYAvg ) / 2;
say "Upper Left Y average:  $ulYAvrg\tUpper Left Y stdev: $ulYStdDev" if $debug;

#Delete values from the array that are outside 1st dev
for ( my $i = 0 ; $i <= $#ulYAvg ; $i++ ) {
    splice( @ulYAvg, $i, 1 )
      if ( $ulYAvg[$i] < ( $ulYAvrg - $ulYStdDev )
        || $ulYAvg[$i] > ( $ulYAvrg + $ulYStdDev ) );
}
$ulYAvrg = &average( \@ulYAvg );
say "Upper Left Y average after deleting outside 1st dev: $ulYAvrg" if $debug;

#------------------------
#------------------------
#lrX average and standard deviation
my $lrXAvrg   = &average( \@lrXAvg );
my $lrXStdDev = &stdev( \@lrXAvg ) / 2;
say "Lower Right X average:  $lrXAvrg\tLower Right X stdev: $lrXStdDev"
  if $debug;

#Delete values from the array that are outside 1st dev
for ( my $i = 0 ; $i <= $#lrXAvg ; $i++ ) {
    splice( @lrXAvg, $i, 1 )
      if ( $lrXAvg[$i] < ( $lrXAvrg - $lrXStdDev )
        || $lrXAvg[$i] > ( $lrXAvrg + $lrXStdDev ) );
}
$lrXAvrg = &average( \@lrXAvg );
say "Lower Right X average after deleting outside 1st dev: $lrXAvrg" if $debug;

#------------------------
#------------------------
#lrY average and standard deviation
my $lrYAvrg   = &average( \@lrYAvg );
my $lrYStdDev = &stdev( \@lrYAvg ) / 2;
say "Lower Right Y average:  $lrYAvrg\tLower Right Y stdev: $lrYStdDev"
  if $debug;

#Delete values from the array that are outside 1st dev
for ( my $i = 0 ; $i <= $#lrYAvg ; $i++ ) {
    splice( @lrYAvg, $i, 1 )
      if ( $lrYAvg[$i] < ( $lrYAvrg - $lrYStdDev )
        || $lrYAvg[$i] > ( $lrYAvrg + $lrYStdDev ) );
}
$lrYAvrg = &average( \@lrYAvg );
say "Lower Right Y average after deleting outside 1st dev: $lrYAvrg" if $debug;

#------------------------

#----------------------------------------------------------------------------------------------------------------------------------------------------
#Try to georeference based on the list of Ground Control Points
my $gdal_translateoutput;

my $upperLeftLon  = $ulXAvrg;
my $upperLeftLat  = $ulYAvrg;
my $lowerRightLon = $lrXAvrg;
my $lowerRightLat = $lrYAvrg;
$gdal_translateoutput =
qx(gdal_translate -of GTiff -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" -a_ullr $upperLeftLon $upperLeftLat $lowerRightLon $lowerRightLat $targetpng  $targettif  );

# $gdal_translateoutput =
# qx(gdal_translate  -strict -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpng $targetvrt);
$retval = $? >> 8;
die "No output from gdal_translate  Is it installed? Return code was $retval"
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
# $output = qx(gdal_translate -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpdf $targetpdf.vrt);
# say $output;
# $output = qx(gdalwarp -t_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" -dstalpha $targetpdf.vrt $targettif);
# say $output;

#;
#;

