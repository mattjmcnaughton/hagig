"""Proof-only LLDB observer; never imported by the product. Numeric metadata only."""
import os
import time

import lldb


editor = 0
hits = {"mouse": 0, "responder": 0}
selector_hits = {"mouse": 0, "responder": 0}
returns = {}
log = None
failed = False

# Getter ABI declarations only, for the checked arm64 macOS target. Avoid the
# AppKit module importer that stalls before observation on the hosted image.
getter_declarations = '''
typedef struct { double x, y; } HGPoint;
typedef struct { double width, height; } HGSize;
typedef struct { HGPoint origin; HGSize size; } HGRect;
@class NSString;
extern "C" Class NSClassFromString(NSString *);
@interface HGObserved
- (id)contentView;
- (id)superview;
- (id)hitTest:(HGPoint)point;
- (unsigned long)type;
- (bool)isKindOfClass:(Class)type;
- (bool)acceptsFirstResponder;
- (bool)acceptsFirstMouse:(id)event;
- (bool)canBecomeKeyWindow;
- (id)window;
- (bool)isKeyWindow;
- (id)firstResponder;
- (HGRect)frame;
- (HGRect)bounds;
- (HGRect)visibleRect;
- (id)enclosingScrollView;
- (HGPoint)locationInWindow;
- (HGPoint)convertPoint:(HGPoint)point fromView:(id)view;
@end
'''


def emit(label, value):
    print(f"{label}={value}", file=log, flush=True)


def number(frame, expression, timeout=1000000):
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetPrefix(getter_declarations)
    options.SetTimeoutInMicroSeconds(timeout)
    options.SetIgnoreBreakpoints(True)
    value = frame.EvaluateExpression(expression, options)
    if value.GetError().Fail():
        emit("expression.error-code", value.GetError().GetError())
        emit("expression.error-type", value.GetError().GetType())
        raise RuntimeError("expression")  # Never publish raw expression/error output.
    return value


def snapshot(frame, phase):
    view = f"((HGObserved *){editor})"
    for label, expression in {
        "window-key": f"(bool)[(HGObserved *)[{view} window] isKeyWindow]",
        "first-responder": f"(bool)([(HGObserved *)[{view} window] firstResponder] == {view})",
        "frame-width": f"(double)[{view} frame].size.width",
        "frame-height": f"(double)[{view} frame].size.height",
        "bounds-height": f"(double)[{view} bounds].size.height",
        "visible-height": f"(double)[{view} visibleRect].size.height",
        "clip-height": f"(double)[(HGObserved *)[(HGObserved *)[{view} enclosingScrollView] contentView] bounds].size.height",
    }.items():
        value = number(frame, expression)
        emit(phase + "." + label, float(value.GetValue()) if "height" in label or "width" in label
             else value.GetValueAsUnsigned())


def entry(frame, breakpoint_id):
    global editor, failed
    try:
        name = "mouse" if breakpoint_id == mouse_id else "responder"
        selector_hits[name] += 1
        receiver = frame.FindRegister("x0").GetValueAsUnsigned()
        if editor:
            if receiver != editor:
                return False
        else:
            if not number(frame, f'(bool)[(HGObserved *){receiver} isKindOfClass:NSClassFromString(@"HagigPresentation.ReviewTextView")]').GetValueAsUnsigned():
                return False
            editor = receiver
            emit("editor-observed", 1)
        hits[name] += 1
        emit(name + ".entry", hits[name])
        snapshot(frame, name)
        if name == "mouse":
            event = frame.FindRegister("x2").GetValueAsUnsigned()
            emit("mouse.inside-visible", number(frame, f'''(bool)({{
                HGPoint p = [(HGObserved *){editor} convertPoint:[(HGObserved *){event} locationInWindow] fromView:(id)0];
                HGRect r = [(HGObserved *){editor} visibleRect];
                p.x >= r.origin.x && p.x < r.origin.x + r.size.width &&
                p.y >= r.origin.y && p.y < r.origin.y + r.size.height;
            }})''').GetValueAsUnsigned())
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


def window_event(frame):
    global failed
    try:
        event = frame.FindRegister("x2").GetValueAsUnsigned()
        if number(frame, f"(unsigned long)[(HGObserved *){event} type]").GetValueAsUnsigned() != 1:
            return
        emit("window.left-mouse-down", 1)
        window = frame.FindRegister("x0").GetValueAsUnsigned()
        emit("window.event-key", number(frame, f"(bool)[(HGObserved *){window} isKeyWindow]").GetValueAsUnsigned())
        emit("window.can-become-key", number(frame, f"(bool)[(HGObserved *){window} canBecomeKeyWindow]").GetValueAsUnsigned())
        flags = number(frame, f'''(unsigned long)({{
            HGObserved *content = [(HGObserved *){window} contentView];
            HGObserved *parent = [content superview];
            HGPoint p = [parent convertPoint:[(HGObserved *){event} locationInWindow] fromView:(id)0];
            HGObserved *hit = parent ? [content hitTest:p] : (id)0;
            unsigned long result = parent ? 1 : 0;
            if ([hit isKindOfClass:NSClassFromString(@"HagigPresentation.ReviewTextView")]) {{
                result |= 2;
                if ([hit acceptsFirstResponder]) result |= 4;
                if ([hit acceptsFirstMouse:(id){event}]) result |= 8;
            }}
            result;
        }})''').GetValueAsUnsigned()
        emit("window.content-parent", int(bool(flags & 1)))
        emit("window.hit-editor", int(bool(flags & 2)))
        if flags & 2:
            emit("editor.accepts-first-responder", int(bool(flags & 4)))
            emit("editor.accepts-first-mouse", int(bool(flags & 8)))
    except Exception:
        failed = True
        emit("UNPROVEN.window-event", 1)


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
            window_bp = target.BreakpointCreateByName("-[NSWindow sendEvent:]")
            emit("breakpoint.locations.window-send-event", window_bp.GetNumLocations())
            if window_bp.GetNumLocations() == 0:
                raise RuntimeError("window-symbols")
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
                        elif breakpoint_id == window_bp.GetID():
                            window_event(thread.GetFrameAtIndex(0))
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
            emit("editor-observed-at-end", int(editor != 0))
            if editor:
                snapshot(process.GetThreadAtIndex(0).GetFrameAtIndex(0), "after")
            emit("selector.mouse.total", selector_hits["mouse"])
            emit("selector.responder.total", selector_hits["responder"])
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
