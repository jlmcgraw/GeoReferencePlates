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

use Math::Trig;
use Math::Trig qw(great_circle_distance deg2rad great_circle_direction rad2deg);

no if $] >= 5.018, warnings => "experimental";

$VERSION = 1.00;
@ISA     = qw(Exporter);
@EXPORT =
  qw( rtrim ltrim coordinatetodecimal is_vhf onlyuniq uniq average stdev median same_sign is_between
   targetLonLatRatio usage hashHasUnmatchedIcons trueHeading WGS84toGoogleBing slopeAngle NESW removeIconsAndTextboxesInMaskedAreas
   processMaskingFile drawFeaturesOnPdf);

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
sub targetLonLatRatio {
     my ($_airportLatitudeDec) = @_;
     #This equation comes from a polynomial regression analysis of longitudeToLatitudeRatio by airportLatitudeDec
                my $_targetLonLatRatio =
                  0.000000000065 * ( $_airportLatitudeDec**6 ) -
                  0.000000010206 * ( $_airportLatitudeDec**5 ) +
                  0.000000614793 * ( $_airportLatitudeDec**4 ) -
                  0.000014000833 * ( $_airportLatitudeDec**3 ) +
                  0.000124430097 * ( $_airportLatitudeDec**2 ) +
                  0.003297052219 * ($_airportLatitudeDec) + 0.618729977577;
        
        return $_targetLonLatRatio;

}
sub hashHasUnmatchedIcons {

    # Return true if the passed hash has icons that aren't matched

    my ($hashRefA) = @_;

    # say "hashHasUnmatchedIcons if $debug;

    foreach my $key ( sort keys %$hashRefA ) {

        if ( !$hashRefA->{$key}{"MatchedTo"} ) {
            return 1;
        }
    }
    return 0;
}
sub usage {
    say "Usage: $0 <options> <pdf_file>";
    say "-v debug";
    say "-a<FAA airport ID>  To specify an airport ID";
    say "-i<2 Letter state ID>  To specify a specific state";
    say "-p Output a marked up version of PDF";
    say "-s Output statistics about the PDF";
    say "-c Don't overwrite existing .vrt";
    say "-o Re-create outlines/mask files";
    say "-b Allow creation of vrt with known bad lon/lat ratio";
    say "-m Allow use of non-unique obstacles";

}
sub trueHeading {
    my ( $_x1, $_y1, $_x2, $_y2 ) = @_;

    return rad2deg( pi / 2 - atan2( $_y2 - $_y1, $_x2 - $_x1 ) );
}

sub WGS84toGoogleBing {
    my ( $lon, $lat ) = @_;
    my $x = $lon * 20037508.34 / 180;
    my $y = log( tan( ( 90 + $lat ) * pi / 360 ) ) / ( pi / 180 );
    $y = $y * 20037508.34 / 180;
    return ( $x, $y );
}

sub GoogleBingtoWGS84Mercator {
    my ( $x, $y ) = @_;
    my $lon = ( $x / 20037508.34 ) * 180;
    my $lat = ( $y / 20037508.34 ) * 180;

    $lat = 180 / pi * ( 2 * atan( exp( $lat * pi / 180 ) ) - pi / 2 );
    return ( $lon, $lat );
}

sub slopeAngle {
    my ( $x1, $y1, $x2, $y2 ) = @_;
    return rad2deg( atan2( $y2 - $y1, $x2 - $x1 ) ) % 180;
}

sub NESW {

    # Notice the 90 - latitude: phi zero is at the North Pole.
    return deg2rad( $_[0] ), deg2rad( 90 - $_[1] );
}

sub removeIconsAndTextboxesInMaskedAreas {

    #Remove an icon or a text box if it is in an area that is masked out
    say "removeIconsAndTextboxesInMaskedAreas" if $debug;
    my ( $type, $targetHashRef ) = @_;

    say "type: $type, hashref $targetHashRef" if $debug;

    foreach my $key ( sort keys %$targetHashRef ) {

        my $_pdfX = $targetHashRef->{$key}{"CenterX"};
        my $_pdfY = $targetHashRef->{$key}{"CenterY"};

        next unless ( $_pdfX && $_pdfY );

        my @pixels;
        my $_rasterX = $_pdfX * $main::scaleFactorX;
        my $_rasterY = $main::pngYSize - ( $_pdfY * $main::scaleFactorY );

        #Make sure all our info is defined
        if ( $_rasterX && $_rasterY ) {

            #Get the color value of the pixel at the x,y of the GCP
            @pixels = $main::image->GetPixel( x => $_rasterX, y => $_rasterY );

            #This is actually a RGB triplet rather than just 1 byte so I'm cheating a little bit here
            say "perlMagick: $pixels[0]" if $debug;

            #say @pixels;
            #Only keep this feature if the pixel at this point is black
            if ( $pixels[0] eq 0 ) {
            }
            else {
                #Otherwise delete it
                say "$type $key is being deleted" if $debug;
                delete $targetHashRef->{$key};
            }

        }
    }
    return;
}

sub processMaskingFile {
    if ( !-e "$main::outputPdfOutlines.png" || $main::shouldRecreateOutlineFiles ) {

        #If the .PNG doesn't already exist lets create it
        #offset from the center to start the fills
        my $offsetFromCenter = 120;

#If the masking PNG doesn't already exist, read in the outlines PDF, floodfill and then save

        #Read in the .pdf maskfile
        # $image->Set(units=>'1');
        $main::image->Set( units   => 'PixelsPerInch' );
        $main::image->Set( density => '300' );
        $main::image->Set( depth   => 1 );

        #$image->Set( background => 'white' );
        $main::image->Set( alpha => 'off' );
        $main::perlMagickStatus = $main::image->Read("$main::outputPdfOutlines");

#Now do two fills from just around the middle of the inner box, just in case there's something in the middle of the box blocking the fill
#I've only seen this be an issue once
# $image->Draw(primitive=>'color',method=>'Replace',fill=>'black',x=>1,y=>1,color => 'black');
        $main::image->Set( depth => 1 );

        #$image->Set( background => 'white' );
        $main::image->Set( alpha => 'off' );
        $main::image->ColorFloodfill(
            fill        => 'black',
            x           => $main::pngXSize / 2 - $offsetFromCenter,
            y           => $main::pngYSize / 2 - $offsetFromCenter,
            bordercolor => 'black'
        );
        $main::image->ColorFloodfill(
            fill        => 'black',
            x           => $main::pngXSize / 2 + $offsetFromCenter,
            y           => $main::pngYSize / 2 + $offsetFromCenter,
            bordercolor => 'black'
        );

# $image->Draw(stroke=>'red',  fill        => 'white',primitive=>'rectangle', points=>'20,20 100,100');

        #Write out to a .png do we don't have to do this work again
        $main::perlMagickStatus = $main::image->write("$main::outputPdfOutlines.png");
        warn "$main::perlMagickStatus" if "$main::perlMagickStatus";
    }
    else {
        # $image->Set( units      => 'PixelsPerInch' );
        # $image->Set( density    => '300' );
        $main::image->Set( depth => 1 );

        # $image->Set( background => 'white' );
        # $image->Set( alpha      => 'off' );

        #Use the already created mask image
        $main::perlMagickStatus = $main::image->Read("$main::outputPdfOutlines.png");
        warn "$main::perlMagickStatus" if "$main::perlMagickStatus";
    }

# $image->Draw(primitive=>'rectangle',method=>'Floodfill',fill=>'black',points=>"$halfPngX1,$halfPngY1,5,100",color=>'black');
# $image->Draw(fill=>'black',points=>'$halfPngX2,$halfPngY2',floodfill=>'yes',color => 'black');
#warn "$perlMagickStatus" if "$perlMagickStatus";
#Uncomment these lines to write out the mask file so you can see what it looks like
#Black pixel represent areas to keep, what is what to ignore
# $perlMagickStatus = $image->Write("$outputPdfOutlines.png");
# warn "$perlMagickStatus" if "$perlMagickStatus";
}
sub drawFeaturesOnPdf {

    if ( -e "$main::targetpng" ) {
        #Read in the .png we've created
        my ( $image, $perlMagickStatus );
        $image = Image::Magick->new;

        $perlMagickStatus = $image->Read("$main::targetpng");
        warn $perlMagickStatus if $perlMagickStatus;
        
        # say $main::airportLatitudeDec;
        my $y1 = latitudeToPixel($main::airportLatitudeDec) - 2;
        my $x1 = longitudeToPixel($main::airportLongitudeDec) - 2;
        my $x2 = $x1 + 4;
        my $y2 = $y1 + 4;

        $image->Draw(
            primitive => 'circle',
            stroke    => 'none',
            fill      => 'green',
            points    => "$x1,$y1 $x2,$y2",
            alpha     => '100'
        );

        # $image->Draw(
        # primitive   => 'line',
        # stroke      => 'none',
        # fill        => 'yellow',
        # points      => "$x1,$y1 $x2,$y2",
        # strokewidth => '50',
        # alpha       => '100'
        # );

        foreach my $key ( sort keys %main::gcps ) {

            my $lon = $main::gcps{$key}{"lon"};
            my $lat = $main::gcps{$key}{"lat"};
   
            my $y1  = latitudeToPixel($lat) - 1;
            my $x1  = longitudeToPixel($lon) - 1;
            my $x2  = $x1 + 2;
            my $y2  = $y1 + 2;
   
            $image->Draw(
                primitive => 'circle',
                stroke    => 'none',
                fill      => 'red',
                points    => "$x1,$y1 $x2,$y2",
                alpha     => '100'
            );

        }
        #Draw the runway endpoints in orange
                foreach my $key ( sort keys %main::runwaysToDraw ) {

                    my $latLE = $main::runwaysToDraw{$key}{"LELatitude"};
                    my $lonLE = $main::runwaysToDraw{$key}{"LELongitude"};
              
           
                    my $y1  = latitudeToPixel($latLE) - 1;
                    my $x1  = longitudeToPixel($lonLE) - 1;
                    my $x2  = $x1 + 2;
                    my $y2  = $y1 + 2;
           
                    $image->Draw(
                        primitive => 'circle',
                        stroke    => 'none',
                        fill      => 'orange',
                        points    => "$x1,$y1 $x2,$y2",
                        alpha     => '100'
                    );
                    
                    my $latHE = $main::runwaysToDraw{$key}{"HELatitude"};
                    my $lonHE = $main::runwaysToDraw{$key}{"HELongitude"};
                    $y1  = latitudeToPixel($latHE) - 1;
                    $x1  = longitudeToPixel($lonHE) - 1;
                    $x2  = $x1 + 2;
                    $y2  = $y1 + 2;
           
                    $image->Draw(
                        primitive => 'circle',
                        stroke    => 'none',
                        fill      => 'orange',
                        points    => "$x1,$y1 $x2,$y2",
                        alpha     => '100'
                    );

        }
        
        $perlMagickStatus = $image->write("$main::gcpPng");
        warn $perlMagickStatus if $perlMagickStatus;
        return;
    }
}
sub latitudeToPixel {
    my ($_latitude) = @_;
    return 0 unless $main::yMedian;

    # say $_latitude;
    #say "$ulYmedian, $yMedian";
    my $_pixel = abs( ( $main::ulYmedian - $_latitude ) / $main::yMedian );

    # say "$_latitude to $_pixel";

    return $_pixel;
}

sub longitudeToPixel {
    my ($_longitude) = @_;
    return 0 unless $main::xMedian;

    # say $_longitude;
    #say "$ulXmedian, $xMedian";
    my $_pixel = abs( ( $main::ulXmedian - $_longitude ) / $main::xMedian );

    #say "$_longitude to $_pixel";

    return $_pixel;
}
1;
