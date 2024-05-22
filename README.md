
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

The main script

### jobs.conf

Configure some jobs to run.

### test-job.sh

A test job.

### lib/Jobrun.pm

Logic for controlling semaphores and job creation

### Examples

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


### Things to implement

- track job by pid, job name and status
- resumable - persist status and results
  - option - set a jobrun ID for the batch of jobs
    - used to identify file
	 - or maybe just a name for the results file
	 - skip jobs that have already run and have status == 1
  - option - rerun or not rerun failed jobs - status == 2
- check if job running when status == 2
- option - use system metric to throttle number of jobs
  - for OS - could be load (bad idea, I know, just an example)
  - for Oracle - check AAS - allow up to N jobs to run where N == Cores/2
  - code read from a config file - should return an integer
  - in main config - manually set a threshold value for chosen metric
- results
  - some kind of reporting


