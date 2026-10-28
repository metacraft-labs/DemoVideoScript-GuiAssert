# DemoVideoScript-GuiAssert

The [DemoVideoScript](https://github.com/metacraft-labs/DemoVideoScript) scenario backend
for desktop applications, by vision, over [GuiAssert](https://github.com/metacraft-labs/GuiAssert):
a scenario runs against the real application in a real window, read as pixels and
driven by the operating system's synthetic input. The application cooperates in nothing.

A project supplies a **binding** (`GuiBinding`): its stage procedures (which start the
application), how its page objects are read from a frame of its window, the conditions it
can detect, and its binding resolver. The adapter answers the backend protocol with it —
`locate`, `read`, `send`, `await`, `record`, `hit` — in process, and over JSON lines for
out-of-process consumers. Geometry is in window pixels.

What it does:

- **The display is private.** Each run starts its own Xvfb on a free display number
  (unless `DVS_GUIASSERT_DISPLAY` names one), so a run never sends input to the desktop of
  whoever started it.
- **Observing**: GuiAssert's `linux-x11` capture of the window, and GuiAssert's OCR engine
  (Tesseract). The adapter gives a binding the frame, a cached OCR call and a smoothing
  filter; what a frame means is the binding's. A word read below the confidence floor is
  not accepted: a property that needs it is refused, never guessed.
- **Input**: GuiAssert's `linux-xtest` — keys, chords and typing with GuiAssert's key
  names, clicks with modifiers, the wheel, moves, hovers and drags, a realistic pointer
  path as one gesture. GuiAssert releases whatever a request leaves held, so the adapter
  holds modifier keys itself and delivers a pointer press and its release together, as
  one gesture, when the release comes; a read between the two is refused.
- **Settled** is a window that stopped changing: captures 60 ms apart, all equal over at
  least 300 ms of the clock.
- **Recordings**: a video of the window (GuiAssert's recorder and `ffmpeg`) and a PNG
  still per step.
- **Capabilities** are honest about vision: no `observe.style`, no `observe.image`.

The conformance application's binding (`conformance/notes_vision.nim`) is the worked
example — it reads a fixed-pitch character grid from the window's pixels, tells reversed
cells and box lines by their pixels, and puts each OCR'd word back on the cells under it —
and `dvs-guiassert-notes` is the `dvs` command line with it linked in:

```sh
dvs-guiassert-notes run scenario.yaml --pack notes-app.pack.yaml --backend guiassert
dvs-guiassert-notes --serve        # the same backend over JSON lines on stdio
```

## Developing

The siblings named in `.github/sibling-repos` are expected next to this checkout
(`../DemoVideoScript`, `../GuiAssert`), or at the paths in `DVS_SRC` and
`GUI_ASSERT_SRC`. Linux only. In the dev shell:

| Recipe                                         | Does                                                                                                 |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `just build`                                   | the adapter's command line, the conformance application's native-window build, the slow-redraw check |
| `just test`                                    | the adapter suite, the protocol check, then the conformance suite (fast, realistic, planted defects) |
| `just lint`                                    | `nim check`, the neutrality scan, `nixfmt`                                                           |
| `just grid-dump <fixture>`                     | prints what the conformance binding reads, frame by frame                                            |
| `python3 tests/mutation/run-dvs5-mutations.py` | every planted defect in the adapter and its binding must turn `just test` red                        |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
