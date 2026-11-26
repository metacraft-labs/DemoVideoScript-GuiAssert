#!/usr/bin/env python3
"""DVS-15 verification gate: windows that never stop changing.

Each arm is a defect in the adapter's two answers to such a window: a
binding's own `settled` rule, and the sampler that keeps the frames between
two reads. The kill command builds the tools and runs the restless suite
(`tests/test_restless.nim`) against the real applications on a private Xvfb.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
A = "src/demo_video_script_guiassert.nim"

ARMS = [
    Arm("S1", A, "  if a.b.settled != nil:", "  if false:",
        "the binding's settled ignored: every window must stop changing to settle"),
    Arm("S2", A, "  while s.frames.len > s.maxFrames: s.frames.delete(0)",
        "  while s.frames.len > 1: s.frames.delete(0)",
        "the sampler drops the frame between two reads (its ring keeps only the newest)"),
    Arm("S3", A, "    a.ctx.stopSampler()\n", "    discard\n",
        "the sampler outlives its stage: close leaves it grabbing"),
]

if __name__ == "__main__":
    main("dvs15", ROOT, ARMS, ["just", "build", "test-restless"])
