#ifndef BUP_CHUNK_H
#define BUP_CHUNK_H

#include "strbuf.h"
#include "repository.h"

int bup_chunking_enabled(void);
int bup_chunk_blob(const void *data, unsigned long len, struct strbuf *out);
int bup_is_chunk_list(const char *buf, unsigned long len, int hexsz);
int bup_dechunk_blob(struct repository *r, const char *buf, unsigned long len,
		     struct strbuf *out);

#endif /* BUP_CHUNK_H */
