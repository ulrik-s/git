#ifndef BUP_CHUNK_H
#define BUP_CHUNK_H

#include "strbuf.h"
#include "repository.h"

int bup_chunking_enabled(void);
int bup_chunk_blob(const void *data, unsigned long len, struct strbuf *out);
int bup_is_chunk_list(const char *buf, unsigned long len, int hexsz);
int bup_dechunk_blob(struct repository *r, const char *buf, unsigned long len,
                     struct strbuf *out);
int bup_parse_chunk_header(struct repository *r, const char *buf,
                          unsigned long len, struct object_id *expect,
                          const char **list_start, unsigned long *list_len);
int bup_dechunk_and_verify(struct repository *r, const char *buf,
                           unsigned long len, struct strbuf *out);
int bup_for_each_chunk(struct repository *r, const char *buf, unsigned long len,
                       int (*cb)(const struct object_id *, void *), void *data);

#define BUP_HEADER "BUPCHUNK\n"
#define BUP_HEADER_LEN 9
#define BUP_CHUNK_THRESHOLD 4096

#endif /* BUP_CHUNK_H */
