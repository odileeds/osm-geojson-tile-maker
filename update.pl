#!/usr/bin/perl
################
# OSM tile layer updater.
# Created:      2020-07-27
# Last updated: 2020-07-29
#
# perl update.pl -mode update
# perl update.pl -mode info

my $basedir;
BEGIN {
	$basedir = $0;
	$basedir =~ s/[^\/]*$//g;
	if(!$basedir){ $basedir = "./"; }
	$lib = $basedir."lib/";
}
use lib $lib;
use strict;
use warnings;
use Data::Dumper;
use POSIX qw(strftime);
use JSON::XS;
use ODILeeds::ProgressBar;
use ODILeeds::Tiler;


my (%data,$i,$k,$v,$json,$jsonbit,$coder,$coderu,$str,$slice,$timestamp,$convert,$filter,$planet,$mode,$file,$filepbf,$filegeo,$ogr,@lines,$line,$tiler,%tiles,@types,$n,$zoom,$odir,$ini,@props,$p,$x,$y,$t,$feature,$tile,$ntiles,$progress);

my $datadir = $basedir."osmdata/";
my $tempdir = $basedir."temp/";

if(-e $basedir.".osm_lock"){
	print "Process already running ($basedir.osm_lock)\n";
	exit;
}
# Create a lock file
`touch $basedir.osm_lock`;

$convert = "osmconvert";
$filter = "osmfilter";
$planet = $datadir."planet.o5m";
$mode = "info";
$ogr = "ogr2ogr";
@types = ('points');
$n = 0;
$zoom = 12;
$odir = $datadir;
$ini = $basedir."osmconf.ini";


# Parse command line parameters
for($i = 0; $i < @ARGV; $i += 2){
	$k = $ARGV[$i];
	$v = $ARGV[$i+1];
	$k =~ s/^\-//;
	if($k eq "convert"){ $convert = $v; }
	elsif($k eq "filter"){ $filter = $v; }
	elsif($k eq "planet"){ $planet = $v; }
	elsif($k eq "mode"){ $mode = $v; }
}

# Check for existence of osmctools
if(!`which $convert`){
	print "Unable to find $convert\n";
	exit;
}
if(!`which $filter`){
	print "Unable to find $filter\n";
	exit;
}
if(!`which $ogr`){
	print "Unable to find $ogr\n";
	exit;
}


$tiler = ODILeeds::Tiler->new();
$progress = ODILeeds::ProgressBar->new();


$coder = JSON::XS->new->ascii->canonical(1);
$coderu = JSON::XS->new->utf8->canonical(1);
open(FILE,$basedir."config.json");
$str = join("",<FILE>);
close(FILE);

$json = $coder->decode($str);


if($mode eq "info"){
	# Filter the main planet file to make each slice
	for $slice (sort(keys(%{$json}))){
		$file = $datadir.$slice.".o5m";
		print "$slice ($file):\n";
		# We want to find out when it was last updated
		if(-e $file){
			$timestamp = getTimestamp($file);
			print "\tTimestamp = $timestamp\n";
		}else{
			print "\tThe cut-down version $file doesn't exist.\n";
		}
	}
}elsif($mode eq "update"){
	# Filter the main planet file to make each slice
	for $slice (sort(keys(%{$json}))){
		print "$slice:\n";
		if($json->{$slice}{'make'}){
			$file = $datadir.$slice.".o5m";
			if(!-e $file){
				print "\t$file doesn't exist so we first need to make it from the planet file. Run:\n";
				print "\t$filter $planet --keep=\"$json->{$slice}{'tags'}\" -v --drop-ways --drop-relations -o=$file\n";
				exit;
			}

			# At this point we want to update the cut-down version
			$timestamp = getPlanetUpdates($slice,$file,$json->{$slice}{'tags'});

			
			# Now we convert the file type into one that ogr2ogr can deal with
			$filepbf = $datadir.$slice.".osm.pbf";
			$filegeo = $datadir.$slice.".geojson";

			print "\tCreating GeoJSON output...\n";
			if(-e $filegeo){
				`rm $filegeo`;
			}
			`$convert $file -o=$filepbf`;
			`$ogr -overwrite --config $ini -skipfailures -f GeoJSON $filegeo $filepbf points`;
			`sed -i 's/"crs": { "type": "name", "properties": { "name": "urn:ogc:def:crs:OGC:1.3:CRS84" } },/"lastupdate":"$timestamp",/g' $filegeo `;

			$odir = $json->{$slice}{'odir'}||"./";
			$zoom = $json->{$slice}{'zoom'}||12;
			if($odir){

				if(!-d $odir){ makedir($odir); }
				if(!-d $odir.$zoom){ makedir($odir.$zoom); }
					
				$n = `sed -n '\$=' $filegeo`;
				$n =~ s/[\n\r]//g;
				$i = 0;
				$progress->max($n-1);
				print "\tProcessing $filegeo\n";
				open(FILE,$filegeo);
				while(<FILE>){
					if($_ =~ /\"type\": \"Feature\"/){
						$line = $_;
						chomp $line;
						$line =~ s/\,$//g;
						# Remove nulls
						$line =~ s/, \"([^\"]*)\": null//g;
						$jsonbit = $coder->decode($line);
						if($line){
							# Clean up 'other_tags'
							if($jsonbit->{'properties'}->{'other_tags'}){
								if($jsonbit->{'properties'}->{'other_tags'}){
									# Turn into JSON
									$jsonbit->{'properties'}->{'other_tags'} =~ s/\=\>/\:/g;
									# Escape newlines
									$jsonbit->{'properties'}->{'other_tags'} =~ s/[\n\r]/\\n/g;
									$jsonbit->{'properties'}->{'tag'} = $coderu->decode("{".$jsonbit->{'properties'}->{'other_tags'}."}");
								}
								# Remove original group
								delete $jsonbit->{'properties'}->{'other_tags'};
							}
						}else{
							print "No line for $n ($line)\n";
						}
						# Truncate coordinates to 6dp (~11cm)
						$jsonbit->{'geometry'}->{'coordinates'}[0] =~ s/([0-9]\.[0-9]{6}).*/$1/g;
						$jsonbit->{'geometry'}->{'coordinates'}[1] =~ s/([0-9]\.[0-9]{6}).*/$1/g;
						$jsonbit->{'geometry'}->{'coordinates'}[0] += 0;
						$jsonbit->{'geometry'}->{'coordinates'}[1] += 0;
						($x,$y) = $tiler->project($jsonbit->{'geometry'}->{'coordinates'}[1],$jsonbit->{'geometry'}->{'coordinates'}[0],$zoom);
						$t = $x."/".$y;
						if(!$tiles{$t}){ $tiles{$t} = ""; }
						$feature = $coder->encode($jsonbit);
						$feature =~ s/\,\"tag\":\{\}//g;
						$tiles{$t} .= ($tiles{$t} ? ",\n":"")."\t".$feature;
					}
					$i++;
					$progress->update($i,"\t");
				}
				$n = $i;
				close(FILE);
				$ntiles = keys(%tiles);
				$progress->max($ntiles);
				print "\tSaving $n $slice in $ntiles tiles ($json->{$slice}{'tags'})\n";
				$i = 0;
				foreach $tile (keys(%tiles)){
					($x,$y) = split(/\//,$tile);
					if(!-d $odir.$zoom."/$x"){
						`mkdir $odir$zoom/$x`;
					}
					$file = "$odir$zoom/$tile.geojson";
					open(FILE,">",$file);
					print FILE "{\n";
					print FILE "\"type\": \"FeatureCollection\",\n";
					print FILE "\"lastupdate\": \"".$timestamp."\",\n";
					print FILE "\"features\": [\n";
					print FILE "$tiles{$tile}\n";
					print FILE "]\n";
					print FILE "}\n";
					close(FILE);
					$i++;
					$progress->update($i,"\t");
				}
			}else{
				print "No output directory given.\n";
			}
		}
	}
}

# Remove lock file
`rm $basedir.osm_lock`;


#`osmfilter planet.o5m --keep="amenity=waste_basket =recycling" -v --drop-ways --drop-relations -o=bins.o5m`;




##########################
sub getPlanetUpdates {
	# Download state
	my ($file,$line,$seq,$tstamp,$timestamp,@lines,$s,$t,$url,$cfile,$sfile,$processfiles,$tags,$slice,$ofile,$newest);
	$slice = $_[0];
	$file = $_[1];
	$tags = $_[2];

	print "\tGet planet updates for $slice ($tags)\n";
	# We should now have the cut down version of the planet file.
	# We want to update it with any changes.
	$timestamp = getTimestamp($file);
	if(!$timestamp){
		# We want to add back the timestamp from the original planet file we started with
		$timestamp = getTimestamp($planet);
		if(!$timestamp){
			print "Bad timestamp in original planet file $timestamp.\n";
			exit;
		}else{
			print "Adding timestamp=$timestamp from $planet\n";
			`mv $file temp.o5m`;
			`$convert --timestamp=$timestamp -o=$file temp.o5m`;
			`rm temp.o5m`;
		}
	}
	print "\tTimestamp = $timestamp\n";
	
	# Get latest state
	@lines = `wget -q --no-check-certificate -O- "https://planet.osm.org/replication/day/state.txt"`;
	($seq,$tstamp) = processState(@lines);
	$newest = $tstamp;
	
	print "\tSequence = $tstamp\n";

	if($tstamp le $timestamp){
		print "\t$file is up-to-date\n";
	}else{
		# We need to go backwards downloading files that are after 
		
		print "\tNeed to download backwards from $seq\n";
		$processfiles = "";
		while($tstamp gt $timestamp){
			print "\tprocessState($seq)\n";
			($seq,$tstamp) = getState($seq);
			if($tstamp gt $timestamp){
				# Now we download the changefile
				$url = getPlanetBaseUrlFromState($seq).".osc.gz";
				$cfile = $tempdir.$seq.".osc";
				$sfile = $cfile;
				$sfile =~ s/\.osc/-$slice\.osc/;

				if(!-e $sfile){
					if(!-e $cfile){
						if(!-e ($cfile.".gz")){
							print "\tDownloading $url to $cfile.gz\n";
							`wget -q --no-check-certificate -O "$cfile.gz" "$url"`;
						}
						print "\tGunzipping $cfile.gz\n";
						`gunzip "$cfile.gz"`;
					}
					print "-> $seq, $tstamp ".getPlanetBaseUrlFromState($seq).".osc\n";
					# Now we need to filter the change file
					if(!-e $sfile){
						print "\tFiltering $cfile to $sfile.\n";
						`$filter $cfile --keep="$tags" -v --drop-ways --drop-relations -o=$sfile`;
					}
					if(!-e "$cfile.gz"){
						print "\tZipping file back up ($cfile)\n";
						`gzip "$cfile"`;
					}else{
						print "\t$cfile.gz is zipped\n";
					}
				}
				$processfiles = $sfile.($processfiles ? " ":"").$processfiles;
			}
			$seq--;
		}
		if($processfiles){
			$ofile = $file;
			$ofile =~ s/.o5m/-new.o5m/g;
			if(-e $ofile){
				`rm $ofile`;
			}
			print "\tosmconvert $file $processfiles -o=$ofile\n";
			`$convert $file $processfiles --timestamp=$newest -o=$ofile`;
			if(-s $ofile==0){
				print "\tERROR: Temporary file ($ofile) seems empty.\n";
				exit;
			}else{
				if(-e $file){
					`rm $file`;
				}
				`mv $ofile $file`;
				print "\t$file has timestamp: ".getTimestamp($file)."\n";
				return getTimestamp($file);
			}
		}else{
			print "\tERROR: Couldn't find any change files even though the timestamp suggests they exist.\n";
			exit;
		}
	}
	return $timestamp;
}

sub getPlanetBaseUrlFromState {
	my ($seq,$state);
	$seq = $_[0];
	$state = sprintf("%09d",$seq);
	# Insert a directory separator every third character
	$state =~ s/...\K(?=.)/\//sg;
	return "https://planet.osm.org/replication/day/".$state;
}

sub getState {
	my (@lines,$line,$seq,$tstamp,$file,$state,$url);
	$seq = $_[0];
	$file = $tempdir."state-$seq.txt";
	$url = getPlanetBaseUrlFromState($seq);
	if(!-e $file || -s $file == 0){
		if(-e $file){ `rm $file`; }
		$url .= ".state.txt";
		print "\tGetting state from $url to $file\n";
		`wget -q --no-check-certificate -O $file "$url"`;
	}
	open(FILE,$file);
	@lines = <FILE>;
	close(FILE);
	return processState(@lines);
}

sub processState {
	# Download state
	my ($line,$seq,$tstamp);
	my @lines = @_;
	for $line (@lines){
		chomp $line;
		$line =~ s/\\//g;
		if($line =~ /sequenceNumber=([0-9]+)/){ $seq = $1; }
		if($line =~ /timestamp=([0-9\-A-Z\:]+)/){ $tstamp = $1; }
	}
	return ($seq,$tstamp);
}

sub makedir {
	my $i;
	my $path = $_[0];
	my (@dirs) = split(/\//,$path);
	print "\tMaking directory $path\n";
	$path = "";
	for($i = 0; $i < @dirs; $i++){
		$path .= $dirs[$i]."/";
		if(!-d $path){
			`mkdir $path`;
		}
	}
}

sub getTimestamp {
	my $file = $_[0];
	my $timestamp = `$convert $file --out-timestamp`;
	$timestamp =~ s/[\n\r]//g;
	if($timestamp !~ /[0-9]{4}\-[0-9]{2}\-[0-9]{2}/){
		$timestamp = "";
	}
	return $timestamp;
}
