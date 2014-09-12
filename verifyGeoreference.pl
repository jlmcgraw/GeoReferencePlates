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
my $opt_string = 'cspvobma:i:';
my $arg_num    = scalar @ARGV;

#Whether to draw various features
our $shouldDrawRunways = 1;
our $shouldDrawFixes;
our $shouldDrawNavaids   = 1;
our $shouldDrawObstacles = 0;
our $shouldDrawGcps = 1;

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
my $_plateWithNoLonLat          = chartsWithNoLonLat();
my $indexIntoPlatesWithNoLonLat = 0;

#a reference to an array of charts marked bad
my $_platesMarkedBad         = chartsMarkedBad();
my $indexIntoPlatesMarkedBad = 0;

#a reference to an array of charts marked Changed
my $_platesMarkedChanged         = chartsMarkedChanged();
my $indexIntoPlatesMarkedChanged = 0;

our (
    $currentGcpName, $currentGcpLon,  $currentGcpLat, $currentGcpPdfX,
    $currentGcpPdfY, $currentGcpPngX, $currentGcpPngY
);

#Process each plate returned by our query
foreach my $_row (@$_allPlates) {

    my (
        $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
        $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
        $MILITARY_USE, $COPTER_USE,  $STATE_ID
    ) = @$_row;

    our ( $airportLatitudeDec, $airportLongitudeDec );

    #--------------------------------------------------------------------------------------------------------------
    # #Some regex building blocks to be used elsewhere
    #numbers that start with 1-9 followed by 2 or more digits
    our $obstacleHeightRegex = qr/[1-9]\d{1,}/x;

    #A number with possible decimal point and minus sign
    our $numberRegex = qr/[-\.\d]+/x;

    #Create the UI
    my $builder = Gtk3::Builder->new();
    $builder->add_from_file('./verifyPlatesUI.glade');

    #Set the initial plate
    our $plate   = $builder->get_object('image2');
    our $plateSw = $builder->get_object('viewport1');
    our $pixbuf;

    #Connect our handlers
    $builder->connect_signals(undef);

    my $window = $builder->get_object('applicationwindow1');
    $window->set_screen( $window->get_screen() );
    $window->signal_connect( destroy => sub { Gtk3->main_quit } );

    our $runwayBox    = $builder->get_object('runwayBox');
    our $navaidBox    = $builder->get_object('navaidBox');
    our $fixesBox     = $builder->get_object('fixesBox');
    our $obstaclesBox = $builder->get_object('obstaclesBox');
    our $gcpBox       = $builder->get_object('gcpBox');

    my $liststoreNavaids = $builder->get_object('liststoreNavaids');

    #     $liststoreNavaids->set_column_types( qw/Glib::String/ );
    #     my $navaidsIter = $liststoreNavaids->append;
    # #		my $s = Gtk2::ListStore->new('G::String');
    # 	      for (qw(foo bar baz foofoo foobar foobaz)) {
    # # 		$listStoreNadvaids->set($navaidsIter, 3 => "test");
    # 		$liststoreNavaids->insert_with_values($navaidsIter,0 => "$_");
    # # 		$liststoreNavaids->insert_with_values($navaidsIter,0,"TEST2");
    # 	      }
    #
    #  my $treeView = $builder->get_object('treeview');
    # # 	      my $l = Gtk2::TreeView->new($s);
    # 	      $treeView->append_column(
    # 	       Gtk3::TreeViewColumn->new_with_attributes(
    # 	        "foo",
    # 	        Gtk3::CellRendererText->new,
    # 	        text => 3
    # 	        )
    # 	      );
    $window->show_all();
    Gtk3->main();

    #Execute the main loop for this plate
    #     doAPlate( $PDF_NAME, $FAA_CODE, $STATE_ID, $CHART_NAME );
    exit;
}

# #Close the charts database
# $dtppSth->finish();
$dtppDbh->disconnect();

#Close the locations database
# $sth->finish();
$dbh->disconnect();

exit;

# sub plateBox_click {
# #   my ( $widget, $event, $data ) = @_;
#   say "wft";
#   #     g_print ("Event box clicked at coordinates %f,%f\n",
#   #              event->x, event->y);
#
#     return TRUE;
# }

# sub on_button_clicked {
#     $image->set_from_pixbuf(load_image($file, $scrolled));
# }
#
#
# sub load_image {
#     my ($file, $parent) = @_;
#     my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($file);
#     my $scaled = scale_pixbuf($pixbuf, $parent);
#     return $scaled;
# }
#
# sub scale_pixbuf {
#     my ($pixbuf, $parent) = @_;
#     my $max_w = $parent->get_allocation()->{width};
#     my $max_h = $parent->get_allocation()->{height};
#     my $pixb_w = $pixbuf->get_width();
#     my $pixb_h = $pixbuf->get_height();
#     if (($pixb_w > $max_w) || ($pixb_h > $max_h)) {
#         my $sc_factor_w = $max_w / $pixb_w;
#         my $sc_factor_h = $max_h / $pixb_h;
#         my $sc_factor = min $sc_factor_w, $sc_factor_h;
#         my $sc_w = int($pixb_w * $sc_factor);
#         my $sc_h = int($pixb_h * $sc_factor);
#         my $scaled
#             = $pixbuf->scale_simple($sc_w, $sc_h, 'GDK_INTERP_HYPER');
#         return $scaled;
#     }
#     return $pixbuf;
# }

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#SUBROUTINES
#------------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------
#The main loop
sub doAPlate {

    #Validate and set input parameters to this function
    my ( $PDF_NAME, $FAA_CODE, $STATE_ID, $CHART_NAME ) = validate_pos(
        @_,
        { type => SCALAR },
        { type => SCALAR },
        { type => SCALAR },
        { type => SCALAR },
    );

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

    # our $targetvrt         = $dir . $filename . ".vrt";
    our $targetVrtFile =
      $STATE_ID . "-" . $FAA_CODE . "-" . $PDF_NAME . "-" . $CHART_NAME;

    # convert spaces, ., and slashes to dash
    $targetVrtFile =~ s/[\s \/ \\ \. \( \)]/-/xg;
    our $targetVrtBadRatio = $dir . "badRatio-" . $targetVrtFile . ".vrt";
    our $touchFile         = $dir . "noPoints-" . $targetVrtFile . ".vrt";
    our $targetvrt         = $dir . $targetVrtFile . ".vrt";

    our $targetStatistics = "./statistics.csv";

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

    # if ( scalar(@pdftotext) < 5 ) {
    # say "Not enough pdftotext output for $targetPdf";
    # writeStatistics() if $shouldOutputStatistics;
    # return(1);
    # }

    #Get the mediabox size and other variables from the PDF
    our ( $pdfXSize, $pdfYSize, $pdfCenterX, $pdfCenterY, $pdfXYRatio ) =
      getMediaboxSize();

    #     #Convert the PDF to a PNG if one doesn't already exist
    #     convertPdfToPng();

    #     #Get PNG dimensions and the PDF->PNG scale factors
    #     our ( $pngXSize, $pngYSize, $scaleFactorX, $scaleFactorY, $pngXYRatio ) =
    #       getPngSize();

    # my $rawPdf = returnRawPdf();

    #

    #---------------------------------------------------------------------------------------------------------------------------------------------------
    #Create the combined hash of Ground Control Points
    our %gcps = ();

    #     #Add Runway endpoints to Ground Control Points hash
    #     addCombinedHashToGroundControlPoints( "runway",
    #         \%matchedRunIconsToDatabase );
    #
    #     #Add Obstacles to Ground Control Points hash
    #     addCombinedHashToGroundControlPoints( "obstacle",
    #         $matchedObstacleIconsToTextBoxes );
    #
    #     #Add Fixes to Ground Control Points hash
    #     addCombinedHashToGroundControlPoints( "fix", $matchedFixIconsToTextBoxes );
    #
    #     #Add Navaids to Ground Control Points hash
    #     addCombinedHashToGroundControlPoints( "navaid",
    #         $matchedNavaidIconsToTextBoxes );
    #
    #     #Add GPS waypoints to Ground Control Points hash
    #     addCombinedHashToGroundControlPoints( "gps",
    #         $matchedGpsWaypointIconsToTextBoxes );
    #
    #     if ($debug) {
    #         say "";
    #         say "Combined Ground Control Points";
    #         print Dumper ( \%gcps );
    #         say "";
    #     }
    #
    #     #build the GCP portion of the command line parameters
    #     my $gcpstring = createGcpString();
    #
    #     #outline the GCP points we ended up using
    #     drawCircleAroundGCPs() if $shouldSaveMarkedPdf;
    #
    #     #Make sure we have enough GCPs
    #     my $gcpCount = scalar( keys(%gcps) );
    #     say "Found $gcpCount potential Ground Control Points" if $debug;
    #
    #     #Save statistics
    #     $statistics{'$gcpCount'} = $gcpCount;
    #
    #     if ($shouldSaveMarkedPdf) {
    #         $pdf->saveas($outputPdf);
    #     }
    #
    #     #----------------------------------------------------------------------------------------------------------------------------------------------------
    #     #Now some math
    #     our ( @xScaleAvg, @yScaleAvg, @ulXAvg, @ulYAvg, @lrXAvg, @lrYAvg ) = ();
    #
    #     our ( $xAvg,    $xMedian,   $xStdDev )   = 0;
    #     our ( $yAvg,    $yMedian,   $yStdDev )   = 0;
    #     our ( $ulXAvrg, $ulXmedian, $ulXStdDev ) = 0;
    #     our ( $ulYAvrg, $ulYmedian, $ulYStdDev ) = 0;
    #     our ( $lrXAvrg, $lrXmedian, $lrXStdDev ) = 0;
    #     our ( $lrYAvrg, $lrYmedian, $lrYStdDev ) = 0;
    #     our ($lonLatRatio) = 0;
    #
    #     #Can't do anything if we didn't find any valid ground control points
    #     if ( $gcpCount < 2 ) {
    #         say
    #           "Only found $gcpCount ground control points in $targetPdf, can't georeference";
    #         say "Touching $touchFile";
    #         open( my $fh, ">", "$touchFile" )
    #           or die "cannot open > $touchFile: $!";
    #         close($fh);
    #         say
    #           "xScaleAvgSize: $statistics{'$xScaleAvgSize'}, yScaleAvgSize: $statistics{'$yScaleAvgSize'}";
    #
    #         #touch($touchFile);
    #         writeStatistics() if $shouldOutputStatistics;
    #         return (1);
    #     }
    #
    #     #Calculate the rough X and Y scale values
    #     if ( $gcpCount == 1 ) {
    #         say "Found 1 ground control points in $targetPdf";
    #         say "Touching $touchFile";
    #         open( my $fh, ">", "$touchFile" )
    #           or die "cannot open > $touchFile: $!";
    #         close($fh);
    #
    #         #Is it better to guess or do nothing?  I think we should do nothing
    #         #calculateRoughRealWorldExtentsOfRasterWithOneGCP();
    #         writeStatistics() if $shouldOutputStatistics;
    #         return (1);
    #     }
    #     else {
    #         calculateRoughRealWorldExtentsOfRaster();
    #     }
    #
    #
    #     # if ($debug) {
    #     # say "";
    #     # say "Ground Control Points showing mismatches";
    #     # print Dumper ( \%gcps );
    #     # say "";
    #     # }
    #
    #     if ( @xScaleAvg && @yScaleAvg ) {
    #
    #         #Smooth out the X and Y scales we previously calculated
    #         calculateSmoothedRealWorldExtentsOfRaster();
    #
    #         #Actually produce the georeferencing data via GDAL
    #         georeferenceTheRaster();
    #
    #         #Count of entries in this array
    #         my $xScaleAvgSize = 0 + @xScaleAvg;
    #
    #         #Count of entries in this array
    #         my $yScaleAvgSize = 0 + @yScaleAvg;
    #
    #         say "xScaleAvgSize: $xScaleAvgSize, yScaleAvgSize: $yScaleAvgSize";
    #
    #         #Save statistics
    #         $statistics{'$xAvg'}          = $xAvg;
    #         $statistics{'$xMedian'}       = $xMedian;
    #         $statistics{'$xScaleAvgSize'} = $xScaleAvgSize;
    #         $statistics{'$yAvg'}          = $yAvg;
    #         $statistics{'$yMedian'}       = $yMedian;
    #         $statistics{'$yScaleAvgSize'} = $yScaleAvgSize;
    #         $statistics{'$lonLatRatio'}   = $lonLatRatio;
    #     }
    #     else {
    #         say
    #           "No points actually added to the scale arrays for $targetPdf, can't georeference";
    #
    #         say "Touching $touchFile";
    #
    #         open( my $fh, ">", "$touchFile" )
    #           or die "cannot open > $touchFile: $!";
    #         close($fh);
    #     }
    #
    #     #Write out the statistics of this file if requested
    #     writeStatistics() if $shouldOutputStatistics;

    return;
}

# sub findObstacleHeightTexts {
#
#     #The text from the PDF
#     my @_pdftotext = @_;
#     my @_obstacle_heights;
#
#     foreach my $line (@_pdftotext) {
#
#         #Find numbers that match our obstacle height regex
#         if ( $line =~ m/^($main::obstacleHeightRegex)$/ ) {
#
#             #Any height over 30000 is obviously bogus
#             next if $1 > 30000;
#             push @_obstacle_heights, $1;
#         }
#
#     }
#
#     #Remove all entries that aren't unique
#     @_obstacle_heights = onlyuniq(@_obstacle_heights);
#
#     if ($debug) {
#         say "Potential obstacle heights from PDF";
#         print join( " ", @_obstacle_heights ), "\n";
#
#         say "Unique potential obstacle heights from PDF";
#         print join( " ", @_obstacle_heights ), "\n";
#     }
#     return @_obstacle_heights;
# }

# sub testfindObstacleHeightTexts {
#
#     #The text from the PDF
#     my @_pdftotext = @_;
#     my @_obstacle_heights;
#
#     foreach my $line (@_pdftotext) {
#
#         # say $line;
#         #Find numbers that match our obstacle height regex
#         if ( $line =~
#             m/xMin="[\d\.]+" yMin="[\d\.]+" xMax="[\d\.]+" yMax="[\d\.]+">($main::obstacleHeightRegex)</
#           )
#         {
#
#             #Any height over 30000 is obviously bogus
#             next if $1 > 30000;
#             push @_obstacle_heights, $1;
#         }
#
#     }
#
#     #Remove all entries that aren't unique
#     @_obstacle_heights = onlyuniq(@_obstacle_heights);
#
#     if ($debug) {
#         say "Potential obstacle heights from PDF";
#         print join( " ", @_obstacle_heights ), "\n";
#
#         say "Unique potential obstacle heights from PDF";
#         print join( " ", @_obstacle_heights ), "\n";
#     }
#     return @_obstacle_heights;
# }
#
sub findAirportLatitudeAndLongitude {

    #Validate and set input parameters to this function
    my ($FAA_CODE) = validate_pos( @_, { type => SCALAR }, );

    #Get the lat/lon of the airport for the plate we're working on

    my $_airportLatitudeDec  = "";
    my $_airportLongitudeDec = "";

    #Query the database for airport
    my $sth = $dbh->prepare(
        "SELECT  FaaID, Latitude, Longitude, Name  
             FROM airports  
             WHERE  FaaID = '$FAA_CODE'"
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

    #         if ( $_airportLongitudeDec eq "" or $_airportLatitudeDec eq "" ) {
    #             say
    #               "No airport coordinate information found for $airportId in $main::targetPdf  or database";
    #             return (1);
    #         }

    #     #Save statistics
    #     $statistics{'$airportLatitude'}  = $_airportLatitudeDec;
    #     $statistics{'$airportLongitude'} = $_airportLongitudeDec;
    say
      "FAA_CODE: $FAA_CODE, Lat:$_airportLatitudeDec, Lon:$_airportLongitudeDec";
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

    #---------------------------------------------------------------------------------------------------------------------------------------------------
    #Find obstacles with a certain height in the database

    #@obstacle_heights only contains unique potential heights mentioned on the plate
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

    #         return ( $dtppSth->fetchall_arrayref() );

    my $all = $dtppSth->fetchall_arrayref();

    #         my $_rows = $sth->rows();
    #         say "Found $_rows objects of height $heightmsl" if $debug;

    #         #This may be a terrible idea but I'm testing the theory that if an obstacle is mentioned only once on the PDF that even if that height is not unique in the real world within the bounding box
    #         #that the designer is going to show the one that's closest to the airport.  I could be totally wrong here and causing more mismatches than I'm solving
    #         my $bestDistanceToAirport = 9999;
    #
    #         if ($shouldUseMultipleObstacles) {
    #             foreach my $_row (@$all) {
    #                 my ( $lat, $lon, $heightmsl, $heightagl ) = @$_row;
    #                 my $distanceToAirport =
    #                   sqrt( ( $lat - $main::airportLatitudeDec )**2 +
    #                       ( $lon - $main::airportLongitudeDec )**2 );
    #
    #                 #say    "current distance $distanceToAirport, best distance for object of height $heightmsl msl is now $bestDistanceToAirport";
    #                 next if ( $distanceToAirport > $bestDistanceToAirport );
    #
    #                 $bestDistanceToAirport = $distanceToAirport;
    #
    #                 #say "closest distance for object of height $heightmsl msl is now $bestDistanceToAirport";
    #
    #                 $main::unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
    #                 $main::unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
    #             }
    #         }
    #         else {
    #Don't show results of searches that have more than one result, ie not unique
    #             next if ( $_rows != 1 );

    foreach my $_row (@$all) {

        #Populate variables from our database lookup
        my ( $lat, $lon, $heightmsl, $heightagl ) = @$_row;
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

# sub findObstacleHeightTextBoxes {
#
#     #Validate and set input parameters to this function
#     my ($pdfToTextBbox) =
#       validate_pos( @_, { type => ARRAYREF } );
#
#     #-----------------------------------------------------------------------------------------------------------
#     #Get list of potential obstacle height textboxes
#     #For whatever dumb reason they're in raster axes (0,0 is top left, Y increases downwards)
#     #   but in points coordinates
#     my $obstacleTextBoxRegex =
#       qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">($main::obstacleHeightRegex)</;
#
#     my %obstacleTextBoxes;
#
#     foreach my $line (@$pdfToTextBbox) {
#         if ( $line =~ m/$obstacleTextBoxRegex/ ) {
#             $obstacleTextBoxes{ $1 . $2 }{"Text"} = $5;
#
#         }
#
#     }
#     return ( \%obstacleTextBoxes );
# }

# sub findFixTextboxes {
#
#     #Validate and set input parameters to this function
#     my ($pdfToTextBbox) =
#       validate_pos( @_, { type => ARRAYREF } );
#
#     #--------------------------------------------------------------------------
#     #Get list of potential fix/intersection/GPS waypoint  textboxes
#     #For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#     #We'll convert them to PDF coordinates
#     my $fixTextBoxRegex =
#       qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([A-Z]{5})</;
#
#     my $invalidFixNamesRegex = qr/tower|south|radar/i;
#     my %fixTextboxes;
#
#     foreach my $line (@$pdfToTextBbox) {
#         if ( $line =~ m/$fixTextBoxRegex/ ) {
#             my $_fixXMin = $1;
#             my $_fixYMin = $2;
#             my $_fixXMax = $3;
#             my $_fixYMax = $4;
#             my $_fixName = $5;
#
#             # $fixTextboxes{ $_fixXMin . $_fixYMin }{"RasterX"} =
#
#             $fixTextboxes{ $_fixXMin . $_fixYMin }{"Text"} = $_fixName;
#         }
#
#     }
#     return ( \%fixTextboxes );
# }
#
# sub findNavaidTextboxes {
#
#     #Validate and set input parameters to this function
#     my ($pdfToTextBbox) =
#       validate_pos( @_, { type => ARRAYREF } );
#
#     #--------------------------------------------------------------------------
#     #Get list of potential VOR (or other ground based nav)  textboxes
#
#     my $vorTextBoxRegex =
#       qr/^\s+<word xMin="($main::numberRegex)" yMin="($main::numberRegex)" xMax="($main::numberRegex)" yMax="($main::numberRegex)">([A-Z]{3})<\/word>$/m;
#
#     my %vorTextboxes;
#
#     foreach my $line (@$pdfToTextBbox) {
#         if ( $line =~ m/$vorTextBoxRegex/ ) {
#             my $_navXMin = $1;
#             my $_navYMin = $2;
#             my $_navXMax = $3;
#             my $_navYMax = $4;
#             my $_navName = $5;
#
#             $vorTextboxes{ $_navXMin . $_navYMin }{"Text"} = $_navName;
#         }
#
#     }
#
#     return ( \%vorTextboxes );
# }

sub calculateRoughRealWorldExtentsOfRaster {
    my ($gcpsHashRef) =
      validate_pos( @_, { type => HASHREF } );

    #This is where we finally generate the real information for each plate
    foreach my $key ( sort keys $gcpsHashRef ) {

        #This code is for calculating the PDF x/y and lon/lat differences between every object
        #to calculate the ratio between the two
        foreach my $key2 ( sort keys $gcpsHashRef ) {

            #Don't calculate a scale with ourself
            next if $key eq $key2;

            my ( $ulX, $ulY, $lrX, $lrY, $longitudeToPixelRatio,
                $latitudeToPixelRatio, $longitudeToLatitudeRatio );

            #X pixels between points
            my $pixelDistanceX =
              ( $gcpsHashRef->{$key}{"pngx"} - $gcpsHashRef->{$key2}{"pngx"} );

            #Y pixels between points
            my $pixelDistanceY =
              ( $gcpsHashRef->{$key}{"pngy"} - $gcpsHashRef->{$key2}{"pngy"} );

            #Longitude degrees between points
            my $longitudeDiff =
              ( $gcpsHashRef->{$key}{"lon"} - $gcpsHashRef->{$key2}{"lon"} );

            #Latitude degrees between points
            my $latitudeDiff =
              ( $gcpsHashRef->{$key}{"lat"} - $gcpsHashRef->{$key2}{"lat"} );

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

                    #                     if ($debug) {
                    say
                      "Bad latitudeToPixelRatio $latitudeToPixelRatio on $key->$key2 pair";

                    #                     }

                    #   next;
                }
                else {
                    #For the raster, calculate the latitude of the upper-left corner based on this object's latitude and the degrees per pixel
                    $ulY =
                      $gcpsHashRef->{$key}{"lat"} +
                      ( $gcpsHashRef->{$key}{"pngy"} * $latitudeToPixelRatio );

                    #For the raster, calculate the latitude of the lower-right corner based on this object's latitude and the degrees per pixel
                    $lrY =
                      $gcpsHashRef->{$key}{"lat"} -
                      (
                        abs( $main::pngYSize - $gcpsHashRef->{$key}{"pngy"} ) *
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

                    say
                      "Bad longitudeToPixelRatio $longitudeToPixelRatio on $key-$key2 pair";

                }
                else {
                    #For the raster, calculate the Longitude of the upper-left corner based on this object's longitude and the degrees per pixel
                    $ulX =
                      $gcpsHashRef->{$key}{"lon"} -
                      ( $gcpsHashRef->{$key}{"pngx"} * $longitudeToPixelRatio );

                    #For the raster, calculate the longitude of the lower-right corner based on this object's longitude and the degrees per pixel
                    $lrX =
                      $gcpsHashRef->{$key}{"lon"} +
                      (
                        abs( $main::pngXSize - $gcpsHashRef->{$key}{"pngx"} ) *
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

            #             say
            #               "$key,$key2,$pixelDistanceX,$pixelDistanceY,$longitudeDiff,$latitudeDiff,$longitudeToPixelRatio,$latitudeToPixelRatio,$ulX,$ulY,$lrX,$lrY,$longitudeToLatitudeRatio"
            #               if $debug;

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
        croak
          "Error executing gdal_translate.  Is it installed? Return code was $retval";
    }
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

    my $dtppSth = $dtppDbh->prepare($update_dtpp_geo_record);

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

    #     $dtppSth->bind_param( 32, $PDF_NAME );

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

        my @A = NESW( coordinateToDecimalCifpFormat($lon),coordinateToDecimalCifpFormat($lat) );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $fixes_from_db{$fixname}{"Name"}     = $fixname;
        $fixes_from_db{$fixname}{"Lat"}      = coordinateToDecimalCifpFormat($lat);
        $fixes_from_db{$fixname}{"Lon"}      = coordinateToDecimalCifpFormat($lon);
        $fixes_from_db{$fixname}{"Type"}     = '$fixtype';
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

        my @A = NESW( coordinateToDecimalCifpFormat($lon),coordinateToDecimalCifpFormat($lat) );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $fixes_from_db{$fixname}{"Name"}     = $fixname;
        $fixes_from_db{$fixname}{"Lat"}      = coordinateToDecimalCifpFormat($lat);
        $fixes_from_db{$fixname}{"Lon"}      = coordinateToDecimalCifpFormat($lon);
        $fixes_from_db{$fixname}{"Type"}     = '$fixtype';
        $fixes_from_db{$fixname}{"Distance"} = $nm;
    }
    return ( \%fixes_from_db );
}

# sub findFeatureInDatabaseNearAirport {
#
#     #Validate and set input parameters to this function
#     my ( $airportLongitude, $airportLatitude ) =
#       validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );
#
#     #my ($radius, $type, $table, $referenceToHash) = @_;
#     my $radiusNm = .5;
#
#     #Calculate radius for the airport's latitude
#     my ( $radiusDegreesLatitude, $radiusDegreesLongitude ) =
#       radiusGivenLatitude( $radiusNm, $airportLatitude );
#
#     #What type of fixes to look for
#     my $type = "%REP-PT";
#
#     #Query the database for fixes within our $radius
#     my $sth = $dbh->prepare(
#         "SELECT *
#         FROM fixes
#         WHERE
#         (Latitude >  $main::airportLatitudeDec - $radius )
#         and
#         (Latitude < $main::airportLatitudeDec + $radius )
#         and
#         (Longitude >  $main::airportLongitudeDec - $radius )
#         and
#         (Longitude < $main::airportLongitudeDec +$radius )
#         and
#         (Type like '$type')"
#     );
#     $sth->execute();
#
#     my $allSqlQueryResults = $sth->fetchall_arrayref();
#
#     foreach my $_row (@$allSqlQueryResults) {
#         my ( $fixname, $lat, $lon, $fixtype ) = @$_row;
#         $main::fixes_from_db{$fixname}{"Name"} = $fixname;
#         $main::fixes_from_db{$fixname}{"Lat"}  = $lat;
#         $main::fixes_from_db{$fixname}{"Lon"}  = $lon;
#         $main::fixes_from_db{$fixname}{"Type"} = $fixtype;
#
#     }
#
# #     if ($debug) {
# #         my $nmLatitude = 60 * $radius;
# #         my $nmLongitude =
# #           $nmLatitude * cos( deg2rad($main::airportLatitudeDec) );
# #
# #         my $_rows  = $sth->rows();
# #         my $fields = $sth->{NUM_OF_FIELDS};
# #         say
# #           "Found $_rows FIXES within $radius degrees of airport  ($main::airportLongitudeDec, $main::airportLatitudeDec) ($nmLongitude x $nmLatitude nm)  from database";
# #
# #         say "All $type fixes from database";
# #         say "We have selected $fields field(s)";
# #         say "We have selected $_rows row(s)";
# #
# #         #print Dumper ( \%fixes_from_db );
# #         say "";
# #     }
#
#     return;
# }

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

        my @A = NESW( $lon, $lat );
        my @B = NESW( $airportLongitude, $airportLatitude );

        # Last number is radius of earth in whatever units (eg 6378.137 is kilometers
        my $km = great_circle_distance( @A, @B, 6378.137 );
        my $nm = great_circle_distance( @A, @B, 3443.89849 );

        $navaids_from_db{$navaidName}{"Name"}     = $navaidName;
        $navaids_from_db{$navaidName}{"Lat"}      = $lat;
        $navaids_from_db{$navaidName}{"Lon"}      = $lon;
        $navaids_from_db{$navaidName}{"Type"}     = $navaidType;
        $navaids_from_db{$navaidName}{"Distance"} = $nm;

    }
    return ( \%navaids_from_db );
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



# sub findAllTextboxes {
#
#     #Validate and set input parameters to this function
#     my ($targetPdf) =
#       validate_pos( @_, { type => SCALAR } );
#
#     #Get all of the text and respective bounding boxes in the PDF
#     my @pdfToTextBbox = qx(pdftotext $targetPdf -layout -bbox - );
#     my $retval        = $? >> 8;
#     die
#       "No output from pdftotext -bbox.  Is it installed? Return code was $main::retval"
#       if ( @pdfToTextBbox eq "" || $retval != 0 );
#
#     #Find potential obstacle height textboxes
#     my $obstacleTextBoxesHashRef =
#       findObstacleHeightTextBoxes( \@pdfToTextBbox );
#     print Dumper ($obstacleTextBoxesHashRef);
#
#     #Find textboxes that are valid for both fix and GPS waypoints
#     my $fixTextBoxesHashRef = findFixTextboxes( \@pdfToTextBbox );
#     print Dumper ($fixTextBoxesHashRef);
#
#     #Find textboxes that are valid for navaids
#     my $navaidTextBoxesHashRef = findNavaidTextboxes( \@pdfToTextBbox );
#     print Dumper ($navaidTextBoxesHashRef);
#
#     return ( $obstacleTextBoxesHashRef, $fixTextBoxesHashRef,
#         $navaidTextBoxesHashRef );
# }

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

sub chartsWithNoLonLat {

    #Charts with no lon/lat
    my $dtppSth = $dtppDbh->prepare( "
      SELECT 
	D.PDF_NAME
	,D.FAA_CODE
	,D.CHART_NAME
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
--           AND 
--        FAA_CODE LIKE  '$airportId' 
--           AND
--        STATE_ID LIKE  '$stateId'                   
          AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
          AND
        DG.STATUS NOT LIKE '%MANUAL%'
--        CAST (DG.upperLeftLon AS FLOAT) = '0'
--          AND
--        CAST (DG.xScaleAvgSize as FLOAT) > 1
--          AND
--        Difference  > .08
--      ORDER BY 
--        Difference ASC
;"
    );
    $dtppSth->execute();

    #An array of all APD and IAP charts with no lon/lat
    return ( $dtppSth->fetchall_arrayref() );
}

sub allIapAndApdCharts {

    #Query the dtpp database for IAP and APD charts
    my $dtppSth = $dtppDbh->prepare(
        "SELECT  TPP_VOLUME, FAA_CODE, CHART_SEQ, CHART_CODE, CHART_NAME, USER_ACTION, PDF_NAME, FAANFD18_CODE, MILITARY_USE, COPTER_USE, STATE_ID
             FROM dtpp  
             WHERE  
                ( 
                  CHART_CODE = 'IAP' 
                    OR 
                  CHART_CODE = 'APD' 
                )                 
                AND 
                FAA_CODE LIKE  '$airportId' 
                AND
                STATE_ID LIKE  '$stateId'
                "
    );

    $dtppSth->execute();

    #An array of all APD and IAP charts
    return ( $dtppSth->fetchall_arrayref() );
}

sub chartsMarkedBad {

    #Charts marked bad
    my $dtppSth = $dtppDbh->prepare( "
      SELECT
	D.PDF_NAME
	,D.FAA_CODE
	,D.CHART_NAME
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
--           AND
--        FAA_CODE LIKE  '$airportId'
--           AND
--        STATE_ID LIKE  '$stateId'
          AND
        DG.PDF_NAME NOT LIKE '%DELETED%'
          AND
        DG.STATUS LIKE '%BAD%'
        --Civilian charts only for now
         AND
        D.MILITARY_USE != 'M'
--          AND
--        CAST (DG.yScaleAvgSize AS FLOAT) > 1
--          AND
--        CAST (DG.xScaleAvgSize as FLOAT) > 1
--          AND
--        Difference  > .08
      ORDER BY
        Difference ASC
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
	D.PDF_NAME
	,D.FAA_CODE
	,D.CHART_NAME
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
        DG.PDF_NAME NOT LIKE '%DELETED%'

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

    #     #calculate degrees of latitude per pixel
    #     my $pixelSizeY =
    #       abs( $main::upperLeftLat - $main::lowerRightLat ) / $scaledImageHeight;
    #     my $_yPixel = abs( ( $main::upperLeftLat - $_latitude ) / $pixelSizeY );

    #BUG TODO, why doesn't $_yPixel have right sign after transform?
    # if ($_yPixel < 0)
    # { $_yPixel = -($_yPixel);}
    #Clamp to height
    if ( $_yPixel < 0 || $_yPixel > $scaledImageHeight ) {
#         $_yPixel = $scaledImageHeight;
#          $_yPixel = ($scaledImageHeight + ( $scrollWindowHeight - $scaledImageHeight ) / 2 );
	 $_yPixel = 0;
    }
    else {
        $_yPixel =
          ( $_yPixel + ( $scrollWindowHeight - $scaledImageHeight ) / 2 );
    }

    #     #calculate degrees of longitude per pixel
    #     my $pixelSizeX =
    #       abs( $main::upperLeftLon - $main::lowerRightLon ) / $scaledImageWidth;
    #     my $_xPixel = abs( $main::upperLeftLon - $_longitude ) / $pixelSizeX;
    #Clamp to width
    if (  $_xPixel < 0 || $_xPixel > $scaledImageWidth ) {
#         $_xPixel = ($scaledImageWidth + ( $scrollWindowWidth - $scaledImageWidth ) / 2 );
	  $_xPixel = 0;
    }
    else {
        $_xPixel =
          ( $_xPixel + ( $scrollWindowWidth - $scaledImageWidth ) / 2 );
    }
     return ( $_xPixel, $_yPixel ) ;
}
else {return (0,0)}
    #
#     say "Longitude: $_longitude -> $_xPixel, Latitude: $_latitude -> $_yPixel";
  

}

# sub latitudeToPixel {
#     my ($_latitude) = @_;
#
#     #     return 0 unless $main::yMedian;
#     return 0 unless $main::upperLeftLat;
#
#     #The height of our plate pixbuf
#     #     my $pixb_h = $main::pixbuf->get_height();
#
#     my $scaledImageHeight  = $main::scaledPlate->get_height();
#     my $scrollWindowHeight = $main::plateSw->get_allocation()->{height};
#
#     #     my $pixb_h = $main::scaledPlate->get_height();
#     my $pixb_h = $main::scaledPlate->get_height();
#
#     #     my $pixb_h = $main::plateSw->get_allocation()->{height};
#
#     #calculate degrees of latitude per pixel
#     my $pixelSizeY =
#       abs( $main::upperLeftLat - $main::lowerRightLat ) / $pixb_h;
#
#     #     my $_pixel = abs( ( $main::ulYmedian - $_latitude ) / $main::yMedian );
#
#     #BUG HACK TODO
#     #     say $main::upperLeftLat;
#     my $_pixel = abs( ( $main::upperLeftLat - $_latitude ) / $pixelSizeY );
#
#     #     say "$_latitude to $_pixel";
#     return 0 if ( $_pixel > $scaledImageHeight );
#     return ( $_pixel + ( $scrollWindowHeight - $scaledImageHeight ) / 2 );
# }
#
# sub longitudeToPixel {
#     my ($_longitude) = @_;
#
#     #     return 0 unless $main::xMedian;
#     return 0 unless $main::upperLeftLon;
#
#     #The width of our plate pixbuf
#     #     my $pixb_w = $main::pixbuf->get_width();
#     my $pixb_w = $main::scaledPlate->get_width();
#
#     #     my $pixb_w = $main::plateSw->get_allocation()->{width};
#
#     #calculate degrees of longitude per pixel
#     my $pixelSizeX =
#       abs( $main::upperLeftLon - $main::lowerRightLon ) / $pixb_w;
#
#     #BUG HACK TODO
#     #     my $_pixel = abs( ( $main::ulXmedian - $_longitude ) / $main::xMedian );
#     #  say $main::upperLeftLon;
#     my $_pixel = abs( $main::upperLeftLon - $_longitude ) / $pixelSizeX;
#
#     #     say "$_longitude to $_pixel";
#
#     my $scaledImageWidth  = $main::scaledPlate->get_width();
#     my $scrollWindowWidth = $main::plateSw->get_allocation()->{width};
#     return 0 if ( $_pixel > $scaledImageWidth );
#
#     return ( $_pixel + ( $scrollWindowWidth - $scaledImageWidth ) / 2 );
# }

sub toggleDrawingFixes {
    $main::shouldDrawFixes = !$main::shouldDrawFixes;
#     gtk_widget_draw($main::plateSw, NULL);
#     $main::plateSw->draw(NULL);
    $main::plateSw->queue_draw;   
}

sub toggleDrawingNavaids {
    $main::shouldDrawNavaids = !$main::shouldDrawNavaids;
   $main::plateSw->queue_draw;   
}

sub toggleDrawingRunways {
    $main::shouldDrawRunways = !$main::shouldDrawRunways;
   $main::plateSw->queue_draw;   
}

sub cairo_draw {
    my ( $widget, $context, $ref_status ) = @_;

    my $runwayHashRef  = $main::runwaysFromDatabaseHashref;
    my $navaidsHashRef = $main::navaids_from_db_hashref;
    my $fixHashRef     = $main::fixes_from_db_hashref;
    my $gcpHashRef     = $main::gcp_from_db_hashref;

    #Draw fixes
    if ($shouldDrawFixes) {
        foreach my $key ( sort keys $fixHashRef ) {

            my $lat  = $fixHashRef->{$key}{"Lat"};
            my $lon  = $fixHashRef->{$key}{"Lon"};
            my $text = $fixHashRef->{$key}{"Name"};

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($lat);
            #             my $x1 = longitudeToPixel($lon);
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
            if ( $x1 && $y1 ) {

                # Circle with border - transparent
                $context->set_source_rgba( 0, 0, 255, 0.2 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;

                #             $context->set_source_rgba( 0.9, 0.2, 0.2, 0.2 );
                $context->set_source_rgba( 0, 0, 255, 0.2 );
                $context->fill;

#                             # Text
#                             $context->set_source_rgba( 255, 0, 255, 255 );
#                             $context->select_font_face( "Sans", "normal", "normal" );
#                             $context->set_font_size(9);
#                             $context->move_to( $x1+5, $y1 );
#                             $context->show_text("$text");
#                             $context->stroke;
            }
        }
    }

    #Draw navaids
    if ($shouldDrawNavaids) {
        foreach my $key ( sort keys $navaidsHashRef ) {

            my $lat  = $navaidsHashRef->{$key}{"Lat"};
            my $lon  = $navaidsHashRef->{$key}{"Lon"};
            my $text = $navaidsHashRef->{$key}{"Name"};

            # 		    say "$latLE, $lonLE, $latHE, $lonHE";
            #             my $y1 = latitudeToPixel($lat);
            #             my $x1 = longitudeToPixel($lon);
            my ( $x1, $y1 ) = wgs84ToPixelBuf( $lon, $lat );
            if ( $x1 && $y1 ) {

                # Circle with border - transparent
                $context->set_source_rgba( 0, 255, 0, 128 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;
                $context->set_source_rgba( 0, 255, 0, 128 );
                $context->fill;

                # Text
                $context->set_source_rgba( 255, 0, 255, 128 );
                $context->select_font_face( "Sans", "normal", "normal" );
                $context->set_font_size(10);
                $context->move_to( $x1+5, $y1 );
                $context->show_text("$text");
                $context->stroke;
            }
        }
    }

    # # 		# Line
    # 		$context->set_source_rgba(0, 255, 0, 0.5);
    # 		$context->set_line_width(30);
    # 		$context->move_to(50, 50);
    #  		$context->line_to(550, 350);
    #  		$context->stroke;

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
            if ( $x1 && $y1 && $x2 && $y2  ) {
                $context->set_source_rgba( 255, 0, 0, 128 );
                $context->set_line_width(2);
                $context->move_to( $x1, $y1 );
                $context->line_to( $x2, $y2 );
                $context->stroke;
            }

        }
    }
    #Draw GCPs
    if ($shouldDrawGcps) {
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
                $context->set_source_rgba( 0, 255, 0, 128 );
                $context->arc( $x1, $y1, 2, 0, 3.1415 * 2 );
                $context->set_line_width(2);
                $context->stroke_preserve;
                $context->set_source_rgba( 0, 255, 0, 128 );
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

    # Text
    $context->set_source_rgba( 0.0, 0.9, 0.9, 0.7 );
    $context->select_font_face( "Sans", "normal", "normal" );
    $context->set_font_size(15);
    $context->move_to( 0, 0 );
    $context->show_text("$main::targetPng");
    $context->stroke;

    #  		$context->move_to(370, 170);
    #  		$context->text_path( "pretty" );
    # 		$context->set_source_rgba(0.9, 0, 0.9, 0.7);
    # 		$context->fill_preserve;
    # 		$context->set_source_rgba(0.2, 0.1, 0.1, 0.7);
    #  		$context->set_line_width( 2 );
    #  		$context->stroke;

    return FALSE;
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
    my $max_w = $main::plate->get_allocation()->{width};
    my $max_h = $main::plate->get_allocation()->{height};

    #Commenting out while playing with scaling
    #     my $pixb_w = $main::pixbuf->get_width();
    #     my $pixb_h = $main::pixbuf->get_height();
    my $pixb_w = $main::scaledPlate->get_width();
    my $pixb_h = $main::scaledPlate->get_height();

    #W
    my $originalImageWidth  = $main::pixbuf->get_width();
    my $originalImageHeight = $main::pixbuf->get_height();

    my $horizontalScaleFactor = $originalImageWidth / $pixb_w;
    my $verticalScaleFactor   = $originalImageHeight / $pixb_h;

    #         my @imageallocatedsize = $main::plate->allocation->values;
    #         $x -= ($imageallocatedsize[2] - $imagesize[0])/2;
    $x -= ( $max_w - $pixb_w ) / 2;

    #         $y -= ($imageallocatedsize[3] - $imagesize[1])/2;
    $y -= ( $max_h - $pixb_h ) / 2;

    $main::currentGcpPngX = $x * $horizontalScaleFactor;
    $main::currentGcpPngY = $y * $verticalScaleFactor;
    say "Scaled X:$x Y:$y"
      . " Original X:"
      . $x * $horizontalScaleFactor . "Y:"
      . $y * $verticalScaleFactor;

    #     say "$horizontalScaleFactor, $verticalScaleFactor";
    say

      return TRUE;
}

sub nextZeroButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #
    my $totalPlateCount = scalar @{$_plateWithNoLonLat};

    #Get info about the airport we're currently pointing to
    say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
    my $rowRef = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    #BUG TODO Make length of array
    if ( $indexIntoPlatesWithNoLonLat < $totalPlateCount ) {
        $indexIntoPlatesWithNoLonLat++;
    }

    say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";

    #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub previousZeroButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #     #Get info about the airport we're currently pointing to
    #     my $_row = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );
    #
    #     my ( $PDF_NAME, $FAA_CODE, $CHART_NAME, $Difference ) = @$_row;
    my $totalPlateCount = scalar @{$_plateWithNoLonLat};
    say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";

    #Info about current plate
    my $rowRef = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    if ( $indexIntoPlatesWithNoLonLat > 0 ) {
        $indexIntoPlatesWithNoLonLat--;
    }
    say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";

    #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub nextBadButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #Get info about the airport we're currently pointing to
    my $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );

    my $totalPlateCount = scalar @{$_platesMarkedBad};

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    #BUG TODO Make length of array
    if ( $indexIntoPlatesMarkedBad < $totalPlateCount ) {
        $indexIntoPlatesMarkedBad++;
    }

    say "$indexIntoPlatesMarkedBad / $totalPlateCount";

    #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub previousBadButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #     #Get info about the airport we're currently pointing to
    #     my $_row = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );
    #
    #     my ( $PDF_NAME, $FAA_CODE, $CHART_NAME, $Difference ) = @$_row;

    my $rowRef = ( @$_platesMarkedBad[$indexIntoPlatesMarkedBad] );

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    if ( $indexIntoPlatesMarkedBad > 0 ) {
        $indexIntoPlatesMarkedBad--;
    }
    say $indexIntoPlatesMarkedBad;

    #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub nextChangedButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #Get info about the airport we're currently pointing to
    my $rowRef = ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );

    my $totalPlateCount = scalar @{$_platesMarkedChanged};

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    #BUG TODO Make length of array
    if ( $indexIntoPlatesMarkedChanged < $totalPlateCount ) {
        $indexIntoPlatesMarkedChanged++;
    }

    say "$indexIntoPlatesMarkedChanged / $totalPlateCount";

    #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub previousChangedButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #     #Get info about the airport we're currently pointing to
    #     my $_row = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );
    #
    #     my ( $PDF_NAME, $FAA_CODE, $CHART_NAME, $Difference ) = @$_row;

    my $rowRef = ( @$_platesMarkedChanged[$indexIntoPlatesMarkedChanged] );

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);

    if ( $indexIntoPlatesMarkedChanged > 0 ) {
        $indexIntoPlatesMarkedChanged--;
    }
    say $indexIntoPlatesMarkedChanged;

    #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub addGcpButtonClick {
    my ( $widget, $event ) = @_;

    say "Name: $main::currentGcpName";
    say "Longitude: $main::currentGcpLon";
    say "Latitude: $main::currentGcpLat";
    say "PngX: $main::currentGcpPngX";
    say "PngY: $main::currentGcpPngY";

    my $lstore = $main::gcpModel;

    my $iter = $lstore->append();

    #         say $hashRef->{$item}{Name};
    #         say $hashRef->{$item}{Type};
    #         get length of key
    #         split in two
    # say length $item;

    $lstore->set(
        $iter,                 0, $main::currentGcpName, 1,
        $main::currentGcpLon,  2, $main::currentGcpLat,  3,
        "0",                   4, "0",                   5,
        $main::currentGcpPngX, 6, $main::currentGcpPngY
    );

    return TRUE;
}

sub activateNewPlate {

    #Stuff we want to update every time we go to a new plate

    #Validate and set input parameters to this function
    #$rowRef is array reference to data about plate we're displaying
    my ($rowRef) = validate_pos(
        @_,
        { type => ARRAYREF },

    );

    our (
        $PDF_NAME,     $FAA_CODE,     $CHART_NAME,    $Difference,
        $upperLeftLon, $upperLeftLat, $lowerRightLon, $lowerRightLat,
        $xMed,         $yMed,         $xPixelSkew,    $yPixelSkew
    ) = @$rowRef;

    #FQN of the PDF for this chart
    my $targetPdf = $dtppDirectory . $PDF_NAME;

    #Pull out the various filename components of the input file from the command line
    my ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

    our $targetPng     = $dir . $filename . ".png";
    our $storedGcpHash = $dir . "gcp-" . $filename . "-hash.txt";

    $statistics{'$targetPdf'} = $targetPdf;

    #Pull all text out of the PDF
    #     my @pdftotext;
    #     @pdftotext = qx(pdftotext $targetPdf  -enc ASCII7 -);
    #     my $retval = $? >> 8;
    #
    #     if ( @pdftotext eq "" || $retval != 0 ) {
    #         say
    #           "No output from pdftotext.  Is it installed?  Return code was $retval";
    #     }
    #     $statistics{'$pdftotext'} = scalar(@pdftotext);

    #Convert the PDF to a PNG if one doesn't already exist
    convertPdfToPng( $targetPdf, $targetPng );

    #Pull airport lon/lat from database
    ( $main::airportLatitudeDec, $main::airportLongitudeDec ) =
      findAirportLatitudeAndLongitude($FAA_CODE);

    #---------------------------------------------------------------------------------------
    #Look up runways for this airport from the database
    our $runwaysFromDatabaseHashref = findRunwaysInDatabase($FAA_CODE);

    #    '0220' => {
    #                       'HEHeading' => '218',
    #                       'HELatitude' => '64.8222956666667',
    #                       'HELongitude' => '-147.835075416667',
    #                       'LEHeading' => '038',
    #                       'LELatitude' => '64.8160556111111',
    #                       'LELongitude' => '-147.8465555'
    #                     },

    #     print Dumper($runwaysFromDatabaseHashref);

    #Testing adding liststore programmmatically to partially glade-built interface
    # Create TreeModel
    my $runwayModel = create_model_runways($runwaysFromDatabaseHashref);

    # Create a TreeView
    my $runwayTreeview = Gtk3::TreeView->new($runwayModel);
    $runwayTreeview->set_rules_hint(TRUE);
    $runwayTreeview->set_search_column(0);
    $runwayTreeview->signal_connect( row_activated => sub { Gtk3->main_quit } );

    $runwayTreeview->get_selection->signal_connect(
        changed => sub {
            my ($selection) = @_;
            my ( $model, $iter ) = $selection->get_selected;
            $main::currentGcpName = $model->get_value( $iter, 0 );
            $main::currentGcpLon  = $model->get_value( $iter, 1 );
            $main::currentGcpLat  = $model->get_value( $iter, 2 );
            if ($iter) {

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

    $navaidTreeview->get_selection->signal_connect(
        changed => sub {
            my ($selection) = @_;
            my ( $model, $iter ) = $selection->get_selected;
            $main::currentGcpName = $model->get_value( $iter, 0 );
            $main::currentGcpLon  = $model->get_value( $iter, 2 );
            $main::currentGcpLat  = $model->get_value( $iter, 3 );
            if ($iter) {

                $selection->get_tree_view->scroll_to_cell(
                    $model->get_path($iter),
                    undef, FALSE, 0.0, 0.0 );

                #     $treeview->scroll_to_cell ($path, $column=undef, $use_align=FALSE, $row_align=0.0, $col_align=0.0);

            }
        }
    );

    #Delete all existing children for the tab box
    foreach my $child ( $main::navaidBox->get_children ) {
        $main::navaidBox->remove($child);    # remove all the children
    }

    $main::navaidBox->add($navaidTreeview);

    # Add columns to TreeView
    add_columns($navaidTreeview);
    $main::navaidBox->show_all();

    #---------------------------------------------------

    #Find fixes near the airport
    our $fixes_from_db_hashref =
      findFixesNearAirport( $main::airportLongitudeDec,
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

    #Auto-scroll to selected row
    $fixesTreeview->get_selection->signal_connect(
        changed => sub {
            my ($selection) = @_;
            my ( $model, $iter ) = $selection->get_selected;
            if ($iter) {
                $main::currentGcpName = $model->get_value( $iter, 0 );
                $main::currentGcpLon  = $model->get_value( $iter, 2 );
                $main::currentGcpLat  = $model->get_value( $iter, 3 );
                $selection->get_tree_view->scroll_to_cell(
                    $model->get_path($iter),
                    undef, TRUE, 0.5, 0.5 );

                #     $treeview->scroll_to_cell ($path, $column=undef, $use_align=FALSE, $row_align=0.0, $col_align=0.0);

            }
        }
    );

    #Delete all existing children for the tab box
    foreach my $child ( $main::fixesBox->get_children ) {
        $main::fixesBox->remove($child);    # remove all the children
    }

    $main::fixesBox->add($fixesTreeview);

    # Add columns to TreeView
    add_columns($fixesTreeview);
    $main::fixesBox->show_all();

    #---------------------------------------------------
    #Find obstacles near the airport
    #Find all unique obstacles near airport
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

    #     $fixesTreeview->signal_connect( row_activated => sub { Gtk3->main_quit } );

    #Delete all existing children for the tab box
    foreach my $child ( $main::obstaclesBox->get_children ) {
        $main::obstaclesBox->remove($child);    # remove all the children
    }

    $main::obstaclesBox->add($obstaclesTreeview);

    # Add columns to TreeView
    add_columns_runways($obstaclesTreeview);
    $main::obstaclesBox->show_all();

    #     #Find GPS waypoints near the airport
    #     our $gpswaypoints_from_db_hashref =
    #       findGpsWaypointsNearAirport( $main::airportLongitudeDec,
    #         $main::airportLatitudeDec );
    #     print Dumper($gpswaypoints_from_db_hashref);

    #--------------------------------------------------------------------------
    #Populate the GCP box from stored GCP hash
    if ( -e $storedGcpHash ) {
        say "Loading existing hash table $storedGcpHash";
        our $gcp_from_db_hashref = retrieve($storedGcpHash);

#         print Dumper($gcp_from_db_hashref);

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
        my $gcpTreeview = Gtk3::TreeView->new($gcpModel);
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
        $main::gcpBox->show_all();
    }

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

    #No scaling
    $main::pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($targetPng);

    #     $main::plate->set_from_pixbuf($main::pixbuf);

    #Hardcoded scaling
    #     my $scaled = $main::pixbuf->scale_simple(400, 400, 'GDK_INTERP_HYPER');
    #     $main::plate->set_from_pixbuf($scaled);

    #Dynamic scaling
    our $scaledPlate = load_image( $targetPng, $main::plateSw );
    $main::plate->set_from_pixbuf($scaledPlate);

    my $originalImageWidth  = $main::pixbuf->get_width();
    my $originalImageHeight = $main::pixbuf->get_height();
    my $scaledImageWidth    = $main::scaledPlate->get_width();
    my $scaledImageHeight   = $main::scaledPlate->get_height();

    my $horizontalScaleFactor = $originalImageWidth / $scaledImageWidth;
    my $verticalScaleFactor   = $originalImageHeight / $scaledImageHeight;

    #adjust the scale factors per the ratio of the image to the actual window
    #      say "------";
    #      say $xMed;
    #      say "$originalImageWidth -> $scaledImageWidth";
    #       say "$originalImageHeight -> $scaledImageHeight";

    #     $xMed = $xMed * ($scaledImageWidth / $originalImageWidth);
    $xMed = $xMed * $horizontalScaleFactor;
$xPixelSkew = $xPixelSkew * $horizontalScaleFactor;
    #     say $xMed;
    #     $yMed = $yMed * ($scaledImageHeight / $originalImageHeight);
    $yMed = $yMed * $verticalScaleFactor;
$yPixelSkew = $yPixelSkew * $verticalScaleFactor;
    #     say "------";
    say
      " $xMed, $xPixelSkew, $yPixelSkew,  $yMed, $upperLeftLon, $upperLeftLat";

    #Set up the affine transformations
    #y sizes have to be negative
    if ( $yMed > 0 ) { $yMed = -($yMed); }
    our ( $AffineTransform, $invertedAffineTransform );

    #Make our basic parameters are defined before trying to create the transforms
    if ( $xMed && $yMed && $upperLeftLon && $upperLeftLat ) {
        $AffineTransform = Geometry::AffineTransform->new(
            m11 => $xMed,
            m12 => $yPixelSkew,
            m21 => $xPixelSkew,
            m22 => $yMed,
            tx  => $upperLeftLon,
            ty  => $upperLeftLat
        );
        $invertedAffineTransform = $AffineTransform->clone()->invert();
    }

    #     say "Affine";
    #     my ( $x, $y ) = $AffineTransform->transform( 0, 0 );
    #     say "$x $y";
    #
    #     say "Inverse Affine";
    #
    #     my ( $x1, $y1 ) = $invertedAffineTransform->transform( $x, $y );
    #     say "$x1 $y1";

    #Connect this signal to draw features over the plate
    $main::plate->signal_connect_after( draw => \&cairo_draw );

    if ( $upperLeftLon && $upperLeftLat && $lowerRightLon && $lowerRightLat ) {
        say
          "$upperLeftLon && $upperLeftLat && $lowerRightLon && $lowerRightLat";

        #         drawFeaturesOnPlate();
        #
        #         my ( $pixmap, $mask ) = $main::pixbuf->render_pixmap_and_mask();
        #         my $cm  = $pixmap->get_colormap();
        #         my $red = $cm->alloc_color('red');
        #         my $gc  = $pixmap->new_gc( $red );
        #         $pixmap->draw_rectangle( $gc, "False", 0, 0, 400, 100 );
        #         $main::plate->set_from_pixmap( $pixmap, $mask );
    }
    return;
}

sub load_image {
    my ( $file, $parent ) = @_;
    my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($file);
    my $scaled = scale_pixbuf( $pixbuf, $parent );
    return $scaled;
}

sub scale_pixbuf {
    my ( $pixbuf, $parent ) = @_;
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

sub drawFeaturesOnPlate {

    return;
}

# sub add_columns {
#     my $treeview = shift;
#     my $model    = $treeview->get_model();
#
#     # Column for fixed toggles
#     my $renderer = Gtk3::CellRendererToggle->new;
#     $renderer->signal_connect(
#         toggled => \&fixed_toggled,
#         $model
#     );
#     my $column =
#       Gtk3::TreeViewColumn->new_with_attributes( 'Fixed', $renderer,
#         active => COLUMN_FIXED );
#
#     # Set this column to a fixed sizing (of 50 pixels)
#     $column->set_sizing('fixed');
#     $column->set_fixed_width(50);
#     $treeview->append_column($column);
#
#     # Column for bug numbers
#     $renderer = Gtk3::CellRendererText->new;
#     $column =
#       Gtk3::TreeViewColumn->new_with_attributes( 'Bug number', $renderer,
#         text => COLUMN_NUMBER );
#     $column->set_sort_column_id(COLUMN_NUMBER);
#     $treeview->append_column($column);
#
#     # Column for severities
#     $column =
#       Gtk3::TreeViewColumn->new_with_attributes( 'Severity', $renderer,
#         text => COLUMN_SEVERITY );
#     $column->set_sort_column_id(COLUMN_SEVERITY);
#     $treeview->append_column($column);
#
#     # Column for description
#     $column =
#       Gtk3::TreeViewColumn->new_with_attributes( 'Description', $renderer,
#         text => COLUMN_DESCRIPTION );
#     $column->set_sort_column_id(COLUMN_DESCRIPTION);
#     $treeview->append_column($column);
# }

# sub create_model {
#     my $lstore =
#       Gtk3::ListStore->new( 'Glib::Boolean', 'Glib::Uint', 'Glib::String',
#         'Glib::String', );
#     for my $item (@main::data) {
#         my $iter = $lstore->append();
#         $lstore->set(
#             $iter,
#             COLUMN_FIXED,            $item->{fixed},
#             COLUMN_NUMBER,            $item->{number},
#             COLUMN_SEVERITY,            $item->{severity},
#             COLUMN_DESCRIPTION,            $item->{description}
#         );
#     }
#     return $lstore;
# }
sub add_columns {

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
    for my $item ( keys $hashRef ) {
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
    for my $item ( keys $hashRef ) {
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

    #           'fix-COATT-0.335522331285691' => {
    #                                              'lat' => '37.9582805555556',
    #                                              'lon' => '-77.5768027777778',
    #                                              'pdfx' => '135.945',
    #                                              'pdfy' => '467.38',
    #                                              'pngx' => '566.613139534884',
    #                                              'pngy' => '527.583333333333'
    #                                            },

    #Define our listStore
    my $lstore = Gtk3::ListStore->new(
        'Glib::String', 'Glib::Double', 'Glib::Double', 'Glib::Double',
        'Glib::Double', 'Glib::Double', 'Glib::Double'
    );

    #Populate the data for the list store from the hashRef
    for my $item ( keys $hashRef ) {
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
  gcpListstoreToHash();
  
#     #----------------------------------------------------------------------------------------------------------------------------------------------------
#     #Now some math
#     our ( @xScaleAvg, @yScaleAvg, @ulXAvg, @ulYAvg, @lrXAvg, @lrYAvg ) = ();
# 
#     our ( $xAvg,    $xMedian,   $xStdDev )   = 0;
#     our ( $yAvg,    $yMedian,   $yStdDev )   = 0;
#     our ( $ulXAvrg, $ulXmedian, $ulXStdDev ) = 0;
#     our ( $ulYAvrg, $ulYmedian, $ulYStdDev ) = 0;
#     our ( $lrXAvrg, $lrXmedian, $lrXStdDev ) = 0;
#     our ( $lrYAvrg, $lrYmedian, $lrYStdDev ) = 0;
#     our ($lonLatRatio) = 0;
# 
#     calculateRoughRealWorldExtentsOfRaster($main::gcp_from_db_hashref);
# 
#     #
# 
#     #
#     #         #Smooth out the X and Y scales we previously calculated
#     calculateSmoothedRealWorldExtentsOfRaster();
#     #
#     #         #Actually produce the georeferencing data via GDAL
#     georeferenceTheRaster();
#     #
#     #         #Count of entries in this array
#     #         my $xScaleAvgSize = 0 + @xScaleAvg;
#     #
#     #         #Count of entries in this array
#     #         my $yScaleAvgSize = 0 + @yScaleAvg;
#     #
#     #         say "xScaleAvgSize: $xScaleAvgSize, yScaleAvgSize: $yScaleAvgSize";
#     #
#     #         #Save statistics
#     #         $statistics{'$xAvg'}          = $xAvg;
#     #         $statistics{'$xMedian'}       = $xMedian;
#     #         $statistics{'$xScaleAvgSize'} = $xScaleAvgSize;
#     #         $statistics{'$yAvg'}          = $yAvg;
#     #         $statistics{'$yMedian'}       = $yMedian;
#     #         $statistics{'$yScaleAvgSize'} = $yScaleAvgSize;
#     #         $statistics{'$lonLatRatio'}   = $lonLatRatio;
#     #

}
sub updateStatus {
  my ($_status, $_PDF_NAME) = validate_pos(
        @_,
        { type => SCALAR },
        { type => SCALAR },
        );
    #Update the georef table
    my $update_dtpp_geo_record =
        "UPDATE dtppGeo " 
      . "SET "
      . "status = ? "
      . "WHERE "
      . "PDF_NAME = ?";

    my $dtppSth = $dtppDbh->prepare($update_dtpp_geo_record);

   
    $dtppSth->bind_param( 1, $_status );
    $dtppSth->bind_param( 2, $_PDF_NAME );

    say "$_status, $_PDF_NAME";
    $dtppSth->execute();

    #Uncomment here to write to .CSV file
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
sub markGoodButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #     #Get info about the airport we're currently pointing to
    #     my $_row = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );
    #
    #     my ( $PDF_NAME, $FAA_CODE, $CHART_NAME, $Difference ) = @$_row;
    updateStatus ("MANUALGOOD", $main::PDF_NAME);
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
#     #     say @$_plateWithNoLonLat;
    my $totalPlateCount = scalar @{$_plateWithNoLonLat};

    #BUG TODO Make length of array
    if ( $indexIntoPlatesWithNoLonLat < $totalPlateCount ) {
        $indexIntoPlatesWithNoLonLat++;
    }

    say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
    
    #Get info about the airport we're currently pointing to
    my $rowRef = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);



    #     say @$_plateWithNoLonLat;


    return TRUE;
}
sub markBadButtonClick {
    my ( $widget, $event ) = @_;

    #     foreach my $_row (@$_allPlates) {
    #
    #     my (
    #         $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    #         $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    #         $MILITARY_USE, $COPTER_USE,  $STATE_ID
    #     ) = @$_row;
    #

    #     #Get info about the airport we're currently pointing to
    #     my $_row = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );
    #
    #     my ( $PDF_NAME, $FAA_CODE, $CHART_NAME, $Difference ) = @$_row;
    updateStatus ("MANUALBAD", $main::PDF_NAME);
    my $totalPlateCount = scalar @{$_plateWithNoLonLat};

    #BUG TODO Make length of array
    if ( $indexIntoPlatesWithNoLonLat < $totalPlateCount ) {
        $indexIntoPlatesWithNoLonLat++;
        
    }

    say "$indexIntoPlatesWithNoLonLat / $totalPlateCount";
    
    #Get info about the airport we're currently pointing to
    my $rowRef = ( @$_plateWithNoLonLat[$indexIntoPlatesWithNoLonLat] );

    #Update information for the plate we're getting ready to display
    activateNewPlate($rowRef);
    
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
#     #     say @$_plateWithNoLonLat;

    return TRUE;
}

sub coordinateToDecimalCifpFormat {

    #Convert a latitude or longitude in CIFP format to its decimal equivalent
    my ($coordinate)= validate_pos(
        @_,
        { type => SCALAR },
        );
        
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

sub gcpListstoreToHash {
 #create a new hash from the current GCP liststore
  my $model = $main::gcpModel;
  my %newGcpHash;
  #   my $iter = $lstore->append();
  $model->foreach(\&gcpTest, \%newGcpHash);
  print Dumper \%newGcpHash;
  my $gcpstring = createGcpString(\%newGcpHash);
  georeferenceTheRaster();
  
#   #Save the hash back to disk
#   store(\%newGcpHash, $main::storedGcpHash);
  }
  
sub gcpTest {
    my ($model, $path, $iter, $user_data)= validate_pos(
        @_,
        { type => HASHREF },
        { type => SCALARREF },
        { type => SCALARREF },
        { type => HASHREF | UNDEF },
        );
        my $key = $model->get_value( $iter, 0 );
        $user_data->{$key}{lon} = $model->get_value( $iter, 1 );
        $user_data->{$key}{lat} = $model->get_value( $iter, 2 );
        $user_data->{$key}{pdfx} = $model->get_value( $iter, 3 );
        $user_data->{$key}{pdfy} = $model->get_value( $iter, 4 );
        $user_data->{$key}{pngx} = $model->get_value( $iter, 5 );
        $user_data->{$key}{pngy} = $model->get_value( $iter, 6 );
        
        
say $model->get_value( $iter, 0 );
say $model->get_value( $iter, 1 );
say $model->get_value( $iter, 2 );
return FALSE;
}

sub createGcpString {
my ($gcpHashRef)= validate_pos(
        @_,
        { type => HASHREF },
        );
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
my ($gcpstring)= validate_pos(
        @_,
        { type => SCALAR },
        );
    # #Try to georeference
# You may be able to create the world files but you will need to know the pixel resolution and calculate the skew. Your world file should be named exactly the same as the image, but with a different exstention (.wld or .jpgw) and have the following lines:
# 
#     pixel resolution * cos(rotation angle)
#     -pixel resolution * sin(rotation angle)
#     -pixel resolution * sin(rotation angle)
#     -pixel resolution * cos(rotation angle)
#     upper left x
#     upper left y

    
    my $gdal_translateCommand =
      "gdal_translate -q -of VRT -strict -a_srs EPSG:4326 $gcpstring '$main::targetpng'  '$main::targetvrt'";
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
          $statistics{'$status'} = "AUTOBAD";
        touchFile($main::failFile);

        # say "Touching $main::failFile";
        # open( my $fh, ">", "$main::failFile" )
        # or die "cannot open > $main::failFile $!";
        # close($fh);
        return (1);
    }
    say $gdal_translateoutput if $debug;

    #Run gdalwarp

    my $gdalwarpCommand =
      "gdalwarp -q -of VRT -t_srs EPSG:4326 -order 1 -overwrite ''$main::targetvrt''  '$main::targetvrt2'";
    if ($debug) {
        say $gdalwarpCommand;
        say "";
    }

    my $gdalwarpCommandOutput = qx($gdalwarpCommand);

    $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gdalwarp.  Is it installed? Return code was $retval";
        ++$main::failCount;
        touchFile($main::failFile);
        $statistics{'$status'} = "AUTOBAD";
        return (1);
    }

    say $gdalwarpCommandOutput if $debug;

    #Run gdalinfo

    my $gdalinfoCommand = "gdalinfo '$main::targetvrt2'";
    if ($debug) {
        say $gdalinfoCommand;
        say "";
    }

    my $gdalinfoCommandOutput = qx($gdalinfoCommand);

    $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gdalinfo.  Is it installed? Return code was $retval";
          $statistics{'$status'} = "AUTOBAD";
        return;
    }
    say $gdalinfoCommandOutput if $debug;

    #Extract georeference info from gdalinfo output (some of this will be overwritten below)
    my (
        $pixelSizeX,    $pixelSizeY,    $upperLeftLon, $upperLeftLat,
        $lowerRightLon, $lowerRightLat, $lonLatRatio
    ) = extractGeoreferenceInfo($gdalinfoCommandOutput);

   #---------------------
  my $gdalinfoCommand = "gcps2wld.py '$main::targetvrt'";
    if ($debug) {
        say $gdalinfoCommand;
        say "";
    }

    my $gdalinfoCommandOutput = qx($gdalinfoCommand);

    $retval = $? >> 8;

    if ( $retval != 0 ) {
        carp
          "Error executing gdalinfo.  Is it installed? Return code was $retval";
          $statistics{'$status'} = "AUTOBAD";
        return;
    }
    say $gdalinfoCommandOutput if $debug;
my ($xPixelSkew, $yPixelSkew);
    #Extract georeference info from gdalinfo output
     ($pixelSizeX,    $pixelSizeY,   $xPixelSkew, $yPixelSkew, $upperLeftLon, $upperLeftLat
        
    ) = extractGeoreferenceInfoGcps2Wld($gdalinfoCommandOutput); 


    #Save the info for writing out
    $statistics{'$yMedian'}       = $pixelSizeY;
    $statistics{'$xMedian'}       = $pixelSizeX;
    $statistics{'$lonLatRatio'}   = $lonLatRatio;
    $statistics{'$upperLeftLon'}  = $upperLeftLon;
    $statistics{'$upperLeftLat'}  = $upperLeftLat;
    $statistics{'$lowerRightLon'} = $lowerRightLon;
    $statistics{'$lowerRightLat'} = $lowerRightLat;
    $statistics{'$yPixelSkew'}       = $yPixelSkew;
    $statistics{'$xPixelSkew'}       = $xPixelSkew;

    my $lonDiff = $upperLeftLon - $lowerRightLon;
    my $latDiff = $upperLeftLat - $lowerRightLat;

    #Check that the lat and lon range of the image seem valid
    if (   $lonDiff > .2
        || $latDiff > .12 )
    {
        say "Bad latDiff ($latDiff) or lonDiff ($lonDiff), georeference failed";
        georeferenceFailed();
        $statistics{'$status'} = "AUTOBAD";
        return 1;
    }

    # lonDiff < .2
    # latDiff < .12

    # landscape
    # y = 0.00000005x4 - 0.00000172x3 + 0.00008560x2 + 0.00072247x + 0.65758002

    # portrait
    # y = 0.00091147x2 - 0.03659641x + 2.03248188

 
    $statistics{'$isPortraitOrientation'} = $main::isPortraitOrientation;

    #Check that the latLon ratio fo the image seems valid
    if ($main::isPortraitOrientation) {
        my $targetLonLatRatioPortrait =
          targetLonLatRatioPortrait($main::airportLatitudeDec);
         $statistics{'$targetLonLatRatio'} = $targetLonLatRatioPortrait;
        unless ( abs( $lonLatRatio - $targetLonLatRatioPortrait ) < .1 ) {
            say
              "Bad portrait lonLatRatio, georeference failed: Calculated: $lonLatRatio, expected: $targetLonLatRatioPortrait";
            $statistics{'$status'} = "AUTOBAD";
            georeferenceFailed();
            return 1;
        }
    }
    else {
        #valid landscape ratios are different}
        my $targetLonLatRatioLandscape =
          targetLonLatRatioLandscape($main::airportLatitudeDec);
    $statistics{'$targetLonLatRatio'} = $targetLonLatRatioLandscape;
    
        unless ( abs( $lonLatRatio - $targetLonLatRatioLandscape ) < .12 ) {
            say
              "Bad landscape lonLatRatio, georeference failed: Calculated: $lonLatRatio, expected: $targetLonLatRatioLandscape";
            $statistics{'$status'} = "AUTOBAD";
            georeferenceFailed();
            return 1;
        }

        # print Dumper ( \%statistics );
    }
    $statistics{'$status'} = "AUTOGOOD";
    say "Sucess!";
    ++$main::successCount;

    return 0;
}