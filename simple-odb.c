#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "environment.h"
#include "dir.h"
#include "hash.h"
#include "hex.h"
#include "path.h"
#include "repository.h"
#include "simple-odb.h"
#include "wrapper.h"
#include "git-zlib.h"

static int make_dir(const char *path)
{
        char *dup;

        if (!path || !*path)
                return error("simple-odb: empty path");

        dup = xstrdup(path);
        if (safe_create_leading_directories_no_share(dup) < 0) {
                int save_errno = errno;
                free(dup);
                errno = save_errno;
                return error_errno("unable to create directories for '%s'", path);
        }
        free(dup);

        if (mkdir(path, 0777) && errno != EEXIST)
                return error_errno("unable to create '%s'", path);

        return 0;
}

void simple_odb_init(struct simple_odb *odb)
{
        strbuf_init(&odb->root, 0);
        strbuf_init(&odb->objects_dir, 0);
}

void simple_odb_release(struct simple_odb *odb)
{
        strbuf_release(&odb->root);
        strbuf_release(&odb->objects_dir);
}

int simple_odb_prepare(struct simple_odb *odb, const char *path)
{
        struct strbuf real = STRBUF_INIT;
        struct strbuf tmp = STRBUF_INIT;
        int ret = -1;

        if (!path || !*path)
                return error("simple-odb: missing object directory path");

        strbuf_addstr(&tmp, path);
        if (make_dir(tmp.buf))
                goto out;

        if (!strbuf_realpath(&real, tmp.buf, 1)) {
                error_errno("simple-odb: unable to canonicalize '%s'", tmp.buf);
                goto out;
        }

        strbuf_addf(&odb->objects_dir, "%s/objects", real.buf);
        if (make_dir(odb->objects_dir.buf))
                goto out;
        if (make_dir(mkpath("%s/info", odb->objects_dir.buf)))
                goto out;
        if (make_dir(mkpath("%s/pack", odb->objects_dir.buf)))
                goto out;

        strbuf_swap(&odb->root, &real);
        ret = 0;
out:
        strbuf_release(&real);
        strbuf_release(&tmp);
        if (ret)
                simple_odb_release(odb);
        return ret;
}

int simple_odb_store_buffer(struct simple_odb *odb,
                            enum object_type type,
                            const void *data,
                            size_t len,
                            struct object_id *oid)
{
        struct git_hash_ctx ctx;
        struct strbuf dir = STRBUF_INIT;
        struct strbuf path = STRBUF_INIT;
        struct strbuf tmp = STRBUF_INIT;
        struct strbuf header = STRBUF_INIT;
        struct git_zstream stream;
        unsigned long maxsize;
        size_t header_len;
        size_t total_len;
        size_t compressed_len;
        int fd = -1;
        int ret = -1;
        unsigned char *payload = NULL;
        unsigned char *compressed = NULL;
        const char *type_name_str = type_name(type);
        const struct git_hash_algo *algo;

        if (!odb->objects_dir.len)
                return error("simple-odb: object directory not initialized");
        if (!type_name_str)
                return error("simple-odb: invalid object type");

        strbuf_addf(&header, "%s %"PRIuMAX, type_name_str, (uintmax_t)len);
        header_len = header.len + 1;

        total_len = header_len + len;
        payload = xmalloc(total_len);
        memcpy(payload, header.buf, header_len);
        if (len)
                memcpy(payload + header_len, data, len);

        algo = the_repository ? the_repository->hash_algo
                              : &hash_algos[GIT_HASH_SHA1_LEGACY];

        oid_set_algo(oid, algo);

        algo->init_fn(&ctx);
        algo->update_fn(&ctx, payload, total_len);
        algo->final_oid_fn(oid, &ctx);

        git_deflate_init(&stream, zlib_compression_level);
        maxsize = git_deflate_bound(&stream, total_len);
        compressed = xmalloc(maxsize);
        stream.next_in = payload;
        stream.avail_in = total_len;
        stream.next_out = compressed;
        stream.avail_out = maxsize;
        if (git_deflate(&stream, Z_FINISH) != Z_STREAM_END) {
                error("simple-odb: unable to compress object");
                git_deflate_abort(&stream);
                goto out;
        }
        compressed_len = maxsize - stream.avail_out;
        git_deflate_end_gently(&stream);

        const char *hex = oid_to_hex(oid);

        strbuf_addf(&dir, "%s/%2.2s", odb->objects_dir.buf, hex);
        if (make_dir(dir.buf))
                goto out;

        strbuf_addf(&path, "%s/%s", dir.buf, hex + 2);
        if (!access(path.buf, F_OK)) {
                ret = 0;
                goto out;
        }

        strbuf_addf(&tmp, "%s/.tmp_simple_XXXXXX", odb->objects_dir.buf);
        fd = xmkstemp_mode(tmp.buf, 0444);
        if (fd < 0) {
                error_errno("simple-odb: unable to create temporary file");
                goto out;
        }
        if (write_in_full(fd, compressed, compressed_len) < 0) {
                error_errno("simple-odb: unable to write object data");
                goto out;
        }
        if (close(fd) < 0) {
                error_errno("simple-odb: unable to close object file");
                fd = -1;
                goto out;
        }
        fd = -1;

        if (rename(tmp.buf, path.buf)) {
                error_errno("simple-odb: unable to move object into place");
                goto out;
        }
        strbuf_setlen(&tmp, 0);
        if (the_repository)
                adjust_shared_perm(the_repository, path.buf);
        ret = 0;
out:
        if (fd >= 0)
                close(fd);
        if (tmp.len)
                unlink_or_warn(tmp.buf);
        strbuf_release(&dir);
        strbuf_release(&path);
        strbuf_release(&tmp);
        strbuf_release(&header);
        free(payload);
        free(compressed);
        return ret;
}
