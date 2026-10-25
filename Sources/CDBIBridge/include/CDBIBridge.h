#ifndef CDBIBRIDGE_H
#define CDBIBRIDGE_H
#include <stddef.h>
#include <stdint.h>

/* ss_mtp_* exposes enumeration/metadata only. Installation's explicit-open USB API
   is isolated in SphairaUSB.h and never used by the inventory reader. */
typedef struct ss_mtp_session ss_mtp_session;
typedef enum {
    SS_MTP_OK = 0, SS_MTP_RUNTIME_MISSING = 1, SS_MTP_RUNTIME_INCOMPATIBLE = 2,
    SS_MTP_BUSY = 3, SS_MTP_NO_DEVICE = 4, SS_MTP_MULTIPLE_DEVICES = 5,
    SS_MTP_OPEN_FAILED = 6, SS_MTP_IO_FAILED = 7, SS_MTP_INVALID_METADATA = 8,
    SS_MTP_MEMORY = 9
} ss_mtp_status;
typedef struct { int code; int native_code; } ss_mtp_error;
typedef struct { uint32_t id; char *name; } ss_mtp_storage;
typedef struct {
    uint32_t id, parent_id, storage_id;
    uint64_t byte_count;
    int is_folder;
    char *name;
} ss_mtp_object;

/* On initial load, a nonempty override is authoritative (no fallback). NULL searches
   bundle/Homebrew paths. Runtime code remains resident; restart to change its selection.
   Only one session across all callers is allowed. All returned allocations are bridge-owned
   until the caller releases them using the matching clear/free function. */
int ss_mtp_open(const char *runtime_override, ss_mtp_session **out, ss_mtp_error *error);
void ss_mtp_close(ss_mtp_session *session);
int ss_mtp_get_storages(ss_mtp_session *, ss_mtp_storage **out, size_t *count, ss_mtp_error *);
void ss_mtp_free_storages(ss_mtp_storage *, size_t count);
int ss_mtp_get_children(ss_mtp_session *, uint32_t storage, uint32_t parent,
                        uint32_t **out, size_t *count, ss_mtp_error *);
int ss_mtp_get_object(ss_mtp_session *, uint32_t id, ss_mtp_object *out, ss_mtp_error *);
void ss_mtp_clear_object(ss_mtp_object *);
void ss_mtp_free(void *allocation);
/* Installation is a separate explicit-open API, not an inventory operation. */
#include "SphairaUSB.h"
#endif
