"""Proof-only LLDB observer; never imported by the product. Numeric metadata only."""
import os
import time

import lldb


editor = 0
hits = {"mouse": 0, "responder": 0}
returns = {}
log = None
failed = False


def emit(label, value):
    print(f"{label}={value}", file=log, flush=True)


def number(frame, expression, timeout=1000000):
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetTimeoutInMicroSeconds(timeout)
    options.SetIgnoreBreakpoints(True)
    value = frame.EvaluateExpression(expression, options)
    if value.GetError().Fail():
        emit("expression.error-code", value.GetError().GetError())
        emit("expression.error-type", value.GetError().GetType())
        raise RuntimeError("expression")  # Never publish raw expression/error output.
    return value


def snapshot(frame, phase):
    view = f"((NSTextView *){editor})"
    for label, expression in {
        "window-key": f"(BOOL)[[{view} window] isKeyWindow]",
        "first-responder": f"(BOOL)([[{view} window] firstResponder] == {view})",
        "frame-width": f"(double)[{view} frame].size.width",
        "frame-height": f"(double)[{view} frame].size.height",
        "bounds-height": f"(double)[{view} bounds].size.height",
        "visible-height": f"(double)[{view} visibleRect].size.height",
        "clip-height": f"(double)[[{view} enclosingScrollView] contentView].bounds.size.height",
    }.items():
        value = number(frame, expression)
        emit(phase + "." + label, float(value.GetValue()) if "height" in label or "width" in label
             else value.GetValueAsUnsigned())


def entry(frame, breakpoint_id):
    global failed
    if frame.FindRegister("x0").GetValueAsUnsigned() != editor:
        return False
    try:
        name = "mouse" if breakpoint_id == mouse_id else "responder"
        hits[name] += 1
        emit(name + ".entry", hits[name])
        snapshot(frame, name)
        if name == "mouse":
            event = frame.FindRegister("x2").GetValueAsUnsigned()
            emit("mouse.inside-visible", number(frame,
                f"(BOOL)NSPointInRect([(NSView *){editor} convertPoint:[(NSEvent *){event} locationInWindow] "
                f"fromView:nil], [(NSView *){editor} visibleRect])").GetValueAsUnsigned())
        else:
            address = frame.FindRegister("lr").GetValueAsUnsigned()
            if not address:
                raise RuntimeError("return-address")
            bp = frame.GetThread().GetProcess().GetTarget().BreakpointCreateByAddress(address)
            bp.SetThreadID(frame.GetThread().GetThreadID())
            bp.SetOneShot(True)
            returns[bp.GetID()] = True
    except Exception:
        failed = True
        emit("UNPROVEN.callback", 1)
    return False  # Observe only: no stepping, setters or alternate input.


def returned(frame, breakpoint_id):
    global failed
    try:
        returns.pop(breakpoint_id)
        emit("responder.return", frame.FindRegister("x0").GetValueAsUnsigned() & 0xff)
        snapshot(frame, "responder-return")
    except Exception:
        failed = True
        emit("UNPROVEN.return", 1)
    return False


def observe(debugger):
    global editor, log, mouse_id
    process = None
    directory = os.environ["HAGIG_DIAGNOSTIC_DIRECTORY"]
    with open(os.path.join(directory, "responder.log"), "x") as stream:
        log = stream
        stage = "attach"
        emit("phase.observer-enter", 1)
        try:
            pid = int(os.environ["HAGIG_DIAGNOSTIC_PID"])
            executable = os.environ["HAGIG_DIAGNOSTIC_EXECUTABLE"]
            emit("phase.async-start", 1)
            debugger.SetAsync(True)
            emit("phase.settings-start", 1)
            debugger.HandleCommand("settings set target.skip-prologue false")
            emit("phase.target-start", 1)
            target = debugger.CreateTarget(executable)
            emit("phase.target-created", int(target.IsValid()))
            error = lldb.SBError()
            emit("phase.attach-start", 1)
            process = target.AttachToProcessWithID(debugger.GetListener(), pid, error)
            emit("phase.attach-returned", 1)
            emit("attach.error-code", error.GetError())
            emit("attach.error-type", error.GetType())
            if error.Fail() or process.GetProcessID() != pid:
                raise RuntimeError("attach")
            emit("phase.identity-start", 1)
            if os.path.realpath(process.GetProcessInfo().GetExecutableFile().fullpath) != executable:
                raise RuntimeError("identity")
            if not target.GetTriple().startswith("arm64"):
                raise RuntimeError("architecture")
            stage = "constant"
            emit("phase.constant-start", 1)
            frame = process.GetThreadAtIndex(0).GetFrameAtIndex(0)
            emit("constant.value", number(frame, "1").GetValueAsUnsigned())
            stage = "import"
            emit("phase.import-start", 1)
            number(frame, "@import AppKit; 1", timeout=5000000)
            stage = "editor"
            emit("phase.editor-start", 1)
            # Bounded read-only traversal, no text, selection or object descriptions.
            editor = number(frame, '''(unsigned long long)({
                NSView *queue[1500]; unsigned count = 0; NSView *found = nil;
                for (NSWindow *window in [NSApp windows]) {
                    if (count < 1500 && [window contentView]) queue[count++] = [window contentView];
                }
                unsigned visited = 0;
                while (count && visited++ < 1500) {
                    NSView *view = queue[--count];
                    if ([view isKindOfClass:NSClassFromString(@"HagigPresentation.ReviewTextView")]) {
                        found = view; break;
                    }
                    for (NSView *child in [view subviews]) if (count < 1500) queue[count++] = child;
                }
                found;
            })''').GetValueAsUnsigned()
            emit("editor-found", int(editor != 0))
            if not editor:
                raise RuntimeError("editor")
            snapshot(frame, "before")
            stage = "breakpoints"
            emit("phase.breakpoints-start", 1)
            entries = set()
            for name in ["mouseDown:", "becomeFirstResponder"]:
                bp = target.BreakpointCreateByName(
                    name, lldb.eFunctionNameTypeSelector,
                    lldb.SBFileSpecList(), lldb.SBFileSpecList())
                if bp.GetNumLocations() == 0:
                    raise RuntimeError("symbols")
                entries.add(bp.GetID())
                if name == "mouseDown:":
                    mouse_id = bp.GetID()
                emit("breakpoint.locations." + name.rstrip(":"), bp.GetNumLocations())
            if process.Continue().Fail():
                raise RuntimeError("continue")
            emit("phase.ready", 1)
            with open(os.path.join(directory, "responder.ready"), "x"):
                pass
            stage = "observe"
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline and not os.path.exists(os.path.join(directory, "responder.stop")):
                state = process.GetState()
                if state in [lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached]:
                    raise RuntimeError("process")
                if state == lldb.eStateStopped:
                    observed = False
                    for thread in process:
                        if thread.GetStopReason() != lldb.eStopReasonBreakpoint:
                            continue
                        breakpoint_id = thread.GetStopReasonDataAtIndex(0)
                        if breakpoint_id in entries:
                            entry(thread.GetFrameAtIndex(0), breakpoint_id)
                        elif breakpoint_id in returns:
                            returned(thread.GetFrameAtIndex(0), breakpoint_id)
                        else:
                            raise RuntimeError("unexpected-breakpoint")
                        observed = True
                    if not observed or failed or process.Continue().Fail():
                        raise RuntimeError("observation")
                time.sleep(0.02)
            else:
                if not os.path.exists(os.path.join(directory, "responder.stop")):
                    raise RuntimeError("deadline")
            stage = "after"
            if process.GetState() != lldb.eStateStopped and process.Stop().Fail():
                raise RuntimeError("stop")
            snapshot(process.GetThreadAtIndex(0).GetFrameAtIndex(0), "after")
            emit("mouse.total", hits["mouse"])
            emit("responder.total", hits["responder"])
            if failed or returns:
                raise RuntimeError("callback")
            emit("observation-complete-not-acceptance", 1)
        except Exception:
            emit("UNPROVEN." + stage, 1)
        finally:
            emit("phase.detach-start", 1)
            detached = process is not None and process.IsValid() and process.Detach().Success()
            emit("detached", int(detached))
