#!/usr/bin/perl

# Script to produce a set of 3d nii files from an input 4d nifti file
# Based on ana4dto3d, but without the mean and variance calculating
# capability
#
# Guy Williams
# 15/9/05
#

use Getopt::Long;

my %options;
GetOptions( \%options, "d=i", "verbose|v" );

my $source = shift; 
if (! defined $source) { 
	die "Syntax: nii4dto3d.pl [-v][-d <dummyno>] file.nii [<output dir>]\n"; 
}

my $output = shift;

# Parse the output into directory and filestem
my $fname = "";
my $outdir = "";
if ( -d $output || ! defined $output) { 
	($outdir, $fname) = ($source =~ m#(.*)/(.*)#);
	if (! defined $fname) { 
		$fname = $source; 
	}
}
if (-d $output) { 
	$outdir = $output . "/";
}
my ($filestem) = ($fname =~ m/(.*)\.nii/);
$filestem = (defined $filestem) ? $filestem : $fname; 

$output = $outdir . $filestem; 
$output =~ s#//#/#;

if ($options{verbose}) { 
	print "Input Nifti File: $source\n"; 
	print "Output file stem: $output\n"; 
}

my $num_vols; 

open (NII, "nifti_tool -disp_hdr -field dim -infiles $source|");

while(<NII>) { 

	my ($name, $offset, $nvals, $values) = m/(\S+)\s+(\d+)\s+(\d+)\s+(.*)/; 
	if (defined $name) { 
		my @dim_array = split / /, $values;
		$num_vols = $dim_array[4];	
	}
}
close NII;

if ($num_vols<=1) { 
	print "This is not 4D data! Number of time points: $num_vols\n"; 
	exit;
} else { 
	if ($options{verbose}) {
		print "Nifti file has $num_vols volumes\n";
	}
}
my $d = 0; 
if ($options{d}) { 
	$d = $options{d}; 
	if ($options{verbose}) { 
		print "Ignoring first $d volumes\n"; 
	}
}
for (my $t=$d; $t<$num_vols; $t++) { 

	my $prefix = sprintf("%s_%.4d", $output, ($t+1));
	if ($options{verbose}) { 
		print "Extracting volume file $prefix\n";
	}

	system("nifti_tool -cbl -prefix $prefix -infiles $source'[$t]'\n");
}
