#!/bin/bash

. $TCDIR/lib/mm.sh

get_vma_protection() { grep -A 2 700000000000 /proc/$pid/maps; }

prepare_hugepage_migration() {
	prepare_mm_generic || return 1

	if [ "$RESERVE_HUGEPAGE" ] ; then
		$hog_hugepages -m private -n $RESERVE_HUGEPAGE -r &
		set_return_code RESERVE
		sleep 1 # TODO: properly wait for reserve completion
	fi

	if [ "$ALLOCATE_HUGEPAGE" ] ; then
		$hog_hugepages -m private -n $ALLOCATE_HUGEPAGE -N $ALLOCATE_NODE &
		set_return_code ALLOCATE
		sleep 1 # TODO: properly wait for reserve completion
	fi

	if [ "$MIGRATE_TYPE" = hotremove ] ; then
		reonline_memblocks
	fi

	return 0
}

cleanup_hugepage_migration() {
	cleanup_mm_generic

	if [ "$MIGRATE_TYPE" = hotremove ] ; then
		reonline_memblocks
	fi
}

check_hugepage_migration() {
	# migration from madv_soft allows page migration within the same node,
	# so it's meaningless to compare node statistics.
	if [ "$HUGETLB" ] && [[ "$EXPECTED_RETURN_CODE" =~ " MIGRATION_PASSED" ]] && \
		   [ -s $TMPD/numa_maps2 ] && [ "$MIGRATE_SRC" != "madv_soft" ] ; then
		check_numa_maps
	fi

	if [ "$CGROUP" ] && [ -s $TMPD/memcg2 ] ; then
		# TODO: meaningful check/
		diff -u $TMPD/memcg0 $TMPD/memcg1 | grep -e ^+ -e ^-
		diff -u $TMPD/memcg1 $TMPD/memcg2 | grep -e ^+ -e ^-
	fi
}

check_numa_maps() {
    local map1="$(grep " huge " $TMPD/numa_maps1 | sed -r 's/.* (N[0-9]*=[0-9]*).*/\1/g' | tr '\n' ' ')"
    local map2="$(grep " huge " $TMPD/numa_maps2 | sed -r 's/.* (N[0-9]*=[0-9]*).*/\1/g' | tr '\n' ' ')"

    count_testcount "CHECK /proc/pid/numa_maps"
    if [ "$map1" == "$map2" ] ; then
        count_failure "hugepage is not migrated ($map1, $map2)"
    else
        count_success "hugepage is migrated. ($map1 -> $map2)"
    fi
}

control_hugepage_migration() {
    local pid="$1"
    local line="$2"

	if [ "$pid" ] ; then # sync mode
		echo_log "$line"
		case "$line" in
			"just started")
				# TODO: Need better data output
				get_numa_maps $pid | grep 700000
				grep ^Huge /proc/meminfo
				cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/free_hugepages
				cat /sys/devices/system/node/node1/hugepages/hugepages-2048kB/free_hugepages

				if [ "$CGROUP" ] ; then
					cgclassify -g $CGROUP $pid
					cgget -g $CGROUP > $TMPD/memcg0
				fi

				kill -SIGUSR1 $pid
				;;
			"page_fault_done")
				grep ^Huge /proc/meminfo
				get_numa_maps $pid | tee $TMPD/numa_maps1 | grep ^700000 | tee -a $OFILE
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -Nrl | grep -v offset | tee $TMPD/pagetypes1 | head -n30
				cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/free_hugepages
				cat /sys/devices/system/node/node1/hugepages/hugepages-2048kB/free_hugepages
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -NrL | grep -v offset | cut -f1,2 > $TMPD/mig1

				# TODO: better condition check
				if [ "$RACE_SRC" == "race_with_gup" ] ; then
					$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
					$PAGETYPES -p $pid -r -b anon | grep total
					ps ax | grep thp
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					( for i in $(seq 10) ; do migratepages $pid 0 1 ; migratepages $pid 1 0 ; done ) &
				fi

				# TODO: better condition check
				if [ "$RACE_SRC" == "race_with_fork" ] ; then
					$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
					$PAGETYPES -p $pid -r -b anon | grep total
					ps ax | grep thp
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					( for i in $(seq 10) ; do migratepages $pid 0 1 ; migratepages $pid 1 0 ; done ) &
				fi

				if [ "$MIGRATE_SRC" = auto_numa ] ; then
					echo "current CPU: $(ps -o psr= $pid)"
					taskset -p $pid
				fi

				if [ "$MIGRATE_SRC" = change_cpuset ] ; then
					cgclassify -g cpu,cpuset,memory:test1 $pid
					[ $? -eq 0 ] && set_return_code CGCLASSIFY_PASS || set_return_code CGCLASSIFY_FAIL
					echo "cat /sys/fs/cgroup/memory/test1/tasks"
					cat /sys/fs/cgroup/memory/test1/tasks
					ls /sys/fs/cgroup/memory/test1/tasks
					cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
					# $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
					$PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPD/pagetypes1

					cgset -r cpuset.mems=0 test1
					cgset -r cpuset.mems=1 test1
					cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
				fi

				kill -SIGUSR1 $pid
				;;
			"entering busy loop")
				# sysctl -a | grep huge

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg1
				fi

				# check migration pass/fail now.
				if [ "$MIGRATE_SRC" = migratepages ] ; then
					echo "do migratepages"
					do_migratepages $pid
					# if [ $? -ne 0 ] ; then
					# 	set_return_code MIGRATEPAGES_FAILED
					# else
					# 	set_return_code MIGRATEPAGES_PASSED
					# fi
					sleep 1
				fi

				if [ "$MIGRATE_SRC" = hotremove ] ; then
					echo_log "do memory hotplug ($(cat $TMPD/preferred_memblk))"
					echo_log "echo offline > /sys/devices/system/memory/memory$(cat $TMPD/preferred_memblk)/state"
					echo offline > /sys/devices/system/memory/memory$(cat $TMPD/preferred_memblk)/state
					if [ $? -ne 0 ] ; then
						set_return_code MEMHOTREMOVE_FAILED
						echo_log "do_memory_hotremove failed."
					fi
				fi

				if [ "$OPERATION_TYPE" == mlock ] ; then
					$PAGETYPES -p $pid -Nrl -a 0x700000000+$[THP * 512] | head
				fi

				if [ "$OPERATION_TYPE" == mprotect ] ; then
					get_vma_protection
					$PAGETYPES -p $pid -Nrl -a 0x700000000+$[THP * 512] | head
				fi

				if [ "$MIGRATE_SRC" = auto_numa ] ; then
					# Current CPU/Memory should be NUMA non-optimal to kick
					# auto NUMA.
					echo "current CPU: $(ps -o psr= $pid)"
					taskset -p $pid
					get_numa_maps $pid | tee $TMPD/numa_maps1 | grep ^70000
					# get_numa_maps ${pid}
					$PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
					grep numa_hint_faults /proc/vmstat
					# expecting numa balancing migration
					sleep 3
					echo "current CPU: $(ps -o psr= $pid)"
					taskset -p $pid
					get_numa_maps $pid | tee $TMPD/numa_maps2 | grep ^70000
					$PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
					grep numa_hint_faults /proc/vmstat
				fi

				if [ "$MIGRATE_SRC" = change_cpuset ] ; then
					$PAGETYPES -p $pid -r -b anon | grep total
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					grep RssAnon /proc/$pid/status
					$PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPD/pagetypes2
				fi

				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -NrL | grep -v offset | cut -f1,2 > $TMPD/mig2
				# count diff stats
				diff -u0 $TMPD/mig1 $TMPD/mig2 > $TMPD/mig3
				diffsize=$(grep -c -e ^+ -e ^- $TMPD/mig3)
				if [ "$diffsize" -eq 0 ] ; then
					set_return_code MIGRATION_FAILED
					echo "page migration failed."
				else
					echo "pfn/vaddr shows $diffsize diff lines"
					set_return_code MIGRATION_PASSED
				fi

				kill -SIGUSR2 $pid
				;;
			"exited busy loop")
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -Nrl | grep -v offset | tee $TMPD/pagetypes2 | head -n 30
				get_numa_maps $pid   > $TMPD/numa_maps2

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg2
				fi
				kill -SIGUSR1 $pid
				set_return_code EXIT
				return 0
				;;
			"mbind failed")
				# TODO: how to handle returncode?
				# set_return_code MBIND_FAILED
				kill -SIGUSR1 $pid
				;;
			"move_pages failed")
				# TODO: how to handle returncode?
				# set_return_code MOVE_PAGES_FAILED
				kill -SIGUSR1 $pid
				;;
			"madvise(MADV_SOFT_OFFLINE) failed")
				kill -SIGUSR1 $pid
				;;
			"before memory_hotremove"* )
				echo $line | sed "s/before memory_hotremove: *//" > $TMPD/preferred_memblk
				echo_log "preferred memory block: $targetmemblk"
				$PAGETYPES -rNl -p ${pid} -b huge,compound_head=huge,compound_head > $TMPD/pagetypes1 | head
				grep -i huge /proc/meminfo
				# find /sys -type f | grep hugepage | grep node | grep 2048
				# find /sys -type f | grep hugepage | grep node | grep 2048 | xargs cat
				get_numa_maps ${pid} | tee -a $OFILE > $TMPD/numa_maps1
				kill -SIGUSR1 $pid
				;;
			"need unpoison")
				$PAGETYPES -b hwpoison,huge,compound_head=hwpoison,huge,compound_head -x -N | head
				kill -SIGUSR2 $pid
				;;
			"start background migration")
				run_background_migration $pid &
				BG_MIGRATION_PID=$!
				kill -SIGUSR2 $pid
				;;
			"parepared_for_process_vm_access")
				local cpid=$(pgrep -P $pid .)
				echo "$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head -Nl"
				$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head -Nl
				echo "$PAGETYPES -p $cpid -r -b thp,compound_head=thp,compound_head -Nl"
				$PAGETYPES -p $cpid -r -b thp,compound_head=thp,compound_head -Nl
				( for i in $(seq 20) ; do
						migratepages $pid 0 1  2> /dev/null
						migratepages $pid 1 0  2> /dev/null
						migratepages $cpid 0 1 2> /dev/null
						migratepages $cpid 1 0 2> /dev/null
						done ) &
				kill -SIGUSR1 $pid
				;;
			"exit")
				kill -SIGUSR1 $pid
				kill -SIGKILL "$BG_MIGRATION_PID"
				set_return_code EXIT
				return 0
				;;
			*)
				;;
		esac
		return 1
	else # async mode
		true
	fi
}

run_background_migration() {
    local tp_pid=$1
    while true ; do
        echo migratepages $tp_pid 0 1 >> $TMPD/run_background_migration
        migratepages $tp_pid 0 1 2> /dev/null
        get_numa_maps $tp_pid    2> /dev/null | grep " huge " >> $TMPD/run_background_migration
        grep HugeP /proc/meminfo >> $TMPD/run_background_migration
        echo migratepages $tp_pid 1 0 >> $TMPD/run_background_migration
        migratepages $tp_pid 1 0 2> /dev/null
        get_numa_maps $tp_pid    2> /dev/null | grep " huge " >> $TMPD/run_background_migration
        grep HugeP /proc/meminfo >> $TMPD/run_background_migration
    done
}

_control() {
	control_hugepage_migration "$1" "$2"
}

_prepare() {
	prepare_hugepage_migration || return 1
}

_cleanup() {
	cleanup_hugepage_migration
}

_check() {
	check_hugepage_migration
}
