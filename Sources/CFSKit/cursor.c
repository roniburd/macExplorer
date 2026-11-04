#include "CFSKit.h"
#include <string.h>
#include <sys/attr.h>
#include <sys/vnode.h>

/* Fixed sizes of the attributes we request, in kernel packing order. */
#define CFSK_SET_SIZE   ((size_t)sizeof(attribute_set_t))   /* 20 */
#define CFSK_REF_SIZE   ((size_t)sizeof(attrreference_t))   /* 8 */
#define CFSK_TS_SIZE    ((size_t)sizeof(struct timespec))   /* 16 on LP64 */
#define CFSK_FINFO_SIZE ((size_t)32)

typedef struct cfsk_reader {
    const uint8_t *p;     /* next field */
    const uint8_t *end;   /* end of this record */
    int ok;               /* 0 once a field ran past `end` */
} cfsk_reader;

static int take(cfsk_reader *r, void *dst, size_t n) {
    if (!r->ok || (size_t)(r->end - r->p) < n) { r->ok = 0; return 0; }
    memcpy(dst, r->p, n);
    r->p += n;
    return 1;
}

static int64_t ts_to_ns(const struct timespec *ts) {
    const int64_t limit = INT64_MAX / 1000000000LL - 1;
    int64_t sec = (int64_t)ts->tv_sec;
    if (sec > limit) return INT64_MAX;
    if (sec < -limit) return INT64_MIN;
    return sec * 1000000000LL + (int64_t)ts->tv_nsec;
}

static uint16_t be16(const uint8_t *b) { return (uint16_t)(((uint16_t)b[0] << 8) | b[1]); }
static uint32_t be32(const uint8_t *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

void cfsk_cursor_init(cfsk_cursor *c, const void *buf, size_t used_len, uint32_t count) {
    c->next = (const uint8_t *)buf;
    c->end = (const uint8_t *)buf + (buf ? used_len : 0);
    c->remaining = buf ? count : 0;
}

/* Parses one record whose bytes are [start, start+len). Returns CFSK_NEXT_OK or CFSK_NEXT_DROPPED. */
static int parse_record(const uint8_t *start, uint32_t len, int has_error_field, cfsk_record *out) {
    memset(out, 0, sizeof *out);
    cfsk_reader r = { start + sizeof(uint32_t), start + len, 1 };
    attribute_set_t set;
    if (!take(&r, &set, CFSK_SET_SIZE)) return CFSK_NEXT_DROPPED;

    if (has_error_field && (set.commonattr & ATTR_CMN_ERROR)) {
        if (!take(&r, &out->error, sizeof(uint32_t))) return CFSK_NEXT_DROPPED;
        out->fields |= CFSK_HAS_ERROR;
    }
    if (set.commonattr & ATTR_CMN_NAME) {
        const uint8_t *ref_at = r.p;
        attrreference_t ref;
        if (!take(&r, &ref, CFSK_REF_SIZE)) return CFSK_NEXT_DROPPED;
        /* offset is relative to the attrreference itself; must stay inside this record */
        int64_t off = (int64_t)ref.attr_dataoffset;
        int64_t rel = (int64_t)(ref_at - start) + off;
        if (off < 0 || ref.attr_length == 0 || rel < 0 || rel > (int64_t)len ||
            (int64_t)ref.attr_length > (int64_t)len - rel) return CFSK_NEXT_DROPPED;
        const char *name = (const char *)(start + rel);
        uint32_t n = ref.attr_length;
        if (name[n - 1] == '\0') n -= 1;          /* kernel includes the NUL in attr_length */
        if (n == 0 || memchr(name, '\0', n) != NULL) return CFSK_NEXT_DROPPED;
        out->name = name;
        out->name_len = n;
        out->fields |= CFSK_HAS_NAME;
    }
    if (set.commonattr & ATTR_CMN_DEVID) {
        dev_t d;
        if (!take(&r, &d, sizeof d)) return CFSK_NEXT_DROPPED;
        out->dev_id = (int32_t)d;
        out->fields |= CFSK_HAS_DEVID;
    }
    if (set.commonattr & ATTR_CMN_OBJTYPE) {
        fsobj_type_t t;
        if (!take(&r, &t, sizeof t)) return CFSK_NEXT_DROPPED;
        out->obj_type = (uint32_t)t;
        out->fields |= CFSK_HAS_OBJTYPE;
    }
    if (set.commonattr & ATTR_CMN_CRTIME) {
        struct timespec ts;
        if (!take(&r, &ts, CFSK_TS_SIZE)) return CFSK_NEXT_DROPPED;
        out->crtime_ns = ts_to_ns(&ts);
        out->fields |= CFSK_HAS_CRTIME;
    }
    if (set.commonattr & ATTR_CMN_MODTIME) {
        struct timespec ts;
        if (!take(&r, &ts, CFSK_TS_SIZE)) return CFSK_NEXT_DROPPED;
        out->mtime_ns = ts_to_ns(&ts);
        out->fields |= CFSK_HAS_MODTIME;
    }
    if (set.commonattr & ATTR_CMN_FNDRINFO) {
        uint8_t fi[CFSK_FINFO_SIZE];
        if (!take(&r, fi, sizeof fi)) return CFSK_NEXT_DROPPED;
        /* FileInfo: fdType[0..4], fdCreator[4..8], fdFlags[8..10]; FolderInfo: frRect[0..8], frFlags[8..10].
           Finder info is stored big-endian. */
        out->finder_flags = be16(fi + 8);
        out->finder_type = be32(fi);
        out->fields |= CFSK_HAS_FNDRINFO;
    }
    if (set.commonattr & ATTR_CMN_FLAGS) {
        uint32_t f;
        if (!take(&r, &f, sizeof f)) return CFSK_NEXT_DROPPED;
        out->bsd_flags = f;
        out->fields |= CFSK_HAS_FLAGS;
    }
    if (set.commonattr & ATTR_CMN_USERACCESS) {
        uint32_t m;
        if (!take(&r, &m, sizeof m)) return CFSK_NEXT_DROPPED;
        out->access_mask = m;
        out->fields |= CFSK_HAS_ACCESSMASK;
    }
    if (set.commonattr & ATTR_CMN_FILEID) {
        uint64_t id;
        if (!take(&r, &id, sizeof id)) return CFSK_NEXT_DROPPED;
        out->file_id = id;
        out->fields |= CFSK_HAS_FILEID;
    }
    if (set.dirattr & ATTR_DIR_ENTRYCOUNT) {
        uint32_t n;
        if (!take(&r, &n, sizeof n)) return CFSK_NEXT_DROPPED;
        out->entry_count = n;
        out->fields |= CFSK_HAS_ENTRYCOUNT;
    }
    if (set.dirattr & ATTR_DIR_MOUNTSTATUS) {
        uint32_t m;
        if (!take(&r, &m, sizeof m)) return CFSK_NEXT_DROPPED;
        out->mount_status = m;
        out->fields |= CFSK_HAS_MOUNTSTATUS;
    }
    if (set.fileattr & ATTR_FILE_ALLOCSIZE) {
        off_t v;
        if (!take(&r, &v, sizeof v)) return CFSK_NEXT_DROPPED;
        out->alloc_size = (int64_t)v;
        out->fields |= CFSK_HAS_ALLOCSIZE;
    }
    if (set.fileattr & ATTR_FILE_DATALENGTH) {
        off_t v;
        if (!take(&r, &v, sizeof v)) return CFSK_NEXT_DROPPED;
        out->data_length = (int64_t)v;
        out->fields |= CFSK_HAS_DATALENGTH;
    }
    if (set.forkattr & ATTR_CMNEXT_LINKID) {
        uint64_t id;
        if (!take(&r, &id, sizeof id)) return CFSK_NEXT_DROPPED;
        out->link_id = id;
        out->fields |= CFSK_HAS_LINKID;
    }
    return CFSK_NEXT_OK;
}

int cfsk_cursor_next(cfsk_cursor *c, cfsk_record *out) {
    for (;;) {
        if (c->remaining == 0 || c->next >= c->end) return CFSK_NEXT_END;
        size_t avail = (size_t)(c->end - c->next);
        uint32_t len;
        if (avail < sizeof len) { c->remaining = 0; return CFSK_NEXT_TRUNCATED; }
        memcpy(&len, c->next, sizeof len);
        if (len < sizeof(uint32_t) + CFSK_SET_SIZE || len > avail) { c->remaining = 0; return CFSK_NEXT_TRUNCATED; }
        const uint8_t *start = c->next;
        c->next += len;
        c->remaining -= 1;
        int rc = parse_record(start, len, 1, out);
        if (rc == CFSK_NEXT_OK) return rc;
        return CFSK_NEXT_DROPPED;
    }
}

/* Used by cfsk_stat_at (bulk.c): a getattrlist buffer is one record without ATTR_CMN_ERROR. */
int cfsk_parse_single(const void *buf, size_t used_len, cfsk_record *out) {
    uint32_t len;
    if (used_len < sizeof len) return CFSK_NEXT_TRUNCATED;
    memcpy(&len, buf, sizeof len);
    if (len < sizeof(uint32_t) + CFSK_SET_SIZE || len > used_len) return CFSK_NEXT_TRUNCATED;
    return parse_record((const uint8_t *)buf, len, 0, out);
}
