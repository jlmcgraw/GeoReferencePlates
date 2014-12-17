Create Georeferencing information for Instrument Approach Procedures and Airport Diagrams

![SFO Airport Diagram](https://raw.github.com/jlmcgraw/GeoReferencePlates/master/screenshots/SFO-AD.png)

![SFO VOR RWY 19L](https://raw.github.com/jlmcgraw/GeoReferencePlates/master/screenshots/SFO-VOR-RWY-19L.png)

These instructions are based on using Ubuntu

How to get this utility up and running:

	Enable the "universe" repository in "Software & Updates" section of System Settings and update

	Install git
		sudo apt-get install git

	Download the repository
		git clone https://github.com/jlmcgraw/GeoReferencePlates

	Install the following external programs
		gdal 		(sudo apt-get install gdal-bin)
		mupdf-tools 	(sudo apt-get install mupdf-tools)
		sqlite3 	(sudo apt-get install sqlite3)

	Install the following CPAN modules
		PDF::API2   	(sudo apt-get install libpdf-api2-perl)
		DBI 		(sudo apt-get install libdbi-perl)
		DBD::SQLite3	(sudo apt-get install libdbd-sqlite3-perl) 
		Image::Magick	(sudo apt-get install libimage-magick-perl)
		File::Slurp	(sudo apt-get install libfile-slurp-perl)
		XML::Xpath 	(sudo apt-get install libxml-xpath-perl)

	Download some Instrument Approach Procedure plates
		- Download these with the "load_dtpp_metadata.pl" file
			This will also re-initialize the dtpp.db file, be careful

		- A download of all plates takes several hours
			
		downloadPlates.pl requires the following CPAN modules:
			XML::Xpath (sudo apt-get install libxml-xpath-perl)

	Requires a database containing lat/lon info 
		(currently included in the git repository)

	Requires a database containing charting cycle information
		(create this with the load_dtpp_metadata.pl program)

	Requires perl version > 5.010

How to use these utilities
	To georeference instrument procedures:
		 ./georeferencePlatesViaDb.pl <options> <directory_with_PDFs>
			-v debug
			-a<FAA airport ID>  To specify an airport ID
			-i<2 Letter state ID>  To specify a specific state
			-p Output a marked up version of PDF
			-s Output statistics to dtpp.db about the PDF
			-c Don't overwrite existing .vrt
			-o Re-create outlines/mask files
			-b Allow creation of vrt with suspected bad lon/lat ratio
			-m Allow use of non-unique obstacles
	
	To georeference airport diagrams:
		Usage: ./georeferenceAirportDiagramsViaDb.pl <options> <directory_with_PDFs>
			-v debug
			-a<FAA airport ID>  To specify an airport ID
			-i<2 Letter state ID>  To specify a specific state
			-p Output a marked up version of PDF
			-s Output statistics to dtpp.db about the PDF
			-c Don't overwrite existing .vrt

	-p will create two extra files:
		 marked-*.pdf
			Shows how the ground control points were matched
			A green circle indicates which were used 

		 gcp-*.png
			Uses lon/lat information from the database to draw the ground control points.  If the red dots don't seem to match up with a feature (obstacle, fix, nav aid) the georeference probably wasn't accurate
			The green dot is the airport lon/lat

The first time the utility is run for a particular PDF it will take longer as it is generating the corresponding PNG and mask files.  These will not be created again if they exist

A first run for all plates may take a day or two, subsequent runs will be much shorter

Running
	Refresh the locationinfo.db database
		Code to do so is not currently in github

	Create empty ./dtpp folder

	./load_dtpp_metadata.pl . 1409
		Download DTPP XML catalog, create DTPP database and download procedures.  Change cycle number as needed

	./georeferencePlatesViaDb.pl -m -p -s ./dtpp/

	./georeferenceAirportDiagramsViaDb.pl -p -s ./dtpp/

This software and the data it produces come with no guarantees about accuracy or usefulness whatsoever!  Don't use it when your life may be on the line!

Thanks for trying this out!  If you have any feedback, ideas or patches please submit them to github.

-Jesse McGraw
jlmcgraw@gmail.com

DISTRIBUTION

Users are  prohibited from  any commercial or non-free resale use without explicit written permission from Jesse McGraw. Users should acknowledge this project as
the source used  in the creation  of any reports,  publications, new data  sets,
derived products, or services resulting from the use of this data set. I also
request  reprints of  any publications  and notification  of any  redistributing
efforts.   For commercial  access to  the data,  send requests  to Jesse McGraw
jlmcgraw@gmail.com.

NO WARRANTY OR LIABILITY

I provide  these data  without any  warranty of  any kind whatsoever, either
express or implied,  including warranties of  merchantability and fitness  for a
particular purpose. I shall not  be liable for incidental, consequential,  or
special damages arising out of the use of any data.

ACKNOWLEDGMENT AND CITATION

I kindly ask  any users to  cite this data  in any published  material produced
using this data,  and if possible  link web pages  to the github mwebsite
(http://github.com/jlmcgraw).
