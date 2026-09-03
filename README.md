# Thor

A self-hosted build tool for the [Zap programming language](https://github.com/thezaplang/zap).

## Requirements

- [Zap](https://github.com/thezaplang/zap) `v0.4.0`

## Building from Source

Thor uses itself for its second build. The first build uses `zapc` directly.

### Step 1 -> Bootstrap

```bash
git clone https://github.com/thezaplang/thor
cd thor
./build.sh
```

### Step 2 -> Self-hosted build

Once the bootstrap binary exists, rebuild Thor with Thor itself:

```bash
./build/thor build
```

You now have a fully self-hosted Thor binary.

The bootstrap build restores Thor's pinned `zap-toml` dependency under
`vendor/` and uses Zap's failable filesystem API. Make sure `zapc` is
available in `PATH`.

## Adding to PATH

```bash
# Option A - copy to a directory already in PATH
sudo cp build/thor /usr/local/bin/thor

# Option B - add the build directory to PATH (add to ~/.bashrc or ~/.zshrc)
export PATH="$PATH:/path/to/thor/build"
source ~/.bashrc
```

Verify:

```bash
thor --version
```

## Usage
```bash
thor new <project_name>
thor build
thor run
thor build --compiler /path/to/zapc
thor build -- --emit-ir
```

## Dependencies

To add a dependency, run:

```bash
thor add <github_url>

```

Add `--test` to wire it into `[test-dependencies]` instead (only restored
and linked by `thor test`, never by `thor build`/`thor run`).

## Testing

```bash
thor test
```

Discovers and runs `@test`-annotated functions in `test/*.zp` (see
`test/example_test.zp` from `thor new` for the shape). This covers
thor's own pure helper functions (`test/*_test.zp`).

The rest of thor -- CLI parsing, `thor new`/`thor add`/`thor build`/
`thor run`/`thor test` behavior end to end, dependency restore, build
hooks -- is covered by a separate shell-driven suite that builds thor
and drives it as a real subprocess against throwaway fixture projects:

```bash
./test/integration/run_integration_tests.sh
```

## License

See [LICENSE](LICENSE).
