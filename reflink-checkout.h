#ifndef REFLINK_CHECKOUT_H
#define REFLINK_CHECKOUT_H

struct cache_entry;
struct checkout;
struct repository;

/*
 * Copy-on-write acceleration of checkout: when "git worktree add
 * --reflink" spawns its internal checkout ("git reset --hard"), it
 * names the worktree to clone files from with the internal option
 * "--reflink-donor=<path>", which reset passes on in
 * struct unpack_trees_options.  The donor must be a worktree of the
 * same repository.  With "--reflink=always" it adds the internal
 * "--reflink-required", which turns a filesystem's refusal to clone a
 * file into a checkout error instead of a fallback.
 */

/*
 * Get "donor" ready to serve as the clone source for a new working
 * tree at "path" (which need not exist yet), and decide whether that
 * can work at all: refresh the donor's index opportunistically, the
 * way "git status" does, then clone a temporary file and one file of
 * the donor into the nearest existing ancestor of "path" and remove
 * them again.  Returns 1 if cloning worked, 0 if the filesystem(s)
 * cannot clone between the two, and -1 if no verdict could be reached
 * because not even a temporary file could be created there (in which
 * case creating the working tree is bound to fail with a better error
 * than ours).
 */
int reflink_prepare_donor(struct repository *donor, const char *path);

/*
 * A map from blob object id to the donor's index entry for a file
 * whose content is supposed to be that blob.  Opaque.
 */
struct reflink_donor_map;

/*
 * Build the donor map for the worktree at "donor", or return NULL if
 * "donor" is NULL or does not name a usable worktree of "r".  NULL
 * simply means "no acceleration".  With "required", a clone attempt
 * that the filesystem refuses outright is an error (see below) rather
 * than a fallback.
 */
struct reflink_donor_map *reflink_donor_map_load(struct repository *r,
						 const char *donor,
						 int required);

/*
 * Try to materialize "ce" by cloning a donor file.  Returns 1 when the
 * working-tree file exists, has been re-hashed and matches ce's object
 * id, and ce's stat information has been recorded exactly as
 * checkout_entry() would have done; the caller must then skip
 * checkout_entry() for this entry.  Returns 0 when the caller should
 * fall back to checkout_entry(); no destination file is left behind
 * in that case.  Returns -1, after reporting the error, when the map
 * was loaded with "required" and the filesystem refused to clone the
 * file at all; the caller should still fall back for this entry, and
 * must fail the checkout as a whole.  No further clones are attempted
 * after that.
 */
int reflink_try_checkout_entry(const struct checkout *state,
			       struct cache_entry *ce,
			       struct reflink_donor_map *map);

/*
 * Emit the trace2 statistics accumulated in "map" and free it.
 * Accepts NULL.
 */
void reflink_donor_map_free(struct reflink_donor_map *map);

#endif /* REFLINK_CHECKOUT_H */
