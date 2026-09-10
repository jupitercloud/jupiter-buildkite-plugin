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

Each hook is sourced in a separate Bash process. Tests inspect exported variables
and cwd. The sudo mock accepts only `sudo -n /run/current-system/profile/bin/btrfs`
and routes it to the Btrfs mock, never to the real sudo or Btrfs binary. Direct
Btrfs calls are rejected. The Btrfs mock copies fixture directories instead of making snapshots;
it accepts writable snapshots and deletion within the current test fixture.
It rejects `subvolume show` with a permission error to model an unprivileged agent.
The mock can fail deliberately to test status propagation. The post-checkout
success test includes an `.envrc` and rejects any direnv invocation to ensure
environment loading remains separate. The hooks are tested individually, not
as an end-to-end pipeline.
