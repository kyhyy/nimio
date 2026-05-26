## Tool definitions for nimio. Each tool has a name, a description shown
## to the model, a JSON schema describing its arguments, and a Nim proc
## that executes it.
##
## Tool procs all share the same signature: take a JsonNode of arguments,
## return a string result (whatever the model should see). They raise
## ValueError on bad input, which the dispatcher catches and reports back
## to the model as the tool result.

import std/[json, os, osproc, strutils, tables]

type
  ToolProc* = proc(args: JsonNode, workdir: string): string {.gcsafe.}

  Tool* = object
    name*: string
    description*: string
    parameters*: JsonNode  # JSON schema for the model
    run*: ToolProc

# ---------------------------------------------------------------------------
# Path containment: every tool that takes a path goes through this.
# ---------------------------------------------------------------------------

proc resolveInside(workdir, path: string): string =
  ## Resolve `path` relative to `workdir` and ensure the result stays
  ## inside `workdir`. Raises ValueError if the path escapes.
  let abs =
    if isAbsolute(path): path
    else: workdir / path
  let normalized = absolutePath(abs).normalizedPath()
  let absWork = absolutePath(workdir).normalizedPath()
  if normalized != absWork and not normalized.startsWith(absWork & DirSep):
    raise newException(ValueError,
      "path '" & path & "' is outside the workdir")
  return normalized

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

proc readFileTool(args: JsonNode, workdir: string): string {.gcsafe.} =
  if not args.hasKey("path"):
    raise newException(ValueError, "missing required argument 'path'")
  let path = resolveInside(workdir, args["path"].getStr())
  if not fileExists(path):
    raise newException(ValueError, "file does not exist: " & path)
  return readFile(path)

proc writeFileTool(args: JsonNode, workdir: string): string {.gcsafe.} =
  if not args.hasKey("path"):
    raise newException(ValueError, "missing required argument 'path'")
  if not args.hasKey("content"):
    raise newException(ValueError, "missing required argument 'content'")
  let path = resolveInside(workdir, args["path"].getStr())
  let content = args["content"].getStr()
  # Create parent dirs if needed
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, content)
  return "wrote " & $content.len & " bytes to " & path

proc editFileTool(args: JsonNode, workdir: string): string {.gcsafe.} =
  if not args.hasKey("path"):
    raise newException(ValueError, "missing required argument 'path'")
  if not args.hasKey("old_str"):
    raise newException(ValueError, "missing required argument 'old_str'")
  if not args.hasKey("new_str"):
    raise newException(ValueError, "missing required argument 'new_str'")

  let path = resolveInside(workdir, args["path"].getStr())
  let oldStr = args["old_str"].getStr()
  let newStr = args["new_str"].getStr()

  if not fileExists(path):
    raise newException(ValueError, "file does not exist: " & path)
  let content = readFile(path)

  # Must match exactly once. Zero matches = error; multiple = ambiguous.
  let count = content.count(oldStr)
  if count == 0:
    raise newException(ValueError,
      "old_str not found in " & path & ". the model must provide an exact match.")
  if count > 1:
    raise newException(ValueError,
      "old_str matches " & $count & " times in " & path &
      ". provide more surrounding context to make it unique.")

  let updated = content.replace(oldStr, newStr)
  writeFile(path, updated)
  return "edited " & path

proc bashTool(args: JsonNode, workdir: string): string {.gcsafe.} =
  if not args.hasKey("command"):
    raise newException(ValueError, "missing required argument 'command'")
  let command = args["command"].getStr()
  # Run in workdir, capture stdout+stderr together
  let (output, exitCode) = execCmdEx(command, workingDir = workdir)
  result = output
  if exitCode != 0:
    result.add("\n[exit code: " & $exitCode & "]")

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

proc buildRegistry*(): Table[string, Tool] =
  result = initTable[string, Tool]()

  result["read_file"] = Tool(
    name: "read_file",
    description: "Read the full contents of a file. Path is relative to the workdir.",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Path to the file, relative to workdir."
        }
      },
      "required": ["path"]
    },
    run: readFileTool
  )

  result["write_file"] = Tool(
    name: "write_file",
    description: "Write content to a file, creating it if it doesn't exist and overwriting if it does. Creates parent directories as needed.",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Path to the file, relative to workdir."},
        "content": {"type": "string", "description": "The full content to write to the file."}
      },
      "required": ["path", "content"]
    },
    run: writeFileTool
  )

  result["edit_file"] = Tool(
    name: "edit_file",
    description: "Replace a unique substring in a file. The old_str must match exactly once in the file; provide surrounding context to disambiguate. Use this for surgical edits; use write_file to overwrite the whole file.",
    parameters: %*{
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Path to the file, relative to workdir."},
        "old_str": {"type": "string", "description": "Exact substring currently in the file. Must match exactly once."},
        "new_str": {"type": "string", "description": "String to replace old_str with."}
      },
      "required": ["path", "old_str", "new_str"]
    },
    run: editFileTool
  )

  result["bash"] = Tool(
    name: "bash",
    description: "Execute a shell command in the workdir. Returns combined stdout and stderr.",
    parameters: %*{
      "type": "object",
      "properties": {
        "command": {"type": "string", "description": "Shell command to execute."}
      },
      "required": ["command"]
    },
    run: bashTool
  )

proc dispatch*(registry: Table[string, Tool], name: string,
               args: JsonNode, workdir: string): string =
  ## Look up a tool by name and run it. On failure, return the error
  ## message as the tool result (so the model can see what went wrong
  ## and try again).
  if name notin registry:
    return "error: no such tool: " & name
  try:
    return registry[name].run(args, workdir)
  except ValueError as e:
    return "error: " & e.msg
  except CatchableError as e:
    return "error: " & e.msg
