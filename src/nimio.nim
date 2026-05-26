import std/[net, json, strutils, terminal]

const
  OllamaHost = "localhost"
  OllamaPort = Port(11434)
  Model = "qwen3.6:35b"

proc chat(messages: seq[JsonNode]): string =
  ## Sends the conversation to Ollama, streams the response to stdout,
  ## and returns the assistant's full content (no thinking) for history.

  let body = $(%*{
    "model": Model,
    "messages": messages,
    "stream": true
  })

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

  # Skip headers
  while true:
    let line = socket.recvLine()
    if line == "\r\n" or line.len == 0:
      break

  var inThinking = false
  var inContent = false
  var assistantContent = ""  # accumulated for history
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

      if parsed.hasKey("done") and parsed["done"].getBool():
        echo ""
        if parsed.hasKey("eval_count") and parsed.hasKey("eval_duration"):
          let tokens = parsed["eval_count"].getInt()
          let durNs = parsed["eval_duration"].getInt()
          let durS = durNs.float / 1_000_000_000.0
          let tps = tokens.float / durS
          stdout.styledWrite(styleDim,
            "[", $tokens, " tokens in ", formatFloat(durS, ffDecimal, 2), "s = ",
            formatFloat(tps, ffDecimal, 1), " tok/s]\n")
        socket.close()
        return assistantContent

  socket.close()
  return assistantContent

proc main() =
  echo "nimio — talking to ", Model
  echo "type a message and press Enter. Empty input or Ctrl+D to quit."
  echo ""

  var messages: seq[JsonNode] = @[]

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

    # Append user message to history
    messages.add(%*{"role": "user", "content": trimmed})

    # Send and stream response
    let reply = chat(messages)

    # Append assistant reply to history (content only, no thinking)
    messages.add(%*{"role": "assistant", "content": reply})

    echo ""  # blank line between turns

main()
