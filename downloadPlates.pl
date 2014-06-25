#!/usr/bin/perl
#This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Copyright 2012 Mike Stewart http://www.mstewart.net
#
# Modified 2014 by Jesse McGraw (jlmcgraw@gmail.com)

use v5.10;
use strict;
use warnings;

my $fileVer = "v4.3-jlm";    #this script version
use XML::XPath;
use XML::XPath::XMLParser;

use Time::Local;
use Getopt::Long;
use Socket;
use FindBin qw($Bin);

use LWP::Simple;

my $ip_address;
my $nacoaddr   = "aeronav.faa.gov";
my $xmlDataDir = "xml_data";

#obtain the NACO ip address
my $packed_ip = gethostbyname($nacoaddr);
if ( defined $packed_ip ) {
    $ip_address = inet_ntoa($packed_ip);
    print "$nacoaddr found at $ip_address\n";
}
else {
    die "unable to get the NACO IP address from $nacoaddr $!";
}
my $webServer = "http://$ip_address/d-tpp/";

my $procedureServer;
my $procedureDirectory;
my $procedureOriginalName;
my $procedureUrl       = "";
my $procedureLocalName = "";

my $tppIndex =
  "http://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/dtpp/";
my $xmlFile   = "d-TPP_Metafile.xml";
my $outputDir = "plates";

# Define wgetCmd here as null for global scoping, we'll set it below based on the Operating System
my $wgetCmd = "";

my $MySlash = "\\";    #thanks Matt
my $MyDash  = "-";

my $indexFile = "index.html";    #NACO index file to parse to get current cycle
my $filesize;

# setup my defaults
my $debug   = "no";
my $states  = "all";
my $volumes = "";
my $getmins = "no";
my $help    = 0;
my $destination;
my $forceupdate           = "no";
my $shouldDownloadSidStar = "no";
my $shouldDownloadHotspot = "no";
my $shouldDownloadLahso   = "no";
my $shouldDownloadDiagram = "no";

#my $startover="no";
my $longName     = "yes";
my $statefolders = "";      # for the option
my $statefolder  = "";      # for writing path
my $cityNameDir  = "";      # for writing path

my $desiredAirport = "";

my $os = $^O;               #return the OS name to work cross platform
print "Running in: $os\n";

# #sent to me by John Ewing to get his Mac OS X 10.5.7 working
# if ( $os =~ "darwin" ) {
# $wgetCmd = "curl --retry 8 --progress -v -o ";    # For Mac OS X
# }
# else {
# $wgetCmd =
# "wget";    # For Windows, et al.
# }

# if ( $os =~ "MSWin32" ) {
# $MySlash = "\\";                                    # For Windows
# }
# else {
$MySlash = "/";    # For other OS'

# }

GetOptions(
    'debug=s'                 => \$debug,
    'states=s'                => \$states,
    'volumes=s'               => \$volumes,
    'help!'                   => \$help,
    'destination=s'           => \$destination,
    'forceupdate=s'           => \$forceupdate,
    'getmins=s'               => \$getmins,
    'longfilenames=s'         => \$longName,
    'statefolders=s'          => \$statefolders,
    'shouldDownloadSidStar=s' => \$shouldDownloadSidStar,
    'shouldDownloadHotspot=s' => \$shouldDownloadHotspot,
    'shouldDownloadLahso=s'   => \$shouldDownloadLahso,
    'shouldDownloadDiagram=s' => \$shouldDownloadDiagram,

    # 'airport=s'	=> \$desiredAirport
) or die "Incorrect usage! Please read the instructions.txt\n";

if ($help) {
    print "Please see the instructions.txt file for usage\n";
    system("instructions.txt");
    exit();
}
if ( ( !defined($states) ) && ( !defined($volumes) ) ) {
    $states = "all";
    say "states set to = $states";
}
if ( defined($destination) ) {
    if ( !-e $destination ) {
        print "destination:$destination\n";
        mkdir($destination)
          || die "unable to make destination directory $destination  $!";

    }
    $outputDir = "$destination$MySlash$outputDir$MySlash";
    print "$outputDir\n";
}
else {
    $destination = $Bin;
    $outputDir   = "$destination$MySlash$outputDir$MySlash";
    print "output dir: $outputDir\n";
}

################################################################################
#   Main
################################################################################
say "$0 ver $fileVer starting";
my $iStartTime = (time);

say "Beginning Script at " . localtime(time);

#Get the plate XML calatog from the FAA NACO site
my $htmlcycle = GetCycleHTML();
say "HTML cycle = $htmlcycle";

if ( -e $xmlFile ) {
    say "We already have our d-TPP XML file, no need to download";
}
else {
    my $sourceFile =
      $webServer . $htmlcycle . $MySlash . $xmlDataDir . $MySlash . $xmlFile;
    my $outputFile = $xmlFile;
    say "Getting $sourceFile ->  $outputFile";

    #Get d-TPP file
    getstore( $sourceFile, $outputFile );

    die "Can't find XML plate catalog file \"$xmlFile\""
      unless -f $xmlFile;
}

if ( !-e $outputDir ) {
    mkdir($outputDir) || die "unable to make plates download directory:  $!";
}

#time to load the XML for the actual work effort
print "loading XML file. This could take a few minutes.\n";
print "Please stand by........\n";
my $xmlRef = XML::XPath->new( filename => $xmlFile );

# parse the xml doc
my $tppSet = $xmlRef->find('//digital_tpp')
  || die "couldn't find digital_tpp node:  $!";

#CheckXML ($tppSet);
my $iAirports          = 0;
my $iCharts            = 0;
my $iChanged           = 0;
my $iDeleted           = 0;
my $iDownloaded        = 0;
my $iMinCharts         = 0;
my $iAddedCharts       = 0;
my $iAirportDirCreated = 0;

#Here comes the parsing of the XML part
say "Starting to parse";

foreach my $tpp ( $tppSet->get_nodelist ) {
    my $xmlcycle = $tpp->find('@cycle');
    print "html cycle=$htmlcycle and xml cycle=$xmlcycle\n";
    if ( $htmlcycle =~
        $xmlcycle )    # just in case there is some problem with the cycles
    {
        print "HTML and XML cycles are the same\n";
    }
    else {
        print
          "html cycle:$htmlcycle does not equal xml cycle:$xmlcycle  . The XML CATALOG IS OUT OF DATE!!!!\n";
        print
          "I'm getting the files from cycle $htmlcycle but they are NOT CURRENT!\n";

        $xmlcycle = $htmlcycle;

        print "xmlcycle now is $xmlcycle\n";

        exit();
    }
    my $fromDate = $tpp->find('@from_edate');
    my $toDate   = $tpp->find('@to_edate');
    print "NACO XML cycle:  $xmlcycle\n";
    print "from:   $fromDate\n";
    print "to:     $toDate\n";

    my $stateList = $tpp->find('state_code');

    foreach my $state ( $stateList->get_nodelist ) {
        my $stateName = $state->find('@state_fullname')->string_value;
        my $stateID   = $state->find('@ID')->string_value;
        if ( $statefolders =~ "yes" ) {
            $statefolder = ( $stateName . $MySlash );

        }
        else {
            $statefolder = ("");
        }

        my $cityList = $state->find('city_name');

        foreach my $city ( $cityList->get_nodelist ) {
            my $cityName = $city->find('@ID')->string_value;

            # convert spaces, ., and slashes to dash
            $cityName =~ s/[ |\/|\\|\.]/-/g;
            if ( $statefolders =~ "yes" ) {

                #$statefolder = ($statefolder . $cityName .$MySlash);
                $cityNameDir = ( $cityName . $MySlash );
            }
            else {
                $cityNameDir = ("");
            }

            my $volumeID = $city->find('@volume')->string_value;

            #print "volumeID = $volumeID\n";
            #if (($states =~ m/$stateID/i) || ($getall=~"yes") || ($volumes =~m/$volumeID/i))
            my $airportList = $city->find('airport_name');
            foreach my $airport ( $airportList->get_nodelist ) {
                my $airportID = $airport->find('@apt_ident')->string_value;
                my $icaoID    = $airport->find('@icao_ident')->string_value;

                #next if (($desiredAirport ne "" )&& ($desiredAirport ne $airportID));
                $iAirports++;

                print "airport:  $airportID, $icaoID\n" if $debug =~ "yes";
                my $recordList = $airport->find('record');

                foreach my $record ( $recordList->get_nodelist ) {

                    $iCharts++;
                    my $chartCode = $record->find('chart_code');
                    my $chartName = $record->find('chart_name');

                    # convert spaces and slashes to dash
                    $chartName =~ s/[ |\/|\\]/-/g;

                    # remove parens
                    $chartName =~ s/[(|)]//g;

                    if ($longName) {
                        $chartName =
                          (     $stateID
                              . $MyDash
                              . $airportID
                              . $MyDash
                              . $chartName );
                        print "chartname:$chartName\n" if $debug =~ "yes";

                    }
                    my $pdfName    = $record->find('pdf_name');
                    my $useraction = $record->find('useraction');

                    # skip the takeoff minimum charts unless we specifically ask for them
                    if ( ( $chartCode =~ /^MIN$/ ) && ( $getmins =~ "no" ) ) {
                        $iMinCharts++;

                        print
                          "skipping min chart: $stateName $airportID  $chartName\n"
                          if $debug =~ "yes";
                        next;
                    }

                    #else {
                    if ( $useraction =~ /D/ ) {
                        $iDeleted++;

                        if (
                            -e (
                                    $outputDir
                                  . $statefolder
                                  . $cityNameDir
                                  . $airportID
                                  . $MySlash
                                  . $chartName . ".pdf"
                            )
                          )
                        {
                            unlink( $outputDir
                                  . $statefolder
                                  . $cityNameDir
                                  . $airportID
                                  . $MySlash
                                  . $chartName
                                  . ".pdf" )
                              || warn
                              "unable to delete old chart file:$outputDir$MySlash$airportID$MySlash$chartName.pdf  $!";
                            print
                              "$chartName existed and it was deleted based on the FAA catalog forcedupdate:$forceupdate\n";

                        }
                        next;
                    }

                    if (   ( $states =~ m/$stateID/i )
                        || ( $volumes =~ m/$volumeID/i )
                        || ( $states =~ "all" ) )
                    {
                        my $outputFile =
                            $outputDir
                          . $statefolder
                          . $cityNameDir
                          . $airportID
                          . $MySlash
                          . $chartName . ".pdf";
                        if (   ( $useraction =~ /[A|C]/ )
                            || ( $forceupdate =~ "yes" )
                            || ( !-e ($outputFile) ) )
                        {
                            if ( $useraction =~ /C/ ) {
                                $iChanged++;
                            }
                            if ( $useraction =~ /A/ ) {
                                $iAddedCharts++;
                            }

                            print
                              "$airportID, $chartName, $pdfName, changed?  $useraction\n";

                            # print MyLogFile"would have downloaded $airportID, $chartName, $pdfName, changed:$useraction \n"
                            # if $debug =~ "yes";
                            if (
                                !-e ( $outputDir . $statefolder . $airportID ) )
                            {
                                mkdir( $outputDir . $statefolder );
                                mkdir(
                                    $outputDir . $statefolder . $cityNameDir );
                                mkdir(  $outputDir
                                      . $statefolder
                                      . $cityNameDir
                                      . $airportID );
                                print("$outputDir$statefolder$airportID\n");
                                $iAirportDirCreated++;

                                #print MyLogFile "Airport dir created $outputDir$MySlash$airportID count:$iAirportDirCreated\n" if $debug=~"yes";
                            }

                            #$cmd = $wgetCmd . $MySlash . $outputFile . $MySlash . $webServer . $xmlcycle . $MySlash . $pdfName;
                            my $sourceFile =
                              $webServer . $xmlcycle . "/" . $pdfName;

                            if ( ( $debug =~ "yes" ) ) {
                                next;

                            }
                            $procedureLocalName =
                              "$outputDir" . "/" . "$pdfName";

                            # getstore( $sourceFile, $outputFile );
                            # die
                            # "Can't download plate $sourceFile to $outputFile"
                            # unless -f $outputFile;
                            say "$sourceFile->$outputFile";
                            $iDownloaded++;
                            $filesize = ( $filesize + ( -s "$outputFile" ) );

                        }
                    }

                    #}
                }
            }
        }
    }
}
my $iEndTime = (time);
my $RunTime  = ( $iEndTime - $iStartTime ) / 60;
$filesize = $filesize / 1024 / 1024;    #get to megabytes
print "\n\n";
print "airports processed:  		$iAirports\n";
print "charts available:    		$iCharts\n";
print "charts marked for changed:	$iChanged\n";
print "charts downloaded:   		$iDownloaded\n";
print "charts marked for delete:      	$iDeleted\n";
print "charts marked for add:      	$iAddedCharts\n";
print "Folders created for airports:	$iAirportDirCreated\n";
print "Mins charts skipped: 		$iMinCharts\n\n";
print "Your $iDownloaded charts were put in:		$outputDir\n";

print "Runtime was $RunTime minutes\n";
print
  "I have a few things to clean up first. Your command prompt should show up shortly\n";
print "Please stand by...\n";

exit 0;

#routine to get the cycle number from the FAA website
sub GetCycleHTML {

    #was having issues with sget replacing the file. Have to delete.
    if ( -e $indexFile ) {
        unlink($indexFile);

        #print "$indexFile\n";
    }

    #Get the html file containing cycle information
    getstore( $tppIndex, $indexFile );

    my $htmlcycle = "";

    open( INFILE, $indexFile ) || die "unable to open indexFile:  $!";
    while ( my $line = <INFILE> ) {

        #print "$line\n";
        if ( $line =~
            /<td><a href=\"http:\/\/aeronav.faa.gov\/\/digital_tpp.asp\?ver=(\d{4})/
          )
        {

            #Note that this will probably pick up the new cycle, even when it technically isn't active yet
            # print $line;
            $htmlcycle = $1;
        }
    }

    close(INFILE);
    return $htmlcycle;
}
