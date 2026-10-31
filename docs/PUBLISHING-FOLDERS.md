# Publishing a folder (no Git needed)

For people who keep their work in a plain folder, such as a Capstan project or Scrimshaw course
source, and want it on GitHub or GitLab without learning Git.

## Steps

1. Connect the project (Overview → paste the project address).
2. Type the folder's full path under **Or use a folder you already have**, optionally type a branch
   name under **Name your work branch**, and select **Publish this folder as a new work branch**.
   Gangplank creates the branch from the project's default branch and treats the folder as the
   workspace. Nothing from the folder is uploaded yet.
3. Under **Changes**, every file in the folder is listed as new. Review the list. Files Smart Save
   will not publish are marked **Excluded**: secret-looking names and content, links, and any file
   over 5 MB.
4. Select the files and use **Publish selected changes** (Smart Save). The safety checks are the usual
   ones (Sentinel scan, no force, audit log). Then **Create review request** if someone should look
   before it is merged.

The project's own files that are not in your folder are listed as deletions and are never selected
automatically, so publishing a folder does not remove anything.

## What to expect

- **Large exports.** A rendered video or other export over 5 MB is Excluded. Keep exports outside
  the published folder, or publish the project source only.
- **Folders Gangplank skips.** `.git`, `Logs`, `work`, `.vs` and `node_modules` are never offered.
- **Not the shared branch.** Publishing always starts a new work branch; Smart Save to the default
  branch stays disabled.
- **If you already have a clone** of the project, use **Use this folder** instead: Gangplank reads
  the branch and commit from the clone and shows only what you changed.

The folder layouts of Capstan and Scrimshaw are not special-cased; Gangplank treats both as plain
folders. This is tested against the synthetic GitHub with a fictional course folder
(`tests/e2e/host.e2e.mjs`, "publish a folder").
