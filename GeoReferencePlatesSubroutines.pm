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
use Carp;

$VERSION = 1.00;
@ISA     = qw(Exporter);
@EXPORT =
  qw( rtrim ltrim coordinatetodecimal is_vhf onlyuniq uniq average stdev median same_sign is_between);

#@EXPORT_OK   = qw(  coordinatetodecimal );

my $debug = 0;

sub is_vhf($) {
    my $freq = shift;
    return 1
      if ( $freq =~ m/(1[1-3][0-9]\.\d{1,3})/ && ( $1 >= 118 && $1 < 137 ) );
    return 0;
}

sub coordinatetodecimal {
    my ($coordinate) = @_;
    my ( $deg, $min, $sec, $signeddegrees, $declination );

    #Remove any whitespace
    $coordinate =~ s/\s//g;

    $declination = substr( $coordinate, -1, 1 );

    return "" if !( $declination =~ /[NSEW]/ );

    $coordinate =~ m/^(\d{1,3})-/;

    #print $1;
    $deg = $1 / 1;

    $coordinate =~ m/-(\d{2})-/;

    #print $1;
    $min = $1 / 60;

    $coordinate =~ m/-(\d{2}\.\d+)/;

    #print $1;
    $sec = $1 / 3600;

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
    say "Coordinate: $coordinate to $signeddegrees"        if $debug;
    say "Deg: $deg, Min:$min, Sec:$sec, Decl:$declination" if $debug;
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

    #Remove all entries from an array that are duplicates (eg 1 2 3 2 2 -> 1 3)
    my %seen = ();
    my @r    = ();

    foreach my $a (@_) {
        $seen{$a} = 0;
    }

    foreach my $a (@_) {
        $seen{$a} = $seen{$a} + 1;
    }

    foreach my $key ( keys %seen ) {
        if ( $seen{$key} == 1 ) {
            push @r, $key;
        }
    }
    return @r;
}

sub average {
    my ($data) = @_;
    if ( not @$data ) {
        croak("Average: Empty array\n");

    }
    my $total = 0;
    foreach (@$data) {
        $total += $_;
    }
    my $average = $total / @$data;
    return $average;
}

sub stdev {
    my ($data) = @_;
    if ( @$data == 1 ) {
        return 0;
    }
    my $average = &average($data);
    my $sqtotal = 0;
    foreach (@$data) {
        $sqtotal += ( $average - $_ )**2;
    }
    my $std = ( $sqtotal / ( @$data - 1 ) )**0.5;
    return $std;
}

sub median {
    my ($data) = @_;
    my $median;
    my $mid           = int @$data / 2;
    my @sorted_values = sort by_number @$data;
    if ( @$data % 2 ) {
        $median = $sorted_values[$mid];
    }
    else {
        $median = ( $sorted_values[ $mid - 1 ] + $sorted_values[$mid] ) / 2;

    }
    return $median;
}

sub by_number {
    if    ( $a < $b ) { -1 }
    elsif ( $a > $b ) { 1 }
    else              { 0 }
}

sub same_sign {
    $_[0] * $_[1] > 0;

    # my ($x,$y) = @_;

    # if ( undef($x) or undef($y)) {
    # return 0;           # "undef" is never same-sign
    # }
    # if (   ( ($x >= 0) and ($y >= 0) )
    # or ( ($x <  0) and ($y <  0) ) )
    # {
    # return 1;
    # }
    # else
    # {
    # return 0;
    # }
}

sub is_between {
    my $lower = shift;
    my $upper = shift;
    my $num   = shift;
    return ( sort { $a <=> $b } $lower, $upper, $num )[1] == $num;
}
1;
