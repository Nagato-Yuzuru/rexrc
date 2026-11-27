#!/usr/bin/env python3
"""End-to-end smoke test of features/ against the running Rex server.

Works only in a background window it creates in $REX_SESSION and always closes,
and drives every rex call with an explicit block: an empty target would fall
back to the focused pane, which is the user's.

    mise run test
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections.abc import Callable
from typing import Any

SESSION = os.environ.get("REX_SESSION", "")


class Failure(Exception):
    pass


def rex(*args: str) -> str:
    result = subprocess.run(["rex", *args], check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise Failure(f"rex {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def require_id(value: Any, kind: str) -> str:
    if not isinstance(value, str) or not value.startswith(kind + ":"):
        raise Failure(f"expected a {kind} id, got {value!r}")
    return value


def wait(check: Callable[[], Any], what: str, timeout: float = 5.0) -> Any:
    deadline = time.monotonic() + timeout
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > deadline:
            raise Failure(f"timed out waiting for {what}")
        time.sleep(0.1)


class Window:
    def __init__(self) -> None:
        created = json.loads(rex("window", "new", "-s", SESSION, "--focus=false", "--json"))
        self.id = require_id(created["window_id"], "window")
        self.first = require_id(created["block_ids"][0], "block")

    def close(self) -> None:
        rex("window", "close", "-s", SESSION, self.id)

    def inspect(self) -> dict:
        return json.loads(rex("window", "inspect", self.id, "-s", SESSION, "--json"))

    def tiled(self) -> dict:
        return next(layer["layout"] for layer in self.inspect()["layers"] if layer["kind"] == "tiled")

    def floats(self) -> list[tuple[str, str | None, str | None]]:
        """(block id, label, layer state) for every block in a floating layer."""
        return [
            (block["block_id"], block.get("label"), layer.get("state"))
            for layer in self.inspect()["layers"]
            if layer["kind"] != "tiled"
            for block in layer.get("blocks", [])
        ]

    def float_labeled(self, label: str) -> str | None:
        return next((block for block, lbl, _ in self.floats() if lbl == label), None)

    def split(self) -> None:
        rex("split", "-s", SESSION, "-b", self.first, "--split", "right", "--focus=false")

    def do(self, action: str, *args: str, block: str | None = None) -> None:
        rex("do", "-s", SESSION, "-b", require_id(block or self.first, "block"), action, *args)


def send(block: str, text: str | None = None, key: str | None = None) -> None:
    block = require_id(block, "block")
    if text is not None:
        rex("send", "-s", SESSION, "-b", block, text)
    if key is not None:
        rex("send-key", "-s", SESSION, "-b", block, key)


def capture(block: str) -> str:
    return rex("capture", "-s", SESSION, "-b", require_id(block, "block"))


def shape(node: dict) -> Any:
    """A layout tree as nested (direction, ratio rounded, before, after), leaves as block ids."""
    if "block_id" in node:
        return node["block_id"]
    split = node["split"]
    return (split["direction"], round(split["ratio"], 2), shape(split["before"]), shape(split["after"]))


def open_bar(win: Window) -> str:
    win.do("popup")
    return wait(lambda: win.float_labeled("popup>"), "the popup bar")


def test_popup_command(win: Window) -> None:
    send(open_bar(win), "sleep 1", "enter")
    wait(lambda: win.float_labeled("popup"), "the popup to show")
    wait(lambda: not win.floats(), "the popup to close after the command exits")


def test_popup_quick_failure(win: Window) -> None:
    bar = open_bar(win)
    send(bar, "ls /nonexistent-rex-smoke", "enter")
    wait(lambda: "nonexistent-rex-smoke: No such file" in capture(bar), "the error in the bar")
    if win.float_labeled("popup"):
        raise Failure("a quick failure showed the popup")
    send(bar, key="escape")
    wait(lambda: not win.floats(), "Esc to close the bar")


def test_popup_empty_opens_shell(win: Window) -> None:
    send(open_bar(win), key="enter")
    shell = wait(lambda: win.float_labeled("popup"), "the popup shell")
    send(shell, "exit", "enter")
    wait(lambda: not win.floats(), "the popup shell to close")


def test_scratch(win: Window) -> None:
    listed = json.loads(rex("block", "ls", "-s", SESSION, "--json"))
    blocks = listed["blocks"] if isinstance(listed, dict) else listed
    if any(block.get("label") == "scratch" for block in blocks):
        print("  skipped: this session already has a scratch, which the test would move")
        return
    win.do("scratch_toggle")
    scratch = wait(lambda: win.float_labeled("scratch"), "the scratch to open")
    win.do("scratch_toggle", block=scratch)
    wait(lambda: "minimized" in [state for b, _, state in win.floats() if b == scratch], "minimize")
    win.do("scratch_toggle")
    wait(lambda: "minimized" not in [state for b, _, state in win.floats() if b == scratch], "restore")
    send(scratch, "exit", "enter")
    wait(lambda: not win.floats(), "the scratch shell to close")


def test_scratch_follows_to_other_window(win: Window) -> None:
    win.do("scratch_toggle")
    scratch = wait(lambda: win.float_labeled("scratch"), "the scratch to open")
    other = Window()
    try:
        other.split()
        tiled = shape(other.tiled())
        other.do("scratch_toggle")
        wait(lambda: other.float_labeled("scratch") == scratch, "the scratch to move to the other window")
        wait(lambda: not win.floats(), "the scratch's old layer to go")
        wait(lambda: [lbl for _, lbl, _ in other.floats()] == ["scratch"], "the placeholder to close")
        if shape(other.tiled()) != tiled:
            raise Failure(f"floating the scratch changed the tiled panes: {shape(other.tiled())}")
    finally:
        other.close()


def test_layout_select(win: Window) -> None:
    win.do("layout_select", "name=even-vertical")
    got = shape(win.tiled())
    if not (isinstance(got, tuple) and got[0] == "vertical" and got[2] == win.first):
        raise Failure(f"even-vertical gave {got}")


def test_layout_picker(win: Window) -> None:
    win.do("layout_popup")
    picker = wait(lambda: win.float_labeled("layout"), "the layout picker")
    wait(lambda: "Select layout" in capture(picker), "the picker to draw")
    send(picker, key="4")
    send(picker, key="enter")
    wait(lambda: not win.floats(), "the picker to close")
    got = shape(win.tiled())
    if not (got[0] == "horizontal" and got[1] == 0.6 and got[2] == win.first and got[3][0] == "vertical"):
        raise Failure(f"main-vertical gave {got}")


def test_layout_picker_esc(win: Window) -> None:
    before = shape(win.tiled())
    win.do("layout_popup")
    picker = wait(lambda: win.float_labeled("layout"), "the layout picker")
    wait(lambda: "Select layout" in capture(picker), "the picker to draw")
    send(picker, key="escape")
    wait(lambda: not win.floats(), "Esc to close the picker")
    if shape(win.tiled()) != before:
        raise Failure("Esc changed the layout")


def contains(tree: Any, subtree: Any) -> bool:
    return tree == subtree or (isinstance(tree, tuple) and (contains(tree[2], subtree) or contains(tree[3], subtree)))


# The block argument skips the picker, which would ask the user's apps.
def test_join_from_other_window(win: Window) -> None:
    other = Window()
    try:
        win.do("pane_join", f"block={other.first}")
    except Failure:
        other.close()
        raise
    # Its only pane left, so Rex closed the other window.
    if not contains(shape(win.tiled()), ("vertical", 0.5, win.first, other.first)):
        raise Failure(f"the joined pane isn't below the focused one: {shape(win.tiled())}")
    close_block(other.first)


def test_send_to_other_window(win: Window) -> None:
    other = Window()
    try:
        other.do("pane_send", f"anchor={win.first}")
    except Failure:
        other.close()
        raise
    if not contains(shape(win.tiled()), ("vertical", 0.5, win.first, other.first)):
        raise Failure(f"the sent pane isn't below the anchor: {shape(win.tiled())}")
    close_block(other.first)


TESTS = [
    test_popup_command,
    test_popup_quick_failure,
    test_popup_empty_opens_shell,
    test_scratch,
    test_scratch_follows_to_other_window,
    test_layout_select,
    test_layout_picker_esc,
    test_layout_picker,
    test_join_from_other_window,
    test_send_to_other_window,
]


def blocks_outside(window_id: str) -> set[str]:
    """Every block in the session's other windows."""
    session_view = json.loads(rex("session", "inspect", SESSION, "--json"))
    session_view = session_view.get("view", session_view)
    return {
        block["block_id"]
        for window in session_view["windows"]
        if window["window_id"] != window_id
        for layer in window["layers"]
        for block in layer.get("blocks", [])
    }


def close_block(block: str) -> None:
    rex("api", "call", "-s", SESSION, "block.close", json.dumps({"block_id": require_id(block, "block")}))


def main() -> int:
    if not SESSION.startswith("session:"):
        print("REX_SESSION is not set: run inside a Rex terminal", file=sys.stderr)
        return 2
    win = Window()
    before = blocks_outside(win.id)
    failed = 0
    try:
        win.split()
        win.split()
        for test in TESTS:
            name = test.__name__.removeprefix("test_")
            try:
                test(win)
                print(f"ok    {name}")
            except Failure as err:
                failed += 1
                print(f"FAIL  {name}: {err}")
                for block, _, _ in win.floats():
                    close_block(block)
    finally:
        # Anything new outside the test window was opened in the wrong place.
        leaked = blocks_outside(win.id) - before
        for block in leaked:
            close_block(block)
        win.close()
    if leaked:
        failed += 1
        print(f"FAIL  isolation: {len(leaked)} block(s) opened outside the test window, now closed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
