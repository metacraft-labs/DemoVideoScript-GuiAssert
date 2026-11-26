## Running a tool the way the suites do: in a process group of its own, with
## a deadline, its output collected in a file.

import std/[os, osproc, monotimes, times]
from std/posix import kill, SIGKILL, Pid

const RunDeadlineMs = 15 * 60 * 1000
  ## How long one run of a tool may take. A run that outlives it is killed
  ## (its whole process group: the application and the Xvfb it started too)
  ## and fails the test, rather than leaving it waiting forever.

proc runRaw*(exe: string; args: seq[string]; deadlineMs = RunDeadlineMs): (string, int) =
  ## `exe` in a process group of its own, its output in a file — not a pipe,
  ## which a surviving grandchild (the application) would hold open — waited
  ## for until the deadline.
  let outFile = getTempDir() / ("dga-run-" & $getCurrentProcessId() & "-" &
                                $(getMonoTime().ticks mod 1_000_000_000) & ".out")
  var cmd = "exec setsid " & quoteShell(exe)
  for a in args: cmd.add " " & quoteShell(a)
  cmd.add " > " & quoteShell(outFile) & " 2>&1 < /dev/null"
  let p = startProcess("/bin/sh", args = ["-c", cmd], options = {})
  let deadline = getMonoTime() + initDuration(milliseconds = deadlineMs)
  var code = -1
  while true:
    code = p.peekExitCode
    if code != -1: break
    if getMonoTime() > deadline:
      discard kill(-Pid(p.processID), SIGKILL)
      discard p.waitForExit()
      p.close()
      let o = (try: readFile(outFile) except IOError: "")
      removeFile(outFile)
      raise newException(IOError, exe & " did not finish within " & $(deadlineMs div 1000) &
                         " s and was killed with its process group; its output:\n" & o)
    sleep(100)
  # the group's other members (an application the tool left behind) go too
  discard kill(-Pid(p.processID), SIGKILL)
  p.close()
  let o = (try: readFile(outFile) except IOError: "")
  removeFile(outFile)
  (o, code)
