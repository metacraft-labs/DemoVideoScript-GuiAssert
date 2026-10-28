## The GuiAssert adapter on the conformance application's native-window build,
## on a private Xvfb: in process and over JSON lines, the video and stills it
## records, and what it refuses. Every check runs the real application through
## the built `dvs-guiassert-notes` (or `slow-redraw`), read by real captures and
## a real OCR engine; no stand-ins.

import std/[json, os, osproc, strutils, unittest, streams]

let bin = getEnv("DVS_BIN_DIR", "build/bin")
let tool = bin / "dvs-guiassert-notes"
let dvsRoot = getEnv("DVS_ROOT", "../DemoVideoScript")
let pack = dvsRoot / "conformance/pack/notes-app.pack.yaml"
let scenarios = dvsRoot / "conformance/scenarios"
let here = currentSourcePath().parentDir

proc runRaw(exe: string; args: seq[string]): (string, int) =
  let p = startProcess(exe, args = args, options = {poStdErrToStdOut})
  let o = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (o, code)

proc runJson(scenario, backend: string; extra: seq[string] = @[]): JsonNode =
  let (o, _) = runRaw(tool, @["run", scenario, "--pack", pack, "--backend", backend,
                              "--json", "--record", "off"] & extra)
  for line in o.splitLines:
    if line.startsWith("{"): return parseJson(line)
  raise newException(ValueError, "no result: " & o)

proc statuses(r: JsonNode): seq[string] =
  for s in r["steps"]: result.add s["path"].getStr & ":" & s["status"].getStr

suite "the GuiAssert adapter":
  test "in process and over JSON lines give identical step results":
    for name in ["archive-from-keyboard", "context-menu-pin"]:
      let f = scenarios / name & ".yaml"
      let a = runJson(f, "guiassert")
      let b = runJson(f, "cmd:" & tool & " --serve")
      checkpoint name & ": " & $a["message"] & " / " & $b["message"]
      check a["outcome"].getStr == "passed"
      check b["outcome"].getStr == "passed"
      check statuses(a) == statuses(b)

  test "a drag reorders the list through the operating system's pointer":
    let r = runJson(scenarios / "drag-to-reorder.yaml", "guiassert", @["--mode", "realistic"])
    checkpoint $r["message"]
    check r["outcome"].getStr == "passed"

  test "a realistic run records a video and a still per step":
    let dir = getTempDir() / "dga-rec-" & $getCurrentProcessId()
    defer: removeDir(dir)
    let (o, code) = runRaw(tool, @["run", scenarios / "archive-from-keyboard.yaml", "--pack", pack,
                                   "--backend", "guiassert", "--mode", "realistic",
                                   "--record", "always", "--out", dir])
    checkpoint o
    check code == 0
    let video = dir / "session.mp4"
    check fileExists(video)
    let (probe, pcode) = runRaw(findExe("ffprobe"), @["-v", "error", "-show_entries",
      "format=duration:stream=codec_type,width,height", "-of", "json", video])
    check pcode == 0
    let info = parseJson(probe)
    check info["streams"][0]["codec_type"].getStr == "video"
    check info["streams"][0]["width"].getInt > 0
    check parseFloat(info["format"]["duration"].getStr) > 0.5
    var stills = 0
    for f in walkDir(dir / "steps"):
      if f.path.endsWith(".png"):
        check readFile(f.path).startsWith("\x89PNG")
        inc stills
    check stills > 0
    check fileExists(dir / "manifest.json")

  test "what is not on screen is unsupported, not answered from elsewhere":
    let r = runJson(scenarios / "search-and-matchers.yaml", "guiassert")
    check r["outcome"].getStr == "unsupported"
    var caps: seq[string]
    for u in r["unsupported"]: caps.add u["capability"].getStr
    check "binding.note.property.body" in caps
    check "binding.note.property.tags" in caps

  test "a word read below the confidence floor is not accepted":
    let r = runJson(here / "scenarios/doubtful-title.yaml", "guiassert")
    checkpoint $r
    check r["outcome"].getStr == "failed"
    check "below the floor" in $r["steps"]

  test "nothing is read between a pointer press and its release":
    let r = runJson(here / "scenarios/read-while-pressed.yaml", "guiassert")
    checkpoint $r
    check r["outcome"].getStr == "failed"
    check "not yet released" in $r["steps"]

  test "settled waits for the last of several redraw bursts":
    let slow = bin / "slow-redraw"
    for i in 1 .. 3:
      let (o, code) = runRaw(slow, @["run", here / "scenarios/slow-redraw.yaml", "--pack",
                                     here / "support/slow.pack.yaml", "--backend", "guiassert",
                                     "--record", "off"])
      checkpoint o
      check code == 0
