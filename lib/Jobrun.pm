#
# Jared Still
# 2024-05-21
# jkstill@gmail.com
#
# use to fork a process to run a job
# jobrun.pl is the front end
######################################################

=head1 Jobrun.pm

Not yet documented

=cut


package Jobrun;

use warnings;
use strict;
use IPC::Semaphore;
use IPC::SysV qw(IPC_PRIVATE SEM_UNDO IPC_CREAT S_IRUSR S_IWUSR);
use Data::Dumper;
use File::Temp qw/ :seekable tmpnam/;
#use Time::HiRes qw( usleep );
use IPC::Shareable;
use IO::File;
use lib '.';

require Exporter;
our @ISA= qw(Exporter);
our @EXPORT_OK = qw(logger %allJobs);
our @EXPORT = qw();
our $VERSION = '0.01';

#use POSIX qw( ENOTCONN ECONNREFUSED ECONNRESET EINPROGRESS EWOULDBLOCK EAGAIN WNOHANG );

my %shmOptions = (
   create    => 1,
   exclusive => 0,
   mode      => 0644,
   destroy   => 1
);

my $jobPidsSHMKey = 'jobpid';
my $completedJobsSHMKey  = 'completed-id';
my $pidTreeSSHMKey = 'pidtree';
our %jobPids=();
tie %jobPids, 'IPC::Shareable', $jobPidsSHMKey, { %shmOptions } or die "tie failed jobPids - $!\n";

our %completedJobs=();
tie %completedJobs, 'IPC::Shareable', $completedJobsSHMKey, { %shmOptions } or die "tie failed %completedJobs= - $!\n";

# %allJobs used when creating resumable file
our %allJobs;
# %pidTree used to track if jobs completed when eix
our %pidTree;
tie %pidTree, 'IPC::Shareable', $pidTreeSSHMKey, { %shmOptions } or die "tie failed %pidTree= - $!\n";

use constant {
    SEM_CHILD_COUNT => 0, # Index for child count semaphore
    SEM_LOCK => 1,        # Index for lock semaphore
};


# Create semaphores
my $sem_key = IPC_PRIVATE; # Private key for IPC
my $sem = IPC::Semaphore->new($sem_key, 2, S_IRUSR | S_IWUSR | IPC_CREAT) or die "Unable to create semaphore: $!";

# Initialize semaphore values
$sem->setval(SEM_CHILD_COUNT, 0);
$sem->setval(SEM_LOCK, 1); # 1 indicates that the lock is available

sub logger {
	my $fh = shift @_;
	my $verbose = shift @_;
	while (@_) {
		my $line = shift @_;
		$fh->print($line);
		print "$line" if $verbose;
	}
	return;
}

sub new {
   my $pkg = shift;
   my $class = ref($pkg) || $pkg;
   #print "Class: $class\n";
   my (%args) = @_;

   my $retval = bless \%args, $class;
   #print 'Sqlrun::new retval: ' . Dumper($retval);
   return $retval;
}

#sub childCleanup {
	#my ($pid) = @_;
	# see cleanup in jobrun.pl
	# also loop through %jobPids and check for those
#}

sub lock {
    # Wait for lock to become available and decrement it
    $sem->op(SEM_LOCK, -1, SEM_UNDO);
}

sub unlock {
    # Increment the lock semaphore to release it
    $sem->op(SEM_LOCK, 1, SEM_UNDO);
}

sub incrementChildren {
    lock();
    # Perform safe increment
    my $current_value = $sem->getval(SEM_CHILD_COUNT);
    $sem->setval(SEM_CHILD_COUNT, $current_value + 1);
    unlock();
}

sub decrementChildren {
    lock();
    # Perform safe decrement
    my $current_value = $sem->getval(SEM_CHILD_COUNT);
	 if ($current_value) {
    	$sem->setval(SEM_CHILD_COUNT, $current_value - 1);
	}
    unlock();
}

sub getChildrenCount {
    # Return current child count
    return $sem->getval(SEM_CHILD_COUNT);
}

sub cleanup {
	# This should be called to cleanup semaphores, typically on program exit
	# or when the job engine dies unexpectedly.
	lock();
	$sem->setval(SEM_CHILD_COUNT, 0);
	$sem->setval(SEM_LOCK, 1);
	unlock();
	$sem->remove();
	undef %jobPids;
	undef %completedJobs;
	undef %pidTree;
	return;
}

sub status {
	print "=== STATUS ===\n";
	foreach my $key ( sort keys %jobPids ) {
		print "job: $key status: $jobPids{$key}\n";
	}
	print "====================================\n";
	return;
}

sub showCompletedJobs {

	print "===  COMPLETED ===\n";
	foreach my $key ( sort keys %completedJobs ) {
		print "job: $key status: $completedJobs{$key}\n";
	}
	print "====================================\n";
	return;

}

sub showAllJobs {
	foreach my $key ( sort keys %allJobs ) {
		#$fh->print("$key:$allJobs{$key}\n") unless exists($completedJobs{$key});
		print "$key:$allJobs{$key}\n";
	}
	return;
}

sub createResumableFile {
	my ($resumableFileName) = @_;

	my $fh = new IO::File;
	$fh->open($resumableFileName, '>') or die "could not create resumable file - $resumableFileName: $!\n";

	foreach my $key ( sort keys %allJobs ) {
		$fh->print("$key:$allJobs{$key}\n") unless exists($completedJobs{$key});
		#$fh->print("$key:$allJobs{$key}\n");
	}
	return;
}

# remove the file if empty
sub cleanupResumableFile {
	my ($resumableFileName) = @_;
	-z $resumableFileName && unlink $resumableFileName;
	return;
}

sub getJobPids {
	return \%jobPids;
}

sub child {
	my $self = shift;
	my ($jobName,$cmd) = @_;

	#print 'SELF: ' . Dumper($self);
	my $grantParentPID=$$;

	my $child = fork();
	#die("Can't fork: $!") unless defined ($child = fork());
	die("Can't fork #1: $!") unless defined($child);

	if ($child) {
		$self->{LOGGER}( "child:$$  cmd:$self->{CMD}\n");

	} else {
		my $parentPID=$$;
		my $grandChild = fork();	
		die("Can't fork #2: $!") unless defined($grandChild);

		if ($grandChild == 0 ) {
			# use system() here
			#qx/$cmd/;
			my $pid=$$;
			$pidTree{$grantParentPID}->{$parentPID}=$pid;

			$jobPids{$self->{JOBNAME}} = "$pid:running";

			$self->{LOGGER}( "grandChild:$pid:running\n");
			#
			$self->{LOGGER} ( "grancChild:$pid running job $self->{JOBNAME}\n");
			system($self->{CMD});
			my $rc = $?;

			if ( $rc != 0 ) {
				$self->{LOGGER} ("#######################################\n");
				$self->{LOGGER} ("## error with $self->{JOBNAME}\n");
				$self->{LOGGER} ("## CMD: $self->{CMD}\n");
				$self->{LOGGER} ("#######################################\n");
			}

			if ($rc == -1) {
				$self->{LOGGER} ("!!failed to execute: $!\n");
			}
			elsif ($rc & 127) {
				$self->{LOGGER} (sprintf "!!child died with signal %d, %s coredump\n",
					($rc & 127),  ($rc & 128) ? 'with' : 'without');
			}
			else {
				$self->{LOGGER} (sprintf "!!child exited with value %d\n", $? >> 8);
			}
	
			decrementChildren();
			$jobPids{$self->{JOBNAME}} = "$pid:complete";
			$completedJobs{$self->{JOBNAME}} = $self->{CMD};
			delete $pidTree{$grantParentPID}->{$parentPID};
			exit $rc;
		} else {
			exit 0;
		}

	};

	waitpid($child,0);
	return;
}


