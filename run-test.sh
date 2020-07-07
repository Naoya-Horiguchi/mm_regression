#!/bin/bash

DEVEL_MODE=
# LOGLEVEL might be set as an environment variable
# RECIPELIST might be set as an environment variable
# TESTCASE_FILTER might be set as an environment variable
SHOW_TEST_VERSION=
# PRIORITY might be set as an environment variable
RUN_ALL_WAITING=

while getopts v:s:t:f:Sp:DVw OPT ; do
    case $OPT in
        v) export LOGLEVEL="$OPTARG" ;;
        s) KERNEL_SRC="$OPTARG" ;;
        t) TESTNAME="$OPTARG" ;;
        f) TESTCASE_FILTER="$TESTCASE_FILTER $OPTARG" ;;
        S) SCRIPT=true ;;
		p) PRIORITY=$OPTARG ;;
		D) DEVEL_MODE=true ;;
		V) SHOW_TEST_VERSION=true ;;
		w) RUN_ALL_WAITING=true ;;
    esac
done

shift $[OPTIND-1]

export LANG=C
export LC_ALL=C

export TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
# Assuming that current directory is the root directory of the current test.
export TRDIR=$PWD

. $TCDIR/setup_generic.sh
. $TCDIR/setup_test_core.sh

# record current revision of test suite and test_core tool
if [ "$SHOW_TEST_VERSION" ] ; then
	echo "Current test: $(basename $TRDIR)"
	echo "TESTNAME/RUNNAME: $TESTNAME"
	( cd $TRDIR ; echo "Test version: $(git log -n1 --pretty="format:%H %s")" )
	( cd $TCDIR ; echo "Test Core version: $(git log -n1 --pretty="format:%H %s")" )
	exit 0
fi

. $TCDIR/lib/recipe.sh
. $TCDIR/lib/patch.sh
. $TCDIR/lib/common.sh

if [ "$USER" = root ] ; then
	echo 1 > /proc/sys/kernel/panic_on_oops
	echo 1 > /proc/sys/kernel/softlockup_panic
	echo 1 > /proc/sys/kernel/softlockup_all_cpu_backtrace
fi

stop_test_running() {
	echo "kill_all_subprograms $$"
	kill_all_subprograms $$
	exit
}

trap stop_test_running SIGTERM SIGINT

skip_testcase_out_priority() {
	echo_log "This testcase is skipped because the testcase priority ($TEST_PRIORITY) is not within given priority range [$PRIORITY]."
	echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
}

run_recipe() {
	export RECIPE_FILE="$1"
	local recipe_relpath=$(echo $RECIPE_FILE | sed 's/.*cases\///')
	export TEST_TITLE=$recipe_relpath
	export RTMPD=$GTMPD/$recipe_relpath
	export TMPF=$TMPD

	if [ -d $RTMPD ] && [ "$AGAIN" == true ] ; then
		rm -rf $RTMPD/* > /dev/null 2>&1
	fi
	mkdir -p $RTMPD > /dev/null 2>&1

	# recipe run status check
	check_testcase_already_run && return
	check_remove_suffix $RECIPE_FILE || return

	# just for saving, not functional requirement.
	cp $RECIPE_FILE $RTMPD/_recipe

	( set -o posix; set ) > $RTMPD/.var1

	TEST_PRIORITY=10 # TODO: better place?
	. $RECIPE_FILE
	ret=$?
	echo_log "===> testcase '$TEST_TITLE' start" | tee /dev/kmsg

	if [ "$SKIP_THIS_TEST" ] ; then
		echo_log "This testcase is marked to be skipped by developer."
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		echo SKIPPED > $RTMPD/run_status
	elif [ "$ret" -ne 0 ] ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		echo SKIPPED > $RTMPD/run_status
	elif ! check_skip_priority $TEST_PRIORITY ; then
		skip_testcase_out_priority
		echo SKIPPED > $RTMPD/run_status
	elif check_test_flag ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		echo SKIPPED > $RTMPD/run_status
		# TODO: check_inclusion_of_fixedby_patch && break
	else
		save_environment_variables

		# reminder for restart after reboot. If we find this file when starting,
		# that means the reboot was triggerred during running the testcase.
		if [ -f $GTMPD/current_testcase ] && [ "$RECIPE_FILE" = $(cat $GTMPD/current_testcase) ] ; then
			# restarting from reboot
			RESTART=true
		else
			echo $RECIPE_FILE > $GTMPD/current_testcase
		fi
		echo RUNNING > $RTMPD/run_status
		date +%s%3N > $RTMPD/start_time
		sync
		# TODO: put general system information under $RTMPD
		# prepare empty testcount file at first because it's used to check
		# testcase result from summary script.
		reset_per_testcase_counters
		echo_verbose "PID calling do_soft_try $BASHPID"
		do_soft_try > >(tee -a $RTMPD/result) 2>&1
		date +%s%3N > $RTMPD/end_time
		echo FINISHED > $RTMPD/run_status
		rm -f $GTMPD/current_testcase
		echo -n cases/$recipe_relpath > $GTMPD/finished_testcase
		sync
	fi
	echo_log "<=== testcase '$TEST_TITLE' end" | tee /dev/kmsg
}

run_recipes() {
	local pid=
	local basedir=$(echo $@ | cut -f1 -d:)
	local elms="$(echo $@ | cut -f2- -d:)"
	# echo "- parsing [$basedir] $elms"

	if [ -f "$basedir/config" ] ; then
		# TODO: this is a hack for dir_cleanup, to be simplified.
		local tmp="$(echo $basedir | sed 's|cases|work/'${RUNNAME:=debug}'|')"
		echo $BASHPID > $tmp/BASHPID
		. "$basedir/config"
		if [ "$?" -ne 0 ] ; then
			echo "skip this directory due to the failure in $basedir/config" >&2
			return 1
		fi
	fi

	local elm=
	local keepdir=
	local linerecipe=
	for elm in $elms ; do
		local dir=$(echo $elm | cut -f1 -d/)
		local abc=$(echo $elm | cut -f2- -d/)

		# echo "-- $elm: $dir, $abc"
		if [ "$elm" = "$dir" ] ; then # file
			if [ "$keepdir" ] ; then # end of previous dir
				(
					run_recipes "$linerecipe"
				) &
				pid=$!
				echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
				wait $pid
				keepdir=
				linerecipe=
			fi
			# execute file recipe
			# echo "--- Execute recipe: $basedir/$elm"
			(
				run_recipe "$basedir/$elm"
			) &
			pid=$!
			echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
			wait $pid
		else # dir
			if [ "$keepdir" != "$dir" ] ; then # new dir
				if [ "$keepdir" ] ; then # end of previous dir
					# echo "--- 1: run_recipes \"$linerecipe\""
					(
						run_recipes "$linerecipe"
					) &
					pid=$!
					echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
					wait $pid
					linerecipe=
				fi
				linerecipe="${basedir:+$basedir/}$dir: $abc"
				keepdir=$dir
				# echo "--- 3"
			else # keep dir
				linerecipe="$linerecipe $abc"
				# echo "--- 5"
			fi
		fi
	done
	if [ "$linerecipe" ] ; then
		(
			run_recipes "$linerecipe"
		) &
		pid=$!
		echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
		wait $pid
	fi

	if [ -s "$tmp/BASHPID" ] && [ "$(cat $tmp/BASHPID)" = "$BASHPID" ] ; then
		dir_cleanup
	fi
}

if [ -f "$RECIPELIST" ] ; then
	cp $RECIPELIST $GTMPD/recipelist
elif [ ! -f "$GTMPD/recipelist" ] ; then
	if [ -f "$GTMPD/full_recipe_list" ] ; then
		cp $GTMPD/full_recipe_list $GTMPD/recipelist
	else
		make --no-print-directory allrecipes | grep ^cases | sort > $GTMPD/recipelist
	fi
fi
# make --no-print-directory RUNNAME=$RUNNAME waiting_recipes | grep ^cases > $GTMPD/waiting_recipe_list

. $TCDIR/lib/environment.sh

if [ "$USER" != root ] ; then
	run_recipes ": $(cat $GTMPD/recipelist | tr '\n' ' ')"
	exit
fi

setup_systemd_service
if [ "$BACKGROUND" ] ; then
	systemctl start test.service
	exit
fi
run_recipes ": $(cat $GTMPD/recipelist | tr '\n' ' ')"
cancel_systemd_service
echo "All testcases in project $RUNNAME finished."
ruby test_core/lib/test_summary.rb work/$RUNNAME
