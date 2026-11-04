#include "CFSKit.h"
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/attr.h>

int cfsk_parse_single(const void *buf, size_t used_len, cfsk_record *out);  /* cursor.c */

static void fill_attrlist(struct attrlist *al, int bulk) {
    memset(al, 0, sizeof *al);
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID |
                     ATTR_CMN_MODTIME | ATTR_CMN_CRTIME | ATTR_CMN_FLAGS | ATTR_CMN_USERACCESS | ATTR_CMN_FNDRINFO;
    if (bulk) al->commonattr |= ATTR_CMN_ERROR;
    al->fileattr = ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE;
    al->dirattr = ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS;
    al->forkattr = ATTR_CMNEXT_LINKID;
}

int cfsk_bulk_read(int dirfd, void *buf, size_t buflen) {
    struct attrlist al;
    fill_attrlist(&al, 1);
    return getattrlistbulk(dirfd, &al, buf, buflen, FSOPT_ATTR_CMN_EXTENDED);
}

int cfsk_stat_at(int dirfd, const char *name, void *buf, size_t buflen, cfsk_record *out) {
    struct attrlist al;
    fill_attrlist(&al, 0);
    if (getattrlistat(dirfd, name, &al, buf, buflen, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) != 0) return -1;
    int rc = cfsk_parse_single(buf, buflen, out);
    if (rc != CFSK_NEXT_OK) { errno = EIO; return -1; }
    return 0;
}
