#include "git-compat-util.h"
#include "bup-chunk.h"
#include "object-file.h"
#include "environment.h"
#include "hex.h"

#define BUP_WINDOWBITS   6
#define BUP_WINDOW       (1 << BUP_WINDOWBITS)
#define BUP_BLOB_BITS    12
#define BUP_MIN_CHUNK    (1 << BUP_BLOB_BITS)
#define BUP_MAX_CHUNK    1048576
#define BUP_MASK         ((1 << BUP_BLOB_BITS) - 1)

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
	return e && *e;
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
       unsigned long off = 0;

       while (off < len) {
	       unsigned long i;
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
