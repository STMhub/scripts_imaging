#!/usr/bin/perl
use File::Find;
use Cwd;
use strict;
use warnings;

if ($#ARGV != 0) {
    print "usage : $0  <Search Directory path> \n\n";
	print("================DTI image preprocessinmg============\n
		
		Input: DTI image in Analyze format
			<filename>dti.img
			<filename>dti.hdr
			<filename>dti.mat
			<filename>dti.bvals
			<filename>dti.bvecs
		Process:
			1.skull stripping using bet 
			2.FSL eddy correction of volumes for movement
			3.dtifit that creates MD file
			4.Extract volumes
		out files:
			<filename>_b0
			<filename>_dwi1000
			<filename>_MD\n\n"
			);
     exit;
            }
my $dir =$ARGV[0];#"/scratch/stm29/img_setup/joseph/tmp/ct";

find(\&do_something_with_file, $dir);

sub do_something_with_file
{
    print "$_ \n";
#	find(sub {print $File::Find::name if -d}, ".");
	if ($_ =~ /dti\.img\b/m)#looking for dti imgs
	{
	print("i'm in th loop \n");
	my $thisdir = cwd();
	my $filename = $_;
	print("processing :$thisdir/$filename \n");#printing full path of the file
	my @fname = split(".img", $filename);#retriving basename of the file
	my $basename = $fname[0];
	#print ("$basename \n");
	my $avroiout= $basename . "_b0";
	###################1.Skull stripping#################################################

#	print ("avroi output filename: $avroiout\n");
	`fslroi $filename $avroiout 0 1`;#performing avroi cmd
	my $betoutp= $basename . "_brain";
#	print ("bet outputfile name : $betoutp");
	`bet $avroiout $betoutp -m -f 0.1`;#perdorming bet cmd

	##################2.Eddy correction###################################################
	my $eddyoutp= $basename . "_eddy";
	`eddy_correct $filename $eddyoutp 0`;#performing eddy_correct

	##################3.DTI Fit###########################################################
	my $dfitBMaskinp= $betoutp . "_mask";
	my $dfitbvecsinp= $basename . ".bvecs";
	my $dfitbvalsinp= $basename . ".bvals";
	my $dtifitBName= $basename . "_dtifit";#performning dtfit
	`dtifit -k $eddyoutp -o $dtifitBName -m $dfitBMaskinp -r $dfitbvecsinp -b $dfitbvalsinp`;
	my $avmathEddyMask= $eddyoutp . "_mask";
	`fslmaths $eddyoutp -mul $dfitBMaskinp $avmathEddyMask`;#creating a eddy mask using avwmaths
	##################4.Extract Volumes#####################################################
	my $bvalsfile= $basename . ".bvals";
        open FILE, $bvalsfile or die $!;
        my $bvalues = <FILE>;
#       print $bvalues;
        my $count;
        while ($bvalues =~ /\s0\s/g) { $count++ }
#		print "There are $count Zeros in the string";
        my $avroinp=$basename . "_eddy.nii";
        my $avroioutp=$basename . "_b1000";
        if ($count ==2)
        	{print ("dti image has got 39 volumes\n");
        	`fslroi $avroinp $avroioutp 14 12`;
	        }	
        else 
		{print ("dti image has got 65 volumes\n");
	        `fslroi $avroinp $avroioutp 27 12`;
             	}
	############Calculate mean of the set to get DWI image#############
	my $dwi1000=$basename . "_dwi1000.nii";
      `fslmaths $avroioutp -Tmean $dwi1000 `;
	}
 }
 exit 0;
