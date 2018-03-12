#!/usr/bin/perl

#
# Tool to ensures files are in the cache and not on tape in the DICOM Server. 
# This will prevent timeouts when downloading them. 
#
# Guy Williams
#
# 21/03/02
#

use DBI; 

if (@ARGV!=1) { 
	print "Usage: dicom_touch.pl <Hospital Number>\n"; 
	exit; 
}

my $name = $ARGV[0]; 


# Connect to the data base
  my $dbh = DBI->connect( "DBI:mysql:Central;localhost", 'ctn', 'ctn' )
     or die("Cannot connect: " . $DBI::errstr);

# Find paths

  my $query = qq( SELECT Path, SOPInsUID, SerInsUID, StuInsUID  
		  FROM InstanceTable, ImageLevel, SeriesLevel, StudyLevel
		  WHERE InstanceTable.ImageUID = ImageLevel.SOPInsUID
		    AND ImageLevel.SerParent = SeriesLevel.SerInsUID
		    AND SeriesLevel.StuParent = StudyLevel.StuInsUID
		    AND StudyLevel.PatParent = '$name' 
		); 
  my $sth = $dbh->prepare( $query ); 
  $sth->execute();
  
  my ( $path, $image, $series, $study); 
  $sth->bind_columns( undef, \$path, \$image, \$series, \$study ); 
  
  my $num_on_tape = 0; 
  my $num_total = 0; 
  my @ones_to_retrieve; 
  my ( %study_count, %series_count, %image_count, %image_found, %missing_images); 
  my %series_missing; 

  while ( $sth->fetch() ) {
  	$study_count{$study} = "PASS"; 	
  	$series_count{$series} = $study; 	
  	if (!defined $image_found{$image}) { 
		$image_count{$series}++; 	
	}

	$num_total++; 
	#system("ls -l $path"); 
	if ( ! -e $path ) { 
		if (!defined $image_found{$image}) { 
			$series_missing{$series}++; 
		}
		$image_found{$image} = 1; 
		$missing_images{$image} = 1; 	
		#print "Missing image !!!\n"; 
	} else { 
		my $param = $image_found{$image} || 0; 
		if ( $param == 1) { 
			$series_missing{$series}--; 
		}
		$image_found{$image} = 2; 
		$missing_images{$image} = undef; 	
	}
	
	if ( (-e $path ) && (-k $path )) { 
		push (@ones_to_retrieve, $path); 
		$num_on_tape++; 	
	}
  }
  
  $sth->finish(); 
  $dbh->disconnect; 
  
  print "Number of files for subject $name: $num_total\n"; 
  my $num_missing = scalar keys %missing_images; 
  if ($num_missing != 0) { 
	print "Number of actual images: $num_missing\n"; 
  }
  foreach (keys %study_count) { 
	my $indiv_study = $_; 
	print "Study contents: "; 
	foreach (keys %series_count) { 
		if ($indiv_study eq $series_count{$_}) {  
			if ($series_missing{$_}==0) { 
				print $image_count{$_} , " ";
			} else { 
				print "$image_count{$_}($series_missing{$_}) "; 
			}	
		}	
	}
	print "\n"; 
  }
  if ($num_on_tape == 0) { 
 	if ($num_total != 0) { 
		print "All are online\n"; 	
	}
	exit; 
  }

  print "Number on tape = $num_on_tape\n"; 
  print "Bringing scan slices back.....\n"; 

  my $count = 1; 
  foreach my $filename (@ones_to_retrieve) { 
	system("/usr/bin/wc $filename >/dev/null"); 
	print "\r$count / $num_on_tape brought back"; 	
 	$count++;  
  }
  print "\n"; 

  
