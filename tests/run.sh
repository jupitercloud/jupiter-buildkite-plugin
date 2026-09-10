#!/usr/bin/env bash
# Local regression tests. No Buildkite agent, network, or Btrfs is used.
set -euo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PLUGIN_DIR=$(cd -- "$TESTS_DIR/.." && pwd -P)
export PLUGIN_DIR

for command in bash git guile mktemp realpath cp rm mkdir cmp env; do
    command -v "$command" >/dev/null || {
        printf 'Missing required command: %s\n' "$command" >&2
        exit 1
    }
done
for file in hooks/pre-checkout hooks/post-checkout lib/integrate-submodule.scm lib/integrate-root.scm; do
    if [[ ! -f "$PLUGIN_DIR/$file" ]]; then
        printf 'Missing plugin implementation: %s\n' "$PLUGIN_DIR/$file" >&2
        exit 1
    fi
done

SUITE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jupiter-plugin-tests.XXXXXX")
trap 'rm -rf -- "$SUITE_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Ignore the host's Git identity/configuration and prohibit network transports.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Plugin Test' GIT_AUTHOR_EMAIL=plugin-test@example.invalid
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=file
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
unset BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH
unset BUILDKITE_PLUGIN_JUPITER_ROOT_REPO
unset BUILDKITE_JUPITER_SNAPSHOT_PATH
unset BUILDKITE_BUILD_CHECKOUT_PATH JUPITER_ROOT BASH_ENV ENV
export PATH="$TESTS_DIR/mocks:$PATH"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "expected [$1], got [$2]${3:+ ($3)}"
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

assert_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "path should not exist: $1"
}

assert_empty() {
    [[ ! -s "$1" ]] || fail "expected empty output: $1"
}

assert_line() {
    local expected=$1 file=$2 line
    while IFS= read -r line; do
        [[ "$line" != "$expected" ]] || return 0
    done < "$file"
    fail "missing line [$expected] in $file"
}

assert_log() {
    local expected
    printf -v expected '%q ' "$@"
    assert_line "$expected" "$TEST_MOCK_LOG"
}

assert_raw_path() {
    cmp -s <(printf '%s\n' "$1") "$TEST_CASE_DIR/stdout" ||
        fail 'helper stdout must contain only the absolute path and newline'
}

capture() {
    # Deliberately do not enable errexit in the hook's shell: its return status
    # must report failures without relying on the caller's shell options.
    if "$@" >"$TEST_CASE_DIR/stdout" 2>"$TEST_CASE_DIR/stderr"; then
        CAPTURE_STATUS=0
    else
        CAPTURE_STATUS=$?
    fi
}

assert_success() {
    if (( CAPTURE_STATUS != 0 )); then
        cat "$TEST_CASE_DIR/stderr" >&2
        fail "command exited $CAPTURE_STATUS"
    fi
}

assert_failure() {
    (( CAPTURE_STATUS != 0 )) || fail 'command unexpectedly succeeded'
}

setup_case() {
    export TEST_CASE_DIR TEST_MOCK_LOG
    TEST_CASE_DIR=$(mktemp -d "$SUITE_DIR/case.XXXXXX")
    TEST_MOCK_LOG="$TEST_CASE_DIR/mock.log"
    : > "$TEST_MOCK_LOG"
    export HOME="$TEST_CASE_DIR/home" XDG_CONFIG_HOME="$TEST_CASE_DIR/home/.config"
    mkdir -p -- "$XDG_CONFIG_HOME"
    unset TEST_BTRFS_FAIL TEST_SUDO_FAIL TEST_BTRFS_VIA_SUDO
}

make_fixture() {
    local subpath=${1:-components/app}
    APP="$TEST_CASE_DIR/app"
    ROOT="$TEST_CASE_DIR/jupiter"
    SUB="$ROOT/$subpath"
    export APP ROOT SUB
    git init -q -b main "$APP"
    printf 'base\n' > "$APP/tracked.txt"
    git -C "$APP" add tracked.txt
    git -C "$APP" commit -qm base
    git -C "$APP" remote add origin git@EXAMPLE.invalid:Team/app.git
    git init -q -b main "$ROOT"
    git -C "$ROOT" -c protocol.file.allow=always submodule add -q "$APP" "$subpath"
    git -C "$ROOT" config -f .gitmodules "submodule.$subpath.url" https://example.invalid/Team/app.git
    git -C "$ROOT" add .gitmodules "$subpath"
    git -C "$ROOT" commit -qm 'Add local submodule'
    BASE_HEAD=$(git -C "$SUB" rev-parse HEAD)
}

detached_commit() {
    git -C "$APP" checkout -q --detach
    printf 'detached change\n' > "$APP/tracked.txt"
    git -C "$APP" add tracked.txt
    git -C "$APP" commit -qm 'Detached commit with no branch'
    APP_HEAD=$(git -C "$APP" rev-parse HEAD)
    assert_equal '' "$(git -C "$APP" for-each-ref --contains="$APP_HEAD" --format='%(refname)' refs/heads/)"
    if git -C "$SUB" cat-file -e "$APP_HEAD^{commit}" 2>/dev/null; then
        fail 'fixture already contains the detached commit'
    fi
}

run_helper() {
    capture guile --no-auto-compile "$PLUGIN_DIR/lib/integrate-submodule.scm" "$APP" "$ROOT"
}

source_hook() {
    capture bash --noprofile --norc -c '
        cd -- "$TEST_CASE_DIR" || exit
        source "$PLUGIN_DIR/hooks/$1"
        status=$?
        env > "$TEST_CASE_DIR/hook.env"
        pwd -P > "$TEST_CASE_DIR/hook.cwd"
        exit "$status"
    ' bash "$1"
}

setup_pre() {
    CHECKOUT="$TEST_CASE_DIR/checkout with spaces"
    SNAPSHOT="$TEST_CASE_DIR/snapshot with spaces"
    mkdir -p -- "$CHECKOUT" "$SNAPSHOT"
    printf 'snapshot contents\n' > "$SNAPSHOT/snapshot-marker"
    printf 'unrelated checkout data\n' > "$CHECKOUT/keep-me"
    export BUILDKITE_BUILD_CHECKOUT_PATH="$CHECKOUT"
    export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$SNAPSHOT"
}

setup_post() {
    make_fixture 'components/app with spaces'
    export BUILDKITE_BUILD_CHECKOUT_PATH="$APP" JUPITER_ROOT="$ROOT"
    printf 'exit 99\n' > "$SUB/.envrc"
    printf 'unrelated checkout data\n' > "$TEST_CASE_DIR/keep-me"
}

setup_root() {
    make_fixture "${1:-components/app with spaces}"
    printf 'base\n' > "$ROOT/tracked.txt"
    git -C "$ROOT" add tracked.txt
    git -C "$ROOT" commit -qm 'Root base'
    ROOT_HEAD=$(git -C "$ROOT" rev-parse HEAD)
    # The snapshot's component has advanced beyond the root's recorded gitlink.
    printf 'snapshot component\n' > "$SUB/tracked.txt"
    git -C "$SUB" commit -qam 'Snapshot component revision'
    SNAPSHOT_SUB_HEAD=$(git -C "$SUB" rev-parse HEAD)
    APP="$TEST_CASE_DIR/root checkout with spaces"
    git clone -q "$ROOT" "$APP"
    git -C "$APP" remote set-url origin https://git.example.invalid/jupiter/jupiter
    detached_commit
    git -C "$ROOT" config submodule.recurse true
    export BUILDKITE_BUILD_CHECKOUT_PATH="$APP" JUPITER_ROOT="$ROOT"
    export BUILDKITE_PLUGIN_JUPITER_ROOT_REPO=true
}

assert_root_integrated() {
    assert_equal "$APP_HEAD" "$(git -C "$ROOT" rev-parse HEAD)"
    assert_equal 'detached change' "$(< "$ROOT/tracked.txt")"
    assert_equal "$SNAPSHOT_SUB_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
    assert_equal 'snapshot component' "$(< "$SUB/tracked.txt")"
    if git -C "$ROOT" symbolic-ref -q HEAD; then
        fail 'integrated root HEAD must be detached'
    fi
}

test_root_helper() {
    setup_root
    if [[ "$1" == existing-remote ]]; then
        git -C "$ROOT" remote add ci-app "$TEST_CASE_DIR/stale-checkout"
    fi
    capture guile --no-auto-compile "$PLUGIN_DIR/lib/integrate-root.scm" "$APP" "$ROOT"
    assert_success
    assert_raw_path "$ROOT"
    assert_root_integrated
    assert_equal "$APP" "$(git -C "$ROOT" remote get-url ci-app)"
    assert_file "$APP/tracked.txt"
}

test_root_without_submodules() {
    APP="$TEST_CASE_DIR/root checkout"
    ROOT="$TEST_CASE_DIR/snapshot root"
    git init -q -b main "$APP"
    printf 'base\n' > "$APP/tracked.txt"
    git -C "$APP" add tracked.txt
    git -C "$APP" commit -qm base
    git clone -q "$APP" "$ROOT"
    git -C "$APP" checkout -q --detach
    printf 'new root\n' > "$APP/tracked.txt"
    git -C "$APP" commit -qam 'Root revision'
    capture guile --no-auto-compile "$PLUGIN_DIR/lib/integrate-root.scm" "$APP" "$ROOT"
    assert_success
    assert_raw_path "$ROOT"
    assert_equal "$(git -C "$APP" rev-parse HEAD)" "$(git -C "$ROOT" rev-parse HEAD)"
    assert_equal 'new root' "$(< "$ROOT/tracked.txt")"
}

test_post_root() {
    setup_root
    source_hook post-checkout
    assert_success
    assert_root_integrated
    assert_line "BUILDKITE_BUILD_CHECKOUT_PATH=$ROOT" "$TEST_CASE_DIR/hook.env"
    assert_line "JUPITER_ROOT=$ROOT" "$TEST_CASE_DIR/hook.env"
    assert_equal "$ROOT" "$(< "$TEST_CASE_DIR/hook.cwd")"
    assert_absent "$APP"
    assert_empty "$TEST_MOCK_LOG"
}

test_post_root_failure() {
    setup_root
    printf 'uncommitted root work\n' > "$ROOT/tracked.txt"
    source_hook post-checkout
    assert_failure
    assert_file "$APP/tracked.txt"
    assert_equal "$APP_HEAD" "$(git -C "$ROOT" rev-parse FETCH_HEAD)" 'fetch succeeded before checkout failed'
    assert_equal "$ROOT_HEAD" "$(git -C "$ROOT" rev-parse HEAD)"
    assert_equal 'uncommitted root work' "$(< "$ROOT/tracked.txt")"
    assert_equal "$SNAPSHOT_SUB_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
}

test_helper_normalization() {
    make_fixture
    git -C "$APP" remote set-url origin "$1"
    git -C "$ROOT" config -f .gitmodules submodule.components/app.url "$2"
    run_helper
    assert_success
    assert_raw_path "$SUB"
    assert_equal "$BASE_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
}

test_helper_detached() {
    make_fixture
    detached_commit
    run_helper
    assert_success
    assert_raw_path "$SUB"
    assert_equal "$APP_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
    assert_equal 'detached change' "$(< "$SUB/tracked.txt")"
    if git -C "$SUB" symbolic-ref -q HEAD; then
        fail 'integrated HEAD must be detached'
    fi
    assert_file "$APP/tracked.txt"
}

test_helper_spaces() {
    make_fixture 'components/app with spaces'
    run_helper
    assert_success
    assert_raw_path "$SUB"
}

test_helper_unmatched() {
    make_fixture
    git -C "$APP" remote set-url origin https://example.invalid/Team/other.git
    run_helper
    assert_failure
    assert_empty "$TEST_CASE_DIR/stdout"
    assert_file "$APP/tracked.txt"
    assert_equal "$BASE_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
    assert_equal origin "$(git -C "$SUB" remote)"
}

test_helper_checkout_failure() {
    make_fixture
    detached_commit
    printf 'uncommitted work\n' > "$SUB/tracked.txt"
    run_helper
    assert_failure
    assert_empty "$TEST_CASE_DIR/stdout"
    assert_equal 'uncommitted work' "$(< "$SUB/tracked.txt")"
    assert_equal "$BASE_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
    assert_equal "$APP_HEAD" "$(git -C "$APP" rev-parse HEAD)"
}

test_helper_escape() {
    local kind=$1
    make_fixture
    # A similarly prefixed sibling catches naive string-prefix containment.
    OUTSIDE="$ROOT-outside"
    git clone -q "$APP" "$OUTSIDE"
    if [[ "$kind" == symlink ]]; then
        ln -s -- "$OUTSIDE" "$ROOT/escape"
        git -C "$ROOT" config -f .gitmodules submodule.components/app.path escape
    else
        git -C "$ROOT" config -f .gitmodules submodule.components/app.path ../jupiter-outside
    fi
    run_helper
    assert_failure
    assert_empty "$TEST_CASE_DIR/stdout"
    assert_equal origin "$(git -C "$OUTSIDE" remote)" 'must reject before configuring ci-app'
    assert_equal "$BASE_HEAD" "$(git -C "$OUTSIDE" rev-parse HEAD)"
    assert_file "$APP/tracked.txt"
}

test_helper_self_path() {
    make_fixture
    git -C "$ROOT" config -f .gitmodules submodule.components/app.path .
    local root_head
    root_head=$(git -C "$ROOT" rev-parse HEAD)
    run_helper
    assert_failure
    assert_empty "$TEST_CASE_DIR/stdout"
    assert_equal '' "$(git -C "$ROOT" remote)"
    assert_equal "$root_head" "$(git -C "$ROOT" rev-parse HEAD)"
}

test_pre_success() {
    setup_pre
    source_hook pre-checkout
    assert_success
    assert_file "$CHECKOUT/jupiter/snapshot-marker"
    [[ -d "$CHECKOUT/app" ]] || fail 'temporary app checkout was not created'
    assert_absent "$CHECKOUT/keep-me"
    assert_file "$SNAPSHOT/snapshot-marker"
    assert_log btrfs subvolume snapshot "$SNAPSHOT" "$CHECKOUT/jupiter"
    assert_line "JUPITER_ROOT=$CHECKOUT/jupiter" "$TEST_CASE_DIR/hook.env"
    assert_log sudo -n /run/current-system/profile/bin/btrfs subvolume snapshot "$SNAPSHOT" "$CHECKOUT/jupiter"
    assert_line "BUILDKITE_BUILD_CHECKOUT_PATH=$CHECKOUT/app" "$TEST_CASE_DIR/hook.env"
}

test_pre_snapshot_environment() {
    setup_pre
    export BUILDKITE_JUPITER_SNAPSHOT_PATH="$SNAPSHOT"
    unset BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH
    if [[ "$1" == empty-option ]]; then
        export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH=''
    fi
    source_hook pre-checkout
    assert_success
    assert_log btrfs subvolume snapshot "$SNAPSHOT" "$CHECKOUT/jupiter"
}

test_pre_snapshot_precedence() {
    setup_pre
    export BUILDKITE_JUPITER_SNAPSHOT_PATH="$TEST_CASE_DIR/nonexistent-snapshot"
    source_hook pre-checkout
    assert_success
    assert_log btrfs subvolume snapshot "$SNAPSHOT" "$CHECKOUT/jupiter"
}

test_pre_snapshot_missing() {
    setup_pre
    unset BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH BUILDKITE_JUPITER_SNAPSHOT_PATH
    if [[ "$1" == empty ]]; then
        export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH='' BUILDKITE_JUPITER_SNAPSHOT_PATH=''
    fi
    source_hook pre-checkout
    assert_failure
    [[ "$(< "$TEST_CASE_DIR/stderr")" == *'Set the Jupiter plugin snapshot-path option or BUILDKITE_JUPITER_SNAPSHOT_PATH'* ]] ||
        fail 'missing snapshot configuration diagnostic'
    assert_empty "$TEST_MOCK_LOG"
    assert_file "$CHECKOUT/keep-me"
    assert_absent "$CHECKOUT/jupiter"
    assert_absent "$CHECKOUT/app"
}

test_pre_existing() {
    setup_pre
    mkdir -p -- "$CHECKOUT/jupiter" "$CHECKOUT/app"
    printf 'old snapshot\n' > "$CHECKOUT/jupiter/stale"
    printf 'old checkout\n' > "$CHECKOUT/app/stale"
    source_hook pre-checkout
    assert_success
    assert_log btrfs subvolume delete "$CHECKOUT/jupiter"
    assert_log sudo -n /run/current-system/profile/bin/btrfs subvolume delete "$CHECKOUT/jupiter"
    assert_log btrfs subvolume snapshot "$SNAPSHOT" "$CHECKOUT/jupiter"
    assert_absent "$CHECKOUT/jupiter/stale"
    assert_absent "$CHECKOUT/app/stale"
    assert_file "$CHECKOUT/jupiter/snapshot-marker"
    assert_absent "$CHECKOUT/keep-me"
}

setup_stale_workspace() {
    setup_root components/guix
    SNAPSHOT="$ROOT"
    CHECKOUT="$TEST_CASE_DIR/checkout with spaces"
    export SNAPSHOT CHECKOUT
    git clone -q "$SNAPSHOT" "$CHECKOUT"
    # Model the competing environment/project files in the failed job's layout.
    local file
    for file in .envrc .envrc.root project.scm; do
        printf 'snapshot environment\n' > "$SNAPSHOT/$file"
        printf 'stale environment\n' > "$CHECKOUT/$file"
    done
    export BUILDKITE_BUILD_CHECKOUT_PATH="$CHECKOUT"
    export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$SNAPSHOT"
}

assert_clean_workspace() {
    local entry
    for entry in "$CHECKOUT"/* "$CHECKOUT"/.[!.]* "$CHECKOUT"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "$entry" in
            "$CHECKOUT/jupiter"|"$CHECKOUT/app") ;;
            *) fail "stale outer workspace entry: $entry" ;;
        esac
    done
}

test_pre_stale_workspace() {
    setup_stale_workspace
    source_hook pre-checkout
    assert_success
    assert_clean_workspace
    assert_file "$CHECKOUT/jupiter/.git/HEAD"
    assert_file "$CHECKOUT/jupiter/.envrc"
    assert_file "$CHECKOUT/jupiter/.envrc.root"
    assert_file "$CHECKOUT/jupiter/project.scm"
    assert_equal "$SNAPSHOT_SUB_HEAD" "$(git -C "$CHECKOUT/jupiter/components/guix" rev-parse HEAD)"
    assert_file "$SNAPSHOT/.git/HEAD"
}

test_pre_stale_workspace_failure() {
    setup_stale_workspace
    export TEST_BTRFS_FAIL=snapshot
    source_hook pre-checkout
    assert_failure
    assert_equal "$ROOT_HEAD" "$(git -C "$CHECKOUT" rev-parse HEAD)"
    assert_file "$CHECKOUT/.envrc"
    assert_file "$CHECKOUT/.envrc.root"
    assert_file "$CHECKOUT/project.scm"
    [[ -d "$CHECKOUT/components/guix" ]] || fail 'old submodule directory was removed'
    assert_absent "$CHECKOUT/jupiter"
    assert_absent "$CHECKOUT/app"
}

test_pre_cleanup_symlinks() {
    setup_pre
    ln -s -- "$SNAPSHOT" "$CHECKOUT/snapshot-link"
    ln -s -- "$SNAPSHOT" "$CHECKOUT/.hidden-link"
    ln -s -- "$TEST_CASE_DIR/nonexistent" "$CHECKOUT/dangling-link"
    mkdir -p -- "$CHECKOUT/..hidden" "$CHECKOUT/jupiter-old"
    source_hook pre-checkout
    assert_success
    assert_clean_workspace
    assert_file "$SNAPSHOT/snapshot-marker"
    assert_file "$CHECKOUT/jupiter/snapshot-marker"
}

test_root_workspace_lifecycle() {
    setup_stale_workspace
    # Use both real hooks, with a local clone standing in for Buildkite checkout.
    capture bash --noprofile --norc -c '
        cd -- "$CHECKOUT" || exit
        source "$PLUGIN_DIR/hooks/pre-checkout"
        git clone -q "$APP" "$BUILDKITE_BUILD_CHECKOUT_PATH"
        source "$PLUGIN_DIR/hooks/post-checkout"
        env > "$TEST_CASE_DIR/hook.env"
        pwd -P > "$TEST_CASE_DIR/hook.cwd"
    '
    assert_success
    assert_clean_workspace
    ROOT="$CHECKOUT/jupiter"
    SUB="$ROOT/components/guix"
    assert_root_integrated
    assert_absent "$CHECKOUT/app"
    assert_file "$ROOT/.envrc"
    assert_file "$ROOT/project.scm"
    assert_line "JUPITER_ROOT=$ROOT" "$TEST_CASE_DIR/hook.env"
    assert_line "BUILDKITE_BUILD_CHECKOUT_PATH=$ROOT" "$TEST_CASE_DIR/hook.env"
    assert_equal "$ROOT" "$(< "$TEST_CASE_DIR/hook.cwd")"
}

test_pre_canonical_paths() {
    setup_pre
    ln -s -- "$CHECKOUT" "$TEST_CASE_DIR/checkout-link"
    ln -s -- "$SNAPSHOT" "$TEST_CASE_DIR/snapshot-link"
    export BUILDKITE_BUILD_CHECKOUT_PATH="$TEST_CASE_DIR/checkout-link/../checkout-link"
    export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$TEST_CASE_DIR/snapshot-link/."
    source_hook pre-checkout
    assert_success
    assert_log btrfs subvolume snapshot "$SNAPSHOT" "$CHECKOUT/jupiter"
    assert_line "JUPITER_ROOT=$CHECKOUT/jupiter" "$TEST_CASE_DIR/hook.env"
    assert_line "BUILDKITE_BUILD_CHECKOUT_PATH=$CHECKOUT/app" "$TEST_CASE_DIR/hook.env"
}

test_pre_invalid_checkout() {
    setup_pre
    export BUILDKITE_BUILD_CHECKOUT_PATH="$1"
    source_hook pre-checkout
    assert_failure
    assert_empty "$TEST_MOCK_LOG"
    assert_file "$CHECKOUT/keep-me"
    assert_file "$SNAPSHOT/snapshot-marker"
}

test_pre_overlap() {
    local kind=$1
    setup_pre
    case "$kind" in
        equal) export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$CHECKOUT" ;;
        source-inside)
            mkdir -p -- "$CHECKOUT/source"
            export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$CHECKOUT/source"
            ;;
        checkout-inside)
            export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$TEST_CASE_DIR"
            ;;
        symlink)
            ln -s -- "$CHECKOUT" "$TEST_CASE_DIR/source-link"
            export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$TEST_CASE_DIR/source-link"
            ;;
    esac
    source_hook pre-checkout
    assert_failure
    assert_empty "$TEST_MOCK_LOG"
    assert_file "$CHECKOUT/keep-me"
}

test_pre_invalid_snapshot() {
    setup_pre
    mkdir -p -- "$CHECKOUT/jupiter" "$CHECKOUT/app"
    printf 'existing snapshot\n' > "$CHECKOUT/jupiter/stale"
    printf 'existing checkout\n' > "$CHECKOUT/app/stale"
    if [[ "$1" == missing ]]; then
        export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$TEST_CASE_DIR/missing-snapshot"
    else
        export BUILDKITE_PLUGIN_JUPITER_SNAPSHOT_PATH="$SNAPSHOT/snapshot-marker"
    fi
    source_hook pre-checkout
    assert_failure
    assert_empty "$TEST_MOCK_LOG"
    assert_file "$CHECKOUT/jupiter/stale"
    assert_file "$CHECKOUT/app/stale"
    assert_file "$CHECKOUT/keep-me"
}

test_pre_sudo_failure() {
    setup_pre
    mkdir -p -- "$CHECKOUT/jupiter" "$CHECKOUT/app"
    printf 'existing snapshot\n' > "$CHECKOUT/jupiter/stale"
    printf 'existing checkout\n' > "$CHECKOUT/app/stale"
    export TEST_SUDO_FAIL=1
    source_hook pre-checkout
    assert_failure
    assert_log sudo -n /run/current-system/profile/bin/btrfs subvolume delete "$CHECKOUT/jupiter"
    assert_file "$CHECKOUT/jupiter/stale"
    assert_file "$CHECKOUT/app/stale"
    assert_file "$SNAPSHOT/snapshot-marker"
}

test_pre_btrfs_failure() {
    setup_pre
    export TEST_BTRFS_FAIL="$1"
    if [[ "$1" == delete ]]; then
        mkdir -p -- "$CHECKOUT/jupiter"
        printf 'existing snapshot\n' > "$CHECKOUT/jupiter/stale"
    fi
    source_hook pre-checkout
    assert_failure
    assert_file "$CHECKOUT/keep-me"
    assert_file "$SNAPSHOT/snapshot-marker"
    if [[ "$1" == delete ]]; then
        assert_file "$CHECKOUT/jupiter/stale"
    else
        assert_absent "$CHECKOUT/jupiter"
    fi
}

test_post_success() {
    setup_post
    if [[ "${1:-}" == explicit-false ]]; then
        export BUILDKITE_PLUGIN_JUPITER_ROOT_REPO=false
    fi
    direnv() { return 99; }
    export -f direnv
    detached_commit
    source_hook post-checkout
    assert_success
    assert_line "BUILDKITE_BUILD_CHECKOUT_PATH=$SUB" "$TEST_CASE_DIR/hook.env"
    assert_line "JUPITER_ROOT=$ROOT" "$TEST_CASE_DIR/hook.env"
    assert_equal "$SUB" "$(< "$TEST_CASE_DIR/hook.cwd")"
    assert_equal "$APP_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
    assert_absent "$APP"
    assert_file "$TEST_CASE_DIR/keep-me"
    assert_file "$SUB/.envrc"
    assert_empty "$TEST_MOCK_LOG"
}

test_post_helper_failure() {
    setup_post
    if [[ "$1" == unmatched ]]; then
        git -C "$APP" remote set-url origin https://example.invalid/Team/other.git
    else
        detached_commit
        printf 'uncommitted work\n' > "$SUB/tracked.txt"
    fi
    source_hook post-checkout
    assert_failure
    assert_file "$APP/tracked.txt"
    assert_file "$TEST_CASE_DIR/keep-me"
    assert_empty "$TEST_MOCK_LOG"
    assert_equal "$BASE_HEAD" "$(git -C "$SUB" rev-parse HEAD)"
    if [[ "$1" != unmatched ]]; then
        assert_equal 'uncommitted work' "$(< "$SUB/tracked.txt")"
    fi
    # A hook may exit the sourced shell on failure instead of returning.
    if [[ -f "$TEST_CASE_DIR/hook.env" ]]; then
        assert_line "BUILDKITE_BUILD_CHECKOUT_PATH=$APP" "$TEST_CASE_DIR/hook.env"
        assert_equal "$TEST_CASE_DIR" "$(< "$TEST_CASE_DIR/hook.cwd")"
    fi
}

passed=0
failed=0
run_test() {
    local name=$1 status
    shift
    # Do not put this subshell in an if/|| expression: that would disable
    # errexit throughout the test function and conceal setup/assertion errors.
    set +e
    (set -e; setup_case; "$@") > "$SUITE_DIR/test.log" 2>&1
    status=$?
    set -e
    if (( status == 0 )); then
        printf 'ok - %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'not ok - %s\n' "$name"
        cat "$SUITE_DIR/test.log"
        failed=$((failed + 1))
    fi
}

run_test 'helper: SCP-style SSH matches HTTPS' test_helper_normalization \
    git@EXAMPLE.invalid:Team/app.git https://example.invalid/Team/app.git
run_test 'helper: ssh:// matches HTTPS with userinfo' test_helper_normalization \
    ssh://git@EXAMPLE.invalid:2222/Team/app.git https://user@example.invalid/Team/app.git
run_test 'helper: HTTPS matches SSH without .git suffix' test_helper_normalization \
    https://example.invalid/Team/app git@example.invalid:Team/app.git
run_test 'helper: detached commit absent from every branch transfers' test_helper_detached
run_test 'helper: spaces remain literal in raw absolute stdout' test_helper_spaces
run_test 'helper: unmatched URL fails without stdout or mutation' test_helper_unmatched
run_test 'helper: failed checkout preserves local work and app' test_helper_checkout_failure
run_test 'helper: parent traversal rejected before Git sync' test_helper_escape traversal
run_test 'helper: symlink escape rejected before Git sync' test_helper_escape symlink
run_test 'helper: super-repository itself is not a submodule' test_helper_self_path
run_test 'root helper: detached root transfers while snapshot components stay populated' test_root_helper new-remote
run_test 'root helper: stale ci-app remote is updated' test_root_helper existing-remote
run_test 'root helper: no origin or .gitmodules required, paths with spaces' test_root_without_submodules
run_test 'pre-checkout: writable snapshot and exported paths without privileged inspection' test_pre_success
run_test 'pre-checkout: snapshot path falls back to environment' test_pre_snapshot_environment unset-option
run_test 'pre-checkout: empty snapshot option falls back to environment' test_pre_snapshot_environment empty-option
run_test 'pre-checkout: snapshot option overrides environment' test_pre_snapshot_precedence
run_test 'pre-checkout: missing snapshot configuration aborts safely' test_pre_snapshot_missing unset
run_test 'pre-checkout: empty snapshot configuration aborts safely' test_pre_snapshot_missing empty
run_test 'pre-checkout: replaces snapshot/app and clears outer workspace' test_pre_existing
run_test 'pre-checkout: removes stale outer repository and retains populated snapshot' test_pre_stale_workspace
run_test 'pre-checkout: snapshot failure preserves stale outer repository' test_pre_stale_workspace_failure
run_test 'pre-checkout: clears hidden entries and symlinks without following targets' test_pre_cleanup_symlinks
run_test 'root workspace: preparation and integration leave one populated root' test_root_workspace_lifecycle
run_test 'pre-checkout: canonicalizes symlink and dot paths' test_pre_canonical_paths
run_test 'pre-checkout: rejects relative checkout' test_pre_invalid_checkout relative/checkout
run_test 'pre-checkout: rejects root checkout' test_pre_invalid_checkout /
run_test 'pre-checkout: rejects empty checkout' test_pre_invalid_checkout ''
run_test 'pre-checkout: rejects identical source and checkout' test_pre_overlap equal
run_test 'pre-checkout: rejects source inside checkout' test_pre_overlap source-inside
run_test 'pre-checkout: rejects checkout inside source' test_pre_overlap checkout-inside
run_test 'pre-checkout: rejects overlap through symlink' test_pre_overlap symlink
run_test 'pre-checkout: snapshot failure propagates' test_pre_btrfs_failure snapshot
run_test 'pre-checkout: missing snapshot source preserves workspace' test_pre_invalid_snapshot missing
run_test 'pre-checkout: non-directory snapshot source preserves workspace' test_pre_invalid_snapshot file
run_test 'pre-checkout: deletion failure preserves existing snapshot' test_pre_btrfs_failure delete
run_test 'pre-checkout: sudo denial fails without deleting workspace' test_pre_sudo_failure
run_test 'post-checkout: integrates, exports, and changes cwd without loading .envrc' test_post_success
run_test 'post-checkout: root-repo false selects component integration' test_post_success explicit-false
run_test 'post-checkout: root-repo true integrates and exports snapshot root' test_post_root
run_test 'post-checkout: root checkout failure preserves app and local work' test_post_root_failure
run_test 'post-checkout: unmatched app is preserved on failure' test_post_helper_failure unmatched
run_test 'post-checkout: checkout failure preserves app and local work' test_post_helper_failure checkout

printf '\n%d passed; %d failed\n' "$passed" "$failed"
(( failed == 0 ))
