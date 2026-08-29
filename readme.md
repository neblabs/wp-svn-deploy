# wp-svn-deploy

Deploys a build dir to a *new* tag with the given version to your plugin's WordPress repo using svn. Now instead of deploying to trunk, this will deploy it to a new tag. So you can test that the deployed build was uploaded correctly and without corruptions. After you have tested the new tag, you just have to cp the tag to the trunk and then it will be live.

### things to consider
- Will create a new tag with the given version. If the tag already exists it'll override it.
- It commits the files in batches of 500 by default. This is because in medium to large codebases (1,000+ or so files) the plugins repo will timeout and changes will not be committed. So this tool goes through a list of all the files changed ((A)dded, (M)odified, (R)emoved, etc) and it will commit them in batches. Waits 60s per commit to try to prevent rate-limiting.

## Installation

Run the installer

```bash
curl -L https://raw.githubusercontent.com/neblabs/wp-svn-deploy/main/install.sh | sh

## Usage

wp-snv-deploy -slug slug -build dir -version n -user svn-user -pass svn-password [--batch-size n] [--message message]

### Example usage

wp-snv-deploy -slug coupons-plus-for-woocommerce -build "$pluginBuildDir" -version 1.2.3 -user "$SVN_USERNAME" -pass "$SVN_PASSWORD"
