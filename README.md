# Jupiter Buildkite Plugin

Run a component build inside a writable Btrfs snapshot of the Jupiter multi-repo.
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

## How It Works

1. `pre-checkout` snapshots the published Jupiter subvolume into
   `<original-checkout>/jupiter`, exports `JUPITER_ROOT`, and redirects Buildkite's
   normal checkout to `<original-checkout>/app`.
2. Buildkite checks out the component using its normal credentials and checkout
   settings. The plugin does not replace Buildkite's checkout implementation.
3. `post-checkout` matches that checkout's `origin` URL against Jupiter's
   `.gitmodules`. SSH, SCP-style SSH, HTTP(S), and Git URLs are normalized so
   differing transports and SSH ports can identify the same repository.
4. The helper fetches the exact component `HEAD` through a local `ci-app` remote
   and checks it out detached in the matching submodule. This also transfers
   Gerrit patchset commits that are not reachable from a branch.
5. The hook changes into the integrated component, updates
   `BUILDKITE_BUILD_CHECKOUT_PATH`, and removes the temporary app checkout. If
   integration fails, the temporary checkout is retained for diagnosis.

The snapshot's other repositories and the parent gitlink remain unchanged. The
plugin does not recursively update the tested component's nested submodules.
The `ci-app` remote is retained for reuse but points to the now-removed temporary
checkout; it is not an upstream remote for subsequent fetches.

The build workspace is retained after the job for diagnostics and normal agent
workspace management. On reuse, the plugin deletes the old `jupiter` Btrfs
subvolume and replaces it with a fresh snapshot, and resets the temporary `app`
directory. These two names are reserved for the plugin; other files in the
original checkout directory are left alone. No post-job cleanup hook is added.

## Configuration

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `snapshot-path` | string | `BUILDKITE_JUPITER_SNAPSHOT_PATH` environment variable | Absolute path to an existing published Jupiter Btrfs subvolume. |

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

- A self-hosted Linux agent with Bash, Git, Guile, Btrfs tools, and GNU coreutils
  (including `realpath`) on `PATH`. Component build tools and environment loading
  are configured separately.
- A populated, writable-snapshot-capable Jupiter Btrfs subvolume, with initialized
  submodules and `.gitmodules`. The source and agent checkout paths must be on
  the same Btrfs filesystem, must not overlap, and the agent user must have
  permission to create and delete snapshots. Submodule Git metadata must be
  self-contained in the snapshot, not linked to paths outside it.
- An absolute, agent-managed checkout path, not shared by concurrent jobs.
  Checkout must be enabled. Reference this plugin remotely, not as a vendored
  relative-path plugin, because preparation must run before checkout.
- The component's origin must match a top-level Jupiter submodule. Do not use
  this plugin for the Jupiter super-repository itself or its snapshot publisher.
- Normal agent credentials and fetch settings must make the requested revision
  available to Buildkite. Gerrit triggering and fetching `refs/changes/...` remain
  the responsibility of the existing Gerrit/agent integration; this plugin
  transfers the revision only after Buildkite has checked it out.

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

Add the plugin explicitly to the component's upload and build steps. Do not
apply it globally or to the snapshot-publishing pipeline. No existing pipelines
are changed by this migration.

Replace the old agent `environment` hook with the separate `jupitercloud/direnv`
plugin on steps that need it, following the ordering described above.

## Local Checks

```bash
bash tests/run.sh
```

The tests use disposable local Git repositories and mocked Btrfs commands.
They require Bash, Git, Guile, and coreutils, but no running agent, real Btrfs
operations, or network access. Real-agent end-to-end validation is a separate
manual step using a component pipeline.
