#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "git-compat-util.h"
#include "hash.h"
#include "hex.h"
#include "object-file.h"
#include "object.h"
#include "setup.h"
#include "strbuf.h"

struct simple_odb_header {
    const struct git_hash_algo *algo;
};

static const char simple_odb_magic[] = "simple-odb v1";

static void simple_odb_write_header(FILE *f, const struct git_hash_algo *algo)
{
    fprintf(f, "%s %s\n", simple_odb_magic, algo->name);
}

static void simple_odb_read_header(FILE *f, struct simple_odb_header *out)
{
    struct strbuf line = STRBUF_INIT;
    const char *algo_name;
    int algo;

    if (strbuf_getline_lf(&line, f) == EOF)
        die("invalid simple odb file: missing header");

    if (!skip_prefix(line.buf, simple_odb_magic, &algo_name) ||
        !algo_name || *algo_name != ' ')
        die("invalid simple odb header: '%s'", line.buf);

    algo_name++;
    algo = hash_algo_by_name(algo_name);
    if (algo < 0)
        die("unknown hash algorithm '%s' in simple odb", algo_name);

    out->algo = &hash_algos[algo];
    strbuf_release(&line);
}

static const struct git_hash_algo *detect_default_algo(void)
{
    int nongit_ok = 0;

    setup_git_directory_gently(&nongit_ok);
    if (!nongit_ok && the_repository->hash_algo)
        return the_repository->hash_algo;

    return &hash_algos[GIT_HASH_SHA1];
}

static FILE *simple_odb_open(const char *path, const char *mode,
                             struct simple_odb_header *header)
{
    FILE *f = xfopen(path, mode);

    if (strchr(mode, 'r')) {
        rewind(f);
        simple_odb_read_header(f, header);
    } else if (strchr(mode, '+')) {
        rewind(f);
        simple_odb_read_header(f, header);
        fseek(f, 0, SEEK_END);
    }

    return f;
}

static void simple_odb_encode_hex(struct strbuf *out, const void *data, size_t len)
{
    static const char hex[] = "0123456789abcdef";
    const unsigned char *bytes = data;

    strbuf_grow(out, len * 2);
    for (size_t i = 0; i < len; i++) {
        strbuf_addch(out, hex[bytes[i] >> 4]);
        strbuf_addch(out, hex[bytes[i] & 0x0f]);
    }
}

static void simple_odb_decode_hex(struct strbuf *out, const char *hex, size_t hexlen)
{
    size_t bytes;
    char *buf;

    if (hexlen % 2)
        die("invalid hex payload length");

    bytes = hexlen / 2;
    buf = xmalloc(bytes + 1);
    if (hex_to_bytes((unsigned char *)buf, hex, bytes))
        die("invalid hex payload data");
    buf[bytes] = '\0';
    strbuf_attach(out, buf, bytes, bytes + 1);
}

static int simple_odb_init(const char *path, const struct git_hash_algo *algo)
{
    FILE *f;

    if (!access(path, F_OK))
        die("simple odb '%s' already exists", path);

    f = xfopen(path, "w");
    simple_odb_write_header(f, algo);
    fclose(f);
    return 0;
}

static int simple_odb_write_entry(const char *path, enum object_type type,
                                  struct strbuf *payload, struct object_id *oid)
{
    FILE *f;
    struct simple_odb_header header;
    struct strbuf hex = STRBUF_INIT;
    char oid_hex[GIT_MAX_HEXSZ + 1];

    f = simple_odb_open(path, "a+", &header);

    hash_object_file(header.algo, payload->buf, payload->len, type, oid);
    oid_to_hex_r(oid_hex, oid);
    simple_odb_encode_hex(&hex, payload->buf, payload->len);

    fprintf(f, "%s %s %" PRIuMAX "\n", oid_hex, type_name(type), (uintmax_t)payload->len);
    fwrite(hex.buf, 1, hex.len, f);
    fputc('\n', f);

    strbuf_release(&hex);
    fclose(f);
    return 0;
}

static int simple_odb_read_entry(const char *path, const struct object_id *oid,
                                 const char *out_path)
{
    FILE *f;
    struct simple_odb_header header;
    struct strbuf line = STRBUF_INIT;
    struct strbuf data = STRBUF_INIT;
    struct object_id current;
    int found = 0;

    f = simple_odb_open(path, "r", &header);

    while (strbuf_getline_lf(&line, f) != EOF) {
        char *type_str, *size_str;
        char *endptr;
        enum object_type type;
        uintmax_t size;

        if (!line.len)
            continue;

        type_str = strchr(line.buf, ' ');
        if (!type_str)
            die("corrupt simple odb entry header");
        *type_str++ = '\0';

        size_str = strchr(type_str, ' ');
        if (!size_str)
            die("corrupt simple odb entry header");
        *size_str++ = '\0';

        if (get_oid_hex_algop(line.buf, &current, header.algo))
            die("invalid object id '%s' in simple odb", line.buf);

        type = type_from_string_gently(type_str, -1, 1);
        if (type < 0)
            die("invalid type '%s' in simple odb", type_str);

        size = strtoumax(size_str, &endptr, 10);
        if (*endptr)
            die("invalid size '%s' in simple odb", size_str);

        if (strbuf_getline_lf(&data, f) == EOF)
            die("missing payload in simple odb entry");

        if (data.len != size * 2)
            die("corrupt payload for '%s'", line.buf);

        if (!oideq(&current, oid))
            continue;

        simple_odb_decode_hex(&data, data.buf, data.len);
        found = 1;

        if (out_path) {
            int out = xopen(out_path, O_CREAT | O_TRUNC | O_WRONLY, 0666);
            if (write_in_full(out, data.buf, data.len) < 0)
                die_errno("unable to write '%s'", out_path);
            close(out);
        }

        printf("%s\n", type_name(type));
        break;
    }

    if (!found)
        die("object %s not found in simple odb", oid_to_hex(oid));

    strbuf_release(&line);
    strbuf_release(&data);
    fclose(f);
    return 0;
}

static int simple_odb_list(const char *path)
{
    FILE *f;
    struct simple_odb_header header;
    struct strbuf line = STRBUF_INIT;

    f = simple_odb_open(path, "r", &header);

    while (strbuf_getline_lf(&line, f) != EOF) {
        char *type_str;

        if (!line.len)
            continue;

        type_str = strchr(line.buf, ' ');
        if (!type_str)
            die("corrupt simple odb entry header");
        *type_str = '\0';
        printf("%s\n", line.buf);

        if (strbuf_getline_lf(&line, f) == EOF)
            break;
    }

    strbuf_release(&line);
    fclose(f);
    return 0;
}

int cmd__simple_odb(int argc, const char **argv)
{
    if (argc < 2)
        die("test-tool simple-odb <command> [args]");

    argv++;
    argc--;

    if (!strcmp(argv[0], "init")) {
        const struct git_hash_algo *algo = detect_default_algo();
        if (argc < 2 || argc > 3)
            die("usage: test-tool simple-odb init <path> [algo]");
        if (argc == 3) {
            int idx = hash_algo_by_name(argv[2]);
            if (idx < 0)
                die("unknown hash algorithm '%s'", argv[2]);
            algo = &hash_algos[idx];
        }
        simple_odb_init(argv[1], algo);
        return 0;
    } else if (!strcmp(argv[0], "write")) {
        struct strbuf payload = STRBUF_INIT;
        struct object_id oid;
        enum object_type type;
        char oid_hex[GIT_MAX_HEXSZ + 1];

        if (argc != 3)
            die("usage: test-tool simple-odb write <path> <type>");

        type = type_from_string_gently(argv[2], -1, 0);
        if (type < 0)
            die("unknown object type '%s'", argv[2]);

        if (strbuf_read(&payload, 0, 0) < 0)
            die_errno("failed to read payload");

        simple_odb_write_entry(argv[1], type, &payload, &oid);
        oid_to_hex_r(oid_hex, &oid);
        printf("%s\n", oid_hex);
        strbuf_release(&payload);
        return 0;
    } else if (!strcmp(argv[0], "read")) {
        struct object_id oid;
        if (argc != 4)
            die("usage: test-tool simple-odb read <path> <oid> <out>");
        if (get_oid_hex_any(argv[2], &oid) < 0)
            die("invalid object id '%s'", argv[2]);
        simple_odb_read_entry(argv[1], &oid, argv[3]);
        return 0;
    } else if (!strcmp(argv[0], "list")) {
        if (argc != 2)
            die("usage: test-tool simple-odb list <path>");
        simple_odb_list(argv[1]);
        return 0;
    }

    die("unknown simple-odb command '%s'", argv[0]);
}
