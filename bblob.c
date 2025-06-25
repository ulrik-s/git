#include "git-compat-util.h"
#include "bblob.h"
#include "alloc.h"
#include "object-file.h"
#include "hash.h"
#include "repository.h"
#include "object-store.h"
#include "streaming.h"

extern int disable_bblob_conversion;


struct bblob *lookup_bblob(struct repository *r, const struct object_id *oid)
{
       struct object *obj = lookup_object(r, oid);
       if (!obj)
	       return create_object(r, oid, alloc_bblob_node(r));
       return object_as_type(obj, OBJ_BBLOB, 0);
}

void parse_bblob_buffer(struct bblob *item)
{
	item->object.parsed = 1;
}

static int write_bblob_tree(struct repository *r, struct object_id *oids,
                           int nr, struct object_id *oid)
{
       size_t oidsz = r->hash_algo->rawsz;
       int ret;
       int groups;
       struct object_id *tmp;
       int i;

       if (nr <= BBLOB_FANOUT) {
               size_t rawlen = oidsz * BBLOB_FANOUT;
               void *raw = xcalloc(1, rawlen);

               for (i = 0; i < nr; i++)
                       memcpy((char *)raw + i * oidsz, oids[i].hash, oidsz);

               ret = write_object_file(raw, rawlen, OBJ_BBLOB, oid);
               free(raw);
               return ret;
       }

       groups = (nr + BBLOB_FANOUT - 1) / BBLOB_FANOUT;
       tmp = xcalloc(groups, sizeof(*tmp));
       for (i = 0; i < groups; i++) {
               int this = nr - i * BBLOB_FANOUT;
               if (this > BBLOB_FANOUT)
                       this = BBLOB_FANOUT;
               if (write_bblob_tree(r, oids + i * BBLOB_FANOUT, this, &tmp[i])) {
                       free(tmp);
                       return -1;
               }
       }
       ret = write_bblob_tree(r, tmp, groups, oid);
       free(tmp);
       return ret;
}

int write_bblob(struct repository *r, const void *buf, unsigned long len,
               struct object_id *oid)
{
       size_t oids_alloc = 0, oids_nr = 0;
       struct object_id *oids = NULL;
       unsigned char window[64];
       size_t win_len = 0;
       size_t chunk_start = 0;
       size_t i;
       int ret;

       for (i = 0; i < len; i++) {
               window[win_len % 64] = ((const unsigned char *)buf)[i];
	       if (win_len >= 63 && i - chunk_start + 1 >= BBLOB_CHUNK_GOAL) {
                       struct git_hash_ctx c;
                       unsigned char out[GIT_MAX_RAWSZ];
                       unsigned short bits;
		       r->hash_algo->init_fn(&c);
		       git_hash_update(&c, window, 64);
                       git_hash_final(out, &c);
                       bits = (out[r->hash_algo->rawsz - 2] << 8) |
                               out[r->hash_algo->rawsz - 1];
		       if ((bits & 0x1fff) == 0) {
                               struct object_id ch;
			       disable_bblob_conversion++;
			       if (write_object_file((const char *)buf + chunk_start,
						    i - chunk_start + 1,
						    OBJ_BLOB, &ch)) {
				       disable_bblob_conversion--;
				       free(oids);
				       return -1;
			       }
			       disable_bblob_conversion--;
			       ALLOC_GROW(oids, oids_nr + 1, oids_alloc);
			       oidcpy(&oids[oids_nr++], &ch);
			       chunk_start = i + 1;
		       }
	       }
	       win_len++;
       }
       if (chunk_start < len) {
	       struct object_id ch;
	       disable_bblob_conversion++;
	       if (write_object_file((const char *)buf + chunk_start,
				    len - chunk_start,
				    OBJ_BLOB, &ch)) {
		       disable_bblob_conversion--;
		       free(oids);
		       return -1;
	       }
	       disable_bblob_conversion--;
	       ALLOC_GROW(oids, oids_nr + 1, oids_alloc);
	       oidcpy(&oids[oids_nr++], &ch);
       }

       ret = write_bblob_tree(r, oids, oids_nr, oid);
       free(oids);
       return ret;
}

static void *read_raw(struct repository *r, const struct object_id *oid,
		      enum object_type *type, unsigned long *size)
{
       struct object_info oi = OBJECT_INFO_INIT;
       void *data;

       oi.typep = type;
       oi.sizep = size;
       oi.contentp = &data;
       if (oid_object_info_extended(r, oid, &oi,
				    OBJECT_INFO_DIE_IF_CORRUPT | OBJECT_INFO_LOOKUP_REPLACE))
	       return NULL;
       return data;
}

static void *read_bblob_rec(struct repository *r, const struct object_id *oid,
                            unsigned long *size)
{
       enum object_type t;
       unsigned long sz;
       size_t oidsz = r->hash_algo->rawsz;
       int cnt;
       unsigned long out_sz = 0;
       char *out = NULL;
       int i;
       void *data = read_raw(r, oid, &t, &sz);
       if (!data)
	       return NULL;
       if (t == OBJ_BLOB) {
	       *size = sz;
	       return data;
       }
       if (t != OBJ_BBLOB) {
	       free(data);
	       return NULL;
       }


       cnt = sz / oidsz;

       for (i = 0; i < cnt; i++) {
               struct object_id child;
               unsigned long csz;
               void *cbuf;

               memset(&child, 0, sizeof(child));
               memcpy(child.hash, (char *)data + i * oidsz, oidsz);
               if (is_null_oid(&child))
                       continue;

               cbuf = read_bblob_rec(r, &child, &csz);
               if (!cbuf) {
                       free(out);
                       free(data);
                       return NULL;
               }
	       REALLOC_ARRAY(out, out_sz + csz);
	       memcpy(out + out_sz, cbuf, csz);
	       out_sz += csz;
	       free(cbuf);
       }
       free(data);
       *size = out_sz;
       return out;
}

static unsigned long size_bblob_rec(struct repository *r, const struct object_id *oid)
{
       enum object_type t;
       unsigned long sz;
       size_t oidsz = r->hash_algo->rawsz;
       int cnt;
       unsigned long total = 0;
       int i;
       void *data = read_raw(r, oid, &t, &sz);
       if (!data)
               return 0;
       if (t == OBJ_BLOB) {
	       free(data);
	       return sz;
       }
       if (t != OBJ_BBLOB) {
	       free(data);
	       return 0;
       }
       cnt = sz / oidsz;

       for (i = 0; i < cnt; i++) {
               struct object_id child;

               memset(&child, 0, sizeof(child));
               memcpy(child.hash, (char *)data + i * oidsz, oidsz);
               if (is_null_oid(&child))
                       continue;

               total += size_bblob_rec(r, &child);
       }
       free(data);
       return total;
}

void *read_bblob(struct repository *r, const struct object_id *oid,
		 unsigned long *size)
{
       return read_bblob_rec(r, oid, size);
}

unsigned long bblob_size(struct repository *r, const struct object_id *oid)
{
       return size_bblob_rec(r, oid);
}
