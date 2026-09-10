# Local Regression Tests

Run from the plugin directory:

```bash
bash tests/run.sh
```

Requires Bash, Git, Guile, and coreutils. No sudo privileges, Bats, ShellCheck, Buildkite agent,
Btrfs filesystem, direnv installation, external fetch, or build is needed.

The runner creates disposable fixtures under `${TMPDIR:-/tmp}` and removes them
on exit. Git uses isolated configuration and only the `file` transport, so
SSH/HTTPS origin URLs are matching inputs, never network destinations.

The actual Scheme helper runs against local Git submodules, including a detached
commit absent from every branch and absent from the destination object database.
Coverage includes URL normalization, raw path output with spaces, unmatched URLs,
path containment, and preservation of local work after checkout failure.
Root integration coverage includes detached commits, new and stale local remotes,
repositories without an origin or `.gitmodules`, and retaining populated snapshot
components even when `submodule.recurse` is enabled. Hook tests exercise
`root-repo: true`, explicit `false`, root path exports, and failed root checkout.
Workspace tests reproduce a stale outer root checkout with empty submodules and
environment files. They verify its removal after snapshot creation, preservation
on snapshot failure, and cleanup of hidden files and symlinks without following
their targets. A lifecycle test runs both hooks with a simulated local Buildkite
checkout and checks the final cwd, exports, commit, and populated `components/guix`.

Each hook is sourced in a separate Bash process. Tests inspect exported variables
and cwd. The sudo mock accepts only `sudo -n /run/current-system/profile/bin/btrfs`
and routes it to the Btrfs mock, never to the real sudo or Btrfs binary. Direct
Btrfs calls are rejected. The Btrfs mock copies fixture directories instead of making snapshots;
it accepts writable snapshots and deletion within the current test fixture.
It rejects `subvolume show` with a permission error to model an unprivileged agent.
The mock can fail deliberately to test status propagation. The post-checkout
success test includes an `.envrc` and rejects any direnv invocation to ensure
environment loading remains separate. These are local hook tests, not a live
Buildkite/direnv end-to-end pipeline.
