#define USE_THE_REPOSITORY_VARIABLE
#include "git-compat-util.h"
#include "promisor-odb.h"
#include "object-file.h"
#include "odb.h"
#include "path.h"
#include "environment.h"
#include "abspath.h"
#include "remote.h"
#include "repository.h"
#include "strbuf.h"
#include "transport.h"
#include "url.h"
#include "parse.h"

struct lop_odb {
    struct lop_odb *next;
    char *name;
    char *gitdir;
    struct repository repo;
    int repo_ready;
};

static struct lop_odb *lop_odb_cache;

static int lop_odb_prepare_repo(struct lop_odb *entry, struct strbuf *err)
{
    if (entry->repo_ready)
        return 0;

    if (repo_init(&entry->repo, entry->gitdir, NULL)) {
        strbuf_addf(err, "unable to open LOP repository '%s'", entry->gitdir);
        return -1;
    }

    entry->repo_ready = 1;
    return 0;
}

static int lop_parse_file_url(const char *url, struct strbuf *out)
{
    const char *rest;

    if (skip_prefix(url, "file://", &rest)) {
        strbuf_addstr(out, rest);
        return 0;
    }
    if (skip_prefix(url, "file:", &rest)) {
        if (*rest == '/')
            strbuf_addstr(out, rest);
        else
            return -1;
        return 0;
    }
    if (is_absolute_path(url)) {
        strbuf_addstr(out, url);
        return 0;
    }
    if (!is_url(url)) {
        strbuf_addstr(out, url);
        return 0;
    }
    return -1;
}

static struct lop_odb *lop_odb_create(const char *remote_name, struct strbuf *err)
{
    struct remote *remote;
    struct lop_odb *entry;
    struct strbuf gitdir = STRBUF_INIT;

    remote = remote_get(remote_name);
    if (!remote || !remote->url.nr) {
        strbuf_addf(err, "unknown LOP remote '%s'", remote_name);
        return NULL;
    }

    if (lop_parse_file_url(remote->url.v[0], &gitdir)) {
        strbuf_addf(err, "lop remote '%s' must use a local file:// URL", remote_name);
        strbuf_release(&gitdir);
        return NULL;
    }

    entry = xcalloc(1, sizeof(*entry));
    entry->name = xstrdup(remote_name);
    entry->gitdir = strbuf_detach(&gitdir, NULL);
    entry->next = lop_odb_cache;
    lop_odb_cache = entry;
    return entry;
}

struct lop_odb *lop_odb_get(const char *remote_name, struct strbuf *err)
{
    struct lop_odb *cur;

    for (cur = lop_odb_cache; cur; cur = cur->next)
        if (!strcmp(cur->name, remote_name))
            break;

    if (!cur) {
        cur = lop_odb_create(remote_name, err);
        if (!cur)
            return NULL;
    }

    if (lop_odb_prepare_repo(cur, err))
        return NULL;

    return cur;
}

static int lop_odb_prepare_source(struct lop_odb *entry, const struct object_id *oid,
                                  struct odb_source **source, struct strbuf *err)
{
    if (!entry) {
        strbuf_addstr(err, "internal error: missing LOP entry");
        return -1;
    }

    if (!entry->repo_ready) {
        if (lop_odb_prepare_repo(entry, err))
            return -1;
    }

    if (entry->repo.hash_algo != the_repository->hash_algo) {
        strbuf_addf(err, "lop remote '%s' uses incompatible hash algorithm", entry->name);
        return -1;
    }

    if (odb_has_object(entry->repo.objects, oid, 0))
        return 1;

    if (git_env_bool("GIT_TEST_LOP_FORCE_READONLY", 0)) {
        strbuf_addf(err, "lop remote '%s' does not have a writable object store", entry->name);
        return -1;
    }

    *source = entry->repo.objects->sources;
    if (!*source || !(*source)->local) {
        strbuf_addf(err, "lop remote '%s' does not have a writable object store", entry->name);
        return -1;
    }

    return 0;
}

int lop_odb_write_blob(struct lop_odb *entry, const struct object_id *oid,
                       const void *data, size_t size, struct strbuf *err)
{
    struct object_id written;
    struct odb_source *source = NULL;
    int status;

    status = lop_odb_prepare_source(entry, oid, &source, err);
    if (status)
        return status;

    if (write_object_file(source, data, size, OBJ_BLOB, &written, NULL, 0)) {
        strbuf_addf(err, "failed to write blob to '%s'", entry->name);
        return -1;
    }

    if (!oideq(&written, oid)) {
        strbuf_addf(err, "lop remote '%s' stored blob with unexpected id", entry->name);
        return -1;
    }

    return 0;
}
