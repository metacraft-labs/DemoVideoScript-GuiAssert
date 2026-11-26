## DemoVideoScript-GuiAssert: the scenario backend protocol over GuiAssert.
##
## The adapter answers `locate`, `read`, `send`, `await`, `record` and `hit`
## for a desktop application by vision: it reads the application's window as
## pixels (GuiAssert's capture), recognises text in them (GuiAssert's OCR
## engine), and delivers input as the operating system's synthetic pointer and
## keyboard events (GuiAssert's input backend). The application cooperates in
## nothing. A project supplies a `GuiBinding`: its stage procedures (which
## start the application), how to derive the tree of role instances from a
## frame, the conditions it can detect, and its binding resolver. Locator
## resolution over that tree is DemoVideoScript's (`surface.nim`), so it
## behaves as on every other tree-producing backend.
##
## The display is private: unless `DVS_GUIASSERT_DISPLAY` names an X display,
## the adapter starts its own Xvfb on a free display number, so a run never
## sends input to the desktop of the person who started it.
##
## GuiAssert releases whatever an input request leaves held when the request
## ends (a safety rule: a failed client never leaves a button down). So the
## adapter holds modifier keys itself, as state it adds to every later input,
## and delivers a scenario's pointer `press` … `release` as one gesture when
## the release comes. Between the two nothing has been delivered yet: the
## screen is what it was before the press, and a read there is refused.
##
## A window that never stops changing (a game, a video, an animation) is not
## served by the default meaning of `settled`, "the window stopped changing":
## a binding may give its own rule (`GuiBinding.settled`; the library's are
## `windowStill`, the default, and `framesPresented`). And a property of the
## frames between two reads (the frame that flashed) is not in any frame a read
## grabs: a binding may ask the adapter for a sampler (`startSampler`), which
## grabs frames at a declared rate into a bounded ring, between reads and
## during them, for the binding's observations to read with `framesSince`. The
## sampler runs from the call that asks for it until the stage's application is
## torn down (`close`), or until the binding stops it.

import std/[json, os, osproc, strutils, strtabs, tables, times, monotimes, options, hashes,
             locks, atomics]
from std/unicode import runes, `$`
from std/posix import Stat, stat
import gui_assert/core/[geometry, png, image, ocr_types]
from gui_assert/core/desktop_types import nil
from gui_assert/core/interfaces import CaptureBackend, InputBackend, OcrEngine, OcrRequest,
  CaptureRequest, CaptureTarget, CaptureTargetKind, RecordRequest, WindowFilter,
  GestureStep, GestureStepKind, ScrollUnit
from gui_assert/core/interfaces as gai import nil
import gui_assert/core/keys
import gui_assert/backends/capture/linux_common
import gui_assert/backends/capture/linux_x11
import gui_assert/backends/input/linux_common as input_common
import gui_assert/backends/input/linux_xtest
import gui_assert/backends/ocr/tesseract
import gui_assert/cancel
import demo_video_script/[backend, surface]

export surface, backend, image

type
  GuiDefect* = enum
    ## Planted defects for the conformance suite's negative arms (§12).
    gdNone = "none", gdStaleRead = "stale-read", gdOffByOne = "off-by-one",
    gdEarlySync = "early-sync", gdReadSideEffect = "read-side-effect"

  Frame* = object
    ## One capture of the application's window: its pixels, 8-bit RGB, and
    ## the clock it was grabbed at (when the grab started: a frame grabbed at
    ## or after an instant shows the window as it was at or after it).
    image*: RgbImage
    at*: MonoTime

  Word* = object
    ## A word the OCR engine read, in the frame's pixels.
    text*: string
    confidence*: float              ## 0 … 100, the engine's own
    x*, y*, w*, h*: int

  GuiContext* = ref object
    ## What stages and the binding work with.
    env*: Table[string, string]      ## the environment the application runs in
    workDir*: string                 ## scratch files (captures, OCR inputs)
    app*: Process
    running*: bool
    window*: geometry.Rect           ## the application's window, desktop pixels
    windowId*: string
    base*: string                    ## the scenario's directory
    state*: JsonNode                 ## per-run scratch for the binding's stages
    typed*: seq[string]              ## the text the scenario typed, in order
    confidenceFloor*: float
      ## Words the OCR engine read with a lower confidence are not accepted.
    xvfb: Process
    captureCfg: LinuxCaptureConfig
    capture: CaptureBackend
    input: InputBackend
    ocr: OcrEngine
    ocrCache: Table[Hash, (string, seq[Word])]
    lastInputAt*: MonoTime
      ## When the last input action was delivered (its end); the zero
      ## instant before the first.
    sampler: Sampler
    samplerLast: SamplerStats        ## the stopped sampler's last counts

  FrameSource* = object
    ## The frames a `settled` rule judges, in the order they were grabbed,
    ## from the instant the settle starts at (`since`: the last input, when one
    ## was sent since the previous settle, else the settle's start). With a
    ## sampler running, `next` gives the sampler's frames grabbed after the
    ## one it gave last (waiting for the next when there is none yet);
    ## without, a grab now.
    since*: MonoTime
    next*: proc (): Frame {.closure.}

  SettledRule* = proc (ctx: GuiContext; frames: FrameSource; timeoutMs: int): bool {.closure.}
    ## A binding's meaning of `settled`: true once it holds, false when it did
    ## not within `timeoutMs`.

  SamplerStats* = object
    ## What a sampler holds and has done.
    running*: bool
    rateHz*: float
    maxFrames*, maxAgeMs*: int        ## the ring's bounds
    grabs*: int                       ## grabs started
    failures*: int                    ## grabs that failed (the last one's message in `lastError`)
    held*: int                        ## frames in the ring now
    oldestAgeMs*, newestAgeMs*: float ## their ages now (0 when none)
    lastError*: string

  SamplerShared = object
    ## The ring and the counters the sampling thread and the adapter share.
    lock: Lock
    frames: seq[Frame]               ## oldest first; guarded by `lock`
    lastError: string                ## guarded by `lock`
    stop: Atomic[bool]
    grabs, failures: Atomic[int]
    maxFrames, maxAgeMs: int

  SamplerArgs = object
    shared: ptr SamplerShared
    token: CancelToken
    stateDir: string
    env: seq[(string, string)]
    rect: geometry.Rect
    intervalMs: float

  Sampler = ref object
    shared: ptr SamplerShared
    token: CancelToken
    thread: Thread[SamplerArgs]
    rateHz: float

  GuiBinding* = ref object
    name*: string
    roles*: JsonNode                 ## role -> { affordances, properties } it can deliver
    stage*: proc (ctx: GuiContext; use: string; args: JsonNode) {.closure.}
    surface*: proc (ctx: GuiContext; f: Frame): Tree {.closure.}
      ## The role instances in a frame, geometry in window pixels.
    condition*: proc (ctx: GuiContext; f: Frame; name: string): Option[bool] {.closure.}
      ## A condition the binding detects; none() when it does not know the name.
    resolveChord*: proc (ctx: GuiContext; operation: string): Option[string] {.closure.}
    anchor*: proc (ctx: GuiContext; n: SurfaceNode; anchor: string): Option[(int, int)] {.closure.}
      ## A named point of an instance, in window pixels.
    settled*: SettledRule
      ## What `settled` means for this application (the `wait: settled`
      ## condition and the settle after every input); nil is `windowStill`'s
      ## meaning, the window stopped changing.

  Pending = object
    ## A pointer press not yet delivered: the gesture it starts.
    on: bool
    steps: seq[GestureStep]
    button: gai.MouseButton

  Adapter = ref object
    b: GuiBinding
    ctx: GuiContext
    idx: SurfaceIndex
    tree: Tree
    frame: Frame
    hasFrame: bool
    inputSince: bool                 ## an input was sent since the surface was derived
    beforeSend: Tree
    hasBefore: bool
    stageClosed: bool
    held: set[Modifier]
    pending: Pending
    lastSettleAt: MonoTime
    defect: GuiDefect
    recId: string
    recPath: string

const
  DefaultConfidenceFloor* = 60.0
  QuietIntervalMs = 60
    ## The interval between the captures `settled` compares.
  QuietSpanMs = 300
    ## How long the window must stay unchanged to be settled.
  OcrCacheSize = 2048
    ## How many regions' OCR results are kept (each keyed by its pixels).
  ScreenSize = "2048x1536x24"

proc refuse(msg: string): ref BackendError = backendError(beRefused, msg)

proc gaFailure(what: string; e: ref CatchableError): ref BackendError =
  backendError(beInternal, what & ": " & e.msg)

# --- the display ------------------------------------------------------------------------

proc exists(path: string): bool =
  ## Whether anything (a socket too) is at `path`.
  var st: Stat
  stat(path.cstring, st) == 0

proc startPrivateDisplay(ctx: GuiContext) =
  ## An Xvfb of our own on the first display number nobody holds.
  let xvfb = findExe("Xvfb")
  if xvfb.len == 0:
    raise backendError(beInternal, "Xvfb is not on PATH: the adapter runs the application " &
      "on a private X display")
  var n = 90 + getCurrentProcessId() mod 400
  for attempt in 0 ..< 40:
    if not exists("/tmp/.X" & $n & "-lock") and not exists("/tmp/.X11-unix/X" & $n):
      let p = startProcess(xvfb, args = [":" & $n, "-screen", "0", ScreenSize, "-nolisten",
                                         "tcp", "-noreset"],
                           options = {poStdErrToStdOut})
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while getMonoTime() < deadline and p.running and not exists("/tmp/.X11-unix/X" & $n):
        sleep(20)
      if p.running and exists("/tmp/.X11-unix/X" & $n):
        ctx.xvfb = p
        ctx.env["DISPLAY"] = ":" & $n
        ctx.env.del("WAYLAND_DISPLAY")
        return
      if p.running: p.kill()
      discard p.waitForExit()
      p.close()
    inc n
  raise backendError(beInternal, "no free X display number for a private Xvfb")

proc ensureDisplay(ctx: GuiContext) =
  if ctx.capture.name.len > 0: return
  let given = getEnv("DVS_GUIASSERT_DISPLAY")
  if given.len > 0:
    ctx.env["DISPLAY"] = given
    ctx.env.del("WAYLAND_DISPLAY")
  else:
    ctx.startPrivateDisplay()
  let token = newCancelToken()
  ctx.captureCfg = LinuxCaptureConfig(stateDir: ctx.workDir / "state", token: token, env: ctx.env)
  ctx.capture = newLinuxX11Capture(ctx.captureCfg)
  let capture = ctx.capture
  ctx.input = newLinuxXtestInput(LinuxInputConfig(
    stateDir: ctx.workDir / "state", token: token, env: ctx.env,
    displays: proc (): seq[desktop_types.Display] = capture.displays(""),
    windows: proc (): seq[desktop_types.Window] = capture.windows("", WindowFilter()).windows))
  createDir(ctx.workDir / "state")

# --- the application ---------------------------------------------------------------------

proc startApp*(ctx: GuiContext; argv: seq[string]; title: string; timeoutMs = 20_000;
               titleContains = false) =
  ## Starts the application on the adapter's display and waits for its
  ## window, titled `title`, to be mapped; gives it the keyboard focus.
  ## With `titleContains` the window's title need only contain `title` — for
  ## an application that names its window after what it shows.
  ctx.ensureDisplay()
  var env = newStringTable(modeCaseSensitive)
  for k, v in ctx.env: env[k] = v
  try:
    ctx.app = startProcess(argv[0], args = argv[1 .. ^1], env = env,
                           options = {poParentStreams})
  except OSError as e:
    raise backendError(beStage, "cannot start " & argv[0] & ": " & e.msg)
  ctx.running = true
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    var found = false
    try:
      let filter = if titleContains: WindowFilter(titleContains: some(title))
                   else: WindowFilter(title: some(title))
      for w in ctx.capture.windows("", filter).windows:
        if w.onScreen:
          ctx.window = w.bounds
          ctx.windowId = w.id
          found = true
    except gai.BackendError as e: raise gaFailure("listing the windows", e)
    if found: break
    if not ctx.app.running:
      raise backendError(beStage, argv[0] & " exited (status " & $ctx.app.peekExitCode &
        ") before its window appeared")
    if getMonoTime() > deadline:
      raise backendError(beStage, "no window titled " & (if titleContains: "with " else: "") &
        "'" & title & "' within " & $timeoutMs & " ms")
    sleep(50)
  try: discard ctx.input.focusWindow("", ctx.windowId)
  except gai.BackendError as e: raise gaFailure("focusing the window", e)

proc requireRunning(ctx: GuiContext) =
  if not ctx.running:
    raise backendError(beInternal, "the application is not running (no stage started it)")

type Profile* = object
  ## Where a run's time goes (`DVS_GUIASSERT_PROFILE`): the captures, the
  ## OCR engine's reads (and the ones its results were kept for), the
  ## binding's surface derivations, and each backend operation.
  grabs*, ocrCalls*, ocrHits*, surfaces*: int
  settleChanges*: int
    ## captures a settle found different from the one before
  settleRows*: (int, int)
    ## the rows the last of those differed in (first, last)
  grabMs*, ocrMs*, surfaceMs*: float

var profile*: Profile
let profilePath = getEnv("DVS_GUIASSERT_PROFILE")

proc msSince(t: MonoTime): float = float((getMonoTime() - t).inMicroseconds) / 1000.0

proc profileLine(op: string; ms: float; before: Profile) =
  ## One line of the profile: the operation, its time, and what it cost in
  ## captures, OCR reads and surface derivations.
  if profilePath.len == 0: return
  let f = open(profilePath, fmAppend)
  defer: f.close()
  f.writeLine $(%*{"op": op, "ms": ms,
    "grabs": profile.grabs - before.grabs, "grabMs": profile.grabMs - before.grabMs,
    "ocr": profile.ocrCalls - before.ocrCalls, "ocrHits": profile.ocrHits - before.ocrHits,
    "ocrMs": profile.ocrMs - before.ocrMs,
    "surfaces": profile.surfaces - before.surfaces, "surfaceMs": profile.surfaceMs - before.surfaceMs,
    "settleChanges": profile.settleChanges - before.settleChanges,
    "settleRows": [profile.settleRows[0], profile.settleRows[1]]})

proc grab*(ctx: GuiContext): Frame =
  ## The application's window as it is on screen now: its pixels read
  ## straight from the X server (GuiAssert's `x11GrabRgb`), no window listing
  ## and no PNG file between, since a settle or a wait grabs many times a
  ## second.
  ctx.requireRunning()
  let t0 = getMonoTime()
  result.at = t0
  try:
    result.image = x11GrabRgb(ctx.captureCfg, ctx.window)
  except gai.BackendError as e: raise gaFailure("capturing the window", e)
  except CatchableError as e: raise gaFailure("reading the capture", e)
  inc profile.grabs
  profile.grabMs += msSince(t0)

proc pointerShape*(ctx: GuiContext): string =
  ## The shape of the pointer where it rests now (`default`, `pointer`,
  ## `text`, `col-resize`, `row-resize`, `grab`, `grabbing`, `not-allowed`,
  ## `wait`, `crosshair`; "" when the image says none of them). The X server
  ## draws the pointer itself, so no frame shows it: this asks the server for
  ## the cursor's image (GuiAssert's `x11PointerShape`, XFixes).
  ctx.requireRunning()
  try:
    let img = x11PointerShape(ctx.captureCfg)
    # the theme the application's cursors come from, when its environment
    # names one (XCURSOR_THEME on XCURSOR_PATH): its cursor files say which
    # shape an image is exactly
    var themeCursors = ""
    let theme = ctx.env.getOrDefault("XCURSOR_THEME", "")
    if theme.len > 0:
      for d in ctx.env.getOrDefault("XCURSOR_PATH", "").split(':'):
        if themeCursors.len == 0 and d.len > 0 and dirExists(d / theme / "cursors"):
          themeCursors = d / theme / "cursors"
    result = pointerShapeOf(img, themeCursors)
    if getEnv("DVS_GUIASSERT_POINTER_DEBUG").len > 0:
      stderr.writeLine "pointer ", result, " name='", img.name, "' ", img.width, "x", img.height,
        " hot ", img.xhot, ",", img.yhot
      for row in img.mask: stderr.writeLine "  ", row
  except gai.BackendError as e: raise gaFailure("reading the pointer's shape", e)

proc recognize*(ctx: GuiContext; img: GrayImage; psm = 6): seq[Word] =
  ## The words the OCR engine reads in `img` (dark text on a light ground),
  ## as one block of text (Tesseract's page segmentation mode `psm`: 6 a
  ## block, 7 a single line). Results are kept per image, so an unchanged
  ## frame is not read twice.
  let h = hash(img.pixels) !& psm
  if ctx.ocrCache.hasKey(h) and ctx.ocrCache[h][0] == img.pixels:
    inc profile.ocrHits
    return ctx.ocrCache[h][1]
  let t0 = getMonoTime()
  defer:
    inc profile.ocrCalls
    profile.ocrMs += msSince(t0)
  let path = ctx.workDir / "ocr.png"
  writeFile(path, encodePng(img))
  try:
    let r = ctx.ocr.recognize(OcrRequest(imagePath: path, psm: some(psm)))
    for w in r.words:
      result.add Word(text: w.text, confidence: w.confidence, x: w.bbox[0], y: w.bbox[1],
                      w: w.bbox[2], h: w.bbox[3])
  except gai.BackendError as e: raise gaFailure("recognising text", e)
  # a surface reads tens of regions; a cache smaller than a few surfaces'
  # worth was cleared within one wait, and every poll read them all again
  if ctx.ocrCache.len > OcrCacheSize: ctx.ocrCache.clear()
  ctx.ocrCache[h] = (img.pixels, result)

proc luma*(f: Frame; x, y: int): int =
  ## The gray value of one pixel of the frame.
  let i = (y * f.image.width + x) * 3
  rgbToGray(ord(f.image.pixels[i]), ord(f.image.pixels[i + 1]), ord(f.image.pixels[i + 2]))

proc smooth*(img: GrayImage; radius: int): GrayImage =
  ## A box blur of `radius` pixels (separable, two passes). Text drawn by
  ## pixel replication reads better after it: the OCR engine is trained on
  ## smooth glyph edges, not on square steps.
  if radius <= 0: return img
  let w = img.width
  let h = img.height
  var tmp = newImage(GrayImage, w, h)
  result = newImage(GrayImage, w, h)
  for y in 0 ..< h:
    var s = 0
    var n = 0
    for x in -radius .. radius:
      if x >= 0 and x < w: (s += ord(img.pixels[y * w + x]); inc n)
    for x in 0 ..< w:
      tmp.pixels[y * w + x] = char(s div n)
      let outX = x - radius
      let inX = x + radius + 1
      if outX >= 0: (s -= ord(img.pixels[y * w + outX]); dec n)
      if inX < w: (s += ord(img.pixels[y * w + inX]); inc n)
  for x in 0 ..< w:
    var s = 0
    var n = 0
    for y in -radius .. radius:
      if y >= 0 and y < h: (s += ord(tmp.pixels[y * w + x]); inc n)
    for y in 0 ..< h:
      result.pixels[y * w + x] = char(s div n)
      let outY = y - radius
      let inY = y + radius + 1
      if outY >= 0: (s -= ord(tmp.pixels[outY * w + x]); dec n)
      if inY < h: (s += ord(tmp.pixels[inY * w + x]); inc n)

# --- the surface ------------------------------------------------------------------------

proc quietLongEnough*(quietSince, sampled: MonoTime): bool =
  ## Whether a window unchanged from `quietSince` to `sampled` has settled:
  ## at least `QuietSpanMs` of the clock. An application's pause between two
  ## redraws that is shorter than that is not the end of its redraw.
  (sampled - quietSince).inMilliseconds >= QuietSpanMs

proc settleOver*(grab: proc (): string; now: proc (): MonoTime; pause: proc (ms: int);
                 timeoutMs: int): bool =
  ## The settle rule over any frame source and clock: captures
  ## `QuietIntervalMs` apart were all equal over at least `QuietSpanMs`, from
  ## the end of the first capture to the start of the last. Measured by the
  ## clock, not by a count of captures, because a capture's own duration
  ## varies with the machine's load.
  let deadline = now() + initDuration(milliseconds = timeoutMs)
  var last = grab()
  var quietSince = now()
  while now() < deadline:
    pause(QuietIntervalMs)
    let started = now()
    let next = grab()
    if next == last:
      if quietLongEnough(quietSince, started): return true
    else:
      quietSince = now()
    last = next
  false

proc settle(a: Adapter; timeoutMs = 5000): bool =
  ## The window stopped changing (`settleOver`, on the window's captures and
  ## the real clock).
  var last = ""
  let width = max(1, a.ctx.window.width) * 3
  proc grabNoting(): string =
    result = a.ctx.grab().image.pixels
    if profilePath.len > 0 and last.len > 0 and result != last:
      inc profile.settleChanges
      var first = -1
      var final = -1
      for i in 0 ..< min(result.len, last.len):
        if result[i] != last[i]:
          if first < 0: first = i
          final = i
      profile.settleRows = (first div width, final div width)
    last = result
  settleOver(grabNoting, getMonoTime, proc (ms: int) = sleep(ms), timeoutMs)

# --- continuous sampling ----------------------------------------------------------------

proc ageMs(t, now: MonoTime): float = float((now - t).inMicroseconds) / 1000.0

proc prune(s: ptr SamplerShared; now: MonoTime) =
  ## The ring within its bounds: at most `maxFrames` frames, none older than
  ## `maxAgeMs`. The caller holds the lock.
  while s.frames.len > s.maxFrames: s.frames.delete(0)
  while s.frames.len > 0 and ageMs(s.frames[0].at, now) > float(s.maxAgeMs): s.frames.delete(0)

proc samplerLoop(args: SamplerArgs) {.thread.} =
  ## The sampling thread: a grab every `intervalMs` (no burst to catch up
  ## after a slow one), each frame stamped with the clock its grab started
  ## at, until asked to stop. It has a capture configuration of its own (its
  ## own state directory, so its grabs' files never meet the adapter's) and
  ## touches nothing of the adapter's but the shared ring.
  {.cast(gcsafe).}:
    let s = args.shared
    var env = initTable[string, string]()
    for (k, v) in args.env: env[k] = v
    let cfg = LinuxCaptureConfig(stateDir: args.stateDir, token: args.token, env: env)
    var due = getMonoTime()
    while not s.stop.load:
      let t0 = getMonoTime()
      discard s.grabs.fetchAdd(1)
      try:
        let img = x11GrabRgb(cfg, args.rect)
        withLock s.lock:
          s.frames.add Frame(image: img, at: t0)
          prune(s, getMonoTime())
      except CatchableError as e:
        if not s.stop.load:
          discard s.failures.fetchAdd(1)
          withLock s.lock: s.lastError = e.msg
      due = due + initDuration(microseconds = int(args.intervalMs * 1000))
      let now = getMonoTime()
      if due < now: due = now
      while not s.stop.load and getMonoTime() < due:
        sleep(max(1, min(5, int((due - getMonoTime()).inMilliseconds))))

proc sampling*(ctx: GuiContext): bool =
  ## Whether a sampler is running.
  ctx.sampler != nil

proc stopSampler*(ctx: GuiContext) =
  ## Stops the sampler (a grab in flight is cancelled) and drops its frames;
  ## nothing when none runs. Its last counts stay in `samplerStats`.
  let sm = ctx.sampler
  if sm == nil: return
  let s = sm.shared
  s.stop.store(true)
  sm.token.cancel(crRequest)
  joinThread(sm.thread)
  withLock s.lock:
    ctx.samplerLast = SamplerStats(running: false, rateHz: sm.rateHz, maxFrames: s.maxFrames,
                                   maxAgeMs: s.maxAgeMs, grabs: s.grabs.load,
                                   failures: s.failures.load, lastError: s.lastError)
    s.frames = @[]
    s.lastError = ""
  deinitLock(s.lock)
  deallocShared(s)
  sm.token.free()
  ctx.sampler = nil

proc startSampler*(ctx: GuiContext; rateHz: float; maxFrames: int; maxAgeMs: int) =
  ## Grabs the application's window `rateHz` times a second, between and
  ## during the adapter's own reads, into a ring of at most `maxFrames`
  ## frames none older than `maxAgeMs`, for `framesSince`. A sampler already
  ## running is replaced. It stops when the stage's application is torn down
  ## (the backend's `close`), or at `stopSampler`.
  ctx.requireRunning()
  if rateHz <= 0 or maxFrames < 1 or maxAgeMs < 1:
    raise backendError(beInternal, "a sampler needs a positive rate, frame count and age")
  ctx.stopSampler()
  # the helper resolved here, once: the thread then finds it in its environment
  var helper = ""
  try: helper = helperPath(ctx.captureCfg, linuxX11Name, "x11_probe")
  except gai.BackendError as e: raise gaFailure("finding the capture helper", e)
  var env: seq[(string, string)]
  for k, v in ctx.env:
    if k != "GUI_ASSERT_HELPER_DIR": env.add (k, v)
  env.add ("GUI_ASSERT_HELPER_DIR", helper.parentDir)
  let dir = ctx.workDir / "sampler"
  createDir(dir)
  let s = cast[ptr SamplerShared](allocShared0(sizeof(SamplerShared)))
  initLock(s.lock)
  s.maxFrames = maxFrames
  s.maxAgeMs = maxAgeMs
  let sm = Sampler(shared: s, token: newCancelToken(), rateHz: rateHz)
  createThread(sm.thread, samplerLoop, SamplerArgs(shared: s, token: sm.token, stateDir: dir,
    env: env, rect: ctx.window, intervalMs: 1000.0 / rateHz))
  ctx.sampler = sm

proc samplerStats*(ctx: GuiContext): SamplerStats =
  ## The running sampler's ring and counts now; the last counts of the one
  ## stopped last (`running` false) when none runs.
  let sm = ctx.sampler
  if sm == nil: return ctx.samplerLast
  let s = sm.shared
  withLock s.lock:
    let now = getMonoTime()
    prune(s, now)
    result = SamplerStats(running: true, rateHz: sm.rateHz, maxFrames: s.maxFrames,
                          maxAgeMs: s.maxAgeMs, grabs: s.grabs.load, failures: s.failures.load,
                          held: s.frames.len, lastError: s.lastError)
    if s.frames.len > 0:
      result.oldestAgeMs = ageMs(s.frames[0].at, now)
      result.newestAgeMs = ageMs(s.frames[^1].at, now)

proc framesSince*(ctx: GuiContext; t: MonoTime): seq[Frame] =
  ## The sampled frames grabbed at or after `t` that the ring still holds,
  ## oldest first; none without a sampler.
  let sm = ctx.sampler
  if sm == nil: return
  let s = sm.shared
  withLock s.lock:
    prune(s, getMonoTime())
    for f in s.frames:
      if f.at >= t: result.add f

proc sampledAfter(ctx: GuiContext; t: MonoTime; strict: bool): Option[Frame] =
  ## The first sampled frame grabbed after `t` (at or after, unless `strict`).
  let sm = ctx.sampler
  if sm == nil: return
  let s = sm.shared
  withLock s.lock:
    for f in s.frames:
      if f.at > t or (not strict and f.at == t): return some(f)

# --- settled ---------------------------------------------------------------------------

proc windowStill*(): SettledRule =
  ## The default meaning of `settled`: the window stopped changing
  ## (`settleOver` on the frame source).
  result = proc (ctx: GuiContext; frames: FrameSource; timeoutMs: int): bool =
    settleOver(proc (): string = frames.next().image.pixels, getMonoTime,
               proc (ms: int) = sleep(ms), timeoutMs)

proc framesPresented*(n: int): SettledRule =
  ## `settled` for a window that never stops changing: `n` more frames were
  ## presented after the input, each seen as a frame different from the one
  ## before it. The first frame of the source (the window at the input) is
  ## the one they are counted from, so a frame the application drew while the
  ## input was on its way counts as one of them at most: a binding asks for
  ## two when its application takes an input into the frame after the one it
  ## was drawing.
  result = proc (ctx: GuiContext; frames: FrameSource; timeoutMs: int): bool =
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    var last = frames.next()
    var seen = 0
    while seen < n:
      if getMonoTime() > deadline: return false
      let f = frames.next()
      if f.image.pixels != last.image.pixels: inc seen
      last = f
    true

proc frameSource(a: Adapter): FrameSource =
  let ctx = a.ctx
  let since = (if ctx.lastInputAt > a.lastSettleAt: ctx.lastInputAt else: getMonoTime())
  var cursor = since
  var first = true
  result.since = since
  result.next = proc (): Frame =
    if ctx.sampler != nil:
      # the sampler's next frame; a grab of our own when it stalls (a frame
      # source never waits longer than a few of the sampler's intervals)
      let wait = getMonoTime() + initDuration(milliseconds = 250 + int(4000.0 / ctx.sampler.rateHz))
      while getMonoTime() < wait:
        let f = ctx.sampledAfter(cursor, strict = not first)
        if f.isSome:
          first = false
          cursor = f.get.at
          return f.get
        sleep(2)
    result = ctx.grab()
    first = false
    cursor = result.at

proc settled(a: Adapter; timeoutMs = 5000): bool =
  ## `settled` as the binding means it: its own rule when it has one, else
  ## the window stopped changing.
  if a.b.settled != nil:
    result = a.b.settled(a.ctx, a.frameSource(), timeoutMs)
  else:
    result = a.settle(timeoutMs)
  a.lastSettleAt = getMonoTime()

proc refresh(a: Adapter) =
  a.ctx.requireRunning()
  let f = a.ctx.grab()
  if a.hasFrame and not a.inputSince and f.image.pixels == a.frame.image.pixels: return
  a.inputSince = false
  a.frame = f
  a.hasFrame = true
  let t0 = getMonoTime()
  a.tree = a.b.surface(a.ctx, f)
  inc profile.surfaces
  profile.surfaceMs += msSince(t0)

proc requireNothingPending(a: Adapter; what: string) =
  if a.pending.on:
    raise refuse("a pointer button is pressed and not yet released: GuiAssert delivers a " &
      "press and its release together, so nothing can be " & what & " between them")

proc treeForRead(a: Adapter): Tree =
  if a.defect == gdStaleRead and a.hasBefore: a.beforeSend
  else:
    a.refresh()
    a.tree

proc pointOf(a: Adapter; id, anchor: string): Point =
  ## The desktop point an input aimed at an instance lands on.
  a.refresh()
  let n = a.idx.lookup(a.tree, id)
  var p = (int(n.x + n.w / 2), int(n.y + n.h / 2))
  if anchor.len > 0 and anchor != "center":
    let r = (if a.b.anchor == nil: none((int, int)) else: a.b.anchor(a.ctx, n, anchor))
    if r.isNone: raise backendError(beUnsupported, "no anchor '" & anchor & "' on " & n.keyText)
    p = r.get
  if a.defect == gdOffByOne: p[1] += int(n.h)
  point(a.ctx.window.x + p[0], a.ctx.window.y + p[1])

proc pathPoint(a: Adapter; p: JsonNode): Point =
  point(a.ctx.window.x + int(p[0].getFloat + 0.5), a.ctx.window.y + int(p[1].getFloat + 0.5))

# --- input ------------------------------------------------------------------------------

proc modOf(name: string): Option[Modifier] =
  case name
  of "Shift": some(modShift)
  of "Ctrl": some(modCtrl)
  of "Alt": some(modAlt)
  of "Meta": some(modCmd)
  else: none(Modifier)

proc spelled(mods: set[Modifier]): seq[string] =
  for m in Modifier:
    if m in mods: result.add $m

proc keyName(key: string): string =
  ## The canonical key name (Format §4.3.3) as GuiAssert's key table spells it.
  if key == "Plus": return "+"
  if key == "Backspace": return "BackSpace"
  if modOf(key).isSome or key == "Mod":
    raise refuse("the " & key & " key on its own is a modifier: press and release it")
  let c = canonicalKey(key)
  if c.len == 0: raise refuse("GuiAssert has no key '" & key & "'")
  c

proc deliver(a: Adapter; what: string; body: proc ()) =
  try: body()
  except gai.BackendError as e: raise gaFailure(what, e)
  except KeyComboError as e: raise refuse(e.msg)

proc sendKey(a: Adapter; key: string; mods: set[Modifier]) =
  let k = keyName(key)
  var combo = modifierSpelling(mods)
  if combo.len > 0: combo.add '+'
  combo.add(if k == "+": "+" else: k)
  var normalized = ""
  try: normalized = normalizeCombo(combo)
  except KeyComboError as e: raise refuse(e.msg)
  a.deliver("sending " & normalized, proc () = discard a.ctx.input.key("", normalized))

proc buttonOf(v: JsonNode): gai.MouseButton =
  case v{"button"}.getStr("left")
  of "middle": gai.mbMiddle
  of "right": gai.mbRight
  else: gai.mbLeft

proc pause(ms: float) =
  if ms > 0: sleep(int(ms + 0.5))

proc pathSteps(a: Adapter; path: JsonNode): seq[GestureStep] =
  ## A realistic pointer path as gesture steps: a move to each point at its time.
  if path == nil: return
  var last = 0.0
  for p in path:
    let wait = int(p[2].getFloat - last + 0.5)
    if wait > 0: result.add GestureStep(kind: gsWait, ms: wait)
    last = p[2].getFloat
    result.add GestureStep(kind: gsMove, to: a.pathPoint(p))

proc keyDowns(mods: set[Modifier]): seq[GestureStep] =
  for m in spelled(mods): result.add GestureStep(kind: gsKeyDown, combo: m)

proc gesture(a: Adapter; steps: seq[GestureStep]) =
  if steps.len == 0: return
  a.deliver("delivering a gesture", proc () = discard a.ctx.input.gesture("", steps))

proc sendAction(a: Adapter; act: JsonNode) =
  a.ctx.requireRunning()
  if not a.pending.on:
    a.refresh()
    a.beforeSend = a.tree
    a.hasBefore = true
  let targets = act{"targets"}
  let timing = act{"timing"}
  if act.hasKey("ext"):
    raise backendError(beUnsupported, "no extension step '" & act["ext"].getStr & "'")
  if a.pending.on and not (act.hasKey("move") or act.hasKey("release")):
    a.requireNothingPending("sent")
  if act.hasKey("key"):
    a.sendKey(act["key"].getStr, a.held)
  elif act.hasKey("chord"):
    for c in act["chord"].getStr.split(' '):
      let parts = c.split('+')
      var mods = a.held
      for m in parts[0 ..< parts.high]:
        let mm = modOf(m)
        if mm.isNone: raise refuse("'" & m & "' is not a modifier")
        mods.incl mm.get
      a.sendKey(parts[^1], mods)
  elif act.hasKey("type"):
    let text = (if act["type"].kind == JString: act["type"].getStr else: act["type"]{"text"}.getStr)
    a.ctx.typed.add text
    let delays = timing{"keyDelaysMs"}
    if delays == nil or delays.len == 0:
      a.deliver("typing", proc () = discard a.ctx.input.typeText("", text, 0))
    else:
      var k = 0
      for r in text.runes:
        if k < delays.len: pause(delays[k].getFloat)
        let s = $r
        a.deliver("typing", proc () = discard a.ctx.input.typeText("", s, 0))
        inc k
  elif act.hasKey("press") or act.hasKey("release"):
    let isPress = act.hasKey("press")
    let v = (if isPress: act["press"] else: act["release"])
    if v.hasKey("key"):
      let m = modOf(v["key"].getStr)
      if m.isNone:
        raise refuse("GuiAssert sends a key's press and release together; it cannot hold '" &
          v["key"].getStr & "'")
      if isPress: a.held.incl m.get else: a.held.excl m.get
    elif isPress:
      if a.pending.on: raise refuse("a pointer button is already pressed")
      let p = a.pointOf(targets["target"].getStr, v{"anchor"}.getStr)
      a.pending = Pending(on: true, button: buttonOf(v))
      a.pending.steps = keyDowns(a.held) & a.pathSteps(timing{"path"})
      a.pending.steps.add GestureStep(kind: gsMove, to: p)
      a.pending.steps.add GestureStep(kind: gsPress, at: p, button: buttonOf(v))
    else:
      if not a.pending.on: raise refuse("release of a pointer button that is not pressed")
      let p = a.pointOf(targets["target"].getStr, v{"anchor"}.getStr)
      a.pending.steps.add a.pathSteps(timing{"path"})
      a.pending.steps.add GestureStep(kind: gsMove, to: p)
      a.pending.steps.add GestureStep(kind: gsRelease, at: p, button: a.pending.button)
      let steps = a.pending.steps
      a.pending = Pending()
      a.gesture(steps)
  elif act.hasKey("move") or act.hasKey("hover"):
    let v = (if act.hasKey("move"): act["move"] else: act["hover"])
    let p = a.pointOf(targets["target"].getStr, v{"anchor"}.getStr)
    var steps = a.pathSteps(timing{"path"})
    steps.add GestureStep(kind: gsMove, to: p)
    if a.pending.on:
      a.pending.steps.add steps
    else:
      a.gesture(keyDowns(a.held) & steps)
    if act.hasKey("hover"):
      let f = v{"for"}.getStr("")
      if f.len > 0:
        pause(if f.endsWith("ms"): parseFloat(f[0 ..< f.len - 2])
              elif f.endsWith("s"): parseFloat(f[0 ..< f.len - 1]) * 1000
              else: parseFloat(f) * 1000)
  elif act.hasKey("click"):
    let v = act["click"]
    var mods = a.held
    for m in v{"modifiers"}.getElems:
      let mm = modOf(m.getStr)
      if mm.isNone: raise refuse("'" & m.getStr & "' is not a modifier")
      mods.incl mm.get
    let p = a.pointOf(targets["target"].getStr, v{"anchor"}.getStr)
    if timing{"path"} != nil: a.gesture(a.pathSteps(timing["path"]))
    let btn = buttonOf(v)
    let count = v{"count"}.getInt(1)
    a.deliver("clicking", proc () = discard a.ctx.input.click("", p, btn, count, spelled(mods)))
  elif act.hasKey("drag"):
    let v = act["drag"]
    var mods = a.held
    for m in v{"modifiers"}.getElems:
      let mm = modOf(m.getStr)
      if mm.isNone: raise refuse("'" & m.getStr & "' is not a modifier")
      mods.incl mm.get
    let btn = buttonOf(v)
    let fa = (if v["from"].kind == JObject: v["from"]{"anchor"}.getStr else: "")
    let ta = (if v["to"].kind == JObject: v["to"]{"anchor"}.getStr else: "")
    let p0 = a.pointOf(targets["from"].getStr, fa)
    var waypoints: seq[Point]
    for vid in targets{"via"}.getElems: waypoints.add a.pointOf(vid.getStr, "")
    let p1 = a.pointOf(targets["to"].getStr, ta)
    var steps = keyDowns(mods)
    steps.add GestureStep(kind: gsMove, to: p0)
    steps.add GestureStep(kind: gsPress, at: p0, button: btn)
    steps.add GestureStep(kind: gsWait, ms: 40)
    for w in waypoints:
      steps.add GestureStep(kind: gsMove, to: w)
      steps.add GestureStep(kind: gsWait, ms: 40)
    steps.add a.pathSteps(timing{"path"})
    steps.add GestureStep(kind: gsMove, to: p1)
    steps.add GestureStep(kind: gsWait, ms: 40)
    steps.add GestureStep(kind: gsRelease, at: p1, button: btn)
    a.gesture(steps)
  elif act.hasKey("wheel"):
    let v = act["wheel"]
    let p = a.pointOf(targets["target"].getStr, v{"anchor"}.getStr)
    let n = v{"amount"}.getInt(1)
    let (dx, dy) = case v{"direction"}.getStr
      of "up": (0, -n)
      of "down": (0, n)
      of "left": (-n, 0)
      else: (n, 0)
    if a.held == {}:
      a.deliver("scrolling", proc () = discard a.ctx.input.scroll("", p, dx, dy, suLine))
    else:
      # the held modifiers are down while the wheel turns (Shift+wheel): one
      # gesture, which releases them again at its end as every request does
      a.gesture(keyDowns(a.held) &
                @[GestureStep(kind: gsScroll, wheelAt: p, dx: dx, dy: dy, unit: suLine)])
  else:
    raise backendError(beProtocol, "send: no input action in " & $act)
  a.idx.clear()
  a.ctx.lastInputAt = getMonoTime()
  # an input can change what the pixels do not show (the pointer's shape
  # under a hover): the next read derives the surface afresh, even from an
  # unchanged frame (the OCR engine's results are kept per image, so that
  # costs no second reading of the text)
  a.inputSince = true

# --- the backend -------------------------------------------------------------------------

const Capabilities = ["input.key", "input.chord", "input.text", "input.pointer.move",
                      "input.pointer.click", "input.pointer.drag", "input.wheel", "input.hover",
                      "observe.text", "observe.geometry", "observe.focus", "sync.visual-settle",
                      "record.video", "record.still"]
  ## What vision can do. Not `observe.style` (the adapter reads text and where
  ## it is, not how it is styled) and not `observe.image`.

proc newOfflineContext*(workDir: string): GuiContext =
  ## A context with the OCR engine and no application: for reading saved
  ## frames (a run's stills) with a binding's `surface`, to see what it
  ## derives from them. Nothing that needs the application (a grab, input,
  ## the pointer) works on it.
  createDir(workDir)
  GuiContext(workDir: workDir, state: newJObject(), confidenceFloor: DefaultConfidenceFloor,
             ocr: newTesseractOcr())

proc frameOf*(png: string): Frame =
  ## A saved PNG as a frame.
  Frame(image: decodePngRgb(readFile(png)))

proc newGuiAssertBackend*(binding: GuiBinding; defect = gdNone;
                          confidenceFloor = DefaultConfidenceFloor): Backend =
  let work = getTempDir() / ("dvs-guiassert-" & $getCurrentProcessId() & "-" &
                             $(getMonoTime().ticks mod 1_000_000_000))
  createDir(work)
  var env = initTable[string, string]()
  for k, v in envPairs(): env[k] = v
  env.del("DISPLAY")
  let ctx = GuiContext(env: env, workDir: work, state: newJObject(),
                       confidenceFloor: confidenceFloor, ocr: newTesseractOcr())
  let a = Adapter(b: binding, ctx: ctx, defect: defect)
  result = Backend()
  result.hello = proc (): Hello =
    Hello(backend: "guiassert", version: "1", platform: "linux", capabilities: @Capabilities,
          bindings: binding.roles, units: "px")
  result.stage = proc (use: string; args: JsonNode) =
    if a.stageClosed:
      raise backendError(beStageClosed, "the stage has ended; '" & use & "' cannot run now")
    a.ctx.base = args{"$base"}.getStr(".")
    let t0 = getMonoTime()
    let before = profile
    defer: profileLine("stage " & use, msSince(t0), before)
    try: binding.stage(a.ctx, use, args)
    except BackendError: raise
    except CatchableError as e: raise backendError(beStage, use & ": " & e.msg)
  result.endStage = proc () =
    let t0 = getMonoTime()
    let before = profile
    defer: profileLine("end-stage (launch settled)", msSince(t0), before)
    a.stageClosed = true
    if a.ctx.running: discard a.settled()
  result.resolveChord = proc (operation: string): Option[string] =
    if binding.resolveChord == nil: none(string) else: binding.resolveChord(a.ctx, operation)
  result.locate = proc (locator: JsonNode): LocateResult =
    let t0 = getMonoTime()
    let before = profile
    defer: profileLine("locate", msSince(t0), before)
    if not a.pending.on: a.refresh()
    a.idx.locate(a.tree, locator)
  result.read = proc (instance: string; properties: seq[string]): JsonNode =
    let t0 = getMonoTime()
    let before = profile
    defer: profileLine("read", msSince(t0), before)
    a.requireNothingPending("read")
    let t = a.treeForRead()
    let n = a.idx.lookup(t, instance)
    result = readNode(n, properties)
    if a.defect == gdReadSideEffect and n.role != t.root.role:
      # the planted defect: reading clicks the instance with Ctrl
      let p = point(a.ctx.window.x + int(n.x) + 3, a.ctx.window.y + int(n.y + n.h / 2))
      a.deliver("clicking", proc () = discard a.ctx.input.click("", p, gai.mbLeft, 1, @["ctrl"]))
      discard a.settled(1000)
  result.send = proc (action: JsonNode) =
    let t0 = getMonoTime()
    let before = profile
    defer:
      var kind = ""
      for k, _ in action:
        if k notin ["targets", "timing"]: kind = k
      profileLine("send " & kind, msSince(t0), before)
    a.sendAction(action)
  result.await = proc (condition, instance: string; timeoutMs: int): bool =
    let t0 = getMonoTime()
    let before = profile
    defer: profileLine("await " & condition, msSince(t0), before)
    a.ctx.requireRunning()
    if a.defect == gdEarlySync: return true
    if a.pending.on:
      # nothing has been delivered since the last settled screen
      return true
    if condition == "settled": return a.settled(timeoutMs)
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while true:
      let met = binding.condition(a.ctx, a.ctx.grab(), condition)
      if met.isNone:
        raise backendError(beUnsupported, "the " & binding.name & " binding cannot detect '" &
          condition & "'")
      if met.get: return true
      if getMonoTime() > deadline: return false
      sleep(50)
  result.record = proc (op: RecordOp; args: JsonNode): JsonNode =
    result = %*{"files": []}
    case op
    of recStart:
      a.ctx.requireRunning()
      let dir = args{"dir"}.getStr
      createDir(dir)
      a.recPath = dir / "session.mp4"
      try:
        a.recId = a.ctx.capture.startRecording(RecordRequest(
          target: CaptureTarget(kind: ctkRegion, region: a.ctx.window), outPath: a.recPath,
          fps: 15.0)).id
      except gai.BackendError as e: raise gaFailure("starting the recording", e)
    of recMark: discard
    of recStill:
      a.ctx.requireRunning()
      let base = args{"dir"}.getStr(".") / args{"path"}.getStr("still")
      createDir(base.parentDir)
      try:
        discard a.ctx.capture.capture(CaptureRequest(
          target: CaptureTarget(kind: ctkRegion, region: a.ctx.window), outPath: base & ".png"))
      except gai.BackendError as e: raise gaFailure("capturing a still", e)
      result["files"] = %[base & ".png"]
    of recStop:
      if a.recId.len > 0:
        try:
          let r = a.ctx.capture.stopRecording(a.recId)
          result["files"] = %[r.path]
        except gai.BackendError as e: raise gaFailure("stopping the recording", e)
        a.recId = ""
  result.hit = proc (x, y: float): Option[string] =
    a.refresh()
    a.tree.hit(x, y)
  result.close = proc () =
    # the sampler ends with the stage, before the application and the display it grabs
    a.ctx.stopSampler()
    if a.recId.len > 0:
      try: discard a.ctx.capture.stopRecording(a.recId)
      except CatchableError: discard
      a.recId = ""
    if a.ctx.running:
      if a.ctx.app.running:
        a.ctx.app.terminate()
        discard a.ctx.app.waitForExit(3000)
        if a.ctx.app.running: a.ctx.app.kill()
      a.ctx.app.close()
      a.ctx.running = false
    if a.ctx.xvfb != nil:
      a.ctx.xvfb.terminate()
      discard a.ctx.xvfb.waitForExit(3000)
      if a.ctx.xvfb.running: a.ctx.xvfb.kill()
      a.ctx.xvfb.close()
      a.ctx.xvfb = nil
    removeDir(a.ctx.workDir)
