## Shared model types: chat messages, tool calls, and the client's response.
## JSON helpers here are used for session persistence.

import std/[json, strutils]

type
  Role* = enum
    rUser = "user"
    rAssistant = "assistant"
    rSystem = "system"
    rTool = "tool"

  ToolCall* = object
    id*: string
    name*: string
    arguments*: JsonNode

  Message* = object
    role*: Role
    content*: string
    toolCalls*: seq[ToolCall]  # only for role=rAssistant: calls the model emitted
    toolCallId*: string        # only for role=rTool: id of the call this answers

  ChatResponse* = object
    content*: string
    toolCalls*: seq[ToolCall]
    promptTokens*: int
    outputTokens*: int

proc toJson*(m: Message): JsonNode =
  result = %*{"role": $m.role, "content": m.content}
  if m.role == rAssistant and m.toolCalls.len > 0:
    var arr = newJArray()
    for tc in m.toolCalls:
      arr.add(%*{"id": tc.id, "function": {"name": tc.name, "arguments": tc.arguments}})
    result["tool_calls"] = arr
  if m.role == rTool and m.toolCallId.len > 0:
    result["tool_call_id"] = %m.toolCallId

proc messageFromJson*(j: JsonNode): Message =
  result.role = parseEnum[Role](j["role"].getStr())
  result.content = j["content"].getStr()
  if j.hasKey("tool_calls"):
    for tc in j["tool_calls"]:
      let fn = tc["function"]
      let id = if tc.hasKey("id"): tc["id"].getStr() else: ""
      result.toolCalls.add(ToolCall(id: id, name: fn["name"].getStr(), arguments: fn["arguments"]))
  if j.hasKey("tool_call_id"):
    result.toolCallId = j["tool_call_id"].getStr()
