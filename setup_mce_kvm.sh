#!/bin/bash

. $TRDIR/setup_kvm.sh || return 1

TARGETGVA=""
TARGETGPA=""
TARGETHPA=""

# check VM RAM size is not greater than 2GB
memsize=$(virsh dominfo $VM | grep "Used memory:" | tr -s ' ' | cut -f3 -d' ')
if [ "$memsize" -gt 2097152 ] ; then
	echo_log "Too much VM RAM size. (> 2GB)"
	return 1
fi

get_gpa_guest_memeater() {
	local vmip=$(sshvm -i $VM)
	local flagtype=$1

	ssh $vmip "for pid in $(cat $TMPD/.guest_memeater_pids.1) ; do $GUESTPAGETYPES -p \$pid -NrL -b $flagtype -a 0x700000000+0x10000000 ; done" | grep -v offset | tr '\t' ' ' | tr -s ' ' > $TMPD/guest_page_types

	local lines=`wc -l $TMPD/guest_page_types | cut -f1 -d' '`
	[ "$lines" -eq 0 ] && echo_log "Page ($flagtype) not exist on guest memeater." >&2 && return 1
	[ "$lines" -gt 2 ] && lines=`ruby -e "p rand($lines) + 1"`
	echo "# of pages $flagtypes: $lines"
	TARGETGVA=0x`cat $TMPD/guest_page_types | sed -n ${lines}p | cut -f1 -d ' '`
	TARGETGPA=0x`cat $TMPD/guest_page_types | sed -n ${lines}p | cut -f2 -d ' '`
	[ "$TARGETGPA" == 0x ] && echo_log "Failed to get GPA. Test skipped." && return 1
	TARGETHPA=`ruby $GPA2HPA $VM $TARGETGPA`
	if [ ! "$TARGETHPA" ] || [ "$TARGETHPA" == "0x" ] || [ "$TARGETHPA" == "0x0" ] ; then
		echo_log "Failed to get HPA. Test skipped." && return 1
	fi
	echo_log "GVA:$TARGETGVA => GPA:$TARGETGPA => HPA:$TARGETHPA"
	return 0
}

get_hpa() {
	local vmip=$(sshvm -i $VM)
	local flagtype="$1"

	get_gpa_guest_memeater "$flagtype" || return 1
	echo_log -n "HPA status: " ; $PAGETYPES -a $TARGETHPA -Nlr | grep -v offset
	echo_log -n "GPA status: " ; ssh $vmip $GUESTPAGETYPES -a $TARGETGPA -Nlr | grep -v offset
}

guest_process_running() {
	local vmip=$(sshvm -i $VM)

	ssh $vmip "pgrep -f $GUESTTESTALLOC" | tr '\n' ' ' > $TMPD/.guest_memeater_pids.2
	diff -q $TMPD/.guest_memeater_pids.1 $TMPD/.guest_memeater_pids.2 > /dev/null
}

prepare_mce_kvm() {
	TARGETGVA=""
	TARGETGPA=""
	TARGETHPA=""

	if [ "$ERROR_TYPE" = mce-srao ] ; then
		check_mce_capability || return 1 # MCE SRAO not supported
	fi

	prepare_mm_generic || return 1
	# unconditionally restart vm because memory background might change
	# (thp <=> anon)
	vm_shutdown_wait $VM $VMIP
	echo 3 > /proc/sys/vm/drop_caches ; sync
	vm_start_wait $VM
	local vmip=$(sshvm -i $VM)
	start_vm_console_monitor $TMPD/vmconsole $VM
	stop_guest_memeater $vmip
	send_helper_to_guest $vmip
	save_nr_corrupted_before
	return 0
}

cleanup_mce_kvm() {
	save_nr_corrupted_inject
	all_unpoison
	show_guest_console
	cleanup_mm_generic
	save_nr_corrupted_unpoison
	vm_shutdown_wait $VM $VMIP
}

check_guest_state() {
	if vm_ssh_connectable_one $VM ; then
		echo_log "Guest OS still alive."
		set_return_code "GUEST_ALIVE"
		if guest_process_running ; then
			echo_log "And $GUESTTESTALLOC still running."
			set_return_code "GUEST_PROC_ALIVE"
			echo_log "let $GUESTTESTALLOC access to error page"

			access_error
			if vm_ssh_connectable_one $VM ; then
				if guest_process_running ; then
					echo_log "$GUESTTESTALLOC was still alive"
					set_return_code "GUEST_PROC_ALIVE_LATER_ACCESS"
				else
					echo_log "$GUESTTESTALLOC was killed"
					set_return_code "GUEST_PROC_KILLED_LATER_ACCESS"
				fi
			else
				echo_log "Guest OS panicked."
				set_return_code "GUEST_PANICKED_LATER_ACCESS"
			fi
			return
		else
			echo_log "But $GUESTTESTALLOC was killed."
			set_return_code "GUEST_PROC_KILLED"
			return
		fi
	else
		echo_log "Guest OS panicked."
		set_return_code "GUEST_PANICKED"
	fi
}

access_error() {
	local vmip=$(sshvm -i $VM)

	ssh $vmip "pkill -SIGUSR1 -f $GUESTTESTALLOC > /dev/null 2>&1 </dev/null"
	sleep 0.2 # need short time for access operation to finish.
}

check_page_migrated() {
	local gpa="$1"
	local oldhpa="$2"

	count_testcount
	currenthpa=$(ruby ${GPA2HPA} $VM $gpa)
	# echo_log "[$TARGETGPA] [$TARGETHPA] [$currenthpa]"
	if [ ! "$currenthpa" ] ; then
		count_failure "Fail to get HPA after migration."
	elif [ "$oldhpa" = "$currenthpa" ] ; then
		count_failure "page migration failed or not triggered."
	else
		count_success "page $oldhpa was migrated to $currenthpa."
	fi
}

control_mce_kvm() {
	start_guest_memeater $VM $[512 * 4] || return 1
	sleep 0.2
	echo_log "get_hpa $TARGET_PAGETYPES"
	get_hpa "$TARGET_PAGETYPES" || return 1
	set_return_code "GOT_HPA"
	echo_log "$MCEINJECT -e $ERROR_TYPE -a ${TARGETHPA}"
	$MCEINJECT -e "$ERROR_TYPE" -a "${TARGETHPA}"
	check_guest_state
}

control_mce_kvm_panic() {
	local vmip=$(sshvm -i $VM)

	echo_log "start $FUNCNAME"
	start_guest_memeater $VM $[512 * 4] || return 1
	get_hpa "$TARGET_PAGETYPES" || return 1
	set_return_code "GOT_HPA"
	echo_log "echo 0 > /proc/sys/vm/memory_failure_recovery"
	ssh $vmip "echo 0 > /proc/sys/vm/memory_failure_recovery"
	echo_log $MCEINJECT -e \"$ERROR_TYPE\" -a \"${TARGETHPA}\"
	$MCEINJECT -e "$ERROR_TYPE" -a "${TARGETHPA}"
	if vm_connectable_one $VM ; then
		ssh $vmip "echo 1 > /proc/sys/vm/memory_failure_recovery"
	fi
	check_guest_state
}

check_mce_kvm() {
	check_nr_hwcorrupted
	check_kernel_message "${TARGETHPA}"
	check_kernel_message_nobug
	check_guest_kernel_message "${TARGETGPA}"
}

check_mce_kvm_panic() {
	check_nr_hwcorrupted
	check_kernel_message "${TARGETHPA}"
	check_guest_kernel_message "Kernel panic"
}

check_mce_kvm_soft_offline() {
	check_nr_hwcorrupted
	check_kernel_message_nobug
	check_guest_kernel_message -v "${TARGETGPA}"
	# TODO: move to return code
	# check_page_migrated "$TARGETGPA" "$TARGETHPA"
}

control_mce_kvm_inject_mce_on_qemu_page() {
	local pid=$(cat /var/run/libvirt/qemu/$VM.pid)
	$PAGETYPES -p $pid -Nrl -b lru | grep -v offset > $TMPD/pagetypes.1

	local target=$(tail -n1 $TMPD/pagetypes.1 | cut -f2)
	if [ "$target" ] ; then
		set_return_code GOT_TARGET_PFN
		echo "$MCEINJECT -e $ERROR_TYPE -a 0x$target"
		$MCEINJECT -e $ERROR_TYPE -a 0x$target
	else
		set_return_code NO_TARGET_PFN
	fi

	set_return_code EXIT
}

check_mce_kvm_inject_mce_on_qemu_page() {
	check_kernel_message "${TARGETHPA}"
	check_kernel_message_nobug
}

#
# Default definition. You can overwrite in each recipe
#
_control() {
	control_mce_kvm "$1" "$2"
}

_prepare() {
	prepare_mce_kvm || return 1
}

_cleanup() {
	cleanup_mce_kvm
}

_check() {
	check_mce_kvm
}
