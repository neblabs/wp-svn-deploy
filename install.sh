#!/usr/bin/env bash

targetDir=${1:-$HOME/.local/bin}
targetFilePath=$targetDir/wp-svn-deploy


# first make sure the target dir exists
mkdir -p "$targetDir"

echo installing into "$targetFilePath"

set -e
curl -sSL  https://raw.githubusercontent.com/neblabs/wp-svn-deploy/main/wp-svn-deploy.sh -o "$targetFilePath"


sudo chmod +x "$targetFilePath"

# warn if not in path
if ! [[ "$targetDir" == *"/.local/bin"* ]]; then
    echo [warn] Installed to "$targetFilePath" but it "doesn't" seem to be in your PATH.
fi
