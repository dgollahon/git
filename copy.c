#include "git-compat-util.h"
#include "copy.h"
#include "path.h"
#include "gettext.h"
#include "strbuf.h"
#include "abspath.h"

int copy_fd(int ifd, int ofd)
{
	while (1) {
		char buffer[8192];
		ssize_t len = xread(ifd, buffer, sizeof(buffer));
		if (!len)
			break;
		if (len < 0)
			return COPY_READ_ERROR;
		if (write_in_full(ofd, buffer, len) < 0)
			return COPY_WRITE_ERROR;
	}
	return 0;
}

static int copy_times(const char *dst, const char *src)
{
	struct stat st;
	struct utimbuf times;
	if (stat(src, &st) < 0)
		return -1;
	times.actime = st.st_atime;
	times.modtime = st.st_mtime;
	if (utime(dst, &times) < 0)
		return -1;
	return 0;
}

int copy_file(struct repository *repo,
	      const char *dst, const char *src, int mode)
{
	int fdi, fdo, status;

	mode = (mode & 0111) ? 0777 : 0666;
	if ((fdi = open(src, O_RDONLY)) < 0)
		return fdi;
	if ((fdo = open(dst, O_WRONLY | O_CREAT | O_EXCL, mode)) < 0) {
		close(fdi);
		return fdo;
	}
	status = copy_fd(fdi, fdo);
	switch (status) {
	case COPY_READ_ERROR:
		error_errno("copy-fd: read returned");
		break;
	case COPY_WRITE_ERROR:
		error_errno("copy-fd: write returned");
		break;
	}
	close(fdi);
	if (close(fdo) != 0)
		return error_errno("%s: close error", dst);

	if (!status && adjust_shared_perm(repo, dst))
		return -1;

	return status;
}

int copy_file_with_time(struct repository *repo,
			const char *dst, const char *src, int mode)
{
	int status = copy_file(repo, dst, src, mode);
	if (!status)
		return copy_times(dst, src);
	return status;
}

/*
 * Copy-on-write cloning of a single file.  See copy.h for the contract.
 */
#if defined(HAVE_FICLONE) || defined(HAVE_CLONEFILE)
/*
 * Was the source written to between two snapshots of its stat data?
 * Both snapshots come from the descriptor we hold, so this compares
 * what the index would compare, minus anything that depends on
 * configuration; a rename over the path is neither visible nor a
 * problem, since we clone the inode we opened.
 */
static int source_changed(const struct stat *a, const struct stat *b)
{
	return a->st_size != b->st_size ||
	       a->st_mtime != b->st_mtime ||
	       ST_MTIME_NSEC(*a) != ST_MTIME_NSEC(*b) ||
	       a->st_ctime != b->st_ctime ||
	       ST_CTIME_NSEC(*a) != ST_CTIME_NSEC(*b);
}
#endif

#if defined(HAVE_FICLONE)

#include <sys/ioctl.h>
/*
 * <linux/fs.h> would provide this, but the kernel headers are not
 * part of every libc installation (musl-based builds, for one); the
 * value is stable uapi, and _IOW() encodes it correctly for every
 * architecture.
 */
#ifndef FICLONE
#define FICLONE _IOW(0x94, 9, int)
#endif

int reflink_file(const char *dst, const char *src, int mode)
{
	struct stat before, after;
	int in, out, saved_errno;

	/*
	 * O_NONBLOCK so that a source which turned into a FIFO since the
	 * caller looked at it fails the S_ISREG() test below instead of
	 * blocking here until a writer shows up.
	 */
	in = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
	if (in < 0)
		return -1;
	if (fstat(in, &before))
		goto fail_in;
	if (!S_ISREG(before.st_mode)) {
		errno = EINVAL;
		goto fail_in;
	}

	out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
	if (out < 0)
		goto fail_in;
	if (ioctl(out, FICLONE, in) < 0)
		goto fail_out;

	/*
	 * A writer racing with us may have modified the source while
	 * it was being cloned; report that so the caller falls back to
	 * writing the content out itself.
	 */
	if (fstat(in, &after))
		goto fail_out;
	if (source_changed(&before, &after)) {
		errno = EAGAIN;
		goto fail_out;
	}

	close(in);
	if (close(out)) {
		saved_errno = errno;
		unlink(dst);
		errno = saved_errno;
		return -1;
	}
	return 0;

fail_out:
	saved_errno = errno;
	close(out);
	unlink(dst);
	close(in);
	errno = saved_errno;
	return -1;
fail_in:
	saved_errno = errno;
	close(in);
	errno = saved_errno;
	return -1;
}

#elif defined(HAVE_CLONEFILE)

#include <sys/clonefile.h>
#include <sys/time.h>
#include <sys/xattr.h>

#ifndef CLONE_NOOWNERCOPY
#define CLONE_NOOWNERCOPY 0
#endif

/*
 * clonefile() copies the extended attributes of the source, a file
 * created by open(2) has none.  Drop them, best effort: the ones the
 * system protects cannot be removed, and are harmless.
 */
static void drop_xattrs(int fd)
{
	ssize_t len = flistxattr(fd, NULL, 0, 0);
	char *names, *p;

	if (len <= 0)
		return;
	names = xmalloc(len);
	len = flistxattr(fd, names, len, 0);
	for (p = names; len > 0 && p < names + len; p += strlen(p) + 1)
		fremovexattr(fd, p, 0);
	free(names);
}

int reflink_file(const char *dst, const char *src, int mode)
{
	struct stat before, after;
	mode_t mask;
	int in, out, saved_errno;

	in = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
	if (in < 0)
		return -1;
	if (fstat(in, &before))
		goto fail_in;
	if (!S_ISREG(before.st_mode)) {
		errno = EINVAL;
		goto fail_in;
	}
	/*
	 * The clone inherits the BSD file flags of its source; an
	 * immutable or append-only one would give us a file we could
	 * neither chmod() nor unlink().  Leave those to the caller.
	 */
	if (before.st_flags &
	    (UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)) {
		errno = EPERM;
		goto fail_in;
	}

	/*
	 * clonefile(2) refuses an existing destination (EEXIST), but
	 * says nothing about following a symbolic link there; refuse
	 * one ourselves rather than clone to wherever it points.
	 */
	if (!lstat(dst, &after)) {
		errno = EEXIST;
		goto fail_in;
	}

	/*
	 * Clone the very inode we hold open, so that the path being
	 * swapped under us cannot make us clone something else.
	 * CLONE_NOOWNERCOPY gives the destination the ownership any
	 * file we create would get.
	 */
	if (fclonefileat(in, AT_FDCWD, dst, CLONE_NOOWNERCOPY))
		goto fail_in;
	if (fstat(in, &after))
		goto fail_out;
	if (source_changed(&before, &after)) {
		errno = EAGAIN;
		goto fail_out;
	}

	/*
	 * Make the clone look like a file open(2) would have created:
	 * "mode" with the umask applied (fchmod() does not consult it),
	 * the current time as its timestamps instead of the source's,
	 * and no extended attributes.
	 */
	out = open(dst, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (out < 0)
		goto fail_out;
	mask = umask(0);
	umask(mask);
	if (fstat(out, &after) || !S_ISREG(after.st_mode) ||
	    fchmod(out, mode & ~mask) || futimes(out, NULL)) {
		saved_errno = errno;
		close(out);
		errno = saved_errno;
		goto fail_out;
	}
	drop_xattrs(out);
	close(out);
	close(in);
	return 0;

fail_out:
	saved_errno = errno;
	unlink(dst);
	close(in);
	errno = saved_errno;
	return -1;
fail_in:
	saved_errno = errno;
	close(in);
	errno = saved_errno;
	return -1;
}

#else

int reflink_file(const char *dst UNUSED, const char *src UNUSED,
		 int mode UNUSED)
{
	errno = ENOSYS;
	return -1;
}

#endif
