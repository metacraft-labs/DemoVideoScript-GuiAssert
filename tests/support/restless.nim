## Two X11 applications whose windows defeat "the window stopped changing",
## and the vision bindings that read them:
##
## - `animate` redraws without ever stopping, as a game does: a bar moves
##   across the window every `FrameMs`, and below it one square per key the
##   application has taken. It takes a key into the frame it draws next, so an
##   input has landed once two more frames were presented after it.
## - `flash` is still, except that a key makes it flash: `FlashDelayMs` after
##   the key it draws one dark frame, shown for `FlashMs`, and then the light
##   one again. Read before the key and after it the window looks the same; only
##   the frames between the two reads show the flash.
##
## The bindings, one per way of reading them:
##
##   still     `animate` with the default `settled` (the window stopped changing)
##   game      `animate` with `settled` as `framesPresented(2)`
##   sampled   `flash` with a sampler: `flashed` is read from the frames since the
##             last input (`framesSince`) as well as the current one
##   own       `flash` reading only the frames its own reads grab (the control)
##
## Real X clients on the adapter's real display, read by real captures; not a
## stand-in for anything: each is the smallest application with the behaviour
## the binding has to cope with.
##
##   restless --app animate|flash   an application
##   restless run …                 the `dvs` command line with the bindings linked in

import std/[json, options, os, tables]
import demo_video_script/[backend, cli]
import demo_video_script_guiassert

{.passl: "-lX11".}

type
  Display {.importc: "Display", header: "<X11/Xlib.h>", incompleteStruct.} = object
  XWindow = culong
  GC = pointer
  XEvent {.importc: "XEvent", header: "<X11/Xlib.h>", union.} = object
    theType {.importc: "type".}: cint
    pad: array[24, clong]

proc XOpenDisplay(name: cstring): ptr Display {.importc, header: "<X11/Xlib.h>".}
proc XDefaultScreen(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}
proc XRootWindow(d: ptr Display; s: cint): XWindow {.importc, header: "<X11/Xlib.h>".}
proc XBlackPixel(d: ptr Display; s: cint): culong {.importc, header: "<X11/Xlib.h>".}
proc XWhitePixel(d: ptr Display; s: cint): culong {.importc, header: "<X11/Xlib.h>".}
proc XCreateSimpleWindow(d: ptr Display; parent: XWindow; x, y: cint; w, h, bw: cuint;
                         border, bg: culong): XWindow {.importc, header: "<X11/Xlib.h>".}
proc XStoreName(d: ptr Display; w: XWindow; name: cstring): cint {.importc, header: "<X11/Xlib.h>".}
proc XSelectInput(d: ptr Display; w: XWindow; mask: clong): cint {.importc, header: "<X11/Xlib.h>".}
proc XMapWindow(d: ptr Display; w: XWindow): cint {.importc, header: "<X11/Xlib.h>".}
proc XCreateGC(d: ptr Display; w: XWindow; mask: culong; v: pointer): GC {.importc, header: "<X11/Xlib.h>".}
proc XSetForeground(d: ptr Display; gc: GC; c: culong): cint {.importc, header: "<X11/Xlib.h>".}
proc XFillRectangle(d: ptr Display; w: XWindow; gc: GC; x, y: cint; wd, h: cuint): cint {.importc, header: "<X11/Xlib.h>".}
proc XNextEvent(d: ptr Display; e: ptr XEvent): cint {.importc, header: "<X11/Xlib.h>".}
proc XPending(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}
proc XSync(d: ptr Display; discardEvents: cint): cint {.importc, header: "<X11/Xlib.h>".}

const
  W* = 300
  H* = 200
  FrameMs* = 30        ## `animate`: a frame every 30 ms, forever
  BarRow = 40          ## `animate`: the moving bar (y 20..60)
  KeysRow = 140        ## `animate`: one square per key taken (y 130..150)
  FlashDelayMs* = 40   ## `flash`: from the key to the dark frame
  FlashMs* = 200       ## `flash`: how long the dark frame is shown
  KeyPress = 2
  Expose = 12

type Win = object
  d: ptr Display
  w: XWindow
  gc: GC
  black, white: culong

proc openWindow(title: string): Win =
  result.d = XOpenDisplay(nil)
  if result.d == nil: quit "restless: cannot open the display", 2
  let scr = XDefaultScreen(result.d)
  result.black = XBlackPixel(result.d, scr)
  result.white = XWhitePixel(result.d, scr)
  result.w = XCreateSimpleWindow(result.d, XRootWindow(result.d, scr), 0, 0, W, H, 0,
                                 result.black, result.white)
  discard XStoreName(result.d, result.w, title.cstring)
  discard XSelectInput(result.d, result.w, (1 shl 15) or 1)   # Exposure, KeyPress
  discard XMapWindow(result.d, result.w)
  result.gc = XCreateGC(result.d, result.w, 0, nil)

proc fill(win: Win; color: culong; x, y, w, h: int) =
  discard XSetForeground(win.d, win.gc, color)
  discard XFillRectangle(win.d, win.w, win.gc, cint(x), cint(y), cuint(w), cuint(h))

proc animate() =
  let win = openWindow("Restless")
  var frame, keys = 0
  var ev: XEvent
  while true:
    # the events that arrived since the last frame, taken into this one
    while XPending(win.d) > 0:
      discard XNextEvent(win.d, addr ev)
      if ev.theType == KeyPress: inc keys
    inc frame
    win.fill(win.white, 0, 0, W, H)
    win.fill(win.black, 10 + (frame * 7) mod (W - 40), BarRow - 20, 20, 40)
    for i in 0 ..< keys: win.fill(win.black, 20 + i * 30, KeysRow - 10, 20, 20)
    discard XSync(win.d, 0)
    sleep(FrameMs)

proc flash() =
  let win = openWindow("Flash")
  var ev: XEvent
  while true:
    discard XNextEvent(win.d, addr ev)
    case ev.theType
    of Expose:
      win.fill(win.white, 0, 0, W, H)
      discard XSync(win.d, 0)
    of KeyPress:
      sleep(FlashDelayMs)
      win.fill(win.black, 50, 50, W - 100, H - 100)
      discard XSync(win.d, 0)
      sleep(FlashMs)
      win.fill(win.white, 0, 0, W, H)
      discard XSync(win.d, 0)
    else: discard

proc countRuns(f: Frame; y: int): int =
  ## The dark runs along row `y` of the window.
  var dark = false
  for x in 0 ..< f.image.width:
    let d = f.luma(x, y) < 128
    if d and not dark: inc result
    dark = d

proc dark*(f: Frame): bool =
  ## Whether `f` is the flash's dark frame (its middle is dark).
  f.image.width > 0 and f.luma(f.image.width div 2, f.image.height div 2) < 128

proc restlessBinding*(name: string; settled: SettledRule = nil; sampler = false;
                      app = getAppFilename()): GuiBinding =
  ## A binding for the restless applications (`app`, this program). `settled`
  ## is its rule (nil, the default); with `sampler` its stage starts a sampler
  ## and `flashed` is read from the frames since the last input as well.
  let withSampler = sampler
  GuiBinding(
    name: name, roles: newJNull(), settled: settled,
    stage: proc (ctx: GuiContext; use: string; args: JsonNode) =
      case use
      of "launch-animate": ctx.startApp(@[app, "--app", "animate"], "Restless")
      of "launch-flash": ctx.startApp(@[app, "--app", "flash"], "Flash")
      else: raise newException(ValueError, "no stage '" & use & "'")
      if withSampler: ctx.startSampler(rateHz = 50, maxFrames = 64, maxAgeMs = 4000),
    surface: proc (ctx: GuiContext; f: Frame): Tree =
      var flashed = f.dark
      if withSampler:
        for g in ctx.framesSince(ctx.lastInputAt):
          if g.dark: flashed = true
      result.root = node("screen", 0, 0, float(f.image.width), float(f.image.height),
                         %*{"keys": countRuns(f, KeysRow), "flashed": flashed}),
    condition: proc (ctx: GuiContext; f: Frame; name: string): Option[bool] = none(bool),
    resolveChord: proc (ctx: GuiContext; op: string): Option[string] = none(string),
    anchor: nil)

when isMainModule:
  if paramCount() >= 2 and paramStr(1) == "--app":
    case paramStr(2)
    of "animate": animate()
    of "flash": flash()
    else: quit "restless: no application '" & paramStr(2) & "'", 2
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["still"] = proc (): Backend = newGuiAssertBackend(restlessBinding("still"))
  builtins["game"] = proc (): Backend =
    newGuiAssertBackend(restlessBinding("game", settled = framesPresented(2)))
  builtins["sampled"] = proc (): Backend =
    newGuiAssertBackend(restlessBinding("sampled", sampler = true))
  builtins["own"] = proc (): Backend = newGuiAssertBackend(restlessBinding("own"))
  dvsMain(builtins)
