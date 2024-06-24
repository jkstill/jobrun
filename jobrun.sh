#!/usr/bin/env bash


# does not work in Bash 3
# does work in Bash 4.2, possibly earlier

# always returns the location of the current script
scriptHome=$(dirname -- "$( readlink -f -- "$0"; )")

cd $scriptHome || { echo "could not cd $scriptHome"; exit 1; }

fileName="$1"

set -u

declare PGID=$$

declare -A runningJobs=()
declare -A runningPIDS
declare -A completedJobs
declare intervalSeconds=3

declare maxConcurrentJobs=5
declare numberJobsRunning
declare pidFileDir=pidfiles

onTerm () {
	echo
	echo "TERM: Cleaning up"
	ps -o pgid,pid,ppid,cmd | grep "^$PGID"
	kill -KILL -- -$PGID
	echo
	exit
}

trap onTerm SIGV TERM INT

fileIsReadable () {
	if [[ -r "$1" ]]; then
		return 0
	else
		return 1
	fi
}

getTimestamp () {
	date '+%Y-%m-%d %H:%M:%S'
}

# return array of key value pairs
getKV () {
	local arrayName="$1"
	local fileName="$2"

	fileIsReadable $fileName
	RC=$?
	if [[ $RC -eq 0 ]]; then
		while IFS=: read key value
		do
			#echo "getKV - key: $key  value: $value" 1>&2
			#echo "$arrayName['$key']"="'$value'"
			eval "$arrayName['$key']"="'$value'"
		done < <(grep -Ev '^\s*$|^\s*#' $fileName) 
	else
		echo "cannot read file $fileName"
		exit 1
	fi
}

showKV () {
	# works directly with Hash Array in Bash 4.3+
	#local -n arrayName="$1" #[@];shift
	# value required in older versions

	local arrayName="$1"

	local -a keys
	declare keyString='${!'$arrayName'[@]}'

	declare -a keys
	eval keys="$keyString"

	for key in ${keys[@]}
	do
		eval 'val=${'$arrayName'['$key']}'
		echo "key: $key  val: $val"
		#echo key: $key
	done

	return 0
}


declare -A jobsConf
declare -A jobrunConf

getKV jobrunConf jobrun.conf
getKV jobsConf jobs.conf

echo '### jobrun.conf ###'
showKV jobrunConf

echo '### jobs.conf ###'
showKV jobsConf

for key in "${!jobsConf[@]}"
do
	echo "key: $key   val: ${jobsConf[$key]}"
done

declare -a jobKeys=${!jobsConf[@]}

#maxConcurrentJobs=5
numberJobsRunning=0
#runningJobs=()

userName=$(id -un)

for jobKey in ${jobKeys[@]}
do
	echo jobkey: $jobKey

	if [[ ${#runningJobs[@]} -lt $maxConcurrentJobs ]]; then

		(( numberJobsRunning++ ))
		runningJobs[$jobKey]=${jobsConf[$jobKey]}
		exec ${jobsConf[$jobKey]} &
		childPID=$!
		runningPIDS[$childPID]=$jobKey
		mkdir -p $pidFileDir
		ps -p $childPID -o pid,ppid,cmd > $pidFileDir/${childPID}.pid
		unset jobsConf[$jobKey]
		echo "Continuing"
		continue

	fi
	
	echo "Checking RunPIDS"

	for runPID in ${!runningPIDS[@]} 
	do
		echo "chk runPID: $runPID"
		psOUT=$(ps --no-headers -p $runPID -o user,pid | grep "^$userName")
		declare RC=$?

		#echo "RC: $RC"
		#echo "psOUT: $psOUT"
		#echo "runPID: $runPID"

		timestamp="$(getTimestamp)"

		if [[ $RC -eq 0 ]]; then
			echo "running PID Job: ${runningPIDS[$runPID]}"
			declare currJob=${runningPIDS[$runPID]}
			unset runningJobs[$currJob]
			echo "$timestamp - still running "  >> $pidFileDir/${runPID}.pid 
			(( numberJobsRunning-- ))
		else
			echo "$timestamp - finished "  >> $pidFileDir/${runPID}.pid 
		fi
	done

	[[ ${#jobsConf[@]} -lt 1 ]] && { break; }

	echo "sleep $intervalSeconds"
	sleep $intervalSeconds

done

wait

echo "runningJobs:"
showKV runningJobs

echo "jobsConf:"
showKV jobsConf













