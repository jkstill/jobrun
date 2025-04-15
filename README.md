
Jobrun
======

When you need to run several jobs concurrently, there is frequently a bit of a conundrum.

Some jobs may run very quickly, others may take a long time.

If you split the jobs up equally into different groups, it is easy to run them via some shell scripts.

For instance, you have 8 jobs to run, and you want to run 4 at a time.

Script 1:
- short-job-01.sh
- short-job-02.sh

Script 2:
- long-job-03.sh
- long-job-04.sh

Script 3:
- short-job-05.sh
- long-job-06.sh

Script 4:
- short-job-07.sh
- short-job-08.sh


Scripts 1,3 and 4 may be done long before Script 2 completes.

In fact, the first job in Script 2 may still be running after the others have all finished.

And you will then have to wait on long-job-04 as well.

Using jobrun allows running N jobs concurrently, and starting more jobs as others complete.


## Files

### jobrun.conf

Defaults for jobrun.pl

### jobrun.pid

A PID file created when jobrun.pl starts.

### jobrun.pl

The main Perl script

### jobrun.sh

Alternative Bash script

### jobs.conf

Configure some jobs to run.

### test-job.sh

A test job.

### lib/Jobrun.pm

Logic for controlling jobs to create and run.

The metadata is stored in a CSV table.

Metadata manipulation is done via SQL.



### Examples - jobrun.pl

Start a session:

```text
$  ./jobrun.pl --maxjobs 1 --nodebug --noverbose
jobrun.pl
parent pid: 1038440
:parent:1038440 main loop
parent:1038440 Number of jobs left to run: 9
parent:1038440 sending job: ./test-job.sh job-2 15
JOB: job-2: ./test-job.sh job-2 15
child:1038440  cmd:./test-job.sh job-2 15
```

After a bit, you decide to run 9 jobs concurently, and enable --verbose and --debug.

These values are already set in the jobs.conf file, so send HUP to cause the config file to be reloaded and applied.

```text
$  kill -1 $(cat jobrun.pid)
```

### Examples - jobrun.sh


```text
./jobrun.sh -n -i 2 -m 3 -s logs-sh -t jobrun-sh
```

The following options override the jobrun.conf configuration file

'-n': debug off

'-i 2':  set the loop interval to 2 seconds

'-m': max number of concurrent jobs set to 3

'-s logs-sh':  the name of the log directory

'-t jobrun-sh': log file base name

```

Addd '-y' for the dry run option:

```text
$  ./jobrun.sh -n -i 2 -m 3 -s logs-sh -t jobrun-sh $@ -y
interval seconds: 2

############################################################
## getKV jobrun.conf
############################################################

 key: logdir  val: ./logs
 key: logfile  val: jobrun-sem
 key: verbose  val: 1
 key: logfile-suffix  val: log
 key: maxjobs  val: 4
 key: debug  val: 1
 key: iteration-seconds  val: 9

############################################################
## getKV jobs.conf
############################################################

 key: job-10  val: ./test-job.sh job-10 10
 key: job-1  val: ./test-job.sh job-1 10
 key: job-3  val: ./test-job.sh job-3 10
 key: job-2  val: ./test-job.sh job-2 10
 key: job-5  val: ./test-job.sh job-5 10
 key: job-4  val: ./test-job.sh job-4 10
 key: job-7  val: ./test-job.sh job-7 10
 key: job-6  val: ./test-job.sh job-6 10
 key: job-9  val: ./test-job.sh job-9 10
 key: job-8  val: ./test-job.sh job-8 10

           logDir: logs-sh
    logFileSuffix: log
      logFileName: jobrun-sh
  intervalSeconds: 2
          logFile: logs-sh/jobrun-sh-2024-06-28_14-46-18.log
maxConcurrentJobs: 3
 jobrunConfigFile: jobrun.conf
   jobsConfigFile: jobs.conf
            debug: N
```



## Help - jobrun.pl

```text
  ./jobrun.pl -h
usage: jobrun.pl

  The default values are found in jobrun.conf, and can be changed.

  --config-file        jobrun config file. default: jobrun.conf
  --job-config-file    jobs config file. default: jobs.conf
  --iteration-seconds  seconds between checks to run more jobs. default: 10
  --maxjobs            number of jobs to run concurrently. default: 9
  --logfile-base       logfile basename. default: jobrun-sem
  --status             show status of currently running child jobs
  --status-type        status type to show.
                         all, running, completed, error, failed
                       default: all

  --control-table      The control table to use. default: jobrun_control
                       The control table will be found in the ./tables directory


  --snapshot           adds a timestamp to the control table name
                       this allows maintaining a history of of jobs that have been run


  --resumable          if the script is terminated with -TERM or -INT (CTL-C for instance)
                       a temporary job configuration file is created for jobs not completed
                       this file will be used to restart if --resumable is again used

  --kill               kill the current child jobs and parent
  --logfile-suffix     logfile suffix. default: log
  --reload-config      signal main jobrun.pl process to reload the config file
  --verbose            print more messages: default: 1 or on
  --debug              print debug messages: default: 1 or on
  --help               show this help.

Example:

  ./jobrun.pl --logfile-suffix=load-log --job-config-file dbjobs.conf --maxjobs 1 --nodebug --noverbose

  ./jobrun.pl --verbose --resumable --iteration-seconds 2 --config-file perl-run.conf --job-config-file perl-jobs.conf

 When jobrun.pl starts, it will create a file 'jobrun.pid' in the current directory.

 There are traps on the INT, TERM and QUIT signals.

 Pressing CTL-C will not stop jobrun, but it will print a status message.

 Pressing CTL-\ should kill the program and children.

 'jorun.pl --kill' will kill the parent and children immediately if CTL-\ does not work.

 The config file can be reloaded by sending the HUP signal to the current jobrun.pl parent process.

 Or just run './jobrun.pl' --reload-config.

 Say you have started jobrun with the --noverbose and --nodebug flags, but would now like to change
 that so that more info appears on screen.

 The following command will do that:

 $ kill -1 $(cat jobrun.pid)

 jobrun can also be stopped with QUIT or TERM (see kill -l)

 QUIT
 $ kill -3 $(cat jobrun.pid)

 TERM
 $ kill -15 $(cat jobrun.pid)


 It may take a few moments for the chilren to die.

 The fastest method to stop jobrun is 'jobrun.pl --kill'

```

### Help - jobrun.sh

```text
./jobrun.sh

  -c  resumable
      if the script is terminated with -TERM or -INT (CTL-C for instance)
      a temporary job configuration file is created for jobs not completed
      this file will be used to restart if -c is again used

  -i  interval seconds - default 10
  -j  jobs config file - default jobs.conf
  -r  jobrun config file - default jobrun.conf
  -m  max concurrent jobs - default 5
  -s  log directory  - default logs
  -t  log file base name - default jobrun-sh
  -u  log file suffix - default log
  -d  debug on - output is to STDERR
  -n  debug off - overrides config file
  -y  dry run - read arguments, config file, show variables and exit
  -h  help
```

### ToDo: Things to implement

- correct the line terminator in the jobrun control table
  - it has CRLF line terminators
  - ```text
     $ file tables/jobrun_control_2025_04_15_06_52_26.csv
     tables/jobrun_control_2025_04_15_06_52_26.csv: ASCII text, with CRLF line terminators
```
- populate elapsed time for currently running jobs
  - this is normally updated by the child process
  - maybe a separate process to update the elapsed time?
- option - use system metric to throttle number of jobs
  - for OS - could be load (bad idea, I know, just an example)
  - for Oracle - check AAS - allow up to N jobs to run where N == Cores/2
  - code read from a config file - should return an integer
  - in main config - manually set a threshold value for chosen metric
- results
  - some kind of reporting
  - already done - record the error code from the called program
    - sqlldr for instance returns 0 for success, 1-4 for various warnings and errors
    - [SQLLDR Exit Codes](https://docs.oracle.com/en/database/oracle/oracle-database/19/sutil/oracle-sql-loader-commands.html#GUID-FDC9B490-7C23-4DEF-B826-9FDAEAF0FA64)


