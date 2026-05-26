## nimio — minimal coding agent harness inspired by pi.

import std/[json, os, parseopt, strutils, tables, terminal]
import ollama, tools

const
  Model = "qwen3.6:35b"
  SystemPrompt = """You are nimio, a minimal coding agent running in a terminal.

You have four tools: read_file, write_file, edit_file, and bash. Use them to
inspect and modify the user's project. All file paths are relative to the
working directory.

Be concise. Take action with tools rather than describing what you would do.
If a tool returns an error, read the message and try a different approach.
When you've finished the user's request, respond with a short summary."""

type
  Config = object
    workdir: string
    testTools: bool

proc parseArgs(): Config =
  result.workdir = getCurrentDir()
  var workdirSet = false

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
        result.workdir = absolutePath(expandTilde(p.val))
        workdirSet = true
      of "test-tools":
        result.testTools = true
      else:
        stderr.writeLine "error: unknown option --" & p.key
        quit 1
    of cmdArgument:
      if workdirSet:
        stderr.writeLine "error: unexpected argument: " & p.key
        quit 1
      result.workdir = absolutePath(expandTilde(p.key))
      workdirSet = true

  if not dirExists(result.workdir):
    stderr.writeLine "error: workdir does not exist: " & result.workdir
    quit 1

proc runToolTests(workdir: string) =
  let registry = buildRegistry()

  template demo(name: string, args: JsonNode) =
    stdout.styledWrite(styleBright, "\n--- ", name, " ", $args, " ---\n")
    let r = dispatch(registry, name, args, workdir)
    echo r

  demo "read_file", %*{"path": "nimio.nimble"}
  demo "write_file", %*{"path": "/tmp_nimio_test.txt", "content": "hello\n"}
  demo "write_file", %*{"path": "tmp_nimio_test.txt", "content": "hello\n"}
  demo "edit_file", %*{"path": "tmp_nimio_test.txt", "old_str": "hello", "new_str": "greetings"}
  demo "read_file", %*{"path": "tmp_nimio_test.txt"}
  demo "bash", %*{"command": "ls -la tmp_nimio_test.txt"}
  demo "read_file", %*{"path": "../../../etc/passwd"}
  demo "nope", %*{"x": 1}
  demo "bash", %*{"command": "rm tmp_nimio_test.txt"}

proc toolsSchema(registry: Table[string, Tool]): JsonNode =
  result = newJArray()
  for t in registry.values:
    result.add(%*{
      "type": "function",
      "function": {
        "name": t.name,
        "description": t.description,
        "parameters": t.parameters
      }
    })

proc agentTurn(model: string, registry: Table[string, Tool],
               messages: var seq[Message], workdir: string) =
  let toolsJson = toolsSchema(registry)

  while true:
    let response = chat(model, messages, tools = toolsJson, think = false)

    if response.content.len > 0 or response.toolCalls.len == 0:
      messages.add(Message(role: rAssistant, content: response.content))

    if response.toolCalls.len == 0:
      return

    for tc in response.toolCalls:
      stdout.styledWrite(styleBright, "\n🔧 ", tc.name, " ", $tc.arguments, "\n")
      let result = dispatch(registry, tc.name, tc.arguments, workdir)
      let preview =
        if result.len > 500: result[0 ..< 500] & "\n... [" & $(result.len - 500) & " more bytes]"
        else: result
      stdout.styledWrite(styleDim, preview, "\n")

      messages.add(Message(role: rTool, content: result, toolName: tc.name))

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

  let registry = buildRegistry()

  var messages: seq[Message] = @[
    Message(role: rSystem, content: SystemPrompt)
  ]

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
    agentTurn(Model, registry, messages, cfg.workdir)
    echo ""

main()
