#ifndef SIMPLE_ODB_H
#define SIMPLE_ODB_H

#include "git-compat-util.h"
#include "hash.h"
#include "object.h"
#include "strbuf.h"

struct simple_odb {
        struct strbuf root;
        struct strbuf objects_dir;
};

void simple_odb_init(struct simple_odb *odb);
void simple_odb_release(struct simple_odb *odb);

int simple_odb_prepare(struct simple_odb *odb, const char *path);
int simple_odb_store_buffer(struct simple_odb *odb,
                            enum object_type type,
                            const void *data,
                            size_t len,
                            struct object_id *oid);

#endif /* SIMPLE_ODB_H */
