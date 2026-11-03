#ifndef CFSKIT_H
#define CFSKIT_H
#include <stdint.h>
#include <stddef.h>

/* Bits of cfsk_record.fields: which attributes the kernel actually returned. */
static const uint32_t CFSK_HAS_NAME       = 1u << 0;
static const uint32_t CFSK_HAS_ERROR      = 1u << 1;
static const uint32_t CFSK_HAS_OBJTYPE    = 1u << 2;
static const uint32_t CFSK_HAS_FILEID     = 1u << 3;
static const uint32_t CFSK_HAS_MODTIME    = 1u << 4;
static const uint32_t CFSK_HAS_CRTIME     = 1u << 5;
static const uint32_t CFSK_HAS_FLAGS      = 1u << 6;
static const uint32_t CFSK_HAS_ACCESSMASK = 1u << 7;
static const uint32_t CFSK_HAS_FNDRINFO   = 1u << 8;
static const uint32_t CFSK_HAS_DATALENGTH = 1u << 9;
static const uint32_t CFSK_HAS_ALLOCSIZE  = 1u << 10;
static const uint32_t CFSK_HAS_ENTRYCOUNT = 1u << 11;
static const uint32_t CFSK_HAS_LINKID     = 1u << 12;

/* Result codes of cfsk_cursor_next. */
static const int CFSK_NEXT_END       = 0;  /* no more records */
static const int CFSK_NEXT_OK        = 1;  /* *out filled */
static const int CFSK_NEXT_DROPPED   = 2;  /* record malformed (bad name ref etc.), skipped; call again */
static const int CFSK_NEXT_TRUNCATED = 3;  /* record length out of bounds; rest of buffer unusable; stop */

typedef struct cfsk_record {
    const char *name;          /* points into the caller's buffer; NOT NUL-terminated by contract; use name_len */
    uint32_t    name_len;      /* bytes, excluding any trailing NUL */
    uint32_t    fields;        /* CFSK_HAS_* */
    uint32_t    error;         /* ATTR_CMN_ERROR (errno) or 0 */
    uint32_t    obj_type;      /* enum vtype: VREG, VDIR, VLNK, ... */
    uint64_t    file_id;
    uint64_t    link_id;
    int64_t     mtime_ns;
    int64_t     crtime_ns;
    uint32_t    bsd_flags;     /* st_flags */
    uint32_t    access_mask;   /* R_OK|W_OK|X_OK for the calling user */
    uint16_t    finder_flags;  /* host-endian FileInfo/FolderInfo finderFlags */
    uint32_t    finder_type;   /* host-endian OSType, e.g. 'alis' */
    int64_t     data_length;
    int64_t     alloc_size;
    uint32_t    entry_count;
} cfsk_record;

typedef struct cfsk_cursor {
    const uint8_t *next;
    const uint8_t *end;
    uint32_t       remaining;  /* record count the kernel reported for this buffer */
} cfsk_cursor;

/* getattrlistbulk with the §4.2 attribute set and FSOPT_ATTR_CMN_EXTENDED (no FSOPT_PACK_INVAL_ATTRS).
   Returns entries in buf (>0), 0 at end of directory, -1 with errno set. */
int  cfsk_bulk_read(int dirfd, void *buf, size_t buflen);

/* Parser: never reads outside [buf, buf+used_len). Safe on arbitrary bytes. */
void cfsk_cursor_init(cfsk_cursor *c, const void *buf, size_t used_len, uint32_t count);
int  cfsk_cursor_next(cfsk_cursor *c, cfsk_record *out);

/* Single item via getattrlistat(dirfd, name, FSOPT_NOFOLLOW) with the same attributes (minus ATTR_CMN_ERROR).
   out->name points into buf. Returns 0, or -1 with errno set. */
int  cfsk_stat_at(int dirfd, const char *name, void *buf, size_t buflen, cfsk_record *out);

/* Materialization policy for the calling thread. */
int  cfsk_materialize_off(int *previous);   /* 0 ok, -1 errno */
int  cfsk_materialize_restore(int previous); /* 0 ok, -1 errno */

typedef struct cfsk_volcaps {
    uint8_t persistent_ids;   /* VOL_CAP_FMT_PERSISTENTOBJECTIDS */
    uint8_t rename_excl;      /* VOL_CAP_INT_RENAME_EXCL */
    uint8_t clone;            /* VOL_CAP_INT_CLONE */
    uint8_t case_sensitive;   /* VOL_CAP_FMT_CASE_SENSITIVE */
} cfsk_volcaps;
int  cfsk_volume_caps(const char *mount_path, cfsk_volcaps *out); /* 0 ok, -1 errno */

#endif
