#include "CFSKit.h"
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>

struct cfsk_capsbuf {
    uint32_t length;
    vol_capabilities_attr_t caps;
} __attribute__((aligned(4), packed));

static uint8_t has(const vol_capabilities_attr_t *c, int idx, uint32_t bit) {
    return (c->valid[idx] & bit) && (c->capabilities[idx] & bit) ? 1 : 0;
}

int cfsk_volume_caps(const char *mount_path, cfsk_volcaps *out) {
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;
    struct cfsk_capsbuf buf;
    memset(&buf, 0, sizeof buf);
    if (getattrlist(mount_path, &al, &buf, sizeof buf, 0) != 0) return -1;
    out->persistent_ids = has(&buf.caps, VOL_CAPABILITIES_FORMAT, VOL_CAP_FMT_PERSISTENTOBJECTIDS);
    out->case_sensitive = has(&buf.caps, VOL_CAPABILITIES_FORMAT, VOL_CAP_FMT_CASE_SENSITIVE);
    out->rename_excl = has(&buf.caps, VOL_CAPABILITIES_INTERFACES, VOL_CAP_INT_RENAME_EXCL);
    out->clone = has(&buf.caps, VOL_CAPABILITIES_INTERFACES, VOL_CAP_INT_CLONE);
    return 0;
}
