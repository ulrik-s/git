#define USE_THE_REPOSITORY_VARIABLE
#include "git-compat-util.h"
#include "bup-chunk.h"
#include "object-file.h"
#include "environment.h"
#include "config.h"
#include "parse.h"
#include "repository.h"
#include "hex.h"

#define BUP_WINDOWBITS   6
#define BUP_WINDOW       (1 << BUP_WINDOWBITS)
#define BUP_BLOB_BITS    12
#define BUP_MIN_CHUNK    (1 << BUP_BLOB_BITS)
#define BUP_MAX_CHUNK    1048576
#define BUP_MASK         ((1 << BUP_BLOB_BITS) - 1)

#define BUP_HEADER "BUPCHUNK\n"
#define BUP_HEADER_LEN 9

#define ROLLSUM_CHAR_OFFSET 31

struct rollsum {
       unsigned s1, s2;
       unsigned char window[BUP_WINDOW];
       int wofs;
};

static void rollsum_init(struct rollsum *r)
{
       r->s1 = BUP_WINDOW * ROLLSUM_CHAR_OFFSET;
       r->s2 = BUP_WINDOW * (BUP_WINDOW - 1) * ROLLSUM_CHAR_OFFSET;
       r->wofs = 0;
       memset(r->window, 0, BUP_WINDOW);
}

static void rollsum_add(struct rollsum *r, unsigned char drop,
		       unsigned char add)
{
       r->s1 += add - drop;
       r->s2 += r->s1 - (BUP_WINDOW * (drop + ROLLSUM_CHAR_OFFSET));
}

#define rollsum_roll(r, ch) \
       do { \
	       rollsum_add((r), (r)->window[(r)->wofs], (ch)); \
	       (r)->window[(r)->wofs] = (ch); \
	       (r)->wofs = ((r)->wofs + 1) % BUP_WINDOW; \
       } while (0)

static uint32_t rollsum_digest(const struct rollsum *r)
{
       return (r->s1 << 16) | (r->s2 & 0xffff);
}

int bup_chunking_enabled(void)
{
	const char *e = getenv("GIT_BUP_CHUNKING");
	int v;

	if (e)
	return git_env_bool("GIT_BUP_CHUNKING", 0);

	if (the_repository &&
	!repo_config_get_bool(the_repository, "bup.chunking", &v))
	return v;
	if (!git_config_get_bool("bup.chunking", &v))
	return v;

	return 0;
}

static size_t bup_chunk_next(const unsigned char *data, size_t len)
{
       struct rollsum r;
       size_t i;

       rollsum_init(&r);
       for (i = 0; i < len; i++) {
	       rollsum_roll(&r, data[i]);
	       if (i + 1 >= BUP_MIN_CHUNK &&
		   ((rollsum_digest(&r) & BUP_MASK) == BUP_MASK))
		       return i + 1;
	       if (i + 1 >= BUP_MAX_CHUNK)
		       return i + 1;
       }
       return len;
}

int bup_chunk_blob(const void *data, unsigned long len, struct strbuf *out)
{
        const unsigned char *buf = data;
        size_t off = 0;
        int first = 1;
        struct object_id full;

        hash_object_file(the_repository->hash_algo, data, len, OBJ_BLOB, &full);
        strbuf_addstr(out, BUP_HEADER);
        strbuf_addstr(out, oid_to_hex(&full));
        strbuf_addch(out, '\n');

        while (off < len) {
                size_t chunk = bup_chunk_next(buf + off, len - off);
                struct object_id oid;

               if (write_object_file_flags(buf + off, chunk, OBJ_BLOB, &oid,
                                          NULL, WRITE_OBJECT_FILE_NO_CHUNK))
                       return -1;
                if (!first)
                        strbuf_addch(out, '\n');
                strbuf_addstr(out, oid_to_hex(&oid));
                off += chunk;
                first = 0;
        }
        return 0;
}

int bup_is_chunk_list(const char *buf, unsigned long len, int hexsz)
{
       unsigned long off = 0, i;

       if (len < (unsigned long)(BUP_HEADER_LEN + hexsz + 1))
               return 0;
       if (strncmp(buf, BUP_HEADER, BUP_HEADER_LEN))
               return 0;
       off = BUP_HEADER_LEN;
       for (i = 0; i < (unsigned long)hexsz; i++)
               if (!isxdigit(buf[off + i]))
                       return 0;
       off += hexsz;
       if (buf[off] != '\n')
               return 0;
       off++;

       while (off < len) {
               if (off + hexsz > len)
                       return 0;
               for (i = 0; i < (unsigned long)hexsz; i++)
                       if (!isxdigit(buf[off + i]))
                               return 0;
               off += hexsz;
               if (off == len)
                       break;
               if (buf[off] != '\n')
                       return 0;
               off++;
       }
       return 1;
}

int bup_dechunk_blob(struct repository *r, const char *buf, unsigned long len,
                     struct strbuf *out)
{
       int hexsz = r->hash_algo->hexsz;
       unsigned long off = 0;

       if (len < (unsigned long)(BUP_HEADER_LEN + hexsz + 1))
               return -1;
       if (strncmp(buf, BUP_HEADER, BUP_HEADER_LEN))
               return -1;
       off = BUP_HEADER_LEN + hexsz;
       if (buf[off] != '\n')
               return -1;
       off++;

       while (off < len) {
               struct object_id oid;
               enum object_type type;
               unsigned long chunk_size;
               void *chunk;

               if (get_oid_hex_algop(buf + off, &oid, r->hash_algo))
                       return -1;
               off += hexsz;
               if (off < len)
                       off++; /* skip newline */

	       chunk = repo_read_object_file(r, &oid, &type, &chunk_size);
	       if (!chunk || type != OBJ_BLOB) {
		       free(chunk);
		       return -1;
	       }
               strbuf_add(out, chunk, chunk_size);
               free(chunk);
       }
       return 0;
}

int bup_parse_chunk_header(struct repository *r, const char *buf,
                          unsigned long len, struct object_id *expect,
                          const char **list_start, unsigned long *list_len)
{
       int hexsz = r->hash_algo->hexsz;
       const char *p = buf;

       if (len < (unsigned long)(BUP_HEADER_LEN + hexsz + 1))
               return -1;
       if (strncmp(p, BUP_HEADER, BUP_HEADER_LEN))
               return -1;
       p += BUP_HEADER_LEN;
       if (get_oid_hex_algop(p, expect, r->hash_algo))
               return -1;
       p += hexsz;
       if ((size_t)(p - buf) >= len || *p != '\n')
               return -1;
       p++;
       if (list_start)
               *list_start = p;
       if (list_len)
               *list_len = len - (p - buf);
       return 0;
}

int bup_dechunk_and_verify(struct repository *r, const char *buf,
                           unsigned long len, struct strbuf *out)
{
       struct object_id expect, real;

       if (bup_parse_chunk_header(r, buf, len, &expect, NULL, NULL))
               return -1;
       if (bup_dechunk_blob(r, buf, len, out))
               return -1;
       hash_object_file(r->hash_algo, out->buf, out->len, OBJ_BLOB, &real);
       if (!oideq(&real, &expect))
               return -1;
       return 0;
}

int bup_for_each_chunk(struct repository *r, const char *buf, unsigned long len,
                      int (*cb)(const struct object_id *, void *), void *data)
{
       const char *p;
       unsigned long remain;
       struct object_id oid, dummy;
       int hexsz = r->hash_algo->hexsz;

       if (bup_parse_chunk_header(r, buf, len, &dummy, &p, &remain))
               return -1;
       while (remain) {
               if (remain < (unsigned long)hexsz)
                       return -1;
               if (get_oid_hex_algop(p, &oid, r->hash_algo))
                       return -1;
               if (cb(&oid, data))
                       return -1;
               p += hexsz;
               remain -= hexsz;
               if (remain && *p == '\n') {
                       p++;
                       remain--;
               }
       }
       return 0;
}
int bup_maybe_dechunk(struct repository *r, enum object_type type,
                      const char *buf, unsigned long len,
                      struct strbuf *out)
{
    if (type != OBJ_BLOB)
        return 0;
    if (!bup_is_chunk_list(buf, len, r->hash_algo->hexsz))
        return 0;
    if (bup_dechunk_and_verify(r, buf, len, out))
        return -1;
    return 1;
}
