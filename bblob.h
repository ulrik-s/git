#ifndef BBLOB_H
#define BBLOB_H

#include "object.h"

/* Number of child entries in each bblob node */
#define BBLOB_FANOUT 64

/* heuristic target chunk size when splitting large blobs */
#define BBLOB_CHUNK_GOAL 4096

struct bblob {
       struct object object;
       struct object_id oids[BBLOB_FANOUT];
};

struct bblob *lookup_bblob(struct repository *r, const struct object_id *oid);
void parse_bblob_buffer(struct bblob *item);
int write_bblob(struct repository *r, const void *buf, unsigned long len,
	       struct object_id *oid);
void *read_bblob(struct repository *r, const struct object_id *oid,
		unsigned long *size);
unsigned long bblob_size(struct repository *r, const struct object_id *oid);

#endif /* BBLOB_H */
