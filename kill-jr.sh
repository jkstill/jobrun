#!/usr/bin/env bash

ps -u $(id -un) -o pid,cmd | grep -E 'perl .+./[j]obrun.pl'| awk '{ print $1 }' | xargs -n 1 kill -9


