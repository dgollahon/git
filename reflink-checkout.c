/*
 * Copy-on-write acceleration for checkout: materialize blobs by cloning
 * the files of a "donor" worktree of the same repository instead of
 * writing them out from the object database.  See reflink-checkout.h.
 *
 * The tree being checked out decides what exists; the donor only speeds
 * up delivering the bytes.  A donor file is believed to hold the blob
 * its index entry names on the same terms "git status" believes it:
 * when its stat data matches the entry and the entry is not racily
 * clean.  A racily clean entry is admitted too, but its clone is
 * re-hashed before it is used.
 */
#include "git-compat-util.h"
#include "convert.h"
#include "copy.h"
#include "entry.h"
#include "hash.h"
#include "object-file.h"
#include "oidmap.h"
#include "read-cache-ll.h"
#include "reflink-checkout.h"
#include "repository.h"
#include "statinfo.h"
#include "strbuf.h"
#include "trace2.h"
#include "worktree.h"

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
	struct {
		uintmax_t eligible;
		uintmax_t skipped_other; /* unmerged, skip-worktree, not a file */
		uintmax_t skipped_dirty;
		uintmax_t cloned;
		uintmax_t cloned_bytes;
		uintmax_t verified;	/* racily clean, hence re-hashed */
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
 * must be re-hashed, without the racy-timestamp refinement, which the
 * caller applies separately (see reflink_try_checkout_entry()).  The
 * assume-unchanged and fsmonitor validity bits are not consulted: the
 * stat data is compared for real.
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
						 const char *donor)
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
 * Hash the clone we now own and compare with the object id the entry
 * asked for.  Used for clones of racily clean donor files, whose stat
 * data cannot vouch for their content.
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
	int mode, racy, fd = -1, ret = 0;

	/*
	 * Only a regular file that is to be created anew is ours to
	 * clone; anything already at the path (see below) and a
	 * checkout that must not create files are for checkout_entry()
	 * to sort out.
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
	racy = is_racy_timestamp(&m->donor_index, donor_ce);

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
		m->n.fallback_clone_fail++;
		/*
		 * A failure may be specific to one file (an unreadable
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

	/*
	 * reflink_file() made sure the inode it cloned was not written
	 * to while it did so.  That the inode is the one the donor's
	 * index describes, and was not modified between our lstat() and
	 * its open(), is what looking at the path again tells us.
	 */
	if (!racy && !donor_file_clean(donor_ce, m->donor_root, &src, &st))
		goto reject;

	fd = open_nofollow(dst.buf, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode))
		goto reject;
	if (racy) {
		if (!clone_matches_oid(m->repo, fd, &st, &ce->oid))
			goto reject;
		m->n.verified++;
	}
	close(fd);

	update_ce_after_write(state, ce, &st);
	m->n.cloned++;
	m->n.cloned_bytes += st.st_size;
	ret = 1;
	goto out;

reject:
	if (fd >= 0)
		close(fd);
	unlink(dst.buf);
	m->n.fallback_verify_fail++;
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
	trace2_data_intmax("reflink", r, "verified", m->n.verified);
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
