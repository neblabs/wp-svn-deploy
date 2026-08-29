#!/usr/bin/env bash

function print-usage() {
	echo usage: "$0" "-slug slug -build dir -version n -user svn-user -pass svn-password [--batch-size n] [--message message]" 1>&2
}

function fail-if-empty() {
	if [[ -z "$1" ]]; then
		print-usage
		exit 1
	fi
}

commitMessage="Updated trunk"
batchSize=500

while [[ $# -gt 0 ]]; do
	case $1 in
	-slug)
		pluginSlug="$2"
		fail-if-empty "$pluginSlug"
		shift 2
		;;
	-build)
		buildDir="$2"
		fail-if-empty "$buildDir"
		shift 2
		;;
	-version)
		version="$2"
		fail-if-empty "$version"
		shift 2
		;;
	-user)
		SVN_USER="$2"
		fail-if-empty "$SVN_USER"
		shift 2
		;;
	-pass|-password)
		SVN_PASS="$2"
		fail-if-empty "$SVN_PASS"
		shift 2
		;;
	--batch-size)
		batchSize=$2
		fail-if-empty "$batchSize"
		shift 2
		;;
	--message)
		commitMessage=$2
		fail-if-empty "$commitMessage"
		shift 2
		;;
	*)
		print-usage
		exit 1
		;;
	esac
done

if [[ -z "$pluginSlug" ]] || [[ -z "$buildDir" ]] || [[ -z "$version" ]]; then
	print-usage
	exit 1
fi

tmpSvnDir=$(mktemp -d)

set -euo pipefail

# svn creds for use in commands that touch the remote.
SVN_AUTH=(--username "$SVN_USER" --password "$SVN_PASS" --no-auth-cache --non-interactive)

pluginDirSvnURI="https://plugins.svn.wordpress.org/$pluginSlug"
newTagDir="tags/$version"

# Delete the remote tag if it exists so we can cleanly override it. 
# "|| true" prevents set -e from killing the script if the tag doesn't exist.
svn delete "$pluginDirSvnURI/$newTagDir" -m "Removing existing $newTagDir for clean override" "${SVN_AUTH[@]}" 2>/dev/null || true
# first lets clone the trunk into the new-to-be tag from the server to prevent double downloads/uploads later when we update this.
svn copy "$pluginDirSvnURI"/trunk "$pluginDirSvnURI/$newTagDir" -m "Preparing new $newTagDir with old trunk" "${SVN_AUTH[@]}"

# ONLY checkout the specific tag to avoid downloading the entire history of the plugin
svn co "$pluginDirSvnURI/$newTagDir" "$tmpSvnDir"/"$newTagDir"

cd "$tmpSvnDir"

# then rsync the target dir onto the svn repo
#!IMPORTANT: note the / at the end of "$buildDir"/, that is needed because rsync treats it different with and without that slash.
rsync -rcvi --delete-delay --exclude='.svn/' "$buildDir"/ "$newTagDir"/
#rsync -rcvi --delete-delay --exclude='.svn/' "$buildDir/" "trunk/"

# then add changes to staging area
svn add "$newTagDir" --force --auto-props --parents -q

# schedule files for deletion (wrapped in an if-check to prevent xargs crashing on empty output)
DELETED=$(svn status "$newTagDir" | awk '/^!/ {print $2}')
if [[ -n "$DELETED" ]]; then
    echo "$DELETED" | sed 's/$/@/' | xargs svn delete
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Trailing '@' on every path: svn treats '@' in a path argument as the
# peg-revision separator (path@REV). Some vendor filenames genuinely
# contain '@' (e.g. aa_ER@saaho.php), which svn would otherwise try to
# parse as "path@bogus-revision" and fail with E200009. Appending a
# bare trailing '@' is a no-op for normal paths but tells svn "no peg
# revision, take everything before the last @ literally" for the rest.
svn status "$newTagDir" | awk '{print $2 "@"}' >"$TMPDIR/all_targets_unsorted.txt"
# lets sort the targets to make sure dirs always come first, crucial so that svn can handle updates with dirs first before their nested files
sort "$TMPDIR/all_targets_unsorted.txt" > "$TMPDIR/all_targets.txt"

TOTAL=$(wc -l <"$TMPDIR/all_targets.txt")
if [ "$TOTAL" -eq 0 ]; then
	echo "Nothing pending — working copy is clean."
	exit 0
fi
echo "Total pending paths: $TOTAL (batches of $batchSize)"

# Split into chunk files: chunk_aa, chunk_ab, chunk_ac, ...
split -l "$batchSize" "$TMPDIR/all_targets.txt" "$TMPDIR/chunk_"

n=1
for chunk in "$TMPDIR"/chunk_*; do
	count=$(wc -l <"$chunk")
	echo "== Batch $n: committing $count paths =="
	echo "$chunk"
	svn commit --depth empty --targets "$chunk" -m "$commitMessage (part $n)" "${SVN_AUTH[@]}"
	n=$((n + 1))
	sleep 60
done

echo "Done. All batches committed."
