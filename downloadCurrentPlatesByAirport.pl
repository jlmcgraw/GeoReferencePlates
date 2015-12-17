#!/usr/bin/perl

# Given the XML metafile for dtpp data, download charts
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
# * Copyright 2012 Nadeem Hasan <nhasan@nadmm.com>
# *

use 5.010;

use strict;
use warnings;

#Allow use of locally installed libraries in conjunction with Carton
use FindBin '$Bin';
use lib "$FindBin::Bin/local/lib/perl5";

use DBI;
use LWP::Simple;
use XML::Twig;

# use Parallel::ForkManager;
use File::Path qw(make_path remove_tree);
use Params::Validate qw(:all);
use File::Basename;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Carp;
use Getopt::Std;

#
my @links = ();

use vars qw/ %opt /;
my $arg_num = scalar @ARGV;

#Define the valid command line options
my $opt_string = 'r';

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

my $BASE_DIR = shift @ARGV;
my $cycle    = shift @ARGV;

#We'll use this to check that our requested cycle matches what's in the catalog
our $requestedCycle = $cycle;

#Where to download DTPPs to
my $dtppDownloadDir = "$BASE_DIR/platesByAirport-$cycle/";

#Where to download XML catalog to
my $TPP_METADATA_FILE = "$dtppDownloadDir/d-TPP_Metafile.xml";

#Make the download directory if it doesn't already exist
if ( !-e "$dtppDownloadDir" ) {
    make_path("$dtppDownloadDir");
}

die "$dtppDownloadDir doesn't exist" if ( !-e $dtppDownloadDir );

#URL of the DTPP catalog
# my $dtpp_url =
# "http://aeronav.faa.gov/d-tpp/$cycle/xml_data/d-TPP_Metafile.xml";
my $dtpp_url = "https://nfdc.faa.gov/webContent/dtpp/current.xml";

my ( $count, $downloadedCount, $deletedCount, $changedCount, $addedCount );

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

# This is commented out for now, no reason to overload the servers
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
    say $faa_code;
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

    say "\rLoading # $count...";

    #USER_ACTION
    #Remove spaces from user_action
    $user_action =~ s/\s+//g;

    #Keep a tally of chart types and actions
    $countHash{$chart_code}{$user_action}++;

    #Make the download directory if it doesn't already exist
    if ( !-e "$dtppDownloadDir" . "/" . $faa_code ) {
        make_path( "$dtppDownloadDir" . "/" . $faa_code );
    }

    #If the pdf doesn't exist locally fetch it
    #but don't bother trying to download DELETED charts
    if ( !( $pdf_name =~ /DELETED/i ) ) {

        #         #Save the link in an array for downloading in parallel
        #         push @links,
        #           [ "$chart_url_base" . "$pdf_name", "$dtppDownloadDir" . "$pdf_name" ];

        downloadPlate($pdf_name);
    }

    #Should we rasterize this PDF?
    if ( $opt{r} ) {

        #FQN of the PDF for this chart
        my $targetPdf = $dtppDownloadDir . $pdf_name;

        #Pull out the various filename components of the input file from the command line
        my ( $filename, $dir, $ext ) = fileparse( $targetPdf, qr/\.[^.]*/x );

        #Name of the png to create
        my $targetPng = $dtppDownloadDir . $filename . ".png";

        #Create the PNG for this chart if it doesn't already exist
        if ( !-e $targetPng ) {

            #Convert the PDF to a PNG if one doesn't already exist
            say "Create PNG: $targetPdf -> $targetPng";
            convertPdfToPng( $targetPdf, $targetPng );
        }
    }

    $twig->purge;

    return 1;
}

sub downloadPlate {

    #Download a chart if it doesn't already exist locally
    #Validate and set input parameters to this function
    #First parameter is the name of the PDF (eg 00130RC.PDF)
    my ($pdf_name) =
      validate_pos( @_, { type => SCALAR } );

    #     my $pdf_name       = shift @_;
    #     my $pdf_name_lower = $pdf_name =~ s/\.PDF/\.pdf/;

    #Pull out the various filename components of the input file from the command line
    my ( $filename, $dir, $ext ) = fileparse( $pdf_name, qr/\.[^.]*/x );

    #Where to download DTPPs from
    my $chart_url_base = "http://aeronav.faa.gov/d-tpp/$cycle/";

    #Do nothing if the chart already exists locally
    return
      if ( -e "$dtppDownloadDir" . "/" . $faa_code . "/" . "$pdf_name" );

    say "Download changed chart $chart_url_base"
      . "$pdf_name" . " -> "
      . "$dtppDownloadDir" . "/"
      . $faa_code . "/"
      . "$pdf_name";

    my $status;

    until ( is_success($status) ) {
        $status = getstore( "$chart_url_base" . "$pdf_name",
            "$dtppDownloadDir" . "/" . $faa_code . "/" . "$pdf_name" );
    }

    ++$downloadedCount;

}

sub convertPdfToPng {

    #Convert the PDF to a PNG

    #Validate and set input parameters to this function
    my ( $targetPdf, $targetPng ) =
      validate_pos( @_, { type => SCALAR }, { type => SCALAR }, );

    #DPI of the output PNG
    my $pngDpi = 300;

    #Return if the png already exists
    if ( -e $targetPng ) {
        return;
    }

    my $pdfToPpmOutput = qx(pdftoppm -png -r $pngDpi $targetPdf > $targetPng);

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
    say "You must at least specify base dir and requested cycle";
    say "eg: $0 . 1503";
    say "-r Rasterize plates to png";

}
