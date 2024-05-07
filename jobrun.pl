#!/usr/bin/env perl

use warnings;
use strict;
use Data::Dumper;
use IPC::Shareable;
use POSIX qw( ENOTCONN ECONNREFUSED ECONNRESET EINPROGRESS EWOULDBLOCK EAGAIN WNOHANG );


my $debug=0;
my $NOTDONE=1;
my $jobPidsSHMKey = 'jobpid';
my $jobStatusSHMKey = 'jobstatus';
my %jobsToRun=();
my %jobs=();
my %config=();

my $configFile='jobrun.conf';
-r $configFile || die "could not read $configFile - $!\n";

my %shmOptions = (
	create    => 1,
	exclusive => 0,
	mode      => 0644,
	destroy   => 1
);

my %jobPids=();
my %jobStatus=();

tie %jobPids, 'IPC::Shareable', $jobPidsSHMKey, { %shmOptions } or die "tie failed - $!\n";
tie %jobStatus, 'IPC::Shareable', $jobStatusSHMKey, { %shmOptions } or die "tie failed - $!\n";

my $jobFile='jobs.conf';
-r $jobFile || die "could not read $jobFile - $!\n";

$SIG{HUP} = sub {getKV($configFile,\%config)}; # kill -1 - reload config
$SIG{INT} = sub { $NOTDONE=0; }; # kill -2
$SIG{QUIT} = sub { $NOTDONE=0; }; # kill -3
$SIG{TERM} = sub { $NOTDONE=0; }; # kill -15 - use this, as -3 and -2 will not work on children that are running system()

getKV($configFile,\%config);
getKV($jobFile,\%jobsToRun);
#print 'config: ' . Dumper(\%config);
#print 'jobsToRun ' . Dumper(\%jobsToRun);
#exit;

=head1 %jobs structure

status is initially 2
children update the status

0: child finished with error
1: child finished successfully
2: running - status has not updated by child - check if still running
3: failed to run

%jobs = (
	pid => {
		name => 'name of job',
		cmd  => 'command',
		status => 0 for fail 1 for success
	},
);

example:

%jobs = (
	12345 => {
		name => 'job#1',
		cmd  => 'sleep 1',
		status => 0 # finished with
	},

	67890 => {
		name => 'job#2',
		cmd  => 'sleep 1',
		status => 2 # not updated by child - check if ok
	},

	78234 => {
		name => 'job#3',
		cmd  => 'sleep 1',
		status => 1 # success!
	}
)

=cut

print Dumper(\%jobsToRun) if $debug;

my @jobNames = keys %jobsToRun;
#my @jobsRunning=();
#

print '@jobNames: ' . Dumper(\@jobNames);
print '%jobsToRun ' . Dumper(\%jobsToRun);
#exit;

while ($NOTDONE) {


	foreach (my $i=0;$i< $config{maxjobs};$i++) {
		last unless $#jobNames >= 0 ;

		my @jobsRunning = keys %jobPids;
		if ( $#jobsRunning > $config{maxjobs} ) {
			last;
		}

		print '@jobNames ' . Dumper(\@jobNames) if $debug;
		print "\$#jobNames $#jobNames\n" if $debug;
		print "i: $i\n" if $debug;
		#last unless ($#jobNames + 1) < $config{maxjobs};
		#
		# check for number of jobs running here;

		print "Starting job $jobNames[0]\n"; # always zero due to shift later
		# spawn
		my $childPID = child($jobNames[0],"$jobsToRun{$jobNames[0]}");
		print "main-parent-child PID: $childPID\n";
		#$jobs{$childPID}->{name} = $jobNames[0];
		#$jobs{$childPID}->{cmd} = $jobsToRun{$jobNames[0]};
		$jobs{$jobNames[0]}->{pid} = $childPID;
		$jobs{$jobNames[0]}->{cmd} = $jobsToRun{$jobNames[0]};
		$jobs{$jobNames[0]}->{status} = 2;
		#$jobs{$childPID}->{status} = 2;
		shift @jobNames;

	}

	# cleanup jobs that have finished
	jobCleanup(0);

	$NOTDONE = 0 unless $#jobNames >= 0 ;

	print "main sleeping...\n";
	sleep $config{'iteration-seconds'};
}

jobCleanup(1);

# update the status values in %jobs
foreach my $jobName ( keys %jobStatus ) {
	$jobs{$jobName}->{status} = $jobStatus{$jobName};
}

print '%jobPids: ' . Dumper(\%jobPids);
print '%jobStatus ' . Dumper(\%jobStatus);
print '%jobs: ' . Dumper(\%jobs) ; #if $debug;
exit;


# the job hashes/arrays are all global
sub jobCleanup {
	my ($cleanupAll) = @_;
	my $kid;
	while (1) {

		# wait for any grandchild to complete
		$kid = waitpid(-1,WNOHANG);
		print "jobCleanup - kid: $kid\n" if $debug;

		# exit the loop if there is space to create a new process
		# child() is removing entries form jobPids as the the process completes
		# keep in mind that %jobPids and %jobStatus are in shared memory
		my @pidCount = keys %jobPids;	
		last if $#pidCount < 0;

		#print "jobCleanup: pidCount: $#pidCount\n"; # if $debug;
		#print "jobCleanup: cleanupAll: $cleanupAll - " . Dumper(\%jobPids); # if $debug;

		unless ( $cleanupAll ) {
			if ( $#pidCount < ($config{maxjobs} + 1) ) {
				last;
			}
		}

		sleep 0.10;

	} # while ($kid > 0);

	return;	
}

sub child {
	my ($jobID, $cmd) = @_;

	my $child = fork();
	#die("Can't fork: $!") unless defined ($child = fork());
	die("Can't fork #1: $!") unless defined($child);

	if ($child) {
		print "child - parent: name: $jobID  cmd: $cmd\n";
		#delete $jobs{$child} if exists $jobs{$child};
		#$jobs{$child}->{name} = $jobID;	
		#$jobs{$child}->{cmd} = $cmd;	
	} else {

		$child = fork();	
		die("Can't fork #2: $!") unless defined($child);

		if ($child == 0 ) {
			# use system() here
			#qx/$cmd/;
			my $pid=$$;
			$jobPids{$jobID} = $pid;
			$jobStatus{$jobID} = 2; # running
			#push @jobsRunning, $pid;
			system($cmd);
	
			my $rc = $?;
	
			if ( $? == -1) {
				# failed to execute
				$jobStatus{$jobID} = 3; # error
				;
			} elsif ( $? & 127) {
				$jobStatus{$jobID} = 0; # error
			} else {
				;
				$jobStatus{$jobID} = 1; # success
			}
	
			delete $jobPids{$jobID};
			#delete $jobStatus{$jobID};
			print "rc $rc - $cmd\n";
	
			# at this time always exit with success
			# success/fail status is tracked in %jobStatus
			exit 0;
		} else {
			exit;
		}

	};

	return $child;
}

sub getKV {
	my ($configFile,$configRef) = @_;
	open CFG, '<', $configFile || die "getKV() - could not open $configFile - $!\n";
	while (<CFG>) {
		chomp;
		next if /^#/;
		next if /^\s*$/;

		my ($key,$value) = split(/\s*:\s*/);
		$configRef->{$key} = $value;
	}
	return;
}



