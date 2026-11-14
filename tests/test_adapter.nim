## The GuiAssert adapter on the conformance application's native-window build,
## on a private Xvfb: in process and over JSON lines, the video and stills it
## records, and what it refuses. Every check runs the real application through
## the built `dvs-guiassert-notes` (or `slow-redraw`), read by real captures and
## a real OCR engine; no stand-ins.

import std/[json, os, osproc, strutils, unittest, streams, monotimes, times]
from std/posix import kill, SIGKILL, Pid
import demo_video_script_guiassert

let bin = getEnv("DVS_BIN_DIR", "build/bin")
let tool = bin / "dvs-guiassert-notes"
let dvsRoot = getEnv("DVS_ROOT", "../DemoVideoScript")
let pack = dvsRoot / "conformance/pack/notes-app.pack.yaml"
let scenarios = dvsRoot / "conformance/scenarios"
let here = currentSourcePath().parentDir

const RunDeadlineMs = 15 * 60 * 1000
  ## How long one run of a tool may take. A run that outlives it is killed
  ## (its whole process group: the application and the Xvfb it started too)
  ## and fails the test, rather than leaving it waiting forever.

proc runRaw(exe: string; args: seq[string]; deadlineMs = RunDeadlineMs): (string, int) =
  ## `exe` in a process group of its own, its output in a file — not a pipe,
  ## which a surviving grandchild (the application) would hold open — waited
  ## for until the deadline.
  let outFile = getTempDir() / ("dga-run-" & $getCurrentProcessId() & "-" &
                                $(getMonoTime().ticks mod 1_000_000_000) & ".out")
  var cmd = "exec setsid " & quoteShell(exe)
  for a in args: cmd.add " " & quoteShell(a)
  cmd.add " > " & quoteShell(outFile) & " 2>&1 < /dev/null"
  let p = startProcess("/bin/sh", args = ["-c", cmd], options = {})
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  var code = -1
  while true:
    code = p.peekExitCode
    if code != -1: break
    if getMonoTime() > deadline:
      discard kill(-Pid(p.processID), SIGKILL)
      discard p.waitForExit()
      p.close()
      let o = (try: readFile(outFile) except IOError: "")
      removeFile(outFile)
      raise newException(IOError, exe & " did not finish within " & $(deadlineMs div 1000) &
                         " s and was killed with its process group; its output:\n" & o)
    sleep(100)
  # the group's other members (an application the tool left behind) go too
  discard kill(-Pid(p.processID), SIGKILL)
  p.close()
  let o = (try: readFile(outFile) except IOError: "")
  removeFile(outFile)
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

  test "a pause between redraws shorter than the quiet span is not settled":
    # The slow-redraw application pauses 200 ms between its bursts, on its own
    # clock. Whether the end-to-end check below sees `settled` reported inside
    # such a pause depends on how fast a capture is on the machine (a loaded
    # one takes longer than the pause to compare two frames), so the span
    # itself is checked here, against the clock alone.
    let t = getMonoTime()
    check not quietLongEnough(t, t + initDuration(milliseconds = 200))
    check not quietLongEnough(t, t + initDuration(milliseconds = 299))
    check quietLongEnough(t, t + initDuration(milliseconds = 300))

  test "settled is the clock's quiet span after the last change, not one unchanged capture":
    # The settle rule over a scripted window and a scripted clock — the one
    # stand-in here, and why it is not a mock: the rule is a function of
    # which captures were equal and when, and a real window on a loaded
    # machine cannot be made to put two equal captures inside one pause on
    # demand (the end-to-end slow-redraw case below can only sometimes). Each
    # capture costs 20 ms of the clock; the window redraws once, at the third
    # capture, after two equal ones.
    var t = getMonoTime()
    var grabs = 0
    let frames = @["a", "a", "b"]
    proc grab(): string =
      t = t + initDuration(milliseconds = 20)
      inc grabs
      frames[min(grabs - 1, frames.high)]
    let settled = settleOver(grab, proc (): MonoTime = t,
                             proc (ms: int) = t = t + initDuration(milliseconds = ms), 5000)
    check settled
    # settled only once the frame after the redraw stayed for the whole span:
    # 300 ms at a capture every 80 ms is four more captures after the third
    check grabs >= 3 + 4
    # and a window that never stops changing never settles
    var n = 0
    t = getMonoTime()
    proc changing(): string =
      inc n
      t = t + initDuration(milliseconds = 20)
      $n
    check not settleOver(changing, proc (): MonoTime = t,
                         proc (ms: int) = t = t + initDuration(milliseconds = ms), 1000)

  test "settled waits for the last of several redraw bursts":
    let slow = bin / "slow-redraw"
    for i in 1 .. 3:
      let (o, code) = runRaw(slow, @["run", here / "scenarios/slow-redraw.yaml", "--pack",
                                     here / "support/slow.pack.yaml", "--backend", "guiassert",
                                     "--record", "off"])
      checkpoint o
      check code == 0

  test "a wheel turned with Shift held arrives with Shift":
    let slow = bin / "slow-redraw"
    let (o, code) = runRaw(slow, @["run", here / "scenarios/shift-wheel.yaml", "--pack",
                                   here / "support/slow.pack.yaml", "--backend", "guiassert",
                                   "--record", "off"])
    checkpoint o
    check code == 0

  test "a passing run keeps its capture's still without --record always":
    let build = getTempDir() / "dga-cap-" & $getCurrentProcessId()
    defer: removeDir(build)
    let (o, code) = runRaw(tool, @["run", scenarios / "archive-from-keyboard.yaml", "--pack", pack,
                                   "--backend", "guiassert", "--build", build])
    checkpoint o
    check code == 0
    var stills: seq[string]
    for f in walkDirRec(build / "scenario-runs"):
      if f.endsWith(".png"): stills.add f
    checkpoint $stills
    # the capture step's still, and nothing of the recording beside it
    check stills.len == 1
    check stills.len == 1 and stills[0].extractFilename.endsWith("-after-archive.png")
    check stills.len == 1 and readFile(stills[0]).startsWith("\x89PNG")
    var media = 0
    for f in walkDirRec(build / "scenario-runs"):
      if f.endsWith(".mp4"): inc media
    check media == 0
