## The conformance application's vision binding: its role instances read from
## the pixels of its native-window build (`notes-x11`, built from
## DemoVideoScript's conformance/app), as a person looking at the window
## would, through GuiAssert's capture and OCR.
##
## The window draws a grid of fixed-pitch character cells, scaled 3x. The
## binding finds the grid (its padding and pitch follow from the window's size
## and the columns and rows the stage asked for), and for every cell what a
## glance at its pixels tells: whether it is drawn reversed (light on dark:
## selection, hover and the text cursor), whether it holds ink, and whether it
## is a line of a box (a menu's or a dialog's frame) or a list row's handle
## (two dots). The text is the OCR
## engine's: cells holding text are copied, dark on light, into one image for
## the engine, smoothed, and each word it reads is put back on the cells under
## it. A word read below the confidence floor is not accepted: what it covers
## cannot be read, and a property that needs it is refused rather than
## guessed.
##
## OCR slips on single letters (`Mew` for `New`). A word within one edit of
## exactly one word of the binding's vocabulary is read as that word: the
## application's own labels and messages, the titles the stage seeded, and the
## text the scenario typed — what a person who knows the application expects
## to see.
##
## What is not drawn is not read: a note's body, tags and state are never on
## screen, nor the full order of a scrolled list; they are declared
## unreadable, as on the terminal.

import std/[json, os, strutils, options, tables, editdistance, math]
from std/unicode import Rune, runes, toRunes, size, `$`
import demo_video_script_guiassert

const
  Scale = 3        ## the window draws each pixel of its frame 3x3
  Pad = 3 * Scale  ## the frame's margin around the cells

type
  Cell* = object
    text*: string     ## the character read, " " when the cell is blank
    reversed*: bool
    ink*: bool
    shape*: char      ## '|', '-' or '+' for a line of a box, ':' for a handle; '\0' otherwise
    confidence*: float

  Grid* = object
    cols*, rows*: int
    cw*, ch*: int     ## a cell's size in window pixels
    cells*: seq[seq[Cell]]

proc notesX11Path(): string =
  result = getEnv("DVS_NOTES_X11")
  if result.len == 0: result = findExe("notes-x11")
  if result.len == 0:
    raise newException(IOError, "set DVS_NOTES_X11 to the notes-x11 binary")

const keymap = {"notes.archive-selected": "Ctrl+d", "notes.rename": "F2", "notes.sort": "Ctrl+s",
                "notes.focus-search": "Ctrl+f", "notes.pin": "Ctrl+p"}.toTable

const vocabulary = ["Notes", "notes", "Sort", "Filter", "New", "Search", "Pin", "Unpin", "Rename",
                    "Archive", "Name", "OK", "Cancel", "Ready", "Loading", "Sorted", "by", "title",
                    "Filtered", "Archived", "Renamed", "Pinned", "Unpinned", "Moved", "Show",
                    "pinned", "only", "Create", "a", "note", "no"]

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["title"], "affordances": []},
    "toolbar": {"properties": [], "affordances": []},
    "toolbar-button": {"properties": ["label", "enabled"], "affordances": ["click"]},
    "search-field": {"properties": ["value", "focused"],
                     "affordances": ["click", "text-entry", "focusable"]},
    "note-list": {"properties": ["count", "order", "first-visible"],
                  "affordances": ["drop-target", "wheel", "focusable"]},
    "note": {"properties": ["title", "selected", "pinned", "position"],
             "affordances": ["click", "double-click", "context-click", "drag-source", "drop-target"]},
    "dialog": {"properties": ["title"], "affordances": []},
    "text-field": {"properties": ["label", "value", "focused"],
                   "affordances": ["click", "text-entry", "focusable"]},
    "dialog-button": {"properties": ["label"], "affordances": ["click"]},
    "context-menu": {"properties": [], "affordances": []},
    "menu-item": {"properties": ["label", "enabled"], "affordances": ["click"]},
    "status-bar": {"properties": ["message"], "affordances": []}}

# --- reading the grid ---------------------------------------------------------------------

proc lexicon(ctx: GuiContext): seq[string] =
  result = @vocabulary
  for t in ctx.state{"titles"}.getElems:
    for w in t.getStr.splitWhitespace: result.add w
  for t in ctx.typed:
    for w in t.splitWhitespace: result.add w

proc snap*(word: string; lex: openArray[string]): string =
  ## `word`, or the one vocabulary word it is one edit away from. Leading and
  ## trailing punctuation is kept as read; words with digits are never
  ## changed (a digit misread is not a near miss of a word).
  var a = 0
  var b = word.len
  while a < b and word[a] notin {'A'..'Z', 'a'..'z', '0'..'9'}: inc a
  while b > a and word[b - 1] notin {'A'..'Z', 'a'..'z', '0'..'9'}: dec b
  let core = word[a ..< b]
  if core.len < 3 or core in lex: return word
  for c in core:
    if c in {'0'..'9'}: return word
  var best = ""
  var count = 0
  for w in lex:
    if w != best and editDistance(core, w) == 1:
      if best.len == 0 or w != best: inc count
      best = w
  if count == 1: word[0 ..< a] & best & word[b .. ^1] else: word

proc shapeOf(mask: seq[seq[bool]]): char =
  ## A box line, by where the cell's ink is: one full row ('-'), one full
  ## column ('|'), or exactly one of each crossing ('+').
  let h = mask.len
  let w = mask[0].len
  var rowsWith, colsWith: seq[int]
  var count = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      if mask[y][x]:
        inc count
        if y notin rowsWith: rowsWith.add y
        if x notin colsWith: colsWith.add x
  if count == 0: return '\0'
  if rowsWith.len == 1 and colsWith.len >= w - 1: return '-'
  var runs = 0
  for y in 0 ..< h:
    if y in rowsWith and (y == 0 or (y - 1) notin rowsWith): inc runs
  if colsWith.len == 1 and rowsWith.len >= h div 2 and runs == 1: return '|'
  # a list row's handle: two dots, one above the other
  if colsWith.len <= 3 and rowsWith.len <= 6 and runs == 2: return ':'
  # a cross: some row and some column carry all the ink
  for y in rowsWith:
    for x in colsWith:
      var all = true
      var rowN, colN = 0
      for yy in 0 ..< h:
        for xx in 0 ..< w:
          if mask[yy][xx] and yy != y and xx != x: all = false
      for xx in 0 ..< w:
        if mask[y][xx]: inc rowN
      for yy in 0 ..< h:
        if mask[yy][x]: inc colN
      # the arms reach out on all four sides ('T', 'L' and '+' differ here)
      let left = x > 0 and mask[y][x - 1]
      let right = x < w - 1 and mask[y][x + 1]
      let up = y > 0 and mask[y - 1][x]
      let down = y < h - 1 and mask[y + 1][x]
      if all and rowN >= 3 and colN >= 3 and left and right and up and down: return '+'
  '\0'

proc readGrid*(ctx: GuiContext; f: Frame): Grid =
  let cols = ctx.state{"cols"}.getInt(60)
  let rows = ctx.state{"rows"}.getInt(16)
  let fw = f.image.width
  let fh = f.image.height
  result = Grid(cols: cols, rows: rows, cw: (fw - 2 * Pad) div cols,
                ch: (fh - 2 * Pad) div rows)
  ctx.state["cw"] = %result.cw
  ctx.state["ch"] = %result.ch
  let cw1 = result.cw div Scale
  let ch1 = result.ch div Scale
  result.cells = newSeq[seq[Cell]](rows)
  var ocrImg = newImage(GrayImage, fw, fh, 255)
  var anyText = false
  for r in 0 ..< rows:
    result.cells[r] = newSeq[Cell](cols)
    for c in 0 ..< cols:
      let x0 = Pad + c * result.cw
      let y0 = Pad + r * result.ch
      let rev = f.luma(x0 + 1, y0 + 1) < 128
      var mask = newSeq[seq[bool]](ch1)
      var ink = false
      for yy in 0 ..< ch1:
        mask[yy] = newSeq[bool](cw1)
        for xx in 0 ..< cw1:
          let dark = f.luma(x0 + xx * Scale + 1, y0 + yy * Scale + 1) < 128
          mask[yy][xx] = dark != rev
          if mask[yy][xx]: ink = true
      let shape = (if ink: shapeOf(mask) else: '\0')
      result.cells[r][c] = Cell(text: (if shape != '\0': $shape else: " "), reversed: rev,
                                ink: ink, shape: shape,
                                confidence: (if ink and shape == '\0': 0.0 else: 100.0))
      if ink and shape == '\0':
        anyText = true
        for yy in 0 ..< result.ch:
          for xx in 0 ..< result.cw:
            let v = f.luma(x0 + xx, y0 + yy)
            ocrImg.pixels[(y0 + yy) * fw + x0 + xx] = char(if rev: 255 - v else: v)
  if not anyText: return
  let lex = ctx.lexicon
  let smoothed = smooth(ocrImg, 2)
  for w0 in ctx.recognize(smoothed):
    var w = w0
    if w.text.strip.len == 0: continue
    if w.confidence < ctx.confidenceFloor:
      # a doubtful word is read again on its own, as a single line
      let m = 12
      var crop = newImage(GrayImage, w.w + 2 * m, w.h + 2 * m, 255)
      for yy in 0 ..< w.h:
        for xx in 0 ..< w.w:
          let sx = w.x + xx
          let sy = w.y + yy
          if sx >= 0 and sx < fw and sy >= 0 and sy < fh:
            crop.pixels[(yy + m) * crop.width + xx + m] = smoothed.pixels[sy * fw + sx]
      let again = ctx.recognize(crop, psm = 7)
      if existsEnv("DVS_GUIASSERT_DUMP"):
        for a in again: stderr.writeLine "   again ", a.text, " ", int(a.confidence)
      if again.len == 1 and again[0].confidence > w.confidence:
        w.text = again[0].text
        w.confidence = again[0].confidence
    let row = (w.y + w.h div 2 - Pad) div result.ch
    if existsEnv("DVS_GUIASSERT_DUMP"):
      stderr.writeLine "   word ", w.text, " ", int(w.confidence), " row ", row, " x ", w.x, "+", w.w
    if row < 0 or row >= rows: continue
    # the cells under the word that hold text: the pixels say how many glyphs
    # the word has, so a character the engine adds at an edge (a smoothed
    # edge read as punctuation) is dropped
    let third = result.cw div 3
    let c0 = max(0, (w.x - Pad + third) div result.cw)
    let c1 = min(cols - 1, (w.x + w.w - Pad - third) div result.cw)
    var targets: seq[int]
    for c in c0 .. c1:
      if result.cells[row][c].ink and result.cells[row][c].shape == '\0': targets.add c
    var text = (if w.confidence >= ctx.confidenceFloor: snap(w.text, lex) else: w.text).toRunes
    proc punct(r: Rune): bool = r.size == 1 and ($r)[0] notin {'A'..'Z', 'a'..'z', '0'..'9'}
    while text.len > targets.len and text.len > 0 and punct(text[0]): text = text[1 .. ^1]
    while text.len > targets.len and text.len > 0 and punct(text[^1]): text.setLen(text.len - 1)
    for k, c in targets:
      if k >= text.len: break
      result.cells[row][c].text = $text[k]
      result.cells[row][c].confidence = w.confidence

proc text*(g: Grid; r: int; c0 = 0; c1 = -1): string =
  let e = (if c1 < 0: g.cols else: min(c1, g.cols))
  for c in max(0, c0) ..< e: result.add g.cells[r][c].text

proc unread(g: Grid; floor: float; r, c0, c1: int): string =
  ## Why the text of row `r`, columns [c0, c1), cannot be read; "" when it can.
  for c in max(0, c0) ..< min(c1, g.cols):
    let cell = g.cells[r][c]
    if cell.ink and cell.shape == '\0' and cell.confidence < floor:
      return "OCR read '" & cell.text & "' at column " & $c & " with confidence " &
        $int(cell.confidence) & ", below the floor " & $int(floor)
  ""

# --- the surface --------------------------------------------------------------------------

type Box = object
  row, col, w, h: int

proc boxes(g: Grid): seq[Box] =
  ## Rectangles drawn with '+', '-' and '|'.
  for r in 0 ..< g.rows:
    var c = 0
    while c < g.cols:
      if g.cells[r][c].shape == '+':
        var e = c + 1
        while e < g.cols and g.cells[r][e].shape == '-': inc e
        if e < g.cols and e > c + 1 and g.cells[r][e].shape == '+':
          var k = r + 1
          while k < g.rows and g.cells[k][c].shape == '|' and g.cells[k][e].shape == '|': inc k
          if k < g.rows and k > r + 1 and g.cells[k][c].shape == '+' and
              g.cells[k][e].shape == '+':
            result.add Box(row: r, col: c, w: e - c + 1, h: k - r + 1)
          c = e
      inc c

proc parseFrame*(ctx: GuiContext; f: Frame): Tree =
  let g = ctx.readGrid(f)
  let floor = ctx.confidenceFloor
  if existsEnv("DVS_GUIASSERT_DUMP"):
    # a diagnostic: each row as read, with its reversed (#) and unaccepted (?) cells
    for r in 0 ..< g.rows:
      var marks = ""
      for c in 0 ..< g.cols:
        let cell = g.cells[r][c]
        marks.add(if cell.ink and cell.shape == '\0' and cell.confidence < floor: '?'
                  elif cell.reversed: '#' else: ' ')
      stderr.writeLine align($r, 2) & " |" & g.text(r) & "|"
      if marks.strip.len > 0: stderr.writeLine "   |" & marks & "|"
  let cw = float(g.cw)
  let ch = float(g.ch)
  proc px(c: int): float = float(Pad) + float(c) * cw
  proc py(r: int): float = float(Pad) + float(r) * ch
  proc rect(n: string; c, r, w, h: int; props: JsonNode = newJObject();
            keys: seq[(string, string)] = @[]): SurfaceNode =
    node(n, px(c), py(r), float(w) * cw, float(h) * ch, props, keys)
  proc band(n: string; r, h: int; props: JsonNode = newJObject();
            keys: seq[(string, string)] = @[]): SurfaceNode =
    ## a part that runs across the whole window: from edge to edge
    node(n, 0, py(r), float(f.image.width), float(h) * ch, props, keys)
  var dlg, menu: Box
  var hasDlg, hasMenu = false
  for b in g.boxes:
    if b.h == 6 and "Name:" in g.text(b.row + 2, b.col, b.col + b.w):
      dlg = b
      hasDlg = true
    elif not hasMenu:
      menu = b
      hasMenu = true
  proc overlayStart(r: int): int =
    result = g.cols
    if hasMenu and r >= menu.row and r < menu.row + menu.h: result = min(result, menu.col)
    if hasDlg and r >= dlg.row and r < dlg.row + dlg.h: result = min(result, dlg.col)
  var t: Tree
  # the window and its fixed parts
  let title = g.text(0).strip.split("  ")[0].strip
  t.root = node("window", 0, 0, float(f.image.width), float(f.image.height), %*{"title": title})
  let titleWhy = g.unread(floor, 0, 0, title.len + 2)
  if titleWhy.len > 0: t.root.unreadable["title"] = titleWhy
  var count = 0
  let right = g.text(0).strip.splitWhitespace
  if right.len >= 2 and right[^1] == "notes":
    try: count = parseInt(right[^2]) except ValueError: discard
  let tb = band("toolbar", 1, 1)
  t.add(t.root, tb)
  var c = 0
  while c < g.cols:
    if g.cells[1][c].text == "[":
      var e = c + 1
      while e < g.cols and g.cells[1][e].text != "]" and g.cells[1][e].ink: inc e
      let label = g.text(1, c + 1, e)
      let n = rect("toolbar-button", c, 1, e - c + 1, 1, %*{"label": label, "enabled": true},
                   @[("label", label)])
      let why = g.unread(floor, 1, c, e + 1)
      if why.len > 0: n.unreadable["label"] = why
      t.add(tb, n)
      c = e
    inc c
  # the text cursor: a reversed cell in a text field
  var curRow, curCol = -1
  for r in (if hasDlg: @[2, dlg.row + 2] else: @[2]):
    for cc in 8 ..< g.cols:
      if g.cells[r][cc].reversed and r != 1:
        curRow = r
        curCol = cc
  let searchFocused = curRow == 2 and not hasDlg
  let sv = g.text(2, 8).strip(leading = false)
  let search = rect("search-field", 8, 2, g.cols - 8, 1, %*{"value": sv, "focused": searchFocused})
  search.focused = searchFocused
  let svWhy = g.unread(floor, 2, 8, g.cols)
  if svWhy.len > 0: search.unreadable["value"] = svWhy
  t.add(t.root, search)
  # the list
  let listTop = 3
  let listRows = g.rows - 4
  var list = band("note-list", listTop, listRows)
  t.add(t.root, list)
  var titles: seq[string]
  var orderWhy = ""
  for k in 0 ..< listRows:
    let r = listTop + k
    let cells = g.cells[r]
    # a note's row: its handle in columns 1-2, a blank, its title from column 4
    if not (cells[1].ink and cells[2].ink and not cells[3].ink and cells[4].ink): continue
    let e = overlayStart(r)
    # the title ends at the last ink before a marker (" *" pinned, " <" drop target)
    var last = e - 1
    while last >= 4 and not cells[last].ink: dec last
    var pinned = false
    var markers = 0
    while last >= 6 and cells[last].ink and not cells[last - 1].ink and markers < 2:
      let m = cells[last].text
      if m == "*": pinned = true
      last -= 2
      inc markers
      while last >= 4 and not cells[last].ink: dec last
    let text = g.text(r, 4, last + 1).strip(leading = false)
    let why = g.unread(floor, r, 4, last + 1)
    titles.add text
    let n = band("note", r, 1,
                 %*{"title": text, "selected": cells[0].reversed, "pinned": pinned,
                    "position": k + 1}, @[("title", text)])
    if why.len > 0:
      n.unreadable["title"] = why
      orderWhy = why
    if markers > 0 and g.unread(floor, r, last + 1, e).len > 0:
      n.unreadable["pinned"] = g.unread(floor, r, last + 1, e)
    t.add(list, n)
  list.props = %*{"count": count, "order": titles,
                  "first-visible": (if titles.len > 0: titles[0] else: "")}
  if count != titles.len:
    list.unreadable["order"] = "only " & $titles.len & " of " & $count & " notes are on screen"
    for n in t.kids(list):
      n.unreadable["position"] = "the list is scrolled, so a row's place in it is not on screen"
  elif orderWhy.len > 0:
    list.unreadable["order"] = orderWhy
  if orderWhy.len > 0: list.unreadable["first-visible"] = orderWhy
  list.focused = not hasDlg and not searchFocused
  let status = band("status-bar", g.rows - 1, 1,
                    %*{"message": g.text(g.rows - 1).strip})
  let stWhy = g.unread(floor, g.rows - 1, 0, g.cols)
  if stWhy.len > 0: status.unreadable["message"] = stWhy
  t.add(t.root, status)
  if hasDlg:
    let d = rect("dialog", dlg.col, dlg.row, dlg.w, dlg.h, %*{"title": "Rename"},
                 @[("title", "Rename")])
    t.add(t.root, d)
    let value = g.text(dlg.row + 2, dlg.col + 8, dlg.col + dlg.w - 1).strip(leading = false)
    let field = rect("text-field", dlg.col + 8, dlg.row + 2, dlg.w - 10, 1,
                     %*{"label": "Name", "value": value, "focused": true}, @[("label", "Name")])
    field.focused = true
    let fWhy = g.unread(floor, dlg.row + 2, dlg.col + 8, dlg.col + dlg.w - 1)
    if fWhy.len > 0: field.unreadable["value"] = fWhy
    t.add(d, field)
    t.add(d, rect("dialog-button", dlg.col + 2, dlg.row + 4, 4, 1, %*{"label": "OK"},
                  @[("label", "OK")]))
    t.add(d, rect("dialog-button", dlg.col + 7, dlg.row + 4, 8, 1, %*{"label": "Cancel"},
                  @[("label", "Cancel")]))
  if hasMenu:
    let m = rect("context-menu", menu.col, menu.row, menu.w, menu.h)
    t.add(t.root, m)
    for r in menu.row + 1 ..< menu.row + menu.h - 1:
      let label = g.text(r, menu.col + 1, menu.col + menu.w - 1).strip
      let n = rect("menu-item", menu.col + 1, r, menu.w - 2, 1,
                   %*{"label": label, "enabled": true}, @[("label", label)])
      let why = g.unread(floor, r, menu.col + 1, menu.col + menu.w - 1)
      if why.len > 0: n.unreadable["label"] = why
      t.add(m, n)
  t

proc notesBinding*(): GuiBinding =
  GuiBinding(
    name: "notes-app vision",
    roles: roles(),
    stage: proc (ctx: GuiContext; use: string; args: JsonNode) =
      case use
      of "seed-notes":
        let f = args{"fixture"}.getStr
        let path = (if f.isAbsolute: f else: ctx.base / f)
        ctx.state["fixture"] = %path
        var titles = newJArray()
        for n in parseFile(path){"notes"}.getElems: titles.add n{"title"}
        ctx.state["titles"] = titles
      of "launch-app":
        var a = @[notesX11Path()]
        if ctx.state.hasKey("fixture"): a.add @["--fixture", ctx.state["fixture"].getStr]
        let w = args{"width"}.getInt(60)
        let h = args{"height"}.getInt(16)
        ctx.state["cols"] = %w
        ctx.state["rows"] = %h
        a.add @["--width", $w, "--height", $h]
        ctx.startApp(a, "Notes")
      of "set-clock": discard
      of "mark-started":
        let p = args{"path"}.getStr
        writeFile((if p.isAbsolute: p else: ctx.base / p), "the stage ran\n")
      else: raise newException(ValueError, "no stage procedure '" & use & "'"),
    surface: parseFrame,
    condition: proc (ctx: GuiContext; f: Frame; name: string): Option[bool] =
      case name
      of "note-list.loaded", "idle":
        let g = ctx.readGrid(f)
        some(not g.text(g.rows - 1).strip.startsWith("Loading"))
      else: none(bool),
    resolveChord: proc (ctx: GuiContext; operation: string): Option[string] =
      if keymap.hasKey(operation): some(keymap[operation]) else: none(string),
    anchor: proc (ctx: GuiContext; n: SurfaceNode; anchor: string): Option[(int, int)] =
      let cw = ctx.state{"cw"}.getFloat(18)
      let midY = int(n.y + n.h / 2)
      let x0 = (if n.role == "note": float(Pad) else: n.x)  # a note runs edge to edge
      proc cellX(col: float): int = int(x0 + (col + 0.5) * cw)
      case anchor.split('(')[0]
      of "handle": some((cellX(1), midY))
      of "title-end": some((cellX(float(4 + n.props{"title"}.getStr.toRunes.len - 1)), midY))
      of "caret-at":
        let col = parseInt(anchor[anchor.find('(') + 1 ..< anchor.find(')')])
        some((cellX(float(col)), midY))
      else: none((int, int)))
