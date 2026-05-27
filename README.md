# nimio

A minimal coding agent harness, written in Nim, that talks to a local
[Ollama](https://ollama.com) instance. Inspired by
[pi](https://github.com/badlogic/pi-mono).

This is a learning project that I'm using to learn Nim and to understand
how agent harnesses actually work. It's also usable as is: you can point it at a project directory and it'll read, write, edit, and run shell commands on your behalf.

I'm currently using it myself to write another project of mine, [theCrap](https://github.com/kyhyy/theCrap).

## What it does

Four tools, an inner agent loop, and a streaming chat client. That's it.

- **`read_file`** - read file contents
- **`write_file`** - create or overwrite a file
- **`edit_file`** - find-and-replace (must match exactly once)
- **`bash`** - run a shell command

All file operations are constrained to a working directory (defaults to
cwd, override with `--workdir` or the first positional arg). The model can't read or write outside it.

The HTTP client speaks directly to Ollama's `/api/chat` endpoint over a
raw TCP socket with no async runtime, no third-party HTTP libraries.

## Requirements

- [Nim](https://nim-lang.org) 2.0+ (`pacman -S nim` on Arch which I'm using currently as of writing this README)
- [Ollama](https://ollama.com) running locally on `:11434`
- A model with tool-calling support pulled. Default is `qwen3.6:35b`; override per-project via the config file (see below).

## Install

```sh
git clone https://github.com/kyhyy/nimio
cd nimio
nimble install
```

`nimble install` builds the binary and copies it to `~/.nimble/bin/`.
Make sure that directory is on your `PATH`:

```sh
# bash/zsh
export PATH="$HOME/.nimble/bin:$PATH"

# fish
fish_add_path ~/.nimble/bin
```

Verify with `which nimio`.

To uninstall: `nimble uninstall nimio`.

## Usage

```sh
nimio                # use current directory
nimio .              # same as above
nimio ~/code/myproj  # use a specific directory
nimio --workdir=/tmp # same, but explicit flag form
```

Other flags:

- `--model=<name>` (or `-m`) pick the Ollama model for this run
- `--max-tool-calls=<n>` cap how many tools the model can call in one turn before nimio asks if you want to keep going (default 30)

CLI flags override anything set in the config file.

## Configuration

Drop a `nimio.config.toml` in the working directory to set things per-project. All fields are optional.

```toml
model = "qwen3.6:35b"
max_tool_calls = 30
think = false              # let the model emit reasoning blocks
context_size = 32768       # used for the context usage display
agent_md = "AGENTS.md"     # prepended to system prompt if set

system_prompt = """
You are nimio, a coding agent. Be concise.
"""
```

If `agent_md` is set, the contents of that file get prepended to the system prompt. Useful for project-specific guidance like conventions or architecture notes.

## Example

```
> read the nimio.nimble file and tell me what it contains
🔧 read_file {"path":"nimio.nimble"}
# Package
version       = "0.1.0"
...
💬 The nimio.nimble file defines a Nim package with version 0.1.0,
   author KHajduk00, MIT license, and depends on parsetoml.
[context: 944 / 32768 (2.9%)]

> create a file called hello.txt that contains "hello world"
🔧 write_file {"path":"hello.txt","content":"hello world"}
wrote 11 bytes to /home/khajduk/Projects/nimio/hello.txt
💬 Created hello.txt with the content "hello world".
[context: 1102 / 32768 (3.4%)]

> change "hello world" to "hello nimio" in hello.txt
🔧 edit_file {"path":"hello.txt","old_str":"hello world","new_str":"hello nimio"}
edited /home/khajduk/Projects/nimio/hello.txt
💬 Updated hello.txt to contain "hello nimio".
[context: 1278 / 32768 (3.9%)]
```

## Project layout

```
src/
├── nimio.nim      # entry point, agent loop, REPL, arg + config resolution
├── ollama.nim     # HTTP/streaming client, message types
├── tools.nim      # tool definitions, dispatch, path containment
└── config.nim     # nimio.config.toml loader
```

## License

MIT
