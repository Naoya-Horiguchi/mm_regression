#!/bin/bash

VERBOSE=""
DEVEL_MODE=
# RECIPEFILES might be set as an environment variable
# RECIPEDIR might be set as an environment variable
# TESTCASE_FILTER might be set as an environment variable
SHOW_TEST_VERSION=

while getopts vs:t:f:Spd:r:DV OPT ; do
    case $OPT in
        v) VERBOSE="-v" ;;
        s) KERNEL_SRC="${OPTARG}" ;;
        t) TESTNAME="$OPTARG" ;;
        f) TESTCASE_FILTER="$TESTCASE_FILTER ${OPTARG}" ;;
        S) SCRIPT=true ;;
		p) SUBPROCESS=true ;;
		d) RECIPEDIR="$OPTARG" ;;
		r) RECIPEFILES="$RECIPEFILES $OPTARG" ;;
		D) DEVEL_MODE=true ;;
		V) SHOW_TEST_VERSION=true ;;
    esac
done

shift $[OPTIND-1]

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

# keep backward compatibility with older version of test_core
export NEWSTYLE=true

[ "$RECIPEFILES" ] && RECIPEFILES="$(readlink -f $RECIPEFILES)"

for rd in $RECIPEDIR ; do
	if [ -d "$rd" ] ; then
		for rf in $(find $(readlink -f $rd) -type f) ; do
			RECIPEFILES="$RECIPEFILES $rf"
		done
	fi
done

[ ! "$RECIPEFILES" ] && echo "RECIPEFILES not given or not exist." >&2 && exit 1
export RECIPEFILES

. $TCDIR/lib/recipe.sh
. $TCDIR/lib/patch.sh
. $TCDIR/lib/common.sh

stop_test_running() {
	ps x -o  "%p %r %y %x %c" | grep $$
	kill -9 -$(ps --no-header -o "%r" $$)
}

trap stop_test_running SIGTERM

echo_log "=========> start testing $(basename $TRDIR):$TESTNAME"
echo_log "RECIPEFILES:"
echo_log "${RECIPEFILES//$TRDIR\/cases\//}"

for recipe in $RECIPEFILES ; do
	if [ ! -f "$recipe" ] ; then
		"Recipe $recipe must be a regular file." >&2
		continue
	fi

	recipe_relpath=${recipe##$PWD/cases/}
	# recipe_id=${recipe_relpath//\//_}

	check_remove_suffix $recipe || continue

	if [ "$TESTCASE_FILTER" ] ; then
		filtered=$(echo "$recipe_relpath" | grep $(_a="" ; for f in $TESTCASE_FILTER ; do _a="$_a -e $f" ; done ; echo $_a))
	fi

	if [ "$TESTCASE_FILTER" ] && [ ! "$filtered" ] ; then
		echo_verbose "======= SKIPPED: Recipe: $recipe_relpath"
		continue
	fi

	parse_recipefile $recipe .tmp.recipe

	(
		export TEST_TITLE=$recipe_relpath
		export TMPD=$GTMPD/$recipe_relpath
		export TMPF=$TMPD
		export OFILE=$TMPD/result

		if check_testcase_already_run ; then
			echo_log "### You already have workfiles for recipe $recipe_relpath with TESTNAME: $TESTNAME, so skipped. If you really want to run with removing old work directory, please give environment variable AGAIN=true."
			continue
		fi

		if [ -d $TMPD ] ; then
			rm -rf $TMPD/* > /dev/null 2>&1
		else
			mkdir -p $TMPD > /dev/null 2>&1
		fi

		echo_log "======> Recipe: $recipe_relpath start"
		date +%s > $TMPD/start_time

		# prepare empty testcount file at first because it's used to check
		# testcase result from summary script.
		reset_per_testcase_counters
		init_return_code

		mv .tmp.recipe $TMPD/_recipe
		. $TMPD/_recipe
		ret=$?
		if [ "$SKIP_THIS_TEST" ] ; then
			echo_log "This testcase is marked to be skipped by developer."
			echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		elif [ "$ret" -ne 0 ] ; then
			echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		else
			do_soft_try
		fi

		date +%s > $TMPD/end_time
		echo_log "<====== Recipe: $recipe_relpath done"
	) &
	testcase_pid=$!

	wait $testcase_pid
done

ruby $TCDIR/lib/test_summary.rb $GTMPD
echo_log "<========= end testing $(basename $TRDIR):$TESTNAME"
