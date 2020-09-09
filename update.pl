#!/usr/bin/perl
################
# OSM tile layer updater.
# Created:      2020-07-27
# Last updated: 2020-08-07
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


my (%data,%zip,$i,$k,$v,$json,$jsonbit,$coder,$coderu,$str,$slice,$timestamp,$convert,$filter,$planet,$mode,$stats,$file,$filepbf,$filegeo,$ogr,@lines,$line,$tiler,%tiles,@types,$n,$zoom,$odir,$ini,@props,$p,$x,$y,$t,$feature,$tile,$ntiles,$progress);

my $datadir = $basedir."osm/";
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
	elsif($k eq "stats"){ $stats = $v; }
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
$progress->len(100);


$coder = JSON::XS->new->ascii->canonical(1);
$coderu = JSON::XS->new->utf8->canonical(1);
open(FILE,$basedir.".config");
$str = join("",<FILE>);
close(FILE);

$json = $coder->decode($str);




if($mode eq "info"){
	# Filter the main planet file to make each slice
	for $slice (sort(keys(%{$json->{'layers'}}))){
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
	for $slice (sort(keys(%{$json->{'layers'}}))){
		print "$slice:\n";
		if($json->{'layers'}->{$slice}{'make'}){
			$file = $datadir.$slice.".o5m";
			if(!-e $file){
				print "\t$file doesn't exist so we first need to make it from the planet file. Run:\n";
				print "\t$filter $planet --keep=\"$json->{'layers'}->{$slice}{'tags'}\" -v --drop-ways --drop-relations -o=$file\n";
				exit;
			}

			# At this point we want to update the cut-down version
			$timestamp = getPlanetUpdates($slice,$file,$json->{'layers'}->{$slice}{'tags'});

			
			# Now we convert the file type into one that ogr2ogr can deal with
			$filepbf = $datadir.$slice.".osm.pbf";
			$filegeo = $datadir.$slice.".geojson";


			if(!$json->{'layers'}->{$slice}{'skipdb'}){
				print "\tCreating GeoJSON output...\n";
				if(-e $filegeo){
					`rm $filegeo`;
				}
				`$convert $file -o=$filepbf`;
				`$ogr -overwrite --config $ini -skipfailures -f GeoJSON $filegeo $filepbf points`;
				# No need to spend time updating the timestamp by writing big files to disk
				#`sed -i 's/"crs": { "type": "name", "properties": { "name": "urn:ogc:def:crs:OGC:1.3:CRS84" } },/"lastupdate":"$timestamp",/g' $filegeo `;
			}

			$odir = ($json->{'osm-geojson'}||"./")."tiles/$slice/";
			$zoom = $json->{'layers'}->{$slice}{'zoom'}||12;
			if($odir && $json->{'layers'}->{$slice}{'tiles'}){

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
				print "\tSaving $n $slice in $ntiles tiles ($json->{'layers'}->{$slice}{'tags'})\n";
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
					#print FILE "\"lastupdate\": \"".$timestamp."\",\n";
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


if($stats || $mode eq "stats"){

	my (%Areas,$f,$adir,$ddir,$taglist,@tagarray,$t,@dirs,@countries,$cc,$dir,@files,$afile,$code,$area,$geojson,$bbfile,$clipfile,$spat,$nm,$waste,$recycling,$url);

	if(!$json->{'osm-geojson'} || ($json->{'osm-geojson'} && !-d $json->{'osm-geojson'})){

		print "ERROR: Your .config needs to contain \"osm-geojson\" which should be the path to the \"osm-geojson\" repository ($json->{'osm-geojson'}).\n";
		exit;

	}else{

		# Find sub directories in areas folder
		@dirs = ();
		$ddir = $json->{'osm-geojson'}."boundaries/";
		print "$ddir\n";

		opendir (DIR,$ddir) or die "Couldn't open directory, $!";
		while ($cc = readdir DIR){
			if(-d $ddir.$cc && -d $ddir.$cc && $cc !~ /^\.+$/){
				#push(@countries,{ 'dir'=>$ddir$cc,'code'=>$file});
				print "$cc\n";
				opendir(SUBDIR,$ddir.$cc) or die "Couldn't open directory, $!";
				while($file = readdir SUBDIR){
					if($file =~ /^(.*).geojson/){
						$code = $1;
						$bbfile = $ddir.$cc."/".$1.".yaml";
						$clipfile = $ddir.$cc."/".$file;
						$spat = "";
						$nm = "";
						if(-e $bbfile){
							open(BOUNDS,$bbfile);
							@lines = <BOUNDS>;
							close(BOUNDS);
							foreach $line (@lines){
								$line =~ s/[\n\r]//g;
								if($line =~ /BOUNDS: +(.*)/){
									$spat = "-spat $1";
								}elsif($line =~ /NAME: +(.*)/){
									$nm = $1;
								}
							}
							#print "\tUsing $spat for $nm\n";
						}else{
							print "\tNo spatial bounds provided for $code (this may be slow)\n";
						}
						
						push(@files,{'code'=>$code,'geojson'=>$clipfile,'cc'=>$cc,'yaml'=>$bbfile,'bounds'=>$spat,'name'=>$nm});
					}
				}
				closedir(SUBDIR);
			}
		}
		closedir(DIR);

		for $slice (sort(keys(%{$json->{'layers'}}))){
			print "$slice:\n";
			
			if($json->{'layers'}->{$slice}{'stats'}){

				undef %Areas;
			
				$filepbf = $datadir.$slice.".osm.pbf";

				$adir = $json->{'osm-geojson'}."areas/$slice/";
				if(!-d $adir){
					print "Making $adir\n";
					`mkdir $adir`;
				}
				
				$taglist = $json->{'layers'}->{$slice}{'tags'};
				$taglist =~ s/(^|\s)[^\s]*\=/ /g;
				@tagarray = split(" ",$taglist);

				for($f = 0; $f < @files; $f++){

					$file = $adir.$files[$f]{'cc'}."/".$files[$f]{'code'}.".geojson";

					print "Processing $files[$f]{'cc'}/$files[$f]{'code'} - $files[$f]{'name'}\n";
					print "\tOutput = $file\n";
					print "\tBoundary file = $files[$f]{'geojson'}\n";
					print "\tBounds = $files[$f]{'bounds'}\n";

					# Remove any existing version
					if(-e $file){ `rm $file`; }
					`ogr2ogr -f GeoJSON $file $files[$f]{'bounds'} -clipsrc "$files[$f]{'geojson'}" -skipfailures $filepbf points`;

					$code = $files[$f]{'code'};
					$cc = $files[$f]{'cc'};
					$nm = $files[$f]{'name'};
					$Areas{$code} = {'cc'=>$cc,'name'=>$nm,'total'=>0,'tags'=>{}};
					for($t = 0; $t < @tagarray; $t++){
						$Areas{$code}{'tags'}{$tagarray[$t]} = 0;
					}

					$geojson = "";
					open(GEO,$file);
					while(<GEO>){
						$line = $_;
						for($t = 0; $t < @tagarray; $t++){
							if($line =~ /\"$tagarray[$t]\\\"/){
								$Areas{$code}{'tags'}{$tagarray[$t]}++;
								$Areas{$code}{'total'}++;
							}
						}
						$geojson .= $line;
					}
					close(GEO);

					# Tidy GeoJSON to remove nulls
					$geojson =~ s/\, \"[^\"]+\": null//g;

					# Save the cleaned GeoJSON
					open(GEO,">",$file);
					print GEO $geojson;
					close(GEO);

					for($t = 0; $t < @tagarray; $t++){
						print "\t$tagarray[$t] = $Areas{$code}{'tags'}{$tagarray[$t]}\n";
					}

				}

				# Print summary stats
				open(CSV,">",$adir."stats.csv");
				open(HTML,">",$adir."stats.txt");
				print CSV "Country,Area ID,Name,Total";
				print HTML "<table><tr><th>Country</th><th>Area</th><th>Name</th><th>Total</th>";
				for($t = 0; $t < @tagarray; $t++){
					print CSV ",".$tagarray[$t];
					print HTML "<th>".$tagarray[$t]."</th>";
				}
				print CSV "\n";
				print HTML "</tr>";
				$url = "https://github.com/odileeds/osm-geojson/tree/master/areas/$slice/";
				foreach $area (reverse(sort{ $Areas{$a}{'total'} <=> $Areas{$b}{'total'} or $Areas{$a}{'name'} cmp $Areas{$b}{'name'} }(keys(%Areas)))){
					print CSV $Areas{$area}{'cc'}.",$area,";
					print HTML "<tr><td>$Areas{$area}{'cc'}</td><td><a href=\"$url$Areas{$area}{'cc'}/$area.geojson\">$area</a></td>";
					if($Areas{$area}{'name'}){
						print CSV ($Areas{$area}{'name'} =~ /\,/ ? "\"$Areas{$area}{'name'}\"" : $Areas{$area}{'name'});
						print HTML "<td><a href=\"$url$Areas{$area}{'cc'}/$area.geojson\">$Areas{$area}{'name'}</a></td>";
					}
					print CSV ",".$Areas{$area}{'total'};
					print HTML "<td>$Areas{$area}{'total'}</td>";
					for($t = 0; $t < @tagarray; $t++){
						print CSV ",".$Areas{$area}{'tags'}{$tagarray[$t]};
						print HTML "<td>$Areas{$area}{'tags'}{$tagarray[$t]}</td>";
					}
					print CSV "\n";
					print HTML "</tr>\n";
				}
				print HTML "</table>";
				close(CSV);
				close(HTML);

			}
			
		}

	}
	
}

# Zip up the files
zipFiles();

# Remove lock file
`rm $basedir.osm_lock`;





##########################
sub zipFiles {
	my ($cfile);
	foreach $cfile (sort(keys(%zip))){
		if(!-e "$cfile.gz"){
			print "\tZipping file back up ($cfile)\n";
			`gzip "$cfile"`;
		}else{
			print "\t$cfile.gz is zipped\n";
		}
	}
}

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
						$zip{$cfile} = 1;
					}
					print "-> $seq, $tstamp ".getPlanetBaseUrlFromState($seq).".osc\n";
					# Now we need to filter the change file
					if(!-e $sfile){
						print "\tFiltering $cfile to $sfile.\n";
						`$filter $cfile --keep="$tags" -v --drop-ways --drop-relations -o=$sfile`;
					}
					# This step is now done afterwards to avoid unzip/zip steps
					#if(!-e "$cfile.gz"){
					#	print "\tZipping file back up ($cfile)\n";
					#	`gzip "$cfile"`;
					#}else{
					#	print "\t$cfile.gz is zipped\n";
					#}
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
