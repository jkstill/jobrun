#!/usr/bin/env bash

ps -u jkstill -o pid,cmd | grep -E 'perl ./[j]obrun.pl'| awk '{ print $1 }' | xargs -n 1 kill -9


