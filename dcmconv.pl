#!/usr/bin/perl

# dcmconv.pl
#
# This perl script downloads images from a DICOM server and saves them in 
# either DICOM, Analyze or Nifti-1 format.
# It uses a C-FIND to aid selection and C-GET to perform the download.
# Supported UIDs for Storage are listed near the top of the code (at time of 
# writing CT, MR, PET, SC).
#
# Depending on the value of -level, the code will attempt to sort the dicom
# files into 3-D, 4-D or 5-D files. 
# 
# Verbose level 1 will report warnings of potentially missing files, or any
# difficulties that the script is having interpreting the headers. If 
# in difficulties, reduce the value of the level option which will make the
# script do less interpretation. If it still drops images (and there is no
# problem with the original number), then output as file type "DICOM" and 
# look at the headers manually.
# 
# Guy Williams					8/12/05
#
use lib "/app/AnalyzeTools/perllibs"; 

use DICOM::Transaction; 
use DICOM::PresContext; 
use DICOM::DICOMObject; 
use Data::Struct::Analyze; 
use Data::Struct::Nifti; 
use Getopt::Long;
use Sys::Hostname;
use Math::MatrixReal;

use POSIX;

my %options; 

#Default options
#$options{remoteae} 		= "WBICProxy"; 
$options{localae} 		= (split /\./, hostname())[0];  # . "_IJ"; 
$options{remoteip} 		= "dicom1"; 
$options{ssl} 			= 1; 
$options{tcp_port}		= 104; 
$options{ssl_port}		= 2761; 
$options{misc}	 		= 1; 
$options{verbose} 		= 1; 
$options{level} 		= 3; 
$options{anon}			= 0;
$options{txthdr} 		= 0; 
$options{outtype} 		= "nifti";
$options{orient}		= 0; 	# 0==neurological, 1=radiological 

if (@ARGV==0) { show_syntax( $0, \%options ); exit; }

GetOptions( \%options, 
	"date=s", "id=s", "name=s", 
	"studyuid=s", "studydes=s", 
	"remoteae=s", "localae=s", 
	"accnum=s", "outdir=s", 
	"outtype=s", "level=i", 
	"verbose=i", "silent+", 
	"remoteip=s", "port=i", 
	"count!", "all!", "info!",
	"indir=s", "txthdr!",
	"radio!", "neuro!", 
	"ssl!", "anon!",
	"makedir!", "dicomdir=s" ); 

#Complain if remoteae, indir & dicomdir are all not set 
if ((! defined $options{remoteae}) && (! defined $options{indir}) && (! defined $options{dicomdir})) { 
	print STDERR "A remote AE title must be selected using -remoteae AETITLE\n";
	show_syntax( $0, \%options );
	exit;
}

#Set port to automatic choices if not set
if (! defined $options{port}) { 
	$options{port} = ($options{ssl}) ? $options{ssl_port} : $options{tcp_port}; 
}

#Perform sanity check on the options
$options{type} = set_output( $options{outtype} );
if ($options{silent}) { $options{verbose} = 0; }
if ($options{level} > 4) { 
	print STDERR "Level must be between 0 and 4!\n"; 
	show_syntax( $0, \%options ); 
	exit; 
}
if ($options{radio} && $options{neuro}) { 
	print STDERR "-neuro and -radio flags cannot both be set!\n";
	show_syntax( $0, \%options );
	exit;
}
if ($options{neuro}) { 
	$options{orient} = 0;
}
if ($options{radio}) { 
	$options{orient} = 1;
}
# If the output is a nifti-compliant image, make it radiological
# since FSL (3.3) can only reliably process radiological images. 
#if ($options{type} > 1) { 
#	$options{orient} = 1;
#}
my $usefiles = 0; 
if (defined $options{indir}) { 
	if (defined $options{remoteae}) { 
		print STDERR "-indir and -remoteae cannot both be defined!\n"; 
		exit;	
	}
	if (defined $options{dicomdir}) { 
		print STDERR "-indir and -dicomdir cannot both be defined!\n"; 
		exit;	
	}
	$usefiles = 1; 
}
if (defined $options{dicomdir}) { 
	if (defined $options{remoteae}) { 
		print STDERR "-dicomdir and -remoteae cannot both be defined!\n"; 
		exit;	
	}
	$usefiles = 2; 
}

#Initialise the DICOM link
my $link = new DICOM::Transaction ( 'LocalAE' => $options{localae}, 
                      'RemoteAE' => $options{remoteae}, 
		      'RemoteIP' => $options{remoteip}, 
		      'Port' => $options{port},
		      ($options{ssl}) ? ('SSL' => 1, 'UseCert' => 1) : ''  ); 

#Set required Presentation Contexts
$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.1.2" );	# CT Image Storage
$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.1.4" ); 	# MR Image storage
$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.1.4.2" ); 	# MR Spectroscopy storage
$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.1.128" ); 	# PET Image storage
$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.1.7" ); 	# SC Image storage
$link->add_prescontext( AbsSyntax => "1.3.12.2.1107.5.9.1" ); 		# CSA Non-Image storage
$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.1.88.22" );	# SR storage

$link->add_prescontext( AbsSyntax => "1.2.840.10008.5.1.4.1.2.2.3" ); 	# Study Root C-GET

# Perform search and selection (if -all option not set)
my ($uids_to_get, $series_info, $all_images); 

if ($usefiles==1) { 
	($all_images, $series_info) = load_dir( $options{indir} ); 
	my @uids = ( keys %{$all_images} );
	$uids_to_get = \@uids;
} else { 
	($uids_to_get, $series_info) = search_dicomserver( $link, \%options );
}

# Generate unique filestems for the downloads
my ($filestems) = make_filestems( $uids_to_get, $series_info, \%options ); 
print "\n"; 

#Reconnect to server for download
if (!$usefiles) { 
	if (! $link->connect() ) { die "Association rejected!"; } 
}

# call download_series for each... 
#while ( my ($series, $fname) = each(%{$filestems}) ) { 
foreach my $series (@{$uids_to_get}) { 
	my $fname = $filestems->{$series};

	my $images; 
	if ($usefiles==1) { 
		$images = $all_images->{$series}; 
	} elsif ($usefiles==2) { 
		my ($some_ims, $dummy) =  load_files( @{$series_info->{$series}->{images}} );
		$images = $some_ims->{$series};	
	} else { 
		$images = download_series( $link, $series, \%options );
	}
#	my $images = ($usefiles) ? 
#		$all_images->{$series} :
#		download_series( $link, $series, \%options );
	write_series( $images, $fname, \%options );
}

# Close connection
if (!$usefiles) { 
	$link->close(); 
} 

sub dicomdircontents { 
# Parse the DICOMDIR file and return an array containing summary contents
#
# Inputs: 	1. DICOMDIR filename
# Outputs:	1. An array of hashes containing study details
#
	my $dicomdir = shift;
	my $dicomobj = new DICOM::DICOMObject( $dicomdir ); 

	if (! $dicomobj) { 
		print "Can't read DICOMDIR!!\n"; 
		return ();
	}

	my $stem = $dicomdir; 
	if ($stem !~ m#^/#) { $stem = "./$stem"; }
	($stem) = ($stem =~ m#(.*)/.*#);

	my $items = $dicomobj->get_element('0004', '1220');
	if (! defined $items) { return (); }
	
	my @output;
	my $patptr; 
	my $stuptr; 
	my $serptr;
	foreach my $entry (@{$items}) {
		my $type = $entry->get_element('0004', '1430');
		if ($type eq "PATIENT ") {
			my %patlevel;
			$patlevel{name} = $entry->get_element('0010', '0010');
			$patlevel{patid} = $entry->get_element('0010', '0020');
			$patlevel{birth} = $entry->get_element('0010', '0030');
			$patlevel{sex} = $entry->get_element('0010', '0040');
			$patptr = \%patlevel;
		} elsif ($type eq "STUDY ") {
			my %stulevel;
			$stulevel{date} = $entry->get_element('0008', '0020');
			$stulevel{studydes} = $entry->get_element('0008', '1030');
			$stulevel{accnum} = $entry->get_element('0008', '0050');
			$stulevel{studyuid} = $entry->get_element('0020', '000d');
			# Since we want are looking at study level search, merge patient data
			$stulevel{name} = $patptr->{name};
			$stulevel{patid} = $patptr->{patid};
			$stulevel{birth} = $patptr->{birth};
			$stulevel{sex} = $patptr->{sex};

			$stuptr = \%stulevel;
			push @output, $stuptr;
		} elsif ($type eq "SERIES") {
			my %serlevel;
			$serlevel{modality} = $entry->get_element('0008', '0060');
			$serlevel{seriesdes} = $entry->get_element('0008', '103e');
			$serlevel{seriesno} = $entry->get_element('0020', '0011');
			$serlevel{seriesuid} = $entry->get_element('0020', '000e');
			$serptr = \%serlevel;
			push @{$stuptr->{series}}, $serptr;
		} elsif (($type eq "IMAGE ") || ($type eq "PRIVATE ")) {
			my $fname = $entry->get_element('0004', '1500');
			$fname =~ s#\\#/#g;
			
			push @{$serptr->{images}}, "$stem/$fname";
		}
	}
	return @output;
}

sub search_dicomserver { 
# Search the dicom server for the series which match the description in the options hash.
# If the -all option is not set, take input from STDIN to decide which series to select
#
# Inputs:	1. The DICOM Transaction object
# 
# Outputs: 	1.  a pointer to an array of series UIDs which should be downloaded
# 		2. A pointer to a hash containing scan ID information

	my $link = shift; 
	my $options = shift; 

	if (! $options->{dicomdir}) { 
		if (! $link->connect() ) { die $DICOM::Transaction::errstr; } 
		#/* "Association rejected!"; */ } 
	}

	my %qualifier = (	Date => $options->{date}, 
				PatID => $options->{id}, 
				PatName => $options->{name}, 
				StudyUID => $options->{studyuid},
				StudyDes => $options->{studydes}, 
				AccNum => $options->{accnum} 
	); 

	my @query_array = ( $options->{dicomdir} ) ? dicomdircontents( $options->{dicomdir} ) : 
		$link->dofind( Level => 'STUDY', %qualifier ); 

	if ( ! @query_array ) { 
		if (defined $DICOM::Transaction::errstr) { 
			die $DICOM::Transaction::errstr; 
		} else { 
			die "No Images!";	
		}
	}

	my @choices; 
	my %serlevel_tags; 

	print "     " . pack("A10",  "Patient ID") . " " . pack("A8", "Date") . " "; 
	print pack("A20", "Study Description") . " Acc. Number\n"; 

	my $i = 1;
	foreach my $indiv (@query_array) { 

		print pack("A5", $i); 
		print pack("A10", $indiv->{patid} ) . " "; 
		print pack("A8", $indiv->{date}) . " "; 
		print pack("A20", $indiv->{studydes}) . " "; 
		print pack("A16", $indiv->{accnum}); 
	
		if ( ! defined $options->{dicomdir} ) { 
			@series_query = $link->dofind( Level => 'SERIES', 
				StudyUID => $indiv->{studyuid} ); 
		} else { 
			@series_query = @{$indiv->{series}};	
		}
		@series_query = sort { $a->{seriesno} <=> $b->{seriesno} } @series_query;

		my %series_uids; 
		my $subselect = "a";	
		foreach my $series (@series_query) { 
			if ($options->{info}) { 
				if ($subselect ne "a") { 
					print "\n" . pack("A62", "");
				}
				print $subselect . ": " . pack("A3", $series->{seriesno}) . " " . pack("A24", $series->{seriesdes}); 
				if ($options->{count}) {
					my @image_query = ( ! defined $options->{dicomdir} ) ? 
						$link->dofind( Level => 'IMAGE', SeriesUID => $series->{seriesuid} ) :
						@{$series->{images}};
					print " (" . (scalar @image_query) . ")";
				}
			
			} else { 
				if ($options->{count}) { 
					my @image_query = ( ! defined $options->{dicomdir} ) ? 
						$link->dofind( Level => 'IMAGE', SeriesUID => $series->{seriesuid} ) : 
						@{$series->{images}}; 	
					print pack("A11", $subselect . ": " . $series->{modality} . "(" . (scalar @image_query). ") "); 
				} else { 
					print pack("A7", $subselect . ": " . $series->{modality} . ", "); 
				}
			}
			$series_uids{$subselect} = $series->{seriesuid}; 	
			$series->{patid} = $indiv->{patid};
			$series->{studydes} = $indiv->{studydes};
			$series->{date} = $indiv->{date};
			$series->{accnum} = $indiv->{accnum};

			$serlevel_tags{$series->{seriesuid}} = $series; 
			my $s1 = (length($subselect)==1) ? "" : substr($subselect, 0, 1);
			my $s2 = substr($subselect, length($subselect)-1, 1);
			if ($s2 eq "z") { $s2 = "A"; } 
			elsif ($s2 eq "Z") { $s1 = ($s1 eq "") ? "a" : chr((ord $s1)+1); $s2 = "a"; }
			else { $s2 = chr((ord $s2) + 1); } 
			$subselect = $s1 . $s2;	
			#$subselect = ($subselect eq "z") ? "A" : chr((ord $subselect) + 1); 	
		}
		push @choices, \%series_uids;	
		$i++;
		print "\n";
	}

	if (! defined $options->{dicomdir}) { $link->close(); } 

	if (scalar @query_array == 0) { die "No images!"; } 

	my @uids_to_get; 
	print "\n";
#if ((scalar @choices == 1) && (keys %{$choices[0]} == 1)) { 
#	$series_to_get[0] = $choices[0]{a};
#	$filenames[0] = $filestem;
	if ($options->{all}) { 
		for (my $i=0; $i<scalar @choices; $i++) { 
			foreach my $series (
				sort { ((" " . $a) =~ /(..)$/)[0] cmp ((" " . $b) =~ /(..)$/)[0] } 
					keys %{$choices[$i]}) { 
				push @uids_to_get, $choices[$i]{$series};	
			}
		}
	} else { 
		while (scalar @uids_to_get == 0) { 
			print "Enter choice : "; 
			my $choice = <STDIN>; 
			my @studies_to_get = split / /, $choice;
			foreach my $ser_choice (@studies_to_get) { 
				my ( $num, $series ) = ( $ser_choice =~ m/^(\d+)([a-zA-Z,]*)$/ ); 
				
				if ($num eq "") { 
					if (scalar @choices == 1) { 
						($series) = ( $ser_choice =~ m/([a-zA-Z,]*)$/ ); 
						if (defined $series) { 
							$num = 1; 
						} else { 
							$num = 0;
						}
					} else { 
						next; 
					}
				}
				if (($num == 0) || ( $num > @choices)) { next; }

				my $use_commas = ( (scalar keys %{$choices[$num-1]} > 52) || 
					($series =~ m/,/) ) ? 1 : 0;

				if ($series eq "") { 
					@series_to_get = sort { ((" " . $a) =~ /(..)$/)[0] cmp ((" " . $b) =~ /(..)$/)[0] }
						keys %{$choices[$num-1]}; 
				} else { 
					if ($use_commas) { 
						@series_to_get = split /,/, $series; 
					} else { 
						@series_to_get = split //, $series; 
					}
				}

			
				foreach (@series_to_get) { 
					if ( ! defined $choices[$num-1]{$_} ) { $num = ""; next; }
					push @uids_to_get, $choices[$num-1]{$_};  
				}
			}	
		}
	}

	return (\@uids_to_get, \%serlevel_tags);
}

#----------------------------------------------------------------------------------------------

sub make_filestems { 
# Work out unique filestems for each of the subjects to be downloaded
# Filestems are the patient ID in the first instances. If this is not unique,
# the date is appended. 
# If this is not unique, the accession number is used. Finally, if it is still 
# not unique, a single letter is appended to the filestem to make it so.
# 
# Inputs: 	1. A pointer to an array of uids to retrieve
# 		2. A hash containing header info for the series
# 		2. Options hash 
# Outputs:	1. A hash with UIDs for keys, and unique filestems as values
#
	my $uids_to_get = shift;
	my $series_info = shift;
	my $options = shift; 

	# Work out unique filestems
	my %uniq_filestems;
	my %id_sorted; 

	if ($options->{makedir}) { 
		for (my $i=0; $i < (scalar @{$uids_to_get}); $i++) {
			my $patid = $series_info->{ $uids_to_get->[$i] }->{patid};
			my $studat = $series_info->{ $uids_to_get->[$i] }->{date};
			my $sernum = $series_info->{ $uids_to_get->[$i] }->{seriesno};
			my $serdes = $series_info->{ $uids_to_get->[$i] }->{seriesdes};
			my $accnum = $series_info->{ $uids_to_get->[$i] }->{accnum};
			$patid =~ s/^ *//g;	$patid =~ s/ *$//g; 	$patid =~ s/ /_/g;
			$serdes =~ s/^ *//g;	$serdes =~ s/ *$//g; 	$serdes =~ s/ /_/g;
			$accnum =~ s/^ *//g;	$accnum =~ s/ *$//g; 	$accnum =~ s/ /_/g;

			my $serstem = sprintf("%s/%s_%s/Series_%03d_%s/DATA", 
				$patid, $studat, $accnum, $sernum, $serdes);
			
			# Check the directories exist
			my @serlist = split /\//, $serstem;
			pop @serlist;
			my $dir = ".";
			if ($options->{outdir}) { $dir = $options->{outdir} . "/"; }
			foreach (@serlist) { 
				$dir = "$dir/$_"; 
				if ( ! -d $dir ) { mkdir $dir; }	
			}
			$uniq_filestems{$uids_to_get->[$i]} = $serstem; 	
		}
		return (\%uniq_filestems);	
	}

	for (my $i=0; $i < (scalar @{$uids_to_get}); $i++) {
		my $patid = $series_info->{ $uids_to_get->[$i] }->{patid};
		$patid =~ s/\W//g; 	# Remove non-alphanumeric characters
		my $studyuid = $series_info->{ $uids_to_get->[$i] }->{studyuid};
		push @{$id_sorted{$patid}->{$studyuid}}, $uids_to_get->[$i]; 
	}
	foreach my $patid (keys %id_sorted) { 
		my @studies = keys %{$id_sorted{$patid}}; 
		if ((scalar @studies) == 1) { 
			foreach my $series (@{$id_sorted{$patid}->{$studies[0]}}) { 
				$uniq_filestems{$series} = $patid; 
			}
		} else { # We have more than one study for this patient
			# First, see if date separates them
			my %dates; 
			my %accnums; 
			my $prev_date; 
			my $prev_accnum; 
			my $are_same =0;
			foreach my $study (keys %{$id_sorted{$patid}}) { 
				my $ser = $id_sorted{$patid}->{$study}->[0];
				$dates{$ser} = $series_info->{ $ser }->{date};
				if (!defined $prev_date) { 
					$prev_date = $dates{$ser}; 
				} else { 
					if ($prev_date eq $dates{$ser}) { 
						$are_same = 1;
					}
				}
			}
			if ($are_same == 0) { 
				foreach my $study (keys %{$id_sorted{$patid}}) { 
					my $ser = $id_sorted{$patid}->{$study}->[0];
					foreach my $series (@{$id_sorted{$patid}->{$study}}) {
						$uniq_filestems{$series} = $patid . "_" . $dates{$ser}; 
					}
				}
				last; 	
			} 
			# Now try to sort on acc no.
			$are_same =0;
			foreach my $study (keys %{$id_sorted{$patid}}) { 
				my $ser = $id_sorted{$patid}->{$study}->[0];
				$acc_nums{$ser} = $series_info->{ $ser }->{accnum};
				$acc_nums{$ser} =~ s/\W//g; 	# Remove whitespace 
				if (!defined $prev_accnum) { 
					$prev_accnum = $accnum{$ser}; 
				} else { 
					if ($prev_accnum eq $acc_nums{$ser}) { 
						$are_same = 1;
					}
				}
			}
			if ($are_same == 0) { 
				foreach my $study (keys %{$id_sorted{$patid}}) { 
					my $ser = $id_sorted{$patid}->{$study}->[0];
					foreach my $series (@{$id_sorted{$patid}->{$study}}) {
						$uniq_filestems{$series} = $patid . "_" . $accnums{$ser}; 
					}
				}
				last; 	
			} 
			# Give up and give them an extra letter
			my $subselect = "a";
			foreach my $study (keys %{$id_sorted{$patid}}) { 
				foreach my $series (@{$id_sorted{$patid}->$study}) {
					$uniq_filestems{$series} = $patid . $subselect; 
				}
				$subselect = chr((ord $subselect) + 1); 	
			}
		}
	}

	return (\%uniq_filestems); 
}

sub sort_series { 
# Sort images within a series according to their pixel information, orientation, echo number
# and position. Produces a nested hash structure with this information within it
#
# Inputs:	1. A pointer to an array of DICOM images (sorted by instance number)
#
# Outputs:	1. A nested hash with all the images places within it
# 		2. A hash of perpendicular vectors for each orientation tag 
# 		2. A nested hash of positions with position as a 3 element array at the end 
# 		4. A hash of pixel information type, pointing to an array with image dimensions etc
# 		
# 		
	my $rawimages = shift; 
	my %image_series; 
	my %all_poses;
	my %all_perps;
	my %all_cals; 

	for (my $i=0; $i<scalar @{$rawimages}; $i++) { 
		my $slice =  $rawimages->[$i];
		if (! defined $slice) { next; }
		my $x = $slice->get_element( '0028', '0011' );  # No of Columns
		my $y = $slice->get_element( '0028', '0010' );  # No of Rows
		my $pix_spacing = $slice->get_element( '0028', '0030' );
		my ($xcal, $ycal) = ($pix_spacing =~ m/\s*([\d,.]+)\s*\\\s*([\d,.]+)/);
		my $bits_stored = $slice->get_element( '0028' , '0100' ); # Bits allocated 
		my $pix_rep = $slice->get_element( '0028' , '0103' ); # Pixel representation 
		my $photo_interp = $slice->get_element( '0028' , '0004' ); # Photo interpretation 
		$photo_interp =~ s/\W//g; 		# Remove non-alphanumeric characters
		my $plane_rep = $slice->get_element( '0028' , '0006' ); # Planar configuration 
		my $num_mosaic = 1;
		
		my $csa_tag = $slice->get_element( '0029', '1010' ) || undef; 
		my $csa_ptr;
		if (defined $csa_tag) { 
			$csa_ptr = parse_csa_header( $csa_tag ); 
			my $mos_ptr =  $csa_ptr->{NumberOfImagesInMosaic}; 
			if (scalar @{$mos_ptr} != 0) { 
				$num_mosaic = $mos_ptr->[0];
				if ($num_mosaic==0) { $num_mosaic=1; }	
			}
		}	
		my $num_in_row = int(ceil( sqrt $num_mosaic ));
		if ($num_mosaic != 1) { 
			$x = $x / $num_in_row;
			$y = $y / $num_in_row;
		}

		my $vdims = sprintf("%d-%d-%.3f-%.3f-%d-%d-%s-%d", $x,$y,$xcal,$ycal, 
			$bits_stored, $pix_rep, $photo_interp, $plane_rep);
		my $v_ptr = $image_series{$vdims};
		if (! defined $v_ptr) {
			$image_series{$vdims} = {}; 
			
			$v_ptr = $image_series{$vdims}; 
			my $zcal = $slice->get_element( '0018', '0050' ) || 0;  # Slice Thickness
			my $tcal = $slice->get_element( '0018', '0080' ) || 0.0; # TR 
			$tcal = $tcal / 1000.0; # (there are other headers such as ImageTime 
						# which could do this more reliably (for Siemens data)??
#			my $win_centre = $slice->get_element( '0028', '1050' ) || 0.0; # Window center
#			my $win_width = $slice->get_element( '0028', '1051' ) || 0.0; # Window width
#			my $cal_min = $win_centre - (0.5 * $win_width); 
#			my $cal_max = $win_centre + (0.5 * $win_width); 
			$all_cals{$vdims} = [ $x, $y, 0, $xcal, $ycal, $zcal, 
				$tcal, $bits_stored, $pix_rep, $photo_interp, $plane_rep, 0, 0 ];
		}
		# Choose the cal_max & cal_min from the slice with the largest range 	
		my $win_centre = $slice->get_element( '0028', '1050' ) || 0.0; # Window center
		my $win_width = $slice->get_element( '0028', '1051' ) || 0.0; # Window width
		my $cal_min = $win_centre - (0.5 * $win_width); 
		my $cal_max = $win_centre + (0.5 * $win_width); 
		if ($cal_max - $cal_min > $all_cals{$vdims}[12] - $all_cals{$vdims}[11] ) { 
			$all_cals{$vdims}[11] = $cal_min;
			$all_cals{$vdims}[12] = $cal_max;
		}
		
		my $orient_tag = $slice->get_element( '0020', '0037' ) || "null";
	##	my (@image_or) =
#			($orient_tag =~ m/\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)\s*/);
		my (@image_or) = split /\\/, $orient_tag;	
		foreach(@image_or) { $_ = (abs $_ < 0.0005) ? 0.0 : $_; } # Prevent -0.000 values 
		$orient_tag = sprintf("%.3f\\%.3f\\%.3f\\%.3f\\%.3f\\%.3f", @image_or);	
		my $o_ptr = $v_ptr->{$orient_tag};
		if (! defined $o_ptr) {
			$v_ptr->{$orient_tag} = {}; 
			my @perp;
			for (my $i=0; $i<6; $i++) { 
				$image_or[$i] = eval $image_or[$i];
			}
			my $norm_ptr; 
			if (defined $csa_ptr) { 
				$norm_ptr = $csa_ptr->{SliceNormalVector}; 
				if (scalar @{$norm_ptr} == 3) { 
					$perp[0] = eval $norm_ptr->[0];
					$perp[1] = eval $norm_ptr->[1];
					$perp[2] = eval $norm_ptr->[2];
				}
			}
			if (! defined $perp) { 
				$perp[0] = ($image_or[1] * $image_or[5]) - ($image_or[2] * $image_or[4]); 
				$perp[1] = ($image_or[2] * $image_or[3]) - ($image_or[0] * $image_or[5]); 
				$perp[2] = ($image_or[0] * $image_or[4]) - ($image_or[1] * $image_or[3]); 
			}
			$o_ptr = $v_ptr->{$orient_tag};
			$all_perps{$vdims}->{$orient_tag} = [ [ @image_or[0..2] ], [ @image_or[3..5] ], \@perp ];	
		}
		
		my $echo = eval $slice->get_element( '0018', '0086' ) || 0;	#Echo Number
		my $e_ptr = $o_ptr->{$echo}; 
		if (! defined $e_ptr ) { 
			$o_ptr->{$echo} = {};
			$e_ptr = $o_ptr->{$echo}; 
		}

		my $pos_tag = $slice->get_element( '0020', '0032' ) || "null";
		my (@image_pos) = ($pos_tag =~ m/\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)\s*\\\s*(-?[\d,.]*)/ );
		foreach(@image_pos) { if (abs $_ < 0.0005) { $_ = 0.0; } } # Prevent -0.000 values 
		
		for (my $k=0; $k<3; $k++) { 
			$image_pos[$k] = eval $image_pos[$k];	
		}
		if ($num_mosaic != 1) { 
			for (my $k=0; $k<3; $k++) { 
				$image_pos[$k] += $xcal*($num_in_row-1)*$image_or[$k] * $x / 2.0;
				$image_pos[$k] += $ycal*($num_in_row-1)*$image_or[$k+3] * $y / 2.0;
			}
		}
		
		for (my $k=0; $k<$num_mosaic; $k++) { 
			my @mod_pos;
			my $zcal = $slice->get_element( '0018', '0088' ) ||  # Spacing between slices
					$all_cals{$vdims}->[5];
			for (my $kk=0; $kk<3; $kk++) { 
				my $pfac = $all_perps{$vdims}->{$orient_tag}->[2]->[$kk];
				$mod_pos[$kk] = $image_pos[$kk] + ($zcal * $k * $pfac);
			}

			$pos_tag = sprintf("%.3f\\%.3f\\%.3f", @mod_pos);

			if (! defined $e_ptr->{$pos_tag} ) { 
			
				$e_ptr->{$pos_tag} = ();
				my @pos; 
				$pos[0]= eval $mod_pos[0];
				$pos[1]= eval $mod_pos[1];
				$pos[2]= eval $mod_pos[2];
				$all_poses{$vdims}->{$orient_tag}->{$pos_tag} = \@pos;
			}
			push @{$e_ptr->{$pos_tag}}, ($num_mosaic==1) ? $i : ($i + (($k+1)/1000));
		}	
	}
#	print "SORTED: " . (scalar (keys  %image_series) ) . "\n"; 
#	foreach my $k (keys %image_series) { 
#		print "0: $k " . (scalar (keys %{$image_series{$k}})) . "\n";
#		foreach my $kk (keys %{$image_series{$k}}) { 
#			print "1: $kk " . (scalar (keys %{$image_series{$k}->{$kk}})) . "\n";
#			foreach my $kkk (keys %{$image_series{$k}->{$kk}}) { 
#				print "2:  $kkk " . (scalar (keys %{$image_series{$k}->{$kk}->{$kkk}})) . "\n";
#				foreach my $kkkk (keys %{$image_series{$k}->{$kk}->{$kkk}}) { 
#					print "3:   $kkkk " . (scalar @{$image_series{$k}->{$kk}->{$kkk}->{$kkkk}}) . "\n";
#				}
#			}
#		}
#	}		
	
	return ( \%image_series, \%all_perps, \%all_poses, \%all_cals );
}	

sub order_by_instance_no { 
# Does an initial sort based on instance number and retrieves some header info
#
# Inputs:	1. Pointer to an array of DICOM images
# 		2. Pointer to the command line options hash 
#
# Outputs:	1. Pointer to a hash containing one array per series UID. The array
# 			is positioned according to instance number (so may have gaps)
# 		2. The same structure but pointer to an 2 element array with the rescale
# 			intercept and slope.
# 		3. Various other Series Header Info
# 		
	my $images = shift; 
	my $options = shift;
	my %output;
	my %rescales;
	my %info; 

	my %series_degen;
	my %image_counts;
	# First do a check for degeneracy in the image numbers
	# some siemens headers do not have unique instance no.s
	for (my $i=0; $i<scalar @{$images}; $i++) {
# 		if ($options{anon}) { 
# 			$images->[$i]->add_element( '0010', '0010', "Anonymous" ); # Patient Name
# 			$images->[$i]->add_element( '0010', '0030', "00000000" ); # BirthDate 
# 			$images->[$i]->add_element( '0010', '1010', "00Y" ); # Age 
# 			$images->[$i]->add_element( '0010', '1030', "0.00" ); # Weight 
# 			$images->[$i]->add_element( '0010', '1040', "" ); # Address  
# 			$images->[$i]->add_element( '0010', '1090', "" ); # Record locator  
# 			$images->[$i]->add_element( '0010', '2154', "" ); # Phone Numbers  
# 		}
		my $seriesuid = $images->[$i]->get_element( '0020', '000e' ); # Series UID
		if ($seriesuid eq "") { 
			# Bizarre.... empty image returned?
			next;
		}
		if (! defined $output{$seriesuid} ) { 
			$output{$seriesuid} = [];
			$rescales{$seriesuid} = [];
			$image_counts{$seriesuid} = [];
			my $patid = $images->[$i]->get_element( '0010', '0020' ); # Patient ID
			$patid =~ s/\W//g; 		# Remove non-alphanumeric characters
			my $series_num = $images->[$i]->get_element( '0020', '0011' ); # Series ID
			my $series_des = $images->[$i]->get_element( '0008', '103e' ); # Series Descrip 
			my $series_date = $images->[$i]->get_element( '0008', '0021' ); # Series Date 
			my $series_time = $images->[$i]->get_element( '0008', '0031' ); # Series Time 
			my $class_uid = $images->[$i]->get_element( '0008', '0016' ); # Class UID 
			($class_uid) = ($class_uid =~ m/([\d\.]*)/);
			$info{$seriesuid} = { 'PatID' => $patid, 
						'SeriesNum' => $series_num,
						'SeriesDescrip' => $series_des, 
						'SeriesDate' => $series_date, 
						'SeriesTime' => $series_time,
						'ClassUID' => $class_uid };	
		}
		my $imageno = $images->[$i]->get_element( '0020', '0013' ); 	# Instance Number
		my $echono = eval $images->[$i]->get_element( '0018', '0086' ) || 0;	# Echo Number
		if (defined $image_counts{$seriesuid}->[$imageno]) { 
			if (grep { /^${echono}$/ } @{$image_counts{$seriesuid}->[$imageno]}) { 
				if ($options->{verbose}) {
					print "Image $imageno has a duplicate in this series! Unpredictable results\n";
				}
#			} else { 
			}
				push @{$image_counts{$seriesuid}->[$imageno]}, $echono; 	
#			}
		} else { 
			$image_counts{$seriesuid}->[$imageno] = [];	
			push @{$image_counts{$seriesuid}->[$imageno]}, $echono; 	
		}
	}
	foreach my $seriesuid (keys %image_counts) { 
		$series_degen{$seriesuid} = 1;
		foreach (@{$image_counts{$seriesuid}}) { 
			my $dup_count = scalar @{$_}; 
			if ($dup_count > $series_degen{$seriesuid}) { $series_degen{$seriesuid} = $dup_count; }
		}
		$image_counts{$seriesuid} = [];	
	}
	
	for (my $i=0; $i<scalar @{$images}; $i++) { 
		my $seriesuid = $images->[$i]->get_element( '0020', '000e' ); # Series UID
		
		my $imageno = $images->[$i]->get_element( '0020', '0013' ); 	# Instance Number
		if ($imageno eq "") { 
			# Bizarre.... empty image returned?
			next;
		}
		my $r_int = $images->[$i]->get_element( '0028', '1052' ) || 0; # Rescale Intercept 
		my $r_slope = $images->[$i]->get_element( '0028', '1053' ) || 1; # Rescale Slope 
		
		my $echono = eval $images->[$i]->get_element( '0018', '0086' ) || #0;	# Echo Number
			($image_counts{$seriesuid}->[$imageno]++) || 0; 
		if ($series_degen{$seriesuid} != 1) { 
			$imageno = ($series_degen{$seriesuid} * $imageno) + $echono;
		} 	# recreate imageno allowing space for duplicate echos if needed 
		$output{$seriesuid}->[$imageno] = $images->[$i]; 
		$rescales{$seriesuid}->[$imageno] = [ $r_int, $r_slope ]; 
	}
	if ($options->{verbose}) { # Now check for missing images
		foreach my $series (keys %output) { 
			my $min = 0; 
			for (my $i=0; $i<scalar @{$output{$series}}; $i++) { 
				if (defined $output{$series}->[$i]) { $min = 1; }
				else { 
					if ($min) { 
						print "Image $i missing. May cause problems later\n";
					}
				}
			}
		}
	}
	return (\%output, \%rescales, \%info ); 
}
	
sub download_series { 
# Download the specified series with the specified file stem. 
#
# Inputs:	1. The DICOM Transaction Object
# 		2. The Series UID to retrieve
# 		3. Options hash (contains level number, verbosity, filetype etc)
# Outputs:	1. A pointer to an array of DICOM Objects
#
	my $link = shift;
	my $seriesuid = shift; 
	my $filestem = shift;
	my $options = shift; 

	my $callbk = sub { 
		if ($options{verbose} == 0) {return; }
		$| = 1;
		printf("%7d complete %7d remaining", $_[2], $_[1]); 
		if ($_[3] !=0 ) { printf(" %d failed", $_[3]); } 
		if ($_[4] !=0 ) { printf(" %d warnings", $_[4]); } 
		printf("\r");
	};
	my @getimage = $link->doget( Callback => $callbk, SeriesUID => $seriesuid ); 
	print "\n"; 
	if (scalar @getimage == 0) { die "No images!"; } 
	
	return \@getimage; 
}

sub write_series { 
#Output the given series
#
# Inputs:	1. The DICOM Objects to write 
# 		2. The filestem (series number will be appended). 
# 		3. Options hash (contains level number, verbosity, filetype etc)
# Outputs:	None
#
	my $getimage = shift;
	my $filestem = shift; 
	my $options = shift; 

#	my ($simage, $rescales, $info) = order_by_instance_no( \@getimage );
	my ($simage, $rescales, $info) = order_by_instance_no( $getimage, $options );
	
	my $level = $options->{level}; 

	foreach my $uid (keys %{$simage}) { 
		my $patid = $info->{$uid}{PatID}; # $all_ids->{$uid};
		my $series_no = $info->{$uid}{SeriesNum}; # $all_series_nos->{$uid};
		my $uinfo = $info->{$uid}; 
		my $file_ser_stem = sprintf("%s_%.4d", $filestem, $series_no);
		my $announceCSA = 0;
		my $announceSpec = 0;
		my $announceSR = 0;
		
		my $outformat = $options{type};
		if ($info->{$uid}{ClassUID} eq "1.3.12.2.1107.5.9.1") { 
			if (($options{type} != 0) && ($options{verbose})) { 
#				print "Outputing Siemens CSA data in dicom format\n"; 	
			}
#			$announceCSA = 1;
			$outformat = 0; 
		}
		if ($info->{$uid}{ClassUID} eq "1.2.840.10008.5.1.4.1.1.4.2") { 
			if (($options{type} != 0) && ($options{verbose})) { 
#				print "Outputing spectroscopy data in dicom format\n"; 	
			}
#			$announceSpec = 1;
			$outformat = 0; 
		}
		if ($info->{$uid}{ClassUID} eq "1.2.840.10008.5.1.4.1.1.88.22") { 
			if (($options{type} != 0) && ($options{verbose})) { 
#				print "Outputing structured report data in dicom format\n"; 	
			}
#			$announceSR = 1;
			$outformat = 0; 
		}
		if ($outformat == 0) { 
			if ($options{verbose}) { 
				print "Writing dicom files with filestem $file_ser_stem\n"; 
			}
			for (my $i=0; $i<scalar @{$simage->{$uid}}; $i++) { 
				if (! defined $simage->{$uid}->[$i]) { next; }
				my $filename = sprintf("%s_%.5d.dcm", $file_ser_stem, $i); 
				if (defined $options{outdir}) { 
					$filename = $options{outdir} . "/$filename";
				}
				unless (open (DCMIMAGE, ">$filename")) { 
					print STDERR "Can't write $filename\n";
					next;
				}
				delete $simage->{$uid}->[$i]->{'0002'};	# Remove group 0002 as matlab fails
				if ($options{verbose}) { 
					my $class_uid = $simage->{$uid}->[$i]->get_element( '0008', '0016' ); # Class UID
					($class_uid) = ($class_uid =~ m/([\d\.]*)/);
					if (($class_uid eq "1.3.12.2.1107.5.9.1") && ($announceCSA==0)) { 
						print "Outputing Siemens CSA data in dicom format\n";
						$announceCSA = 1;
					}
					if (($class_uid eq "1.2.840.10008.5.1.4.1.1.4.2") && ($announceSpec==0)) { 
						print "Outputing spectroscopy data in dicom format\n";
						$announceSpec = 1;
					} 
					if (($class_uid eq "1.2.840.10008.5.1.4.1.1.88.22") && ($announceSR==0)) { 
						print "Outputing structured report data in dicom format\n";
						$announceSR = 1;
					} 
				}	
				$simage->{$uid}->[$i]->write(*DCMIMAGE); 
				close DCMIMAGE;
			}
			next;
		}
		my ($sorted_set, $perp_vectors, $pos_vectors, $all_cals ) = sort_series( $simage->{$uid} );

		my $subselect = "";
		foreach my $samedims (keys %{$sorted_set}) { 
			my $cals = $all_cals->{$samedims}; 
			if ((keys %{$sorted_set}) != 1) { 
				$subselect = ($subselect eq "") ? "a" : chr((ord $subselect) + 1); 	
			} 
			# If completely dumb, do vols as 3d here, else
			if ($level == 0) { 
				my @image_nos; 
				foreach my $orient (keys %{$sorted_set->{$samedims}}) {
					foreach my $echo (keys %{$sorted_set->{$samedims}->{$orient}}) {
						foreach my $pos (values %{$sorted_set->{$samedims}->{$orient}->{$echo}}) { 
							foreach (@{$pos}) { 
								push @image_nos, $_; 
							}
						}
					}
				}
				@image_nos = sort { $a <=> $b } @image_nos; 
				my $filename = sprintf("%s%s", $file_ser_stem, $subselect);
				write_volume( $filename, [ [ \@image_nos ] ], $simage->{$uid}, $cals, $rescales->{$uid}, $options, $uinfo );
				next;
			}
			foreach my $orient (keys %{$sorted_set->{$samedims}}) {
				# If pretty dumb, do subset of vols as 3d here with marker letter
				if ((keys %{$sorted_set->{$samedims}}) != 1) { 
					$subselect = ($subselect eq "") ? "a" : chr((ord $subselect) + 1); 	
				} 
				if ($level == 1) { 
					my @image_nos; 
					foreach my $echo (keys %{$sorted_set->{$samedims}->{$orient}}) {
						foreach my $pos (values %{$sorted_set->{$samedims}->{$orient}->{$echo}}) { 
							foreach (@{$pos}) { 
								push @image_nos, $_; 
							}
						}
					}
					@image_nos = sort { $a <=> $b } @image_nos; 
					my $filename = sprintf("%s%s", $file_ser_stem, $subselect);
					write_volume( $filename, [ [ \@image_nos ] ], $simage->{$uid}, $cals, $rescales->{$uid}, $options, $uinfo );
					next;
				}
				my @full_vols; 
				my $perp_vec = $perp_vectors->{$samedims}->{$orient};
				
				# If the output format is radiological, we need the determinant of the 
				# sform matrix to be negative (to do this we flip the normal vector which
				# is used in calculating the slice positions).
				if ($options{orient}) {
					for (my $i=0; $i<3; $i++) { 
						$perp_vec->[2]->[$i] = -1 * $perp_vec->[2]->[$i]; 
					}
				}
				my $pos_vecs = $pos_vectors->{$samedims}->{$orient}; 
				my ($validity, $gap, $pos_array) = order_positions( $pos_vecs, $perp_vec->[2], $cals ); 
				if ($options{verbose} == 2) { 
					if ($validity == 1) { 
						print "WARNING: This appears not to be contiguous.\n"; 
					} elsif ($validity == 2) { 
						print "WARNING: This volume has uneven slice thickness.\n"; 
					} elsif ($validity == 3) { 
						print "WARNING: This volume is not cuboidal.\n"; 
					}
					#print "VALIDITY $validity (gap $gap)\n";	
				}
				$cals->[5] = $gap;
				if ($validity>1) { 	
					undef $perp_vec; 
				} else { 
					my $first_slice = $pos_array->[0];
					$perp_vec->[3] = $pos_vecs->{$first_slice};
				}

				my @full_vols; 
				foreach my $echo (keys %{$sorted_set->{$samedims}->{$orient}}) { 
					$full_vols[$echo] = 
						sort_into_vols( $sorted_set->{$samedims}->{$orient}->{$echo}, 
							$pos_array, $options );	
				}
				while (! defined $full_vols[0]) { shift @full_vols; } 
				my $nechos = scalar @full_vols; 
				
				if ($level == 4) { 	# 5D file
					my $filename = sprintf("%s%s", $file_ser_stem, $subselect);
					write_volume( $filename, \@full_vols, $simage->{$uid}, $cals, $rescales->{$uid}, $options, $uinfo, $perp_vec );
				} elsif ($level == 3) { # 4D files
					for (my $i=0; $i<$nechos; $i++) { 
						if (! defined $full_vols[$i]) { next; }
						my $filename = ($nechos==1) ? 
							sprintf("%s%s", $file_ser_stem, $subselect) : 
							sprintf("%s%s_echo%.2d", $file_ser_stem, $subselect, $i); 
						write_volume( $filename, [ $full_vols[$i] ], $simage->{$uid}, $cals, $rescales->{$uid}, $options, $uinfo, $perp_vec );
					}
				} elsif ($level == 2) { # 3D files							 
					for (my $i=0; $i<$nechos; $i++) { 
						if (! defined $full_vols[$i]) { next; }
						my $suffix = ($nechos==1) ? "" : sprintf("_echo%.2d", $i); 
						for (my $j=0; $j < scalar @{$full_vols[$i]}; $j++) { 

							my $filename = (scalar @{$full_vols[$i]}==1) ? 
								sprintf("%s%s%s", $file_ser_stem, $subselect, $suffix) : 
								sprintf("%s%s_%.5d%s", $file_ser_stem, $subselect, $j, $suffix);
							write_volume( $filename, [ [ $full_vols[$i]->[$j] ] ], $simage->{$uid}, $cals, $rescales->{$uid}, $options, $uinfo, $perp_vec );
						}
					}
				}
			}
		}	
	}	
#	}
	
}

sub write_volume { 
	my $filename = shift; 
	my $image_nums = shift; 
	my $image_array = shift; 
	my $dims = shift; 
	my $rescales = shift; 
	my $options = shift; 
	my $info = shift; 
	my $dirns = shift; 

	my $isnifti = $options{type} - 1;
	my $redo_colour = 0;	
	my $is_mosaic = 0;

	# Confirm dimensions & see if rescaling needed 
	my ($zdim, $tdim, $cdim); 
	$cdim = scalar @{$image_nums}; 
	$tdim = 0; $zdim = 0; 
	for (my $i=0; $i<$cdim; $i++) { 
		if (! ref $image_nums->[$i]) { next; }
		if (scalar @{$image_nums->[$i]} > $tdim) { 
			$tdim = scalar @{$image_nums->[$i]}; 
		} 
	}
	my ($r_int, $r_scl);
	my $redo_scale = 0;
	for (my $i=0; $i<$cdim; $i++) { 
		if (! ref $image_nums->[$i]) { next; }
		for (my $j=0; $j<$tdim; $j++) { 
			if (! ref $image_nums->[$i]->[$j]) { next; }
			if (scalar @{$image_nums->[$i]->[$j]} > $zdim) { 
				$zdim = scalar @{$image_nums->[$i]->[$j]};
			}
			for (my $k=0; $k<$zdim; $k++) { 
				my $image_no = $image_nums->[$i]->[$j]->[$k] || -1; 
				if ($image_no==-1) { next; }
				if ($image_no != int($image_no)) { 
					$is_mosaic = 1;
					$image_no = int($image_no);
				}
				my $slice_rint = ${$rescales->[$image_no]}[0] || 0;
				my $slice_rscl = ${$rescales->[$image_no]}[1] || 1;
				if (!defined $r_int) { $r_int = eval $slice_rint; } 
				if (!defined $r_scl) { $r_scl = eval $slice_rscl; } 
				if (($r_int != $slice_rint) || ($r_scl != $slice_rscl)) { $redo_scale = 1; } 
			}

		}
	}
	if (!defined $r_int) { $r_int = 0; }
	if (!defined $r_scl) { $r_scl = 1; }
	if ($redo_scale) { 
		$r_int = 0; 
		$r_scl = 1;
		if ($options{verbose} == 2) { 
			print "Inconsisent data scalings: data will be converted to 32 bit float\n";
		}
	}

	my $ana_hdr;
	if ($isnifti) { 
		$ana_hdr = new Data::Struct::Nifti->new();
		if ($isnifti==1) {
			$ana_hdr->magic("ni1\0");
			$ana_hdr->vox_offset(0);
			$ana_hdr->extension( "hdr" );
		} else { 	# Analyze can't parse nift_ext in .hdr files, so
			$ana_hdr->vox_offset(352);
			push @{$ana_hdr->structure_array}, [ "nifti_ext", 'l', 0 ];
			$ana_hdr = $ana_hdr->clone();	
		}
	} else { 
		$ana_hdr = new Data::Struct::Analyze->new(); 
	}
	

	if ($redo_scale == 0) { 
		if ( (uc $dims->[9]) eq "RGB") { 
			$ana_hdr->datatype( 128 );
			$ana_hdr->bitpix( 24 );
			if ($dims->[10] == 0) { 
				$redo_colour = 1; 
			}
		} else { 
			$ana_hdr->bitpix( $dims->[7] ); 
		}
		if (($dims->[7] == 16 ) && ($dims->[8] == 0)) { 
			$ana_hdr->datatype(4);	# signed -short
			$ana_hdr->bitpix( 16 ); 
		} elsif (($dims->[7] == 16 ) && ($dims->[8] == 1)) {
			$ana_hdr->datatype(4);	# signed -short
			$ana_hdr->bitpix( 16 ); 
		} elsif (($dims->[7] == 32 ) && ($dims->[8] == 0)) {
			$ana_hdr->datatype(8);	# signed -int
			$ana_hdr->bitpix( 32 ); 
		} elsif (($dims->[7] == 32 ) && ($dims->[8] == 1)) {
			$ana_hdr->datatype(8);	# signed -int
			$ana_hdr->bitpix( 32 ); 
		}
	} else { 
		$ana_hdr->datatype( 16 );	# float 
		$ana_hdr->bitpix( 32 ); 
	}
		
#	$ana_hdr->datatype(4); 	# signed -short
	if ($isnifti) { 
		$ana_hdr->scl_slope( $r_scl );
		$ana_hdr->scl_inter( $r_int );
		if (defined $dirns) { 
			for (my $i=0; $i<3; $i++) {
				$ana_hdr->srow_x([$i], (eval $dirns->[$i]->[0] * -$dims->[3+$i])); 
				$ana_hdr->srow_y([$i], (eval $dirns->[$i]->[1] * -$dims->[3+$i])); 
				$ana_hdr->srow_z([$i], $dirns->[$i]->[2] * $dims->[3+$i]); 
			}	
			$ana_hdr->srow_x([3], eval (-$dirns->[3]->[0])); 
			$ana_hdr->srow_y([3], eval (-$dirns->[3]->[1])); 
			$ana_hdr->srow_z([3], $dirns->[3]->[2]); 
			$ana_hdr->sform_code( 1 );	
	
			my @quats = get_quaterns( $dirns ); 
#			print "QFAC : " . ($quats[0]) . "\n";
			$ana_hdr->pixdim([0], $quats[0] ); 	# qfac
			$ana_hdr->quatern_b( $quats[2] ); 
			$ana_hdr->quatern_c( $quats[3] ); 
			$ana_hdr->quatern_d( $quats[4] ); 
			
			$ana_hdr->qoffset_x( eval (-$dirns->[3]->[0])); 
			$ana_hdr->qoffset_y( eval (-$dirns->[3]->[1])); 
			$ana_hdr->qoffset_z( $dirns->[3]->[2]); 
			$ana_hdr->qform_code( 1 );
		}
		$ana_hdr->descrip( $info->{SeriesDescrip} || ""); 
	} else { 
		$ana_hdr->patient_id( $info->{PatID} || ""); 
		$ana_hdr->descrip( $info->{SeriesDescrip} || ""); 
		$ana_hdr->exp_date( $info->{SeriesDate} || ""); 
		$ana_hdr->exp_time( $info->{SeriesTime} || ""); 
	}

	$ana_hdr->dim([0], ($cdim > 1) ? 5 : 4); 
	$ana_hdr->dim([1], $dims->[0]); 
	$ana_hdr->dim([2], $dims->[1]); 
	$ana_hdr->dim([3], $zdim); 
	$ana_hdr->dim([4], $tdim); 
	$ana_hdr->dim([5], $cdim); 
	$ana_hdr->pixdim([1], $dims->[3]); 
	$ana_hdr->pixdim([2], $dims->[4]); 
	$ana_hdr->pixdim([3], $dims->[5]); 
	$ana_hdr->pixdim([4], $dims->[6]); 
	$ana_hdr->xyzt_units( ($tdim==0) ? 2 : 10 ); # Units are mm and seconds 
	$ana_hdr->cal_min( ($r_scl!=0) ? ($dims->[11] - $r_int ) / $r_scl : 0.0 );  
	$ana_hdr->cal_max( ($r_scl!=0) ? ($dims->[12] - $r_int ) / $r_scl : 0.0 );  

	if ($options{outdir}) { 
		$filename = $options{outdir} . "/" . $filename; 
	}
	if ($options{verbose}) { 
		print "Writing $filename $cdim channels, $tdim timepoints, $zdim slices\n"; 
	}
	
	$ana_hdr->write_to( "$filename", "le" ); 
	
	if ($isnifti == 2) { 
		if (! open(IMGFILE, ">>$filename.nii") ) { 
			print STDERR "Could not write to $filename.nii\n";
			return;
		} 
	} else { 
		if (! open(IMGFILE, ">$filename.img") ) { 
			print STDERR "Could not write to $filename.img\n";
			return;
		} 
	}
	
	if ($options{misc}) { 
		my ($te, $bval, @bvec) = get_misc_params( $image_array, 
			$image_nums, $cdim, $tdim, $zdim, $options{verbose} ); 
		if (defined $te) { 
			if (open (ECHOES, ">$filename.te") ) { 
				for (my $c=0; $c<$cdim; $c++) { 
					printf ECHOES ("%g ", $te->[$c]);
				}
				printf ECHOES ("\n");
				close ECHOES;
			}	
		}
		if (defined $bval) { 
			if (open (BVALS, ">$filename.bvals") ) { 
				for (my $t=0; $t<$tdim; $t++) { 
					printf BVALS ("%g ", $bval->[$t]);
				}
				printf BVALS ("\n");
				close BVALS;	
			} else { 
				print STDERR "Could not write to $filename.bvals\n";
				return;
			}
			if (open (BVECS, ">$filename.bvecs") ) { 
				for (my $i=0; $i<3; $i++) { 
					for (my $t=0; $t<$tdim; $t++) { 
						my $bv_cmp = 0;
						for (my $ii=0; $ii<3; $ii++) { 
							$bv_cmp += (eval $dirns->[$i]->[$ii] * $bvec[$ii]->[$t]);
						}
						printf BVECS ("%g ", $bv_cmp);

#						if ($i<2) { 
#							printf BVECS ("%g ", $bvec[$i]->[$t]);
#						} else { 
#							printf BVECS ("%g ", (($options{orient}) ? -1 : 1) * $bvec[$i]->[$t]);
#						}
					}
					printf BVECS ("\n");	
				}
				close BVECS;	
			} else { 
				print STDERR "Could not write to $filename.bvecs\n";
				return;
			}
		}
	}

	my $done_hdr = ($options{txthdr}) ? 0 : 1; 
	my $num_in_row = 1;	
	if ($is_mosaic) { 
		$num_in_row = ceil( sqrt $zdim );	
		$row_offset = $dims->[0] * $dims->[7] / 8;
		$col_offset = $dims->[1] * $num_in_row * $row_offset; 

	}
	
	for (my $k=0; $k<$cdim; $k++) { 
		if (! ref $image_nums->[$k]) { 
			if ($options{verbose}) {
				print "ERROR: Channel $k is blank. Filling with zeros\n";  	
			}
			my $blk_size = $tdim * $zdim * $dims->[0] * $dims->[1] * 
					$dims->[7] / 8; 	
			my $blank_data = pack( sprintf("x%d", $blk_size) );
			print IMGFILE $blank_data;
			next; 	
		}
		for (my $j=0; $j<$tdim; $j++) { 
			if (! ref $image_nums->[$k]->[$j]) { 
				if ($options{verbose}) {
					print "ERROR: Ch. $k, vol $j is blank. Filling with zeros\n";  	
				}
				my $blk_size = $zdim * $dims->[0] * $dims->[1] * 
					$dims->[7] / 8; 	
				my $blank_data = pack( sprintf("x%d", $blk_size) );
				print IMGFILE $blank_data;
				next; 	
			}
			for (my $i = 0; $i<$zdim; $i++ ) {
				my $image_no = $image_nums->[$k]->[$j]->[$i]; 
				if (! defined $image_no) { $image_no = -1; } 
				if ($image_no == -1) { 
					if ($options{verbose}) {
						print "ERROR: Ch. $k, vol $j, slice $i is missing. ";
						print "Filling with zeros\n";  	
					}
					my $blk_size = $dims->[0] * $dims->[1] * 
						$dims->[7] / 8; 	
					my $blank_data = pack( sprintf("x%d", $blk_size) );
					print IMGFILE $blank_data;
					next; 	
				}
				my $mosaic_no = 0;
				if ($image_no != int($image_no)) { 
					$mosaic_no = (($image_no - int($image_no))*1000)-1;
					$mosaic_no = int($mosaic_no + 0.5);
					$image_no = int($image_no);	
#					print "MOSAIC: $image_no $mosaic_no " . ($mosaic_no % $num_in_row) . " " . int($mosaic_no / $num_in_row) . "\n";	
				}
				my $slice = $image_array->[$image_no];
				if (!$done_hdr) { 
					open(OLDOUT, ">&STDOUT");
					if (open (STDOUT, ">$filename.dcmhdr") ) { 
						print $slice->print_contents; 
						close STDOUT; 
					} else { 
						print STDERR "Can't open $filename.dcmhdr!\n";	
					}
					open(STDOUT, ">&OLDOUT");
					$done_hdr = 1;	
				} 

				my $data = $slice->get_element( '7fe0', '0010' );	# Pixel Data
				if ($is_mosaic) { 
					my $sub_data; 
					my $offset = $row_offset * ($mosaic_no % $num_in_row); 
					$offset += $col_offset * int($mosaic_no / $num_in_row); 
					for (my $m=0; $m<$dims->[1]; $m++) { 
#						print "OFFSET: $offset +$row_offset\n"; 
						$sub_data = $sub_data . substr($data, $offset, $row_offset); 
						$offset += $num_in_row * $row_offset; 
					}
					$data = $sub_data;
				}		
				if ($redo_scale) { 
					my @raw;
					if (($dims->[7] == 16)) { 
						@raw = unpack("v*", $data);
					} elsif (($dims->[7] == 32)) { 
						@raw = unpack("V*", $data);
					}
					$r_int = ${$rescales->[$image_no]}[0] || 0;
					$r_scl = ${$rescales->[$image_no]}[1] || 1;
					if (defined @raw) { 
						for (my $t=0; $t<scalar @raw; $t++) { 
							$raw[$t] = ($r_scl * $raw[$t]) + $r_int;
						}
						$data = pack("f*", @raw);
					}
				}
				if ($redo_colour) { 
					my @raw = unpack("C*", $data);
					my (@raw1, @raw2, @raw3); 
					for (my $c=0; $c<(scalar @raw)/3; $c++) { 
						$raw1[$c] = $raw[3*$c]; 
						$raw2[$c] = $raw[(3*$c)+1]; 
						$raw3[$c] = $raw[(3*$c)+2]; 
					}
					$data = pack("C*", @raw1, @raw2, @raw3);
				}
				print IMGFILE $data; 
			}	
		}	
	}	

	close(IMGFILE);
}

sub get_quaterns { 
# This takes a 3x3 matrix and calculates the quaterns amd qfac that it represents
# 
# Inputs:	1. 3x3 matrix
#
# Outputs: 	1. Array (qfac, quatern_a, quatern_b, quatern_c, quatern_d)
#
	my $dirns = shift;
	my $qfac = 1.0;
	my ($qa, $qb, $qc, $qd); 
	my $o;
	
	for (my $i=0; $i<3; $i++) { 
		for (my $j=0; $j<3; $j++) { 
			$o->[$i]->[$j] = eval $dirns->[$j]->[$i];
			if ($i!=2) { $o->[$i]->[$j] = -1.0 * $o->[$i]->[$j]; }	
		}
	}

	my $det = ($o->[0]->[0] * $o->[1]->[1] * $o->[2]->[2]) - 
		($o->[0]->[0] * $o->[2]->[1] * $o->[1]->[2]) + 
		($o->[1]->[0] * $o->[0]->[1] * $o->[2]->[2]) + 
		($o->[1]->[0] * $o->[2]->[1] * $o->[0]->[2]) - 
		($o->[2]->[0] * $o->[0]->[1] * $o->[1]->[2]) -  
		($o->[2]->[0] * $o->[1]->[1] * $o->[0]->[2]);    

#	for (my $i=0; $i<3; $i++) { 
#		for (my $j=0; $j<3; $j++) { printf("%g ", $o->[$i]->[$j]); }
#		printf("\n");
#	}

	if ($det < 0.0) { 
		$o->[0]->[2] = -$o->[0]->[2];
		$o->[1]->[2] = -$o->[1]->[2];
		$o->[2]->[2] = -$o->[2]->[2];
		$qfac = -1.0;	
	}

	$qa = $o->[0]->[0] + $o->[1]->[1] + $o->[2]->[2] + 1.0;
	if ($qa > 0.5) { 
		$qa = 0.5 * sqrt($qa);
		$qb = 0.25 * ($o->[2]->[1] - $o->[1]->[2]) / $qa; 
		$qc = 0.25 * ($o->[0]->[2] - $o->[2]->[0]) / $qa; 
		$qd = 0.25 * ($o->[1]->[0] - $o->[0]->[1]) / $qa; 

	} else { 
		my $xd = 1.0 + $o->[0]->[0] - $o->[1]->[1] - $o->[2]->[2];
		my $yd = 1.0 + $o->[1]->[1] - $o->[0]->[0] - $o->[2]->[2];
		my $zd = 1.0 + $o->[2]->[2] - $o->[0]->[0] - $o->[1]->[1];
		if ($xd > 1.0) { 
			$qb = 0.5 * sqrt($xd);
			$qc = 0.25 * ($o->[0]->[1]+$o->[1]->[0]) / $qb; 
			$qd = 0.25 * ($o->[0]->[1]+$o->[1]->[0]) / $qb; 
			$qa = 0.25 * ($o->[2]->[1]-$o->[1]->[2]) / $qb;  
		} elsif ($yd > 1.0) { 
			$qc = 0.5 * sqrt($yd);
			$qb = 0.25 * ($o->[0]->[1]+$o->[1]->[0]) / $qc; 
			$qd = 0.25 * ($o->[1]->[2]+$o->[2]->[1]) / $qc; 
			$qa = 0.25 * ($o->[0]->[2]-$o->[2]->[0]) / $qc;  
		} else { 
			$qd = 0.5 * sqrt($zd);
			$qb = 0.25 * ($o->[0]->[2]+$o->[2]->[0]) / $qd; 
			$qc = 0.25 * ($o->[1]->[2]+$o->[2]->[1]) / $qd; 
			$qa = 0.25 * ($o->[1]->[0]-$o->[0]->[1]) / $qd;  
		}
		if ($qa < 0.0) { 
			$qb = -$qb;
			$qc = -$qc;
			$qd = -$qd;
		}
	}

	return ($qfac, $qa, $qb, $qc, $qd);
}

sub order_positions { 
# This sorts the positions into a proper order and outputs a control code depending on 
# whether it is a cuboidal volume
#
# Inputs:	1. A hash of position tags pointing to a 3-element array for each position
# 		2. A pointer to a perpendicular vector (3-element array)
#		3. A pointer to an array containing dimensional info 
#	
# Outputs:	1. Return code (0 is cuboidal, 1 is non-contiguous, 2 is uneven slice thickness, 
# 			3 means slices are not aligned with each other
# 		2. Gap between slices (calculated from DICOM position tags)
# 		3. Sorted array of positions
#
	my $pos_hash = shift; 
	my $perp_vector = shift; 
	my $cal = shift; 

	# First see if the perpendicular vector contains information - it always should!
	if (($perp_vector->[0]==0) && ($perp_vector->[1]==0) && ($perp_vector->[2]==0)) { 
		my @failed = keys %{$pos_hash};
		return (2, 0.0, \@failed);  	
	}

	my $ret_val = 0;

	my @output;
	my @slice_poses;
	my $i=0;
	while ( my ($key, $value) = each(%{$pos_hash}) ) { 
		$output[$i] = $key; 
		$slice_poses[$i] = 0; 
		for (my $j=0; $j<3; $j++) { 
			$slice_poses[$i] += $perp_vector->[$j] * $value->[$j];
		}
		$i++;	
	}
	if (scalar @output <= 1) { return ( 0, 0, \@output ); } 
	my @sorted_out = sort {$slice_poses[$a] <=> $slice_poses[$b]} (0..@slice_poses-1);
	@output = @output[@sorted_out];
	@slice_poses = @slice_poses[@sorted_out];
#	print "MAX: " . ($slice_poses[@slice_poses-1]) . "\n"; 
#	print "MIN: " . ($slice_poses[0]) . "\n"; 
#	print "N: " . (scalar @slice_poses) . "\n"; 
	my $gap = ($slice_poses[@slice_poses-1] - $slice_poses[0] ) / (@slice_poses-1); 

	if (abs ($gap - $cal->[5]) > 0.05) { $ret_val = 1; }
	for (my $i=0; $i<scalar @output; $i++) { 
		my @slice_pos = @{$pos_hash->{$output[$i]}}; 
		my $delta = $slice_poses[$i] - $slice_poses[0] - ($gap*$i);  	
		$delta = $delta / $gap; # $cal->[5];	
		if (abs $delta > 0.05) { $ret_val = 2; } 	
		my @offset; 
		for (my $j=0; $j<3; $j++) { 
			$offset[$j] = $slice_pos[$j] - ${$pos_hash->{$output[0]}}[$j]; 
			$offset[$j] = $offset[$j] - ($i * $gap * $perp_vector->[$j]);
#			$offset[$j] = $slice_pos[$j] + ($gap * $perp_vector[$j]);
			$offset[$j] = $offset[$j] / (($j==2) ? $gap : $cal->[$j+3]);	
			if (($ret_val < 2) && (abs $offset[$j] > 0.05)) { $ret_val = 3; } 	
		}
	}
	return ( $ret_val, $gap, \@output );
}

sub sort_into_vols { 
# Attempts to work out which images are in which volume
#
# Inputs:	1. A pointer to a hash of positions which are in the volume
# 		2. A pointer to an array containing the ordered position vectors
#		3. A pointer to the command line options 
#
# Outputs:	1. A pointer to an array of arrays containing ordered image numbers
#
	my $pos_hash = shift; 
	my $pos_order = shift; 
	my $options = shift; 

	# Find minimum image number difference for the same position
	# Assume this is the number of images between time points (may not be
	# the same as the number of images) 
	my ($min, $max, $mindif);   
	my $ismosaic = 0; 
	foreach my $pos (values %{$pos_hash}) { 
		my @sorted = sort { $a <=> $b } @{$pos};
		if ($sorted[0] != int($sorted[0])) { $ismosaic = 1; $mindif = 1; }	
		if ((!defined $min) || ($sorted[0] < $min)) { $min = $sorted[0]; } 
		if ((!defined $max) || ($sorted[@sorted-1] > $max)) { $max = $sorted[@sorted-1]; } 
		if ((! defined $mindif ) && (scalar @sorted != 1)) { $mindif = $max - $min; } 
		for (my $i=1; $i<scalar @sorted; $i++) { 
			if ($sorted[$i] - $sorted[$i-1] < $mindif ) { $mindif = $sorted[$i] - $sorted[$i-1]; }
		}
	}
	my $offset = $min; # ($min==0) ? 0 : 1; # Most image series start at image #1, some at zero
	my $echos = 1; 
#	print "ISMOSAIC $ismosaic $mindif \n";
	if (($ismosaic==0) && ($mindif < scalar @{$pos_order})) { 
		$mindif = $max-$min+1; 					# Can't be less slices than positions! 
		$echos = int ( $mindif / (scalar @{$pos_order}) );	# guess it is some unidentified echo train	
		if ($echos==0) { $echos = 1; }	
	} 
	if (! defined $mindif) { $mindif = $max-$min+1; }
#	print "MIN: $min, MAX: $max, MINDIF: $mindif OFFSET: $offset ECHOS: $echos\n";	
	my $max_num_vols = 1 + int( ($max-$offset) * $echos / $mindif ); 

	my @all_volumes;
	my $num_vols = 0;
	for (my $i=0; $i<$max_num_vols; $i++) { 
		my $ii = int($i / $echos);
		my $vol_min = ($ii * $mindif)+$offset;
		my $vol_max = (($ii+1) * $mindif)+$offset-1;
		if ($ismosaic) { $vol_max += 0.999; }	
		my @vol_array; 
		my $volume_exists = 0;	
#		print "NUMSLICES : " . (scalar @{$pos_order}) . "\n";
		for (my $j=0; $j<scalar @{$pos_order}; $j++) { 
			my $pos_label = $pos_order->[$j];
			my $image_no = shift @{$pos_hash->{$pos_label}} || -1; 
#			print "LABEL $pos_label IMAGENO $image_no VMIN $vol_min VMAX $vol_max\n";
			if (($image_no < $vol_min) || ($image_no > $vol_max)) { 
				if ($image_no > $vol_max) { 
					unshift @{$pos_hash->{$pos_label}}, $image_no; 
				}
				$image_no = -1;
			} else { 
				$volume_exists = 1; 
			}
			push @vol_array, $image_no; 
		
		}
#		print "VOL $i: " . (join(",", @vol_array)) . "\n";
		if ($volume_exists) { 
			$all_volumes[$i] = \@vol_array; 
			$num_vols++;	
		} 
	}
#	print "NUM VOLS: $num_vols " . (scalar @all_volumes) . "\n";
	if ($num_vols==1) { # If only one volume has been found, assume this was deliberate 
		while (! defined $all_volumes[0]) { shift @all_volumes; } 
	}
	
	if ($options->{verbose}) { 
		my @not_done;
		foreach (keys %{$pos_hash}) { 
			push @not_done, @{$pos_hash->{$_}};
		}
		if (scalar @not_done != 0) { 
			print "Images " . (join (" ", @not_done)) . " not sorted correctly!\n";
		}
	}			
	return \@all_volumes; 
}

sub load_dir { 
# Load DICOM files from a directory
# 
# Inputs:	1. Directory to load from
#
# Outputs:	1. Pointer to hash of images sorted by Series uid
# 		2. Hash of header info
	my $indir = shift;
	opendir (DIR, $indir) or die "Can't open $indir!\n"; 
	my @filelist = readdir DIR;
	closedir DIR;	

	my @full_path; 
	foreach (@filelist) { 
		push @full_path, "$indir/$_";
	}
	return load_files( @full_path );
}

sub load_files { 
# Load DICOM files 
# 
# Inputs:	1. Array of filenames 
#
# Outputs:	1. Pointer to hash of images sorted by Series uid
# 		2. Hash of header info

	my @filelist = @_; 

	my %uids;
	my %images;
	foreach my $file (@filelist) { 
		foreach my $bb (@{$file}) { print "$_\n"; } 
		if ( -d "$file" ) { next; }
#		unless (open (DCM, "<$indir/$file")) { 
#			print "Can't open $indir/$file\n"; 
#			next; 
#		} 
#		my $tmp = $/;
#		$/ = undef;
#		my $data = <DCM>;
#		$/ = $tmp;
#		close DCM; 
#		my $image = new DICOM::DICOMObject( $data ); 
		my $image = new DICOM::DICOMObject( "$file" ); 
		if (! $image ) { 
			 print "Can't open $file\n";
			 next;
		}
		my $series_uid = $image->get_element( '0020', '000e' ) || ""; # Series UID	
	
		if (! defined $uids{$series_uid} ) { 
			$uids{$series_uid}->{patid} =  $image->get_element( '0010', '0020' ) || ""; # Patient ID
			$uids{$series_uid}->{date} = $image->get_element( '0008', '0020' ) || ""; # Study Date	
			$uids{$series_uid}->{studyuid} = $image->get_element( '0020', '000d' ) || ""; # Study UID	
			$uids{$series_uid}->{studydes} = $image->get_element( '0008', '1030' ) || ""; # Study Description 
			$uids{$series_uid}->{accnum} = $image->get_element( '0008', '0050' ) || ""; # Accession Number
		}
		push @{$images{$series_uid}}, $image; 	
	}


	return (\%images, \%uids);

}

sub get_misc_params { 
	my $image_array = shift; 
	my $image_nums = shift;
	my $cdim = shift; 
	my $tdim = shift; 
	my $zdim = shift;
	my $verbose = shift; 

	my $nonzero = 0;
	my $te_differ = 0;
	my @all_tes = ();
	my @all_bvals = ();
	my @all_bvec0 = ();
	my @all_bvec1 = ();
	my @all_bvec2 = ();
		
	for (my $c=0; $c<$cdim; $c++) { 	
		my @ch_bvals = ();
		my @ch_bvec0 = ();
		my @ch_bvec1 = ();
		my @ch_bvec2 = ();
	
		my $te; 
		for (my $t=0; $t<$tdim; $t++) { 
			my $bval; 
			my @bvec;
			if (ref $image_nums->[$c]->[$t]) { 
				for (my $z=0; $z<$zdim; $z++) { 
					my $im_no = $image_nums->[$c]->[$t]->[$z] || -1; 
					if ($im_no==-1) { next; }
					my $slice = $image_array->[$im_no]; 
				
					# Echo times
					my $te_val = $slice->get_element( '0018', '0081' ) || 0;  # Echo Time
					if ( ! defined $te ) { 
						$te = $te_val; 
					} else { 
						if ($te != $te_val) { 
							if ($verbose) { 
								print STDERR "Differing echo times in the same volume. Very strange $te\n"; 
							}
						}
					}

					# Diffusion measures from CSA header	
					my $dicom = $slice->get_element( '0029', '1010' ) || undef;
					if (! defined $dicom) { next; } 
					my $siemens = parse_csa_header( $dicom );
					if (! defined $siemens) { next; }

					my $bmatrix_ptr = $siemens->{B_matrix};
					if (scalar @{$bmatrix_ptr} != 6) { 
						$bval_ptr = [ 0 ];
						$bvec_ptr = [ 0, 0, 0 ];
					} else { 
						my $bmatrix = Math::MatrixReal->new_from_rows( [ 
							[ 0+$bmatrix_ptr->[0], 0+$bmatrix_ptr->[1], 0+$bmatrix_ptr->[2] ],
							[ 0+$bmatrix_ptr->[1], 0+$bmatrix_ptr->[3], 0+$bmatrix_ptr->[4] ],
							[ 0+$bmatrix_ptr->[2], 0+$bmatrix_ptr->[4], 0+$bmatrix_ptr->[5] ] ] ); 
						my ($l, $V) = $bmatrix->sym_diagonalize();

						my $max_index = 1;
						my $max_eigen = $l->element(1, 1);
						if ($l->element(2, 1) > $max_eigen) { $max_eigen = $l->element(2, 1); $max_index = 2; }
						if ($l->element(3, 1) > $max_eigen) { $max_eigen = $l->element(3, 1); $max_index = 3; }
						$bval_ptr = [ $max_eigen ];
						if ( $V->element(1, $max_index) > 0.0) { 
							$bvec_ptr = [ $V->element(1, $max_index), $V->element(2, $max_index), $V->element(3, $max_index) ];
						} else { 
							$bvec_ptr = [ -$V->element(1, $max_index), -$V->element(2, $max_index), -$V->element(3, $max_index) ];
						}
					}

#					$bval_ptr = $siemens->{B_value}; 
#					if (scalar @{$bval_ptr} == 0) { 
#						$bval_ptr = [ 0 ];	
#					}
					if ( ! defined $bval) { 
						$bval = $bval_ptr->[0]; 
					} 
					else { 
						if ( $bval_ptr->[0] != $bval ) { #error !
							if ($verbose) { 
								print STDERR "Differing B-values in the same volume. Very strange\n"; 
							}
						} 		
					}
					if (exists $all_bvals[$t]) { 
						if ( $all_bvals[$t] != $bval ) { #error !
							if ($verbose) { 
								print STDERR "Differing B-values in the same volume. Very strange\n"; 
							}
						}
					}
#					my $bvec_ptr = $siemens->{DiffusionGradientDirection}; 
#					if (scalar @{$bvec_ptr} < 3) { 
#						$bvec_ptr = [ 0, 0, 0 ];	
#					}
					if ( ! defined $bvec[0] ) { 
						$bvec[0] = $bvec_ptr->[0];
						$bvec[1] = $bvec_ptr->[1];
						$bvec[2] = $bvec_ptr->[2];
					} else { 
						if (($bvec_ptr->[0] != $bvec[0] ) ||
							($bvec_ptr->[1] != $bvec[1] ) || 
							($bvec_ptr->[2] != $bvec[2] ) ) { 
								if ($verbose) { # error ! 
									print STDERR "Differing B-dirns in the same volume. Very strange\n"; 
								}
						} 		
					}	
					if ( exists $all_bvec0[$t] ) { 
						if (($bvec[0] != $all_bvec0[$t] ) ||
							($bvec[1] != $all_bvec1[$t] ) || 
							($bvec[2] != $all_bvec2[$t] ) ) { 
								if ($verbose) { # error ! 
									print STDERR "Differing B-dirns in the same volume. Very strange\n"; 
								}
						} 		
					}	
				}
			}
			if ($bval) { 
				$nonzero = 1; 
			}
			push @ch_bvals, $bval || 0; 
			push @ch_bvec0, $bvec[0] || 0;
			push @ch_bvec1, $bvec[1] || 0;
			push @ch_bvec2, $bvec[2] || 0;
		}
		push @all_tes, $te; 
		if ($all_tes[0] != $te) { 
			$te_differ = 1;
		}
		if ( ! exists $all_bvals[0]) { 
			push @all_bvals, @ch_bvals;
			push @all_bvec0, @ch_bvec0;
			push @all_bvec1, @ch_bvec1;
			push @all_bvec2, @ch_bvec2;
		}
	}
	
	my $ptr_tes  = ( $te_differ ) ? \@all_tes : undef; 
	my $ptr_bval = ( $nonzero ) ? \@all_bvals : undef; 

	return ( $ptr_tes, $ptr_bval, \@all_bvec0, \@all_bvec1, \@all_bvec2 );
#	return ($nonzero) ? (\@all_bvals, \@all_bvec0, \@all_bvec1, \@all_bvec2) : undef;
}

sub parse_csa_header { 

	my $siemens = shift; 
	my %csa_hash;

	my ($code) = unpack("A4", $siemens); 
	if ($code ne "SV10") { $csa_hash{VALUE} = [ $siemens ] ; return \%csa_hash; }
	
	$siemens = substr($siemens, 4, length($siemens)-4);
	my ($n) = unpack("x4Lx4", $siemens); 
	$siemens = substr($siemens, 12, length($siemens)-12);

	for (my $i=0; $i<$n; $i++) { 
	
		my ($name, $vm, $vr, $syngodt, $nitems, $xx ) = 
			unpack("a64la4l3", $siemens); 
		($name) = ($name =~ m/^([^\000]*)/);

#		print " name: $name\n VM: $vm\n VR: $vr\n syngodt: $syngodt\n nitems: $nitems\n xx: $xx\n"; 
		$siemens = substr($siemens, 84, length($siemens)-84);
		my @item_array; 
		for (my $j=0; $j<$nitems; $j++) { 
			my (@item_xx) = unpack("l4", $siemens); 
			$siemens = substr($siemens, 16, length($siemens)-16);
			my $len = $item_xx[1]; 
#			print "  LENGTH: $len ($item_xx[0] $item_xx[1] $item_xx[2] $item_xx[3])\n"; 
			my $nulls = (4 - ($len % 4)) % 4; 	
			my $pstr = sprintf("a%dx%d", $len, $nulls);
			if (($len+$nulls>0) && ($len+$nulls<=length($siemens))) { 
				# Is this tag parsable? 
				my ($val) = unpack($pstr, $siemens);
				if ($item_xx[0]) { push @item_array, $val; } 	
				$siemens = substr($siemens, $len+$nulls, length($siemens)-$len-$nulls);
			}
#			print "  PSTR: $pstr VAL: $val\n"; 	
		}
		$csa_hash{$name} = \@item_array;
	}
	return \%csa_hash;
}

sub set_output { 
	my $type = shift; 
	if ($type eq "dicom") { 
		return 0; 
	} elsif ($type eq "analyze") { 
		return 1;
	} elsif ($type eq "nifti_img") { 
		return 2;
	} elsif ($type eq "nifti") { 
		return 3;
	} else { 
		print STDERR "Unrecognized file type: $type\n"; 
		exit 1;	
	}
}

sub show_syntax { 

	my $name = shift;
	my $options = shift;

	print "Syntax: $0 	Command line DICOM downloads\n";
	print "\n";
	print " DICOM parameters:\n";
	print "	-remoteae	The remote AE title (default: " . ($options->{remoteae} || "none") . ")\n";
	print "	-remoteip	The remote IP address (default: " . $options->{remoteip} . ")\n";
	print "	-localae 	The local AE title (default: " . $options->{localae} . ")\n";
	print "	-port    	The DICOM port (default: " . 
			$options->{ $options->{ssl} ? "ssl_port" : "tcp_port"} . ")\n"; 
	print "	-ssl 		Use SSL connection to the server (default: " . ($options->{ssl} ? "yes" : "no"). ")\n";
	print "\n";
	print " Search parameters\n";
	print "	-date		Date (YYYYMMDD format)\n";
	print "	-id		Patient ID\n";
	print "	-studyuid 	Study UID\n";
	print "	-studydes	Study Description\n";
	print "	-accnum		Accession Number\n"; 
	print "\n";
	print " Input parameters\n";
	print "	-dicomdir	DICOMDIR. If present, this file is used\n";
	print "			as the DICOM catalogue instead of the\n";
	print "			network DICOM connection.\n";
	print "	-indir		Input directory. If present, instead of\n";
	print "			a DICOM transfer, data is read from the\n";
	print "			given directory. All files in it must be\n"; 
	print "			DICOM files, or odd things will happen\n"; 
	print "\n";
	print " Output parameters\n";
	print "	-outdir		Output directory\n"; 
	print "	-makedir	Create a directory structure for the output files\n"; 
	print "	-outtype	Output format (dicom, analyze, nifti_img, nifti) (default: " . $options->{outtype} . ")\n";
	print "	-level		Determines how to format output files: (default: " . $options->{level} . ")\n"; 
	print "				0: same series in same file\n";
	print "				1: same orientations in same file\n";
	print "				2: max 3 dimensions per file\n";
	print "				3: max 4 dimensions per file\n";
	print "				4: max 5 dimensions per file\n";
	print "			For levels 0 & 1 no orientational info\n"; 
	print "			 	is inferred from the headers\n";
	print "	-radio/-neuro	Output radiological/neurological format data (default: " . ($options{orient} ? "radio" : "neuro") . ")\n";
	print "				Only used for Analyze file output.\n"; 
	print "				For nifti formats, the orientation is\n";
	print "				encoded in the sform header. The radio/neuro\n";
	print "				flags determine the handedness of the data\n";
	print "				if the header is ignored.\n";
	print "				NOTE: The data may need rotating (but _not_\n";
	print "				flipping) to display properly in non-nifti viewers.\n";
	print "	-txthdr		Output DICOM header as text file (default: " . ($options->{txthdr} ? "yes" : "no") . ")\n"; 
	print "	-anon		Anonymise patient identifying DICOM tags (default: " . ($options->{anon} ? "yes" : "no") . ")\n"; 
	print "\n";
	print " Other\n";
	print "	-count		Count images in series\n";
	print "	-info		Print protocol name if available\n";
	print "	-verbose	verbosity level (0=least, 2=most) (default: " . $options->{verbose} . ")\n";
	print "	-silent		Equivalent to --verbose=0\n";
	print "	-all		Take all series foundXXXXXXXXXXXXXXXXXXXXXXXXXXX\n";
#	print "\n\nGuy Williams\n"; 
	
}

