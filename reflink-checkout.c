/*
 * Copy-on-write acceleration for checkout: materialize blobs by cloning
 * the files of a "donor" worktree of the same repository instead of
 * writing them out from the object database.  See reflink-checkout.h.
 *
 * The tree being checked out decides what exists; the donor only speeds
 * up delivering the bytes.  Every cloned file is re-hashed against the
 * object id it stands for before it is trusted, so the donor-side
 * checks below are optimizations that avoid wasted clones, not what
 * correctness rests on.
 */
#include "git-compat-util.h"
#include "abspath.h"
#include "convert.h"
#include "copy.h"
#include "entry.h"
#include "environment.h"
#include "hash.h"
#include "lockfile.h"
#include "object-file.h"
#include "oidmap.h"
#include "read-cache-ll.h"
#include "reflink-checkout.h"
#include "repository.h"
#include "statinfo.h"
#include "strbuf.h"
#include "tempfile.h"
#include "trace2.h"
#include "worktree.h"

/*
 * How many donor files to try cloning before giving up on getting a
 * verdict from them: enough to get past a few odd files (unreadable,
 * being written to) without walking a large index.
 */
#define REFLINK_PROBE_SAMPLES 8

/*
 * How many clone attempts may fail in a row, none having succeeded
 * yet, before the checkout stops trying: a filesystem that refuses
 * clone after clone is not going to start accepting them, and every
 * attempt costs several system calls.
 */
#define REFLINK_MAX_FRUITLESS 16

struct donor_entry {
	struct oidmap_entry entry;	/* key: the blob's object id */
	const struct cache_entry *ce;	/* the donor's entry for it */
};

struct reflink_donor_map {
	struct oidmap map;
	struct index_state donor_index;
	struct repository *repo;
	char *donor_root;
	/* set once clone attempts have proven fruitless */
	unsigned disabled:1;
	/* a filesystem's refusal to clone is an error, not a fallback */
	unsigned required:1;
	struct {
		uintmax_t eligible;
		uintmax_t skipped_other; /* unmerged, skip-worktree, not a file */
		uintmax_t skipped_dirty;
		uintmax_t cloned;
		uintmax_t cloned_bytes;
		uintmax_t fallback_no_donor;
		uintmax_t fallback_conversion;
		uintmax_t fallback_clone_fail;
		uintmax_t fallback_verify_fail;
	} n;
};

/*
 * Is "ce" the kind of donor index entry whose file could be cloned?
 * Only stage-0 regular files that are supposed to be present qualify;
 * unmerged entries, symbolic links, gitlinks, skip-worktree entries,
 * the directory entries of a sparse index (nothing behind them is on
 * disk) and intent-to-add entries (whose object id is the empty blob's
 * whatever the file holds) do not.
 */
static int donor_entry_eligible(const struct cache_entry *ce)
{
	return !ce_stage(ce) && S_ISREG(ce->ce_mode) &&
	       !ce_skip_worktree(ce) && !ce_intent_to_add(ce);
}

/*
 * Does the donor's file for "ce" still look like what the donor's index
 * recorded?  On success, "path" holds the file's full path and "st" its
 * stat data.
 *
 * This is the comparison the index itself uses to decide whether a file
 * must be re-hashed, deliberately without the racy-timestamp
 * refinement: a racily clean entry is admitted, because a clone made
 * from it is re-hashed anyway and rejected if its content differs.
 * (When the donor's index was refreshed and written just before, a
 * racily clean entry whose content had changed has had its stat data
 * smudged and fails here already.)  The assume-unchanged and fsmonitor
 * validity bits are not consulted either: the stat data is compared
 * for real.
 */
static int donor_file_clean(const struct cache_entry *ce, const char *root,
			    struct strbuf *path, struct stat *st)
{
	strbuf_reset(path);
	strbuf_addf(path, "%s/%s", root, ce->name);
	return !lstat(path->buf, st) && S_ISREG(st->st_mode) &&
	       !match_stat_data(&ce->ce_stat_data, st);
}

/*
 * do_read_index() dies on an index it cannot make sense of, which is
 * right for the index a command operates on but not for the donor's:
 * that one belongs to another worktree and is merely an optimization
 * here.  Look at the header first, so that a truncated or overwritten
 * file turns into "no acceleration" instead of a fatal error.  (Damage
 * deeper inside a well-formed header is as fatal as it is for any
 * command run in the donor itself.)  A missing index is fine: nothing
 * to clone from.
 */
static int index_file_usable(const char *path, const struct git_hash_algo *algo)
{
	struct cache_header hdr;
	struct stat st;
	int fd, ok;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return errno == ENOENT;
	ok = !fstat(fd, &st) &&
	     st.st_size >= (off_t)(sizeof(hdr) + algo->rawsz) &&
	     read_in_full(fd, &hdr, sizeof(hdr)) == sizeof(hdr) &&
	     hdr.hdr_signature == htonl(CACHE_SIGNATURE) &&
	     ntohl(hdr.hdr_version) >= INDEX_FORMAT_LB &&
	     ntohl(hdr.hdr_version) <= INDEX_FORMAT_UB;
	close(fd);
	return ok;
}

/*
 * Does this errno from reflink_file() say that the filesystem cannot
 * clone at all, as opposed to something being wrong with one file?
 */
static int errno_means_unsupported(int err)
{
	return err == EOPNOTSUPP || err == ENOTSUP || err == ENOTTY ||
	       err == EXDEV || err == ENOSYS;
}

/*
 * Clone "src" to "dst", which must not exist, and remove the clone
 * again.  Returns 1 on success, 0 if errno says the filesystem cannot
 * clone, and -1 if the failure says nothing about clone support (an
 * unreadable "src", say).  "own_source" says that "src" is a temporary
 * of ours next to "dst", in which case EINVAL cannot be about a
 * mismatch between the two files and is a verdict as well.
 */
static int probe_clone(const char *dst, const char *src, int own_source)
{
	int ret;

	if (!reflink_file(dst, src, 0600))
		ret = 1;
	else if (errno_means_unsupported(errno) ||
		 (own_source && errno == EINVAL))
		ret = 0;
	else
		ret = -1;
	unlink(dst);
	return ret;
}

/*
 * The nearest existing ancestor of "path", or "path" itself.  That is
 * where mkdir() will grow the new working tree from, hence on the same
 * filesystem as it.  The caller frees the result.
 */
static char *nearest_existing_dir(const char *path)
{
	char *dir = xstrdup(path);

	while (!is_directory(dir)) {
		char *copy = xstrdup(dir);
		char *parent = xstrdup(dirname(copy));

		free(copy);
		if (!strcmp(parent, dir)) {
			/* nothing above exists; let mkdir() complain later */
			free(parent);
			break;
		}
		free(dir);
		dir = parent;
	}
	return dir;
}

/*
 * Bring the donor's index up to date with its working tree the way
 * "git status" does: opportunistically, skipping it when another
 * process holds the index lock or when GIT_OPTIONAL_LOCKS says not to
 * take one, and writing the index back only when that is worthwhile.
 * Without this, a donor whose index carries stale
 * or no stat data (after "git read-tree", say) would contribute nothing
 * until its owner's next "git status".
 *
 * refresh_index() looks files up relative to the current directory,
 * and "git worktree add" only guarantees to be at the donor's top
 * level when it was started inside the donor (RUN_SETUP moves it
 * there); with GIT_DIR/GIT_WORK_TREE pointing elsewhere we may be in
 * an unrelated directory, and then we leave the index alone.
 */
static void refresh_donor_index(struct repository *donor, const char *root)
{
	struct lock_file lock = LOCK_INIT;
	struct strbuf cwd = STRBUF_INIT;
	int at_root;

	at_root = !strbuf_getcwd(&cwd) && !strcmp(cwd.buf, root);
	strbuf_release(&cwd);
	if (!at_root) {
		trace2_data_string("reflink", donor, "donor/refresh",
				   "skipped-cwd");
		return;
	}
	if (!use_optional_locks()) {
		trace2_data_string("reflink", donor, "donor/refresh",
				   "skipped-optional-locks");
		return;
	}
	if (repo_hold_locked_index(donor, &lock, 0) < 0) {
		trace2_data_string("reflink", donor, "donor/refresh",
				   "skipped-locked");
		return;
	}
	repo_read_index(donor);
	refresh_index(donor->index, REFRESH_QUIET | REFRESH_UNMERGED,
		      NULL, NULL, NULL);
	repo_update_index_if_able(donor, &lock);
}

int reflink_prepare_donor(struct repository *donor, const char *path)
{
	const char *root = repo_get_work_tree(donor);
	struct strbuf buf = STRBUF_INIT;
	struct tempfile *tmp;
	struct index_state *istate;
	char *dir, *dst;
	int ret = -1, sampled = -1, tried = 0;
	unsigned int i;

	if (!root)
		BUG("reflink_prepare_donor() needs a donor with a working tree");

	/*
	 * One temporary file of ours where the new working tree will be
	 * created (or in the nearest existing ancestor, which is on the
	 * same filesystem): it is the source of the first probe clone,
	 * and its unique name, with a suffix, is where every probe clone
	 * goes.  The tempfile machinery removes it should we die; a
	 * clone exists only between reflink_file() and the unlink() that
	 * follows it.
	 */
	dir = nearest_existing_dir(path);
	strbuf_addf(&buf, "%s/.git-reflink-probe-XXXXXX", dir);
	free(dir);
	tmp = mks_tempfile_sm(buf.buf, 0, 0600);
	if (!tmp) {
		strbuf_release(&buf);
		return -1;
	}
	dst = xstrfmt("%s.clone", get_tempfile_path(tmp));

	/*
	 * First the cheap question: does the destination filesystem
	 * clone at all?  A "no" here is final and spares the donor any
	 * work, which matters on filesystems without clone support; it
	 * also gives "always" a verdict for a donor with nothing to
	 * sample.
	 */
	if (write_in_full(get_tempfile_fd(tmp), "x", 1) == 1 &&
	    !close_tempfile_gently(tmp))
		ret = probe_clone(dst, get_tempfile_path(tmp), 1);
	if (!ret || !index_file_usable(donor->index_file, donor->hash_algo))
		goto out;

	refresh_donor_index(donor, root);

	/*
	 * Then the real one: clone an actual donor file, so that a donor
	 * and a destination that cannot clone between each other
	 * (different filesystems, or the same one behind two mounts) are
	 * answered by the very system call the checkout is going to
	 * make.  A donor with nothing to sample keeps the answer above.
	 */
	repo_read_index(donor);
	istate = donor->index;
	for (i = 0;
	     sampled < 0 && tried < REFLINK_PROBE_SAMPLES && i < istate->cache_nr;
	     i++) {
		const struct cache_entry *ce = istate->cache[i];
		struct stat st;

		if (!donor_entry_eligible(ce) ||
		    !donor_file_clean(ce, root, &buf, &st) || !st.st_size)
			continue;
		tried++;
		sampled = probe_clone(dst, buf.buf, 0);
	}
	if (sampled >= 0)
		ret = sampled;

out:
	delete_tempfile(&tmp);
	free(dst);
	strbuf_release(&buf);
	return ret;
}

static const struct cache_entry *donor_lookup(struct reflink_donor_map *m,
					      const struct object_id *oid)
{
	struct donor_entry *e = oidmap_get(&m->map, oid);

	return e ? e->ce : NULL;
}

static void donor_insert(struct reflink_donor_map *m,
			 const struct cache_entry *ce)
{
	struct donor_entry *e;

	/*
	 * The first entry per object id wins.  When several donor
	 * paths share a blob this only decides which of several
	 * equally good sources is cloned.
	 */
	if (oidmap_get(&m->map, &ce->oid))
		return;
	CALLOC_ARRAY(e, 1);
	oidcpy(&e->entry.oid, &ce->oid);
	e->ce = ce;
	oidmap_put(&m->map, e);
}

struct reflink_donor_map *reflink_donor_map_load(struct repository *r,
						 const char *donor,
						 int required)
{
	struct reflink_donor_map *m;
	struct worktree **worktrees, *wt;
	struct strbuf buf = STRBUF_INIT;
	char *donor_root, *donor_gitdir;
	unsigned int i;

	if (!donor || !*donor)
		return NULL;

	/*
	 * The donor must be a worktree of this very repository: its
	 * index is what tells us which of its files stand for which
	 * blobs.
	 */
	worktrees = get_worktrees(r);
	wt = find_worktree_by_path(worktrees, donor);
	if (!wt) {
		free_worktrees(worktrees);
		return NULL;
	}
	donor_root = xstrdup(wt->path);
	donor_gitdir = get_worktree_git_dir(wt);
	free_worktrees(worktrees);

	strbuf_addf(&buf, "%s/index", donor_gitdir);
	if (!index_file_usable(buf.buf, r->hash_algo)) {
		free(donor_gitdir);
		free(donor_root);
		strbuf_release(&buf);
		return NULL;
	}

	CALLOC_ARRAY(m, 1);
	oidmap_init(&m->map, 0);
	m->repo = r;
	m->donor_root = donor_root;
	m->required = !!required;
	index_state_init(&m->donor_index, r);
	read_index_from(&m->donor_index, buf.buf, donor_gitdir);
	free(donor_gitdir);
	strbuf_release(&buf);

	/*
	 * Whether a file is still what the donor's index says is
	 * checked when it is wanted (see reflink_try_checkout_entry()),
	 * not here for every donor entry: the tree being checked out
	 * may share little with the donor.
	 */
	for (i = 0; i < m->donor_index.cache_nr; i++) {
		const struct cache_entry *ce = m->donor_index.cache[i];

		if (!donor_entry_eligible(ce)) {
			m->n.skipped_other++;
			continue;
		}
		donor_insert(m, ce);
		m->n.eligible++;
	}
	return m;
}

/*
 * Cloning donor bytes is only correct when checking this entry out
 * would write the blob verbatim.  Ask the conversion machinery, and
 * accept nothing but the null stream filter: any smudge filter, ident
 * expansion, working-tree encoding or CRLF on checkout means the bytes
 * on disk would differ from the blob.  (This is stricter than the test
 * write_entry() applies to decide whether it can stream a blob, which
 * admits the ident and LF-to-CRLF filters.)
 */
static int checkout_is_identity(const struct checkout *state,
				const struct cache_entry *ce)
{
	struct conv_attrs ca;
	struct stream_filter *filter;
	int ret;

	convert_attrs(state->istate, &ca, ce->name);
	filter = get_stream_filter_ca(&ca, &ce->oid);
	ret = filter && is_null_stream_filter(filter);
	if (filter)
		free_stream_filter(filter);
	return ret;
}

/*
 * The proof that a clone is what we wanted: hash the file we now own
 * and compare with the object id the entry asked for.
 */
static int clone_matches_oid(struct repository *r, int fd,
			     const struct stat *st,
			     const struct object_id *expect)
{
	struct object_id got;
	size_t len = (size_t)st->st_size;
	void *buf = NULL;

	if ((off_t)len != st->st_size)
		return 0; /* too large to map here: cannot verify, do not trust */
	if (len) {
		buf = xmmap_gently(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
		if (buf == MAP_FAILED)
			return 0; /* cannot verify, so do not trust */
	}
	hash_object_file(r->hash_algo, buf ? buf : "", len, OBJ_BLOB, &got);
	if (buf)
		munmap(buf, len);
	return oideq(&got, expect);
}

int reflink_try_checkout_entry(const struct checkout *state,
			       struct cache_entry *ce,
			       struct reflink_donor_map *m)
{
	struct strbuf dst = STRBUF_INIT, src = STRBUF_INIT;
	const struct cache_entry *donor_ce;
	struct stat st;
	int mode, fd, ret = 0;

	/*
	 * Only a regular file that is to be created anew is ours to
	 * clone; anything already at the path (see the EEXIST fallback
	 * below) and a checkout that must not create files are for
	 * checkout_entry() to sort out.
	 */
	if (!m || m->disabled || state->not_new || !S_ISREG(ce->ce_mode))
		return 0;

	donor_ce = donor_lookup(m, &ce->oid);
	if (!donor_ce) {
		m->n.fallback_no_donor++;
		return 0;
	}
	if (!checkout_is_identity(state, ce)) {
		m->n.fallback_conversion++;
		return 0;
	}
	if (!donor_file_clean(donor_ce, m->donor_root, &src, &st)) {
		m->n.skipped_dirty++;
		goto out;
	}

	strbuf_add(&dst, state->base_dir, state->base_dir_len);
	strbuf_add(&dst, ce->name, ce_namelen(ce));

	/*
	 * Whatever already sits at "dst" (a modified file under
	 * "reset --hard", say) belongs to checkout_entry(), which knows
	 * how to replace it; do not count it as a failed clone.
	 */
	if (!lstat(dst.buf, &st))
		goto out;

	/*
	 * The same leading-directory logic as checkout_entry(), so that
	 * a symbolic link or a file in the way is treated the same way
	 * (replaced, under state->force) and a clone is never written
	 * through a link.
	 */
	create_directories(dst.buf, dst.len, state);

	mode = (ce->ce_mode & 0100) ? 0777 : 0666;
	if (reflink_file(dst.buf, src.buf, mode)) {
		int err = errno;

		m->n.fallback_clone_fail++;
		/*
		 * Under "always", a filesystem that refuses to clone
		 * this file when the probe said it could (a mount point
		 * inside the donor, say) is what the user asked to be
		 * told about, rather than get a slower checkout.
		 */
		if (m->required && errno_means_unsupported(err)) {
			error(_("reflink is set to 'always' but '%s' cannot "
				"be cloned from '%s': %s"),
			      dst.buf, src.buf, strerror(err));
			m->disabled = 1;
			ret = -1;
			goto out;
		}
		/*
		 * Other failures are specific to one file (an unreadable
		 * donor file, EINVAL from mismatched per-file
		 * attributes, EEXIST from something racing us), but when
		 * nothing has succeeded after a fair number of them we
		 * stop paying for attempts that are evidently going
		 * nowhere.
		 */
		if (!m->n.cloned &&
		    m->n.fallback_clone_fail >= REFLINK_MAX_FRUITLESS) {
			m->disabled = 1;
			trace2_data_string("reflink", m->repo, "disabled",
					   "no-success");
		}
		goto out;
	}

	fd = open_nofollow(dst.buf, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) ||
	    !clone_matches_oid(m->repo, fd, &st, &ce->oid)) {
		if (fd >= 0)
			close(fd);
		unlink(dst.buf);
		m->n.fallback_verify_fail++;
		goto out;
	}
	close(fd);

	update_ce_after_write(state, ce, &st);
	m->n.cloned++;
	m->n.cloned_bytes += st.st_size;
	ret = 1;
out:
	strbuf_release(&dst);
	strbuf_release(&src);
	return ret;
}

void reflink_donor_map_free(struct reflink_donor_map *m)
{
	struct repository *r;

	if (!m)
		return;
	r = m->repo;
	trace2_data_intmax("reflink", r, "donor/eligible", m->n.eligible);
	trace2_data_intmax("reflink", r, "cloned", m->n.cloned);
	trace2_data_intmax("reflink", r, "cloned_bytes", m->n.cloned_bytes);
	trace2_data_intmax("reflink", r, "fallback/no_donor",
			   m->n.fallback_no_donor);
	trace2_data_intmax("reflink", r, "fallback/conversion",
			   m->n.fallback_conversion);
	trace2_data_intmax("reflink", r, "fallback/clone_fail",
			   m->n.fallback_clone_fail);
	trace2_data_intmax("reflink", r, "fallback/verify_fail",
			   m->n.fallback_verify_fail);
	trace2_data_intmax("reflink", r, "donor/skipped_dirty",
			   m->n.skipped_dirty);
	trace2_data_intmax("reflink", r, "donor/skipped_other",
			   m->n.skipped_other);
	oidmap_clear(&m->map, 1);
	release_index(&m->donor_index);
	free(m->donor_root);
	free(m);
}
