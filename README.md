GeoReferencePlates
==================

A utility for automatically georeferencing FAA / AeroNav Instrument Approach Plates

Requires a database containing lat/lon info
	Create it from FAA data and the utilities in "database" folder
		FAA data is here: https://nfdc.faa.gov/xwiki/bin/view/NFDC/56+Day+NASR+Subscription
			eg: https://nfdc.faa.gov/webContent/56DaySub/56DySubscription_October_17__2013_-_December_12__2013.zip
		Obstacle data
			http://tod.faa.gov/tod/public/TOD_DOF.html

Requires the following external programs
	GDAL
	mupdf-tools
	pdftotext
	sqlite3


Requires Perl > 5.010

Requires the follwing CPAN modules
	PDF::API2
	DBI
	Data::Dumper
	File::Basename


