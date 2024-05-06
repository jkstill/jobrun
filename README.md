

Things to implement

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

