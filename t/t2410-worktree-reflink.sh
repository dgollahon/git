#!/bin/sh

test_description='git worktree add --reflink (copy-on-write checkout)'

. ./test-lib.sh

test_expect_success 'setup' '
	test_commit_bulk 3 &&
	echo "content one" >file1 &&
	echo "content two" >file2 &&
	echo "content three" >file3 &&
	echo "shared blob" >dup-a &&
	echo "shared blob" >dup-b &&
	>empty &&
	mkdir -p deep/sub &&
	echo "nested" >deep/sub/nested.txt &&
	printf "a\nb\n" >f.crlf &&
	echo "*.crlf text eol=crlf" >.gitattributes &&
	echo "node_modules/" >.gitignore &&
	echo ".env" >>.gitignore &&
	git add -A &&
	git commit -m base &&
	git tag base &&
	echo "changed in tip" >file3 &&
	git commit -am tip &&
	mkdir -p node_modules &&
	echo "abs-path=$(pwd)" >node_modules/marker &&
	echo "SECRET=1" >.env
'

# The contract of the compat helper itself, through test-tool.

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

# Behavior of "worktree add".  Most of these hold on every filesystem:
# where clones are unavailable they exercise probing and falling back.

test_expect_success 'worktree add --reflink=auto produces a clean checkout' '
	git worktree add --reflink=auto wt-auto &&
	git -C wt-auto status --porcelain >status.out &&
	test_must_be_empty status.out &&
	git -C wt-auto diff --quiet HEAD
'

test_expect_success 'reflink worktree is identical to a plain worktree' '
	git worktree add wt-plain &&
	git -C wt-auto ls-files -s >auto.ls &&
	git -C wt-plain ls-files -s >plain.ls &&
	test_cmp plain.ls auto.ls &&
	for f in $(git ls-files)
	do
		test_cmp "wt-plain/$f" "wt-auto/$f" || return 1
	done
'

test_expect_success POSIXPERM 'reflink worktree has the same permission bits as a plain one' '
	for f in $(git ls-files)
	do
		test "$(test_modebits "wt-plain/$f")" = \
		     "$(test_modebits "wt-auto/$f")" || return 1
	done
'

test_expect_success 'untracked and ignored donor files are never copied' '
	test_path_is_missing wt-auto/node_modules &&
	test_path_is_missing wt-auto/.env
'

test_expect_success 'dirty or deleted donor content is not propagated' '
	test_when_finished "git checkout -- file1 dup-b" &&
	echo "DIRTY" >>file1 &&
	rm dup-b &&
	git worktree add --reflink=auto wt-dirty &&
	echo "content one" >expect &&
	test_cmp expect wt-dirty/file1 &&
	echo "shared blob" >expect &&
	test_cmp expect wt-dirty/dup-b &&
	git -C wt-dirty diff --quiet HEAD
'

test_expect_success REFLINK 'dirty and deleted donor entries are filtered out, not cloned and rejected' '
	test_when_finished "git checkout -- file1 dup-b" &&
	echo "DIRTY" >>file1 &&
	rm dup-b &&
	GIT_TRACE2_EVENT="$(pwd)/ev-dirty.json" \
		git worktree add --detach --reflink=always wt-dirty2 &&
	git -C wt-dirty2 diff --quiet HEAD &&
	grep "\"key\":\"donor/skipped_dirty\"" ev-dirty.json >dirty.ev &&
	test_grep ! "\"value\":\"0\"" dirty.ev &&
	grep "\"key\":\"fallback/verify_fail\"" ev-dirty.json >dirty-vf.ev &&
	test_grep "\"value\":\"0\"" dirty-vf.ev
'

test_expect_success 'assume-unchanged donor entries are never trusted' '
	git update-index --assume-unchanged file2 &&
	echo "POISON" >file2 &&
	test_when_finished "git update-index --no-assume-unchanged file2 &&
			    git checkout -- file2" &&
	git worktree add --reflink=auto wt-au &&
	echo "content two" >expect &&
	test_cmp expect wt-au/file2 &&
	git -C wt-au diff --quiet HEAD
'

test_expect_success 'skip-worktree donor entries are never trusted' '
	git update-index --skip-worktree file2 &&
	rm -f file2 &&
	test_when_finished "git update-index --no-skip-worktree file2 &&
			    git checkout -- file2" &&
	git worktree add --reflink=auto wt-sw &&
	echo "content two" >expect &&
	test_cmp expect wt-sw/file2 &&
	git -C wt-sw diff --quiet HEAD
'

test_expect_success REFLINK 'skip-worktree donor entries are filtered out up front' '
	git update-index --skip-worktree file2 &&
	echo "POISON" >file2 &&
	test_when_finished "git update-index --no-skip-worktree file2 &&
			    git checkout -- file2" &&
	GIT_TRACE2_EVENT="$(pwd)/ev-sw.json" \
		git worktree add --detach --reflink=always wt-sw2 &&
	echo "content two" >expect &&
	test_cmp expect wt-sw2/file2 &&
	grep "\"key\":\"donor/skipped_other\"" ev-sw.json >sw.ev &&
	test_grep ! "\"value\":\"0\"" sw.ev &&
	grep "\"key\":\"fallback/verify_fail\"" ev-sw.json >sw-vf.ev &&
	test_grep "\"value\":\"0\"" sw-vf.ev
'

test_expect_success 'cross-commit add materializes the target commit' '
	git worktree add --reflink=auto wt-base base &&
	git worktree add wt-base-plain base &&
	echo "content three" >expect &&
	test_cmp expect wt-base/file3 &&
	for f in $(git -C wt-base-plain ls-files)
	do
		test_cmp "wt-base-plain/$f" "wt-base/$f" || return 1
	done &&
	git -C wt-base diff --quiet HEAD
'

test_expect_success 'CRLF conversion applies in the new worktree' '
	printf "a\r\nb\r\n" >expect &&
	test_cmp expect wt-auto/f.crlf
'

test_expect_success 'smudge-filtered paths are converted, not cloned raw' '
	test_config filter.sm.smudge "sed s/ORIG/SMUDGED/" &&
	test_config filter.sm.clean "sed s/SMUDGED/ORIG/" &&
	echo "sm.txt filter=sm" >>.gitattributes &&
	echo "ORIG payload" >sm.txt &&
	git add .gitattributes sm.txt &&
	git commit -m filtered &&
	git checkout -- sm.txt &&
	git worktree add --reflink=auto wt-filt &&
	echo "SMUDGED payload" >expect &&
	test_cmp expect wt-filt/sm.txt &&
	git -C wt-filt diff --quiet HEAD
'

test_expect_success REFLINK 'conversion demanded by the target, not the donor, is honored' '
	test_when_finished "rm -f .git/info/attributes" &&
	mkdir -p .git/info &&
	echo "file1 text eol=crlf" >.git/info/attributes &&
	GIT_TRACE2_EVENT="$(pwd)/ev-conv.json" \
		git worktree add --detach --reflink=always wt-conv &&
	printf "content one\r\n" >expect &&
	test_cmp expect wt-conv/file1 &&
	grep "\"key\":\"fallback/conversion\"" ev-conv.json >conv.ev &&
	test_grep ! "\"value\":\"0\"" conv.ev &&
	grep "\"key\":\"fallback/verify_fail\"" ev-conv.json >conv-vf.ev &&
	test_grep "\"value\":\"0\"" conv-vf.ev
'

test_expect_success REFLINK 'filtered paths are refused before cloning, not after' '
	test_config filter.sm.smudge "sed s/ORIG/SMUDGED/" &&
	test_config filter.sm.clean "sed s/SMUDGED/ORIG/" &&
	GIT_TRACE2_EVENT="$(pwd)/ev-filt.json" \
		git worktree add --detach --reflink=always wt-filt2 &&
	echo "SMUDGED payload" >expect &&
	test_cmp expect wt-filt2/sm.txt &&
	grep "\"key\":\"fallback/conversion\"" ev-filt.json >filt.ev &&
	test_grep ! "\"value\":\"0\"" filt.ev &&
	grep "\"key\":\"fallback/verify_fail\"" ev-filt.json >filt-vf.ev &&
	test_grep "\"value\":\"0\"" filt-vf.ev
'

test_expect_success SYMLINKS 'symlinks are recreated as symlinks' '
	ln -s file1 alink &&
	git add alink &&
	git commit -m symlink &&
	git worktree add --reflink=auto wt-ln &&
	test_path_is_symlink wt-ln/alink &&
	test "z$(test_readlink wt-ln/alink)" = "zfile1"
'

test_expect_success SYMLINKS 'a symlink is not confused with a file holding its target' '
	printf "file1" >alink.txt &&
	git add alink.txt &&
	git commit -m "same blob as the symlink" &&
	git worktree add --reflink=auto wt-ln2 &&
	test_path_is_symlink wt-ln2/alink &&
	test_path_is_file_not_symlink wt-ln2/alink.txt &&
	test "z$(cat wt-ln2/alink.txt)" = "zfile1" &&
	git -C wt-ln2 diff --quiet HEAD
'

test_expect_success POSIXPERM 'executable bit is preserved' '
	echo "#!/bin/sh" >run.sh &&
	chmod +x run.sh &&
	git add run.sh &&
	git commit -m exec &&
	git worktree add --reflink=auto wt-x &&
	test_path_is_executable wt-x/run.sh
'

test_expect_success POSIXPERM 'files sharing a blob get their own modes' '
	echo "same content" >same-a &&
	echo "same content" >same-b &&
	chmod +x same-b &&
	git add same-a same-b &&
	git commit -m modes &&
	git worktree add --reflink=auto wt-modes &&
	! test -x wt-modes/same-a &&
	test_path_is_executable wt-modes/same-b &&
	git -C wt-modes diff --quiet HEAD
'

test_expect_success POSIXPERM 'cloned permissions follow the umask, not the donor' '
	(
		umask 077 &&
		GIT_TRACE2_EVENT="$(pwd)/ev-um.json" \
			git worktree add --reflink=auto wt-um &&
		git worktree add wt-um-plain
	) &&
	test "$(test_modebits wt-um/file1)" = \
	     "$(test_modebits wt-um-plain/file1)" &&
	if test_have_prereq REFLINK
	then
		grep "\"key\":\"cloned\"" ev-um.json >um-cloned.ev &&
		test_grep ! "\"value\":\"0\"" um-cloned.ev
	fi
'

test_expect_success POSIXPERM 'core.sharedRepository does not leak into worktree directories' '
	git -c core.sharedRepository=0666 worktree add --reflink=auto wt-sh &&
	git -c core.sharedRepository=0666 worktree add wt-sh-plain &&
	test "$(test_modebits wt-sh/deep)" = \
	     "$(test_modebits wt-sh-plain/deep)" &&
	test "$(test_modebits wt-sh/deep/sub)" = \
	     "$(test_modebits wt-sh-plain/deep/sub)"
'

test_expect_success 'post-checkout hook runs once with plain-add arguments' '
	test_hook post-checkout <<-\EOF &&
	echo "$*" >>"$HOOK_LOG"
	EOF
	test_when_finished "sane_unset HOOK_LOG" &&
	HOOK_LOG="$(pwd)/hook.plain" && export HOOK_LOG &&
	rm -f hook.plain hook.reflink &&
	git worktree add wt-hp &&
	HOOK_LOG="$(pwd)/hook.reflink" && export HOOK_LOG &&
	git worktree add --reflink=auto wt-hr &&
	test_line_count = 1 hook.plain &&
	test_line_count = 1 hook.reflink &&
	test_cmp hook.plain hook.reflink
'

test_expect_success 'worktree.reflink configuration is honored' '
	test_config worktree.reflink auto &&
	GIT_TRACE2_EVENT="$(pwd)/ev-cfg-auto.json" git worktree add wt-cfg &&
	git -C wt-cfg diff --quiet HEAD &&
	test_grep "\"category\":\"reflink\"" ev-cfg-auto.json &&
	test_config worktree.reflink true &&
	GIT_TRACE2_EVENT="$(pwd)/ev-cfg-true.json" git worktree add wt-cfg2 &&
	git -C wt-cfg2 diff --quiet HEAD &&
	test_grep "\"category\":\"reflink\"" ev-cfg-true.json
'

test_expect_success REFLINK 'worktree.reflink=auto engages cloning' '
	test_config worktree.reflink auto &&
	GIT_TRACE2_EVENT="$(pwd)/ev-cfg.json" git worktree add wt-cfg-t2 &&
	grep "\"category\":\"reflink\"" ev-cfg.json >cfg.ev &&
	grep "\"key\":\"cloned\"" cfg.ev >cfg-cloned.ev &&
	test_grep ! "\"value\":\"0\"" cfg-cloned.ev
'

test_expect_success 'command line overrides worktree.reflink' '
	test_config worktree.reflink always &&
	git worktree add --reflink=never wt-override &&
	git -C wt-override diff --quiet HEAD
'

test_expect_success 'invalid --reflink value is rejected' '
	test_must_fail git worktree add --reflink=sometimes wt-bad 2>err &&
	test_grep "expects \"always\", \"auto\", or \"never\"" err &&
	test_path_is_missing wt-bad
'

test_expect_success 'invalid worktree.reflink value is rejected' '
	test_must_fail git -c worktree.reflink=sometimes \
		worktree add wt-badcfg 2>err &&
	test_grep "invalid value for .worktree.reflink." err &&
	test_path_is_missing wt-badcfg
'

test_expect_success !REFLINK '--reflink=always fails cleanly when unsupported' '
	test_must_fail git worktree add --reflink=always wt-req 2>err &&
	test_grep "cannot be cloned from" err &&
	test_path_is_missing wt-req &&
	git worktree list --porcelain >wtl &&
	test_grep ! wt-req wtl &&
	test_must_fail git rev-parse --verify refs/heads/wt-req
'

test_expect_success !REFLINK 'a clone the filesystem refuses during the checkout fails under always' '
	# "worktree add" would have refused up front; the internal
	# option reaches the checkout without the probe
	git worktree add --detach wt-req &&
	git -C wt-req ls-files >req-files &&
	(cd wt-req && xargs rm <../req-files) &&
	test_must_fail git -C wt-req reset --hard \
		--reflink-donor="$(pwd)" --reflink-required 2>err &&
	test_grep "reflink is set to .always. but .* cannot be cloned from" err &&
	git -C wt-req reset --hard --reflink-donor="$(pwd)" &&
	git -C wt-req diff --quiet HEAD
'

test_expect_success !REFLINK '--reflink=auto falls back cleanly when unsupported' '
	git worktree add --reflink=auto wt-fb &&
	git -C wt-fb status --porcelain >status.out &&
	test_must_be_empty status.out &&
	git -C wt-fb diff --quiet HEAD
'

test_expect_success !REFLINK 'an unsupported filesystem leaves the donor index untouched' '
	test_when_finished "git update-index -q --refresh" &&
	git read-tree HEAD &&
	test-tool chmtime =-60 .git/index &&
	before=$(test-tool chmtime --get .git/index) &&
	GIT_TRACE2_EVENT="$(pwd)/ev-untouched.json" \
		git worktree add --detach --reflink=auto wt-untouched &&
	after=$(test-tool chmtime --get .git/index) &&
	test "$before" = "$after" &&
	test_grep ! "donor/refresh" ev-untouched.json
'

test_expect_success REFLINK '--reflink=always engages cloning (trace2)' '
	GIT_TRACE2_EVENT="$(pwd)/ev.json" \
		git worktree add --reflink=always wt-t2 &&
	grep "\"category\":\"reflink\"" ev.json >reflink.ev &&
	grep "\"key\":\"cloned\"" reflink.ev >cloned.ev &&
	test_grep ! "\"value\":\"0\"" cloned.ev
'

test_expect_success REFLINK 'writes in the clone never reach the donor' '
	git worktree add --reflink=always wt-ind &&
	echo "clone-side write" >>wt-ind/file1 &&
	echo "content one" >expect &&
	test_cmp expect file1
'

test_expect_success REFLINK 'writes in the donor never reach the clone' '
	cat wt-ind/file1 >expect &&
	echo "donor-side write" >>file1 &&
	test_when_finished "git checkout -- file1" &&
	test_cmp expect wt-ind/file1
'

test_expect_success REFLINK 'duplicate blobs are checked out correctly' '
	git worktree add --reflink=always wt-dup &&
	echo "shared blob" >expect &&
	test_cmp expect wt-dup/dup-a &&
	test_cmp expect wt-dup/dup-b &&
	git -C wt-dup diff --quiet HEAD
'

test_expect_success REFLINK 'clones survive removal of their donor' '
	git worktree add --detach wt-victim &&
	GIT_TRACE2_EVENT="$(pwd)/ev-victim.json" \
		git -C wt-victim worktree add --detach --reflink=always \
		../wt-orphan &&
	grep "\"key\":\"cloned\"" ev-victim.json >victim.ev &&
	test_grep ! "\"value\":\"0\"" victim.ev &&
	git worktree remove --force wt-victim &&
	git -C wt-orphan diff --quiet HEAD &&
	echo "content one" >expect &&
	test_cmp expect wt-orphan/file1
'

test_expect_success REFLINK 'a worktree added right after a commit is cloned' '
	echo fresh >fresh.txt &&
	git add fresh.txt &&
	git commit -m fresh &&
	GIT_TRACE2_EVENT="$(pwd)/ev-fresh.json" \
		git worktree add --detach --reflink=always wt-fresh &&
	grep "\"key\":\"cloned\"" ev-fresh.json >fresh.ev &&
	test_grep ! "\"value\":\"0\"" fresh.ev &&
	grep "\"key\":\"donor/skipped_dirty\"" ev-fresh.json >fresh-dirty.ev &&
	test_grep "\"value\":\"0\"" fresh-dirty.ev &&
	grep "\"key\":\"fallback/no_donor\"" ev-fresh.json >fresh-nd.ev &&
	test_grep "\"value\":\"0\"" fresh-nd.ev &&
	git -C wt-fresh diff --quiet HEAD
'

test_expect_success REFLINK 'a donor whose index lacks stat data is refreshed and still clones' '
	git read-tree HEAD &&
	GIT_TRACE2_EVENT="$(pwd)/ev-stale.json" \
		git worktree add --detach --reflink=always wt-stale &&
	grep "\"key\":\"cloned\"" ev-stale.json >stale.ev &&
	test_grep ! "\"value\":\"0\"" stale.ev &&
	git -C wt-stale diff --quiet HEAD
'

test_expect_success 'cloned entries have stat data recorded in the new index' '
	GIT_TRACE2_EVENT="$(pwd)/ev-warm.json" \
		git worktree add --detach --reflink=auto wt-warm &&
	git -C wt-warm ls-files --debug -- file1 deep/sub/nested.txt >debug &&
	test_grep ! "mtime: 0:0" debug &&
	test_grep ! "size: 0[^0-9]" debug &&
	if test_have_prereq REFLINK
	then
		grep "\"key\":\"cloned\"" ev-warm.json >warm-cloned.ev &&
		test_grep ! "\"value\":\"0\"" warm-cloned.ev
	fi
'

test_expect_success REFLINK 'a same-size donor tamper is caught by the re-hash' '
	git worktree add --detach wt-tamper-donor &&
	# not racily clean, or the refresh of the donor index would
	# notice the tamper by itself instead of leaving it to the re-hash
	test-tool chmtime +60 "$(git -C wt-tamper-donor rev-parse --git-path index)" &&
	git -C wt-tamper-donor ls-files --debug file2 >file2.debug &&
	mtime=$(sed -n "s/.*mtime: \([0-9]*\):.*/\1/p" file2.debug) &&
	printf "content TWO\n" >wt-tamper-donor/file2 &&
	test-tool chmtime =$mtime wt-tamper-donor/file2 &&
	GIT_TRACE2_EVENT="$(pwd)/ev-tamper.json" \
		git -c core.checkstat=minimal -c core.trustctime=false \
		-C wt-tamper-donor worktree add --detach --reflink=always \
		../wt-tamper &&
	echo "content two" >expect &&
	test_cmp expect wt-tamper/file2 &&
	git -C wt-tamper diff --quiet HEAD &&
	grep "\"key\":\"fallback/verify_fail\"" ev-tamper.json >tamper.ev &&
	test_grep ! "\"value\":\"0\"" tamper.ev
'

test_expect_success REFLINK 'reflink composes with parallel checkout' '
	GIT_TRACE2_EVENT="$(pwd)/ev-pc.json" \
		git -c checkout.workers=2 -c checkout.thresholdForParallelism=0 \
		worktree add --detach --reflink=always wt-pc &&
	git -C wt-pc diff --quiet HEAD &&
	grep "\"key\":\"cloned\"" ev-pc.json >pc.ev &&
	test_grep ! "\"value\":\"0\"" pc.ev &&
	git -c checkout.workers=2 -c checkout.thresholdForParallelism=0 \
		worktree add --detach --reflink=always wt-pc2 base &&
	git worktree add --detach wt-pc-plain &&
	for f in $(git ls-files)
	do
		test_cmp "wt-pc-plain/$f" "wt-pc/$f" || return 1
	done &&
	for f in $(git -C wt-base-plain ls-files)
	do
		test_cmp "wt-base-plain/$f" "wt-pc2/$f" || return 1
	done
'

test_expect_success 'bare --reflink (= always) combines with --no-checkout as a no-op' '
	git worktree add --no-checkout --reflink wt-noco &&
	test_path_is_missing wt-noco/file1 &&
	git worktree remove --force wt-noco
'

test_expect_success '--reflink combines with --orphan as a no-op' '
	git worktree add --orphan -b orphan-branch --reflink=always wt-orph &&
	git -C wt-orph symbolic-ref HEAD >actual &&
	echo refs/heads/orphan-branch >expect &&
	test_cmp expect actual &&
	git worktree remove --force wt-orph
'

test_expect_success 'explicit --reflink=never wins over GIT_TEST_WORKTREE_REFLINK' '
	GIT_TRACE2_EVENT="$(pwd)/ev-never.json" \
	GIT_TEST_WORKTREE_REFLINK=1 \
		git worktree add --reflink=never wt-knob-never &&
	test_grep ! "\"category\":\"reflink\"" ev-never.json &&
	git -C wt-knob-never diff --quiet HEAD
'

test_expect_success 'GIT_TEST_WORKTREE_REFLINK engages by default' '
	GIT_TRACE2_EVENT="$(pwd)/ev-knob.json" \
	GIT_TEST_WORKTREE_REFLINK=1 \
		git worktree add wt-knob &&
	git -C wt-knob diff --quiet HEAD &&
	test_grep "\"category\":\"reflink\"" ev-knob.json &&
	if test_have_prereq REFLINK
	then
		grep "\"key\":\"cloned\"" ev-knob.json >knob-cloned.ev &&
		test_grep ! "\"value\":\"0\"" knob-cloned.ev
	fi
'

test_expect_success 'a donor that is not a worktree of the repository is ignored' '
	git worktree add --detach wt-bogus &&
	rm wt-bogus/file1 &&
	GIT_TRACE2_EVENT="$(pwd)/ev-bogus.json" \
		git -C wt-bogus reset --hard --reflink-donor=/nonexistent &&
	git -C wt-bogus diff --quiet HEAD &&
	mkdir notaworktree &&
	cp file1 notaworktree/ &&
	rm wt-bogus/file1 &&
	GIT_TRACE2_EVENT="$(pwd)/ev-bogus.json" \
		git -C wt-bogus reset --hard \
		--reflink-donor="$(pwd)/notaworktree" &&
	git -C wt-bogus diff --quiet HEAD &&
	test_grep ! "\"category\":\"reflink\"" ev-bogus.json
'

test_expect_success 'an unusable destination is reported, not probed' '
	mkdir wt-taken &&
	>wt-taken/occupied &&
	test_must_fail env GIT_TRACE2_EVENT="$(pwd)/ev-taken.json" \
		git worktree add --detach --reflink=always wt-taken 2>err &&
	test_grep "already exists" err &&
	test_grep ! "clone" err &&
	test_grep ! "\"category\":\"reflink\"" ev-taken.json
'

test_expect_success !REFLINK 'a filesystem that cannot clone is given up on' '
	git worktree add --detach wt-once-donor &&
	for i in $(test_seq 1 20)
	do
		echo "once $i" >wt-once-donor/once$i || return 1
	done &&
	git -C wt-once-donor add . &&
	git -C wt-once-donor commit -q -m once &&
	git worktree add --detach wt-once "$(git -C wt-once-donor rev-parse HEAD)" &&
	git -C wt-once ls-files >once-files &&
	(cd wt-once && xargs rm <../once-files) &&
	GIT_TRACE2_EVENT="$(pwd)/ev-once.json" \
		git -C wt-once reset --hard --reflink-donor="$(pwd)/wt-once-donor" &&
	git -C wt-once diff --quiet HEAD &&
	# REFLINK_MAX_FRUITLESS attempts, then the checkout stops trying
	grep "\"key\":\"fallback/clone_fail\"" ev-once.json >once.ev &&
	test_grep "\"value\":\"16\"" once.ev &&
	grep "\"key\":\"disabled\"" ev-once.json >once-dis.ev &&
	test_grep "no-success" once-dis.ev
'

test_expect_success CASE_INSENSITIVE_FS,SYMLINKS 'a clone is never written through a symbolic link' '
	mkdir outside &&
	blob=$(git rev-parse HEAD:file1) &&
	link=$(printf "../outside" | git hash-object -w --stdin) &&
	test_when_finished "git read-tree HEAD" &&
	git read-tree HEAD &&
	git update-index --add --cacheinfo 120000,$link,A &&
	git update-index --add --cacheinfo 100644,$blob,a/inside.txt &&
	tree=$(git write-tree) &&
	commit=$(git commit-tree -m "A -> ../outside, a/inside.txt" $tree) &&
	git worktree add --detach --reflink=auto wt-ci $commit &&
	test_path_is_missing outside/inside.txt &&
	test_path_is_file wt-ci/a/inside.txt
'

test_expect_success 'bare repository: auto degrades, always refuses' '
	git clone --bare . bare-src.git &&
	git -C bare-src.git worktree add --reflink=auto ../wt-bareauto &&
	git -C wt-bareauto diff --quiet HEAD &&
	test_must_fail git -C bare-src.git worktree add \
		--reflink=always ../wt-barereq 2>err &&
	test_grep "no working tree to clone files from" err &&
	test_path_is_missing wt-barereq &&
	git -C bare-src.git worktree remove ../wt-bareauto &&
	rm -rf bare-src.git
'

test_expect_success 'unmerged donor entries are never candidates' '
	# "base" has only regular files, so the two stages of the
	# conflict are the only donor entries there are to skip
	git worktree add --detach wt-um-donor base &&
	b1=$(echo one | git hash-object -w --stdin) &&
	b2=$(echo two | git hash-object -w --stdin) &&
	{
		echo "100644 $b1 1	conflict.txt" &&
		echo "100644 $b2 2	conflict.txt"
	} | git -C wt-um-donor update-index --index-info &&
	echo two >wt-um-donor/conflict.txt &&
	GIT_TRACE2_EVENT="$(pwd)/ev-unmerged.json" \
		git -C wt-um-donor worktree add --detach --reflink=auto \
		../wt-unmerged base &&
	git -C wt-unmerged diff --quiet HEAD &&
	test_path_is_missing wt-unmerged/conflict.txt &&
	if test_have_prereq REFLINK
	then
		grep "\"key\":\"donor/skipped_other\"" ev-unmerged.json >um.ev &&
		test_grep "\"value\":\"2\"" um.ev &&
		grep "\"key\":\"fallback/verify_fail\"" ev-unmerged.json >um-vf.ev &&
		test_grep "\"value\":\"0\"" um-vf.ev
	fi
'

test_expect_success 'sparse-index donor contributes only materialized files' '
	git worktree add wt-sparse &&
	test_when_finished "git worktree remove --force wt-from-sparse;
			    git worktree remove --force wt-sparse" &&
	git -C wt-sparse sparse-checkout set --sparse-index deep &&
	GIT_TRACE2_EVENT="$(pwd)/ev-sparse.json" \
		git -C wt-sparse worktree add --reflink=auto ../wt-from-sparse &&
	git -C wt-from-sparse diff --quiet HEAD &&
	test_path_is_file wt-from-sparse/file1 &&
	test_path_is_file wt-from-sparse/deep/sub/nested.txt &&
	if test_have_prereq REFLINK
	then
		grep "\"key\":\"cloned\"" ev-sparse.json >sparse.ev &&
		test_grep ! "\"value\":\"0\"" sparse.ev
	fi
'

test_expect_success 'destination in a directory that does not exist yet' '
	git worktree add --detach --reflink=auto nested/deep/wt-nested &&
	git -C nested/deep/wt-nested diff --quiet HEAD &&
	test_path_is_file nested/deep/wt-nested/file1
'

test_expect_success REFLINK 'cloning engages for a destination in a new directory' '
	GIT_TRACE2_EVENT="$(pwd)/ev-nested.json" \
		git worktree add --detach --reflink=always nested/deep/wt-nested2 &&
	grep "\"key\":\"cloned\"" ev-nested.json >nested.ev &&
	test_grep ! "\"value\":\"0\"" nested.ev &&
	grep "\"key\":\"probe\"" ev-nested.json >nested-probe.ev &&
	test_grep ok nested-probe.ev
'

test_expect_success REFLINK 'invoked from outside the donor, the index is not refreshed but clones still happen' '
	(
		cd "$TRASH_DIRECTORY/.." &&
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/ev-outside.json" \
		GIT_DIR="$TRASH_DIRECTORY/.git" \
		GIT_WORK_TREE="$TRASH_DIRECTORY" \
			git worktree add --detach --reflink=always \
			"$TRASH_DIRECTORY/wt-outside"
	) &&
	git -C wt-outside diff --quiet HEAD &&
	grep "\"key\":\"donor/refresh\"" ev-outside.json >outside.ev &&
	test_grep "skipped-cwd" outside.ev &&
	grep "\"key\":\"cloned\"" ev-outside.json >outside-cloned.ev &&
	test_grep ! "\"value\":\"0\"" outside-cloned.ev
'

test_expect_success SANITY,REFLINK 'clone attempts stop after enough failures without a success' '
	git worktree add --detach wt-many-unreadable &&
	test_when_finished "chmod -R u+r wt-many-unreadable" &&
	git -C wt-many-unreadable rm -q -r . &&
	for i in $(test_seq 1 20)
	do
		echo "unreadable $i" >wt-many-unreadable/u$i || return 1
	done &&
	git -C wt-many-unreadable add . &&
	git -C wt-many-unreadable commit -q -m unreadable &&
	chmod 0 wt-many-unreadable/u* &&
	# not racily clean, or the refresh would smudge the unreadable
	# entries out of the donor map before any clone is attempted
	test-tool chmtime +60 "$(git -C wt-many-unreadable rev-parse --git-path index)" &&
	GIT_TRACE2_EVENT="$(pwd)/ev-many.json" \
		git -c core.trustctime=false -C wt-many-unreadable worktree add \
		--detach --reflink=always ../wt-from-many &&
	git -C wt-from-many diff --quiet HEAD &&
	grep "\"key\":\"disabled\"" ev-many.json >many-dis.ev &&
	test_grep "no-success" many-dis.ev &&
	# REFLINK_MAX_FRUITLESS attempts, then the checkout stops trying
	grep "\"key\":\"fallback/clone_fail\"" ev-many.json >many-fail.ev &&
	test_grep "\"value\":\"16\"" many-fail.ev
'

test_expect_success REFLINK 'probing happens at the destination, not in TMPDIR' '
	GIT_TRACE2_EVENT="$(pwd)/ev-tmpdir.json" \
	TMPDIR="$(pwd)/no-such-tmpdir" \
		git worktree add --detach --reflink=always wt-tmpdir &&
	grep "\"key\":\"cloned\"" ev-tmpdir.json >tmpdir.ev &&
	test_grep ! "\"value\":\"0\"" tmpdir.ev &&
	grep "\"key\":\"probe\"" ev-tmpdir.json >tmpdir-probe.ev &&
	test_grep ok tmpdir-probe.ev &&
	test_grep ! inconclusive tmpdir-probe.ev
'

test_expect_success SANITY 'a probe that cannot create its temporary defers to the real error' '
	mkdir ro-parent &&
	chmod 555 ro-parent &&
	test_when_finished "chmod 755 ro-parent" &&
	test_must_fail env GIT_TRACE2_EVENT="$(pwd)/ev-ro.json" \
		git worktree add --detach --reflink=always ro-parent/wt 2>err &&
	test_grep "could not create leading directories" err &&
	grep "\"key\":\"probe\"" ev-ro.json >ro.ev &&
	test_grep inconclusive ro.ev
'

test_expect_success !REFLINK '--reflink=always into a new directory creates nothing' '
	test_must_fail git worktree add --detach --reflink=always \
		nested2/deep/wt 2>err &&
	test_grep "cannot be cloned from" err &&
	test_path_is_missing nested2
'

test_expect_success 'a donor with nothing eligible to clone still works' '
	git worktree add --detach wt-empty-donor &&
	git -C wt-empty-donor rm -q -r . &&
	git -C wt-empty-donor worktree add --detach --reflink=auto \
		../wt-from-empty &&
	git -C wt-from-empty diff --quiet HEAD &&
	test_path_is_file wt-from-empty/file1
'

test_expect_success REFLINK 'a donor with nothing to sample still satisfies --reflink=always' '
	git -C wt-empty-donor worktree add --detach --reflink=always \
		../wt-empty-ok &&
	git -C wt-empty-ok diff --quiet HEAD
'

test_expect_success REFLINK 'a locked donor index is left alone and still donates' '
	>.git/index.lock &&
	test_when_finished "rm -f .git/index.lock" &&
	GIT_TRACE2_EVENT="$(pwd)/ev-locked.json" \
		git worktree add --detach --reflink=always wt-locked &&
	git -C wt-locked diff --quiet HEAD &&
	grep "\"key\":\"donor/refresh\"" ev-locked.json >locked.ev &&
	test_grep "skipped-locked" locked.ev &&
	grep "\"key\":\"cloned\"" ev-locked.json >locked-cloned.ev &&
	test_grep ! "\"value\":\"0\"" locked-cloned.ev
'

test_expect_success REFLINK 'GIT_OPTIONAL_LOCKS=0 leaves the donor index alone and still donates' '
	git read-tree HEAD &&
	test-tool chmtime =-60 .git/index &&
	before=$(test-tool chmtime --get .git/index) &&
	GIT_TRACE2_EVENT="$(pwd)/ev-optlocks.json" \
	GIT_OPTIONAL_LOCKS=0 \
		git worktree add --detach --reflink=always wt-optlocks &&
	after=$(test-tool chmtime --get .git/index) &&
	test "$before" = "$after" &&
	git -C wt-optlocks diff --quiet HEAD &&
	grep "\"key\":\"donor/refresh\"" ev-optlocks.json >optlocks.ev &&
	test_grep "skipped-optional-locks" optlocks.ev &&
	git update-index -q --refresh &&
	GIT_TRACE2_EVENT="$(pwd)/ev-optlocks2.json" \
	GIT_OPTIONAL_LOCKS=0 \
		git worktree add --detach --reflink=always wt-optlocks2 &&
	grep "\"key\":\"cloned\"" ev-optlocks2.json >optlocks-cloned.ev &&
	test_grep ! "\"value\":\"0\"" optlocks-cloned.ev
'

test_expect_success REFLINK 'files already in place are left to the normal checkout, not counted as failed clones' '
	git worktree add --detach wt-inplace-donor &&
	for i in $(test_seq 1 20)
	do
		echo "keep $i" >wt-inplace-donor/keep$i || return 1
	done &&
	echo "last" >wt-inplace-donor/z-last &&
	git -C wt-inplace-donor add . &&
	git -C wt-inplace-donor commit -q -m inplace &&
	git worktree add --detach wt-inplace "$(git -C wt-inplace-donor rev-parse HEAD)" &&
	for i in $(test_seq 1 20)
	do
		echo "modified $i" >wt-inplace/keep$i || return 1
	done &&
	rm wt-inplace/z-last &&
	GIT_TRACE2_EVENT="$(pwd)/ev-inplace.json" \
		git -C wt-inplace reset --hard --reflink-donor="$(pwd)/wt-inplace-donor" &&
	git -C wt-inplace diff --quiet HEAD &&
	grep "\"key\":\"fallback/clone_fail\"" ev-inplace.json >inplace-fail.ev &&
	test_grep "\"value\":\"0\"" inplace-fail.ev &&
	grep "\"key\":\"cloned\"" ev-inplace.json >inplace-cloned.ev &&
	test_grep "\"value\":\"1\"" inplace-cloned.ev &&
	test_grep ! "\"key\":\"disabled\"" ev-inplace.json
'

test_expect_success REFLINK 'intent-to-add donor entries are never candidates' '
	# "base" has only regular files, so the intent-to-add entry is
	# the only donor entry there is to skip
	git worktree add --detach wt-ita-donor base &&
	echo "not the empty blob" >wt-ita-donor/ita.txt &&
	git -C wt-ita-donor add -N ita.txt &&
	GIT_TRACE2_EVENT="$(pwd)/ev-ita.json" \
		git -C wt-ita-donor worktree add --detach --reflink=always \
		../wt-ita base &&
	git -C wt-ita diff --quiet HEAD &&
	test_must_be_empty wt-ita/empty &&
	grep "\"key\":\"donor/skipped_other\"" ev-ita.json >ita.ev &&
	test_grep "\"value\":\"1\"" ita.ev &&
	grep "\"key\":\"fallback/verify_fail\"" ev-ita.json >ita-vf.ev &&
	test_grep "\"value\":\"0\"" ita-vf.ev
'

test_expect_success REFLINK 'gitlink entries in the donor are never candidates' '
	test_when_finished "git read-tree HEAD" &&
	git update-index --add --cacheinfo 160000,$(git rev-parse HEAD),sub &&
	GIT_TRACE2_EVENT="$(pwd)/ev-gitlink.json" \
		git worktree add --detach --reflink=always wt-gitlink &&
	git -C wt-gitlink diff --quiet HEAD &&
	test_path_is_missing wt-gitlink/sub &&
	grep "\"key\":\"donor/skipped_other\"" ev-gitlink.json >gl.ev &&
	test_grep ! "\"value\":\"0\"" gl.ev
'

test_expect_success 'a damaged donor index disables cloning instead of failing' '
	git worktree add --detach wt-damaged &&
	: >"$(git -C wt-damaged rev-parse --git-path index)" &&
	GIT_TRACE2_EVENT="$(pwd)/ev-damaged.json" \
		git -C wt-damaged worktree add --detach --reflink=auto \
		../wt-from-damaged &&
	git -C wt-from-damaged diff --quiet HEAD &&
	test_path_is_file wt-from-damaged/file1 &&
	test_grep ! "\"key\":\"cloned\"" ev-damaged.json
'

test_expect_success !REFLINK 'a donor with nothing to sample still gets a definitive answer' '
	test_must_fail git -C wt-empty-donor worktree add --detach \
		--reflink=always ../wt-empty-always 2>err &&
	test_grep "cannot be cloned from" err &&
	test_path_is_missing wt-empty-always
'

# Under "always" too: a file that cannot serve as a source is not a
# filesystem refusing to clone.
test_expect_success SANITY,REFLINK 'an unreadable donor file is skipped, not fatal' '
	git worktree add --detach wt-unread &&
	git -C wt-unread ls-files >unread-files &&
	grep -v -e "^deep/" -e "^1.t\$" unread-files >unread-rm &&
	git -C wt-unread rm -q $(cat unread-rm) &&
	chmod 0 wt-unread/1.t &&
	test-tool chmtime +60 "$(git -C wt-unread rev-parse --git-path index)" &&
	GIT_TRACE2_EVENT="$(pwd)/ev-unread.json" \
		git -c core.trustctime=false -C wt-unread worktree add \
		--detach --reflink=always ../wt-from-unread &&
	git -C wt-from-unread diff --quiet HEAD &&
	git show HEAD:1.t >expect &&
	test_cmp expect wt-from-unread/1.t &&
	grep "\"key\":\"cloned\"" ev-unread.json >unread.ev &&
	test_grep ! "\"value\":\"0\"" unread.ev &&
	grep "\"key\":\"fallback/clone_fail\"" ev-unread.json >unread-fail.ev &&
	test_grep "\"value\":\"1\"" unread-fail.ev
'

test_expect_success '--no-reflink overrides configuration' '
	GIT_TRACE2_EVENT="$(pwd)/ev-noflag.json" \
		git -c worktree.reflink=always worktree add \
		--no-reflink wt-noflag &&
	test_grep ! "\"category\":\"reflink\"" ev-noflag.json &&
	git -C wt-noflag diff --quiet HEAD
'

test_expect_success 'worktree.reflink=false means never' '
	GIT_TRACE2_EVENT="$(pwd)/ev-false.json" \
		git -c worktree.reflink=false worktree add wt-false &&
	test_grep ! "\"category\":\"reflink\"" ev-false.json
'

test_expect_success 'explicit configuration wins over GIT_TEST_WORKTREE_REFLINK' '
	GIT_TRACE2_EVENT="$(pwd)/ev-cfgnever.json" \
	GIT_TEST_WORKTREE_REFLINK=1 \
		git -c worktree.reflink=never worktree add wt-cfgnever &&
	test_grep ! "\"category\":\"reflink\"" ev-cfgnever.json
'

test_expect_success 'valueless worktree.reflink acts as boolean true' '
	GIT_TRACE2_EVENT="$(pwd)/ev-blank.json" \
		git -c worktree.reflink worktree add wt-blank &&
	git -C wt-blank diff --quiet HEAD &&
	test_grep "\"category\":\"reflink\"" ev-blank.json
'

test_expect_success 'worktree lifecycle works on reflink worktrees' '
	git worktree add --reflink=auto -b topic wt-life &&
	git worktree list --porcelain >wtl &&
	test_grep wt-life wtl &&
	git worktree remove wt-life &&
	git worktree list --porcelain >wtl &&
	test_grep ! wt-life wtl &&
	git branch -D topic
'

test_expect_success 'no clone probe litter is left behind' '
	find . -name ".git-reflink-probe*" >litter &&
	test_must_be_empty litter
'

test_done
