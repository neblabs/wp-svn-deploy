#!/usr/bin/env bash

function print-usage() {
	echo usage: "$0" "-slug slug -build dir -version n [--batch-size n] [--message message]" 1>&2
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
		buildDir=$(cd "$buildDir" && pwd)
		if ! [[ -d "$buildDir" ]]; then
			echo "-build not a directory: $buildDir" 1>&2
			exit 1
		fi
		;;
	-version)
		version="$2"
		fail-if-empty "$version"
		shift 2
		# remove v from the version should it have it.
		version=${version#[vV]}
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

if [[ -z "$SVN_USER" ]] || [[ -z "$SVN_PASS" ]]; then
	echo "SVN user credentials needed. The environment needs to have the variables: SVN_USER and SVN_PASS" 1>&2
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

# ONLY checkout the specific tag to avoid downloading the entire history of the plugin.
# FIX: pass SVN_AUTH here too -- with --no-auth-cache in play there's nothing
# else for this checkout to fall back on, so without it this would prompt/hang.
svn co "$pluginDirSvnURI/$newTagDir" "$tmpSvnDir"/"$newTagDir" "${SVN_AUTH[@]}"

cd "$tmpSvnDir"

# then rsync the target dir onto the svn repo
#!IMPORTANT: note the / at the end of "$buildDir"/, that is needed because rsync treats it different with and without that slash.
rsync -rcvi --delete-delay --exclude='.svn/' "$buildDir"/ "$newTagDir"/
# rsync accepts a -n so like -rcvin if i need to dry run for previewing.
# then add changes to staging area
svn add "$newTagDir" --force --auto-props --parents -q

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Missing files (rsync removed them) show as '!' until scheduled for deletion.
# Trailing '@' escapes any path containing a literal '@' -- svn otherwise
# parses '@' as a peg-revision separator (e.g. aa_ER@saaho.php -> E200009).
svn status "$newTagDir" | awk '/^!/ {print $2 "@"}' > "$TMPDIR/delete_targets.txt"

if [[ -s "$TMPDIR/delete_targets.txt" ]]; then
	svn delete --targets "$TMPDIR/delete_targets.txt"
	# Commit deletions in one shot, unbatched. A directory scheduled for
	# deletion is always a single, atomic, whole-subtree operation -- svn
	# status never lists its children as separate targets, so this needs
	# the default --depth infinity to actually remove them. That's also
	# exactly why deletions aren't chunked the same way adds/mods are:
	# there's nothing to split, it's one operation per deleted root.
	svn commit --targets "$TMPDIR/delete_targets.txt" -m "$commitMessage (deletions)" "${SVN_AUTH[@]}"
fi

# Get the fresh state now that deletions are already committed and gone --
# this only contains adds/mods, which is exactly what the chunked,
# --depth empty commits below expect (no directory-deletion targets left
# to conflict with it).
#
# NOTE: no sort here, on purpose. svn status already lists a directory
# before its own children (a path always sorts as "less than" any longer
# string it's a prefix of). Sorting AFTER appending the trailing '@' would
# break that: comparing "newpkg@" vs "newpkg/File.php@", the deciding
# character is '/' (0x2F) vs '@' (0x40), and since '/' < '@', the child
# would sort BEFORE its own not-yet-existing parent directory.
svn status "$newTagDir" | awk '{print $2 "@"}' > "$TMPDIR/all_targets.txt"

TOTAL=$(wc -l < "$TMPDIR/all_targets.txt")
if [ "$TOTAL" -eq 0 ]; then
	echo "Nothing pending — working copy is clean."
	exit 0
fi
echo "Total pending paths: $TOTAL (batches of $batchSize)"

# Split into chunk files: chunk_aa, chunk_ab, chunk_ac, ...
split -l "$batchSize" "$TMPDIR/all_targets.txt" "$TMPDIR/chunk_"

n=1
for chunk in "$TMPDIR"/chunk_*; do
	if (( n != 1 )); then
		echo "-- sleeping 30 until the next batch, hold tight... --"
		sleep 30
	fi
	count=$(wc -l < "$chunk")
	echo "== Batch $n: committing $count paths =="
	svn commit --depth empty --targets "$chunk" -m "$commitMessage (part $n)" "${SVN_AUTH[@]}"
	echo "== Batch $n: DONE! =="
	n=$((n + 1))
done

echo "Done. All batches committed."
