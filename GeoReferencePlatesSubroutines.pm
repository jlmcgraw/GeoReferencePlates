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
package GeoReferencePlatesSubroutines;

use 5.010;
use strict;
use warnings;

use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

$VERSION     = 1.00;
@ISA         = qw(Exporter);
@EXPORT      = qw( rtrim ltrim coordinatetodecimal is_vhf onlyuniq uniq);
#@EXPORT_OK   = qw(  coordinatetodecimal );

my $debug = 0;

sub is_vhf($) {
    my $freq = shift;
    return 1 if ($freq  =~ m/(1[1-3][0-9]\.\d{1,3})/ && ( $1 >= 118 && $1 < 137 ) );
    return 0;
}
sub coordinatetodecimal {
    my ($coordinate) = @_;
    my ( $deg, $min, $sec, $signeddegrees,$declination );
    #Remove any whitespace
   $coordinate =~ s/\s//g;
       
    $declination = substr($coordinate,-1,1);

    return "" if !( $declination =~ /[NSEW]/ );

      
    $coordinate =~ m/^(\d{1,3})-/;
    #print $1;
    $deg =  $1 / 1;
    $coordinate =~ m/-(\d{2})-/;
    #print $1;
    $min = $1 / 60;
    $coordinate =~ m/-(\d{2}\.\d+)/;
    #print $1;
    $sec = $1  / 3600;

    $signeddegrees = ( $deg + $min + $sec );
    
    
    
    if ( ( $declination eq "S" ) || ( $declination eq "W" ) ) {
        $signeddegrees = -($signeddegrees);
    }

    given ($declination) {
        when (/NS/) {
            #Latitude is invalid if less than -90  or greater than 90
            $signeddegrees = "" if ( abs($signeddegrees) > 90 );
        }
        when (/EW/) {
            #Longitude is invalid if less than -180 or greater than 180
            $signeddegrees = "" if ( abs($signeddegrees) > 180 );
        }
        default {
        }
      
    }
    print "Coordinate: $coordinate to $signeddegrees\n" if $debug;
    print "Deg: $deg, Min:$min, Sec:$sec, Decl:$declination\n" if $debug;
    return ($signeddegrees);
}

sub uniq {
#Remove duplicates from a hash, leaving only one entry (eg 1 2 3 2 2 -> 1 2 3)
    my %seen = ();
    my @r    = ();
    foreach my $a (@_) {
        unless ( $seen{$a} ) {
            push @r, $a;
            $seen{$a} = 1;
        }
    }
    return @r;
}

sub onlyuniq {
    #Remove all entries from a hash that are duplicates (eg 1 2 3 2 2 -> 1 3)
    my %seen = ();
    my @r    = ();
    foreach my $a (@_) {
        $seen{$a} = 0;
    }

    foreach my $a (@_) {
        $seen{$a} = $seen{$a} + 1;
    }

    foreach my $key ( sort keys %seen ) {
        if ( $seen{$key} == 1 ) {
            push @r, $key;
        }
    }
    return @r;
}


1;
