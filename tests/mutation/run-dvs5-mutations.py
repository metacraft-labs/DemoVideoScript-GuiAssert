#!/usr/bin/env python3
"""DVS-5 verification gate: the GuiAssert adapter and its conformance binding.

Each arm is a defect in how the adapter delivers input or observes the window,
or in how the binding reads it; the kill command is `just test` (the adapter
suite, then the conformance suite with its planted defects), run against the
real application on a private Xvfb.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
A = "src/demo_video_script_guiassert.nim"
B = "conformance/notes_vision.nim"

ARMS = [
    Arm("G1", A, "  var p = (int(n.x + n.w / 2), int(n.y + n.h / 2))",
        "  var p = (int(n.x + n.w / 2), int(n.y + n.h / 2 + n.h))",
        "a click offset by a pixel band outside the role"),
    Arm("G2", B, "    if cell.ink and cell.shape == '\\0' and cell.confidence < floor:",
        "    if cell.ink and cell.shape == '\\0' and cell.confidence < 0:",
        "an OCR read accepted below its confidence floor"),
    Arm("G3", A, "      if (started - quietSince).inMilliseconds >= QuietSpanMs: return true",
        "      return true",
        "settled declared at the first unchanged capture, before the window stopped changing"),
    Arm("G4", A, "  QuietSpanMs = 300", "  QuietSpanMs = 100",
        "settled after a quiet span shorter than the application's pauses"),
    Arm("G5", A, "      if isPress: a.held.incl m.get else: a.held.excl m.get",
        "      discard m",
        "a held modifier dropped"),
    Arm("G6", A, "  if a.hasFrame and f.image.pixels == a.frame.image.pixels: return",
        "  if a.hasFrame: return",
        "a stale read: the window is not read again after an input"),
    Arm("G7", B, "            ocrImg.pixels[(y0 + yy) * fw + x0 + xx] = char(if rev: 255 - v else: v)",
        "            ocrImg.pixels[(y0 + yy) * fw + x0 + xx] = char(v)",
        "a reversed (selected) row given to OCR without inverting it"),
    Arm("G8", A, "proc requireNothingPending(a: Adapter; what: string) =\n  if a.pending.on:",
        "proc requireNothingPending(a: Adapter; what: string) =\n  if false:",
        "a read answered from the screen before a pending press"),
    Arm("G9", A, '  of "Shift": some(modShift)', '  of "Shift": some(modCtrl)',
        "Shift delivered as Ctrl"),
    Arm("G10", B, "  if colsWith.len == 1 and rowsWith.len >= h div 2 and runs == 1: return '|'",
        "  if false: return '|'",
        "a box's sides not recognised: no menu or dialog is found"),
    Arm("G11", A, "    if a.held == {}:\n      a.deliver(\"scrolling\"", "    if true:\n      a.deliver(\"scrolling\"",
        "a wheel turned without the modifiers held"),
]

if __name__ == "__main__":
    main("dvs5", ROOT, ARMS, ["just", "test"])
