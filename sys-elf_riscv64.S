/*
 * libhugetlbfs - direct system call for riscv64 (31 bit)
 *
 * Author(s): Alexandre Ghiti
 *
 * NOTE: Only 4 syscall parameters supported w/o stack access, but this is
 *       sufficient for the syscalls used so far (__NR_write, __NR_kill and
 *       __NR_getpid).
 */
	.text

	.globl	direct_syscall
direct_syscall:
	mv 	a7, a0
	mv 	a0, a1
	mv	a1, a2
	mv	a2, a3
	mv	a3, a4
	ecall
	ret

#if defined(__linux__) && defined(__ELF__)
	.section .note.GNU-stack,"",%progbits
#endif
