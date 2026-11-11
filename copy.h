#ifndef COPY_H
#define COPY_H

struct repository;

#define COPY_READ_ERROR (-2)
#define COPY_WRITE_ERROR (-3)
int copy_fd(int ifd, int ofd);
int copy_file(struct repository *repo,
	      const char *dst, const char *src, int mode);
int copy_file_with_time(struct repository *repo,
			const char *dst, const char *src, int mode);

/*
 * Clone the regular file "src" to the new file "dst" using the
 * filesystem's copy-on-write primitive (FICLONE on Linux, clonefile(2)
 * on Darwin).  The result is an independent file that shares storage
 * with "src" until either of them is modified.
 *
 * "dst" must not exist; it is created with "mode" interpreted like the
 * mode argument of open(2), i.e. the umask applies and the permission
 * bits of "src" are not inherited.  "src" must be a regular file;
 * symbolic links are not followed.
 *
 * Returns 0 on success.  On failure, returns -1 with errno set and no
 * "dst" left behind.  Errno values callers can rely on:
 *
 *   EOPNOTSUPP, ENOTTY, ENOTSUP, EXDEV
 *              the filesystem (or the pair of filesystems) cannot
 *              clone between these two files;
 *   EINVAL     "src" is not a regular file, or the filesystem
 *              refuses to clone between these two files (e.g. Btrfs
 *              with differing nodatacow settings);
 *   ELOOP      "src" is a symbolic link;
 *   ENOSYS     this platform has no clone primitive at all;
 *   EAGAIN     "src" changed while it was being cloned;
 *   EEXIST     "dst" already exists.
 */
int reflink_file(const char *dst, const char *src, int mode);

#endif /* COPY_H */
