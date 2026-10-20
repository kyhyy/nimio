## Session persistence: save/load conversation history per workdir so
## `nimio --resume` can pick up where you left off. One file per workdir,
## named by an MD5 hash of its absolute path, under
## $XDG_STATE_HOME/nimio/sessions (or ~/.local/state/nimio/sessions).

import std/[json, md5, os]
import types

proc stateDir(): string =
  let xdg = getEnv("XDG_STATE_HOME")
  if xdg.len > 0: xdg / "nimio" / "sessions"
  else: getHomeDir() / ".local" / "state" / "nimio" / "sessions"

proc sessionPath*(workdir: string): string =
  let key = getMD5(absolutePath(workdir).normalizedPath())
  stateDir() / (key & ".json")

proc saveSession*(path: string, messages: seq[Message]) =
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)
  var arr = newJArray()
  for m in messages:
    arr.add(m.toJson())
  writeFile(path, $arr)

proc loadSession*(path: string): seq[Message] =
  let arr = parseJson(readFile(path))
  for j in arr:
    result.add(messageFromJson(j))
