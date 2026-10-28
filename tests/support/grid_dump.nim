## Drives the conformance application's window through the adapter and lets
## the binding print every frame it reads (DVS_GUIASSERT_DUMP): its text,
## reversed cells and unaccepted words. A diagnostic, not a test.
##
##   grid-dump <fixture> <cols> <rows> [<step-json>…]
##
## A step is an input action whose target is given as a locator:
## {"click": {...}, "locate": {"segments": [...]}}.
import std/[json, os, strutils]
import demo_video_script_guiassert
import ../../conformance/notes_vision

putEnv("DVS_GUIASSERT_DUMP", "1")
let b = newGuiAssertBackend(notesBinding())
b.stage("seed-notes", %*{"fixture": paramStr(1)})
b.stage("launch-app", %*{"width": parseInt(paramStr(2)), "height": parseInt(paramStr(3))})
b.endStage()
for i in 4 .. paramCount():
  var step = parseJson(paramStr(i))
  if step.hasKey("locate"):
    let l = b.locate(step["locate"])
    stderr.writeLine "locate " & $l.outcome & " " & $l.candidates
    step.delete("locate")
    step["targets"] = %*{"target": l.instance}
  b.send(step)
  discard b.await("settled", "", 5000)
  discard b.locate(%*{"segments": [{"role": "window"}]})
b.close()
