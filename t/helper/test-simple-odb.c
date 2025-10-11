#define USE_THE_REPOSITORY_VARIABLE
#include "test-tool.h"
#include "odb.h"
#include "repository.h"
#include "setup.h"
#include "simple-odb.h"
#include "strbuf.h"
#include "hex.h"

static void simple_odb_usage(const char *arg0)
{
        die("usage: %s <command> [<args>...]\n"
            "\n"
            "Commands:\n"
            "    init <path>\n"
            "    write <path> <type> <file|- >\n"
            "    add-alternate <path>\n", arg0);
}

static int cmd_simple_init(const char *path)
{
        struct simple_odb odb;

        simple_odb_init(&odb);
        if (simple_odb_prepare(&odb, path)) {
                simple_odb_release(&odb);
                return 1;
        }
        simple_odb_release(&odb);
        return 0;
}

static int cmd_simple_write(const char *path, const char *type_name, const char *file)
{
        struct simple_odb odb;
        struct strbuf data = STRBUF_INIT;
        struct object_id oid;
        enum object_type type;
        int ret = 0;

        type = type_from_string_gently(type_name, strlen(type_name), 1);
        if (type < 0)
                return error("unknown type '%s'", type_name);

        if (!strcmp(file, "-")) {
                if (strbuf_read(&data, 0, 0) < 0)
                        return error_errno("unable to read from stdin");
        } else if (strbuf_read_file(&data, file, 0) < 0) {
                return error_errno("unable to read '%s'", file);
        }

        simple_odb_init(&odb);
        if (simple_odb_prepare(&odb, path)) {
                ret = 1;
                goto out_release;
        }

        if (simple_odb_store_buffer(&odb, type, data.buf, data.len, &oid)) {
                ret = 1;
                goto out_release;
        }

        printf("%s\n", oid_to_hex(&oid));

out_release:
        simple_odb_release(&odb);
        strbuf_release(&data);
        return ret;
}

static int cmd_simple_attach(const char *path)
{
        struct simple_odb odb;

        if (!the_repository)
                return error("simple-odb: repository not set");

        simple_odb_init(&odb);
        if (simple_odb_prepare(&odb, path)) {
                simple_odb_release(&odb);
                return 1;
        }

        odb_add_to_alternates_file(the_repository->objects, odb.objects_dir.buf);
        simple_odb_release(&odb);
        return 0;
}

int cmd__simple_odb(int argc, const char **argv)
{
        setup_git_directory();

        if (argc < 2)
                simple_odb_usage(argv[0]);

        if (!strcmp(argv[1], "init")) {
                if (argc != 3)
                        simple_odb_usage(argv[0]);
                return cmd_simple_init(argv[2]);
        }
        if (!strcmp(argv[1], "write")) {
                if (argc != 5)
                        simple_odb_usage(argv[0]);
                return cmd_simple_write(argv[2], argv[3], argv[4]);
        }
        if (!strcmp(argv[1], "add-alternate")) {
                if (argc != 3)
                        simple_odb_usage(argv[0]);
                return cmd_simple_attach(argv[2]);
        }

        simple_odb_usage(argv[0]);
        return 1;
}
