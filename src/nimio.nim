## nimio — minimal coding agent harness inspired by pi.

import std/[os, parseopt, strutils, terminal]
import ollama

const Model = "qwen3.6:35b"

type
  Config = object
    workdir: string

proc parseArgs(): Config =
  ## Parse command-line arguments. Supports:
  ##   --workdir=<path>  (or -w=<path>)  set agent working directory
  ## Defaults to current working directory.
  result.workdir = getCurrentDir()

  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "workdir", "w":
        if p.val.len == 0:
          stderr.writeLine "error: --workdir requires a path"
          quit 1
        result.workdir = absolutePath(p.val)
      else:
        stderr.writeLine "error: unknown option --" & p.key
        quit 1
    of cmdArgument:
      stderr.writeLine "error: unexpected argument: " & p.key
      quit 1

  if not dirExists(result.workdir):
    stderr.writeLine "error: workdir does not exist: " & result.workdir
    quit 1

proc containsPath*(workdir, path: string): bool =
  ## Returns true if `path` (after resolution) is inside `workdir`.
  ## Used to keep tool calls from touching files outside the sandbox.
  let absWork = absolutePath(workdir).normalizedPath()
  let absPath = absolutePath(path).normalizedPath()
  result = absPath == absWork or absPath.startsWith(absWork & DirSep)

proc main() =
  let cfg = parseArgs()
  setCurrentDir(cfg.workdir)

  echo "nimio — talking to ", Model
  echo "workdir: ", cfg.workdir
  echo "type a message and press Enter. Empty input or Ctrl+D to quit."
  echo ""

  var messages: seq[Message] = @[]

  while true:
    stdout.styledWrite(styleBright, "> ")
    stdout.flushFile()

    var userInput: string
    try:
      userInput = stdin.readLine()
    except EOFError:
      echo "\nbye"
      break

    let trimmed = userInput.strip()
    if trimmed.len == 0:
      echo "bye"
      break

    messages.add(Message(role: rUser, content: trimmed))
    let reply = chat(Model, messages)
    messages.add(Message(role: rAssistant, content: reply))

    echo ""

main()
