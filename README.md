# Jupiter Buildkite Plugin

Run a component or root repository build inside a writable Btrfs snapshot of the
Jupiter multi-repo.
This provides the sibling repositories, Guix channels, and `JUPITER_ROOT` layout
that component builds need, without cloning the entire multi-repo for each job.

## Usage

Add this plugin to every command step that needs the Jupiter layout, including
any initial step that uploads a component's pipeline:

```yaml
steps:
  - label: Build
    command: bb build
    plugins:
      - jupitercloud/jupiter#<commit-sha>:
          snapshot-path: /home/buildkite/snapshots/jupiter
```

Replace `<commit-sha>` with a published plugin commit. No release tag is assumed.
The `snapshot-path` option can be omitted when `BUILDKITE_JUPITER_SNAPSHOT_PATH`
is set in the pipeline environment or agent environment. Uploaded steps must declare the
plugin themselves; they do not inherit it from the upload step.

For builds of the Jupiter root repository, set `root-repo: true`:

```yaml
steps:
  - label: Build Jupiter
    command: bb build
    plugins:
      - jupitercloud/jupiter#<commit-sha>:
          snapshot-path: /home/buildkite/snapshots/jupiter
          root-repo: true
```

This uses the fresh checkout as a local upstream, fetches its exact `HEAD`, and
checks it out detached in the snapshot root. Build commands then run at
`JUPITER_ROOT` with `BUILDKITE_BUILD_CHECKOUT_PATH` pointing there.

## How It Works

1. `pre-checkout` snapshots the published Jupiter subvolume into
   `<original-checkout>/jupiter`, clears all other contents of the original
   checkout directory, exports `JUPITER_ROOT`, and redirects Buildkite's normal
   checkout to `<original-checkout>/app`.
2. Buildkite checks out the repository using its normal credentials and checkout
   settings. The plugin does not replace Buildkite's checkout implementation.
3. `post-checkout` matches that checkout's `origin` URL against Jupiter's
   `.gitmodules` (or selects the snapshot root when `root-repo: true`).
   SSH, SCP-style SSH, HTTP(S), and Git URLs are normalized so
   differing transports and SSH ports can identify the same repository.
4. The helper fetches the exact checkout `HEAD` through a local `ci-app` remote
   and checks it out detached in the matching submodule or snapshot root. This
   also transfers Gerrit patchset commits that are not reachable from a branch.
5. The hook changes into the integrated repository, updates
   `BUILDKITE_BUILD_CHECKOUT_PATH`, and removes the temporary app checkout. If
   integration fails, the temporary checkout is retained for diagnosis.

In component mode, the snapshot's other repositories and the parent gitlink
remain unchanged. In root mode, root files and gitlinks follow the tested commit,
while populated submodule working trees retain their snapshot revisions.
Neither mode recursively updates submodules.
The `ci-app` remote is retained for reuse but points to the now-removed temporary
checkout; it is not an upstream remote for subsequent fetches.

The original checkout directory is a disposable, plugin-managed workspace. On
each preparation, the plugin deletes the old `jupiter` Btrfs subvolume and creates
a fresh snapshot. Only after snapshot creation succeeds does it remove every
other entry, including hidden files, old Git metadata, environment files, and
the temporary `app` checkout. This prevents an old outer repository from
surrounding the snapshot and interfering with repository/environment discovery.
Snapshot creation failure preserves those outer workspace contents.

After preparation the layout is:

```text
<original-checkout>/
├── app/                  # Fresh Buildkite checkout
└── jupiter/              # Populated snapshot
    └── components/
```

Integration removes `app/` on success. The build workspace is retained after the
job for diagnostics and normal agent workspace management.

## Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `snapshot-path` | string | `BUILDKITE_JUPITER_SNAPSHOT_PATH` environment variable | Absolute path to an existing published Jupiter Btrfs subvolume. |
| `root-repo` | boolean | `false` | Fetch and check out the tested commit in the snapshot root instead of matching a submodule. |

An explicit `snapshot-path` takes precedence over `BUILDKITE_JUPITER_SNAPSHOT_PATH`.
There is no hard-coded snapshot location: if neither provides a non-empty value,
the plugin aborts before changing the workspace.

## Environment Loading

This plugin does not load `.envrc` or invoke direnv. Use the separate
`jupitercloud/direnv` plugin for environment loading, and ensure Jupiter's
`post-checkout` runs first so direnv loads from the integrated component.
On agent v3, declare Jupiter before direnv. On agent v4, declare direnv before
Jupiter because post-checkout hooks run in reverse declaration order, unless
`legacy-post-hook-order` is enabled. Other checkout/environment plugins must also
respect the relocation and must not replace the workspace after integration.

## Agent Requirements

- A self-hosted Linux agent with Bash, Git, Guile, sudo, and GNU coreutils
  (including `realpath`) on `PATH`, and Btrfs installed at
  `/run/current-system/profile/bin/btrfs`. Component build tools and environment
  loading are configured separately.
- A populated, writable-snapshot-capable Jupiter Btrfs subvolume, with initialized
  submodules and `.gitmodules`. The source and agent checkout paths must be on
  the same Btrfs filesystem and must not overlap. Snapshot creation and deletion
  run through `sudo -n /run/current-system/profile/bin/btrfs`, using the agent's
  passwordless sudo authorization; all other operations run as the agent user.
  The snapshot contents must be owned/writable as required by the agent user:
  sudo does not change the ownership of the source tree's files.
  The plugin does not use `btrfs subvolume show`, whose metadata searches can
  require administrative privileges even when snapshot creation is permitted.
  Submodule Git metadata must be self-contained in the snapshot, not linked to
  paths outside it.
- An absolute, agent-managed checkout path, not shared by concurrent jobs.
  All contents are disposable; store persistent files outside this directory.
  Checkout must be enabled. Reference this plugin remotely, not as a vendored
  relative-path plugin, because preparation must run before checkout.
- The component's origin must match a top-level Jupiter submodule, unless
  `root-repo: true` is set for the Jupiter super-repository. Root mode does not
  require an origin URL or `.gitmodules` for integration.
- Normal agent credentials and fetch settings must make the requested revision
  available to Buildkite. Gerrit triggering and fetching `refs/changes/...` remain
  the responsibility of the existing Gerrit/agent integration; this plugin
  transfers the revision only after Buildkite has checked it out.

The existing Jupiter agent sudoers rule authorizes these commands:

```sudoers
buildkite ALL=(root) NOPASSWD: /run/current-system/profile/bin/btrfs *
```

No additional sudo permissions are required. The `-n` flag prevents password
prompts; authorization failures abort the hook rather than waiting for input.

The plugin is designed for a single-host agent job, not Kubernetes stacks with
separate checkout/command containers and non-persistent hook environments.

The snapshot publisher (`ci/scripts/snapshot.sh` in Jupiter) remains independent.
It serializes publishers and atomically exchanges the published snapshot, so
readers do not need its lock. Each job uses the snapshot published when it starts;
different steps can therefore see different sibling revisions.

## Migrating Agent Hooks

Remove the old Jupiter `environment`, `pre-checkout`, `post-checkout`, and
`integrate-submodule.scm` files from the agent's configured hooks directory before
enabling the plugin. Running both would prepare/integrate the workspace twice.
Deploying this repository does not remove previously copied agent hooks.

Add the plugin explicitly to upload and build steps that need the Jupiter
snapshot layout, setting `root-repo: true` for root repository steps.
No existing pipelines are changed by this migration.

Replace the old agent `environment` hook with the separate `jupitercloud/direnv`
plugin on steps that need it, following the ordering described above.

## Local Checks

```bash
bash tests/run.sh
```

The tests use disposable local Git repositories and mocked sudo/Btrfs commands.
They require Bash, Git, Guile, and coreutils, but no running agent, real Btrfs
operations, or network access. Real-agent end-to-end validation is a separate
manual step using a component pipeline.
