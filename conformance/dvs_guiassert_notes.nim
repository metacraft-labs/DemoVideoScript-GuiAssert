## The `dvs` command line with the GuiAssert backend and the conformance
## application's vision binding linked in process:
##
##   --backend guiassert                   the adapter
##   --backend guiassert-<defect>          with a planted defect (stale-read,
##                                         off-by-one, early-sync, read-side-effect)
##
## `--serve` instead serves the same backend over JSON lines on stdio
## (`--serve --defect=<defect>` for a planted one), which is how
## out-of-process consumers reach the in-process adapter.

import std/[os, strutils, tables]
import demo_video_script/[backend, cli, jsonlines]
import demo_video_script_guiassert
import ./notes_vision

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--serve":
    var defect = gdNone
    for a in args[1 .. ^1]:
      if a.startsWith("--defect="): defect = parseEnum[GuiDefect](a[9 .. ^1])
    serveJsonLines(newGuiAssertBackend(notesBinding(), defect, serving = true))
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["guiassert"] = proc (): Backend = newGuiAssertBackend(notesBinding())
  for d in [gdStaleRead, gdOffByOne, gdEarlySync, gdReadSideEffect]:
    let defect = d
    builtins["guiassert-" & $d] = proc (): Backend = newGuiAssertBackend(notesBinding(), defect)
  dvsMain(builtins)
