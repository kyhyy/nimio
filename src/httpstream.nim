## Minimal chunked-transfer HTTP body reader for the OpenAI-compatible
## client, keeping the fiddly chunk-decoding logic in one place.

import std/[net, strutils]

type
  ResponseInfo* = object
    status*: int
    chunked*: bool
    contentLength*: int

proc readHeaders*(socket: Socket): ResponseInfo =
  ## Read the status line and headers, returning whether the body is
  ## chunked-transfer-encoded or has a fixed Content-Length. Some
  ## responses (e.g. provider error bodies) use Content-Length instead
  ## of chunked encoding, and must be read differently: recvLine returns
  ## "" if the connection closes before a newline, which would otherwise
  ## look like "no more chunks" and silently swallow the body.
  let statusLine = socket.recvLine()
  # e.g. "HTTP/1.1 200 OK" -> 200
  let parts = statusLine.split(' ')
  if parts.len >= 2:
    try: result.status = parseInt(parts[1])
    except ValueError: result.status = 0
  while true:
    let line = socket.recvLine()
    if line == "\r\n" or line.len == 0: break
    let lower = line.toLowerAscii()
    if lower.startsWith("transfer-encoding:") and lower.contains("chunked"):
      result.chunked = true
    elif lower.startsWith("content-length:"):
      result.contentLength = parseInt(line.split(':', 1)[1].strip())

proc readFixedBody*(socket: Socket, length: int): string =
  result = newString(length)
  var received = 0
  while received < length:
    let n = socket.recv(addr result[received], length - received)
    if n <= 0: break
    received += n

proc readChunkedLines*(socket: Socket, onLine: proc(line: string)) =
  ## Decode a chunked-transfer-encoded body, calling `onLine` for each
  ## newline-delimited line of the decoded content.
  var buffer = ""
  while true:
    let sizeLine = socket.recvLine().strip()
    if sizeLine.len == 0: break
    let chunkSize = parseHexInt(sizeLine)
    if chunkSize == 0: break

    var chunkData = newString(chunkSize)
    var received = 0
    while received < chunkSize:
      let n = socket.recv(addr chunkData[received], chunkSize - received)
      if n <= 0: break
      received += n
    discard socket.recvLine()  # trailing \r\n after the chunk
    buffer.add(chunkData)

    while true:
      let nl = buffer.find('\n')
      if nl == -1: break
      let line = buffer[0 ..< nl]
      buffer = buffer[nl + 1 .. ^1]
      if line.len > 0:
        onLine(line)
