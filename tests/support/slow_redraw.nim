## An X11 application that answers each key in three bursts, 200 ms apart: it
## draws one, then two, then three black bars. And its vision binding, which
## counts the bars in the window's pixels. Together they check `settled`
## deterministically: it must not be reported before the last burst, although
## the window is still for longer than several comparison intervals in between.
##
## The same application counts the wheel's notches below the bars, in two
## rows: the ones that arrived with Shift held and the ones without, read from
## the X event's own modifier state — which is how a Shift+wheel step is seen
## to arrive with its modifier.
##
## A real X client on the adapter's real display, read by real captures; not a
## stand-in for anything: it is the smallest application with a multi-burst
## redraw and a modifier-aware wheel.
##
##   slow-redraw --app        the application
##   slow-redraw run …        the `dvs` command line with the binding linked in

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
  XButtonEvent {.importc: "XButtonEvent", header: "<X11/Xlib.h>".} = object
    state: cuint
    button: cuint

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
proc XFlush(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}

const
  BarGapMs = 200
  W = 300
  H = 200
  BarsRow = 60       ## the middle of the bars (y 20..100)
  ShiftedRow = 140   ## the wheel notches that arrived with Shift (y 130..150)
  PlainRow = 180     ## the ones that arrived without it (y 170..190)
  ShiftMask = 1'u32

proc app() =
  let d = XOpenDisplay(nil)
  if d == nil: quit "slow-redraw: cannot open the display", 2
  let scr = XDefaultScreen(d)
  let w = XCreateSimpleWindow(d, XRootWindow(d, scr), 0, 0, W, H, 0, XBlackPixel(d, scr),
                              XWhitePixel(d, scr))
  discard XStoreName(d, w, "Slow")
  discard XSelectInput(d, w, (1 shl 15) or 1 or (1 shl 2))   # Exposure, KeyPress, ButtonPress
  discard XMapWindow(d, w)
  let gc = XCreateGC(d, w, 0, nil)
  var bars, shifted, plain = 0
  proc draw() =
    discard XSetForeground(d, gc, XWhitePixel(d, scr))
    discard XFillRectangle(d, w, gc, 0, 0, W, H)
    discard XSetForeground(d, gc, XBlackPixel(d, scr))
    for i in 0 ..< bars:
      discard XFillRectangle(d, w, gc, cint(20 + i * 90), 20, 60, 80)
    for i in 0 ..< shifted:
      discard XFillRectangle(d, w, gc, cint(20 + i * 30), ShiftedRow - 10, 20, 20)
    for i in 0 ..< plain:
      discard XFillRectangle(d, w, gc, cint(20 + i * 30), PlainRow - 10, 20, 20)
    discard XFlush(d)
  var ev: XEvent
  while true:
    discard XNextEvent(d, addr ev)
    case ev.theType
    of 12: draw()          # Expose
    of 2:                  # KeyPress: three bursts
      for n in 1 .. 3:
        bars = n
        draw()
        if n < 3: sleep(BarGapMs)
    of 4:                  # ButtonPress: wheel notches are buttons 4..7
      let b = cast[ptr XButtonEvent](addr ev)
      if b.button in 4'u32 .. 7'u32:
        if (b.state and ShiftMask) != 0: inc shifted else: inc plain
        draw()
    else: discard

proc countBars(f: Frame; y: int): int =
  ## The black runs along row `y` of the window.
  var dark = false
  for x in 0 ..< f.image.width:
    let d = f.luma(x, y) < 128
    if d and not dark: inc result
    dark = d

proc slowBinding(): GuiBinding =
  GuiBinding(
    name: "slow redraw", roles: newJNull(),
    stage: proc (ctx: GuiContext; use: string; args: JsonNode) =
      if use != "launch-slow": raise newException(ValueError, "no stage '" & use & "'")
      ctx.startApp(@[getAppFilename(), "--app"], "Slow"),
    surface: proc (ctx: GuiContext; f: Frame): Tree =
      result.root = node("screen", 0, 0, float(f.image.width), float(f.image.height),
                         %*{"bars": countBars(f, BarsRow), "shifted": countBars(f, ShiftedRow),
                            "plain": countBars(f, PlainRow)}),
    condition: proc (ctx: GuiContext; f: Frame; name: string): Option[bool] = none(bool),
    resolveChord: proc (ctx: GuiContext; op: string): Option[string] = none(string),
    anchor: nil)

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == "--app":
    app()
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["guiassert"] = proc (): Backend = newGuiAssertBackend(slowBinding())
  dvsMain(builtins)
