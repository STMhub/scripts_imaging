#!/usr/bin/perl
#
#Converts the NIFTI Images of the directory tree to Anlyze Neuro format.
#
#`nii_to_radio $filename radio`
#
use File::Find;
use Cwd;
use strict;
use warnings;

if ($#ARGV != 0) {
    #print "usage : $0  <Search Directory path>\n
    print "usage : nii_to_img_dir_tree.pl <Search Directory path>\n
    \nConverts the NIFTI<nii> Images in the directory tree to Anlyze Neuro format.\n";
            exit;
            }
my $dir =$ARGV[0];#directory path 
find(\&do_something_with_file, $dir);

sub do_something_with_file
{
#    print "$_ \n";
#	find(sub {print $File::Find::name if -d}, ".");
	if ($_ =~ /\.nii\b/m)#looking for nii images 
	{
	my $thisdir = cwd();
	my $filename = $_;
	print("processing :$thisdir/$filename \n");#printing full path of the file
	`nii_to_radio $filename neuro`;
	`nii_to_img.pl $filename`;
 	}
}
exit 0;
 
