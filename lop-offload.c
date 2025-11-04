#include "git-compat-util.h"
#include "lop-offload.h"
#include "config.h"
#include "environment.h"
#include "hex.h"
#include "list-objects-filter-options.h"
#include "object-file.h"
#include "object.h"
#include "odb.h"
#include "oidset.h"
#include "promisor-odb.h"
#include "promisor-remote.h"
#include "repository.h"
#include "run-command.h"
#include "string-list.h"
#include "strvec.h"
#include "trace.h"
#include "trace2.h"

/*
 * Minimal definition of struct command from builtin/receive-pack.c
 * needed to iterate over pushed refs.
 */
struct command {
    struct command *next;
    const char *error_string;
    char *error_string_owned;
    void *report;
    unsigned int skip_update:1,
                 did_not_exist:1,
                 run_proc_receive:2;
    int index;
    struct object_id old_oid;
    struct object_id new_oid;
    char ref_name[FLEX_ARRAY];
};

struct lop_route_rule {
    char *remote;
    uintmax_t size_above;
    unsigned int has_size:1;
    unsigned int match_all:1;
};

struct lop_policy {
    int enabled;
    struct string_list routes;
};

static int lop_policy_initialized;
static struct lop_policy lop_policy;

static void lop_policy_init(struct lop_policy *policy)
{
    memset(policy, 0, sizeof(*policy));
    string_list_init_dup(&policy->routes);
}

static void lop_policy_ensure_init(void)
{
    if (!lop_policy_initialized) {
        lop_policy_init(&lop_policy);
        lop_policy_initialized = 1;
    }
}

static void lop_route_rule_free(void *util, const char *string UNUSED)
{
    struct lop_route_rule *rule = util;

    if (!rule)
        return;

    free(rule->remote);
    free(rule);
}

static void lop_route_rule_apply_filter(struct lop_route_rule *rule,
                                        const struct list_objects_filter_options *opts)
{
    size_t i;

    switch (opts->choice) {
    case LOFC_BLOB_NONE:
        rule->match_all = 1;
        break;
    case LOFC_BLOB_LIMIT: {
        uintmax_t limit = opts->blob_limit_value;

        if (limit >= UINTMAX_MAX)
            rule->match_all = 1;
        else {
            rule->has_size = 1;
            rule->size_above = limit;
        }
        break;
    }
    case LOFC_COMBINE:
        for (i = 0; i < opts->sub_nr; i++)
            lop_route_rule_apply_filter(rule, &opts->sub[i]);
        break;
    default:
        break;
    }
}

static void lop_route_rule_configure_from_filter(struct lop_route_rule *rule,
                                                 const char *filter)
{
    struct list_objects_filter_options opts = LIST_OBJECTS_FILTER_INIT;
    struct strbuf err = STRBUF_INIT;

    if (!filter)
        return;

    if (gently_parse_list_objects_filter(&opts, filter, &err)) {
        strbuf_release(&err);
        list_objects_filter_release(&opts);
        return;
    }

    lop_route_rule_apply_filter(rule, &opts);

    strbuf_release(&err);
    list_objects_filter_release(&opts);
}

static void lop_policy_clear_routes(struct lop_policy *policy)
{
    string_list_clear_func(&policy->routes, lop_route_rule_free);
    string_list_init_dup(&policy->routes);
}

static int lop_promisor_remote_enabled(struct repository *repo,
                                       const struct promisor_remote *remote)
{
    struct strbuf key = STRBUF_INIT;
    int enabled;
    int result = 0;

    if (!remote)
        return 0;

    strbuf_addf(&key, "remote.%s.promisor", remote->name);
    if (!repo_config_get_bool(repo, key.buf, &enabled)) {
        result = enabled;
        goto out;
    }

    if (repo->repository_format_partial_clone &&
        !strcmp(remote->name, repo->repository_format_partial_clone))
        result = 1;
out:
    strbuf_release(&key);
    return result;
}

static void lop_policy_reload_routes(struct lop_policy *policy,
                                     struct repository *repo)
{
    struct promisor_remote *remote;

    lop_policy_clear_routes(policy);

    if (!policy->enabled)
        return;

    for (remote = repo_promisor_remote_find(repo, NULL);
         remote;
         remote = remote->next) {
        struct lop_route_rule *rule;
        struct string_list_item *item;

        if (!lop_promisor_remote_enabled(repo, remote))
            continue;
        if (!remote->partial_clone_filter)
            continue;

        rule = xcalloc(1, sizeof(*rule));
        rule->remote = xstrdup(remote->name);
        lop_route_rule_configure_from_filter(rule, remote->partial_clone_filter);
        if (!rule->match_all && !rule->has_size) {
            free(rule->remote);
            free(rule);
            continue;
        }

        item = string_list_append(&policy->routes, remote->name);
        item->util = rule;
    }
}

static int lop_route_matches(const struct lop_route_rule *rule,
                             const struct lop_blob_info *blob)
{
    if (rule->match_all)
        return 1;
    if (rule->size_above && blob->size < rule->size_above)
        return 0;
    return rule->has_size;
}

static const char *lop_match_blob(const struct lop_policy *policy,
                                  const struct lop_blob_info *blob)
{
    int i;

    if (!policy->enabled)
        return NULL;
    for (i = 0; i < policy->routes.nr; i++) {
        struct lop_route_rule *rule = policy->routes.items[i].util;
        if (lop_route_matches(rule, blob))
            return rule->remote;
    }
    return NULL;
}

struct lop_offload_stats {
    uintmax_t blob_count;
    uintmax_t total_bytes;
};

struct lop_offload_ctx {
    struct lop_policy *policy;
    struct repository *repo;
    struct string_list stats;
    struct strbuf err;
    int had_error;
};

static struct lop_offload_stats *lop_stats_get(struct string_list *list,
                                               const char *remote)
{
    struct string_list_item *item;

    item = string_list_lookup(list, remote);
    if (!item)
        item = string_list_insert(list, remote);
    if (!item->util)
        item->util = xcalloc(1, sizeof(struct lop_offload_stats));
    return item->util;
}

static void lop_stats_clear(struct string_list *list)
{
    size_t i;

    for (i = 0; i < list->nr; i++)
        free(list->items[i].util);
    string_list_clear(list, 0);
}

static int lop_remove_local_blob(struct repository *repo,
                                 const struct object_id *oid,
                                 struct strbuf *err)
{
    struct odb_source *source;
    int force_error = git_env_bool("GIT_TEST_LOP_FORCE_REMOVE_ERROR", 0);
    int force_dir_warn = git_env_bool("GIT_TEST_LOP_FORCE_REMOVE_DIR_WARN", 0);

    if (git_env_bool("GIT_TEST_LOP_FORCE_REMOVE_FAIL", 0)) {
        if (err)
            strbuf_addf(err, "failed to remove blob %s from local store",
                        oid_to_hex(oid));
        return -1;
    }

    for (source = repo->objects->sources; source; source = source->next) {
        struct strbuf path = STRBUF_INIT;
        const char *loose_path;

        if (!source->local)
            continue;

        loose_path = odb_loose_path(source, &path, oid);
        if (!loose_path) {
            strbuf_release(&path);
            continue;
        }

        int remove_result;

        if (force_error) {
            errno = EACCES;
            remove_result = -1;
        } else {
            remove_result = unlink(loose_path);
        }

        if (!remove_result) {
            const char *slash;
            struct strbuf dir = STRBUF_INIT;

            odb_clear_loose_cache(source);

            slash = strrchr(loose_path, '/');
            if (slash) {
                strbuf_add(&dir, loose_path, slash - loose_path);
                if (force_dir_warn) {
                    errno = EPERM;
                    warning_errno("failed to remove directory '%s'", dir.buf);
                } else if (rmdir(dir.buf) && errno != ENOENT && errno != ENOTEMPTY)
                    warning_errno("failed to remove directory '%s'", dir.buf);
                strbuf_release(&dir);
            }
        } else if (errno != ENOENT || force_error) {
            if (err)
                strbuf_addf(err, "failed to remove blob %s from local store: %s",
                            oid_to_hex(oid), strerror(errno));
            strbuf_release(&path);
            return -1;
        }

        strbuf_release(&path);
    }

    return 0;
}

static int lop_record_blob(struct lop_offload_ctx *ctx,
                           const struct lop_blob_info *blob,
                           const char *remote,
                           size_t size)
{
    struct lop_offload_stats *stats;

    stats = lop_stats_get(&ctx->stats, remote);
    stats->blob_count++;
    stats->total_bytes += size;

    if (blob->path)
        trace2_data_string("lop/match", ctx->repo, "path", blob->path);
    trace2_data_string("lop/match", ctx->repo, "remote", remote);
    trace2_data_intmax("lop/match", ctx->repo, "size", size);
    return 0;
}

int lop_receive_pack_config(const char *var, const char *value)
{
    if (!strcmp(var, "receive.lop.enable")) {
        lop_policy_ensure_init();
        lop_policy.enabled = git_config_bool(var, value);
        return 0;
    }

    return 1;
}

struct lop_offload_ctx *lop_offload_start(struct repository *repo)
{
    struct lop_offload_ctx *ctx;

    lop_policy_ensure_init();
    if (!lop_policy.enabled)
        return NULL;

    lop_policy_reload_routes(&lop_policy, repo);
    if (!lop_policy.routes.nr)
        return NULL;

    ctx = xcalloc(1, sizeof(*ctx));
    ctx->policy = &lop_policy;
    ctx->repo = repo;
    string_list_init_dup(&ctx->stats);
    strbuf_init(&ctx->err, 0);
    return ctx;
}

int lop_offload_blob_cb(const struct lop_blob_info *blob, void *data)
{
    struct lop_offload_ctx *ctx = data;
    const char *remote_name;
    struct lop_odb *odb;
    struct object_info oi = OBJECT_INFO_INIT;
    enum object_type type;
    unsigned long size = 0;
    char *buffer = NULL;
    struct strbuf err = STRBUF_INIT;

    remote_name = lop_match_blob(ctx->policy, blob);
    if (!remote_name)
        return 0;

    if (git_env_bool("GIT_TEST_LOP_FORCE_READ_FAIL", 0)) {
        strbuf_addf(&ctx->err, "unable to read blob %s", oid_to_hex(&blob->oid));
        ctx->had_error = 1;
        goto fail;
    }

    oi.typep = &type;
    oi.sizep = &size;
    oi.contentp = (void **)&buffer;
    if (odb_read_object_info_extended(ctx->repo->objects, &blob->oid, &oi,
                                      OBJECT_INFO_LOOKUP_REPLACE |
                                      OBJECT_INFO_DIE_IF_CORRUPT)) {
        strbuf_addf(&ctx->err, "unable to read blob %s",
                    oid_to_hex(&blob->oid));
        ctx->had_error = 1;
        goto fail;
    }

    if (git_env_bool("GIT_TEST_LOP_FORCE_NON_BLOB", 0))
        type = OBJ_TREE;

    if (type != OBJ_BLOB)
        goto out;

    odb = lop_odb_get(remote_name, &err);
    if (!odb) {
        strbuf_addbuf(&ctx->err, &err);
        ctx->had_error = 1;
        goto fail;
    }

    if (lop_odb_write_blob(odb, &blob->oid, buffer, size, &err)) {
        strbuf_addbuf(&ctx->err, &err);
        ctx->had_error = 1;
        goto fail;
    }

    if (lop_remove_local_blob(ctx->repo, &blob->oid, &ctx->err)) {
        ctx->had_error = 1;
        goto fail;
    }

    lop_record_blob(ctx, blob, remote_name, size);

out:
    free(buffer);
    strbuf_release(&err);
    return 0;
fail:
    free(buffer);
    strbuf_release(&err);
    return -1;
}

int lop_offload_had_error(const struct lop_offload_ctx *ctx)
{
    return ctx->had_error;
}

const struct strbuf *lop_offload_error(const struct lop_offload_ctx *ctx)
{
    return &ctx->err;
}

void lop_offload_finish(struct lop_offload_ctx *ctx)
{
    size_t i;

    for (i = 0; i < ctx->stats.nr; i++) {
        struct lop_offload_stats *stats = ctx->stats.items[i].util;
        trace2_data_string("lop/offload", ctx->repo, "remote",
                           ctx->stats.items[i].string);
        trace2_data_intmax("lop/offload", ctx->repo, "blob-count",
                           stats->blob_count);
        trace2_data_intmax("lop/offload", ctx->repo, "total-bytes",
                           stats->total_bytes);
    }

    lop_stats_clear(&ctx->stats);
    strbuf_release(&ctx->err);
    free(ctx);
}

void lop_offload_abort(struct lop_offload_ctx *ctx)
{
    lop_stats_clear(&ctx->stats);
    strbuf_release(&ctx->err);
    free(ctx);
}

static int lop_for_each_new_blob(struct repository *repo,
                                 struct command *commands,
                                 int (*cb)(const struct lop_blob_info *, void *),
                                 void *data)
{
    struct command *cmd;
    struct oidset seen = OIDSET_INIT;
    struct strbuf line = STRBUF_INIT;

    for (cmd = commands; cmd; cmd = cmd->next) {
        struct child_process cp = CHILD_PROCESS_INIT;
        struct strbuf range = STRBUF_INIT;
        FILE *out;

        if (cmd->skip_update)
            continue;
        if (is_null_oid(&cmd->new_oid))
            continue;

        cp.git_cmd = 1;
        cp.out = -1;
        strvec_push(&cp.args, "rev-list");
        strvec_push(&cp.args, "--objects");
        if (!is_null_oid(&cmd->old_oid)) {
            strbuf_addf(&range, "%s..%s", oid_to_hex(&cmd->old_oid),
                        oid_to_hex(&cmd->new_oid));
            strvec_push(&cp.args, range.buf);
        } else {
            strvec_push(&cp.args, oid_to_hex(&cmd->new_oid));
        }

        if (start_command(&cp)) {
            strbuf_release(&range);
            strbuf_release(&line);
            oidset_clear(&seen);
            return -1;
        }

        out = xfdopen(cp.out, "r");
        while (strbuf_getline_lf(&line, out) != EOF) {
            struct lop_blob_info info;
            char *sep;
            struct object_info oi = OBJECT_INFO_INIT;
            enum object_type type;
            unsigned long size = 0;

            if (!line.len)
                continue;
            sep = strchr(line.buf, ' ');
            if (sep)
                *sep = '\0';
            if (get_oid_hex_algop(line.buf, &info.oid, repo->hash_algo))
                continue;
            if (oidset_insert(&seen, &info.oid))
                continue;

            oi.typep = &type;
            oi.sizep = &size;
            if (odb_read_object_info_extended(repo->objects,
                                              &info.oid, &oi,
                                              OBJECT_INFO_LOOKUP_REPLACE |
                                              OBJECT_INFO_DIE_IF_CORRUPT))
                continue;
            if (type != OBJ_BLOB)
                continue;

            info.size = size;
            info.path = sep ? sep + 1 : NULL;
            if (cb(&info, data)) {
                fclose(out);
                finish_command(&cp);
                strbuf_release(&range);
                strbuf_release(&line);
                oidset_clear(&seen);
                return -1;
            }
        }

        fclose(out);
        finish_command(&cp);
        strbuf_release(&range);
    }

    strbuf_release(&line);
    oidset_clear(&seen);
    return 0;
}

void lop_process_push(struct repository *repo, struct command *commands)
{
    struct lop_offload_ctx *ctx;

    ctx = lop_offload_start(repo);
    if (!ctx)
        return;

    if (lop_for_each_new_blob(repo, commands, lop_offload_blob_cb, ctx) ||
        lop_offload_had_error(ctx)) {
        struct strbuf msg = STRBUF_INIT;
        const struct strbuf *err = lop_offload_error(ctx);

        if (err && err->len)
            strbuf_addbuf(&msg, err);
        else
            strbuf_addstr(&msg, "lop offload failed");

        lop_offload_abort(ctx);
        die("%s", msg.buf);
    }

    lop_offload_finish(ctx);
}
