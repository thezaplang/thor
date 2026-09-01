#!/usr/bin/env bash
# End-to-end tests for the zeus (thor) CLI itself.
#
# thor test / zap-test's TestContext only exercises code reachable from
# a Zap test file, and cross-file privacy in this compiler is strict
# (confirmed: a non-pub symbol is genuinely inaccessible from another
# file, not just a lint warning) -- see test/*.zp for what that covers.
# Most of thor's interesting logic (deps.zp's URL/thor.toml parsing
# helpers, testcmd.zp's test-file discovery, cli.zp's process.argv()
# parsing) lives in non-pub functions or reads process state directly,
# so it can only be verified by actually running the `thor` binary as a
# subprocess against real fixture projects and checking exit codes,
# stdout/stderr, and the filesystem -- which is what this script does.
#
# Network dependency: none required for the core suite. `thor add`/
# dependency restore is tested against local git repos created on the
# fly (git clone accepts a local path as the source, so this never
# touches the network). A couple of scenarios that specifically need a
# real GitHub URL are gated on a network probe and skipped (not failed)
# when offline.
#
# Usage: ./run_integration_tests.sh [-k KEEP_ON_FAILURE=1]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZEUS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
THOR_BIN="$ZEUS_ROOT/build/thor"
ZAPC_NOPIE="$ZEUS_ROOT/tools/zapc-no-pie"

PASS=0
FAIL=0
declare -a FAILED_DESCRIPTIONS=()

WORKDIR="$(mktemp -d)"
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
cleanup() {
    if [[ "$FAIL" -gt 0 && "$KEEP_ON_FAILURE" == "1" ]]; then
        echo "KEEP_ON_FAILURE=1: leaving $WORKDIR in place for inspection" >&2
    else
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# assertion helpers
# ---------------------------------------------------------------------

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_DESCRIPTIONS+=("$1"); echo "  FAIL: $1"; }
section() { echo; echo "--- $1 ---"; }

assert_eq() { # desc actual expected
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected [$3], got [$2])"; fi
}

assert_contains() { # desc haystack needle
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (expected to contain [$3] in: $2)"; fi
}

assert_not_contains() { # desc haystack needle
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (expected NOT to contain [$3] in: $2)"; fi
}

assert_exists() { # desc path
    if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (missing path: $2)"; fi
}

assert_absent() { # desc path
    if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (path unexpectedly exists: $2)"; fi
}

assert_executable_prints() { # desc path expected_substring
    local out
    out="$("$2" 2>&1)"
    assert_contains "$1" "$out" "$3"
}

# Runs $THOR_BIN with the given args from the current directory, capturing
# stdout/stderr/exit code into THOR_OUT / THOR_ERR / THOR_CODE.
run_thor() {
    local outfile errfile
    outfile="$(mktemp)"
    errfile="$(mktemp)"
    "$THOR_BIN" "$@" >"$outfile" 2>"$errfile"
    THOR_CODE=$?
    THOR_OUT="$(cat "$outfile")"
    THOR_ERR="$(cat "$errfile")"
    rm -f "$outfile" "$errfile"
}

# ---------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------

echo "Building zeus's own thor from current source..."
( cd "$ZEUS_ROOT" && ./build.sh >/tmp/zeus_integration_build.log 2>&1 )
if [[ ! -x "$THOR_BIN" ]]; then
    echo "FATAL: build.sh did not produce $THOR_BIN -- see /tmp/zeus_integration_build.log" >&2
    exit 1
fi

NETWORK_AVAILABLE=0
if timeout 5 curl -sI https://github.com >/dev/null 2>&1; then
    NETWORK_AVAILABLE=1
fi

mkgitfixture() { # mkgitfixture <dir>  -- inits a throwaway git repo in $dir with a commit
    git -C "$1" init -q
    git -C "$1" -c user.email=fixture@example.com -c user.name=fixture add -A
    git -C "$1" -c user.email=fixture@example.com -c user.name=fixture commit -q -m "initial"
}

# ---------------------------------------------------------------------
# 1. top-level: --version / --help / no-args / unknown command
# ---------------------------------------------------------------------

test_top_level() {
    section "top-level: --version / --help / no-args / unknown command"
    cd "$WORKDIR"

    run_thor --version
    assert_eq "--version exits 0" "$THOR_CODE" "0"
    assert_contains "--version prints the version string" "$THOR_OUT" "thor 0.4.0"

    run_thor --help
    assert_eq "--help exits 0" "$THOR_CODE" "0"
    assert_contains "--help prints usage" "$THOR_ERR" "usage:"

    run_thor -h
    assert_eq "-h is an alias for --help" "$THOR_CODE" "0"

    run_thor
    assert_eq "no arguments exits 1" "$THOR_CODE" "1"
    assert_contains "no arguments prints usage on stderr" "$THOR_ERR" "usage:"

    run_thor bogus-command
    assert_eq "unknown command exits 1" "$THOR_CODE" "1"
    assert_contains "unknown command is named in the error" "$THOR_ERR" "unknown command: bogus-command"
}

# ---------------------------------------------------------------------
# 2. thor new
# ---------------------------------------------------------------------

test_new() {
    section "thor new"
    cd "$WORKDIR"

    run_thor new demo-app
    assert_eq "thor new exits 0 on a fresh name" "$THOR_CODE" "0"
    assert_exists "project directory created" "demo-app"
    assert_exists "thor.toml scaffolded" "demo-app/thor.toml"
    assert_exists ".gitignore scaffolded" "demo-app/.gitignore"
    assert_exists "src/main.zp scaffolded" "demo-app/src/main.zp"
    assert_exists "test/example_test.zp scaffolded" "demo-app/test/example_test.zp"
    assert_contains "main.zp greets by the project name" "$(cat demo-app/src/main.zp)" "hello from demo-app"
    assert_contains "gitignore ignores build/ and vendor/" "$(cat demo-app/.gitignore)" "build/"

    run_thor new demo-app
    assert_eq "creating over an existing directory fails" "$THOR_CODE" "1"
    assert_contains "existing-target error message" "$THOR_ERR" "target already exists"

    run_thor new -- "-bad"
    assert_eq "a name starting with '-' is rejected" "$THOR_CODE" "1"

    run_thor new "bad name"
    assert_eq "a name with an embedded space is rejected" "$THOR_CODE" "1"
    assert_absent "no directory left behind for a rejected name" "bad name"

    run_thor new ""
    assert_eq "an empty name is rejected" "$THOR_CODE" "1"

    run_thor new
    assert_eq "missing project name exits 1" "$THOR_CODE" "1"
    assert_contains "missing project name error" "$THOR_ERR" "missing project name"

    run_thor new a b
    assert_eq "too many arguments to new exits 1" "$THOR_CODE" "1"
    assert_contains "too many arguments error" "$THOR_ERR" "too many arguments for new"
}

# ---------------------------------------------------------------------
# 3. thor build: thor.toml / entry validation errors
# ---------------------------------------------------------------------

test_build_config_errors() {
    section "thor build: config validation errors"

    local dir="$WORKDIR/build-errors-no-toml"
    mkdir -p "$dir"
    cd "$dir"
    run_thor build
    assert_eq "missing thor.toml exits 1" "$THOR_CODE" "1"
    assert_contains "missing thor.toml error" "$THOR_ERR" "missing thor.toml in current directory"

    dir="$WORKDIR/build-errors-no-entry"
    mkdir -p "$dir"
    cd "$dir"
    cat >thor.toml <<'EOF'
name = "proj"
out  = "build/"
EOF
    run_thor build
    assert_eq "thor.toml missing 'entry' exits 1" "$THOR_CODE" "1"
    assert_contains "missing entry error" "$THOR_ERR" "thor.toml is missing entry"

    dir="$WORKDIR/build-errors-missing-entry-file"
    mkdir -p "$dir/src"
    cd "$dir"
    cat >thor.toml <<'EOF'
name  = "proj"
out   = "build/"
entry = "src/nope.zp"
EOF
    run_thor build
    assert_eq "nonexistent entry file exits 1" "$THOR_CODE" "1"
    assert_contains "nonexistent entry error" "$THOR_ERR" "entry file does not exist: src/nope.zp"

    dir="$WORKDIR/build-errors-entry-is-dir"
    mkdir -p "$dir/src"
    cd "$dir"
    cat >thor.toml <<'EOF'
name  = "proj"
out   = "build/"
entry = "src"
EOF
    run_thor build
    assert_eq "entry pointing at a directory exits 1" "$THOR_CODE" "1"
    assert_contains "entry-is-a-directory error" "$THOR_ERR" "entry path is not a file: src"

    dir="$WORKDIR/build-errors-bad-optimization"
    mkdir -p "$dir/src"
    cd "$dir"
    cat >"$dir/src/main.zp" <<'EOF'
import "std/io";
fun main() Int { io.println("hi"); return 0; }
EOF
    cat >thor.toml <<EOF
name         = "proj"
out          = "build/"
entry        = "src/main.zp"
compiler     = "$ZAPC_NOPIE"
optimization = "O9"
EOF
    run_thor build
    assert_eq "invalid optimization in thor.toml exits 1" "$THOR_CODE" "1"
    assert_contains "invalid thor.toml optimization error" "$THOR_ERR" "invalid optimization in thor.toml: O9"
}

# ---------------------------------------------------------------------
# 4. thor build: successful builds and CLI option overrides
# ---------------------------------------------------------------------

mk_valid_project() { # mk_valid_project <dir> <project-name>
    mkdir -p "$1/src"
    cat >"$1/src/main.zp" <<EOF
import "std/io";
fun main() Int { io.println("hello from $2"); return 0; }
EOF
    cat >"$1/thor.toml" <<EOF
name     = "$2"
out      = "build/"
entry    = "src/main.zp"
compiler = "$ZAPC_NOPIE"
EOF
}

test_build_success_and_overrides() {
    section "thor build: successful build, -o / --compiler / -O overrides, -- passthrough"

    local dir="$WORKDIR/build-success"
    mk_valid_project "$dir" "myproj"
    cd "$dir"

    run_thor build
    assert_eq "a valid project builds successfully" "$THOR_CODE" "0"
    assert_exists "default output path is out/name" "build/myproj"
    assert_executable_prints "the built binary runs and prints its greeting" "./build/myproj" "hello from myproj"

    run_thor build -o custom_out/app
    assert_eq "-o override builds successfully" "$THOR_CODE" "0"
    assert_exists "-o override places the binary at the given path" "custom_out/app"

    run_thor build --compiler "$ZAPC_NOPIE" -o build2/myproj
    assert_eq "--compiler override still builds successfully" "$THOR_CODE" "0"
    assert_exists "--compiler override still produces the binary" "build2/myproj"

    run_thor build --compiler /definitely/not/a/real/compiler
    if [[ "$THOR_CODE" != "0" ]]; then pass "a bogus --compiler override fails"; else fail "a bogus --compiler override fails (expected a nonzero exit code, got 0)"; fi

    for level in -O -O0 -O1 -O2 -O3 -O00 -O01 -O02 -O03; do
        run_thor build -o "opt_out/app" "$level"
        local expected_token
        case "$level" in
            -O) expected_token="'-O2'" ;;
            -O00) expected_token="'-O0'" ;;
            -O01) expected_token="'-O1'" ;;
            -O02) expected_token="'-O2'" ;;
            -O03) expected_token="'-O3'" ;;
            *) expected_token="'$level'" ;;
        esac
        assert_eq "build $level still succeeds" "$THOR_CODE" "0"
        assert_contains "build $level is normalized to $expected_token in the compiler invocation" "$THOR_OUT" "$expected_token"
    done

    run_thor build -O9
    assert_eq "an out-of-range -O override is rejected" "$THOR_CODE" "1"
    assert_contains "invalid -O override error" "$THOR_ERR" "invalid optimization override: -O9"

    run_thor build --bogus-flag
    assert_eq "an unrecognized flag is rejected" "$THOR_CODE" "1"
    assert_contains "unrecognized flag error" "$THOR_ERR" "invalid argument for command build: --bogus-flag"

    run_thor build -o
    assert_eq "-o with a missing value is rejected" "$THOR_CODE" "1"
    assert_contains "-o missing-value error" "$THOR_ERR" "missing value after -o"

    run_thor build --compiler
    assert_eq "--compiler with a missing value is rejected" "$THOR_CODE" "1"
    assert_contains "--compiler missing-value error" "$THOR_ERR" "missing value after --compiler"

    run_thor build -o passthrough_out/app -- --emit-ir -v
    assert_contains "passthrough flags after -- are forwarded to the compiler invocation" "$THOR_OUT" "'--emit-ir' '-v'"
}

# ---------------------------------------------------------------------
# 5. thor build: before_compile / after_compile hooks
# ---------------------------------------------------------------------

test_build_hooks() {
    section "thor build: before_compile / after_compile hooks"

    local dir="$WORKDIR/build-hooks-both-succeed"
    mk_valid_project "$dir" "hookproj"
    cd "$dir"
    cat >>thor.toml <<'EOF'
before_compile = "touch before.marker"
after_compile  = "touch after.marker"
EOF
    run_thor build
    assert_eq "build with succeeding hooks exits 0" "$THOR_CODE" "0"
    assert_exists "before_compile hook ran" "before.marker"
    assert_exists "after_compile hook ran" "after.marker"
    local before_line after_line
    before_line=$(grep -n "^execute: touch before.marker$" <<<"$THOR_OUT" | cut -d: -f1)
    after_line=$(grep -n "^execute: touch after.marker$" <<<"$THOR_OUT" | cut -d: -f1)
    if [[ -n "$before_line" && -n "$after_line" && "$before_line" -lt "$after_line" ]]; then
        pass "before_compile runs before after_compile"
    else
        fail "before_compile runs before after_compile (before line=$before_line, after line=$after_line)"
    fi

    dir="$WORKDIR/build-hooks-before-fails"
    mk_valid_project "$dir" "hookproj2"
    cd "$dir"
    cat >>thor.toml <<'EOF'
before_compile = "exit 3"
EOF
    run_thor build
    assert_eq "a failing before_compile hook returns its own exit code" "$THOR_CODE" "3"
    assert_absent "compilation never runs when before_compile fails" "build/hookproj2"

    dir="$WORKDIR/build-hooks-after-fails"
    mk_valid_project "$dir" "hookproj3"
    cd "$dir"
    cat >>thor.toml <<'EOF'
after_compile = "exit 7"
EOF
    run_thor build
    assert_eq "a failing after_compile hook returns its own exit code" "$THOR_CODE" "7"
    assert_exists "compilation still completed before the failing after_compile hook ran" "build/hookproj3"
}

# ---------------------------------------------------------------------
# 6. thor run
# ---------------------------------------------------------------------

test_run() {
    section "thor run"

    local dir="$WORKDIR/run-success"
    mk_valid_project "$dir" "runproj"
    cd "$dir"
    run_thor run
    assert_eq "thor run exits 0 for a valid project" "$THOR_CODE" "0"
    assert_contains "thor run prints the 'run:' line" "$THOR_OUT" "run: "
    assert_contains "thor run's output includes the program's own stdout" "$THOR_OUT" "hello from runproj"

    dir="$WORKDIR/run-build-fails"
    mkdir -p "$dir/src"
    cd "$dir"
    cat >thor.toml <<'EOF'
name  = "proj"
out   = "build/"
entry = "src/missing.zp"
EOF
    run_thor run
    assert_eq "thor run propagates a build failure's exit code" "$THOR_CODE" "1"
    assert_not_contains "thor run never attempts to execute the binary when the build failed" "$THOR_OUT" "run: "
}

# ---------------------------------------------------------------------
# 7. thor add
# ---------------------------------------------------------------------

test_add() {
    section "thor add"

    local depsrc="$WORKDIR/fixture-dep-a"
    mkdir -p "$depsrc/src"
    echo 'pub fun greet() String { return "hi from dep"; }' >"$depsrc/src/greet.zp"
    mkgitfixture "$depsrc"
    git -C "$depsrc" tag v1.0.0

    local depsrc2="$WORKDIR/fixture-dep-b"
    mkdir -p "$depsrc2/src"
    echo 'pub fun noop() Int { return 0; }' >"$depsrc2/src/noop.zp"
    mkgitfixture "$depsrc2"

    local dir="$WORKDIR/add-target"
    mk_valid_project "$dir" "addproj"
    cd "$dir"

    run_thor add "$depsrc"
    assert_eq "thor add against a local git fixture succeeds" "$THOR_CODE" "0"
    assert_exists "the dependency is cloned into vendor/" "vendor/fixture-dep-a"
    assert_contains "thor.toml gains a [dependencies] entry" "$(cat thor.toml)" '"fixture-dep-a" = { url = "'"$depsrc"'", version = "v1.0.0"'
    assert_contains "thor.toml gains a matching [imports] alias" "$(cat thor.toml)" '"@fixture-dep-a" = "./vendor/fixture-dep-a/src"'

    run_thor add "$depsrc2" --test
    assert_eq "thor add --test against a local git fixture succeeds" "$THOR_CODE" "0"
    assert_exists "the test dependency is cloned into vendor/" "vendor/fixture-dep-b"
    assert_contains "thor.toml gains a [test-dependencies] entry, not [dependencies]" "$(cat thor.toml)" '"fixture-dep-b" = { url = "'"$depsrc2"'"'
    local dep_count
    dep_count=$(grep -c 'fixture-dep-b' thor.toml)
    # [imports] + [test-dependencies] = 2 lines mentioning the name; not
    # a stray extra [dependencies] line too.
    assert_eq "--test wires exactly an [imports] alias plus a [test-dependencies] entry (not [dependencies])" "$dep_count" "2"

    run_thor add "$depsrc"
    assert_eq "re-adding an already-vendored dependency still exits 0" "$THOR_CODE" "0"
    assert_contains "re-adding reports the existing vendor/ dir instead of re-cloning" "$THOR_OUT" "already exists in vendor/"
    dep_count=$(grep -c '"fixture-dep-a" = { url' thor.toml)
    # Documented current behavior, not necessarily desired: insertTableEntry
    # has no dedup check, so re-running `add` for an already-vendored
    # dependency appends a second, identical [dependencies] line rather
    # than being a no-op on thor.toml.
    assert_eq "known quirk: re-adding duplicates the [dependencies] line in thor.toml" "$dep_count" "2"

    run_thor add
    assert_eq "missing git url exits 1" "$THOR_CODE" "1"
    assert_contains "missing git url error" "$THOR_ERR" "missing git url"

    run_thor add "$depsrc" extra-arg
    assert_eq "an unexpected extra argument exits 1" "$THOR_CODE" "1"
    assert_contains "unexpected argument error" "$THOR_ERR" "unexpected argument for add: extra-arg"
}

# ---------------------------------------------------------------------
# 8. full dependency pipeline: add -> restore-on-build -> import-map -> run
# ---------------------------------------------------------------------

test_dependency_pipeline() {
    section "full pipeline: add a dependency, then build/run against it from a clean vendor/"

    local depsrc="$WORKDIR/fixture-dep-pipeline"
    mkdir -p "$depsrc/src"
    # Named depgreet.zp (not greet.zp) deliberately: importing a module
    # whose inferred namespace name is identical to a symbol destructured
    # from it (`import ".../greet" {greet};`) is rejected by zapc as a
    # name conflict between the implicit module namespace and the pulled
    # -in symbol -- confirmed directly. Distinct names sidestep it.
    echo 'pub fun greet() String { return "hi from dep"; }' >"$depsrc/src/depgreet.zp"
    mkgitfixture "$depsrc"

    local dir="$WORKDIR/pipeline-project"
    mk_valid_project "$dir" "pipelineproj"
    cd "$dir"

    run_thor add "$depsrc"
    assert_eq "setup: dependency added" "$THOR_CODE" "0"

    cat >src/main.zp <<'EOF'
import "std/io";
import "@fixture-dep-pipeline/depgreet" {greet};

fun main() Int {
    io.println(greet());
    return 0;
}
EOF

    # vendor/ is .gitignore'd in real projects -- simulate a fresh
    # checkout where it doesn't exist yet, to prove `thor build`
    # restores dependencies on its own rather than only working right
    # after `thor add`.
    rm -rf vendor

    run_thor build
    assert_eq "build restores the missing dependency and succeeds" "$THOR_CODE" "0"
    assert_exists "the dependency is restored into vendor/ by the build itself" "vendor/fixture-dep-pipeline"
    assert_contains "the restored dependency is wired in as an import-map flag" "$THOR_OUT" "'--import-map' '@fixture-dep-pipeline=./vendor/fixture-dep-pipeline/src'"

    run_thor run
    assert_eq "run succeeds against the restored dependency" "$THOR_CODE" "0"
    assert_contains "the program actually calls into the vendored dependency" "$THOR_OUT" "hi from dep"
}

# ---------------------------------------------------------------------
# 9. a dependency's own `flags` (from its thor.toml) are rewritten and
#    merged into the consuming project's build flags
# ---------------------------------------------------------------------

test_dependency_flags_rewriting() {
    section "a dependency's thor.toml 'flags' are path-rewritten into vendor/<name>/..."

    local depsrc="$WORKDIR/fixture-dep-flags"
    mkdir -p "$depsrc/src"
    echo 'pub fun noop() Int { return 0; }' >"$depsrc/src/lib.zp"
    cat >"$depsrc/thor.toml" <<'EOF'
name  = "fixture-dep-flags"
flags = "-Lnativelib -lfoo relative/other.o"
EOF
    mkgitfixture "$depsrc"

    local dir="$WORKDIR/flags-rewrite-project"
    mk_valid_project "$dir" "flagsproj"
    cd "$dir"
    run_thor add "$depsrc"
    assert_eq "setup: dependency-with-flags added" "$THOR_CODE" "0"

    run_thor build
    # Not asserting THOR_CODE here: -lfoo doesn't refer to a real
    # library, so the final `cc` link step is expected to fail. The
    # point of this test is the derived flags on the printed compiler
    # invocation line, which is emitted before the link step runs.
    assert_contains "a -L flag is rewritten to live under vendor/<dep-name>/" "$THOR_OUT" "'-Lvendor/fixture-dep-flags/nativelib'"
    assert_contains "a -l flag passes through unchanged" "$THOR_OUT" "'-lfoo'"
    assert_contains "a bare relative path is rewritten to live under vendor/<dep-name>/" "$THOR_OUT" "'vendor/fixture-dep-flags/relative/other.o'"
}

# ---------------------------------------------------------------------
# 10. thor test
# ---------------------------------------------------------------------

test_test_command() {
    section "thor test"

    local testlib
    testlib="$(cat "$ZEUS_ROOT/vendor/zap-test/src/test.zp")"

    local dir="$WORKDIR/testcmd-no-tests"
    mk_valid_project "$dir" "notests"
    cd "$dir"
    run_thor test
    assert_eq "no test/ directory at all exits 0" "$THOR_CODE" "0"
    assert_contains "no-tests message" "$THOR_OUT" "no test files found under test/"

    dir="$WORKDIR/testcmd-file-with-no-test-fns"
    mk_valid_project "$dir" "notestfns"
    mkdir -p "$dir/test"
    cat >"$dir/test/helpers_test.zp" <<'EOF'
pub fun notATest() Int { return 0; }
EOF
    cd "$dir"
    run_thor test
    assert_eq "known quirk: a test/*.zp file with zero @test functions is silently dropped, not failed" "$THOR_CODE" "0"
    assert_contains "silently-dropped file summary" "$THOR_OUT" "0/0 test files passed"
    assert_not_contains "the file itself is never mentioned" "$THOR_OUT" "helpers_test.zp"

    dir="$WORKDIR/testcmd-mixed"
    mk_valid_project "$dir" "mixedtests"
    mkdir -p "$dir/lib" "$dir/test"
    echo "$testlib" >"$dir/lib/test.zp"
    cat >"$dir/test/pass_test.zp" <<'EOF'
import "../lib/test.zp" {TestContext};

@test
pub fun testAlwaysPasses(t: TestContext) Void {
    t.assertEqual(1 + 1, 2, "arithmetic works");
}
EOF
    cat >"$dir/test/fail_test.zp" <<'EOF'
import "../lib/test.zp" {TestContext};

@test
pub fun testAlwaysFails(t: TestContext) Void {
    t.assertTrue(false, "deliberately false");
}
EOF
    cat >"$dir/test/no_import_test.zp" <<'EOF'
@test
pub fun testMissingImport(t: TestContext) Void {
    t.assertTrue(true, "never actually compiled/run");
}
EOF
    cd "$dir"
    run_thor test
    assert_eq "mixed pass/fail/no-import test files: overall exit code is 1" "$THOR_CODE" "1"
    assert_contains "the passing file is reported as PASS" "$THOR_OUT" "PASS test/pass_test.zp"
    assert_contains "the failing file is reported as FAIL" "$THOR_OUT" "FAIL test/fail_test.zp"
    assert_contains "the file with no TestContext import gets a specific FAIL reason" "$THOR_OUT" "FAIL test/no_import_test.zp (no TestContext import found"
    assert_contains "summary counts all three discovered files, one passing" "$THOR_OUT" "1/3 test files passed"
    assert_absent "the generated runner for the passing file is cleaned up" "test/.pass_test.thor_generated_main.zp"
    assert_absent "the generated runner for the failing file is cleaned up" "test/.fail_test.thor_generated_main.zp"

    dir="$WORKDIR/testcmd-compile-error-independence"
    mk_valid_project "$dir" "compileerr"
    mkdir -p "$dir/lib" "$dir/test"
    echo "$testlib" >"$dir/lib/test.zp"
    cat >"$dir/test/pass_test.zp" <<'EOF'
import "../lib/test.zp" {TestContext};

@test
pub fun testAlwaysPasses(t: TestContext) Void {
    t.assertEqual(2 + 2, 4, "arithmetic works");
}
EOF
    cat >"$dir/test/broken_test.zp" <<'EOF'
import "../lib/test.zp" {TestContext};

@test
pub fun testDoesNotCompile(t: TestContext) Void {
    t.assertTrue(thisIdentifierDoesNotExist, "never gets here");
}
EOF
    cd "$dir"
    run_thor test
    assert_eq "a compile error in one file still exits 1 overall" "$THOR_CODE" "1"
    assert_contains "the broken file is reported as a compile error" "$THOR_OUT" "FAIL test/broken_test.zp (compile error)"
    assert_contains "the other file compiles and passes independently" "$THOR_OUT" "PASS test/pass_test.zp"
    assert_contains "summary reflects one passing file out of two" "$THOR_OUT" "1/2 test files passed"
    assert_absent "the generated runner for the broken file is cleaned up even after a compile error" "test/.broken_test.thor_generated_main.zp"
}

# ---------------------------------------------------------------------
# 11. network-gated smoke tests (skipped, not failed, when offline)
# ---------------------------------------------------------------------

test_network_smoke() {
    section "network-gated smoke tests"
    if [[ "$NETWORK_AVAILABLE" != "1" ]]; then
        echo "  SKIP: no network access detected, skipping GitHub-backed scenarios"
        return
    fi

    local dir="$WORKDIR/network-new-project"
    cd "$WORKDIR"
    run_thor new network-new-project
    assert_eq "thor new exits 0 regardless of the auto zap-test add outcome" "$THOR_CODE" "0"
    cd "$dir"
    # The scaffolded thor.toml leaves `compiler` commented out (defaults
    # to plain "zapc"), which hits this host's PIE-linker quirk (see
    # wiki/build-tooling.md) -- unrelated to what this smoke test is
    # actually checking, so override it explicitly like every other
    # fixture in this script does.
    run_thor test --compiler "$ZAPC_NOPIE"
    # The scaffolded example_test.zp only compiles if zap-test really got
    # vendored as a real [test-dependencies] entry by `thor new` -- this
    # is the ecosystem's actual "does a brand-new project work out of the
    # box" smoke test.
    assert_eq "a freshly-scaffolded project's own example test passes out of the box" "$THOR_CODE" "0"
    assert_contains "the scaffolded example test is discovered and run" "$THOR_OUT" "PASS test/example_test.zp"
}

# ---------------------------------------------------------------------
# run everything
# ---------------------------------------------------------------------

test_top_level
test_new
test_build_config_errors
test_build_success_and_overrides
test_build_hooks
test_run
test_add
test_dependency_pipeline
test_dependency_flags_rewriting
test_test_command
test_network_smoke

echo
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Failed assertions:"
    for d in "${FAILED_DESCRIPTIONS[@]}"; do
        echo "  - $d"
    done
    exit 1
fi
exit 0
