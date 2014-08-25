#!/usr/bin/perl

#/*
# * FlightIntel for Pilots
# *
# * Copyright 2012 Nadeem Hasan <nhasan@nadmm.com>
# *
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
#Modified 2014 Jesse McGraw (<lmcgraw@gmail.com>

use 5.010;

use strict;
use warnings;
use DBI;
use LWP::Simple;
use XML::Twig;
use Parallel::ForkManager;
my @links = ();

my $arg_num = scalar @ARGV;

#We need at least one argument (the name of the PDF to process)
if ( $arg_num < 2 ) {
    say "Specify base dir and cycle";
    say "eg: $0 . 1409";
    exit(1);
}

my $BASE_DIR          = shift @ARGV;
my $cycle             = shift @ARGV;
my $TPP_METADATA_FILE = "$BASE_DIR/d-TPP_Metafile.xml";

#Where to download DTPPs to
my $dtppDownloadDir = "$BASE_DIR/dtpp/";

die "$dtppDownloadDir doesn't exist" if ( !-e $dtppDownloadDir );

#URL of the DTPP catalog
# my $dtpp_url =
  # "http://aeronav.faa.gov/d-tpp/$cycle/xml_data/d-TPP_Metafile.xml";
my $dtpp_url =
  "https://nfdc.faa.gov/webContent/dtpp/current.xml";
  
#Where to download DTPPs from
my $chart_url_base = "http://aeronav.faa.gov/d-tpp/$cycle/";
my ( $count, $downloadedCount, $deletedCount, $changedCount ) = 0;

print "Downloading the d-TPP metafile: ".$dtpp_url."...";
my $ret = 200;
my $ret = getstore( $dtpp_url, $TPP_METADATA_FILE );
if ( $ret != 200 )
{
die "Unable to download d-TPP metadata.";
}
print "done\n";

#The name of our database
my $dbfile = "$BASE_DIR/dtpp.db";
my $dbh = DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "" );

$dbh->do("PRAGMA page_size=4096");
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
  . "?, ?, ?, ?, ?, ?, ?, ?, ?, ?,?" . ")";

# my $create_dtpp_geo_table =
# "CREATE TABLE dtppGeo ("
# . "_id INTEGER PRIMARY KEY AUTOINCREMENT, "
# . "airportLatitude TEXT, "
# . "horizontalAndVerticalLinesCount TEXT, "
# . "gcpCount TEXT, "
# . "yMedian TEXT, "
# . "gpsCount TEXT, "
# . "targetPdf TEXT, "
# . "yScaleAvgSize TEXT, "
# . "airportLongitude TEXT, "
# . "notToScaleIndicatorCount TEXT, "
# . "unique_obstacles_from_dbCount TEXT, "
# . "xScaleAvgSize TEXT, "
# . "navaidCount TEXT, "
# . "xMedian TEXT, "
# . "insetCircleCount TEXT, "
# . "obstacleCount TEXT, "
# . "insetBoxCount TEXT, "
# . "fixCount TEXT, "
# . "yAvg TEXT, "
# . "xAvg TEXT, "
# . "pdftotext TEXT, "
# . "lonLatRatio TEXT, "
# . "upperLeftLon TEXT, "
# . "upperLeftLat TEXT, "
# . "lowerRightLon TEXT, "
# . "lowerRightLat TEXT, "
# . "targetLonLatRatio TEXT, "
# . "runwayIconsCount TEXT, "
# . "PDF_NAME TEXT" . ")";

#Just trying another way of doing this
my $create_dtpp_geo_table_sql = <<'END_SQL';
  CREATE TABLE dtppGeo (
     _id                                                                INTEGER PRIMARY KEY AUTOINCREMENT, 
     airportLatitude                                       TEXT, 
     horizontalAndVerticalLinesCount    TEXT, 
     gcpCount                                                  TEXT, 
     yMedian                                                    TEXT, 
     gpsCount                                                  TEXT, 
     targetPdf                                                   TEXT, 
     yScaleAvgSize                                           TEXT, 
     airportLongitude                                     TEXT, 
     notToScaleIndicatorCount                   TEXT, 
     unique_obstacles_from_dbCount      TEXT, 
     xScaleAvgSize                                            TEXT, 
     navaidCount                                             TEXT, 
     xMedian                                                     TEXT, 
     insetCircleCount                                      TEXT, 
     obstacleCount                                         TEXT, 
     insetBoxCount                                         TEXT, 
     fixCount                                                     TEXT, 
     yAvg                                                             TEXT, 
     xAvg                                                             TEXT, 
     pdftotext                                                   TEXT, 
     lonLatRatio                                                TEXT, 
     upperLeftLon                                          TEXT, 
     upperLeftLat                                          TEXT, 
     lowerRightLon                                        TEXT, 
     lowerRightLat                                          TEXT, 
     targetLonLatRatio                                TEXT, 
     runwayIconsCount                              TEXT, 
     PDF_NAME                                              TEXT,
     isPortrait                                                  TEXT,
     xPixelSkew                                              TEXT,
     yPixelSkew                                              TEXT
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

    print "\rLoading # $count...";

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

    #If the pdf doesn't exist locally fetch it
    if ( !-e ( "$dtppDownloadDir" . "$pdf_name" ) ) {

        say "Download $chart_url_base"
          . "$pdf_name" . " -> "
          . "$dtppDownloadDir"
          . "$pdf_name";

        #Save the link in an array for downloading in parallel
        push @links,
          [ "$chart_url_base" . "$pdf_name", "$dtppDownloadDir" . "$pdf_name" ];

        getstore(
            "$chart_url_base" . "$pdf_name",
            "$dtppDownloadDir" . "$pdf_name"
        );
        ++$downloadedCount;
    }

    if ( $user_action =~ /D/i ) {
        say "Deleting " . "$dtppDownloadDir" . "$pdf_name";
        deleteStaleFiles($pdf_name);
        ++$deletedCount;
    }

    if ( $user_action =~ /C/i ) {
        say "Download changed chart $chart_url_base"
          . "$pdf_name" . " -> "
          . "$dtppDownloadDir"
          . "$pdf_name";
        deleteStaleFiles($pdf_name);
        getstore(
            "$chart_url_base" . "$pdf_name",
            "$dtppDownloadDir" . "$pdf_name"
        );

        ++$changedCount;
    }

    $twig->purge;
    ++$count;

    return 1;
}

sub deleteStaleFiles {
    my $pdf_name       = shift @_;
    my $pdf_name_lower = $pdf_name;
    $pdf_name_lower =~ s/\.PDF/\.pdf/;

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
    if ( -e ( "$dtppDownloadDir" . "$pdf_name" . "png" ) ) {
        say "Deleting " . $dtppDownloadDir . $pdf_name . "png";
        unlink( "$dtppDownloadDir" . "$pdf_name" . "png" );
    }

    #delete the outlines .pdf
    if ( -e ( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower ) ) {
        say "Deleting " . $dtppDownloadDir . "outlines-" . $pdf_name_lower;
        unlink( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower );
    }
    if ( -e ( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower . ".png" ) ) {
        say "Deleting $dtppDownloadDir"
          . "outlines-"
          . $pdf_name_lower . ".png";

        #delete the outlines .png
        unlink( "$dtppDownloadDir" . "outlines-" . $pdf_name_lower . ".png" );
    }

}
