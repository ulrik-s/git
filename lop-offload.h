#ifndef LOP_OFFLOAD_H
#define LOP_OFFLOAD_H

#include "git-compat-util.h"
#include "hash.h"
#include "strbuf.h"

struct repository;
struct command;

struct lop_blob_info {
    struct object_id oid;
    const char *path;
    uintmax_t size;
};

struct lop_offload_ctx;

int lop_receive_pack_config(const char *var, const char *value);

void lop_process_push(struct repository *repo, struct command *commands);

struct lop_offload_ctx *lop_offload_start(struct repository *r);
int lop_offload_blob_cb(const struct lop_blob_info *blob, void *data);
int lop_offload_had_error(const struct lop_offload_ctx *ctx);
const struct strbuf *lop_offload_error(const struct lop_offload_ctx *ctx);
void lop_offload_finish(struct lop_offload_ctx *ctx);
void lop_offload_abort(struct lop_offload_ctx *ctx);

#endif /* LOP_OFFLOAD_H */
