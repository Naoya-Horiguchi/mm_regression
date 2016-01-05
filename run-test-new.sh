#!/bin/bash

VERBOSE=""
TESTCASE_FILTER=""
RECIPEDIR=
RECIPEFILES=
DEVEL_MODE=

while getopts vs:t:f:Spd:r:D OPT ; do
    case $OPT in
        v) VERBOSE="-v" ;;
        s) KERNEL_SRC="${OPTARG}" ;;
        t) TESTNAME="$OPTARG" ;;
        f) export TESTCASE_FILTER="$TESTCASE_FILTER ${OPTARG}" ;;
        S) SCRIPT=true ;;
		p) SUBPROCESS=true ;;
		d) RECIPEDIR="$OPTARG" ;;
		r) RECIPEFILES="$RECIPEFILES $OPTARG" ;;
		D) DEVEL_MODE=true ;;
    esac
done

shift $[OPTIND-1]
[ "$RECIPEFILES" ] && RECIPEFILES="$(readlink -f $RECIPEFILES)"

for rd in $RECIPEDIR ; do
	if [ -d "$rd" ] ; then
		for rf in $(find $(readlink -f $rd) -type f) ; do
			RECIPEFILES="$RECIPEFILES $rf"
		done
	fi
done

[ ! "$RECIPEFILES" ] && echo "RECIPEFILES not given or not exist." >&2 && exit 1

export TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
# Assuming that current directory is the root directory of the current test.
export TRDIR=$PWD

# keep backward compatibility with older version of test_core
export NEWSTYLE=true

. $TCDIR/setup_generic.sh
. $TCDIR/setup_test_core.sh
. $TCDIR/setup_recipe.sh
. $TCDIR/lib/patch.sh
. $TCDIR/lib/common.sh

# record current revision of test suite and test_core tool
echo "Current test: $(basename $TRDIR)"
( cd $TRDIR ; echo "Test version: $(git log -n1 --pretty="format:%H %s")" )
( cd $TCDIR ; echo "Test Core version: $(git log -n1 --pretty="format:%H %s")" )

echo "TESTNAME/RUNNAME: $TESTNAME"
echo "TESTCASE_FILTER: $TESTCASE_FILTER"
echo "RECIPEFILES: ${RECIPEFILES//$TRDIR\/cases\//}"

for recipe in $RECIPEFILES ; do
	echo "===> recipe $recipe"
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
		echo_verbose "===> SKIPPED: Recipe: $recipe_relpath"
		continue
	fi

	parse_recipefile $recipe .tmp.recipe

	(
		export TEST_TITLE=$recipe_relpath
		export TMPD=$GTMPD/$recipe_relpath
		export TMPF=$TMPD
		export OFILE=$TMPD/result

		if check_testcase_already_run ; then
			echo "### You already have workfiles for recipe $recipe_relpath with TESTNAME: $TESTNAME, so skipped."
			echo "### If you really want to run with removing old work directory, please give environment variable AGAIN=true."
			continue
		fi

		if [ -d $TMPD ] ; then
			rm -rf $TMPD/* > /dev/null 2>&1
		else
			mkdir -p $TMPD > /dev/null 2>&1
		fi

		# TODO: suppress filtered testcases at this point
		# check_testcase_filter || exit 1

		echo_log "===> Recipe: $recipe_relpath (ID: $recipe_relpath)"
		. .tmp.recipe
		mv .tmp.recipe $TMPD/_recipe

		date +%s > $TMPD/start_time

		kill_all_subprograms
		reset_per_testcase_counters

		if [ "$TEST_PROGRAM" ] ; then
			do_test "$TEST_PROGRAM -p $PIPE $VERBOSE"
		else
			do_test_async
		fi

		date +%s > $TMPD/end_time
	) &
	testcase_pid=$!

	# echo_verbose "===> Recipe: $recipe_relpath (ID: $recipe_relpath)"
	# echo_verbose "===> $$ -> $testcase_pid"
	wait $testcase_pid
done

# find $GTMPD -name testcount | while read line ; do echo $line $(cat $line) ; done
# find $GTMPD -name success | while read line ; do echo $line $(cat $line) ; done
# find $GTMPD -name later | while read line ; do echo $line $(cat $line) ; done

ruby $TCDIR/lib/test_summary.rb --only-total $GTMPD
show_summary
