## Justfile - DemoVideoScript-GuiAssert.
##
## Sibling sources come from .github/sibling-repos checkouts next to this one;
## each can be overridden (DVS_SRC, GUI_ASSERT_SRC). Build outputs go under
## BUILD_DIR. The adapter starts its own Xvfb for every run, so nothing here
## needs a display.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

build_dir := env_var_or_default("BUILD_DIR", "build")
bin := build_dir / "bin"
dvs_src := env_var_or_default("DVS_SRC", "../DemoVideoScript/src")
dvs_root := dvs_src / ".."
paths := "--path:src --path:" + dvs_src + " --path:" + env_var_or_default("GUI_ASSERT_SRC", "../GuiAssert/src")
nim_flags := "--hints:off --passC:-w --mm:orc --threads:on"
pack := dvs_root / "conformance/pack/notes-app.pack.yaml"
scenarios := dvs_root / "conformance/scenarios"

# The adapter with the conformance binding (`dvs-guiassert-notes`), the
# conformance application's native-window build (`notes-x11`) from the pinned
# DemoVideoScript, the slow-redraw check and the restless applications. The
# tests never build these.
build:
    @mkdir -p {{bin}}
    nim c {{nim_flags}} -d:release {{paths}} --nimcache:{{build_dir}}/nimcache/dga -o:{{bin}}/dvs-guiassert-notes conformance/dvs_guiassert_notes.nim
    nim c {{nim_flags}} -d:release --nimcache:{{build_dir}}/nimcache/notes-x11 -o:{{bin}}/notes-x11 {{dvs_root}}/conformance/app/notes_x11.nim
    nim c {{nim_flags}} -d:release {{paths}} --nimcache:{{build_dir}}/nimcache/slow-redraw -o:{{bin}}/slow-redraw tests/support/slow_redraw.nim
    nim c {{nim_flags}} -d:release {{paths}} --nimcache:{{build_dir}}/nimcache/restless -o:{{bin}}/restless tests/support/restless.nim

test: build test-adapter test-restless test-protocol test-conformance

# §12: every admitted scenario passes in fast and realistic modes, every
# other is unsupported, and every planted defect turns a scenario red.
test-conformance:
    DVS_NOTES_X11={{bin}}/notes-x11 {{bin}}/dvs-guiassert-notes conformance --pack {{pack}} \
      --backend guiassert \
      --defect stale-read=guiassert-stale-read --defect off-by-one=guiassert-off-by-one \
      --defect early-sync=guiassert-early-sync --defect read-side-effect=guiassert-read-side-effect \
      {{scenarios}}/*.yaml

# Every message over JSON lines, both directions, against the published schema.
test-protocol:
    DVS_NOTES_X11={{bin}}/notes-x11 python3 {{dvs_root}}/tests/protocol_conformance.py {{bin}}/dvs-guiassert-notes {{pack}} "cmd:{{bin}}/dvs-guiassert-notes --serve" {{scenarios}}/archive-from-keyboard.yaml {{scenarios}}/drag-to-reorder.yaml {{scenarios}}/hover-and-modifiers.yaml

test-adapter:
    @mkdir -p {{build_dir}}/test-bin
    DVS_NOTES_X11={{bin}}/notes-x11 DVS_BIN_DIR={{bin}} DVS_ROOT={{dvs_root}} \
      nim c -r {{nim_flags}} {{paths}} --nimcache:{{build_dir}}/nimcache/test_adapter -o:{{build_dir}}/test-bin/test_adapter tests/test_adapter.nim

# Windows that never stop changing: a binding's own `settled`, and the sampler.
test-restless:
    @mkdir -p {{build_dir}}/test-bin
    DVS_BIN_DIR={{bin}} \
      nim c -r {{nim_flags}} {{paths}} --nimcache:{{build_dir}}/nimcache/test_restless -o:{{build_dir}}/test-bin/test_restless tests/test_restless.nim

# Prints what the vision binding reads, frame by frame (a diagnostic).
grid-dump fixture cols="60" rows="16" *steps:
    nim c {{nim_flags}} -d:release {{paths}} --nimcache:{{build_dir}}/nimcache/grid-dump -o:{{bin}}/grid-dump tests/support/grid_dump.nim
    DVS_NOTES_X11={{bin}}/notes-x11 {{bin}}/grid-dump {{fixture}} {{cols}} {{rows}} {{steps}}

lint: lint-nim lint-neutrality lint-nix

lint-nim:
    nim check {{nim_flags}} {{paths}} conformance/dvs_guiassert_notes.nim
    nim check {{nim_flags}} {{paths}} tests/test_adapter.nim
    nim check {{nim_flags}} {{paths}} tests/support/slow_redraw.nim
    nim check {{nim_flags}} {{paths}} tests/test_restless.nim
    nim check {{nim_flags}} {{paths}} tests/support/restless.nim

lint-neutrality:
    bash {{dvs_root}}/tests/neutrality_scan.sh $(git ls-files | grep -vE '^(flake.lock)$' | sed "s|^|$PWD/|")

lint-nix:
    nixfmt --check flake.nix

format:
    nixfmt flake.nix

clean:
    rm -rf {{build_dir}}
