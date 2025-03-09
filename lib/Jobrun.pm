# Jared Still
# 2024-05-21
# jkstill@gmail.com
#
# use to fork a process to run a job
# jobrun.pl is the front end
######################################################

=head1 Jobrun.pm

TODO

=cut


package Jobrun;

use warnings;
use strict;
use Data::Dumper;
use File::Temp qw/ :seekable tmpnam/;
use DBI;
use Carp;
use IO::File;
use POSIX qw(strftime);
use Time::HiRes qw(time usleep);

use lib '.';

require Exporter;
our @ISA= qw(Exporter);
our @EXPORT_OK = qw(logger);
our @EXPORT = qw();
our $VERSION = '0.01';

our $tableDir = './tables';
mkdir $tableDir unless -d $tableDir;
-d $tableDir or croak "table directory $tableDir not created: $!\n";

our $controlTable;
sub setControlTable {
	$controlTable = shift;
}

sub getControlTable {
	return $controlTable;
}

# call this just once from the driver script jobrun.pl
our $utilDBH;
sub init {
	$utilDBH = createDbConnection();
	createTable();
	truncateTable();
}

sub createDbConnection {
	my $dbh = DBI->connect ("dbi:CSV:", undef, undef, 
		{
			f_ext      => ".csv",
			f_dir      => $tableDir,
			flock      => 2,
			RaiseError => 1,
		}
	) or croak "Cannot connect: $DBI::errstr";

	return $dbh;
}

# add start,end,elapsed time to table

sub createTable {
	# create table if it does not exist
	eval {
		local $utilDBH->{RaiseError} = 1;
		local $utilDBH->{PrintError} = 0;

		$utilDBH->do (
			qq{CREATE TABLE $controlTable (
				name CHAR(50)
				, pid CHAR(12)
				, status CHAR(20)
				, start_time CHAR(30)
				, end_time CHAR(30)
				, elapsed_time CHAR(20)
				, exit_code CHAR(10)
				, cmd CHAR(200))
			}
		);
	
	};

	#if ($@) {
	#print "Error: $@\n";
	#print "Table most likely already exists\n";
	#}

	return;
}

sub truncateTable {
	$utilDBH = createDbConnection();
	$utilDBH->do("DELETE FROM $controlTable");
	return;
}

sub insertTable {
	my $self = shift;
	#print 'insertTable SELF: ' . Dumper($self);
	my $dbh = $self->{dbh};
	my ($name,$pid,$status,$startTime, $endTime, $elapsedTime, $exit_code, $cmd) = @_;
	my $sth = $dbh->prepare("INSERT INTO $controlTable (name,pid,status,start_time,end_time,elapsed_time,exit_code,cmd) VALUES (?,?,?,?,?,?,?,?)");
	$sth->execute($name,$pid,$status,$startTime, $endTime, $elapsedTime, $exit_code, $cmd);
	# DBD::CSV always autocommits
	# this is here in the event that we use a different DBD
	#$dbh->commit();
}

sub deleteTable {
	my $self = shift;
	my $dbh = $self->{dbh};
	my ($name) = @_;
	my $sth = $dbh->prepare("DELETE FROM $controlTable WHERE name = ?");
	$sth->execute($name);
	#$dbh->commit();
}

sub selectTable {
	my $self = shift;
	my ($column,$value) = @_;
	my $dbh = $self->{dbh};
	my $sth = $dbh->prepare("SELECT * FROM $controlTable WHERE ? = ?");
	$sth->execute($column,$value);
	my $hashRef = $sth->fetchall_hashref;
	return $hashRef;
}

# only updates status and exit_code
sub updateStatus {
	my $self = shift;
	my $dbh = $self->{dbh};
	my ($name,$status,$exit_code,$startTime,$endTime,$elapsedTime) = @_;
	my $sth = $dbh->prepare("UPDATE $controlTable SET status = ?, exit_code = ?, start_time = ? , end_time = ?, elapsed_time = ?  WHERE name = ?");
	$sth->execute($status,$exit_code,$startTime,$endTime,$elapsedTime,$name);
	#$dbh->commit();
}

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
	
	$args{dbh} = createDbConnection();
	
	$args{insert} = \&insertTable;
	$args{updateStatus} = \&updateStatus;
	$args{delete} = \&deleteTable;
	$args{select} = \&selectTable;

	# name,pid,status,start_time,end_time,elapsed_time,exit_code,cmd) VALUES (?,?,?,?,?)");
	
	$args{columnNamesByName} = { name => 0, pid => 1, cmd => 2,  status => 3, exit_code => 4};
	$args{columnNamesByIndex} = { 0 => 'name', 1 => 'pid', 2 => 'cmd', 3 => 'status', 4 => 'exit_code'};
	$args{columnValues} = [qw/undef undef undef undef undef/];

	my ($user,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire)
   	= getpwuid($<) or croak "getpwuid: $!";
	print "User: $user, UID: $uid\n";

   my $retval = bless \%args, $class;

	$retval->{insert}( $retval,
		$retval->{JOBNAME},  #job name
		$$, #pid
		,'running' #status
		,'NA' #exit code
		, '' #start time
		, '' #end time
		, '' #elapsed time
		, $retval->{CMD}, #command

	);
   return $retval;
}

sub getChildrenCount {
	# Return current child count
	my $sth = $utilDBH->prepare("SELECT count(*) child_count FROM $controlTable WHERE status = 'running'");
	$sth->execute();
	my $row = $sth->fetchrow_hashref;
	return $row->{child_count} ? $row->{child_count} : 0;
}

# status is called as a separate process
# and will have not knowledge of the Jobrun object
# so we need to pass the controlTable name
sub status {
	my ($controlTable, $statusType, %config) = @_;
	my $dbh = createDbConnection();
	my $sql;
	-r "$tableDir/${controlTable}.csv" or croak "table $tableDir/$controlTable.csv does not exist: $!\n";
	if ($statusType eq 'all') {
		$sql = "SELECT * FROM $controlTable order by start_time desc";
	} else {
		$sql = "SELECT * FROM $controlTable WHERE status = '$statusType' order by start_time desc";
	}

	print "table: $controlTable\n";

	my $sth = $dbh->prepare($sql);
	$sth->execute();
	# %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %-$config{colLenELAPSED_TIME}s
	printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %-$config{colLenELAPSED_TIME}s %-$config{colLenCMD}s\n", 
		'name', 'pid','status', 'exit_code', 'start_time','end_time', 'elapsed', 'cmd';

	printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %-$config{colLenELAPSED_TIME}s %-$config{colLenCMD}s\n", 
		'-' x $config{colLenNAME}, '-' x $config{colLenPID}, '-' x $config{colLenSTATUS}, '-' x $config{colLenEXIT_CODE}, 
		'-' x $config{colLenSTART_TIME}, '-' x $config{colLenEND_TIME} , '-' x $config{colLenELAPSED_TIME} ,
		'-' x $config{colLenCMD};
	while (my $row = $sth->fetchrow_hashref) {
		my  $rowlen = length($row->{cmd}) + 0;
		#warn "rowlen: $rowlen\n";
		printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %$config{colLenELAPSED_TIME}s %-$config{colLenCMD}s\n",
			$row->{name},
			$row->{pid},
			$row->{status},
			$row->{exit_code},
			$row->{start_time},
			$row->{end_time},
			sprintf('%6.6f',$row->{elapsed_time} ? $row->{elapsed_time} : 0),
			substr(
				$row->{cmd},
				defined($config{colCmdStartPos}) ? $config{colCmdStartPos} : 0,
				defined( $config{colCmdEndPos}) 
					? $config{colCmdEndPos} 
					: ($rowlen - 1),
			);
	}
	return;
}

sub createResumableFile {
	my ($resumableFileName,$jobsHashRef) = @_;

	my $fh = new IO::File;
	$fh->open($resumableFileName, '>') or croak "could not create resumable file - $resumableFileName: $!\n";

	my  $dbh = createDbConnection();
	# cannot figure  out use to get '!=' or 'not in' to work with DBD::CSV
	my $sql = "SELECT name,status FROM $controlTable";
	#warn "SQL: $sql\n";
	my $sth = $dbh->prepare($sql);
	$sth->execute();	
	while (my @row = $sth->fetchrow_array) {
		next if $row[1] eq 'complete';
		$fh->print("$row[0]" . ':' . "$jobsHashRef->{$row[0]}\n");
	}
	return;
}

# remove the file if empty
sub cleanupResumableFile {
	my ($resumableFileName) = @_;
	-z $resumableFileName && unlink $resumableFileName;
	return;
}

# this may be called with --kill, so we need to create a connection
sub getRunningJobPids {
	my $dbh = createDbConnection();
	my $sth = $dbh->prepare("SELECT pid FROM $controlTable WHERE status = 'running'");
	$sth->execute();
	my @jobPids;
	while (my $row = $sth->fetchrow_hashref) {
		push @jobPids, $row->{pid};
	}
	return @jobPids;
}

sub microSleep {
	my $microseconds = shift;
	usleep(($microseconds/1000000)*1000000);
}

sub getTimeStamp {
	my @t = [Time::HiRes::gettimeofday]->@*;
	return strftime("%Y-%m-%d %H:%M:%S", localtime $t[0]) . "." . $t[1];
}
 
sub getTableTimeStamp {
	my @t = [Time::HiRes::gettimeofday]->@*;
	return strftime("%Y_%m_%d_%H_%M_%S", localtime $t[0]);
}
 
sub child {
	my $self = shift;
	my ($jobName,$cmd) = @_;

	#print 'SELF: ' . Dumper($self);
	my $grantParentPID=$$;

	my $child = fork();
	#croak("Can't fork: $!") unless defined ($child = fork());
	croak("Can't fork #1: $!") unless defined($child);

	if ($child) {
		logger($self->{LOGFH},$self->{VERBOSE},"child:$$  cmd:$self->{CMD}\n");

	} else {
		my $parentPID=$$;
		my $grandChild = fork();	
		croak("Can't fork #2: $!") unless defined($grandChild);

		if ($grandChild == 0 ) {
			# use system() here
			#qx/$cmd/;
			my $pid=$$;
			logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
			logger($self->{LOGFH},$self->{VERBOSE}, "## job name: $self->{JOBNAME} child pid: $pid\n");
			logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
			my $dbh = $self->{dbh};
			my $sth = $dbh->prepare("UPDATE $controlTable SET pid = ? WHERE name = ?");
			$sth->execute($pid,$self->{JOBNAME});
			#$dbh->commit();

			#$jobPids{$self->{JOBNAME}} = "$pid:running";

			#logger($self->{LOGFH},$self->{VERBOSE}, "grandChild:$pid:running\n");
			##
			#logger($self->{LOGFH} ,$self->{VERBOSE}, "grancChild:$pid running job $self->{JOBNAME}\n");
			# run the command here
			my $startTime = getTimeStamp();
			my @t0 = [Time::HiRes::gettimeofday]->@*;
			$self->{updateStatus}($self,$self->{JOBNAME},'running','',$startTime,'','');
			system($self->{CMD});
			my $rc = $?>>8;
			my @t1 = [Time::HiRes::gettimeofday]->@*;
			my $endTime = getTimeStamp();

			my $elapsedTime = sprintf("%.6f", Time::HiRes::tv_interval(\@t0,\@t1));

			if ( $rc != 0 ) {
				logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
				logger($self->{LOGFH},$self->{VERBOSE}, "## error with $self->{JOBNAME}\n");
				logger($self->{LOGFH},$self->{VERBOSE}, "## CMD: $self->{CMD}\n");
				logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
			}

			my $jobStatus = 'complete';
			if ($rc == -1) {
				$jobStatus = 'failed';
				logger($self->{LOGFH},$self->{VERBOSE}, "!!failed to execute: $!\n");
			}
			elsif ($rc & 127) {
				$jobStatus = 'error';
				logger($self->{LOGFH},$self->{VERBOSE}, sprintf "!!child $pid died with signal %d, %s coredump\n",
					($rc & 127),  ($rc & 128) ? 'with' : 'without');
			}
			else {
				logger($self->{LOGFH},$self->{VERBOSE}, sprintf "!!child $pid exited with value %d\n", $? >> 8);
			}
	
			# it should not be necessary to pass $self here, not sure yet why it is necessary
			$self->{updateStatus}($self,$self->{JOBNAME},$jobStatus,$rc,$startTime,$endTime,$elapsedTime);
			exit $rc;

		} else {
			exit 0;
		}

	};

	waitpid($child,0);
	return;
}

1;

