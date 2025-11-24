#ifndef PROMISOR_ODB_H
#define PROMISOR_ODB_H

#include "git-compat-util.h"
#include "object.h"
#include "parse.h"
#include "strbuf.h"

struct lop_odb;

struct lop_odb *lop_odb_get(const char *remote_name, struct strbuf *err);
int lop_odb_write_blob(struct lop_odb *odb, const struct object_id *oid,
                       const void *data, size_t size, struct strbuf *err);
#endif
