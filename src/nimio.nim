## nimio — minimal coding agent harness inspired by pi.

import std/[json, os, parseopt, strutils, tables, terminal]
import ollama, tools

const Model = "qwen3.6:35b"

type
  Config = object
    workdir: string
    testTools: bool

proc parseArgs(): Config =
  result.workdir = getCurrentDir()
  result.testTools = false

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
      of "test-tools":
        result.testTools = true
      else:
        stderr.writeLine "error: unknown option --" & p.key
        quit 1
    of cmdArgument:
      stderr.writeLine "error: unexpected argument: " & p.key
      quit 1

  if not dirExists(result.workdir):
    stderr.writeLine "error: workdir does not exist: " & result.workdir
    quit 1

proc runToolTests(workdir: string) =
  ## Run each tool with a hardcoded input and print the result. Used to
  ## verify the tool layer before wiring it to the model.
  let registry = buildRegistry()

  template demo(name: string, args: JsonNode) =
    stdout.styledWrite(styleBright, "\n--- ", name, " ", $args, " ---\n")
    let r = dispatch(registry, name, args, workdir)
    echo r

  # read a file we know exists
  demo "read_file", %*{"path": "nimio.nimble"}

  # write a new file
  demo "write_file", %*{"path": "/tmp_nimio_test.txt",
                        "content": "hello from nimio\n"}
  # (note: /tmp_nimio_test.txt is interpreted as relative to workdir,
  #  not as an absolute path, because no leading workdir match would pass
  #  containment. we expect this to error out — that's the test.)

  # write inside workdir (this should succeed)
  demo "write_file", %*{"path": "tmp_nimio_test.txt",
                        "content": "hello from nimio\n"}

  # edit that file
  demo "edit_file", %*{"path": "tmp_nimio_test.txt",
                       "old_str": "hello", "new_str": "greetings"}

  # read it back to confirm
  demo "read_file", %*{"path": "tmp_nimio_test.txt"}

  # run a bash command
  demo "bash", %*{"command": "ls -la tmp_nimio_test.txt"}

  # try to escape the workdir
  demo "read_file", %*{"path": "../../../etc/passwd"}

  # try a nonexistent tool
  demo "nope", %*{"x": 1}

  # clean up
  demo "bash", %*{"command": "rm tmp_nimio_test.txt"}

proc main() =
  let cfg = parseArgs()
  setCurrentDir(cfg.workdir)

  if cfg.testTools:
    runToolTests(cfg.workdir)
    return

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
