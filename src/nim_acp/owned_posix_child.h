#ifndef ACP_OWNED_POSIX_CHILD_H
#define ACP_OWNED_POSIX_CHILD_H
#include <sys/types.h>
#include <stddef.h>
typedef struct acp_owned_posix_child acp_owned_posix_child;
int acp_owned_spawn(const char *,char *const [],char *const [],const char *,acp_owned_posix_child **);
int acp_owned_read(acp_owned_posix_child *,unsigned char *);
int acp_owned_write_frame(acp_owned_posix_child *,const char *,size_t);
int acp_owned_alive(acp_owned_posix_child *);
int acp_owned_drained(acp_owned_posix_child *);
int acp_owned_close(acp_owned_posix_child *,int,int);
void acp_owned_free(acp_owned_posix_child *);
#ifdef ACP_ADMISSION_DIAGNOSTICS
const char *acp_admission_snapshot_json(void);
#endif
#endif
