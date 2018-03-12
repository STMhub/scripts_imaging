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
#    print "$_ \n";
    
#   
#	find(sub {print $File::Find::name if -d}, ".");

if ($_ =~ /^flair/m)
	{
	#looking for smoothend imgs
	#print $count;
	my $m_filename = $_;
	my $thisdir = cwd();
	`touch_all.pl $m_filename`;
	}
 }
print ("/n/n Done");
 exit 0;
