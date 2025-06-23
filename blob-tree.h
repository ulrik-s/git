#ifndef BLOB_TREE_H
#define BLOB_TREE_H

#include "object.h"

struct repository;
struct strbuf;

struct blob_tree {
        struct object object;
        void *buffer;
        unsigned long size;
};

extern const char *blob_tree_type;

struct blob_tree *lookup_blob_tree(struct repository *r, const struct object_id *oid);
int parse_blob_tree_buffer(struct blob_tree *item, void *buffer, unsigned long size);
int parse_blob_tree_gently(struct blob_tree *tree, int quiet_on_missing);
static inline int parse_blob_tree(struct blob_tree *tree)
{
        return parse_blob_tree_gently(tree, 0);
}
void free_blob_tree_buffer(struct blob_tree *tree);
struct blob_tree *parse_blob_tree_indirect(const struct object_id *oid);


int write_blob_tree_fd(int fd, struct object_id *oid);
int write_blob_tree_file(const char *path, struct object_id *oid);

#endif /* BLOB_TREE_H */
