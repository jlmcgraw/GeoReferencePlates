#!/usr/bin/perl

# GeoRerencePlates - a utility to automatically georeference FAA Instrument Approach Plates / Terminal Procedures
# Copyright (C) 2013  Jesse McGraw (jlmcgraw@gmail.com)
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


use DBI;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use File::Basename;
use Getopt::Std;
use Carp;


#Some subroutines
use GeoReferencePlatesSubroutines;



#database of metadta for dtpp
my $dbfile = "./dtpp.db";
my $dtppDbh =
     DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "", { RaiseError => 1 } )
  or croak $DBI::errstr;

#-----------------------------------------------
#Open the locations database
our $dbh;
my $sth;

$dbh = DBI->connect(
    "dbi:SQLite:dbname=locationinfo.db",
    "", "", { RaiseError => 1 },
) or croak $DBI::errstr;

our (
    $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
    $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
    $MILITARY_USE, $COPTER_USE,  $STATE_ID
);

$dtppDbh->do("PRAGMA page_size=4096");
$dtppDbh->do("PRAGMA synchronous=OFF");

#Query the dtpp database for  count of IAP charts
my $dtppSth = $dtppDbh->prepare(
    "SELECT  TPP_VOLUME, FAA_CODE, CHART_SEQ, CHART_CODE, CHART_NAME, USER_ACTION, PDF_NAME, FAANFD18_CODE, MILITARY_USE, COPTER_USE, STATE_ID
             FROM dtpp  
             WHERE                  
                CHART_CODE = 'IAP' 
                AND
                PDF_NAME NOT LIKE '%DELETED%'
                "
);
$dtppSth->execute();
my $_allSqlQueryResults = $dtppSth->fetchall_arrayref();
my $iapCount = $dtppSth->rows;
say "$iapCount IAP charts";

#Query the dtpp database for  count of Civilian IAP charts
$dtppSth = $dtppDbh->prepare(
    "SELECT  TPP_VOLUME, FAA_CODE, CHART_SEQ, CHART_CODE, CHART_NAME, USER_ACTION, PDF_NAME, FAANFD18_CODE, MILITARY_USE, COPTER_USE, STATE_ID
             FROM dtpp  
             WHERE  
                CHART_CODE = 'IAP'
                AND
                PDF_NAME NOT LIKE '%DELETED%'
                AND
                MILITARY_USE NOT LIKE 'M'
                "
);
$dtppSth->execute();
$_allSqlQueryResults = $dtppSth->fetchall_arrayref();
$iapCount = $dtppSth->rows;
say "$iapCount Civilian IAP charts";
#----------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Query the dtpp database for  count of Civilian IAP charts with good ratio
$dtppSth = $dtppDbh->prepare(
    "SELECT *
      FROM dtpp as D 
      JOIN dtppGeo as DG 
      ON D.PDF_NAME=DG.PDF_NAME
             WHERE
                 D.CHART_CODE = 'IAP'
                AND  
                DG.PDF_NAME NOT LIKE '%DELETED%'
                AND            
                CAST (DG.yScaleAvgSize AS FLOAT) > 0
                AND
                CAST (DG.xScaleAvgSize as FLOAT) > 0
                AND
                D.MILITARY_USE NOT LIKE 'M'
                AND
                (CAST (DG.targetLonLatRatio AS FLOAT) - CAST(DG.lonLatRatio AS FLOAT)  BETWEEN -.09 AND .09 )     
                "
);
$dtppSth->execute();
$_allSqlQueryResults = $dtppSth->fetchall_arrayref();
$iapCount = $dtppSth->rows;
say "$iapCount Civilian IAP charts with good ratio";

#----------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Query the dtpp database for  count of Miltary IAP charts
$dtppSth = $dtppDbh->prepare(
    "SELECT  TPP_VOLUME, FAA_CODE, CHART_SEQ, CHART_CODE, CHART_NAME, USER_ACTION, PDF_NAME, FAANFD18_CODE, MILITARY_USE, COPTER_USE, STATE_ID
             FROM dtpp  
             WHERE  
                CHART_CODE = 'IAP'
                AND
                PDF_NAME NOT LIKE '%DELETED%'
                AND
                MILITARY_USE  LIKE 'M'
                "
);
$dtppSth->execute();
$_allSqlQueryResults = $dtppSth->fetchall_arrayref();
$iapCount = $dtppSth->rows;
say "$iapCount Miltary IAP charts";

#----------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Query the dtpp database for  count of Miltary IAP charts with good ratio
$dtppSth = $dtppDbh->prepare(
    "SELECT *
      FROM dtpp as D 
      JOIN dtppGeo as DG 
      ON D.PDF_NAME=DG.PDF_NAME
             WHERE  
                 D.CHART_CODE = 'IAP'
                AND
                DG.PDF_NAME NOT LIKE '%DELETED%'
                AND
                CAST (DG.yScaleAvgSize AS FLOAT) > 0
                AND
                CAST (DG.xScaleAvgSize as FLOAT) > 0
                AND
                D.MILITARY_USE LIKE 'M'
                AND
                (CAST (DG.targetLonLatRatio AS FLOAT) - CAST(DG.lonLatRatio AS FLOAT)  BETWEEN -.09 AND .09 )
                "
);
$dtppSth->execute();
$_allSqlQueryResults = $dtppSth->fetchall_arrayref();
$iapCount = $dtppSth->rows;
say "$iapCount Miltary IAP charts with good ratio";
# foreach my $row (@$_allSqlQueryResults) {

    # (
        # $TPP_VOLUME,   $FAA_CODE,    $CHART_SEQ, $CHART_CODE,
        # $CHART_NAME,   $USER_ACTION, $PDF_NAME,  $FAANFD18_CODE,
        # $MILITARY_USE, $COPTER_USE,  $STATE_ID
    # ) = @$row;

    # # say      '$TPP_VOLUME, $FAA_CODE, $CHART_SEQ, $CHART_CODE, $CHART_NAME, $USER_ACTION, $PDF_NAME, $FAANFD18_CODE, $MILITARY_USE, $COPTER_USE, $STATE_ID';
    # # say      "$TPP_VOLUME, $FAA_CODE, $CHART_SEQ, $CHART_CODE, $CHART_NAME, $USER_ACTION, $PDF_NAME, $FAANFD18_CODE, $MILITARY_USE, $COPTER_USE, $STATE_ID";

# }

#Close the charts database
$dtppSth->finish();
$dtppDbh->disconnect();

#Close the locations database
# $sth->finish();
$dbh->disconnect();