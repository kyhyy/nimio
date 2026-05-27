## Config file loading for nimio. Reads nimio.config.toml from the
## workdir if present, returns a typed config with defaults filled in.
##
## CLI flags > config file > built-in defaults. The CLI layer owns
## that precedence; this module just reports what the file said.

import std/[options, os]
import parsetoml

type
  FileConfig* = object
    ## All fields optional — `none(T)` means "not specified in the file."
    ## The caller decides what to do with each missing field.
    model*: Option[string]
    systemPrompt*: Option[string]
    agentMd*: Option[string]
    maxToolCalls*: Option[int]
    think*: Option[bool]
    contextSize*: Option[int]

const ConfigFileName* = "nimio.config.toml"

proc loadConfig*(workdir: string): FileConfig =
  ## Look for nimio.config.toml in `workdir`. If absent, return an empty
  ## FileConfig (all fields none). If present but malformed, raises
  ## ValueError with a useful message — the caller is expected to bail
  ## with a clear error rather than silently fall back.
  let path = workdir / ConfigFileName
  if not fileExists(path):
    return FileConfig()

  let toml =
    try:
      parsetoml.parseFile(path)
    except CatchableError as e:
      raise newException(ValueError,
        "failed to parse " & path & ": " & e.msg)

  template tryStr(field, key: untyped) =
    if toml.hasKey(key):
      let v = toml[key]
      if v.kind != TomlValueKind.String:
        raise newException(ValueError,
          "in " & path & ": '" & key & "' must be a string")
      result.field = some(v.getStr())

  template tryInt(field, key: untyped) =
    if toml.hasKey(key):
      let v = toml[key]
      if v.kind != TomlValueKind.Int:
        raise newException(ValueError,
          "in " & path & ": '" & key & "' must be an integer")
      result.field = some(v.getInt())

  template tryBool(field, key: untyped) =
    if toml.hasKey(key):
      let v = toml[key]
      if v.kind != TomlValueKind.Bool:
        raise newException(ValueError,
          "in " & path & ": '" & key & "' must be a boolean")
      result.field = some(v.getBool())

  tryStr(model, "model")
  tryStr(systemPrompt, "system_prompt")
  tryStr(agentMd, "agent_md")
  tryInt(maxToolCalls, "max_tool_calls")
  tryBool(think, "think")
  tryInt(contextSize, "context_size")
