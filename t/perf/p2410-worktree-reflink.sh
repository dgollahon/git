#!/bin/sh

test_description='performance of git worktree add with --reflink'

. ./perf-lib.sh

test_perf_large_repo

test_expect_success 'setup' '
	git checkout -f HEAD &&
	git status >/dev/null
'

# Only the "add" is timed; the previous worktree is removed in the
# untimed setup step of each iteration.
for workers in 1 0
do
	test_perf "worktree add --reflink=never, checkout.workers=$workers" \
		--setup 'rm -rf wt && git worktree prune' "
		git -c checkout.workers=$workers worktree add --detach \
			--reflink=never wt
	"

	test_perf "worktree add --reflink=always, checkout.workers=$workers" \
		--prereq REFLINK --setup 'rm -rf wt && git worktree prune' "
		git -c checkout.workers=$workers worktree add --detach \
			--reflink=always wt
	"
done

test_done
