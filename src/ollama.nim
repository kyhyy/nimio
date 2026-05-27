## Ollama HTTP client. Handles streaming chat requests over a raw TCP
## socket. Returns both the assistant's text content and any tool calls
## the model requested. Knows nothing about agent loops, tools' actual
## behavior, or workdir — those live in higher layers.

import std/[net, json, strutils, terminal]

const
  OllamaHost* = "localhost"
  OllamaPort* = Port(11434)

type
  Role* = enum
    rUser = "user"
    rAssistant = "assistant"
    rSystem = "system"
    rTool = "tool"

  Message* = object
    role*: Role
    content*: string
    toolName*: string  # only for role=rTool: which tool produced this result

  ToolCall* = object
    name*: string
    arguments*: JsonNode

  ChatResponse* = object
    content*: string
    toolCalls*: seq[ToolCall]
    promptTokens*: int
    outputTokens*: int

proc toJson*(m: Message): JsonNode =
  result = %*{"role": $m.role, "content": m.content}
  if m.role == rTool and m.toolName.len > 0:
    result["tool_name"] = %m.toolName

proc chat*(model: string, messages: seq[Message],
           tools: JsonNode = nil,
           think: bool = false): ChatResponse =
  ## Send a chat request to Ollama and stream the response.
  ## Returns the accumulated content and any tool_calls the model emitted.

  var jsonMessages = newJArray()
  for m in messages:
    jsonMessages.add(m.toJson())

  var bodyObj = %*{
    "model": model,
    "messages": jsonMessages,
    "stream": true,
    "think": think
  }
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

  while true:
    let line = socket.recvLine()
    if line == "\r\n" or line.len == 0:
      break

  var inThinking = false
  var inContent = false
  var assistantContent = ""
  var toolCalls: seq[ToolCall] = @[]
  var buffer = ""

  while true:
    let sizeLine = socket.recvLine().strip()
    if sizeLine.len == 0:
      break
    let chunkSize = parseHexInt(sizeLine)
    if chunkSize == 0:
      break

    var chunkData = newString(chunkSize)
    var received = 0
    while received < chunkSize:
      let n = socket.recv(addr chunkData[received], chunkSize - received)
      if n <= 0:
        break
      received += n

    discard socket.recvLine()
    buffer.add(chunkData)

    while true:
      let nl = buffer.find('\n')
      if nl == -1:
        break
      let line = buffer[0 ..< nl]
      buffer = buffer[nl + 1 .. ^1]
      if line.len == 0:
        continue

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
              toolCalls.add(ToolCall(name: name, arguments: args))

      if parsed.hasKey("done") and parsed["done"].getBool():
        echo ""
        var promptTokens = 0
        var outputTokens = 0
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
        socket.close()
        return ChatResponse(
          content: assistantContent,
          toolCalls: toolCalls,
          promptTokens: promptTokens,
          outputTokens: outputTokens
        )

  socket.close()
  return ChatResponse(content: assistantContent, toolCalls: toolCalls,
                       promptTokens: 0, outputTokens: 0)
