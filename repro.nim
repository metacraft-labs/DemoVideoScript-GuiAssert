## repro.nim — DemoVideoScript-GuiAssert for reprobuild.
##
## The vision backend for DemoVideoScript scenarios (pixels and OCR through
## GuiAssert), consumed as Nim library SOURCE (SC-11): a product's scenario pack
## links its binding against `src/demo_video_script_guiassert.nim`, the runner
## (DemoVideoScript) and GuiAssert. Declaring them here lets a consumer's lock
## pin the set this backend was built against. The repository's own tests run
## through its Justfile.
import repro_project_dsl

package demo_video_script_guiassert:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "DemoVideoScript"
    "GuiAssert"
  library demo_video_script_guiassert
  build:
    # Nothing is built here: the library is consumed as source, and the
    # repository's tests run through its Justfile. A package with no
    # `build:` block is not solved, so the lock would record nothing.
    discard
