#!/usr/bin/perl
use File::Find;
use Cwd;
use strict;
use warnings;

if ($#ARGV != 0) {
    print "usage : $0  <Search Directory path> \n";
            exit;
            }
my $dir =$ARGV[0];#"/scratch/stm29/img_setup/joseph/tmp/ct";

find(\&do_something_with_file, $dir);

sub do_something_with_file
{
#    print "$_ \n";
#	find(sub {print $File::Find::name if -d}, ".");
	if ($_ =~ /dti.img/)#looking for dti imgs
	{
	my $thisdir = cwd();
	my $filename = $_;
	print("\nprocessing :$thisdir/$filename ");#printing full path of the file
	my @fname = split(".img", $filename);#retriving basename of the file
	my $basename = $fname[0];
	##################---volume extraction specific#############################	
	my $bvalsfile= $basename . ".bvals";
	open FILE, $bvalsfile or die $!;
	my $bvalues = <FILE>;
#	print $bvalues;
	my $count;
	while ($bvalues =~ /\s0\s/g) { $count++ }
#	    print "There are $count Zeros in the string";
	my $avroinp=$basename . "_eddy.nii";
	my $avroioutp=$basename . "_b1000";
	if ($count ==2)
	{print ("dti image has got 39 volumes\n");
	`avwroi $avroinp $avroioutp 14 12`;   
	}
	else {print ("dti image has got 65 volumes\n");
	`avwroi $avroinp $avroioutp 27 12`;
		}	
	my $dwi1000=$basename . "_dwi1000.nii";	
	`avwmaths $avroioutp -Tmean $dwi1000 `;
	}

 }
 exit 0;
