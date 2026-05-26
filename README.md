# nimio

A minimal coding agent harness, written in Nim, that talks to a local
[Ollama](https://ollama.com) instance. Inspired by
[pi](https://github.com/badlogic/pi-mono).

This is a learning project that I'm using to learn Nim and to understand
how agent harnesses actually work. It's also usable as is: you can point it at a project directory and it'll read, write, edit, and run shell commands on your behalf.
I'm currently using it myself to write another project of mine, [theCrap](https://github.com/kyhyy/theCrap)

## What it does

Four tools, an inner agent loop, and a streaming chat client. That's it.

- **`read_file`** - read file contents
- **`write_file`** - create or overwrite a file
- **`edit_file`** - find-and-replace (must match exactly once)
- **`bash`** - run a shell command

All file operations are constrained to a working directory (defaults to
cwd, override with `--workdir`). The model can't read or write outside it.

The HTTP client speaks directly to Ollama's `/api/chat` endpoint over a
raw TCP socket with no async runtime, no third-party HTTP libraries.

## Requirements

- [Nim](https://nim-lang.org) 2.0+ (`pacman -S nim` on Arch which I'm using currently as of writing this README)
- [Ollama](https://ollama.com) running locally on `:11434`
- A model with tool-calling support pulled. Default is `qwen3.6:35b`;
  edit `Model` in `src/nimio.nim` to change it; later I will implement some type of config file.

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


## Example

```
> read the nimio.nimble file and tell me what it contains
🔧 read_file {"path":"nimio.nimble"}
# Package
version       = "0.1.0"
...
💬 The nimio.nimble file defines a Nim package with version 0.1.0,
   author KHajduk00, MIT license, source directory src/, and binary
   name nimio. It depends on Nim >= 2.0.0.

> create a file called hello.txt that contains "hello world"
🔧 write_file {"path":"hello.txt","content":"hello world"}
wrote 11 bytes to /home/khajduk/Projects/nimio/hello.txt
💬 Created hello.txt with the content "hello world".

> change "hello world" to "hello nimio" in hello.txt
🔧 edit_file {"path":"hello.txt","old_str":"hello world","new_str":"hello nimio"}
edited /home/khajduk/Projects/nimio/hello.txt
💬 Updated hello.txt to contain "hello nimio".
```

## Project layout

```
src/
├── nimio.nim      # entry point, agent loop, REPL, system prompt
├── ollama.nim     # HTTP/streaming client, message types
└── tools.nim      # tool definitions, dispatch, path containment
```

## License

MIT
