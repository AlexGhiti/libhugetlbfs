#! /bin/bash

export QUIET_TEST=1
export HUGETLB_VERBOSE=2
unset HUGETLB_ELF
unset HUGETLB_MORECORE

ENV=/usr/bin/env

function free_hpages() {
	H=$(grep 'HugePages_Free:' /proc/meminfo | cut -f2 -d:)
	[ -z "$H" ] && H=0
	echo "$H"
}

function hugetlbfs_path() {
    if [ -n "$HUGETLB_PATH" ]; then
	echo "$HUGETLB_PATH"
    else
	grep hugetlbfs /proc/mounts | cut -f2 -d' '
    fi
}

TOTAL_HPAGES=$(grep 'HugePages_Total:' /proc/meminfo | cut -f2 -d:)
[ -z "$TOTAL_HPAGES" ] && TOTAL_HPAGES=0
HPAGE_SIZE=$(grep 'Hugepagesize:' /proc/meminfo | awk '{print $2}')
[ -z "$HPAGE_SIZE" ] && HPAGE_SIZE=0
HPAGE_SIZE=$(( $HPAGE_SIZE * 1024 ))

run_test_bits () {
    BITS=$1
    shift

    if [ -d obj$BITS ]; then
	echo -n "$@ ($BITS):	"
	PATH="obj$BITS:$PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH:../obj$BITS" $ENV "$@"
    fi
}

run_test () {
    for bits in $WORDSIZES; do
	run_test_bits $bits "$@"
    done
}

preload_test () {
    run_test LD_PRELOAD=libhugetlbfs.so "$@"
}

elflink_test () {
    args=("$@")
    N="$[$#-1]"
    baseprog="${args[$N]}"
    unset args[$N]
    set -- "${args[@]}"
    run_test "$@" "$baseprog"
    # Test we don't blow up if not linked for hugepage
    preload_test "$@" "$baseprog"
    run_test "$@" "xB.$baseprog"
    run_test "$@" "xBDT.$baseprog"
    # Test we don't blow up if HUGETLB_MINIMAL_COPY is diabled
    run_test HUGETLB_MINIMAL_COPY=no "$@" "xB.$baseprog"
    run_test HUGETLB_MINIMAL_COPY=no "$@" "xBDT.$baseprog"
    # Test that HUGETLB_ELFMAP=no inhibits remapping as intended
    run_test HUGETLB_ELFMAP=no "$@" "xB.$baseprog"
    run_test HUGETLB_ELFMAP=no "$@" "xBDT.$baseprog"
}

elfshare_test () {
    args=("$@")
    N="$[$#-1]"
    baseprog="${args[$N]}"
    unset args[$N]
    set -- "${args[@]}"
    # Run each elfshare test invocation independently - clean up the
    # sharefiles before and after:
    NUM_THREADS=2
    run_test HUGETLB_SHARE=2 "$@" "xB.$baseprog" $NUM_THREADS
    run_test HUGETLB_SHARE=1 "$@" "xB.$baseprog" $NUM_THREADS
    run_test HUGETLB_SHARE=2 "$@" "xBDT.$baseprog" $NUM_THREADS
    run_test HUGETLB_SHARE=1 "$@" "xBDT.$baseprog" $NUM_THREADS
}

setup_shm_sysctl() {
    SHMMAX=`cat /proc/sys/kernel/shmmax`
    SHMALL=`cat /proc/sys/kernel/shmall`
    LIMIT=$(( $HPAGE_SIZE * $TOTAL_HPAGES ))
    echo "$LIMIT" > /proc/sys/kernel/shmmax
    echo "set shmmax limit to $LIMIT"
    echo "$LIMIT" > /proc/sys/kernel/shmall
}

restore_shm_sysctl() {
    echo "$SHMMAX" > /proc/sys/kernel/shmmax
    echo "$SHMALL" > /proc/sys/kernel/shmall
}

functional_tests () {
    #run_test dummy
# Kernel background tests not requiring hugepage support
    run_test zero_filesize_segment

# Library background tests not requiring hugepage support
    run_test test_root
    run_test meminfo_nohuge

# Library tests requiring kernel hugepage support
    run_test gethugepagesize
    run_test HUGETLB_VERBOSE=1 empty_mounts

# Tests requiring an active and usable hugepage mount
    run_test find_path
    run_test unlinked_fd
    run_test readback
    run_test truncate
    run_test shared
    run_test mprotect
    run_test mlock

# Specific kernel bug tests
    run_test ptrace-write-hugepage
    run_test icache-hygeine
    run_test slbpacaflush
    run_test_bits 64 straddle_4GB
    run_test_bits 64 huge_at_4GB_normal_below
    run_test_bits 64 huge_below_4GB_normal_above
    run_test map_high_truncate_2
    run_test misaligned_offset
    run_test truncate_above_4GB

# Tests requiring an active mount and hugepage COW
    run_test private
    run_test malloc
    preload_test HUGETLB_MORECORE=yes malloc
    run_test malloc_manysmall
    preload_test HUGETLB_MORECORE=yes malloc_manysmall
    elflink_test HUGETLB_VERBOSE=0 linkhuge_nofd # Lib error msgs expected
    elflink_test linkhuge

# Sharing tests
    elfshare_test linkshare

# Accounting bug tests
# reset free hpages because sharing will have held some
# alternatively, use
    run_test chunk-overcommit `free_hpages`
    run_test alloc-instantiate-race `free_hpages` shared
    run_test alloc-instantiate-race `free_hpages` private
    run_test truncate_reserve_wraparound
    run_test truncate_sigbus_versus_oom `free_hpages`
}

stress_tests () {
    ITERATIONS=10           # Number of iterations for looping tests

    # Don't update NRPAGES every time like above because we want to catch the
    # failures that happen when the kernel doesn't release all of the huge pages
    # after a stress test terminates
    NRPAGES=`free_hpages`

    run_test mmap-gettest ${ITERATIONS} ${NRPAGES}

    # mmap-cow needs a hugepages for each thread plus one extra
    run_test mmap-cow $[NRPAGES-1] ${NRPAGES}

    setup_shm_sysctl
    THREADS=10    # Number of threads for shm-fork
    # Run shm-fork once using half available hugepages, then once using all
    # This is to catch off-by-ones or races in the kernel allocated that
    # can make allocating all hugepages a problem
    if [ ${NRPAGES} -gt 1 ]; then
	run_test shm-fork ${THREADS} $[NRPAGES/2]
    fi
    run_test shm-fork ${THREADS} $[NRPAGES]

    run_test shm-getraw ${NRPAGES} /dev/full
    restore_shm_sysctl
}

while getopts "vVdt:b:" ARG ; do
    case $ARG in
	"v")
	    unset QUIET_TEST
	    ;;
	"V")
	    export HUGETLB_VERBOSE=99
	    ;;
	"t")
	    TESTSETS=$OPTARG
	    ;;
	"b")
	    WORDSIZES=$OPTARG
	    ;;
    esac
done

if [ -z "$TESTSETS" ]; then
    TESTSETS="func stress"
fi

if [ -z "$WORDSIZES" ]; then
    WORDSIZES="32 64"
fi

for set in $TESTSETS; do
    case $set in
	"func")
	    functional_tests
	    ;;
	"stress")
	    stress_tests
	    ;;
    esac
done
