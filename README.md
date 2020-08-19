# OSM GeoJSON Tile Maker

Extracting specific tags from OSM's planet file and saving them as a GeoJSON tile layer.



## Generating tiles for a specific geographic area

Here is a simple method for generating tiles for a limited area. In this example we have a cronjob that downloads [OSM data for "Great Britain" from Geofabrik](http://download.geofabrik.de/europe/great-britain.html) once a day. That file is around 1.1GB in size:

`wget http://download.geofabrik.de/europe/great-britain-latest.osm.pbf`

We use [`ogr2ogr`](https://gdal.org/programs/ogr2ogr.html) to extract all the __points__ into a GeoJSON file (~900 MB) with one node per line:

`ogr2ogr -overwrite --config OSM_CONFIG_FILE osmconf.ini -skipfailures -f GeoJSON points.geojson great-britain-latest.osm.pbf points`

We process each line of that file and extract every line that matches [`amenity=waste_basket`](https://wiki.openstreetmap.org/wiki/Tag:amenity%3Dwaste_basket) or [`amenity=recycling`](https://wiki.openstreetmap.org/wiki/Tag:amenity%3Drecycling).

```perl
open(FILE,"points.geojson");
while(<FILE>){
  if($_ =~ /\"type\": \"Feature\"/){
    if($_ =~ /\"amenity": \"waste_basket\"/ || $_ =~ /\"amenity\": \"recycling\"/){
      # Process a single line here

      # Use the lat,lon to work out the appropriate tile coordinates
    }
  }
}
close(FILE);
```

Each matching node has it's tile coordinates calculated (based on zoom level 12) and is saved to the appropriate tile file. For Great Britain, the resulting directory is around 15 MB in size. Individual tiles are generally under 200kB and often much smaller than that:



## Generating tiles for the whole planet using a Raspberry Pi 4

Here is our attempt to process the entire planet using a Raspberry Pi 4.

### Setup

We purchased a Raspberry Pi 4 with 8GB RAM and a WD My Passport External SSD 512 GB. The external SSD has theoretical read/write up to 515 MB/s but in practice was much slower. At one point, having the SSD on a USB3.0 port caused unexpected conflicts with the wireless adapter so it was moved to a USB2.0 port. Set up the Raspberry Pi to boot to the command line logged in. The WIFI was set up. Updated the packages:

```
sudo apt update
sudo apt full-upgrade
```

Next we will install git (if it isn't already installed):

`sudo apt install git`

You may also wish to set up the Raspberry Pi for "headless" SSH access (enable SSH in `raspi-config`) and [generate an SSH key for use on Github](https://docs.github.com/en/github/authenticating-to-github/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent).

#### External drive

The external drive was formatted for use:

`sudo mkfs.ntfs /dev/sda1 -f -L "Name"

We want to [automatically mount the drive](https://raspberrytips.com/mount-usb-drive-raspberry-pi/) so we first need to get the drive's UUID:

`sudo ls -l /dev/disk/by-uuid/`

This outputs something like:

```
total 0
lrwxrwxrwx 1 root root 10 Jul 30 14:24 XXXXXXXXXXXXXXXX -> ../../sda1
lrwxrwxrwx 1 root root 15 Jul 30 14:22 XXXX-XXXX -> ../../mmcblk0p1
lrwxrwxrwx 1 root root 15 Jul 30 14:22 XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX -> ../../mmcblk0p2
```

We want the `XXXXXXXXXXXXXXXX` corresponding to `../../sda1`:

Now run `sudo nano /etc/fstab` and add this to the bottom:

`UUID=XXXXXXXXXXXXXXXX  /mnt/Name        ntfs    uid=pi,gid=pi   0       0`

The WD My Passport 512 GB drive for some reason started causing problems with the WIFI adapter. You could either have the drive connected at boot or the WIFI could connect but not both. Switching the drive to a USB2 port seemed to stop the problem. :/


#### OSM tools

Install the osm tools ([osmfilter](https://wiki.openstreetmap.org/wiki/Osmfilter), [osmconvert](https://wiki.openstreetmap.org/wiki/Osmconvert), and osmupdate[https://wiki.openstreetmap.org/wiki/Osmupdate]):

`sudo apt install osmctools`

Now we need to install `ogr2ogr`. We follow the [instructions from GDAL](https://mothergeo-py.readthedocs.io/en/latest/development/how-to/gdal-ubuntu-pkg.html):

```
sudo apt-get install python3.6-dev
sudo apt-get update
sudo apt-get install gdal-bin
ogrinfo --version
```

Note that the `sudo apt-get install gdal-bin` seemed to run into difficulties part way through so it was re-run each time until it managed to complete successfully.

#### Perl


Add a perl library for parsing JSON:

```
sudo perl -MCPAN -e shell
install CPAN
reload CPAN
install JSON::XS
```

#### Planet file

Now download the latest planet file:

`wget https://planet.osm.org/pbf/planet-latest.osm.pbf`

For faster processing later we convert to `o5m` format.

`osmconvert planet-latest.osm.pbf -o=planet.o5m`

This took about 3 hours 4 minutes on the Raspberry Pi 4 and created a 107GB file.

`mv planet.o5m planet_old.o5m`

Now update the planet file with any daily updates required:

`osmupdate --tempfiles=DIR --keep-tempfiles --day planet_old.o5m planet.o5m`

where `DIR` is a directory on the external SSD to use for temporary files. This downloads each daily changeset since your planet file was last updated. Each daily changeset can be around 70-130 MB (in mid 2020) and takes two or three minutes to download. The first time this ran it needed to download 9 days of changesets (the process started on 28th July and the planet file was dated 200720).


### Daily use

We are now ready for daily updates. Because the process of merging daily updates for the entire planet and then filtering the entire planet for the tags we want takes many hours, we have taken a different approach. We pre-filter the world (`osmfilter`) then filter each of the daily change files (`osmfilter`) and then use `osmconvert` to combine these much smaller changes into the filtered planet file. Doing it this way is much quicker each day.

First we use `config.json` to specify the layers we are making:

```json
{
	"bins": {
		"make": true,
		"tags": "amenity=waste_basket =recycling",
		"odir": "../osm-geojson/tiles/bins/",
		"zoom": 12
	}
}
```

The `tags` key contains the `osmfilter` format tags you wish to keep; in this case `amenity=waste_basket` and `amenity=recycling`. `odir` is the directory to save the resulting GeoJSON tiles to - in this case we are saving to the ODI Leeds [osm-geojson repo](https://github.com/odileeds/osm-geojson). We set up a cronjob to run the following command once a day:

`perl /PATH/TO/update.pl -mode update`

This perl script will:

* check for the filtered version of the planet (e.g. `osm/bins.o5m`) and create it if it doesn't exist - that will take a few hours but should only need to be done once;
* download the daily change file into a `temp/` subdirectory;
* uncompress the daily change file;
* run `osmfilter` on the change file to extract only the necessary tags and save these to a new change file (e.g. `temp/XXXX-bins.osc` where `XXXX` is the sequence number);
* run `osmconvert` to combine the daily change with the filtered planet;
* run `osmconvert` to create a `osm/bins.osm.pbf` file;
* run `ogr2ogr` to create a `osm/bins.geojson` file;
* read each feature of `osm/bins.geojson` and work out which map tile it is part of;
* save all the map tiles to the `odir` specified in `config.json`.


#### Statistics

As of 2020-07-31 this took 8m12s to do a daily update on a Raspberry Pi 4. It found 664,758 bins (waste & recycling) and saved 48,617 tiles. 

Some representative file sizes:

* `planet.o5m` - 108 GB
* `bins.o5m` - 20 MB
* `bins.osm.pbf` - 13 MB
* `bins.geojson` - 150 MB
* `2879.osc.gz` - 101 MB (daily changes)
* `2879-bins.osc` - 108 kB (daily changes - bins)

We can find the largest (bytes) GeoJSON tiles:

`find . -printf '%s %p\n'|sort -nr|head`

To calculate area statistics we need some areas. Download the [UK Local Authority Districts (May 2020)](https://geoportal.statistics.gov.uk/datasets/local-authority-districts-may-2020-boundaries-uk-bfe) from ONS as [a Shapefile](https://prod-hub-indexer.s3.amazonaws.com/files/7f83b82ef6ce46d3a5635d371e8a3e7c/0/full/27700/7f83b82ef6ce46d3a5635d371e8a3e7c_0_full_27700.zip) and extract it into `geo/`. Create the SQlite file from the UK LAD Shapefile in QGIS with spatial indexing and convert the coordinates to WGS84.


`ogr2ogr -f "SQLite" bins.sqlite bins.osm.pbf -clipsrc -8.650007 49.864637 1.768912 60.860766`                                                         `

`ogrinfo bins.shp/points.shp -sql "CREATE SPATIAL INDEX ON points" `

Output 

`ogr2ogr -f 'ESRI Shapefile' output.shp -dialect sqlite -sql "SELECT COUNT(*) FROM lad, bins WHERE ST_Intersects(lad.geometry,bins.geometry) GROUP BY lad.lad20cd" input.vrt`

Get cultural boundaries from [Natural Earth](https://www.naturalearthdata.com/downloads/10m-cultural-vectors/ http://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-admin-0-countries/) or [country boundaries from the World Bank](https://datacatalog.worldbank.org/dataset/world-bank-official-boundaries) (CC-BY 4.0) and convert these:


### Setting up SleepyPi

First we follow the [SleepyPi setup instructions](https://spellfoundry.com/docs/sleepy-pi-2-getting-started/):

```
sudo apt update
sudo apt full-update

wget https://raw.githubusercontent.com/SpellFoundry/Sleepy-Pi-Setup/master/Sleepy-Pi-Setup.sh
chmod +x Sleepy-Pi-Setup.sh
sudo ./Sleepy-Pi-Setup.sh
```

Next we have to [set-up the real-time clock](https://spellfoundry.com/sleepy-pi/setting-up-the-real-time-clock-on-raspbian-jessie/) (RTC):

```
i2cdetect -y 1
```

This should output something that looks like:

```
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
00:          -- -- -- -- -- -- -- -- -- -- -- -- --
10: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
20: -- -- -- -- 24 -- -- -- -- -- -- -- -- -- -- --
30: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
40: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
50: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
60: -- -- -- -- -- -- -- -- 68 -- -- -- -- -- -- --
70: -- -- -- -- -- -- -- --
```

Add the line `dtoverlay=i2c-rtc,pcf8523` to the bottom of `/boot/config.txt`. Next edit `hwclock-set`:

```
sudo nano /lib/udev/hwclock-set
```

and comment out the following lines

```
#if [ -e /run/systemd/system ] ; then 
#   exit 0
#fi
```

Also 

```
if [ yes - "$BADYEAR" ] ; then 
#  /sbin/hwclock --rtc=$dev --systz --badyear
  /sbin/hwclock --rtc=$dev --hctosys --badyear
else
#  /sbin/hwclock --rtc=$dev --systz --badyear
  /sbin/hwclock --rtc=$dev --hctosys
fi
```

Read from the hardware clock:

`sudo hwclock -r`


Next the mechanism for updating the time over the network is NTP or Network Time Protocol. Disable this by doing:

```
sudo systemctl stop ntp.service
sudo systemctl disable ntp.service
```

These two steps should do the trick, but if it’s also a good idea to disable the “fake hwclock” (after all, we have a real one!). Disable this by doing:

```
sudo systemctl stop fake-hwclock.service
sudo systemctl disable fake-hwclock.service
```
