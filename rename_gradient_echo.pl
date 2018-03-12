#!/usr/bin/perl
use File::Find;
use Cwd;
#use strict;
#use warnings;

$cnt = 01;
$count= sprintf ("%0.2d",$cnt);
if ($#ARGV != 0) {
    print "usage : $0  <Search Directory path> \n";
            exit;
            }
my $dir =$ARGV[0];#"/scratch/stm29/img_setup/joseph/tmp/ct";

find(\&do_something_with_file, $dir);

sub do_something_with_file
{
    #print "$_ \n";
    
#   
#	find(sub {print $File::Find::name if -d}, ".");
if ($_ =~ m/DATA_\d\d\d\d\.nii\b/)
	{
	#looking for smoothend imgs
	print $count;
	my $m_filename = $_;

	my $thisdir = cwd();
	my @fname = split(".nii", $m_filename);#extracting basename
	my $basename = $fname[0];
	#my $newname = "001_WM.nii";
	my @dirlist = split("/", $thisdir);
	my $subdir=$dirlist[-1];
	my $subdir_wbic=$dirlist[-3];
#	print $subdir;
	if ($subdir =~ /Axial_Gradient_Echo\b/m)
	{	
	print("\nprocessing :$thisdir/$m_filename  \n");#printing full path of the file
	$newname = $subdir_wbic. "_gradient_echo.nii";
	`mv $m_filename $newname`;
	print("processing :$newname \n \n");
	$count = ++$count; 
	}	
	if ($subdir =~ /Axial_Flair\b/mi)
	{
	print("\nprocessing :$thisdir/$m_filename \n");#printing full path of the file
	$newname =$subdir_wbic. "_flair.nii"; 
	`mv $m_filename $newname`;
	print("processing :$newname \n \n");	 
	$count = ++$count;
	}
	}
 }
print ("\n\n Done");
 exit 0;
