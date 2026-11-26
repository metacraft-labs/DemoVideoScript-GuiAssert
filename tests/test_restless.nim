## Windows that never stop changing: a binding's own `settled`, and the
## sampler that keeps the frames between two reads. Every check runs a real
## application (`restless --app animate|flash`) on the adapter's private Xvfb,
## read by real captures: through the built `restless` command line for whole
## scenarios, and through the adapter in process where the check is about the
## sampler's own state. No stand-ins.

import std/[json, os, strutils, unittest, monotimes, times]
import demo_video_script_guiassert
import ./support/[runs, restless]

let bin = getEnv("DVS_BIN_DIR", "build/bin")
let tool = bin / "restless"
let here = currentSourcePath().parentDir
let pack = here / "support/restless.pack.yaml"

proc run(scenario, backend: string): JsonNode =
  let (o, _) = runRaw(tool, @["run", here / "scenarios" / scenario, "--pack", pack,
                              "--backend", backend, "--json", "--record", "off"])
  for line in o.splitLines:
    if line.startsWith("{"): return parseJson(line)
  raise newException(ValueError, "no result: " & o)

proc step(r: JsonNode; i: int): JsonNode = r["steps"][i]

suite "a window that never stops changing":
  test "wait: settled with the default rule times out, as it always did":
    let r = run("restless-wait.yaml", "still")
    checkpoint $r
    check r["outcome"].getStr == "failed"
    check r.step(1)["status"].getStr == "failed"
    check "did not happen within 3000 ms" in $r.step(1)
    check r.step(2)["status"].getStr == "not-run"

  test "with framesPresented(2) settled returns after the input's frames":
    let r = run("restless-wait.yaml", "game")
    checkpoint $r
    check r["outcome"].getStr == "passed"
    # the read straight after the wait sees the key taken: the wait returned
    # once the input had landed, not before
    check r.step(2)["status"].getStr == "passed"
    # and the settle after every input uses the same rule
    let k = run("restless-keys.yaml", "game")
    checkpoint $k
    check k["outcome"].getStr == "passed"
    # the default rule cannot settle after the same inputs
    let s = run("restless-keys.yaml", "still")
    checkpoint $s
    check s["outcome"].getStr == "failed"
    check "did not settle" in $s.step(0)

suite "a flash between two reads":
  test "a binding reading framesSince sees the flash":
    let r = run("flash.yaml", "sampled")
    checkpoint $r
    check r["outcome"].getStr == "passed"

  test "a binding reading only its own grabs does not (the control)":
    let r = run("flash.yaml", "own")
    checkpoint $r
    check r["outcome"].getStr == "failed"
    # the first read and the input passed; only the read after the flash
    # misses it
    check r.step(0)["status"].getStr == "passed"
    check r.step(1)["status"].getStr == "passed"
    check r.step(2)["status"].getStr == "failed"
    check "flashed" in $r.step(2)

suite "the sampler":
  test "its ring stays within its bounds over a long stage, and it stops with the stage":
    var ctx: GuiContext
    let binding = restlessBinding("ring", settled = framesPresented(1), app = tool)
    let launch = binding.stage
    binding.stage = proc (c: GuiContext; use: string; args: JsonNode) =
      ctx = c
      launch(c, use, args)
    let b = newGuiAssertBackend(binding)
    b.stage("launch-animate", %*{})
    b.endStage()
    # nothing samples until the binding asks
    check not ctx.sampling
    check ctx.framesSince(MonoTime()).len == 0

    ctx.startSampler(rateHz = 50, maxFrames = 8, maxAgeMs = 400)
    check ctx.sampling
    let t0 = getMonoTime()
    var maxHeld, outOfBounds = 0
    while getMonoTime() - t0 < initDuration(seconds = 6):
      let st = ctx.samplerStats
      maxHeld = max(maxHeld, st.held)
      if not st.running or st.held > 8 or st.oldestAgeMs > 400: inc outOfBounds
      # the adapter's own reads and settles go on meanwhile
      discard b.hit(10, 10)
      check b.await("settled", "", 2000)
      sleep(50)
    let st = ctx.samplerStats
    checkpoint $st
    check outOfBounds == 0
    check st.failures == 0
    # the bound did work: the ring filled, and many more frames went through it
    check maxHeld == 8
    check st.grabs > 3 * 8
    # its frames are in the order they were grabbed, each with its clock
    let fs = ctx.framesSince(t0)
    check fs.len >= 2
    for i in 1 ..< fs.len: check fs[i].at > fs[i - 1].at
    check fs.len == 0 or fs[0].at >= t0
    check fs.len == 0 or fs[^1].at <= getMonoTime()

    # the age bound, on a ring with room for far more frames than it allows
    ctx.startSampler(rateHz = 50, maxFrames = 1000, maxAgeMs = 1000)
    sleep(3000)
    let aged = ctx.samplerStats
    checkpoint $aged
    check aged.running
    check aged.oldestAgeMs <= 1000
    check aged.held >= 1
    check aged.held < aged.grabs

    # the stage ends: the sampler with it, and nothing grabs afterwards
    b.close()
    check not ctx.sampling
    let after = ctx.samplerStats
    check not after.running
    sleep(600)
    check ctx.samplerStats.grabs == after.grabs
