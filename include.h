#include <sys/uio.h>
#include <sys/time.h>
#include <stdlib.h>
#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"
#include "test_core/lib/pfn.h"

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT 0x700000000000

/* for multi_backend operation */
void *allocate_base = (void *)ADDR_INPUT;

unsigned long nr_nodes;
unsigned long nodemask;

#define BUFNR 0x10000 /* 65536 */
#define CHUNKSIZE 0x1000 /* 4096 pages */

int mapflag = MAP_ANONYMOUS|MAP_PRIVATE;
int protflag = PROT_READ|PROT_WRITE;

int nr_p = 512;
int nr_chunk = 1;
int busyloop = 0;

char *workdir = "work";
char *file;
int fd;
int hugetlbfd;

int forkflag;

struct mem_chunk {
	int mem_type;
	int chunk_size;
	char *p;
	int shmkey;
};

struct mem_chunk *chunkset;
int nr_all_chunks;
int nr_mem_types = 1;

enum {
	AT_MAPPING_ITERATION,
	AT_ALLOCATE_EXIT,
	AT_NUMA_PREPARED,
	AT_NONE,

	AT_SIMPLE,
	AT_ACCESS_LOOP,
	AT_ALLOC_EXIT,
	NR_ALLOCATION_TYPES,
};
int allocation_type = -1;

enum {
	OT_MEMORY_ERROR_INJECTION,
	OT_ALLOC_EXIT,
	OT_PAGE_MIGRATION,
	OT_PROCESS_VM_ACCESS,
	OT_MLOCK,
	OT_MLOCK2,
	OT_MPROTECT,
	OT_POISON_UNPOISON,
	OT_MADV_STRESS,
	OT_FORK_STRESS,
	OT_MREMAP_STRESS,
	OT_MBIND_FUZZ,
	OT_MADV_WILLNEED,
	OT_ALLOCATE_MORE,
	OT_MEMORY_COMPACTION,
	OT_MOVE_PAGES_PINGPONG,
	OT_MBIND_PINGPONG,
	OT_PAGE_MIGRATION_PINGPONG,
	OT_NOOP,
	OT_BUSYLOOP,
	OT_HUGETLB_RESERVE,
	NR_OPERATION_TYPES,
};
int operation_type = -1;

enum {
	PAGECACHE,
	ANONYMOUS,
	THP,
	HUGETLB_ANON,
	HUGETLB_SHMEM,
	HUGETLB_FILE,
	KSM,
	ZERO,
	HUGE_ZERO,
	NORMAL_SHMEM,
	DEVMEM,
	NR_BACKEND_TYPES,
};

#define BE_PAGECACHE		(1UL << PAGECACHE)
#define BE_ANONYMOUS		(1UL << ANONYMOUS)
#define BE_THP			(1UL << THP)
#define BE_HUGETLB_ANON		(1UL << HUGETLB_ANON)
#define BE_HUGETLB_SHMEM	(1UL << HUGETLB_SHMEM)
#define BE_HUGETLB_FILE		(1UL << HUGETLB_FILE)
#define BE_KSM			(1UL << KSM)
#define BE_ZERO			(1UL << ZERO)
#define BE_HUGE_ZERO		(1UL << HUGE_ZERO)
#define BE_NORMAL_SHMEM		(1UL << NORMAL_SHMEM)
#define BE_DEVMEM		(1UL << DEVMEM)
unsigned long backend_bitmap = 0;

#define BE_HUGEPAGE	\
	(BE_THP|BE_HUGETLB_ANON|BE_HUGETLB_SHMEM|BE_HUGETLB_FILE|BE_NORMAL_SHMEM)

/* Waitpoint */
enum {
	WP_START,
	WP_AFTER_MMAP,
	WP_AFTER_ALLOCATE,
	WP_BEFORE_FREE,
	WP_EXIT,
	NR_WAITPOINTS,
};
#define wait_start		(waitpoint_mask & (1 << WP_START))
#define wait_after_mmap		(waitpoint_mask & (1 << WP_AFTER_MMAP))
#define wait_after_allocate	(waitpoint_mask & (1 << WP_AFTER_ALLOCATE))
#define wait_before_munmap	(waitpoint_mask & (1 << WP_BEFORE_FREE))
#define wait_exit		(waitpoint_mask & (1 << WP_EXIT))
int waitpoint_mask = 0;

enum {
	MS_MIGRATEPAGES,
	MS_MBIND,
	MS_MOVE_PAGES,
	MS_HOTREMOTE,
	MS_MADV_SOFT,
	MS_AUTO_NUMA,
	MS_CHANGE_CPUSET,
	MS_MBIND_FUZZ,
	NR_MIGRATION_SRCS,
};
int migration_src = -1;
int mpol_mode_for_page_migration = MPOL_PREFERRED;

enum {
	MCE_SRAO,
	SYSFS_HARD,
	SYSFS_SOFT,
	MADV_HARD,
	MADV_SOFT,
	NR_INJECTION_TYPES,
};
int injection_type = -1;
int access_after_injection;

static int find_next_backend(int i) {
	while (i < NR_BACKEND_TYPES) {
		if (backend_bitmap & (1UL << i))
			break;
		i++;
	}
	return i;
}

#define for_each_backend(i)			\
	for (i = find_next_backend(0);		\
	     i < NR_BACKEND_TYPES;		\
	     i = find_next_backend(i+1))

static int get_nr_mem_types(void) {
	int i, j = 0;

	for_each_backend(i)
		j++;
	return j;
}

/*
 * @i is current chunk index. In the last chunk mmaped size will be truncated.
 */
static int get_size_of_chunked_mmap_area(int i) {
	if ((i % nr_chunk) == nr_chunk - 1)
		return ((nr_p - 1) % CHUNKSIZE + 1) * PS;
	else
		return CHUNKSIZE * PS;
}

static void cleanup_memory(void *baseaddr, int size) {
	;
}

static void read_memory(char *p, int size) {
	int i;
	char c;

	for (i = 0; i < size; i += PS) {
		c = p[i];
	}
}

static void create_regular_file(void) {
	int i;
	char fpath[256];
	char buf[PS];

	sprintf(fpath, "%s/testfile", workdir);
	fd = open(fpath, O_CREAT|O_RDWR, 0755);
	if (fd == -1)
		err("open");
	memset(buf, 'a', PS);
	for (i = 0; i < nr_p; i++)
		write(fd, buf, PS);
	fsync(fd);
}

/*
 * Assuming that hugetlbfs is mounted on @workdir/hugetlbfs. And cleanup is
 * supposed to be done by control scripts.
 */
static void create_hugetlbfs_file(void) {
	int i;
	char fpath[256];
	char buf[PS];
	char *phugetlb;

	sprintf(fpath, "%s/hugetlbfs/testfile", workdir);
	hugetlbfd = open(fpath, O_CREAT|O_RDWR, 0755);
	if (hugetlbfd == -1)
		err("open");
	phugetlb = checked_mmap(NULL, nr_p * PS, protflag, MAP_SHARED,
				hugetlbfd, 0);
	/* printf("phugetlb %p\n", phugetlb); */
	memset(phugetlb, 'a', nr_p * PS);
	munmap(phugetlb, nr_p * PS);
}

static void *alloc_shmem(struct mem_chunk *mc, void *exp_addr, int hugetlb) {
	void *addr;
	int shmid;
	int flags = IPC_CREAT | SHM_R | SHM_W;

	if (hugetlb)
		flags |= SHM_HUGETLB;
	if ((shmid = shmget(shmkey, mc->chunk_size, flags)) < 0) {
		perror("shmget");
		return NULL;
	}
	addr = shmat(shmid, exp_addr, 0);
	if (addr == (char *)-1) {
		perror("Shared memory attach failure");
		shmctl(shmid, IPC_RMID, NULL);
		err("shmat failed");
		return NULL;
	}
	if (addr != exp_addr) {
		printf("Shared memory not attached to expected address (%p -> %p) %lx %lx\n", exp_addr, addr, SHMLBA, SHM_RND);
		shmctl(shmid, IPC_RMID, NULL);
		err("shmat failed");
		return NULL;
	}

	mc->shmkey = shmid;
	return addr;
}

static void free_shmem(struct mem_chunk *mc) {
	if (shmdt((const void *)mc->p))
		perror("Shmem detach failed.");
	shmctl(mc->shmkey, IPC_RMID, NULL);
}

static void prepare_memory(struct mem_chunk *mc, void *baseaddr,
			     unsigned long offset) {
	int dev_mem_fd;

	switch (mc->mem_type) {
	case PAGECACHE:
		/* printf("open, fd %d, offset %lx\n", fd, offset); */
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_SHARED, fd, offset);
		break;
	case ANONYMOUS:
		/* printf("base:0x%lx, size:%lx\n", baseaddr, size); */
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_NOHUGEPAGE);
		break;
	case THP:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		if (madvise(mc->p, mc->chunk_size, MADV_HUGEPAGE) == -1) {
			printf("p %p, size %lx\n", mc->p, mc->chunk_size);
			err("madvise");
		}
		break;
	case HUGETLB_ANON:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_DONTNEED);
		break;
	case HUGETLB_SHMEM:
		/*
		 * TODO: currently alloc_shm_hugepage is not designed to be called
		 * multiple times, so controlling script must cleanup shmems after
		 * running the testcase.
		 */
		mc->p = alloc_shmem(mc, baseaddr, 1);
		break;
	case HUGETLB_FILE:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_SHARED, hugetlbfd, offset);
		break;
	case KSM:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		set_mergeable(mc->p, mc->chunk_size);
		break;
	case ZERO:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_NOHUGEPAGE);
		break;
	case HUGE_ZERO:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_HUGEPAGE);
		break;
	case NORMAL_SHMEM:
		mc->p = alloc_shmem(mc, baseaddr, 0);
		break;
	case DEVMEM:
		/* Assuming that -n 1 is given */
		dev_mem_fd = checked_open("/dev/mem", O_RDWR);
		mc->p = checked_mmap(baseaddr, PS, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, dev_mem_fd, 0);
		checked_mmap(baseaddr + PS, PS, PROT_READ,
				     MAP_SHARED, dev_mem_fd, 0xf0000);
		checked_mmap(baseaddr + 2 * PS, PS, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, dev_mem_fd, 0);
		break;
	}
}

static void access_memory(struct mem_chunk *mc) {
	if (mc->mem_type == ZERO || mc->mem_type == HUGE_ZERO)
		read_memory(mc->p, mc->chunk_size);
	else if (mc->mem_type == DEVMEM) {
		memset(mc->p, 'a', PS);
		memset(mc->p + 2 * PS, 'a', PS);
	} else
		memset(mc->p, 'a', mc->chunk_size);
}

static void mmap_all_chunks(void) {
	int i, j = 0, k, backend;
	void *baseaddr;

	/* printf("backend %lx, nr_chunk %lx\n", backend, nr_chunk); */
	for_each_backend(backend) {
		for (i = 0; i < nr_chunk; i++) {
			k = i + j * nr_chunk;
			baseaddr = allocate_base + k * CHUNKSIZE * PS;

			chunkset[k].chunk_size = get_size_of_chunked_mmap_area(i);
			chunkset[k].mem_type = backend;

			prepare_memory(&chunkset[k], baseaddr, i * CHUNKSIZE * PS);
		}
		j++;
	}
}

static void munmap_memory(struct mem_chunk *mc) {
	if (mc->mem_type == HUGETLB_SHMEM || mc->mem_type == NORMAL_SHMEM)
		free_shmem(mc);
	else if (mc->mem_type == DEVMEM) {
		checked_munmap(mc->p, 3 * PS);
	} else
		checked_munmap(mc->p, mc->chunk_size);
}

static void munmap_all_chunks(void) {
	int i, j;

	for (j = 0; j < nr_mem_types; j++)
		for (i = 0; i < nr_chunk; i++)
			munmap_memory(&chunkset[i + j * nr_chunk]);
}

static int access_all_chunks(void *arg) {
	int i, j;

	for (j = 0; j < nr_mem_types; j++)
		for (i = 0; i < nr_chunk; i++)
			access_memory(&chunkset[i + j * nr_chunk]);
}

int do_work_memory(int (*func)(char *p, int size, void *arg), void *args) {
	int i, j;
	int ret;

	for (j = 0; j < nr_mem_types; j++) {
		for (i = 0; i < nr_chunk; i++) {
			struct mem_chunk *tmp = &chunkset[i + j * nr_chunk];

			/* printf("%s, %d %d\n", __func__, i, j); */
			ret = (*func)(tmp->p, tmp->chunk_size, args);
			if (ret != 0) {
				char buf[64];
				sprintf(buf, "%p", func);
				perror(buf);
				break;
			}
		}
	}
	return ret;
}

int hp_partial;

/*
 * Memory block size is 128MB (1 << 27) = 32k pages (1 << 15)
 */
#define MEMBLK_ORDER	15
#define MEMBLK_SIZE	(1 << MEMBLK_ORDER)
#define MAX_MEMBLK	1024

static void __busyloop(void) {
	pprintf_wait_func(busyloop ? access_all_chunks : NULL, NULL,
			  "entering busy loop\n");
}

static void do_busyloop(void) {
	pprintf_wait_func(access_all_chunks, NULL, "entering busy loop\n");
}

static int set_mempolicy_node(int mode, int nid) {
	/* Assuming that max node number is < 64 */
	unsigned long nodemask = 1UL << nid;

	if (mode == MPOL_DEFAULT)
		set_mempolicy(mode, NULL, nr_nodes);
	else
		set_mempolicy(mode, &nodemask, nr_nodes);
}

static int numa_sched_setaffinity_node(int nid) {
	struct bitmask *new_cpus = numa_bitmask_alloc(32);

	if (numa_node_to_cpus(nid, new_cpus))
		err("numa_node_to_cpus");

	if (numa_sched_setaffinity(0, new_cpus))
		err("numa_sched_setaffinity");

	numa_bitmask_free(new_cpus);
}

static void do_migratepages(void) {
	pprintf_wait_func(busyloop ? access_all_chunks : NULL, NULL,
			  "waiting for migratepages\n");
}

struct mbind_arg {
	int mode;
	unsigned flags;
	struct bitmask *new_nodes;
};

static int __mbind_chunk(char *p, int size, void *args) {
	int i;
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mbind(p + i * HPS, PS,
			      mbind_arg->mode, mbind_arg->new_nodes->maskp,
			      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
	} else
		mbind(p, size,
		      mbind_arg->mode, mbind_arg->new_nodes->maskp,
		      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

static void do_mbind(int mode, int nid) {
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);
	numa_bitmask_setbit(mbind_arg.new_nodes, 1);

	do_work_memory(__mbind_chunk, (void *)&mbind_arg);
}

static void initialize_random(void) {
	struct timeval tv;

	gettimeofday(&tv, NULL);
	srandom(tv.tv_usec);
}

static int __mbind_fuzz_chunk(char *p, int size, void *args) {
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;
	int node = random() % nr_nodes;
	unsigned long offset = (random() % nr_p) * PS;
	unsigned long length = (random() % (nr_p - offset / PS)) * PS;

	printf("%p: node:%x, offset:%x, length:%x\n", p, node, offset, length);
	numa_bitmask_setbit(mbind_arg->new_nodes, node);

	mbind(p + offset, size + length, mbind_arg->mode,
	      mbind_arg->new_nodes->maskp,
	      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

static void __do_mbind_fuzz(void) {
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	initialize_random();

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);

	/* TODO: more race consideration, chunk, busyloop case? */
	pprintf("doing mbind_fuzz\n");
	while (flag)
		do_work_memory(__mbind_fuzz_chunk, (void *)&mbind_arg);
}

static int __move_pages_chunk(char *p, int size, void *args) {
	int i;
	int node = *(int *)args;
	void *__move_pages_addrs[CHUNKSIZE + 1];
	int __move_pages_status[CHUNKSIZE + 1];
	int __move_pages_nodes[CHUNKSIZE + 1];

	for (i = 0; i < size / PS; i++) {
		__move_pages_addrs[i] = p + i * PS;
		__move_pages_nodes[i] = node;
		__move_pages_status[i] = 0;
	}
	numa_move_pages(0, size / PS, __move_pages_addrs, __move_pages_nodes,
			__move_pages_status, MPOL_MF_MOVE_ALL);
}

static void do_move_pages(void) {
	int node = 1;

	do_work_memory(__move_pages_chunk, &node);
}

static int get_max_memblock(void) {
	FILE *f;
	char str[256];
	int spanned;
	int start_pfn;
	int mb;

	f = fopen("/proc/zoneinfo", "r");
	while (fgets(str, 256, f)) {
		sscanf(str, " spanned %d", &spanned);
		sscanf(str, " start_pfn: %d", &start_pfn);
	}
	fclose(f);
	return (spanned + start_pfn) >> MEMBLK_ORDER;
}

/* Assuming that */
static int check_compound(void) {
	return !!(opt_bits[0] & BIT(COMPOUND_HEAD));
}

/* find memblock preferred to be hotremoved */
static int memblock_check(void) {
	int i, j;
	int ret;
	int max_memblock = get_max_memblock();
	uint64_t pageflags[MEMBLK_SIZE];
	int pmemblk = 0;
	int max_matched_pages = 0;
	int compound = check_compound();

	kpageflags_fd = open("/proc/kpageflags", O_RDONLY);
	for (i = 0; i < max_memblock; i++) {
		int pfn = i * MEMBLK_SIZE;
		int matched = 0;

		ret = kpageflags_read(pageflags, pfn, MEMBLK_SIZE);
		for (j = 0; j < MEMBLK_SIZE; j++) {
			if (bit_mask_ok(pageflags[j])) {
				if (compound)
					matched += 512;
				else
					matched++;
			}
		}
		Dprintf("memblock:%d, readret:%d matched:%d (%d%), 1:%lx, 2:%lx\n",
		       i, ret, matched, matched*100/MEMBLK_SIZE,
		       pageflags[0], pageflags[1]);
		if (max_matched_pages < matched) {
			max_matched_pages = matched;
			pmemblk = i;
			if (matched == MEMBLK_SIZE) /* full of target pages */
				break;
		}
	}
	close(kpageflags_fd);

	return pmemblk;
}

static void do_hotremove(void) {
	int pmemblk; /* preferred memory block for hotremove */

	if (set_mempolicy_node(MPOL_PREFERRED, 1) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 1");

	pmemblk = memblock_check();

	pprintf_wait_func(busyloop ? access_all_chunks : NULL, NULL,
			  "waiting for memory_hotremove: %d\n", pmemblk);
}

static int __madv_soft_chunk(char *p, int size, void *args) {
	int i;
	int ret;

	for (i = 0; i < size / HPS; i++) {
		ret = madvise(p + i * HPS, 4096, MADV_SOFT_OFFLINE);
		if (ret)
			break;
	}
	return ret;
}

/* unpoison option? */
static void do_madv_soft(void) {
	/* int loop = 10; */
	/* int do_unpoison = 1; */

	do_work_memory(__madv_soft_chunk, NULL);
}

static void do_auto_numa(void) {
	numa_sched_setaffinity_node(1);
	pprintf_wait_func(busyloop ? access_all_chunks : NULL, NULL,
			  "waiting for auto_numa\n");
}

static void do_change_cpuset(void) {
	pprintf_wait_func(busyloop ? access_all_chunks : NULL, NULL,
			  "waiting for change_cpuset\n");
}

/* default (-1) means no preferred node */
int preferred_cpu_node = -1;
int preferred_mem_node = 0;

static void mmap_all_chunks_numa(void) {
	if (preferred_cpu_node != -1)
		numa_sched_setaffinity_node(preferred_cpu_node);

	if (set_mempolicy_node(MPOL_BIND, preferred_mem_node) == -1)
		err("set_mempolicy");

	mmap_all_chunks();

	if (set_mempolicy_node(MPOL_DEFAULT, 0) == -1)
		err("set_mempolicy");
}

void __do_page_migration(void) {
	switch (migration_src) {
	case MS_MIGRATEPAGES:
		do_migratepages();
		break;
	case MS_MBIND:
		/* TODO: better setting */
		do_mbind(mpol_mode_for_page_migration, 1);
		break;
	case MS_MOVE_PAGES:
		do_move_pages();
		break;
	case MS_HOTREMOTE:
		do_hotremove();
		break;
	case MS_MADV_SOFT:
		do_madv_soft();
		break;
	case MS_AUTO_NUMA:
		do_auto_numa();
		break;
	case MS_CHANGE_CPUSET:
		do_change_cpuset();
		break;
	}
}

/* inject only onto the first page, so allocating big region makes no sense. */
static void do_memory_error_injection(void) {
	char rbuf[256];
	unsigned long offset = 0;

	switch (injection_type) {
	case MCE_SRAO:
	case SYSFS_HARD:
	case SYSFS_SOFT:
		pprintf("waiting for injection from outside\n");
		pause();
		break;
	case MADV_HARD:
	case MADV_SOFT:
		pprintf("error injection with madvise\n");
		pause();
		pipe_read(rbuf);
		offset = strtol(rbuf, NULL, 0);
		Dprintf("madvise inject to addr %lx\n", chunkset[0].p + offset * PS);
		if (madvise(chunkset[0].p + offset * PS, PS, injection_type == MADV_HARD ?
			    MADV_HWPOISON : MADV_SOFT_OFFLINE) != 0)
			perror("madvise");
		pprintf("after madvise injection\n");
		pause();
		break;
	}

	if (access_after_injection) {
		pprintf("writing affected region\n");
		pause();
		access_all_chunks(NULL);
	}
}

static int __process_vm_access_chunk(char *p, int size, void *args) {
	int i;
	struct iovec local[1024];
	struct iovec remote[1024];
	ssize_t nread;
	pid_t pid = *(pid_t *)args;

	for (i = 0; i < size / HPS; i++) {
		local[i].iov_base = p + i * HPS;
		local[i].iov_len = HPS;
		remote[i].iov_base = p + i * HPS;
		remote[i].iov_len = HPS;
	}
	nread = process_vm_readv(pid, local, size / HPS, remote, size / HPS, 0);
	/* printf("0x%lx bytes read, p[0] = %c\n", nread, p[0]); */
}

static pid_t fork_access(void) {
	pid_t pid = fork();

	if (!pid) {
		/* Expecting COW, but it doesn't happend in zero page */
		access_all_chunks(NULL);
		pause();
		return 0;
	}

	return pid;
}

void __do_process_vm_access(void) {
	pid_t pid;

	/* node 0 is preferred */
	if (set_mempolicy_node(MPOL_PREFERRED, 0) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 0");

	pid = fork_access();
	pprintf_wait_func(busyloop ? access_all_chunks : NULL, NULL,
			  "waiting for process_vm_access\n");
	do_work_memory(__process_vm_access_chunk, &pid);
}

static int __mlock_chunk(char *p, int size, void *args) {
	int i;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mlock(p + i * HPS, PS);
	} else
		mlock(p, size);
}

void __do_mlock(void) {
	if (forkflag)
		fork_access();
	do_work_memory(__mlock_chunk, NULL);
}

/* only true for x86_64 */
#define __NR_mlock2 325

static int __mlock2_chunk(char *p, int size, void *args) {
	int i;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			syscall(__NR_mlock2, p + i * HPS, PS, 1);
	} else
		syscall(__NR_mlock2, p, size, 1);
}

void __do_mlock2(void) {
	if (forkflag)
		fork_access();
	do_work_memory(__mlock2_chunk, NULL);
}

static int __mprotect_chunk(char *p, int size, void *args) {
	int i;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mprotect(p + i * HPS, PS, protflag|PROT_EXEC);
	} else
		mprotect(p, size, protflag|PROT_EXEC);
}

void __do_mprotect(void) {
	if (forkflag)
		fork_access();
	do_work_memory(__mprotect_chunk, NULL);
}

static void allocate_transhuge(void *ptr)
{
	uint64_t ent[2];
	int i;

	/* drop pmd */
	if (mmap(ptr, THPS, PROT_READ | PROT_WRITE,
		 MAP_FIXED | MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0) != ptr)
		err("mmap transhuge");

	if (madvise(ptr, THPS, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	/* allocate transparent huge page */
	for (i = 0; i < (1 << (THP_SHIFT - PAGE_SHIFT)); i++) {
		*(volatile void **)(ptr + i * PAGE_SIZE) = ptr;
	}
}

static void do_memory_compaction(void) {
	size_t ram, len;
	void *ptr, *p;

	ram = sysconf(_SC_PHYS_PAGES);
	if (ram > SIZE_MAX / sysconf(_SC_PAGESIZE) / 4)
		ram = SIZE_MAX / 4;
	else
		ram *= sysconf(_SC_PAGESIZE);
	Dprintf("===> %lx\n", ram);
	len = ram;
	Dprintf("===> %lx\n", len);
	len -= len % THPS;
	ptr = mmap((void *)ADDR_INPUT, len + THPS, PROT_READ | PROT_WRITE,
			MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0);

	if (madvise(ptr, len, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	/* TODO: move to pprintf_wait_func */
	pprintf("entering busy loop\n");
	while (flag) {
		for (p = ptr; p < ptr + len; p += THPS) {
			allocate_transhuge(p);
			/* split transhuge page, keep last page */
			if (madvise(p, THPS - PAGE_SIZE, MADV_DONTNEED))
				err("MADV_DONTNEED");
		}
	}
}

static void __do_allocate_more(void) {
	char *panon;
	int size = nr_p * PS;

	panon = checked_mmap((void *)(ADDR_INPUT + size), size, MMAP_PROT,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* should cause swap out with external cgroup setting */
	pprintf("anonymous address starts at %p\n", panon);
	memset(panon, 'a', size);
}

/* inject only onto the first page, so allocating big region makes no sense. */
void __do_memory_error_injection(void) {
	char rbuf[256];
	unsigned long offset = 0;

	switch (injection_type) {
	case MCE_SRAO:
	case SYSFS_HARD:
	case SYSFS_SOFT:
		pprintf("waiting for injection from outside\n");
		pause();
		break;
	case MADV_HARD:
	case MADV_SOFT:
		pprintf("error injection with madvise\n");
		pause();
		pipe_read(rbuf);
		offset = strtol(rbuf, NULL, 0);
		Dprintf("madvise inject to addr %lx\n", chunkset[0].p + offset * PS);
		if (madvise(chunkset[0].p + offset * PS, PS, injection_type == MADV_HARD ?
			    MADV_HWPOISON : MADV_SOFT_OFFLINE) != 0)
			perror("madvise");
		pprintf("after madvise injection\n");
		pause();
		break;
	}

	if (access_after_injection) {
		pprintf("writing affected region\n");
		pause();
		access_all_chunks(NULL);
	}
}

static void __do_madv_stress() {
	int i, j;
	int madv = (injection_type == MADV_HARD ? MADV_HWPOISON : MADV_SOFT_OFFLINE);

	for (j = 0; j < nr_mem_types; j++) {
		for (i = 0; i < nr_chunk; i++) {
			struct mem_chunk *tmp = &chunkset[i + j * nr_chunk];

			if (madvise(tmp->p, PS, madv) == -1) {
				fprintf(stderr, "chunk:%p, backend:%d\n",
					tmp->p, tmp->mem_type);
				perror("madvise");
			}
		}
	}
}

static void _do_madv_stress(void) {
	__do_madv_stress();
	if (access_after_injection)
		access_all_chunks(NULL);
}

static void __do_fork_stress(void) {
	while (flag) {
		pid_t pid = fork();
		if (!pid) {
			access_all_chunks(NULL);
			return;
		}
		/* get status? */
		waitpid(pid, NULL, 0);
	}
}

static int __mremap_chunk(char *p, int csize, void *args) {
	int offset = nr_chunk * CHUNKSIZE * PS;
	int back = *(int *)args; /* 0: +offset, 1: -offset*/
	void *new;

	if (back) {
		printf("mremap p:%p+%lx -> %p\n", p + offset, csize, p);
		new = mremap(p + offset, csize, csize, MREMAP_MAYMOVE|MREMAP_FIXED, p);
	} else {
		printf("mremap p:%p+%lx -> %p\n", p, csize, p + offset);
		new = mremap(p, csize, csize, MREMAP_MAYMOVE|MREMAP_FIXED, p + offset);
	}
	return new == MAP_FAILED ? -1 : 0;
}

static void __do_mremap_stress(void) {
	while (flag) {
		int back = 0;

		back = 0;
		do_work_memory(__mremap_chunk, (void *)&back);

		back = 1;
		do_work_memory(__mremap_chunk, (void *)&back);
	}
}

static int __madv_willneed_chunk(char *p, int size, void *args) {
	return madvise(p, size, MADV_WILLNEED);
}

static void __do_madv_willneed(void) {
	do_work_memory(__madv_willneed_chunk, NULL);
}

static void operate_with_mapping_iteration(void) {
	while (flag) {
		mmap_all_chunks();
		access_all_chunks(NULL);
		munmap_all_chunks();
	}
}

static int iterate_mbind_pingpong(void *arg) {
	struct mbind_arg *mbind_arg = (struct mbind_arg *)arg;

	numa_bitmask_clearall(mbind_arg->new_nodes);
	numa_bitmask_setbit(mbind_arg->new_nodes, 1);
	do_work_memory(__mbind_chunk, mbind_arg);

	numa_bitmask_clearall(mbind_arg->new_nodes);
	numa_bitmask_setbit(mbind_arg->new_nodes, 0);
	do_work_memory(__mbind_chunk, mbind_arg);
}

static void __do_mbind_pingpong(void) {
	int ret;
	int node;
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);

	pprintf_wait_func(iterate_mbind_pingpong, &mbind_arg,
			  "entering iterate_mbind_pingpong\n");
}

static void __do_move_pages_pingpong(void) {
	while (flag) {
		int node;

		node = 1;
		do_work_memory(__move_pages_chunk, &node);

		node = 0;
		do_work_memory(__move_pages_chunk, &node);
	}
}

static void do_hugetlb_reserve(void) {
	mmap_all_chunks();
	__busyloop();
	munmap_all_chunks();
}

enum {
	NR_memory_error_injection,
	NR_mlock,
	NR_test,
	NR_mmap,
	NR_OPERATIONS,
};

static const char *operation_name[] = {
	[NR_memory_error_injection]	= "memory_error_injection",
	[NR_mlock]	= "mlock",
	[NR_test]	= "test",
	[NR_mmap]	= "mmap",
};

static const char *op_supported_args[][10] = {
	[NR_memory_error_injection]	= {"asdf"},
	[NR_mlock]	= {"mlock", "fjfj", "sadf"},
	[NR_test]	= {"test", "ffmm"},
	[NR_mmap]	= {"test", "ffmm", "key2"},
};

struct op_control {
	char *name;
	int wait_before;
	int wait_after;
	char **args;
	char **keys;
	char **values;
	int nr_args;
};

static int get_op_index(struct op_control *opc) {
	int i;

	for (i = 0; i < NR_OPERATIONS; i++)
		if (!strcmp(operation_name[i], opc->name))
			return i;
}

static int parse_operation_arg(struct op_control *opc) {
	int i = 0, op_idx, j;
	char key, *value;
	char buf[256]; /* TODO: malloc? */
	int supported;

	/* op_idx = get_op_index(opc); */
	/* if (op_idx == NR_OPERATIONS) */
	/* 	errmsg("unknown operation: %s\n", opc->name); */

	for (i = 0; i < opc->nr_args; i++) {
		opc->keys[i] = calloc(1, 64);
		opc->values[i] = calloc(1, 64);

		sscanf(opc->args[i], "%[^=]=%s", opc->keys[i], opc->values[i]);

		if (!strcmp(opc->keys[i], "wait_before")) {
			opc->wait_before = 1;
			continue;
		}
		if (!strcmp(opc->keys[i], "wait_after")) {
			opc->wait_after = 1;
			continue;
		}

		supported = 0;
		j = 0;
		while (op_supported_args[op_idx][j]) {
			if (!strcmp(op_supported_args[op_idx][j], opc->keys[i])) {
				supported = 1;
				break;
			}
			j++;
		}
		if (!supported)
			errmsg("operation %s does not support argument %s\n",
			       opc->name, opc->keys[i]);
	}
	return 0;
}

static void print_opc(struct op_control *opc) {
	int i;
	int op_idx = get_op_index(opc);

	printf("===> op_name:%s", opc->name);
	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->values[i], ""))
			printf(", %s", opc->keys[i]);
		else
			printf(", %s=%s", opc->keys[i], opc->values[i]);
	}
	printf("\n");
}

char *op_args[256];
static void parse_operation_args(struct op_control *opc, char *str) {
	char delimiter[] = ":";
	char *ptr;
	int i = 0, j, k;
	char buf[256];
	
	memset(opc, 0, sizeof(struct op_control));
	strcpy(buf, str);

	/* TODO: need overrun check */
	opc->name = malloc(256);
	opc->args = malloc(10 * sizeof(void *));
	opc->keys = malloc(10 * sizeof(void *));
	opc->values = malloc(10 * sizeof(void *));

	ptr = strtok(buf, delimiter);
	strcpy(opc->name, ptr);
	while (1) {
		ptr = strtok(NULL, delimiter);
		if (!ptr)
			break;
		opc->args[i++] = ptr;
	}
	opc->nr_args = i;

	parse_operation_arg(opc);
	print_opc(opc);
}

char *op_strings[256];

static void do_operation_loop(void) {
	int i = 0;
	struct op_control opc;

	for (; op_strings[i] > 0; i++) {
		parse_operation_args(&opc, op_strings[i]);

		if (opc.wait_before)
			pprintf_wait(SIGUSR1, "before_%s\n", opc.name);

		if (!strcmp(opc.name, "start")) {
			;
		} else if (!strcmp(opc.name, "exit")) {
			;
		} else if (!strcmp(opc.name, "mmap")) {
			mmap_all_chunks();
		} else if (!strcmp(opc.name, "mmap_numa")) {
			mmap_all_chunks_numa();
		} else if (!strcmp(opc.name, "access")) {
			access_all_chunks(NULL);
		} else if (!strcmp(opc.name, "busyloop")) {
			do_busyloop();
		} else if (!strcmp(opc.name, "munmap")) {
			munmap_all_chunks();
		} else if (!strcmp(opc.name, "mbind")) {
			do_mbind(mpol_mode_for_page_migration, 1);
		} else if (!strcmp(opc.name, "move_pages")) {
			do_move_pages();
		} else if (!strcmp(opc.name, "mlock")) {
			__do_mlock();
		} else if (!strcmp(opc.name, "mlock2")) {
			__do_mlock2();
		} else if (!strcmp(opc.name, "hugetlb_reserve")) {
			__do_mlock2();
		} else if (!strcmp(opc.name, "memory_error_injection")) {
			do_memory_error_injection();
		} else if (!strcmp(opc.name, "auto_numa")) {
			do_auto_numa();
		} else if (!strcmp(opc.name, "mprotect")) {
			__do_mprotect();
		} else if (!strcmp(opc.name, "change_cpuset")) {
			do_change_cpuset();
		} else if (!strcmp(opc.name, "migratepages")) {
			do_migratepages();
		} else if (!strcmp(opc.name, "memory_compaction")) {
			do_memory_compaction();
		} else if (!strcmp(opc.name, "allocate_more")) {
			__do_allocate_more();
		} else if (!strcmp(opc.name, "madv_willneed")) {
			__do_madv_willneed();
		} else if (!strcmp(opc.name, "madv_soft")) {
			do_madv_soft();
		} else if (!strcmp(opc.name, "iterate_mapping")) {
			operate_with_mapping_iteration();
		} else if (!strcmp(opc.name, "mremap_stress")) {
			__do_mremap_stress();
		} else if (!strcmp(opc.name, "hotremove")) {
			do_hotremove();
		} else if (!strcmp(opc.name, "process_vm_access")) {
			__do_process_vm_access();
		} else if (!strcmp(opc.name, "fork_stress")) {
			__do_fork_stress();
		} else if (!strcmp(opc.name, "mbind_pingpong")) {
			__do_mbind_pingpong();
		} else if (!strcmp(opc.name, "madv_stress")) {
			_do_madv_stress();
		} else
			errmsg("unsupported op_string: %s\n", opc.name);

		if (opc.wait_after)
			pprintf_wait(SIGUSR1, "after_%s\n", opc.name);
	}
}

static void parse_operations(char *str) {
	char delimiter[] = " ";
	char *ptr;
	int i = 0;

	ptr = strtok(str, delimiter);
	op_strings[i++] = ptr;
	while (ptr) {
		ptr = strtok(NULL, delimiter);
		op_strings[i++] = ptr;
	}
}
