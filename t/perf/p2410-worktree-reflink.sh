#!/bin/sh

test_description='performance of git worktree add with copy-on-write clones'

. ./perf-lib.sh

test_perf_large_repo

test_expect_success 'setup' '
	git checkout -f HEAD &&
	git status >/dev/null
'

# Only the "add" is timed; the previous worktree is removed in the
# untimed setup step of each iteration.  Clones are only made where
# the filesystem supports them, so without REFLINK the two are the
# same.
for workers in 1 0
do
	test_perf "worktree add, worktree.reflink=false, checkout.workers=$workers" \
		--setup 'rm -rf wt && git worktree prune' "
		git -c checkout.workers=$workers -c worktree.reflink=false \
			worktree add --detach wt
	"

	test_perf "worktree add, checkout.workers=$workers" \
		--setup 'rm -rf wt && git worktree prune' "
		git -c checkout.workers=$workers worktree add --detach wt
	"
done

test_done
