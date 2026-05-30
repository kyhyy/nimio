## nimio — minimal coding agent harness inspired by pi.

import std/[json, options, os, parseopt, strutils, tables, terminal]
import ollama, tools, config

const
  DefaultModel = "qwen3.6:35b"
  DefaultMaxToolCalls = 30
  DefaultThink = false
  DefaultContextSize = 32768
  DefaultSystemPrompt = """You are nimio, a minimal coding agent running in a terminal.

You have four tools: read_file, write_file, edit_file, and bash. Use them to
inspect and modify the user's project. All file paths are relative to the
working directory.

Be concise. Take action with tools rather than describing what you would do.
If a tool returns an error, read the message and try a different approach.
When you've finished the user's request, respond with a short summary."""

type
  Args = object
    workdir: string
    model: Option[string]
    maxToolCalls: Option[int]
    testTools: bool

  ResolvedConfig = object
    workdir: string
    model: string
    maxToolCalls: int
    think: bool
    systemPrompt: string
    contextSize: int
    testTools: bool

proc parseArgs(): Args =
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
      of "model", "m":
        if p.val.len == 0:
          stderr.writeLine "error: --model requires a value"
          quit 1
        result.model = some(p.val)
      of "max-tool-calls":
        if p.val.len == 0:
          stderr.writeLine "error: --max-tool-calls requires a value"
          quit 1
        try:
          let n = parseInt(p.val)
          if n < 1:
            stderr.writeLine "error: --max-tool-calls must be >= 1"
            quit 1
          result.maxToolCalls = some(n)
        except ValueError:
          stderr.writeLine "error: --max-tool-calls must be an integer"
          quit 1
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

proc resolveConfig(args: Args): ResolvedConfig =
  result.workdir = args.workdir
  result.testTools = args.testTools

  let fileCfg =
    try:
      loadConfig(args.workdir)
    except ValueError as e:
      stderr.writeLine "error: " & e.msg
      quit 1

  result.model =
    if args.model.isSome: args.model.get()
    elif fileCfg.model.isSome: fileCfg.model.get()
    else: DefaultModel

  result.maxToolCalls =
    if args.maxToolCalls.isSome: args.maxToolCalls.get()
    elif fileCfg.maxToolCalls.isSome: fileCfg.maxToolCalls.get()
    else: DefaultMaxToolCalls

  result.think =
    if fileCfg.think.isSome: fileCfg.think.get()
    else: DefaultThink

  result.contextSize =
    if fileCfg.contextSize.isSome: fileCfg.contextSize.get()
    else: DefaultContextSize

  result.systemPrompt =
    if fileCfg.systemPrompt.isSome: fileCfg.systemPrompt.get()
    else: DefaultSystemPrompt

  if fileCfg.agentMd.isSome:
    let mdPath = args.workdir / fileCfg.agentMd.get()
    if not fileExists(mdPath):
      stderr.writeLine "error: agent_md file not found: " & mdPath
      quit 1
    let mdContent = readFile(mdPath)
    result.systemPrompt = mdContent & "\n\n" & result.systemPrompt

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

proc confirmContinue(used: int): bool =
  stdout.styledWrite(styleBright,
    "\n⚠️  hit ", $used, " tool calls in this turn. continue? [y/N] ")
  stdout.flushFile()
  try:
    let answer = stdin.readLine().strip().toLowerAscii()
    return answer == "y" or answer == "yes"
  except EOFError:
    return false

proc agentTurn(cfg: ResolvedConfig, registry: Table[string, Tool],
               messages: var seq[Message]): tuple[promptTokens, outputTokens: int] =
  let toolsJson = toolsSchema(registry)
  var toolCallsUsed = 0
  var budget = cfg.maxToolCalls

  while true:
    let response = chat(cfg.model, messages, tools = toolsJson, think = cfg.think)
    result.promptTokens = response.promptTokens
    result.outputTokens = response.outputTokens

    # Always record the assistant turn when it produced anything — text OR
    # tool calls. The previous condition skipped tool-call-only turns (empty
    # content + calls), which dropped the assistant's tool_calls from history.
    # The tool results that followed then looked like they came out of nowhere,
    # so the model reattributed them to the user.
    if response.content.len > 0 or response.toolCalls.len > 0:
      messages.add(Message(role: rAssistant, content: response.content,
                           toolCalls: response.toolCalls))

    if response.toolCalls.len == 0:
      return

    for tc in response.toolCalls:
      stdout.styledWrite(styleBright, "\n🔧 ", tc.name, " ", $tc.arguments, "\n")
      let res = dispatch(registry, tc.name, tc.arguments, cfg.workdir)
      let preview =
        if res.len > 500: res[0 ..< 500] & "\n... [" & $(res.len - 500) & " more bytes]"
        else: res
      stdout.styledWrite(styleDim, preview, "\n")

      messages.add(Message(role: rTool, content: res))
      toolCallsUsed.inc

    if toolCallsUsed >= budget:
      if confirmContinue(toolCallsUsed):
        budget += cfg.maxToolCalls
      else:
        messages.add(Message(role: rUser,
          content: "(user interrupted: max_tool_calls reached. summarize what you've done so far.)"))
        let final = chat(cfg.model, messages, tools = toolsJson, think = cfg.think)
        result.promptTokens = final.promptTokens
        result.outputTokens = final.outputTokens
        if final.content.len > 0:
          messages.add(Message(role: rAssistant, content: final.content))
        return

proc main() =
  let args = parseArgs()
  setCurrentDir(args.workdir)

  if args.testTools:
    runToolTests(args.workdir)
    return

  let cfg = resolveConfig(args)

  echo "nimio — talking to ", cfg.model
  echo "workdir: ", cfg.workdir
  if fileExists(cfg.workdir / ConfigFileName):
    echo "config: ", ConfigFileName, " loaded"
  echo "type a message and press Enter. Empty input or Ctrl+D to quit."
  echo ""

  let registry = buildRegistry()

  var messages: seq[Message] = @[
    Message(role: rSystem, content: cfg.systemPrompt)
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
    let usage = agentTurn(cfg, registry, messages)
    let totalCtx = usage.promptTokens + usage.outputTokens
    let pct = (totalCtx.float / cfg.contextSize.float * 100.0)
    stdout.styledWrite(styleDim,
      "[context: ", $totalCtx, " / ", $cfg.contextSize, " (",
      formatFloat(pct, ffDecimal, 1), "%)]\n")
    echo ""

main()
