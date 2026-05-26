import std/[net, json, strutils, terminal]

const
  OllamaHost = "localhost"
  OllamaPort = Port(11434)
  Model = "qwen3.6:35b"

proc main() =
  let body = $(%*{
    "model": Model,
    "messages": [
      {"role": "user", "content": "What's 47 * 83? Show your reasoning step by step."}
    ],
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

  # Skip response headers
  while true:
    let line = socket.recvLine()
    if line == "\r\n" or line.len == 0:
      break

  # Track whether we're in thinking or content phase so we can manage
  # terminal colors and add separators
  var inThinking = false
  var inContent = false

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

        # Thinking phase: dim text, prefixed with a header on first token
        if msg.hasKey("thinking"):
          let t = msg["thinking"].getStr()
          if t.len > 0:
            if not inThinking:
              stdout.styledWrite(styleDim, "🤔 thinking...\n")
              inThinking = true
            stdout.styledWrite(styleDim, t)
            stdout.flushFile()

        # Content phase: normal text, with a separator from thinking
        if msg.hasKey("content"):
          let c = msg["content"].getStr()
          if c.len > 0:
            if not inContent:
              if inThinking:
                stdout.write("\n\n")  # break between thinking and answer
              stdout.styledWrite(styleBright, "💬 answer:\n")
              inContent = true
            stdout.write(c)
            stdout.flushFile()

      # Final chunk: print stats
      if parsed.hasKey("done") and parsed["done"].getBool():
        echo ""
        if parsed.hasKey("eval_count") and parsed.hasKey("eval_duration"):
          let tokens = parsed["eval_count"].getInt()
          let durNs = parsed["eval_duration"].getInt()
          let durS = durNs.float / 1_000_000_000.0
          let tps = tokens.float / durS
          stdout.styledWrite(styleDim,
            "\n[", $tokens, " tokens in ", formatFloat(durS, ffDecimal, 2), "s = ",
            formatFloat(tps, ffDecimal, 1), " tok/s]\n")
        socket.close()
        return

  socket.close()

main()
