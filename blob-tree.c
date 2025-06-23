#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "blob-tree.h"
#include "object-file.h"
#include "hex.h"
#include "object-name.h"
#include "object-store.h"
#include "alloc.h"
#include "tree-walk.h"
#include "repository.h"
#include "environment.h"

const char *blob_tree_type = "blob-tree";

struct blob_tree *lookup_blob_tree(struct repository *r, const struct object_id *oid)
{
        struct object *obj = lookup_object(r, oid);
        if (!obj)
                return create_object(r, oid, alloc_blob_tree_node(r));
        return object_as_type(obj, OBJ_BLOB_TREE, 0);
}

int parse_blob_tree_buffer(struct blob_tree *item, void *buffer, unsigned long size)
{
        if (item->object.parsed)
                return 0;
        item->object.parsed = 1;
        item->buffer = buffer;
        item->size = size;
        return 0;
}

int parse_blob_tree_gently(struct blob_tree *item, int quiet_on_missing)
{
        enum object_type type;
        void *buffer;
        unsigned long size;

        if (item->object.parsed)
                return 0;
        buffer = repo_read_object_file(the_repository, &item->object.oid,
                                       &type, &size);
        if (!buffer)
                return quiet_on_missing ? -1 :
                        error("Could not read %s",
                             oid_to_hex(&item->object.oid));
        if (type != OBJ_BLOB_TREE) {
                free(buffer);
                return error("Object %s not a blob tree",
                             oid_to_hex(&item->object.oid));
        }
        return parse_blob_tree_buffer(item, buffer, size);
}

void free_blob_tree_buffer(struct blob_tree *tree)
{
        FREE_AND_NULL(tree->buffer);
        tree->size = 0;
        tree->object.parsed = 0;
}

struct blob_tree *parse_blob_tree_indirect(const struct object_id *oid)
{
        struct repository *r = the_repository;
        struct object *obj = parse_object(r, oid);
        return (struct blob_tree *)repo_peel_to_type(r, NULL, 0, obj, OBJ_BLOB_TREE);
}


#define CHUNK_MASK 0x1fff

static uint32_t roll_hash(uint32_t hash, unsigned char c)
{
        return ((hash << 5) ^ c) & 0xffffffff;
}

int write_blob_tree_fd(int fd, struct object_id *oid)
{
        struct strbuf chunk = STRBUF_INIT;
        struct strbuf tree_buf = STRBUF_INIT;
        ssize_t n;
        unsigned char buf[8192];
        uint32_t h = 0;
        while ((n = xread(fd, buf, sizeof(buf))) > 0) {
                ssize_t i;
                for (i = 0; i < n; i++) {
                        strbuf_addch(&chunk, buf[i]);
                        h = roll_hash(h, buf[i]);
                        if ((h & CHUNK_MASK) == CHUNK_MASK || chunk.len > 65536) {
                                struct object_id c_oid;
                                if (write_object_file(chunk.buf, chunk.len, OBJ_BLOB, &c_oid)) {
                                        strbuf_release(&chunk);
                                        strbuf_release(&tree_buf);
                                        return -1;
                                }
                                strbuf_addf(&tree_buf, "%s\n", oid_to_hex(&c_oid));
                                strbuf_reset(&chunk);
                                h = 0;
                        }
                }
        }
        if (n < 0) {
                strbuf_release(&chunk);
                strbuf_release(&tree_buf);
                return -1;
        }
        if (chunk.len) {
                struct object_id c_oid;
                if (write_object_file(chunk.buf, chunk.len, OBJ_BLOB, &c_oid)) {
                        strbuf_release(&chunk);
                        strbuf_release(&tree_buf);
                        return -1;
                }
                strbuf_addf(&tree_buf, "%s\n", oid_to_hex(&c_oid));
        }
        strbuf_release(&chunk);
        if (write_object_file(tree_buf.buf, tree_buf.len, OBJ_BLOB_TREE, oid)) {
                strbuf_release(&tree_buf);
                return -1;
        }
        strbuf_release(&tree_buf);
        return 0;
}

int write_blob_tree_file(const char *path, struct object_id *oid)
{
        int fd = open(path, O_RDONLY);
        int ret;
        if (fd < 0)
                return error_errno("open('%s')", path);
        ret = write_blob_tree_fd(fd, oid);
        close(fd);
        return ret;
}

