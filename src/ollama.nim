## Ollama HTTP client. Handles streaming chat requests over a raw TCP
## socket. Returns both the assistant's text content and any tool calls
## the model requested. Knows nothing about agent loops, tools' actual
## behavior, or workdir — those live in higher layers.

import std/[net, json, strutils, terminal]
import httpstream

const
  OllamaHost* = "localhost"
  OllamaPort* = Port(11434)

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

proc chat*(model: string, messages: seq[Message],
           tools: JsonNode = nil,
           think: bool = false,
           numCtx: int = 0): ChatResponse =
  ## Send a chat request to Ollama and stream the response.
  ## Returns the accumulated content and any tool_calls the model emitted.
  ## If numCtx > 0, request that context window via options.num_ctx; the
  ## model is (re)loaded at that size on the next call.

  var jsonMessages = newJArray()
  for m in messages:
    jsonMessages.add(m.toJson())

  var bodyObj = %*{
    "model": model,
    "messages": jsonMessages,
    "stream": true,
    "think": think
  }
  if numCtx > 0:
    bodyObj["options"] = %*{"num_ctx": numCtx}
  if tools != nil:
    bodyObj["tools"] = tools

  let body = $bodyObj

  let socket = newSocket()
  socket.connect(OllamaHost, OllamaPort)

  let request =
    "POST /api/chat HTTP/1.1\r\n" &
    "Host: " & OllamaHost & "\r\n" &
    "Content-Type: application/json\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n" &
    "\r\n" &
    body
  socket.send(request)
  let resp = readHeaders(socket)

  var inThinking = false
  var inContent = false
  var assistantContent = ""
  var toolCalls: seq[ToolCall] = @[]
  var promptTokens = 0
  var outputTokens = 0

  proc handleLine(line: string) =
    let parsed = parseJson(line)

    if parsed.hasKey("message"):
      let msg = parsed["message"]

      if msg.hasKey("thinking"):
        let t = msg["thinking"].getStr()
        if t.len > 0:
          if not inThinking:
            stdout.styledWrite(styleDim, "🤔 thinking...\n")
            inThinking = true
          stdout.styledWrite(styleDim, t)
          stdout.flushFile()

      if msg.hasKey("content"):
        let c = msg["content"].getStr()
        if c.len > 0:
          if not inContent:
            if inThinking:
              stdout.write("\n\n")
            stdout.styledWrite(styleBright, "💬 ")
            inContent = true
          stdout.write(c)
          stdout.flushFile()
          assistantContent.add(c)

      # Tool calls arrive as a complete array in a single chunk
      if msg.hasKey("tool_calls"):
        for tc in msg["tool_calls"]:
          if tc.hasKey("function"):
            let fn = tc["function"]
            let name = fn["name"].getStr()
            let args =
              if fn.hasKey("arguments"): fn["arguments"]
              else: newJObject()
            let id =
              if tc.hasKey("id"): tc["id"].getStr()
              else: "call_" & $toolCalls.len
            toolCalls.add(ToolCall(id: id, name: name, arguments: args))

    if parsed.hasKey("done") and parsed["done"].getBool():
      echo ""
      if parsed.hasKey("prompt_eval_count"):
        promptTokens = parsed["prompt_eval_count"].getInt()
      if parsed.hasKey("eval_count") and parsed.hasKey("eval_duration"):
        outputTokens = parsed["eval_count"].getInt()
        let durNs = parsed["eval_duration"].getInt()
        let durS = durNs.float / 1_000_000_000.0
        let tps = outputTokens.float / durS
        stdout.styledWrite(styleDim,
          "[", $outputTokens, " tokens in ", formatFloat(durS, ffDecimal, 2), "s = ",
          formatFloat(tps, ffDecimal, 1), " tok/s]\n")

  if resp.chunked:
    readChunkedLines(socket, handleLine)
  elif resp.contentLength > 0:
    assistantContent = "[ollama error] " & readFixedBody(socket, resp.contentLength)
    stdout.styledWrite(styleBright, "💬 ")
    stdout.write(assistantContent)
  socket.close()
  return ChatResponse(content: assistantContent, toolCalls: toolCalls,
                       promptTokens: promptTokens, outputTokens: outputTokens)
