## OpenAI-compatible chat client (OpenRouter, OpenCode, Groq, llama.cpp's
## server, LM Studio, vLLM, etc.) — anything that speaks the
## /v1/chat/completions SSE streaming protocol. Unlike Ollama's one-shot
## tool_calls array, tool calls arrive here as incremental, index-keyed
## fragments that must be assembled across chunks. Uses TLS only when
## base_url's scheme is https — local servers are typically plain http.

import std/[net, json, strutils, terminal, uri, tables]
import httpstream
import ollama

proc toWireJson(m: Message): JsonNode =
  ## OpenAI's wire format differs from nimio's internal/Ollama shape in
  ## two ways that matter: tool_calls need "type":"function" and
  ## stringified (not object) arguments, and tool-result messages must
  ## carry tool_call_id or the provider rejects the whole request.
  result = %*{"role": $m.role, "content": m.content}
  if m.role == rAssistant and m.toolCalls.len > 0:
    var arr = newJArray()
    for tc in m.toolCalls:
      arr.add(%*{"id": tc.id, "type": "function",
                 "function": {"name": tc.name, "arguments": $tc.arguments}})
    result["tool_calls"] = arr
  if m.role == rTool:
    result["tool_call_id"] = %m.toolCallId

proc chat*(baseUrl, apiKey, model: string, messages: seq[Message],
           tools: JsonNode = nil): ChatResponse =
  let u = parseUri(baseUrl)
  let useTls = u.scheme != "http"
  let defaultPort = if useTls: 443 else: 80
  let port = if u.port.len > 0: Port(parseInt(u.port)) else: Port(defaultPort)
  let path = if u.path.len > 0: u.path else: "/v1/chat/completions"

  var jsonMessages = newJArray()
  for m in messages:
    jsonMessages.add(m.toWireJson())

  var bodyObj = %*{"model": model, "messages": jsonMessages, "stream": true}
  if tools != nil:
    bodyObj["tools"] = tools
  let body = $bodyObj

  let socket = newSocket()
  if useTls:
    let ctx = newContext()
    wrapSocket(ctx, socket)
  socket.connect(u.hostname, port)

  let authHeader = if apiKey.len > 0: "Authorization: Bearer " & apiKey & "\r\n" else: ""
  let request =
    "POST " & path & " HTTP/1.1\r\n" &
    "Host: " & u.hostname & "\r\n" &
    authHeader &
    "Content-Type: application/json\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n" &
    "\r\n" & body
  socket.send(request)
  let resp = readHeaders(socket)

  var inContent = false
  var assistantContent = ""
  var toolCallIds = initTable[int, string]()
  var toolCallNames = initTable[int, string]()
  var toolCallArgs = initTable[int, string]()

  proc handleLine(line: string) =
    if not line.startsWith("data:"): return
    let payload = line[5 .. ^1].strip()
    if payload == "[DONE]" or payload.len == 0: return
    let parsed = parseJson(payload)
    if not parsed.hasKey("choices") or parsed["choices"].len == 0: return
    let choice = parsed["choices"][0]
    if not choice.hasKey("delta"): return
    let delta = choice["delta"]

    if delta.hasKey("content") and delta["content"].kind == JString:
      let c = delta["content"].getStr()
      if c.len > 0:
        if not inContent:
          stdout.styledWrite(styleBright, "💬 ")
          inContent = true
        stdout.write(c)
        stdout.flushFile()
        assistantContent.add(c)

    if delta.hasKey("tool_calls"):
      for tc in delta["tool_calls"]:
        let idx = tc["index"].getInt()
        if tc.hasKey("id") and tc["id"].kind == JString and tc["id"].getStr().len > 0:
          toolCallIds[idx] = tc["id"].getStr()
        if tc.hasKey("function"):
          let fn = tc["function"]
          if fn.hasKey("name") and fn["name"].kind == JString:
            toolCallNames[idx] = fn["name"].getStr()
          if fn.hasKey("arguments") and fn["arguments"].kind == JString:
            toolCallArgs[idx] = toolCallArgs.getOrDefault(idx, "") & fn["arguments"].getStr()

  if resp.chunked:
    readChunkedLines(socket, handleLine)
  elif resp.contentLength > 0:
    assistantContent = "[provider error] " & readFixedBody(socket, resp.contentLength)
    stdout.styledWrite(styleBright, "💬 ")
    stdout.write(assistantContent)
  socket.close()
  echo ""

  var toolCalls: seq[ToolCall] = @[]
  for idx, name in toolCallNames:
    let argsJson =
      try: parseJson(toolCallArgs.getOrDefault(idx, "{}"))
      except CatchableError: newJObject()
    toolCalls.add(ToolCall(id: toolCallIds.getOrDefault(idx, "call_" & $idx),
                           name: name, arguments: argsJson))

  return ChatResponse(content: assistantContent, toolCalls: toolCalls,
                       promptTokens: 0, outputTokens: 0)
