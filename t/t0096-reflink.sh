#!/bin/sh

test_description='reflink_file(): copy-on-write cloning of a single file'

. ./test-lib.sh

test_expect_success REFLINK_PRIMITIVE 'reflink_file: refuses to overwrite an existing destination' '
	echo donor >c-src &&
	echo keep >c-dst &&
	test_must_fail test-tool reflink c-src c-dst 0644 >out &&
	test_grep "errno=EEXIST" out &&
	echo keep >expect &&
	test_cmp expect c-dst
'

test_expect_success REFLINK_PRIMITIVE,SYMLINKS 'reflink_file: refuses a symbolic link as its source' '
	ln -s c-src c-link &&
	test_must_fail test-tool reflink c-link c-out 0644 >out &&
	test_grep -E "errno=(ELOOP|EINVAL)" out &&
	test_path_is_missing c-out
'

test_expect_success REFLINK_PRIMITIVE 'reflink_file: refuses a directory as its source' '
	mkdir c-dir &&
	test_must_fail test-tool reflink c-dir c-out 0644 >out &&
	test_grep "errno=EINVAL" out &&
	test_path_is_missing c-out
'

test_expect_success REFLINK_PRIMITIVE,PIPE 'reflink_file: refuses a fifo as its source without blocking' '
	mkfifo c-fifo &&
	test_must_fail test-tool reflink c-fifo c-out 0644 >out &&
	test_grep "errno=EINVAL" out &&
	test_path_is_missing c-out
'

test_expect_success REFLINK_PRIMITIVE 'reflink_file: reports a missing source and creates nothing' '
	test_must_fail test-tool reflink c-missing c-out 0644 >out &&
	test_grep "errno=ENOENT" out &&
	test_path_is_missing c-out
'

test_expect_success !REFLINK 'reflink_file: reports an unsupported filesystem and creates nothing' '
	echo donor >u-src &&
	test_must_fail test-tool reflink u-src u-dst 0644 >out &&
	test_grep -E "errno=(EOPNOTSUPP|ENOTSUP|ENOTTY|EXDEV|ENOSYS)" out &&
	test_path_is_missing u-dst
'

test_expect_success REFLINK 'reflink_file: clones content into an independent file' '
	echo donor >i-src &&
	test-tool reflink i-src i-dst 0644 &&
	test_cmp i-src i-dst &&
	echo appended >>i-dst &&
	echo donor >expect &&
	test_cmp expect i-src &&
	echo more >>i-src &&
	printf "donor\nappended\n" >expect &&
	test_cmp expect i-dst
'

test_expect_success REFLINK,POSIXPERM 'reflink_file: permissions follow mode and umask, not the source' '
	echo donor >p-src &&
	chmod 0600 p-src &&
	(umask 077 && test-tool reflink p-src p-dst 0666) &&
	test "$(test_modebits p-dst)" = "-rw-------" &&
	(umask 022 && test-tool reflink p-src p-dst2 0777) &&
	test "$(test_modebits p-dst2)" = "-rwxr-xr-x"
'

test_done
