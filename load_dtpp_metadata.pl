#!/usr/bin/perl

# Given the XML metafile for dtpp data, download charts and create a database
#/*
# * This program is free software: you can redistribute it and/or modify
# * it under the terms of the GNU General Public License as published by
# * the Free Software Foundation, either version 3 of the License, or
# * (at your option) any later version.
# *
# * This program is distributed in the hope that it will be useful,
# * but WITHOUT ANY WARRANTY; without even the implied warranty of
# * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# * GNU General Public License for more details.
# *
# * You should have received a copy of the GNU General Public License
# * along with this program.  If not, see <http://www.gnu.org/licenses/>.
# */
#
#Modified 2014 Jesse McGraw (<jlmcgraw@gmail.com>
# started from:
# * FlightIntel for Pilots
# *
# * Copyright 2012 Nadeem Hasan <nhasan@nadmm.com>
# *

use strict;
use warnings;

use File::Basename;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Carp;
use Getopt::Std;
use File::Path qw(make_path remove_tree);

#Allow use of locally installed libraries in conjunction with Carton
use FindBin '$Bin';
use lib "$FindBin::Bin/local/lib/perl5";

#Non-standard libraries
use Modern::Perl '2014';
use DBI;
use LWP::Simple;
use XML::Twig;
use Params::Validate qw(:all);

#Don't buffer stdout
local $| = 1;

my @links = ();

use vars qw/ %opt /;
my $arg_num = scalar @ARGV;

#Define the valid command line options
my $opt_string = 'dra:';

#This will fail if we receive an invalid option
unless ( getopts( "$opt_string", \%opt ) ) {
    usage();
    exit(1);
}

#We need at least two arguments
if ( $arg_num < 2 ) {
    usage();
    exit(1);
}

#Default to all airports for the SQL query
our $airportId = "";
if ( $opt{a} ) {
    #If something  provided on the command line use it instead
    $airportId = $opt{a};
    say "Supplied airport ID: Only $airportId will be processed!";
}

our $downloadAll = $opt{d};


my $BASE_DIR = shift @ARGV;
my $cycle    = shift @ARGV;

#We'll use this to check that our requested cycle matches what's in the catalog
our $requestedCycle = $cycle;

my $TPP_METADATA_FILE = "$BASE_DIR/dtpp-$cycle/d-TPP_Metafile.xml";

# #Where to download DTPPs to
my $dtppDownloadDir = "$BASE_DIR/dtpp-$cycle/";

#
# #Make the download directory if it doesn't already exist
# if ( !-e "$dtppDownloadDir" ) {
#     make_path("$dtppDownloadDir");
# }
#
# die "$dtppDownloadDir doesn't exist" if ( !-e $dtppDownloadDir );

#URL of the DTPP catalog


# my $dtpp_url =
# "http://aeronav.faa.gov/d-tpp/$cycle/xml_data/d-TPP_Metafile.xml";
# my $dtpp_url = "https://nfdc.faa.gov/webContent/dtpp/current.xml";

my ( $count, $downloadedCount, $deletedCount, $changedCount, $addedCount ) = (0) x 5;

my %countHash;

if ( -e $TPP_METADATA_FILE ) {
    say "Using existing local metafile: $TPP_METADATA_FILE";
}
else {
    print "Downloading the d-TPP metafile: " . $dtpp_url . "...";
    
    # my $ret = 200;
    my $ret = getstore( $dtpp_url, $TPP_METADATA_FILE );

    if ( $ret != 200 ) {
        die "Unable to download d-TPP metadata.";
    }
    print "done\n";

}

#The name of our database
my $dbfile = "$BASE_DIR/dtpp-$cycle.sqlite";
my $dbh =
  DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "", { RaiseError => 1 } );

# $dbh->do("PRAGMA page_size=4096");
$dbh->do("PRAGMA synchronous=OFF");

my $create_metadata_table  = "CREATE TABLE android_metadata ( locale TEXT );";
my $insert_metadata_record = "INSERT INTO android_metadata VALUES ( 'en_US' );";

$dbh->do("DROP TABLE IF EXISTS android_metadata");
$dbh->do($create_metadata_table);
$dbh->do($insert_metadata_record);

my $create_cycle_table =
    "CREATE TABLE cycle ("
  . "_id INTEGER PRIMARY KEY AUTOINCREMENT, "
  . "TPP_CYCLE TEXT, "
  . "FROM_DATE TEXT, "
  . "TO_DATE TEXT" . ")";

my $insert_cycle_record =
    "INSERT INTO cycle ("
  . "TPP_CYCLE, "
  . "FROM_DATE, "
  . "TO_DATE"
  . ") VALUES ("
  . "?, ?, ?" . ")";

#SQL statement to create the dtpp table
my $create_dtpp_table =
    "CREATE TABLE dtpp ("
  . "_id INTEGER PRIMARY KEY AUTOINCREMENT, "
  . "TPP_VOLUME TEXT, "
  . "FAA_CODE TEXT, "
  . "CHART_SEQ TEXT, "
  . "CHART_CODE TEXT, "
  . "CHART_NAME TEXT, "
  . "USER_ACTION TEXT, "
  . "PDF_NAME TEXT, "
  . "FAANFD18_CODE TEXT, "
  . "MILITARY_USE TEXT, "
  . "COPTER_USE TEXT,"
  . "STATE_ID TEXT" . ")";

#SQL statement to insert a record into dtpp table
my $insert_dtpp_record =
    "INSERT INTO dtpp ("
  . "TPP_VOLUME, "
  . "FAA_CODE, "
  . "CHART_SEQ, "
  . "CHART_CODE, "
  . "CHART_NAME, "
  . "USER_ACTION, "
  . "PDF_NAME, "
  . "FAANFD18_CODE, "
  . "MILITARY_USE, "
  . "COPTER_USE,"
  . "STATE_ID"
  . ") VALUES ("
  . "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?" . ")";

#SQL statement to create the dtppGeo table
my $create_dtpp_geo_table_sql = <<'END_SQL';
  CREATE TABLE dtppGeo (
     _id		   INTEGER PRIMARY KEY AUTOINCREMENT, 
     airportLatitude                                    TEXT, 
     horizontalAndVerticalLinesCount                    TEXT, 
     gcpCount                                           TEXT, 
     yMedian                                            TEXT, 
     gpsCount                                           TEXT, 
     targetPdf                                          TEXT, 
     yScaleAvgSize                                      TEXT, 
     airportLongitude                                   TEXT, 
     notToScaleIndicatorCount                           TEXT, 
     unique_obstacles_from_dbCount                      TEXT, 
     xScaleAvgSize                                      TEXT, 
     navaidCount                                        TEXT, 
     xMedian                                            TEXT, 
     insetCircleCount                                   TEXT, 
     obstacleCount                                      TEXT, 
     insetBoxCount                                      TEXT, 
     fixCount                                           TEXT, 
     yAvg                                               TEXT, 
     xAvg                                               TEXT, 
     pdftotext                                          TEXT, 
     lonLatRatio                                        TEXT, 
     upperLeftLon                                       TEXT, 
     upperLeftLat                                       TEXT, 
     lowerRightLon                                      TEXT, 
     lowerRightLat                                      TEXT, 
     targetLonLatRatio                                  TEXT, 
     runwayIconsCount                                   TEXT, 
     PDF_NAME                                           TEXT,
     isPortraitOrientation                              TEXT,
     xPixelSkew                                         TEXT,
     yPixelSkew                                         TEXT,
     status						TEXT
 )
END_SQL

my $insert_dtppGeo_record =
  "INSERT INTO dtppGeo (" . "PDF_NAME" . ") VALUES (" . "?" . ")";

$dbh->do("DROP TABLE IF EXISTS dtpp");
$dbh->do($create_dtpp_table);
$dbh->do("CREATE INDEX idx_dtpp_faa_code on dtpp ( FAA_CODE );");
my $sth_dtpp = $dbh->prepare($insert_dtpp_record);

$dbh->do("DROP TABLE IF EXISTS cycle");
$dbh->do($create_cycle_table);
my $sth_cycle = $dbh->prepare($insert_cycle_record);

$dbh->do("DROP TABLE IF EXISTS dtppGeo");
$dbh->do($create_dtpp_geo_table_sql);

my $sth_dtppGeo = $dbh->prepare($insert_dtppGeo_record);

my $twig = new XML::Twig(
    start_tag_handlers => {
        digital_tpp  => \&digital_tpp,
        state_code   => \&state_code,
        city_name    => \&city_name,
        airport_name => \&airport_name
    },
    twig_handlers => {
        record => \&record
    }
);

#Process the XML catalog
$twig->parsefile($TPP_METADATA_FILE);

# #Attempt to download the charts themselves in parallel
# # Max processes for parallel download
# my $pm = Parallel::ForkManager->new(8);

# foreach my $linkarray (@links) {
# $pm->start and next;    # do the fork

# my ( $link, $fn ) = @$linkarray;

# # if ( !-e ("$fn") ) {
# say "$link -> $fn";
# warn "Cannot get $fn from $link"
# if getstore( $link, $fn ) != RC_OK;
# # }

# $pm->finish;            # do the exit in the child process
# }
# $pm->wait_all_children;

print "\rDone loading $count records\n";

say "$downloadedCount charts downloaded";
say "$deletedCount charts deleted";
say "$changedCount charts changed";
say "$addedCount charts added";

print Dumper ( \%countHash );
exit;

my $from_date;
my $to_date;
my $volume;
my $state_id;
my $faa_code;
my $military_use;

sub digital_tpp {
    my ( $twig, $dtpp ) = @_;
    my $cycle     = $dtpp->{'att'}->{'cycle'};
    my $from_date = $dtpp->{'att'}->{'from_edate'};
    my $to_date   = $dtpp->{'att'}->{'to_edate'};

    die
      "Requested cycle ($main::requestedCycle) not equal to catalog cycle ($cycle)"
      unless $main::requestedCycle eq $cycle;

    #TPP_CYCLE
    $sth_cycle->bind_param( 1, $cycle );

    #FROM_DATE
    $sth_cycle->bind_param( 2, $from_date );

    #TO_DATE
    $sth_cycle->bind_param( 3, $to_date );

    $sth_cycle->execute;

    return 1;
}

sub city_name {
    my ( $twig, $city ) = @_;
    $volume = $city->{'att'}->{'volume'};
    return 1;
}

sub state_code {
    my ( $twig, $state ) = @_;
    $state_id = $state->{'att'}->{'ID'};
    return 1;
}

sub airport_name {
    my ( $twig, $apt ) = @_;
    $faa_code     = $apt->{'att'}->{'apt_ident'};
    $military_use = $apt->{'att'}->{'military'};
    return 1;
}

sub record {
    my ( $twig, $record ) = @_;
    my $chart_seq     = $record->child_text( 0, "chartseq" );
    my $chart_code    = $record->child_text( 0, "chart_code" );
    my $chart_name    = $record->child_text( 0, "chart_name" );
    my $user_action   = $record->child_text( 0, "useraction" );
    my $pdf_name      = $record->child_text( 0, "pdf_name" );
    my $faanfd18_code = $record->child_text( 0, "faanfd18" );
    my $copter_use    = $record->child_text( 0, "copter" );

    ++$count;

    if ( !( $airportId eq "" ) && $airportId ne $faa_code) {
        #say "Skipping airport $faa_code";
        return;
    }

    say "\rLoading # $count : $pdf_name: $chart_name";

    #TPP_VOLUME
    $sth_dtpp->bind_param( 1, $volume );

    #FAA_CODE
    $sth_dtpp->bind_param( 2, $faa_code );

    #CHART_SEQ
    $sth_dtpp->bind_param( 3, $chart_seq );

    #CHART_CODE
    $sth_dtpp->bind_param( 4, $chart_code );

    #CHART_NAME
    $sth_dtpp->bind_param( 5, $chart_name );

    #USER_ACTION
    #Remove spaces from user_action
    $user_action =~ s/\s+//g;
    $sth_dtpp->bind_param( 6, $user_action );

    #PDF_NAME
    $sth_dtpp->bind_param( 7, $pdf_name );

    #FAANFD18_CODE
    $sth_dtpp->bind_param( 8, $faanfd18_code );

    #MILITARY_USE
    $sth_dtpp->bind_param( 9, $military_use );

    #COPTER_USE
    $sth_dtpp->bind_param( 10, $copter_use );

    #STATE_ID
    $sth_dtpp->bind_param( 11, $state_id );
    $sth_dtpp->execute;

    #Populate the dtppGeo table
    $sth_dtppGeo->bind_param( 1, $pdf_name );
    $sth_dtppGeo->execute;

    #Keep a tally of chart types and actions
    $countHash{$chart_code}{$user_action}++;

    #We're only going to process IAPs or APDs, though all charts will be put in DB
    if ( !( $chart_code eq "APD" || $chart_code eq "IAP" ) ) { return; }

    if ( $user_action =~ /D/i ) {
        say "Deleting old " . "$dtppDownloadDir" . "$pdf_name";

        #deleteStaleFiles($pdf_name);
        ++$deletedCount;
    }

    my $doDownload = 0;
    if ( $user_action =~ /A/i ) {
        say "Added " . "$dtppDownloadDir" . "$pdf_name";

        #downloadPlate($pdf_name);

        ++$addedCount;
        $doDownload = 1

    }
    if ( $user_action =~ /C/i ) {

        #downloadPlate($pdf_name);
        ++$changedCount;
        $doDownload = 1;
    }

    if ($doDownload || $downloadAll) {
        downloadPlate($pdf_name);
    }
    #If the pdf doesn't exist locally fetch it
    #but don't bother trying to download DELETED charts
    if (  !( $pdf_name =~ /DELETED/i )
        && ( !-e ( "$dtppDownloadDir" . "$pdf_name" ) ) )
    {

        # #         say "Download $chart_url_base"
        # #           . "$pdf_name" . " -> "
        # #           . "$dtppDownloadDir"
        # #           . "$pdf_name";
        #
        # #         #Save the link in an array for downloading in parallel
        # #         push @links,
        # #           [ "$chart_url_base" . "$pdf_name", "$dtppDownloadDir" . "$pdf_name" ];

        # 	downloadPlate($pdf_name);
    }

    #FQN of the PDF for this chart
    my $targetPdf = $dtppDownloadDir . $pdf_name;

    #Pull out the various filename components of the input file from the command line
    my ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

    my $targetPng = $dtppDownloadDir . $filename . ".png";

    #     #Create the PNG for this chart if it doesn't already exist and it isn't a deleted chart
    if (   ( $chart_code eq "APD" || $chart_code eq "IAP" )
        && !-e $targetPng
        && ( $user_action =~ /[AC]/i ) )
    {

        #Convert the PDF to a PNG if one doesn't already exist
        say "Create PNG: $targetPdf -> $targetPng";
        convertPdfToPng( $targetPdf, $targetPng );
    }

    $twig->purge;

    return 1;
}

sub deleteStaleFiles {

    #Validate and set input parameters to this function
    my ($pdf_name) =
      validate_pos( @_, { type => SCALAR } );

    #First parameter is the name of the PDF (eg 00130RC.PDF)
    #     my $pdf_name       = shift @_;
    my $pdf_name_lower = $pdf_name;
    $pdf_name_lower =~ s/\.PDF/\.pdf/;

    #Pull out the various filename components of the input file from the command line
    my ( $filename, $dir, $ext ) = fileparse( $pdf_name, qr/\.[^.]*/x );

    my $targetPng = $dtppDownloadDir . $filename . ".png";

    # say "Deleting "
    # . $dtppDownloadDir
    # . $pdf_name
    # . " and "
    # . $dtppDownloadDir
    # . "outlines-"
    # . $pdf_name_lower
    # . " and $dtppDownloadDir"
    # . "outlines-"
    # . $pdf_name_lower
    # . ".png";

    #delete the old .pdf
    if ( -e ( "$dtppDownloadDir" . "$pdf_name" ) ) {
        say "Deleting " . $dtppDownloadDir . $pdf_name;
        unlink( "$dtppDownloadDir" . "$pdf_name" );
    }

    #delete the old .png
    if ( -e ($targetPng) ) {
        say "Deleting " . $targetPng;
        unlink($targetPng);
    }

    #delete the outlines .pdf
    if ( -e ( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower ) ) {
        say "Deleting " . $dtppDownloadDir . "outlines-" . $pdf_name_lower;
        unlink( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower );
    }

    #delete the outlines .png
    if ( -e ( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower . ".png" ) ) {
        say "Deleting $dtppDownloadDir"
          . "outlines-"
          . $pdf_name_lower . ".png";

        unlink( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower . ".png" );
    }

}

sub downloadPlate {

    #Validate and set input parameters to this function
    my ($pdf_name) =
      validate_pos( @_, { type => SCALAR } );

    #Download a chart if it doesn't already exist locally
    #First parameter is the name of the PDF (eg 00130RC.PDF)
    #     my $pdf_name       = shift @_;
    my $pdf_name_lower = $pdf_name;

    $pdf_name_lower =~ s/\.PDF/\.pdf/;

    #Pull out the various filename components of the input file from the command line
    my ( $filename, $dir, $ext ) = fileparse( $pdf_name, qr/\.[^.]*/x );

    #Where to download DTPPs from
    my $chart_url_base = "http://aeronav.faa.gov/d-tpp/$main::requestedCycle/";

    #Don't download if we already have it locally
    return if ( -e "$dtppDownloadDir" . "$pdf_name" );

    say "Download changed chart $chart_url_base"
      . "$pdf_name" . " -> "
      . "$dtppDownloadDir"
      . "$pdf_name";

    #Delete old files
    #         deleteStaleFiles($pdf_name);

    #         getPlate();
    #Get the new one

    #         $status = getstore(
    #             "$chart_url_base" . "$pdf_name",
    #             "$dtppDownloadDir" . "$pdf_name"
    #         );
    #         die "Error $status on $pdf_name" unless is_success($status);
    #
    #     until ( is_success($status) ) {
    say "Downloading "
      . $chart_url_base
      . $pdf_name
      . $dtppDownloadDir
      . $pdf_name;

    my $status = getstore( "$chart_url_base" . "$pdf_name",
        "$dtppDownloadDir" . "$pdf_name" );

    #     }

    ++$downloadedCount;

}

sub convertPdfToPng {

    #Validate and set input parameters to this function
    my ( $targetPdf, $targetPng ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    #DPI of the output PNG
    my $pngDpi = 300;

    #Convert the PDF to a PNG
    my $pdfToPpmOutput;

    #Return if the png already exists
    if ( -e $targetPng ) {
        return;
    }
    $pdfToPpmOutput = qx(pdftoppm -png -r $pngDpi $targetPdf > $targetPng);

    my $retval = $? >> 8;

    #Did we succeed?
    if ( $retval != 0 ) {

        #Delete the possibly bad png
        unlink $targetPng;
        carp "Error from pdftoppm.   Return code is $retval";
    }

    return $retval;
}

sub usage {
    say "At least specify base dir and cycle";
    say "eg: $0 . 1502";
    say "-d Download ALL plates (default is only added/new)";
    say "-r Rasterize ALL plates (default is only added/new)";
    say "-a<FAA airport ID>  To specify an airport ID";

}
