#include "test-tool.h"
#include "copy.h"

/*
 * test-tool reflink <src> <dst> <octal-mode>
 *
 * Clone <src> to <dst> with reflink_file().  On failure, print the
 * symbolic name of errno and exit with status 1.
 */

static const char *errno_name(int err)
{
	switch (err) {
	case EAGAIN: return "EAGAIN";
	case EEXIST: return "EEXIST";
	case EINVAL: return "EINVAL";
	case ELOOP: return "ELOOP";
	case ENOENT: return "ENOENT";
	case ENOSYS: return "ENOSYS";
	case ENOTTY: return "ENOTTY";
	case EXDEV: return "EXDEV";
	case EOPNOTSUPP: return "EOPNOTSUPP";
#if ENOTSUP != EOPNOTSUPP
	case ENOTSUP: return "ENOTSUP";
#endif
	default: return "other";
	}
}

int cmd__reflink(int argc, const char **argv)
{
	unsigned long mode;
	char *end;

	if (argc != 4)
		usage("test-tool reflink <src> <dst> <octal-mode>");
	mode = strtoul(argv[3], &end, 8);
	if (*end || mode > 07777)
		die("bad mode: %s", argv[3]);
	if (reflink_file(argv[2], argv[1], (int)mode)) {
		printf("errno=%s\n", errno_name(errno));
		return 1;
	}
	return 0;
}
