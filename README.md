# Thor

A self-hosted build tool for the [Zap programming language](https://github.com/thezaplang/zap).

## Requirements

- [Zap](https://github.com/thezaplang/zap) `v0.2.1`

## Building from Source

Thor is self-hosted — it uses itself to build itself. The first build must be done manually using the Zap compiler directly.

### Step 1 — Bootstrap

```bash
git clone https://github.com/thezaplang/thor
cd thor
mkdir -p build
zapc src/main.zp -o build/thor
```

### Step 2 — Self-hosted build

Once the bootstrap binary exists, use it to rebuild Thor with Thor itself:

```bash
./build/thor build
```

You now have a fully self-hosted Thor binary.

## Adding to PATH

```bash
# Option A — copy to a directory already in PATH
sudo cp build/thor /usr/local/bin/thor

# Option B — add the build directory to PATH (add to ~/.bashrc or ~/.zshrc)
export PATH="$PATH:/path/to/thor/build"
source ~/.bashrc
```

Verify:

```bash
thor --version
```

## Usage
```text
thor new <project_name>
thor build
thor run
```

## License

See [LICENSE](LICENSE).
