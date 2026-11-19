#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Windows-style layout picker, run in a floating terminal by features/layout.lua.

argv: target block, current layout index (1-based, 0 = none), then one
"name|pane:x0:y0:x1:y1,..." per layout with coordinates in 0..1.

Everything above the shell section is pure: decode turns bytes into events,
update turns (state, event) into (state, effects), render turns state into a
frame. The shell runs the terminal, the event loop and `rex`, and redraws
whenever the state changes.
"""

import asyncio
import contextlib
import os
import re
import signal
import sys
import termios
import tty
from collections.abc import Callable, Generator
from dataclasses import dataclass, replace
from typing import assert_never

# --- Model ---------------------------------------------------------------------


@dataclass(frozen=True, slots=True, kw_only=True)
class Rect:
    pane: str
    x0: float
    y0: float
    x1: float
    y1: float


@dataclass(frozen=True, slots=True, kw_only=True)
class Layout:
    name: str
    rects: tuple[Rect, ...]


@dataclass(frozen=True, slots=True, kw_only=True)
class Props:
    """What the picker was opened with; fixed for its lifetime."""

    layouts: tuple[Layout, ...]
    current: int | None  # index of the layout last applied to the window


@dataclass(frozen=True, slots=True)
class Size:
    cols: int
    rows: int


@dataclass(frozen=True, slots=True)
class Browsing:
    pass


@dataclass(frozen=True, slots=True)
class Applying:
    pass


@dataclass(frozen=True, slots=True, kw_only=True)
class Failed:
    error: str


type Phase = Browsing | Applying | Failed


@dataclass(frozen=True, slots=True, kw_only=True)
class State:
    selected: int
    size: Size
    phase: Phase = Browsing()


def parse_layouts(specs: list[str]) -> tuple[Layout, ...]:
    """Layouts from "name|pane:x0:y0:x1:y1,..." specs (lib/layout_tree.rects)."""
    layouts = []
    for spec in specs:
        name, _, rest = spec.partition("|")
        rects = []
        for r in rest.split(","):
            pane, x0, y0, x1, y1 = r.split(":")
            rects.append(Rect(pane=pane, x0=float(x0), y0=float(y0), x1=float(x1), y1=float(y1)))
        layouts.append(Layout(name=name, rects=tuple(rects)))
    return tuple(layouts)


# --- Events and effects ----------------------------------------------------------


@dataclass(frozen=True, slots=True, kw_only=True)
class Move:
    step: int


@dataclass(frozen=True, slots=True, kw_only=True)
class Choose:
    index: int


@dataclass(frozen=True, slots=True)
class Confirm:
    pass


@dataclass(frozen=True, slots=True)
class Cancel:
    pass


@dataclass(frozen=True, slots=True)
class Click:
    col: int  # 1-based terminal cell
    row: int


@dataclass(frozen=True, slots=True, kw_only=True)
class Resize:
    size: Size


@dataclass(frozen=True, slots=True)
class Applied:
    pass


@dataclass(frozen=True, slots=True, kw_only=True)
class ApplyFailed:
    error: str


type Event = Move | Choose | Confirm | Cancel | Click | Resize | Applied | ApplyFailed


@dataclass(frozen=True, slots=True, kw_only=True)
class Apply:
    name: str


@dataclass(frozen=True, slots=True)
class Exit:
    pass


type Effect = Apply | Exit


# --- Input decoding ----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Idle:
    pass


@dataclass(frozen=True, slots=True, kw_only=True)
class Pending:
    """An escape sequence cut off by a read, or a lone ESC that may start one."""

    tail: bytes


type Decoder = Idle | Pending

ESC = 0x1B
MOUSE = re.compile(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])")  # SGR 1006
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
SS3 = re.compile(rb"\x1bO[@-~]")
INCOMPLETE = re.compile(rb"\x1b(\[[0-?]*[ -/]*|O)?\Z")  # a prefix of CSI/SS3, or a lone ESC
ARROWS: dict[bytes, Event] = {
    b"\x1b[C": Move(step=1),
    b"\x1bOC": Move(step=1),
    b"\x1b[D": Move(step=-1),
    b"\x1bOD": Move(step=-1),
}
KEYS: dict[int, Event] = {
    ord("l"): Move(step=1),
    ord("\t"): Move(step=1),
    ord("h"): Move(step=-1),
    ord("\r"): Confirm(),
    ord("\n"): Confirm(),
    ord(" "): Confirm(),
    ord("q"): Cancel(),
    0x03: Cancel(),  # Ctrl-C
} | {ord(str(d)): Choose(index=d - 1) for d in range(1, 10)}


def _scan(buf: bytes, *, final: bool) -> tuple[list[Event], bytes]:
    events: list[Event] = []
    i = 0
    while i < len(buf):
        if buf[i] != ESC:
            if (event := KEYS.get(buf[i])) is not None:
                events.append(event)
            i += 1
        elif m := MOUSE.match(buf, i):
            if m[1] == b"0" and m[4] == b"M":  # left button press
                events.append(Click(int(m[2]), int(m[3])))
            i = m.end()
        elif m := CSI.match(buf, i) or SS3.match(buf, i):
            if (event := ARROWS.get(m[0])) is not None:
                events.append(event)
            i = m.end()
        elif INCOMPLETE.match(buf, i) and not final:
            return events, buf[i:]
        else:  # Esc, alone or before a key that isn't a sequence
            events.append(Cancel())
            i += 1
    return events, b""


def decode(decoder: Decoder, data: bytes) -> tuple[Decoder, list[Event]]:
    """Events in the bytes read so far. A trailing partial sequence or lone ESC stays Pending."""
    match decoder:
        case Idle():
            buf = data
        case Pending(tail=tail):
            buf = tail + data
        case _ as unreachable:
            assert_never(unreachable)
    events, tail = _scan(buf, final=False)
    return (Pending(tail=tail) if tail else Idle()), events


def flush(decoder: Decoder) -> list[Event]:
    """Events once no more input came while Pending: a lone ESC is the Esc key."""
    match decoder:
        case Idle():
            return []
        case Pending(tail=tail):
            return _scan(tail, final=True)[0]
        case _ as unreachable:
            assert_never(unreachable)


# --- Update ---------------------------------------------------------------------------


def _confirm(props: Props, state: State) -> tuple[State, list[Effect]]:
    match state.phase:
        case Applying():
            return state, []
        case Browsing() | Failed():
            return replace(state, phase=Applying()), [Apply(name=props.layouts[state.selected].name)]
        case _ as unreachable:
            assert_never(unreachable)


def update(props: Props, state: State, event: Event) -> tuple[State, list[Effect]]:
    n = len(props.layouts)
    match event:
        case Move(step=step):
            return replace(state, selected=(state.selected + step) % n), []
        case Choose(index=index):
            return (replace(state, selected=index) if 0 <= index < n else state), []
        case Click(col, row):
            index = hit(geometry(props, state.size), n, col, row)
            if index is None:
                return state, []
            return _confirm(props, replace(state, selected=index))
        case Confirm():
            return _confirm(props, state)
        case Resize(size=size):
            return replace(state, size=size), []
        case ApplyFailed(error=error):
            return replace(state, phase=Failed(error=error)), []
        case Applied() | Cancel():
            return state, [Exit()]
        case _ as unreachable:
            assert_never(unreachable)


# --- Render -----------------------------------------------------------------------------

U, D, L, R = 1, 2, 4, 8
BOX = {
    U | D: "│",
    L | R: "─",
    D | R: "┌",
    D | L: "┐",
    U | R: "└",
    U | L: "┘",
    U | D | R: "├",
    U | D | L: "┤",
    D | L | R: "┬",
    U | L | R: "┴",
    U | D | L | R: "┼",
}
GAP = 3
BOLD, ACCENT, DIM, RED, REVERSE, RESET = "\x1b[1m", "\x1b[1;36m", "\x1b[2m", "\x1b[31m", "\x1b[7m", "\x1b[0m"


def thumbnail(rects: tuple[Rect, ...], w: int, h: int) -> list[str]:
    """Box-drawn w×h thumbnail; each pane number is drawn only where it fits inside its borders."""
    bits = [[0] * w for _ in range(h)]
    labels: dict[tuple[int, int], str] = {}
    for r in rects:
        x0, x1 = round(r.x0 * (w - 1)), round(r.x1 * (w - 1))
        y0, y1 = round(r.y0 * (h - 1)), round(r.y1 * (h - 1))
        for y in (y0, y1):
            for x in range(x0, x1):
                bits[y][x] |= R
                bits[y][x + 1] |= L
        for x in (x0, x1):
            for y in range(y0, y1):
                bits[y][x] |= D
                bits[y + 1][x] |= U
        if y1 - y0 >= 2 and x1 - x0 > len(r.pane):
            cy, cx = (y0 + y1) // 2, (x0 + x1) // 2 - (len(r.pane) - 1) // 2
            for i, ch in enumerate(r.pane):
                labels[(cy, cx + i)] = ch
    return ["".join(labels.get((y, x)) or BOX.get(bits[y][x], " ") for x in range(w)) for y in range(h)]


def fits(layouts: tuple[Layout, ...], h: int) -> bool:
    """Whether every pane of every layout gets an interior row at thumbnail height h."""
    return all(round(r.y1 * (h - 1)) - round(r.y0 * (h - 1)) >= 2 for layout in layouts for r in layout.rects)


@dataclass(frozen=True, slots=True, kw_only=True)
class Geometry:
    left: int  # 0-based column of the first thumbnail
    top: int  # 0-based row above the thumbnails
    width: int
    height: int


def geometry(props: Props, size: Size) -> Geometry:
    """Where the thumbnails go; shared by render and click hit-testing."""
    n = len(props.layouts)
    width = max(7, min(24, (size.cols - 4 - GAP * (n - 1)) // n))
    height = max(4, min(width // 2 + 1, size.rows - 7))
    while height < size.rows - 7 and not fits(props.layouts, height):
        height += 1
    left = max(0, (size.cols - n * width - GAP * (n - 1)) // 2)
    top = max(2, (size.rows - height - 4) // 2)
    return Geometry(left=left, top=top, width=width, height=height)


def hit(g: Geometry, n: int, col: int, row: int) -> int | None:
    """The layout whose thumbnail or name is at the 1-based cell, if any."""
    if not g.top + 1 <= row <= g.top + g.height + 2:
        return None
    index, offset = divmod(col - 1 - g.left, g.width + GAP)
    return index if 0 <= index < n and offset < g.width else None


def at(row: int, col: int, text: str) -> str:
    return f"\x1b[{row};{col}H{text}"


def hint(props: Props, phase: Phase) -> str:
    match phase:
        case Browsing():
            return DIM + f"←/→ 1-{len(props.layouts)} select · Enter / click apply · Esc cancel · • current"
        case Applying():
            return DIM + "applying…"
        case Failed(error=error):
            return RED + error
        case _ as unreachable:
            assert_never(unreachable)


def render(props: Props, state: State) -> str:
    g = geometry(props, state.size)
    gap = " " * GAP
    thumbs = [thumbnail(layout.rects, g.width, g.height) for layout in props.layouts]
    out = ["\x1b[H\x1b[2J", at(1, g.left + 1, f"{BOLD}Select layout{RESET}")]
    for y in range(g.height):
        line = gap.join((ACCENT if i == state.selected else DIM) + t[y] + RESET for i, t in enumerate(thumbs))
        out.append(at(g.top + 1 + y, g.left + 1, line))
    names = []
    for i, layout in enumerate(props.layouts):
        label = (layout.name + (" •" if i == props.current else ""))[: g.width].center(g.width)
        names.append((REVERSE if i == state.selected else "") + label + RESET)
    out.append(at(g.top + g.height + 2, g.left + 1, gap.join(names)))
    out.append(at(g.top + g.height + 4, g.left + 1, hint(props, state.phase) + RESET))
    return "".join(out)


# --- Shell: the only impure part ----------------------------------------------------------

ESC_WAIT = 0.05  # seconds for the rest of an escape sequence before a lone ESC means Esc


@contextlib.contextmanager
def raw_terminal(fd: int) -> Generator[None]:
    """Raw mode, alternate screen, hidden cursor and SGR mouse reporting, all undone on exit."""
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h")
    sys.stdout.flush()
    try:
        yield
    finally:
        sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


async def apply_layout(target: str, name: str) -> Event:
    proc = await asyncio.create_subprocess_exec(
        "rex",
        "do",
        "layout_apply",
        f"name={name}",
        f"block={target}",
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode == 0:
        return Applied()
    return ApplyFailed(error=(stderr.decode(errors="replace").strip().splitlines() or ["rex do failed"])[-1])


def draw(props: Props, state: State) -> None:
    sys.stdout.write(render(props, state))
    sys.stdout.flush()


class Keyboard:
    """Feeds terminal input through the decoder and emits its Events.

    A Pending decoder gets ESC_WAIT for the rest of its sequence, then is flushed.
    """

    def __init__(self, loop: asyncio.AbstractEventLoop, emit: Callable[[Event], None]) -> None:
        self._loop = loop
        self._emit = emit
        self._decoder: Decoder = Idle()
        self._timer: asyncio.TimerHandle | None = None

    def feed(self, data: bytes) -> None:
        self._settle(*decode(self._decoder, data))

    def _on_timeout(self) -> None:
        self._settle(Idle(), flush(self._decoder))

    def _settle(self, decoder: Decoder, events: list[Event]) -> None:
        # The only writer of _decoder and _timer: the timer runs exactly while Pending.
        if self._timer is not None:
            self._timer.cancel()
        self._decoder = decoder
        self._timer = self._loop.call_later(ESC_WAIT, self._on_timeout) if isinstance(decoder, Pending) else None
        for event in events:
            self._emit(event)


async def run(fd: int, target: str, props: Props, state: State) -> None:
    loop = asyncio.get_running_loop()
    events: asyncio.Queue[Event] = asyncio.Queue()
    keyboard = Keyboard(loop, events.put_nowait)

    def on_readable() -> None:
        if data := os.read(fd, 1024):
            keyboard.feed(data)
        else:  # the terminal closed
            events.put_nowait(Cancel())

    async def perform(name: str) -> None:
        events.put_nowait(await apply_layout(target, name))

    loop.add_reader(fd, on_readable)
    loop.add_signal_handler(signal.SIGWINCH, lambda: events.put_nowait(Resize(size=Size(*os.get_terminal_size(fd)))))
    draw(props, state)
    # Exiting waits for an apply already running, so the window isn't left half rebuilt.
    async with asyncio.TaskGroup() as tasks:
        while True:
            new, effects = update(props, state, await events.get())
            if new != state:
                state = new
                draw(props, state)
            for effect in effects:
                match effect:
                    case Apply(name=name):
                        tasks.create_task(perform(name))
                    case Exit():
                        return
                    case _ as unreachable:
                        assert_never(unreachable)


def main() -> None:
    target, current, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    props = Props(layouts=parse_layouts(specs), current=current - 1 if current > 0 else None)
    fd = sys.stdin.fileno()
    state = State(selected=props.current or 0, size=Size(*os.get_terminal_size(fd)))
    with raw_terminal(fd):
        asyncio.run(run(fd, target, props, state))


if __name__ == "__main__":
    main()
