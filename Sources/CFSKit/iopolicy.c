#include "CFSKit.h"
#include <sys/resource.h>

int cfsk_materialize_off(int *previous) {
    int prev = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    if (prev < 0) return -1;
    if (setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0) return -1;
    *previous = prev;
    return 0;
}

int cfsk_materialize_restore(int previous) {
    return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
}
