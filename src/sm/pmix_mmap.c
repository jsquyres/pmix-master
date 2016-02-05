/*
 * Copyright (c) 2015-2016 Mellanox Technologies, Inc.
 *                         All rights reserved.
 * $COPYRIGHT$
 *
 * Additional copyrights may follow
 *
 * $HEADER$
 */


#include <unistd.h>
#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

#include <private/autogen/config.h>
#include <pmix/pmix_common.h>
#include "src/include/pmix_globals.h"

#include "pmix_sm.h"
#include "pmix_mmap.h"

#if !defined(MAP_ANONYMOUS) && defined(MAP_ANON)
#    define MAP_ANONYMOUS MAP_ANON
#endif /* MAP_ANONYMOUS and MAP_ANON */


static int _mmap_segment_create(pmix_sm_seg_t *sm_seg, const char *file_name, size_t size);
static int _mmap_segment_attach(pmix_sm_seg_t *sm_seg);
static int _mmap_segment_detach(pmix_sm_seg_t *sm_seg);
static int _mmap_segment_unlink(pmix_sm_seg_t *sm_seg);

pmix_sm_base_module_t pmix_sm_mmap_module = {
    "mmap",
    _mmap_segment_create,
    _mmap_segment_attach,
    _mmap_segment_detach,
    _mmap_segment_unlink
};


int _mmap_segment_create(pmix_sm_seg_t *sm_seg, const char *file_name, size_t size)
{
    int rc;
    void *seg_addr;
    pid_t my_pid = getpid();
    rc = PMIX_SUCCESS;
    _segment_ds_reset(sm_seg);
    /* enough space is available, so create the segment */
    if (-1 == (sm_seg->seg_id = open(file_name, O_CREAT | O_RDWR, 0600))) {
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call open(2) fail\n");
        rc = PMIX_ERROR;
        goto out;
    }
    /* size backing file - note the use of real_size here */
    if (0 != ftruncate(sm_seg->seg_id, size)) {
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call ftruncate(2) fail\n");
        rc = PMIX_ERROR;
        goto out;
    }
    if (MAP_FAILED == (seg_addr = mmap(NULL, size,
                                       PROT_READ | PROT_WRITE, MAP_SHARED,
                                       sm_seg->seg_id, 0))) {
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call mmap(2) fail\n");
        rc = PMIX_ERROR;
        goto out;
    }
    sm_seg->seg_cpid = my_pid;
    sm_seg->seg_size = size;
    sm_seg->seg_base_addr = (unsigned char *)seg_addr;
    (void)strncpy(sm_seg->seg_name, file_name, PMIX_PATH_MAX - 1);

out:
    if (-1 != sm_seg->seg_id) {
        if (0 != close(sm_seg->seg_id)) {
            pmix_output_verbose(2, pmix_globals.debug_output,
                    "sys call close(2) fail\n");
            rc = PMIX_ERROR;
         }
     }
    /* an error occured, so invalidate the shmem object and munmap if needed */
    if (PMIX_SUCCESS != rc) {
        if (MAP_FAILED != seg_addr) {
            munmap((void *)seg_addr, size);
        }
        _segment_ds_reset(sm_seg);
    }
    return rc;
}

int _mmap_segment_attach(pmix_sm_seg_t *sm_seg)
{
    if (-1 == (sm_seg->seg_id = open(sm_seg->seg_name, O_RDWR))) {
        return PMIX_ERROR;
    }
    if (MAP_FAILED == (sm_seg->seg_base_addr = (unsigned char *)
                mmap(NULL, sm_seg->seg_size,
                    PROT_READ | PROT_WRITE, MAP_SHARED,
                    sm_seg->seg_id, 0))) {
        /* mmap failed, so close the file and return NULL - no error check
         * here because we are already in an error path...
         */
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call mmap(2) fail\n");
        close(sm_seg->seg_id);
        return PMIX_ERROR;
    }
    /* all is well */
    /* if close fails here, that's okay.  just let the user know and
     * continue.  if we got this far, open and mmap were successful...
     */
    if (0 != close(sm_seg->seg_id)) {
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call close(2) fail\n");
    }
    sm_seg->seg_cpid = 0;/* FIXME */
    return PMIX_SUCCESS;
}

int _mmap_segment_detach(pmix_sm_seg_t *sm_seg)
{
    int rc = PMIX_SUCCESS;

    if (0 != munmap((void *)sm_seg->seg_base_addr, sm_seg->seg_size)) {
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call munmap(2) fail\n");
        rc = PMIX_ERROR;
    }
    /* reset the contents of the pmix_sm_seg_t associated with this
     * shared memory segment.
     */
    _segment_ds_reset(sm_seg);
    return rc;
}

int _mmap_segment_unlink(pmix_sm_seg_t *sm_seg)
{
    if (-1 == unlink(sm_seg->seg_name)) {
        pmix_output_verbose(2, pmix_globals.debug_output,
                "sys call unlink(2) fail\n");
        return PMIX_ERROR;
    }

    sm_seg->seg_id = PMIX_SHMEM_DS_ID_INVALID;
    return PMIX_SUCCESS;
}
