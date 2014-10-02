#!/usr/bin/perl

# Verify the georeferencing of plates
# Copyright (C) 2014  Jesse McGraw (jlmcgraw@gmail.com)
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

#Check the squareness of the "graticule"
#Make auto-routine run only on added,changed IAPs, APDs
#Use status area of GUI
#Show chosen GCP coordinate
#Have auto-apd code save/restore GCP hash
#Start using processFaa2 database

use 5.010;

use strict;
use warnings;

#use diagnostics;

# use PDF::API2;
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
use Gtk3 '-init';
use Glib 'TRUE', 'FALSE';
use List::Util qw[min max];
use Storable;

use GD;
use GD::Polyline;

# use Time::HiRes q/gettimeofday/;

# use Image::Magick;
# use File::Slurp;

#Some subroutines
use GeoReferencePlatesSubroutines;
use AffineTransform;
use Parse::FixedLength;

#Some other constants
# use constant COLUMN_FIXED => 0;
# use constant COLUMN_NUMBER => 1;
# use constant COLUMN_SEVERITY => 2;
# use constant COLUMN_DESCRIPTION => 3;
use constant COLUMN_NAME      => 0;
use constant COLUMN_TYPE      => 1;
use constant COLUMN_LONGITUDE => 2;
use constant COLUMN_LATITUDE  => 3;
use constant COLUMN_DISTANCE  => 4;

#----------------------------------------------------------------------------------------------
#Max allowed radius in PDF points from an icon (obstacle, fix, gps) to its associated textbox's center
our $maxDistanceFromObstacleIconToTextBox = 20;

#DPI of the output PNG
our $pngDpi = 300;

#A hash to collect statistics
our %statistics = ();

use vars qw/ %opt /;

#Define the valid command line options
my $opt_string = 'va:i:';
my $arg_num    = scalar @ARGV;

#Whether to draw various features
our $shouldDrawRunways          = 1;
our $shouldDrawNavaids          = 1;
our $shouldDrawNavaidsNames     = 0;
our $shouldDrawFixes            = 0;
our $shouldDrawFixesNames       = 0;
our $shouldDrawObstacles        = 0;
our $shouldDrawObstaclesHeights = 0;
our $shouldDrawGcps             = 1;
our $shouldDrawGraticules       = 1;

#We need at least one argument (the directory with plates)
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
our $cycle = $ARGV[0];
our ($dtppDirectory) = "./dtpp-$cycle/";

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

# our $shouldNotOverwriteVrt      = $opt{c};
# our $shouldOutputStatistics     = $opt{s};
# our $shouldSaveMarkedPdf        = $opt{p};
our $debug = $opt{v};

# our $shouldRecreateOutlineFiles = $opt{o};
# our $shouldSaveBadRatio         = $opt{b};
# our $shouldUseMultipleObstacles = $opt{m};

#database of metadata for dtpp
my $dtppDbh = DBI->connect( "dbi:SQLite:dbname=./dtpp-$cycle.db",
    "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

#CIFP database
my $cifpDbh =
     DBI->connect( "dbi:SQLite:dbname=./cifp.db", "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

#-----------------------------------------------
#Open the locations database
our $dbh;
my $sth;

$dbh = DBI->connect( "dbi:SQLite:dbname=./locationinfo.db",
    "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

$dtppDbh->do("PRAGMA page_size=4096");
$dtppDbh->do("PRAGMA synchronous=OFF");

#a reference to an array of all IAP and APD charts
my $_allPlates = allIapAndApdCharts();

#a reference to an array of charts with no longitude or latitude info
my $_platesNotMarkedManually    = findPlatesNotMarkedManually();
my $indexIntoPlatesWithNoLonLat = 0;

#a reference to an array of charts marked bad
my $_platesMarkedBad         = findPlatesMarkedBad();
my $indexIntoPlatesMarkedBad = 0;

#a reference to an array of charts marked Changed
my $_platesMarkedChanged         = chartsMarkedChanged();
my $indexIntoPlatesMarkedChanged = 0;

our (
    $currentGcpName, $currentGcpLon,  $currentGcpLat, $currentGcpPdfX,
    $currentGcpPdfY, $currentGcpPngX, $currentGcpPngY
);

#Lat/Lon of current airport
our ( $airportLatitudeDec, $airportLongitudeDec );

#Create the UI
my $builder = Gtk3::Builder->new();
$builder->add_from_file('./verifyPlatesUI.glade');

our $pixbuf;

#Connect our handlers
$builder->connect_signals(undef);

my $window = $builder->get_object('applicationwindow1');
$window->set_screen( $window->get_screen() );
$window->signal_connect( destroy => sub { Gtk3->main_quit } );

#Various UI elements we populate programmmatically
our $plate           = $builder->get_object('image2');
our $plateSw         = $builder->get_object('viewport1');
our $runwayBox       = $builder->get_object('scrolledwindow2');
our $navaidBox       = $builder->get_object('scrolledwindow4');
our $fixesBox        = $builder->get_object('scrolledwindow5');
our $obstaclesBox    = $builder->get_object('scrolledwindow6');
our $gcpBox          = $builder->get_object('scrolledwindow3');
our $lonLatTextEntry = $builder->get_object('lonLatTextEntry');
our $statusBar       = $builder->get_object('statusbar1');
our $context_id      = $statusBar->get_context_id("Statusbar");
our $textview1       = $builder->get_object('textview1');
our $comboboxtext1   = $builder->get_object('comboboxtext1');

# my $textviewBuffer = $textview1->get_buffer;
# my $iter = $textviewBuffer->get_iter_at_offset (0);
# $textviewBuffer->insert ($iter, "The text widget can display text with all kinds of nifty attributes. It also supports multiple views of the same buffer; this demo is showing the same buffer in two places.\n\n");
$window->show_all();

#Set the initial plate
activateNewPlate( @$_allPlates[0] );

#Start the main GUI loop
Gtk3->main();

# #Close the charts database
# $dtppSth->finish();
$dtppDbh->disconnect();

#Close the locations database
# $sth->finish();
$dbh->disconnect();

exit;

sub findAirportLatitudeAndLongitude {

    #Returns the lat/lon of the airport for the plate we're working on

    #Validate and set input parameters to this function
    my ($FAA_CODE) = validate_pos( @_, { type => SCALAR }, );

    my $_airportLatitudeDec;
    my $_airportLongitudeDec;

    #Query the database for airport
    my $sth = $dbh->prepare(
        "SELECT  
	    FaaID, Latitude, Longitude, Name  
         FROM 
	    airports  
         WHERE
	    FaaID = '$FAA_CODE'"
    );
    $sth->execute();

    my $_allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$_allSqlQueryResults) {
        my ( $airportFaaId, $airportname );
        (
            $airportFaaId, $_airportLatitudeDec, $_airportLongitudeDec,
            $airportname
        ) = @$_row;

        #             if ($debug) {
        #                 say "Airport ID: $airportFaaId";
        #                 say "Airport Latitude: $_airportLatitudeDec";
        #                 say "Airport Longitude: $_airportLongitudeDec";
        #                 say "Airport Name: $airportname";
        #             }
    }

    if ( $_airportLatitudeDec && $_airportLongitudeDec ) {
        say
          "FAA_CODE: $FAA_CODE -> Lon:$_airportLongitudeDec Lat:$_airportLatitudeDec";
        my $textviewBuffer = $main::textview1->get_buffer;
        my $iter           = $textviewBuffer->get_iter_at_offset(0);
        $textviewBuffer->insert( $iter,
            "FAA_CODE: $FAA_CODE -> Lon:$_airportLongitudeDec Lat:$_airportLatitudeDec\n\n"
        );

        return ( $_airportLatitudeDec, $_airportLongitudeDec );
    }

    else {
        return ( 0, 0 );
    }
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

sub findObstaclesNearAirport {

    #Validate and set input parameters to this function
    my ( $airportLongitude, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    # my $radius     = ".2";
    my $minimumAgl = "0";

    #How far away from the airport to look for feature
    my $radiusNm = 20;

    #Calculate radius for the airport's latitude
    my ( $radiusDegreesLatitude, $radiusDegreesLongitude ) =
      radiusGivenLatitude( $radiusNm, $airportLatitude );

    #Query the database for obstacles of $heightmsl within our $radius
    my $dtppSth = $dbh->prepare(
        "SELECT *
            FROM obstacles
            WHERE
            (HeightAgl > $minimumAgl)
            and
            (Latitude >  $airportLatitude - $radiusDegreesLatitude )
            and
            (Latitude < $airportLatitude + $radiusDegreesLatitude )
            and
            (Longitude >  $airportLongitude - $radiusDegreesLongitude )
            and
            (Longitude < $airportLongitude + $radiusDegreesLongitude )"
    );
    $dtppSth->execute();

    my %unique_obstacles_from_db;

    my $all = $dtppSth->fetchall_arrayref();

    foreach my $_row (@$all) {
        my ( $lat, $lon, $heightmsl, $heightagl ) = @$_row;
        if ( exists $unique_obstacles_from_db{$heightmsl} ) {

            #This is a duplicate obstacle
            $lat = $lon = 0;
        }

        #Populate variables from our database lookup

        $unique_obstacles_from_db{$heightmsl}{"Name"} = $heightmsl;
        $unique_obstacles_from_db{$heightmsl}{"Lat"}  = $lat;
        $unique_obstacles_from_db{$heightmsl}{"Lon"}  = $lon;

    }

    return ( \%unique_obstacles_from_db );
}

sub convertPdfToPng {

    #Validate and set input parameters to this function
    my ( $targetPdf, $targetpng ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    #---------------------------------------------------
    #Convert the PDF to a PNG
    my $pdfToPpmOutput;
    if ( -e $targetpng ) {
        return;
    }
    $pdfToPpmOutput = qx(pdftoppm -png -r $pngDpi $targetPdf > $targetpng);

    my $retval = $? >> 8;
    die "Error from pdftoppm.   Return code is $retval" if $retval != 0;
    return;
}

sub findFixesNearAirport {

    #Validate and set input parameters to this function
    my ( $airportLongitude, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    # my $radius = .5;
    my $radiusNm = 50;

    #Calculate radius for the airport's latitude
    my ( $radiusDegreesLatitude, $radiusDegreesLongitude ) =
      radiusGivenLatitude( $radiusNm, $airportLatitude );

    #What type of fixes to look for
    #     my $type = "%REP-PT";
    my $type = "%";

    #Query the database for fixes within our $radius
    my $sth = $dbh->prepare(
        "SELECT * 
        FROM fixes 
        WHERE  
        (Latitude >  $airportLatitude - $radiusDegreesLatitude ) 
        and 
        (Latitude < $airportLatitude + $radiusDegreesLatitude )
        and 
        (Longitude >  $airportLongitude - $radiusDegreesLongitude ) 
        and 
        (Longitude < $airportLongitude + $radiusDegreesLongitude ) 
        and
        (Type like '$type')"
    );
    $sth->execute();

    my $allSqlQueryResults = $sth->fetchall_arrayref();

    my %fixes_from_db;

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$_row;

        my @A = NESW( $lon, $lat );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $fixes_from_db{$fixname}{"Name"}     = $fixname;
        $fixes_from_db{$fixname}{"Lat"}      = $lat;
        $fixes_from_db{$fixname}{"Lon"}      = $lon;
        $fixes_from_db{$fixname}{"Type"}     = $fixtype;
        $fixes_from_db{$fixname}{"Distance"} = $nm;
    }

    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    #     if ($debug) {
    #         my $_rows  = $sth->rows();
    #         my $fields = $sth->{NUM_OF_FIELDS};
    #         say
    #           "Found $_rows FIXES within $radiusNm nm of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) from database";
    #
    #         say "All $type fixes from database";
    #         say "We have selected $fields field(s)";
    #         say "We have selected $_rows row(s)";
    #
    #         #print Dumper ( \%fixes_from_db );
    #         say "";
    #     }

    return ( \%fixes_from_db );
}

sub findFixesNearAirport2 {

    #Returns only fixes mentioned in CIFP database for this airport

    #Validate and set input parameters to this function
    my ( $airportLongitude, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    my %fixes_from_db;

    #Query the database for fixes in IAP
    my $sth = $cifpDbh->prepare(
        "select distinct
	  iap.FixIdentifier	
	  ,fix.waypointLatitude
	  ,fix.waypointLongitude
      from 
        \"primary_P_F_base_Airport - Approach Procedures\" as IAP

      JOIN
	\"primary_E_A_base_Enroute - Grid Waypoints\" as FIX

      ON 
	iap.FixIdentifier = fix.waypointIdentifier

      WHERE 
        airportidentifier like '%$main::FAA_CODE%' ;"
    );
    $sth->execute();

    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon ) = @$_row;

        my @A = NESW(
            coordinateToDecimalCifpFormat($lon),
            coordinateToDecimalCifpFormat($lat)
        );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $fixes_from_db{$fixname}{"Name"} = $fixname;
        $fixes_from_db{$fixname}{"Lat"}  = coordinateToDecimalCifpFormat($lat);
        $fixes_from_db{$fixname}{"Lon"}  = coordinateToDecimalCifpFormat($lon);
        $fixes_from_db{$fixname}{"Type"} = '$fixtype';
        $fixes_from_db{$fixname}{"Distance"} = $nm;
    }

    #Query the database for terminal fixes for IAP
    $sth = $cifpDbh->prepare(
        "select distinct
	  iap.FixIdentifier	
	  ,fix.waypointLatitude
	  ,fix.waypointLongitude
      from 
        \"primary_P_F_base_Airport - Approach Procedures\" as IAP

      JOIN
	\"primary_P_C_base_Airport - Terminal Waypoints\" as FIX

      ON 
	iap.FixIdentifier = fix.waypointIdentifier

      WHERE 
        airportidentifier like '%$main::FAA_CODE%' ;"
    );
    $sth->execute();

    $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon ) = @$_row;

        my @A = NESW(
            coordinateToDecimalCifpFormat($lon),
            coordinateToDecimalCifpFormat($lat)
        );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $fixes_from_db{$fixname}{"Name"} = $fixname;
        $fixes_from_db{$fixname}{"Lat"}  = coordinateToDecimalCifpFormat($lat);
        $fixes_from_db{$fixname}{"Lon"}  = coordinateToDecimalCifpFormat($lon);
        $fixes_from_db{$fixname}{"Type"} = '$fixtype';
        $fixes_from_db{$fixname}{"Distance"} = $nm;
    }
    return ( \%fixes_from_db );
}

sub radiusGivenLatitude {

    #Validate and set input parameters to this function
    my ( $radiusNm, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    #Convert to degrees of Longitude and Latitude for the latitude of our airport
    my $radiusDegreesLatitude = $radiusNm / 60;
    my $radiusDegreesLongitude =
      abs( ( $radiusNm / 60 ) / cos( deg2rad($airportLatitude) ) );
    return ( $radiusDegreesLatitude, $radiusDegreesLongitude );

}

sub findGpsWaypointsNearAirport {

    #Validate and set input parameters to this function
    my ( $airportLongitude, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    #How far away from the airport to look for feature
    my $radiusNm = 40;

    #Calculate radius for the airport's latitude
    my ( $radiusDegreesLatitude, $radiusDegreesLongitude ) =
      radiusGivenLatitude( $radiusNm, $airportLatitude );

    #What type of fixes to look for
    my $type = "%";

    my $sth = $dbh->prepare(
        "SELECT * 
        FROM fixes 
        WHERE  
        (Latitude >  $airportLatitude - $radiusDegreesLatitude ) 
        and 
        (Latitude < $airportLatitude + $radiusDegreesLatitude )
        and 
        (Longitude >  $airportLongitude - $radiusDegreesLongitude ) 
        and 
        (Longitude < $airportLongitude + $radiusDegreesLongitude ) 
        and
        (Type like '$type')"
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    my %gpswaypoints_from_db;

    foreach my $_row (@$allSqlQueryResults) {
        my ( $fixname, $lat, $lon, $fixtype ) = @$_row;

        my @A = NESW( $lon, $lat );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $gpswaypoints_from_db{$fixname}{"Name"}     = $fixname;
        $gpswaypoints_from_db{$fixname}{"Lat"}      = $lat;
        $gpswaypoints_from_db{$fixname}{"Lon"}      = $lon;
        $gpswaypoints_from_db{$fixname}{"Type"}     = $fixtype;
        $gpswaypoints_from_db{$fixname}{"Distance"} = $nm;

    }

    #     if ($debug) {
    #         my $_rows  = $sth->rows();
    #         my $fields = $sth->{NUM_OF_FIELDS};
    #         say
    #           "Found $_rows GPS waypoints within $radiusNm NM of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) from database";
    #         say "All $type fixes from database";
    #         say "We have selected $fields field(s)";
    #         say "We have selected $_rows row(s)";
    #
    #         #print Dumper ( \%gpswaypoints_from_db );
    #         say "";
    #     }
    return ( \%gpswaypoints_from_db );
}

sub NESW {

    #Validate and set input parameters to this function
    my ( $airportLongitude, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    # Notice the 90 - latitude: phi zero is at the North Pole.
    return deg2rad($airportLongitude), deg2rad( 90 - $airportLatitude );
}

sub findNavaidsNearAirport {

    #Validate and set input parameters to this function
    my ( $airportLongitude, $airportLatitude ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    # my $radius      = .7;
    # my $nmLatitude  = 60 * $radius;
    # my $nmLongitude = $nmLatitude * cos( deg2rad($airportLatitudeDec) );

    #How far away from the airport to look for feature
    my $radiusNm = 30;

    #Calculate radius for the airport's latitude
    my ( $radiusDegreesLatitude, $radiusDegreesLongitude ) =
      radiusGivenLatitude( $radiusNm, $airportLatitude );

    #What type of fixes to look for
    my $type = "%VOR%";

    #Query the database for fixes within our $radius
    my $sth = $main::dbh->prepare(
        "SELECT * 
        FROM navaids 
        WHERE  
        (Latitude >  $airportLatitude - $radiusDegreesLatitude ) 
        and 
        (Latitude < $airportLatitude + $radiusDegreesLatitude )
        and 
        (Longitude >  $airportLongitude - $radiusDegreesLongitude ) 
        and 
        (Longitude < $airportLongitude + $radiusDegreesLongitude ) 
        --and
        --(Type like '$type' OR  Type like '%NDB%')
        "
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    my %navaids_from_db;

    foreach my $_row (@$allSqlQueryResults) {
        my ( $navaidName, $lat, $lon, $navaidType ) = @$_row;

        #Ignore VOTs
        next if ( $navaidType =~ /^VOT$/i );

        my @A = NESW( $lon, $lat );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $navaids_from_db{ $navaidName . $navaidType }{"Name"}     = $navaidName;
        $navaids_from_db{ $navaidName . $navaidType }{"Lat"}      = $lat;
        $navaids_from_db{ $navaidName . $navaidType }{"Lon"}      = $lon;
        $navaids_from_db{ $navaidName . $navaidType }{"Type"}     = $navaidType;
        $navaids_from_db{ $navaidName . $navaidType }{"Distance"} = $nm;

    }
    return ( \%navaids_from_db );
}

sub findRunwaysInDatabase {
    #
    #Validate and set input parameters to this function
    my ($FAA_CODE) =
      validate_pos( @_, { type => SCALAR } );

    my $sth = $main::dbh->prepare(
        "SELECT * 
        FROM runways 
        WHERE 
         FaaID = '$FAA_CODE'
        "
    );
    $sth->execute();

    my $all = $sth->fetchall_arrayref();

    #     #How many rows did this search return
    #     my $_rows = $sth->rows();
    #     say "Found $_rows runways for $main::airportId" if $debug;

    my %runwaysFromDatabase;

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

        #$runwaysFromDatabase{$LEName}{} = $trueHeading;
        $runwaysFromDatabase{ $LEName . $HEName }{'LELatitude'}  = $LELatitude;
        $runwaysFromDatabase{ $LEName . $HEName }{'LELongitude'} = $LELongitude;
        $runwaysFromDatabase{ $LEName . $HEName }{'LEHeading'}   = $LEHeading;
        $runwaysFromDatabase{ $LEName . $HEName }{'HELatitude'}  = $HELatitude;
        $runwaysFromDatabase{ $LEName . $HEName }{'HELongitude'} = $HELongitude;
        $runwaysFromDatabase{ $LEName . $HEName }{'HEHeading'}   = $HEHeading;

    }
    return ( \%runwaysFromDatabase );
}

sub usage {
    say "Usage: $0 <options> <cycle>";
    say " <cycle> The cycle number, eg. 1410";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-i<2 Letter state ID>  To specify a specific state";
    return;
}

sub findPlatesNotMarkedManually {

    #Charts with no lon/lat
    my $dtppSth = $dtppDbh->prepare( "
      SELECT 
	D.TPP_VOLUME
	,D.FAA_CODE    
	,D.CHART_SEQ 
	,D.CHART_CODE
        ,D.CHART_NAME   
        ,D.USER_ACTION
        ,D.PDF_NAME
        ,D.FAANFD18_CODE
        ,D.MILITARY_USE
        ,D.COPTER_USE
        ,D.STATE_ID
	,ABS( CAST (DG.targetLonLatRatio AS FLOAT) - CAST(DG.lonLatRatio AS FLOAT)) AS Difference
	,DG.upperLeftLon
	,DG.upperLeftLat
	,DG.lowerRightLon
	,DG.lowerRightLat
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
        FAA_CODE LIKE  '$main::airportId' 
           AND
        STATE_ID LIKE  '$main::stateId'                   
          AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
          AND
        DG.STATUS LIKE '%MONKEY%'
        --        AND
        --DG.STATUS NOT LIKE '%MANUAL%'
          AND
        DG.STATUS NOT LIKE '%NOGEOREF%'
--          AND
--        (CAST (DG.xPixelSkew as FLOAT) != '0'
--          OR
--          CAST (DG.yPixelSkew as FLOAT) != '0')
--          and D.MILITARY_USE = 'M'
--        CAST (DG.upperLeftLon AS FLOAT) = '0'
--          AND
--        CAST (DG.xScaleAvgSize as FLOAT) > 1
--          AND
--        Difference  > .08
      ORDER BY
        D.FAA_CODE ASC
;"
    );
    $dtppSth->execute();

    #An array of all APD and IAP charts with no lon/lat
    return ( $dtppSth->fetchall_arrayref() );
}

sub allIapAndApdCharts {

    #Query the dtpp database for IAP and APD charts
    my $dtppSth = $dtppDbh->prepare( "
      SELECT 
	D.TPP_VOLUME
	,D.FAA_CODE    
	,D.CHART_SEQ 
	,D.CHART_CODE
        ,D.CHART_NAME   
        ,D.USER_ACTION
        ,D.PDF_NAME
        ,D.FAANFD18_CODE
        ,D.MILITARY_USE
        ,D.COPTER_USE
        ,D.STATE_ID
	,ABS( CAST (DG.targetLonLatRatio AS FLOAT) - CAST(DG.lonLatRatio AS FLOAT)) AS Difference
	,DG.upperLeftLon
	,DG.upperLeftLat
	,DG.lowerRightLon
	,DG.lowerRightLat
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
        ( CHART_CODE = 'IAP' OR CHART_CODE = 'APD' )                 
           AND 
	FAA_CODE LIKE  '$main::airportId' 
           AND
        STATE_ID LIKE  '$main::stateId'                    
          AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
--          AND
--        DG.STATUS NOT LIKE '%MANUAL%'
--          AND
--        DG.STATUS NOT LIKE '%NOGEOREF%'
--        CAST (DG.upperLeftLon AS FLOAT) = '0'
--          AND
--        CAST (DG.xScaleAvgSize as FLOAT) > 1
--          AND
--        Difference  > .08
      ORDER BY
        D.FAA_CODE ASC
;"
    );

    $dtppSth->execute();

    #An array of all APD and IAP charts
    return ( $dtppSth->fetchall_arrayref() );
}

sub findPlatesMarkedBad {

    #Charts marked bad
    my $dtppSth = $dtppDbh->prepare( "
      SELECT
	D.TPP_VOLUME
	,D.FAA_CODE    
	,D.CHART_SEQ 
	,D.CHART_CODE
        ,D.CHART_NAME   
        ,D.USER_ACTION
        ,D.PDF_NAME
        ,D.FAANFD18_CODE
        ,D.MILITARY_USE
        ,D.COPTER_USE
        ,D.STATE_ID
	,ABS( CAST (DG.targetLonLatRatio AS FLOAT) - CAST(DG.lonLatRatio AS FLOAT)) AS Difference
	,DG.upperLeftLon
	,DG.upperLeftLat
	,DG.lowerRightLon
	,DG.lowerRightLat
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
        ( CHART_CODE = 'IAP' OR CHART_CODE = 'APD' )
           AND
	FAA_CODE LIKE  '$main::airportId' 
           AND
        STATE_ID LIKE  '$main::stateId'   
          AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
          AND
        DG.STATUS LIKE '%BAD%'
        -- AND
        -- DG.STATUS NOT LIKE '%NOGEOREF%'
        -- BUG TODO: Civilian charts only for now
	  AND
        D.MILITARY_USE != 'M'
--          AND
--        CAST (DG.yScaleAvgSize AS FLOAT) > 1
--          AND
--        CAST (DG.xScaleAvgSize as FLOAT) > 1
--          AND
--        Difference  > .08
      ORDER BY
        D.FAA_CODE ASC
;"
    );

    $dtppSth->execute();

    #Return the arraryRef
    return ( $dtppSth->fetchall_arrayref() );

}

sub chartsMarkedChanged {

    #Charts marked bad
    my $dtppSth = $dtppDbh->prepare( "
      SELECT
	D.TPP_VOLUME
	,D.FAA_CODE    
	,D.CHART_SEQ 
	,D.CHART_CODE
        ,D.CHART_NAME   
        ,D.USER_ACTION
        ,D.PDF_NAME
        ,D.FAANFD18_CODE
        ,D.MILITARY_USE
        ,D.COPTER_USE
        ,D.STATE_ID
	,ABS( CAST (DG.targetLonLatRatio AS FLOAT) - CAST(DG.lonLatRatio AS FLOAT)) AS Difference
	,DG.upperLeftLon
	,DG.upperLeftLat
	,DG.lowerRightLon
	,DG.lowerRightLat
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
        D.USER_ACTION = 'C'
        OR
        D.USER_ACTION = 'A'
        )
          AND
        ( 
         CHART_CODE = 'IAP' 
           OR 
         CHART_CODE = 'APD' 
        )  
          AND
        FAA_CODE LIKE  '$main::airportId' 
           AND
        STATE_ID LIKE  '$main::stateId'   
          AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
        -- AND
        -- DG.STATUS NOT LIKE '%NOGEOREF%'
        -- AND
        -- DG.STATUS NOT LIKE '%MANUALGOOD%'

      ORDER BY
        D.FAA_CODE ASC
;"
    );
    $dtppSth->execute();

    #Return the arraryRef
    return ( $dtppSth->fetchall_arrayref() );

}

sub wgs84ToPixelBuf {
    my ( $_longitude, $_latitude ) = validate_pos(
        @_,
        { type => SCALAR },
        { type => SCALAR }

    );
    my $scaledImageHeight  = $main::scaledPlate->get_height();
    my $scrollWindowHeight = $main::plateSw->get_allocation()->{height};

    my $scaledImageWidth  = $main::scaledPlate->get_width();
    my $scrollWindowWidth = $main::plateSw->get_allocation()->{width};

    #The scaling and rotation is set when the transform is created
    if ($main::invertedAffineTransform) {
        my ( $_xPixel, $_yPixel ) =
          $main::invertedAffineTransform->transform( $_longitude, $_latitude );

        #Clamp to height of our scaled image
        if ( $_yPixel < 0 ) {
            $_yPixel = 0;
        }
        elsif ( $_yPixel > $scaledImageHeight ) {
            $_yPixel = $scaledImageHeight;
        }

        $_yPixel =
          ( $_yPixel + ( $scrollWindowHeight - $scaledImageHeight ) / 2 );

        #Clamp to width
        if ( $_xPixel < 0 ) {
            $_xPixel = 0;
        }
        elsif ( $_xPixel > $scaledImageWidth ) {
            $_xPixel = $scaledImageWidth;
        }

        $_xPixel =
          ( $_xPixel + ( $scrollWindowWidth - $scaledImageWidth ) / 2 );

        return ( $_xPixel, $_yPixel );
    }
    else { return ( 0, 0 ) }
}

sub toggleDrawingFixes {
    $main::shouldDrawFixes = !$main::shouldDrawFixes;
    $main::plateSw->queue_draw;
}

sub toggleDrawingFixesNames {
    $main::shouldDrawFixesNames = !$main::shouldDrawFixesNames;
    $main::plateSw->queue_draw;
}

sub toggleDrawingNavaids {
    $main::shouldDrawNavaids = !$main::shouldDrawNavaids;
    $main::plateSw->queue_draw;
}

sub toggleDrawingNavaidsNames {
    $main::shouldDrawNavaidsNames = !$main::shouldDrawNavaidsNames;
    $main::plateSw->queue_draw;
}

sub toggleDrawingRunways {
    $main::shouldDrawRunways = !$main::shouldDrawRunways;
    $main::plateSw->queue_draw;
}

sub toggleDrawingGCPs {
    $main::shouldDrawGcps = !$main::shouldDrawGcps;
    $main::plateSw->queue_draw;
}

sub toggleDrawingObstacles {
    $main::shouldDrawObstacles = !$main::shouldDrawObstacles;
    $main::plateSw->queue_draw;
}

sub toggleDrawingObstaclesHeights {
    $main::shouldDrawObstaclesHeights = !$main::shouldDrawObstaclesHeights;
    $main::plateSw->queue_draw;
}

sub toggleDrawingGraticules {
    $main::shouldDrawGraticules = !$main::shouldDrawGraticules;
    $main::plateSw->queue_draw;
}

sub cairo_draw {
    my ( $widget, $context, $ref_status ) = @_;

    #Immediate exit if no inverse transform defined
    if ( !$main::invertedAffineTransform ) {
        return FALSE;
    }
    my $runwayHashRef  = $main::runwaysFromDatabaseHashref;
    my $navaidsHashRef = $main::navaids_from_db_hashref;

    #     my $fixHashRef       = $main::fixes_from_db_hashref;
    my $gcpHashRef = $main::gcp_from_db_hashref;

    #     my $obstaclesHashRef = $main::unique_obstacles_from_db_hashref;

    #Draw fixes
    if ($shouldDrawFixes) {
        foreach my $key ( keys $main::fixes_from_db_hashref ) {

            my $lat  = $main::fixes_from_db_hashref->{$key}{"Lat"};
            my $lon  = $main::fixes_from_db_hashref->{$key}{"Lon"};
            my $text = $main::fixes_from_db_hashref->{$key}{"Name"};

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($lat);
            #             my $x1 = longitudeToPixel($lon);
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
            if ( $x1 && $y1 ) {

                # Circle with border - transparent
                $context->set_source_rgba( 0, 0, 1, 0.5 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;
                $context->set_source_rgba( 0, 1, 1, 0.5 );
                $context->fill;

                if ($main::shouldDrawFixesNames) {

                    # Text
                    $context->set_source_rgba( 255, 0, 255, 255 );
                    $context->select_font_face( "Sans", "normal", "normal" );
                    $context->set_font_size(9);
                    $context->move_to( $x1 + 5, $y1 );
                    $context->show_text("$text");
                    $context->stroke;
                }

            }
        }
    }
    foreach my $key ( keys $main::fixes_from_db_iap_hashref ) {

        my $lat  = $main::fixes_from_db_iap_hashref->{$key}{"Lat"};
        my $lon  = $main::fixes_from_db_iap_hashref->{$key}{"Lon"};
        my $text = $main::fixes_from_db_iap_hashref->{$key}{"Name"};

        # 		    say "$latLE, $lonLE, $latHE, $lonHE";
        #             my $y1 = latitudeToPixel($lat);
        #             my $x1 = longitudeToPixel($lon);
        my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
        if ( $x1 && $y1 ) {

            # Circle with border - transparent
            $context->set_source_rgba( 0, 0, 1, 0.5 );
            $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
            $context->set_line_width(2);
            $context->stroke_preserve;
            $context->set_source_rgba( 0, 1, 1, 0.5 );
            $context->fill;
            if ($main::shouldDrawFixesNames) {

                # Text
                $context->set_source_rgba( 255, 0, 255, 255 );
                $context->select_font_face( "Sans", "normal", "normal" );
                $context->set_font_size(9);
                $context->move_to( $x1 + 5, $y1 );
                $context->show_text("$text");
                $context->stroke;
            }
        }
    }

    #Draw navaids
    if ($shouldDrawNavaids) {
        foreach my $key ( keys $navaidsHashRef ) {

            my $lat  = $navaidsHashRef->{$key}{"Lat"};
            my $lon  = $navaidsHashRef->{$key}{"Lon"};
            my $text = $navaidsHashRef->{$key}{"Name"};

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($lat);
            #             my $x1 = longitudeToPixel($lon);
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
            if ( $x1 && $y1 ) {

                # Circle with border - transparent
                $context->set_source_rgba( 0, 255, 0, .8 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;
                $context->set_source_rgba( 0, 255, 0, .8 );
                $context->fill;

                if ($main::shouldDrawNavaidsNames) {

                    # Text
                    $context->set_source_rgba( 255, 0, 255, 1 );
                    $context->select_font_face( "Sans", "normal", "normal" );
                    $context->set_font_size(10);
                    $context->move_to( $x1 + 5, $y1 );
                    $context->show_text("$text");
                    $context->stroke;
                }
            }
        }
    }

    # # 		# Line
    # 		$context->set_source_rgba(0, 255, 0, 0.5);
    # 		$context->set_line_width(30);
    # 		$context->move_to(50, 50);
    #  		$context->line_to(550, 350);
    #  		$context->stroke;

    #Draw GCPs
    if ( $shouldDrawGcps && $gcpHashRef ) {
        foreach my $key ( sort keys $gcpHashRef ) {

            my $lat  = $gcpHashRef->{$key}{"lat"};
            my $lon  = $gcpHashRef->{$key}{"lon"};
            my $text = $gcpHashRef->{$key}{$key};

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($lat);
            #             my $x1 = longitudeToPixel($lon);
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
            if ( $x1 && $y1 ) {

                # Circle with border - transparent
                $context->set_source_rgba( 0, 255, 0, 64 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;
                $context->set_source_rgba( 0, 255, 0, 64 );
                $context->fill;

                #                 # Text
                #                 $context->set_source_rgba( 255, 0, 255, 128 );
                #                 $context->select_font_face( "Sans", "normal", "normal" );
                #                 $context->set_font_size(10);
                #                 $context->move_to( $x1+5, $y1 );
                #                 $context->show_text("$text");
                #                 $context->stroke;
            }
        }
    }

    #Draw Obstacles?
    if ($shouldDrawObstacles) {
        foreach my $key ( keys $main::unique_obstacles_from_db_hashref ) {

            # print Dumper $obstaclesHashRef;
            my $lat  = $main::unique_obstacles_from_db_hashref->{$key}{"Lat"};
            my $lon  = $main::unique_obstacles_from_db_hashref->{$key}{"Lon"};
            my $text = $main::unique_obstacles_from_db_hashref->{$key}{"Name"};

            #non-unique obstacles have lon/lat both equal to 0
            next if ( $lon == 0 && $lat == 0 );

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($lat);
            #             my $x1 = longitudeToPixel($lon);
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
            if ( $x1 && $y1 ) {

                # Circle with border - transparent
                $context->set_source_rgba( 0, 1, 1, 0.2 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;
                $context->set_source_rgba( 0, 1, 1, 0.2 );
                $context->fill;
                if ($main::shouldDrawObstaclesHeights) {

                    # Text
                    $context->set_source_rgba( 255, 0, 255, 128 );
                    $context->select_font_face( "Sans", "normal", "normal" );
                    $context->set_font_size(10);
                    $context->move_to( $x1 + 5, $y1 );
                    $context->show_text("$text");
                    $context->stroke;
                }
            }
        }
    }
    if ($shouldDrawRunways) {

        #Draw the runways
        foreach my $key ( sort keys $runwayHashRef ) {

            my $latLE = $runwayHashRef->{$key}{"LELatitude"};
            my $lonLE = $runwayHashRef->{$key}{"LELongitude"};
            my $latHE = $runwayHashRef->{$key}{"HELatitude"};
            my $lonHE = $runwayHashRef->{$key}{"HELongitude"};

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($latLE);
            #             my $x1 = longitudeToPixel($lonLE);
            #
            #             my $y2 = latitudeToPixel($latHE);
            #             my $x2 = longitudeToPixel($lonHE);

            #             my ($x1, $y1, $x2, $y2) = $main::invertedAffineTransform->transform($lonLE, $latLE, $lonHE, $latHE);
            #             say "Wheee!";
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lonLE, $latLE );
            my ( $x2, $y2 ) = wgs84ToPixelBuf( $lonHE, $latHE );

            #             say "$lonLE -> $x1";
            #             say "$latLE -> $y1";
            #             say "$lonHE -> $x2";
            #             say "$latHE -> $y2";

            # 		  say "$x1, $y1, $x2, $y2";

            # Line
            if ( $x1 && $y1 && $x2 && $y2 ) {
                $context->set_source_rgba( 1, 0, 0, .9 );
                $context->set_line_width(2);
                $context->move_to( $x1, $y1 );
                $context->line_to( $x2, $y2 );
                $context->stroke;
            }

        }
    }

    if ($shouldDrawGraticules) {

        #Draw some squares, if they aren't square then something's wrong with transform
        #     my $radius = .5;

        foreach my $radius ( .125, .25, .375, .5 ) {
            my ( $latRadius, $lonRadius ) =
              radiusGivenLatitude( $radius, $main::airportLatitudeDec );

            my ( $x1, $y1 ) = wgs84ToPixelBuf(
                $main::airportLongitudeDec - $lonRadius,
                $main::airportLatitudeDec - $latRadius
            );
            my ( $x2, $y2 ) = wgs84ToPixelBuf(
                $main::airportLongitudeDec - $lonRadius,
                $main::airportLatitudeDec + $latRadius
            );
            my ( $x3, $y3 ) = wgs84ToPixelBuf(
                $main::airportLongitudeDec + $lonRadius,
                $main::airportLatitudeDec + $latRadius
            );
            my ( $x4, $y4 ) = wgs84ToPixelBuf(
                $main::airportLongitudeDec + $lonRadius,
                $main::airportLatitudeDec - $latRadius
            );

            # 	    say "$lonRadius $latRadius $x1 $y1 $x2 $y2";

            $context->set_source_rgba( 0, 0, 1, .5 );
            $context->set_line_width(2);
            $context->move_to( $x1, $y1 );
            $context->line_to( $x2, $y2 );
            $context->line_to( $x3, $y3 );
            $context->line_to( $x4, $y4 );
            $context->line_to( $x1, $y1 );
            $context->stroke;

            #This is a very quick hack to check the squareness of the boxes drawn on map
            my $polyline = new GD::Polyline;

            #Create a square polygon
            $polyline->addPt( $x1, $y1 );
            $polyline->addPt( $x2, $y2 );
            $polyline->addPt( $x3, $y3 );
            $polyline->addPt( $x4, $y4 );
            $polyline->addPt( $x1, $y1 );

            #The anagles between the line segments
            my @vertexAngles = $polyline->vertexAngle();

            my $segment1Length = sqrt( ( $x1 - $x2 )**2 + ( $y1 - $y2 )**2 );
            my $segment2Length = sqrt( ( $x2 - $x3 )**2 + ( $y2 - $y3 )**2 );
            my $segment3Length = sqrt( ( $x3 - $x4 )**2 + ( $y3 - $y4 )**2 );
            my $segment4Length = sqrt( ( $x4 - $x1 )**2 + ( $y4 - $y1 )**2 );

            my $textviewBuffer = $main::textview1->get_buffer;
            my $iter           = $textviewBuffer->get_iter_at_offset(0);
            $textviewBuffer->insert( $iter,
                    "Angles: "
                  . rad2deg( $vertexAngles[1] ) . ","
                  . rad2deg( $vertexAngles[2] ) . ","
                  . rad2deg( $vertexAngles[3] )
                  . "\n" );
            $textviewBuffer->insert( $iter,
                    "Length Diff: "
                  . ( $segment1Length - $segment3Length ) . ","
                  . ( $segment2Length - $segment4Length )
                  . "\n\n" );

            # 	    $textviewBuffer->insert ($iter,"Length $segment1Length,$segment3Length - $segment2Length, $segment4Length\n\n");

            #             #say rad2deg(@vertexAngles[0]);
            #             say rad2deg( $vertexAngles[1] );
            #             say rad2deg( $vertexAngles[2] );
            #             say rad2deg( $vertexAngles[3] );
            #
            #             say "Segment 1 length "
            #               . $segment1Length;
            #             say "Segment 2 length "
            #               . $segment2Length;
            #             say "Segment 3 length "
            #               . $segment3Length;
            #             say "Segment 4 length "
            #               . $segment4Length;
            #
            #             $context->set_source_rgba( 0, 1, 1, .9 );
            #             $context->set_line_width(2);
            #             $context->move_to( $x2, $y2 );
            #             $context->line_to( $x3, $y3 );
            #
            #
            #             $context->stroke;
        }
    }

    # Text
    $context->set_source_rgba( 0.0, 0.9, 0.9, 0.5 );
    $context->select_font_face( "Sans", "normal", "normal" );
    $context->set_font_size(15);
    $context->move_to( 50, 25 );
    $context->show_text("$main::targetPng");
    $context->stroke;

    #  		$context->move_to(370, 170);
    #  		$context->text_path( "pretty" );
    # 		$context->set_source_rgba(0.9, 0, 0.9, 0.7);
    # 		$context->fill_preserve;
    # 		$context->set_source_rgba(0.2, 0.1, 0.1, 0.7);
    #  		$context->set_line_width( 2 );
    #  		$context->stroke;

    return TRUE;
}

sub plateBox_click {

    #Called when plicking on the plate image, we'll get the X/Y of the clicked point in the image
    my ( $widget, $event ) = @_;

    my ( $x, $y ) = ( $event->x, $event->y );

    # say "x:$x y:$y";
    # If the image is smaller than the window, we need to
    # translate these window coords into the image coords.
    # Get the allocated size of the image first.
    # I assume that the image is always centered within the allocation.
    # Then the coords are transformed.
    # $imagesize is the actual size of the image (in this case the png image)
    my $max_w  = $main::plate->get_allocation()->{width};
    my $max_h  = $main::plate->get_allocation()->{height};
    my $pixb_w = $main::scaledPlate->get_width();
    my $pixb_h = $main::scaledPlate->get_height();

    my $originalImageWidth  = $main::pixbuf->get_width();
    my $originalImageHeight = $main::pixbuf->get_height();

    my $horizontalScaleFactor = $originalImageWidth / $pixb_w;
    my $verticalScaleFactor   = $originalImageHeight / $pixb_h;

    $x -= ( $max_w - $pixb_w ) / 2;

    $y -= ( $max_h - $pixb_h ) / 2;

    $main::currentGcpPngX = $x * $horizontalScaleFactor;
    $main::currentGcpPngY = $y * $verticalScaleFactor;

    #     say "Scaled X:$x Y:$y"
    #       . " Original X:"
    #       . $x * $horizontalScaleFactor
    #       . "Y:"
    #       . $y * $verticalScaleFactor;
    #
    #     #     say "$horizontalScaleFactor, $verticalScaleFactor";

    return TRUE;
}

# sub nextPlateNotMarkedManually {
#     my ( $widget, $event ) = @_;
# 
#     my $totalPlateCount = scalar @{$_platesNotMarkedManually};
# 
#     if ( $indexIntoPlatesWithNoLonLat < ( $totalPlateCount - 1 ) ) {
#         $indexIntoPlatesWithNoLonLat++;
#     }
# 
#     say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
# 
#     #Get info about the airport we're currently pointing to
#     say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
#     my $rowRef = ( @$_platesNotMarkedManually[$indexIntoPlatesWithNoLonLat] );
# 
#     #Update information for the plate we're getting ready to display
#     activateNewPlate($rowRef);
# 
#     return TRUE;
# }
# 
# sub previousPlateNotMarkedManually {
#     my ( $widget, $event ) = @_;
# 
#     my $totalPlateCount = scalar @{$_platesNotMarkedManually};
#     say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
# 
#     if ( $indexIntoPlatesWithNoLonLat > 0 ) {
#         $indexIntoPlatesWithNoLonLat--;
#     }
# 
#     #Info about current plate
#     my $rowRef = ( @$_platesNotMarkedManually[$indexIntoPlatesWithNoLonLat] );
# 
#     #Update information for the plate we're getting ready to display
#     activateNewPlate($rowRef);
# 
#     say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
# 
#     return TRUE;
# }

# sub nextBadButtonClick {
#     my ( $widget, $event ) = @_;
# 
#     #Get info about the airport we're currently pointing to
#     my $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );
# 
#     my $totalPlateCount = scalar @{$_platesMarkedBad};
# 
#     #Update information for the plate we're getting ready to display
#     activateNewPlate($rowRef);
# 
#     #BUG TODO Make length of array
#     if ( $indexIntoPlatesMarkedBad < ( $totalPlateCount - 1 ) ) {
#         $indexIntoPlatesMarkedBad++;
#     }
# 
#     say "$indexIntoPlatesMarkedBad / $totalPlateCount";
# 
#     return TRUE;
# }
# 
# sub previousBadButtonClick {
#     my ( $widget, $event ) = @_;
# 
#     my $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );
# 
#     #Update information for the plate we're getting ready to display
#     activateNewPlate($rowRef);
# 
#     if ( $indexIntoPlatesMarkedBad > 0 ) {
#         $indexIntoPlatesMarkedBad--;
#     }
#     say $indexIntoPlatesMarkedBad;
# 
#     return TRUE;
# }

# sub nextChangedButtonClick {
#     my ( $widget, $event ) = @_;
# 
#     #Get info about the airport we're currently pointing to
#     my $rowRef = ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );
# 
#     my $totalPlateCount = scalar @{$_platesMarkedChanged};
# 
#     #Update information for the plate we're getting ready to display
#     activateNewPlate($rowRef);
# 
#     #BUG TODO Make length of array
#     if ( $indexIntoPlatesMarkedChanged < ( $totalPlateCount - 1 ) ) {
#         $indexIntoPlatesMarkedChanged++;
#     }
# 
#     say "$indexIntoPlatesMarkedChanged / $totalPlateCount";
# 
#     return TRUE;
# }
# 
# sub previousChangedButtonClick {
#     my ( $widget, $event ) = @_;
# 
#     my $rowRef = ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );
# 
#     #Update information for the plate we're getting ready to display
#     activateNewPlate($rowRef);
# 
#     if ( $indexIntoPlatesMarkedChanged > 0 ) {
#         $indexIntoPlatesMarkedChanged--;
#     }
#     say $indexIntoPlatesMarkedChanged;
# 
#     return TRUE;
# }

sub addGcpButtonClick {

    #Add to the GCP list
    #Uses the global variables
    my ( $widget, $event ) = @_;

    say "Name: $main::currentGcpName";
    say " Longitude: $main::currentGcpLon";
    say " Latitude: $main::currentGcpLat";
    say " PngX: $main::currentGcpPngX";
    say " PngY: $main::currentGcpPngY";

    #  my $textviewBuffer = $main::textview1->get_buffer;
    # 	  my $iter = $textviewBuffer->get_iter_at_offset (0);
    #           $textviewBuffer->insert ($iter, "FAA_CODE: $FAA_CODE -> Lon:$_airportLongitudeDec Lat:$_airportLatitudeDec\n\n");

    my $lstore = $main::gcpModel;

    my $iter = $lstore->append();

    $lstore->set(
        $iter,                 0, $main::currentGcpName, 1,
        $main::currentGcpLon,  2, $main::currentGcpLat,  3,
        "0",                   4, "0",                   5,
        $main::currentGcpPngX, 6, $main::currentGcpPngY
    );

    return TRUE;
}

sub deleteGcpsButtonClick {

    #Delete all of the currently defined GCPs
    my ( $widget, $event ) = @_;

    my $lstore = $main::gcpModel;
    $lstore->clear;

    return TRUE;
}

sub markNotReferenceableButtonClick {

    #Set this plate's status as not georeferenceable
    my ( $widget, $event ) = @_;
    updateStatus( "NOGEOREF", $main::PDF_NAME );

    return TRUE;
}

# sub deleteActiveGcp {
#   #Delete the active item in the liststore
#   my ( undef, $tree ) = @_;
#
#   my $sel = $main::gcpTreeview->get_selection;
#
#   my ( $model, $iter ) = $sel->get_selected;
#   return unless $iter;
#   $model->remove($iter);
#   return TRUE;
# }

sub deleteActiveGcpDelKey {

    #Linked to "Del" key on treeview
    #Delete the active item in the liststore
    my ( $widget, $event ) = @_;

    my $key = $event->keyval;

    #    say $key;
    #   say Gtk3::Gdk->keyval_name($key);
    if (
        #Delete key value
        $key == 65535

        #             $event->keyval == Gtk3::Gdk::KEY_DELETE;
      )
    {
        #
        #   say $key;
        #   if ($key eq 'Delete') {
        my $sel = $main::gcpTreeview->get_selection;
        my ( $model, $iter ) = $sel->get_selected;
        return unless $iter;
        $model->remove($iter);
        return TRUE;
    }
}

sub activateNewPlate {

    #Stuff we want to update every time we go to a new plate

    #Validate and set input parameters to this function
    #$rowRef is array reference to data about plate we're displaying
    my ($rowRef) = validate_pos(
        @_,
        { type => ARRAYREF },

    );

    #Populate variables from the passed in array row
    our (
        $TPP_VOLUME,   $FAA_CODE,     $CHART_SEQ,     $CHART_CODE,
        $CHART_NAME,   $USER_ACTION,  $PDF_NAME,      $FAANFD18_CODE,
        $MILITARY_USE, $COPTER_USE,   $STATE_ID,      $Difference,
        $upperLeftLon, $upperLeftLat, $lowerRightLon, $lowerRightLat,
        $xMed,         $yMed,         $xPixelSkew,    $yPixelSkew
    ) = @$rowRef;

    $main::statusBar->push( $context_id,
        "FAA_CODE: $FAA_CODE, CHART_CODE: $CHART_CODE, CHART_NAME: $CHART_NAME"
    );
    say "FAA_CODE: $FAA_CODE, CHART_CODE: $CHART_CODE, CHART_NAME: $CHART_NAME";

    my $textviewBuffer = $main::textview1->get_buffer;
    my $iter           = $textviewBuffer->get_iter_at_offset(0);
    $textviewBuffer->insert( $iter,
        "FAA_CODE: $FAA_CODE, CHART_CODE: $CHART_CODE, CHART_NAME: $CHART_NAME\n\n"
    );

    #FQN of the PDF for this chart
    my $targetPdf = $dtppDirectory . $PDF_NAME;

    #Pull out the various filename components of the input file from the command line
    my ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

    our $targetPng     = $dir . $filename . ".png";
    our $targetVrt     = $dir . $filename . ".vrt";
    our $storedGcpHash = $dir . "gcp-" . $filename . "-hash.txt";

    $statistics{'$targetPdf'} = $targetPdf;

    #Convert the PDF to a PNG if one doesn't already exist
    convertPdfToPng( $targetPdf, $targetPng );

    #Pull airport lon/lat from database
    ( $main::airportLatitudeDec, $main::airportLongitudeDec ) =
      findAirportLatitudeAndLongitude($FAA_CODE);

    #---------------------------------------------------------------------------------------
    #Look up runways for this airport from the database
    our $runwaysFromDatabaseHashref = findRunwaysInDatabase($FAA_CODE);

    #Testing adding liststore programmmatically to partially glade-built interface
    # Create TreeModel
    my $runwayModel = create_model_runways($runwaysFromDatabaseHashref);

    # Create a TreeView
    my $runwayTreeview = Gtk3::TreeView->new($runwayModel);
    $runwayTreeview->set_rules_hint(TRUE);
    $runwayTreeview->set_search_column(0);

    $runwayTreeview->get_selection->signal_connect(
        changed => sub {
            my ($selection) = @_;
            my ( $model, $iter ) = $selection->get_selected;

            #             say $main::currentGcpName;
            #             say $iter;
            if ($iter) {
                $main::currentGcpName = $model->get_value( $iter, 0 );
                $main::currentGcpLon  = $model->get_value( $iter, 1 );
                $main::currentGcpLat  = $model->get_value( $iter, 2 );
                $selection->get_tree_view->scroll_to_cell(
                    $model->get_path($iter),
                    undef, FALSE, 0.0, 0.0 );

                #     $treeview->scroll_to_cell ($path, $column=undef, $use_align=FALSE, $row_align=0.0, $col_align=0.0);

            }
        }
    );

    #Delete all existing children for the tab box
    foreach my $child ( $main::runwayBox->get_children ) {
        $main::runwayBox->remove($child);    # remove all the children
    }

    $main::runwayBox->add($runwayTreeview);

    # Add columns to TreeView
    add_columns_runways($runwayTreeview);
    $main::runwayBox->show_all();

    #Delete existing data from navaid, fixes, obstacles boxesl
    #Delete all existing children for the tab box
    foreach my $child ( $main::navaidBox->get_children ) {
        $main::navaidBox->remove($child);    # remove all the children
    }

    #Delete all existing children for the tab box
    foreach my $child ( $main::fixesBox->get_children ) {
        $main::fixesBox->remove($child);     # remove all the children
    }

    #Delete all existing children for the tab box
    foreach my $child ( $main::obstaclesBox->get_children ) {
        $main::obstaclesBox->remove($child);    # remove all the children
    }

    #Don't bother trying any of these if we don't have lat/lon info
    if ( $main::airportLongitudeDec && $main::airportLatitudeDec ) {

        #---------------------------------------------------------------------------------------
        #Find navaids near the airport
        our $navaids_from_db_hashref =
          findNavaidsNearAirport( $main::airportLongitudeDec,
            $main::airportLatitudeDec );

        #     print Dumper($navaids_from_db_hashref);

        #Testing adding liststore programmmatically to partially glade-built interface
        # Create TreeModel
        my $navaidModel = create_model($navaids_from_db_hashref);

        # Create a TreeView
        my $navaidTreeview = Gtk3::TreeView->new($navaidModel);
        $navaidTreeview->set_rules_hint(TRUE);
        $navaidTreeview->set_search_column(COLUMN_NAME);

        #     $navaidTreeview->signal_connect( row_activated => sub { Gtk3->main_quit } );

        #Connect a signal to scroll to selected row (eg as you type_
        $navaidTreeview->get_selection->signal_connect(
            changed => sub {
                my ($selection) = @_;
                my ( $model, $iter ) = $selection->get_selected;

                if ($iter) {
                    $main::currentGcpName = $model->get_value( $iter, 0 );
                    $main::currentGcpLon  = $model->get_value( $iter, 2 );
                    $main::currentGcpLat  = $model->get_value( $iter, 3 );
                    $selection->get_tree_view->scroll_to_cell(
                        $model->get_path($iter),
                        undef, FALSE, 0.0, 0.0 );
                }
            }
        );

        $main::navaidBox->add($navaidTreeview);

        # Add columns to TreeView
        add_columns($navaidTreeview);
        $main::navaidBox->show_all();

        #---------------------------------------------------

        #Find fixes near the airport
        our $fixes_from_db_hashref =
          findFixesNearAirport( $main::airportLongitudeDec,
            $main::airportLatitudeDec );

        our $fixes_from_db_iap_hashref =
          findFixesNearAirport2( $main::airportLongitudeDec,
            $main::airportLatitudeDec );

        #     print Dumper($fixes_from_db_hashref);

        #Testing adding liststore programmmatically to partially glade-built interface
        # Create TreeModel
        my $fixesModel = create_model($fixes_from_db_hashref);

        # Create a TreeView
        my $fixesTreeview = Gtk3::TreeView->new($fixesModel);
        $fixesTreeview->set_rules_hint(TRUE);
        $fixesTreeview->set_search_column(COLUMN_NAME);

        #     $fixesTreeview->signal_connect( row_activated => sub { Gtk3->main_quit } );

        #Set up Auto-scroll to selected row
        $fixesTreeview->get_selection->signal_connect(
            changed => sub {
                my ($selection) = @_;

                my ( $model, $iter ) = $selection->get_selected;

                if ($iter) {
                    $main::currentGcpName = $model->get_value( $iter, 0 );
                    $main::currentGcpLon  = $model->get_value( $iter, 2 );
                    $main::currentGcpLat  = $model->get_value( $iter, 3 );

                    #                 say $main::currentGcpName;
                    #                 say \$iter;
                    $selection->get_tree_view->scroll_to_cell(
                        $model->get_path($iter),
                        undef, FALSE, 0.5, 0.5 );

                    #     $treeview->scroll_to_cell ($path, $column=undef, $use_align=FALSE, $row_align=0.0, $col_align=0.0);

                }
            }
        );

        $main::fixesBox->add($fixesTreeview);

        # Add columns to TreeView
        add_columns($fixesTreeview);
        $main::fixesBox->show_all();

        #---------------------------------------------------
        #Find obstacles near the airport
        our $unique_obstacles_from_db_hashref =
          findObstaclesNearAirport( $main::airportLongitudeDec,
            $main::airportLatitudeDec );

        #     print Dumper($unique_obstacles_from_db_hashref);

        #Testing adding liststore programmmatically to partially glade-built interface
        # Create TreeModel
        my $obstaclesModel =
          create_model_obstacles($unique_obstacles_from_db_hashref);

        # Create a TreeView
        my $obstaclesTreeview = Gtk3::TreeView->new($obstaclesModel);
        $obstaclesTreeview->set_rules_hint(TRUE);
        $obstaclesTreeview->set_search_column(0);

        #Auto-scroll to selected row
        $obstaclesTreeview->get_selection->signal_connect(
            changed => sub {
                my ($selection) = @_;
                my ( $model, $iter ) = $selection->get_selected;
                if ($iter) {
                    $main::currentGcpName = $model->get_value( $iter, 0 );
                    $main::currentGcpLon  = $model->get_value( $iter, 1 );
                    $main::currentGcpLat  = $model->get_value( $iter, 2 );
                    $selection->get_tree_view->scroll_to_cell(
                        $model->get_path($iter),
                        undef, FALSE, 0.0, 0.0 );

                    #     $treeview->scroll_to_cell ($path, $column=undef, $use_align=FALSE, $row_align=0.0, $col_align=0.0);

                }
            }
        );

        $main::obstaclesBox->add($obstaclesTreeview);

        # Add columns to TreeView
        add_columns_runways($obstaclesTreeview);
        $main::obstaclesBox->show_all();

        #     #Find GPS waypoints near the airport
        #     our $gpswaypoints_from_db_hashref =
        #       findGpsWaypointsNearAirport( $main::airportLongitudeDec,
        #         $main::airportLatitudeDec );
        #     print Dumper($gpswaypoints_from_db_hashref);
    }

    #--------------------------------------------------------------------------
    #Populate the GCP box from stored GCP hash if it exists
    our $gcp_from_db_hashref;
    if ( -e $storedGcpHash ) {
        $main::statusBar->push( $context_id,
            "Loading existing hash table $storedGcpHash" );
        say "Loading existing hash table $storedGcpHash";
        my $textviewBuffer = $main::textview1->get_buffer;
        my $iter           = $textviewBuffer->get_iter_at_offset(0);
        $textviewBuffer->insert( $iter,
            "Loading existing hash table $storedGcpHash\n\n" );

        $gcp_from_db_hashref = retrieve($storedGcpHash);

        #         print Dumper($gcp_from_db_hashref);

    }
    else {
        $main::statusBar->push( $context_id,
            "No stored GCP hash, creating an empty one" );
        say "No stored GCP hash, creating an empty one";
        my $textviewBuffer = $main::textview1->get_buffer;
        my $iter           = $textviewBuffer->get_iter_at_offset(0);
        $textviewBuffer->insert( $iter,
            "No stored GCP hash, creating an empty one\n\n" );
        my %gcpHash;
        $gcp_from_db_hashref = \%gcpHash;
    }

    #           'fix-COATT-0.335522331285691' => {
    #                                              'lat' => '37.9582805555556',
    #                                              'lon' => '-77.5768027777778',
    #                                              'pdfx' => '135.945',
    #                                              'pdfy' => '467.38',
    #                                              'pngx' => '566.613139534884',
    #                                              'pngy' => '527.583333333333'
    #                                            },

    #Testing adding liststore programmmatically to partially glade-built interface
    # Create TreeModel
    our $gcpModel = create_model_gcp($gcp_from_db_hashref);

    #Create a TreeView
    our $gcpTreeview = Gtk3::TreeView->new($gcpModel);
    $gcpTreeview->set_rules_hint(TRUE);
    $gcpTreeview->set_search_column(0);

    #     $fixesTreeview->signal_connect( row_activated => sub { Gtk3->main_quit } );

    #Delete all existing children for the tab box
    foreach my $child ( $main::gcpBox->get_children ) {
        $main::gcpBox->remove($child);    # remove all the children
    }

    $main::gcpBox->add($gcpTreeview);

    # Add columns to TreeView
    add_columns_gcp($gcpTreeview);

    $gcpTreeview->signal_connect(
        key_press_event => \&deleteActiveGcpDelKey,
        $main::gcpTreeview
    );
    $main::gcpBox->show_all();

    #--------------------------------------------------------------------------
    #Commenting this out since military plates dont have text anyhow

    #     #A list of valid navaid names around the airport
    #     my @validNavaidNames = keys $navaids_from_db_hashref;
    #     our $validNavaidNames = join( " ", @validNavaidNames );
    #
    #     my ($obstacleTextBoxesHashRef, $fixTextBoxesHashRef, $navaidTextBoxesHashRef) = findAllTextboxes($targetPdf);

    #     #----------------------------------------------------------------------------------------------------------------------------------
    #     #Everything to do with obstacles
    #     #Get a list of unique potential obstacle heights from the pdftotext array
    #     #my @obstacle_heights = findObstacleHeightTexts(@pdftotext);
    #     our @obstacle_heights = testfindObstacleHeightTexts(@pdfToTextBbox);

    #------------------------------------------------------------------------------------------------------------------------------------------

    #Create a pixbuf from the .png of our plate
    $main::pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($targetPng);

    #Scale it to our available window size
    our $scaledPlate = load_image( $targetPng, $main::plateSw );
    $main::plate->set_from_pixbuf($scaledPlate);

    my $originalImageWidth  = $main::pixbuf->get_width();
    my $originalImageHeight = $main::pixbuf->get_height();
    my $scaledImageWidth    = $main::scaledPlate->get_width();
    my $scaledImageHeight   = $main::scaledPlate->get_height();

    my $horizontalScaleFactor = $originalImageWidth / $scaledImageWidth;
    my $verticalScaleFactor   = $originalImageHeight / $scaledImageHeight;

    our ( $AffineTransform, $invertedAffineTransform );

    #Make sure our basic parameters are defined before trying to create the transforms
    if ( $xMed && $yMed && $upperLeftLon && $upperLeftLat ) {

        #adjust the horizontal and vertical scale factors per the ratio of the image to the actual window
        $xMed       = $xMed * $horizontalScaleFactor;
        $xPixelSkew = $xPixelSkew * $horizontalScaleFactor;

        $yMed       = $yMed * $verticalScaleFactor;
        $yPixelSkew = $yPixelSkew * $verticalScaleFactor;

        say "Affine parameters calculated from existing GCP hash";
        say " pixelSizeX->$xMed";
        say " yPixelSkew->$yPixelSkew";
        say " xPixelSkew->$xPixelSkew";
        say " pixelSizeY->$yMed";
        say " upperLeftLon->$upperLeftLon";
        say " upperLeftLat->$upperLeftLat";
        my $textviewBuffer = $main::textview1->get_buffer;
        my $iter           = $textviewBuffer->get_iter_at_offset(0);
        $textviewBuffer->insert( $iter,
            "Affine parameters calculated from existing GCP hash\npixelSizeX->$xMed\nyPixelSkew->$yPixelSkew\nxPixelSkew->$xPixelSkew\npixelSizeY->$yMed\nupperLeftLon->$upperLeftLon\nupperLeftLat->$upperLeftLat\n\n"
        );

        #Set up the affine transformations
        #y sizes have to be negative
        if ( $yMed > 0 ) {
            say "Converting $yMed to negative";
            $yMed = -($yMed);
        }

        #Create the new transform
        $AffineTransform = Geometry::AffineTransform->new(
            m11 => $xMed,
            m12 => $yPixelSkew,
            m21 => $xPixelSkew,
            m22 => $yMed,
            tx  => $upperLeftLon,
            ty  => $upperLeftLat
        );

        #and its inverse
        $invertedAffineTransform = $AffineTransform->clone()->invert();
    }
    else {
        #Otherwise make sure transforms undefined
        $AffineTransform         = undef;
        $invertedAffineTransform = undef;
    }

    #Connect this signal to draw features over the plate
    $main::plate->signal_connect_after( draw => \&cairo_draw );

    return;
}

sub load_image {

    #Load and scale an image
    my ( $file, $parent ) = @_;
    my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($file);
    my $scaled = scale_pixbuf( $pixbuf, $parent );
    return $scaled;
}

sub scale_pixbuf {
    my ( $pixbuf, $parent ) = validate_pos(
        @_,
        { type => HASHREF },
        { type => HASHREF }

    );

    my $max_w  = $parent->get_allocation()->{width};
    my $max_h  = $parent->get_allocation()->{height};
    my $pixb_w = $pixbuf->get_width();
    my $pixb_h = $pixbuf->get_height();
    if ( ( $pixb_w > $max_w ) || ( $pixb_h > $max_h ) ) {
        my $sc_factor_w = $max_w / $pixb_w;
        my $sc_factor_h = $max_h / $pixb_h;
        my $sc_factor   = min $sc_factor_w, $sc_factor_h;
        my $sc_w        = int( $pixb_w * $sc_factor );
        my $sc_h        = int( $pixb_h * $sc_factor );
        my $scaled = $pixbuf->scale_simple( $sc_w, $sc_h, 'GDK_INTERP_HYPER' );
        return $scaled;
    }
    else {
        return $pixbuf;
    }
}

sub add_columns {
    my ($treeview) = validate_pos(
        @_,
        { type => HASHREF },

    );

    #Add columns to our treeview

    my $renderer = Gtk3::CellRendererText->new;

    my $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Name', $renderer,
        text => COLUMN_NAME );
    $column->set_sort_column_id(COLUMN_NAME);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Type', $renderer,
        text => COLUMN_TYPE );
    $column->set_sort_column_id(COLUMN_TYPE);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Longitude', $renderer,
        text => COLUMN_LONGITUDE );
    $column->set_sort_column_id(COLUMN_LONGITUDE);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Latitude', $renderer,
        text => COLUMN_LATITUDE );
    $column->set_sort_column_id(COLUMN_LATITUDE);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Distance', $renderer,
        text => COLUMN_DISTANCE );
    $column->set_sort_column_id(COLUMN_DISTANCE);
    $treeview->append_column($column);
}

sub create_model {
    my ($hashRef) = validate_pos(
        @_,
        { type => HASHREF },

    );

    #Define our listStore
    my $lstore = Gtk3::ListStore->new(
        'Glib::String', 'Glib::String', 'Glib::Double', 'Glib::Double',
        'Glib::Double'
    );

    #Populate the data for the list store from the hashRef
    for my $item ( sort keys $hashRef ) {
        my $iter = $lstore->append();

        #         say $hashRef->{$item}{Name};
        #         say $hashRef->{$item}{Type};
        $lstore->set(
            $iter,                   COLUMN_NAME,
            $hashRef->{$item}{Name}, COLUMN_TYPE,
            $hashRef->{$item}{Type}, COLUMN_LONGITUDE,
            $hashRef->{$item}{Lon},  COLUMN_LATITUDE,
            $hashRef->{$item}{Lat},  COLUMN_DISTANCE,
            $hashRef->{$item}{Distance}
        );
    }
    return $lstore;
}

sub add_columns_runways {

    #Add columns to our treeview

    my $treeview = shift;

    #     my $model    = $treeview->get_model();

    #     # Column for fixed toggles
    #     my $renderer = Gtk3::CellRendererToggle->new;
    #     $renderer->signal_connect(
    #         toggled => \&fixed_toggled,
    #         $model
    #     );
    my $renderer = Gtk3::CellRendererText->new;

    my $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Name', $renderer, text => 0 );
    $column->set_sort_column_id(0);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Longitude', $renderer,
        text => 1 );
    $column->set_sort_column_id(1);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Latitude', $renderer,
        text => 2 );
    $column->set_sort_column_id(2);
    $treeview->append_column($column);

}

sub create_model_runways {
    my ($hashRef) = validate_pos(
        @_,
        { type => HASHREF },

    );

    #Define our listStore
    my $lstore =
      Gtk3::ListStore->new( 'Glib::String', 'Glib::Double', 'Glib::Double' );

    #Populate the data for the list store from the hashRef
    for my $item ( keys $hashRef ) {
        my $iter = $lstore->append();

        #         say $hashRef->{$item}{Name};
        #         say $hashRef->{$item}{Type};
        #         get length of key
        #         split in two
        # say length $item;
        my $firstHalf = substr( $item, 0, ( ( length $item ) / 2 ) );
        my $secondHalf = substr( $item, -( ( length $item ) / 2 ) );

        #         say $item;
        #         say "$firstHalf - $secondHalf";
        $lstore->set(
            $iter, 0, $firstHalf, 1, $hashRef->{$item}{LELongitude},
            2, $hashRef->{$item}{LELatitude},
        );
        $iter = $lstore->append();

        #         $iter->next;
        $lstore->set(
            $iter, 0, $secondHalf, 1, $hashRef->{$item}{HELongitude},
            2, $hashRef->{$item}{HELatitude},
        );
    }
    return $lstore;
}

sub create_model_obstacles {
    my ($hashRef) = validate_pos(
        @_,
        { type => HASHREF },

    );

    #Define our listStore
    my $lstore =
      Gtk3::ListStore->new( 'Glib::Int', 'Glib::Double', 'Glib::Double' );

    #Populate the data for the list store from the hashRef
    for my $item ( sort keys $hashRef ) {
        my $iter = $lstore->append();

        #         say $hashRef->{$item}{Name};
        #         say $hashRef->{$item}{Type};
        #         get length of key
        #         split in two
        # say length $item;

        $lstore->set(
            $iter, 0, $hashRef->{$item}{Name},
            1, $hashRef->{$item}{Lon},
            2, $hashRef->{$item}{Lat},
        );

    }
    return $lstore;
}

sub add_columns_gcp {

    #Add columns to our treeview

    my $treeview = shift;

    #     my $model    = $treeview->get_model();

    #     # Column for fixed toggles
    #     my $renderer = Gtk3::CellRendererToggle->new;
    #     $renderer->signal_connect(
    #         toggled => \&fixed_toggled,
    #         $model
    #     );
    my $renderer = Gtk3::CellRendererText->new;

    my $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Name', $renderer, text => 0 );
    $column->set_sort_column_id(0);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Longitude', $renderer,
        text => 1 );
    $column->set_sort_column_id(1);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'Latitude', $renderer,
        text => 2 );
    $column->set_sort_column_id(2);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'pdfx', $renderer, text => 3 );
    $column->set_sort_column_id(3);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'pdfy', $renderer, text => 4 );
    $column->set_sort_column_id(4);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'pngx', $renderer, text => 5 );
    $column->set_sort_column_id(5);
    $treeview->append_column($column);

    $column =
      Gtk3::TreeViewColumn->new_with_attributes( 'pngy', $renderer, text => 6 );
    $column->set_sort_column_id(6);
    $treeview->append_column($column);

}

sub create_model_gcp {
    my ($hashRef) = validate_pos(
        @_,
        { type => HASHREF },

    );

    #Define our listStore
    my $lstore = Gtk3::ListStore->new(
        'Glib::String', 'Glib::Double', 'Glib::Double', 'Glib::Double',
        'Glib::Double', 'Glib::Double', 'Glib::Double'
    );

    #Populate the data for the list store from the hashRef
    for my $item ( sort keys $hashRef ) {
        my $iter = $lstore->append();

        #         say $hashRef->{$item}{Name};
        #         say $hashRef->{$item}{Type};
        #         get length of key
        #         split in two
        # say length $item;

        $lstore->set(
            $iter,                   0, $item,                   1,
            $hashRef->{$item}{lon},  2, $hashRef->{$item}{lat},  3,
            $hashRef->{$item}{pdfx}, 4, $hashRef->{$item}{pdfy}, 5,
            $hashRef->{$item}{pngx}, 6, $hashRef->{$item}{pngy},
        );

    }
    return $lstore;
}

sub listStoreRowClicked {
}

sub georeferenceButtonClicked {

    #Create a new hash from the current GCP liststore
    my $model = $main::gcpModel;
    my %newGcpHash;

    #For each line in the GPC liststore, extract column data and save in hash
    $model->foreach( \&gcpTest, \%newGcpHash );

    #     print Dumper \%newGcpHash;

    #Create the string of GCPs for gdal_translate from the hash
    my $gcpstring = createGcpString( \%newGcpHash );

    #Call gdal_translate to georef
    my (
        $pixelSizeX, $yPixelSkew,   $xPixelSkew,
        $pixelSizeY, $upperLeftLon, $upperLeftLat
    ) = georeferenceTheRaster($gcpstring);

    #BUG TODO Do we want to do any basic error checking here?
    #                     not( is_between( .00011, .00033, $pixelSizeY ) )
    #                     && not(
    #                         is_between( .00034, .00046, $pixelSizeY ) )
    #                     && not(
    #                         is_between( .00056, .00060, $pixelSizeY, ) )

    #update the affine transform with new parameters

    #redraw the plate
    $main::plateSw->queue_draw;

}

sub saveGeoreferenceButtonClicked {

    #Create a new hash from the current GCP liststore
    my $model = $main::gcpModel;
    my %newGcpHash;

    #For each line in the GPC liststore, extract column data and save in hash
    $model->foreach( \&gcpTest, \%newGcpHash );

    #Save the hash back to disk
    store( \%newGcpHash, $main::storedGcpHash )
      || die "can't store to $main::storedGcpHash\n";

    say "Saved GCP hash to disk";

}

sub lonLatButtonClicked {

    #Take the text of the lon/lat entry box and parse it to decimal representation
    my $text = $main::lonLatTextEntry->get_text;
    my ( $lonDecimal, $latDecimal );

    $text =~
      m/(?<lonDegrees>\d{2,})-(?<lonMinutes>\d\d\.?\d?)(?<lonDeclination>[E|W]),(?<latDegrees>\d{2,})-(?<latMinutes>\d\d\.?\d?)(?<latDeclination>[N|S])/ix;

    my $lonDegrees     = $+{lonDegrees};
    my $lonMinutes     = $+{lonMinutes};
    my $lonSeconds     = 0;
    my $lonDeclination = $+{lonDeclination};

    my $latDegrees     = $+{latDegrees};
    my $latMinutes     = $+{latMinutes};
    my $latSeconds     = 0;
    my $latDeclination = $+{latDeclination};

    #             say "$lonDegrees-$lonMinutes-$lonSeconds-$lonDeclination,$latDegrees-$latMinutes-$latSeconds-$latDeclination";
    if (   $lonDegrees
        && $lonMinutes
        && $lonDeclination
        && $latDegrees
        && $latMinutes
        && $latDeclination )
    {
        $lonDecimal =
          coordinateToDecimal2( $lonDegrees, $lonMinutes, $lonSeconds,
            $lonDeclination );
        $latDecimal =
          coordinateToDecimal2( $latDegrees, $latMinutes, $latSeconds,
            $latDeclination );
        say
          "$text -> $lonDegrees-$lonMinutes-$lonSeconds-$lonDeclination,$latDegrees-$latMinutes-$latSeconds-$latDeclination -> $lonDecimal,$latDecimal";
    }

    #Update the current GCP
    $main::currentGcpLon = $lonDecimal;
    $main::currentGcpLat = $latDecimal;
    $main::currentGcpName =
      "$lonDegrees-$lonMinutes-$lonSeconds-$lonDeclination,$latDegrees-$latMinutes-$latSeconds-$latDeclination";
}

sub coordinateToDecimal2 {

    my ( $deg, $min, $sec, $declination ) = validate_pos(
        @_,
        { type => SCALAR },
        { type => SCALAR },
        { type => SCALAR }
    );

    #     my ( $deg, $min, $sec, $declination ) = @_;

    my $signeddegrees;

    return "" if !( $declination =~ /[NSEW]/ );

    $deg = $deg / 1;
    $min = $min / 60;
    $sec = $sec / 3600;

    $signeddegrees = ( $deg + $min + $sec );

    if ( ( $declination eq "S" ) || ( $declination eq "W" ) ) {
        $signeddegrees = -($signeddegrees);
    }

    given ($declination) {
        when (/N|S/) {

            #Latitude is invalid if less than -90  or greater than 90
            $signeddegrees = "" if ( abs($signeddegrees) > 90 );
        }
        when (/E|W/) {

            #Longitude is invalid if less than -180 or greater than 180
            $signeddegrees = "" if ( abs($signeddegrees) > 180 );
        }
        default {
        }

    }

    # say "Coordinate: $coordinate to $signeddegrees"        if $debug;
    say "Deg: $deg, Min:$min, Sec:$sec, Decl:$declination" if $debug;
    return ($signeddegrees);
}

sub updateStatus {

    #Update this plates status in database to the passed in text
    my ( $_status, $_PDF_NAME ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    #Update the georef table
    my $update_dtpp_geo_record =
      "UPDATE dtppGeo " . "SET " . "status = ? " . "WHERE " . "PDF_NAME = ?";

    my $textviewBuffer = $main::textview1->get_buffer;
    my $iter           = $textviewBuffer->get_iter_at_offset(0);
    $textviewBuffer->insert( $iter, " $_status -> $_PDF_NAME d\n\n" );

    my $dtppSth = $dtppDbh->prepare($update_dtpp_geo_record);

    $dtppSth->bind_param( 1, $_status );
    $dtppSth->bind_param( 2, $_PDF_NAME );

    say "$_status, $_PDF_NAME";
    $dtppSth->execute();
    return;
}

sub markGoodButtonClick {
    my ( $widget, $event ) = @_;

    #Update the status of current plate in database
    updateStatus( "MANUALGOOD", $main::PDF_NAME );

    #Get the index of which plate we want to advance to on marking
    my $comboIndex = $main::comboboxtext1->get_active;
    my $rowRef;
      given ($comboIndex) {
        when (/0/) {

            #------------------------------
            #Use this section to skip to next "unverified" plate
            my $totalPlateCount = scalar @{$_platesNotMarkedManually};

            #BUG TODO Make length of array
            if ( $indexIntoPlatesWithNoLonLat < ( $totalPlateCount - 1 ) ) {
                $indexIntoPlatesWithNoLonLat++;
            }
      
           

            #Get info about the airport we're currently pointing to
            $rowRef =
              ( @$_platesNotMarkedManually[$indexIntoPlatesWithNoLonLat] );
               say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
               
             say "Next non-Manual";  
        }
        when (/1/) {

            #        ------------------------------
            #     Use this section to skip to next "changed" plate
         
	    my $totalPlateCount = scalar @{$_platesMarkedChanged};

            if ( $indexIntoPlatesMarkedChanged < ( $totalPlateCount - 1 ) ) {
                $indexIntoPlatesMarkedChanged++;
            }
               $rowRef =
              ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );
              
            say "$indexIntoPlatesMarkedChanged/ $totalPlateCount";

	    say "Next added/changed";

        }
        when (/2/) {

            #--------------------------------------
            #Use this section to skip to next "bad" plate
            my $totalPlateCount = scalar @{$_platesMarkedBad};

            #BUG TODO Make length of array
            if ( $indexIntoPlatesMarkedBad < ( $totalPlateCount - 1 ) ) {
                $indexIntoPlatesMarkedBad += 1;
            }
             $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );
            say "$indexIntoPlatesMarkedBad / $totalPlateCount";
            say "Next bad";

        }
    }

    #---------------------------------------

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    #     say @$_platesNotMarkedManually;

    return TRUE;
}

sub nextButtonClick {
 my ( $widget, $event ) = @_;
 
     #Get the index of which plate we want to advance to on marking
    my $comboIndex = $main::comboboxtext1->get_active;
    say $comboIndex;
    my $rowRef;
      given ($comboIndex) {
        when (/0/) {

            #------------------------------
            #Use this section to skip to next "unverified" plate
            my $totalPlateCount = scalar @{$_platesNotMarkedManually};

            #BUG TODO Make length of array
            if ( $indexIntoPlatesWithNoLonLat < ( $totalPlateCount - 1 ) ) {
                $indexIntoPlatesWithNoLonLat++;
            }
      
           

            #Get info about the airport we're currently pointing to
            $rowRef =
              ( @$_platesNotMarkedManually[$indexIntoPlatesWithNoLonLat] );
               say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
               
             say "Next non-Manual";  
        }
        when (/1/) {

            #        ------------------------------
            #     Use this section to skip to next "changed" plate
         
	    my $totalPlateCount = scalar @{$_platesMarkedChanged};

            if ( $indexIntoPlatesMarkedChanged < ( $totalPlateCount - 1 ) ) {
                $indexIntoPlatesMarkedChanged++;
            }
               $rowRef =
              ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );
              
            say "$indexIntoPlatesMarkedChanged/ $totalPlateCount";

	    say "Next added/changed";

        }
        when (/2/) {

            #--------------------------------------
            #Use this section to skip to next "bad" plate
            my $totalPlateCount = scalar @{$_platesMarkedBad};

            #BUG TODO Make length of array
            if ( $indexIntoPlatesMarkedBad < ( $totalPlateCount - 1 ) ) {
                $indexIntoPlatesMarkedBad += 1;
            }
             $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );
            say "$indexIntoPlatesMarkedBad / $totalPlateCount";
            say "Next bad";

        }
    }

    #---------------------------------------

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    #     say @$_platesNotMarkedManually;

    return TRUE;
 
}

sub previousButtonClick {
 my ( $widget, $event ) = @_;
 
     #Get the index of which plate we want to advance to on marking
    my $comboIndex = $main::comboboxtext1->get_active;
    say $comboIndex;
    my $rowRef;
      given ($comboIndex) {
        when (/0/) {

            #------------------------------
            #Use this section to skip to next "unverified" plate
            my $totalPlateCount = scalar @{$_platesNotMarkedManually};

            #BUG TODO Make length of array
            if ( $indexIntoPlatesWithNoLonLat  > 0 ) {
		  $indexIntoPlatesWithNoLonLat--;
                
            }
      
           

            #Get info about the airport we're currently pointing to
            $rowRef =
              ( @$_platesNotMarkedManually[$indexIntoPlatesWithNoLonLat] );
               say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
               
             say "Next non-Manual";  
        }
        when (/1/) {

            #        ------------------------------
            #     Use this section to skip to next "changed" plate
         
	    my $totalPlateCount = scalar @{$_platesMarkedChanged};

            if ( $indexIntoPlatesMarkedChanged  > 0 ) {
		  $indexIntoPlatesMarkedChanged--;
            }
               $rowRef =
              ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );
              
            say "$indexIntoPlatesMarkedChanged/ $totalPlateCount";

	    say "Next added/changed";

        }
        when (/2/) {

            #--------------------------------------
            #Use this section to skip to next "bad" plate
            my $totalPlateCount = scalar @{$_platesMarkedBad};

            #BUG TODO Make length of array
            if ( $indexIntoPlatesMarkedBad > 0 ) {
		  $indexIntoPlatesMarkedBad--;
            }
             $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );
            say "$indexIntoPlatesMarkedBad / $totalPlateCount";
            say "Next bad";

        }
    }

    #---------------------------------------

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    return TRUE;
 
}

sub markBadButtonClick {
    my ( $widget, $event ) = @_;

    #Set status in the database
    updateStatus( "MANUALBAD", $main::PDF_NAME );

    #     #--------------------------------------
    #     #Use this section to skip to next "unverified" plate
    #     my $totalPlateCount = scalar @{$_platesNotMarkedManually};
    #
    #     #BUG TODO Make length of array
    #     if ( $indexIntoPlatesWithNoLonLat < ( $totalPlateCount - 1 ) ) {
    #         $indexIntoPlatesWithNoLonLat++;
    #
    #     }
    #
    #     say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
    #
    #     #Get info about the airport we're currently pointing to
    #     my $rowRef = ( @$_platesNotMarkedManually[$indexIntoPlatesWithNoLonLat] );

    #     --------------------------------------
    #Use this section to skip to next "bad" plate
    my $totalPlateCount = scalar @{$_platesMarkedBad};

    #BUG TODO Make length of array
    if ( $indexIntoPlatesMarkedBad < ( $totalPlateCount - 1 ) ) {
        $indexIntoPlatesMarkedBad += 1;
    }
    my $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );
    say "$indexIntoPlatesMarkedBad / $totalPlateCount";

    #         my $rowRef = ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );
    #
    #     #Update information for the plate we're getting ready to display
    #     activateNewPlate($rowRef);
    #
    #     if ( $indexIntoPlatesMarkedChanged > 0 ) {
    #         $indexIntoPlatesMarkedChanged--;
    #     }
    #     say $indexIntoPlatesMarkedChanged;
    #
    #     #     say @$_platesNotMarkedManually;

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    return TRUE;
}

sub coordinateToDecimalCifpFormat {

    #Convert a latitude or longitude in CIFP format to its decimal equivalent
    my ($coordinate) = validate_pos( @_, { type => SCALAR }, );

    my ( $deg, $min, $sec, $signedDegrees, $declination, $secPostDecimal );
    my $data;

    #First parse the common information for a record to determine which more specific parser to use
    my $parser_latitude = Parse::FixedLength->new(
        [
            qw(
              Declination:1
              Degrees:2
              Minutes:2
              Seconds:2
              SecondsPostDecimal:2
              )
        ]
    );
    my $parser_longitude = Parse::FixedLength->new(
        [
            qw(
              Declination:1
              Degrees:3
              Minutes:2
              Seconds:2
              SecondsPostDecimal:2
              )
        ]
    );

    #Get the first character of the coordinate and parse accordingly
    $declination = substr( $coordinate, 0, 1 );

    given ($declination) {
        when (/[NS]/) {
            $data = $parser_latitude->parse_newref($coordinate);
            die "Bad input length on parser_latitude"
              if ( $parser_latitude->length != 9 );

            #Latitude is invalid if less than -90  or greater than 90
            # $signedDegrees = "" if ( abs($signedDegrees) > 90 );
        }
        when (/[EW]/) {
            $data = $parser_longitude->parse_newref($coordinate);
            die "Bad input length on parser_longitude"
              if ( $parser_longitude->length != 10 );

            #Longitude is invalid if less than -180 or greater than 180
            # $signedDegrees = "" if ( abs($signedDegrees) > 180 );
        }
        default {
            return -1;

        }
    }

    $declination    = $data->{Declination};
    $deg            = $data->{Degrees};
    $min            = $data->{Minutes};
    $sec            = $data->{Seconds};
    $secPostDecimal = $data->{SecondsPostDecimal};

    # print Dumper($data);

    $deg = $deg / 1;
    $min = $min / 60;

    #Concat the two portions of the seconds field with a decimal between
    $sec = ( $sec . "." . $secPostDecimal );

    # say "Sec: $sec";
    $sec           = ($sec) / 3600;
    $signedDegrees = ( $deg + $min + $sec );

    #Make coordinate negative if necessary
    if ( ( $declination eq "S" ) || ( $declination eq "W" ) ) {
        $signedDegrees = -($signedDegrees);
    }

    # say "Coordinate: $coordinate to $signedDegrees";           #if $debug;
    # say "Decl:$declination Deg: $deg, Min:$min, Sec:$sec";    #if $debug;

    return ($signedDegrees);
}

sub gcpTest {

    #Extract column data from the GCP liststore and save in hash
    my ( $model, $path, $iter, $user_data ) = validate_pos(
        @_,
        { type => HASHREF },
        { type => SCALARREF },
        { type => SCALARREF },
        { type => HASHREF | UNDEF },
    );
    my $key = $model->get_value( $iter, 0 );
    $user_data->{$key}{lon}  = $model->get_value( $iter, 1 );
    $user_data->{$key}{lat}  = $model->get_value( $iter, 2 );
    $user_data->{$key}{pdfx} = $model->get_value( $iter, 3 );
    $user_data->{$key}{pdfy} = $model->get_value( $iter, 4 );
    $user_data->{$key}{pngx} = $model->get_value( $iter, 5 );
    $user_data->{$key}{pngy} = $model->get_value( $iter, 6 );

    # say $model->get_value( $iter, 0 );
    # say $model->get_value( $iter, 1 );
    # say $model->get_value( $iter, 2 );
    return FALSE;
}

sub createGcpString {
    my ($gcpHashRef) = validate_pos( @_, { type => HASHREF }, );
    my $_gcpstring = "";
    foreach my $key ( keys $gcpHashRef ) {

        #build the GCP portion of the command line parameters
        $_gcpstring =
            $_gcpstring
          . " -gcp "
          . $gcpHashRef->{$key}{"pngx"} . " "
          . $gcpHashRef->{$key}{"pngy"} . " "
          . $gcpHashRef->{$key}{"lon"} . " "
          . $gcpHashRef->{$key}{"lat"};
    }

    say "Ground Control Points command line string";
    say $_gcpstring;
    say "";

    return $_gcpstring;
}

sub georeferenceTheRaster {
    my ($gcpstring) = validate_pos( @_, { type => SCALAR }, );

    # #Try to georeference

    #World file format
    #     pixel resolution * cos(rotation angle)
    #     -pixel resolution * sin(rotation angle)
    #     -pixel resolution * sin(rotation angle)
    #     -pixel resolution * cos(rotation angle)
    #     upper left x
    #     upper left y

    my $gdal_translateCommand =
      "gdal_translate -of VRT -strict -a_srs EPSG:4326 $gcpstring '$main::targetPng' '$main::targetVrt'";

    if ($main::debug) {
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
    say $gdal_translateoutput if $main::debug;

    #     #Run gdalwarp
    #
    #     my $gdalwarpCommand =
    #       "gdalwarp -q -of VRT -t_srs EPSG:4326 -order 1 -overwrite ''$main::targetvrt''  '$main::targetvrt2'";
    #     if ($debug) {
    #         say $gdalwarpCommand;
    #         say "";
    #     }
    #
    #     my $gdalwarpCommandOutput = qx($gdalwarpCommand);
    #
    #     $retval = $? >> 8;
    #
    #     if ( $retval != 0 ) {
    #         carp
    #           "Error executing gdalwarp.  Is it installed? Return code was $retval";
    #         ++$main::failCount;
    #         touchFile($main::failFile);
    #         $statistics{'$status'} = "AUTOBAD";
    #         return (1);
    #     }
    #
    #     say $gdalwarpCommandOutput if $debug;
    #
    #     #Run gdalinfo
    #
    #     my $gdalinfoCommand = "gdalinfo '$main::targetvrt2'";
    #     if ($debug) {
    #         say $gdalinfoCommand;
    #         say "";
    #     }
    #
    #     my $gdalinfoCommandOutput = qx($gdalinfoCommand);
    #
    #     $retval = $? >> 8;
    #
    #     if ( $retval != 0 ) {
    #         carp
    #           "Error executing gdalinfo.  Is it installed? Return code was $retval";
    #           $statistics{'$status'} = "AUTOBAD";
    #         return;
    #     }
    #     say $gdalinfoCommandOutput if $debug;
    #
    #     #Extract georeference info from gdalinfo output (some of this will be overwritten below)
    #     my (
    #         $pixelSizeX,    $pixelSizeY,    $upperLeftLon, $upperLeftLat,
    #         $lowerRightLon, $lowerRightLat, $lonLatRatio
    #     ) = extractGeoreferenceInfo($gdalinfoCommandOutput);

    #---------------------
    my $gdalinfoCommand = "gcps2wld.py '$main::targetVrt'";

    if ($debug) {
        say $gdalinfoCommand;

        say "";
    }

    my $gdalinfoCommandOutput = qx($gdalinfoCommand);

    $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gcps2wld.py, is it installed? Return code was $retval";

        #           $statistics{'$status'} = "AUTOBAD";
        #         return;
    }

    my ( $pixelSizeX, $pixelSizeY, $upperLeftLon, $upperLeftLat, );
    say $gdalinfoCommandOutput if $debug;
    my ( $xPixelSkew, $yPixelSkew );

    #Extract georeference info from gdalinfo output
    (
        $pixelSizeX, $pixelSizeY, $xPixelSkew, $yPixelSkew, $upperLeftLon,
        $upperLeftLat

    ) = extractGeoreferenceInfoGcps2Wld($gdalinfoCommandOutput);
    say "From gcps2wld: ";
    say " pixelSizeX->$pixelSizeX";
    say " yPixelSkew->$yPixelSkew";
    say " xPixelSkew->$xPixelSkew";
    say " pixelSizeY->$pixelSizeY";
    say " upperLeftLon->$upperLeftLon";
    say " upperLeftLat->$upperLeftLat";

    if ( $pixelSizeX && $pixelSizeY && $upperLeftLon && $upperLeftLat ) {
        say "Updating database with new affine transform information";

        #BUG TODO
        if ( $main::CHART_CODE =~ /IAP/ ) {

            #Instrument Approach Procedures are always True North Up
            $xPixelSkew = 0;
            $yPixelSkew = 0;
        }

        #Update the georef table
        my $update_dtpp_geo_record =
            "UPDATE dtppGeo " . "SET "
          . "xMedian = ?, "
          . "yMedian = ?, "
          . "upperLeftLon = ?, "
          . "upperLeftLat = ?, "
          . "xPixelSkew = ?, "
          . "yPixelSkew = ? "
          . "WHERE "
          . "PDF_NAME = ?";

        my $dtppSth = $dtppDbh->prepare($update_dtpp_geo_record);

        $dtppSth->bind_param( 1, $pixelSizeX );
        $dtppSth->bind_param( 2, $pixelSizeY );
        $dtppSth->bind_param( 3, $upperLeftLon );
        $dtppSth->bind_param( 4, $upperLeftLat );
        $dtppSth->bind_param( 5, $xPixelSkew );
        $dtppSth->bind_param( 6, $yPixelSkew );
        $dtppSth->bind_param( 7, $main::PDF_NAME );

        #     say "$_status, $_PDF_NAME";
        my $rc = $dtppSth->execute()
          or die "Can't execute statement: $DBI::errstr";

        my $originalImageWidth  = $main::pixbuf->get_width();
        my $originalImageHeight = $main::pixbuf->get_height();
        my $scaledImageWidth    = $main::scaledPlate->get_width();
        my $scaledImageHeight   = $main::scaledPlate->get_height();

        my $horizontalScaleFactor = $originalImageWidth / $scaledImageWidth;
        my $verticalScaleFactor   = $originalImageHeight / $scaledImageHeight;

        #adjust the scale factors per the ratio of the image to the actual window

        $pixelSizeX = $pixelSizeX * $horizontalScaleFactor;
        $xPixelSkew = $xPixelSkew * $horizontalScaleFactor;
        $pixelSizeY = $pixelSizeY * $verticalScaleFactor;
        $yPixelSkew = $yPixelSkew * $verticalScaleFactor;

        #         say "pixX: $pixelSizeX pixY: $pixelSizeY";
        say "Values scaled to image size:";
        say " pixelSizeX->$pixelSizeX";
        say " yPixelSkew->$yPixelSkew";
        say " xPixelSkew->$xPixelSkew";
        say " pixelSizeY->$pixelSizeY";
        say " upperLeftLon->$upperLeftLon";
        say " upperLeftLat->$upperLeftLat";

        #Update the transform
        $main::AffineTransform = Geometry::AffineTransform->new(
            m11 => $pixelSizeX,
            m12 => $yPixelSkew,
            m21 => $xPixelSkew,
            m22 => $pixelSizeY,
            tx  => $upperLeftLon,
            ty  => $upperLeftLat
        );
        $main::invertedAffineTransform =
          $main::AffineTransform->clone()->invert();

    }
    return (
        $pixelSizeX, $yPixelSkew,   $xPixelSkew,
        $pixelSizeY, $upperLeftLon, $upperLeftLat
    );

    #     return 0;
}

sub extractGeoreferenceInfoGcps2Wld {

    #Pull relevant information out of gdalinfo command
    my ($_output) = @_;
    my (
        $pixelSizeX, $yPixelSkew, $xPixelSkew, $pixelSizeY, $upperLeftLon,
        $upperLeftLat

    ) = split( /\n/, $_output );

    say
      '$pixelSizeX,    $pixelSizeY,    $upperLeftLon, $upperLeftLat,  $xPixelSkew, $yPixelSkew';
    say
      "$pixelSizeX,    $pixelSizeY,    $upperLeftLon, $upperLeftLat,  $xPixelSkew, $yPixelSkew";

    #     return (
    #         $pixelSizeX,    $pixelSizeY,    $upperLeftLon, $upperLeftLat,
    #         $xPixelSkew, $yPixelSkew
    #     );
    return (

        $pixelSizeX, $pixelSizeY, $xPixelSkew, $yPixelSkew, $upperLeftLon,
        $upperLeftLat
    );
}
