#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""bin/layout-picker.py without a terminal: decode, update, render, Keyboard. Run: uv run tests/unit/test_layout_picker.py"""

import asyncio
import importlib.util
import sys
import unittest
from dataclasses import replace
from pathlib import Path

PICKER = Path(__file__).resolve().parents[2] / "bin" / "layout-picker.py"
_spec = importlib.util.spec_from_file_location("layout_picker", PICKER)
assert _spec is not None and _spec.loader is not None
picker = importlib.util.module_from_spec(_spec)
sys.modules["layout_picker"] = picker  # dataclasses resolve their module by name
_spec.loader.exec_module(picker)

# lib/layout_tree.rects output, as features/layout.lua passes it.
MAIN_VERTICAL_3 = (
    "main-vertical|1:0.0000:0.0000:0.6000:1.0000,2:0.6000:0.0000:1.0000:0.5000,3:0.6000:0.5000:1.0000:1.0000"
)
EVEN_VERTICAL_5 = "even-vertical|" + ",".join(f"{i + 1}:0.0000:{i / 5:.4f}:1.0000:{(i + 1) / 5:.4f}" for i in range(5))
EVEN_HORIZONTAL_2 = "even-horizontal|1:0.0000:0.0000:0.5000:1.0000,2:0.5000:0.0000:1.0000:1.0000"


PROPS = picker.Props(layouts=picker.parse_layouts([EVEN_HORIZONTAL_2, MAIN_VERTICAL_3, EVEN_VERTICAL_5]), current=None)


def state(**changes):
    return replace(picker.State(selected=0, size=picker.Size(100, 20)), **changes)


def update(s, event):
    return picker.update(PROPS, s, event)


class Decode(unittest.TestCase):
    def test_keys_and_arrows(self):
        decoder, events = picker.decode(picker.Idle(), b"l\x1b[Ch\x1bOD3\r")
        self.assertEqual(
            events,
            [
                picker.Move(step=1),
                picker.Move(step=1),
                picker.Move(step=-1),
                picker.Move(step=-1),
                picker.Choose(index=2),
                picker.Confirm(),
            ],
        )
        self.assertEqual(decoder, picker.Idle())

    def test_sequence_split_across_reads_waits_for_the_rest(self):
        decoder, events = picker.decode(picker.Idle(), b"l\x1b[")
        self.assertEqual((decoder, events), (picker.Pending(tail=b"\x1b["), [picker.Move(step=1)]))
        decoder, events = picker.decode(decoder, b"C")
        self.assertEqual((decoder, events), (picker.Idle(), [picker.Move(step=1)]))

    def test_lone_esc_is_cancel_only_once_flushed(self):
        decoder, events = picker.decode(picker.Idle(), b"\x1b")
        self.assertEqual((decoder, events), (picker.Pending(tail=b"\x1b"), []))
        self.assertEqual(picker.flush(decoder), [picker.Cancel()])
        self.assertEqual(picker.flush(picker.Idle()), [])

    def test_mouse_left_press_only(self):
        _, events = picker.decode(picker.Idle(), b"\x1b[<0;12;5M\x1b[<0;12;5m\x1b[<2;3;4M")
        self.assertEqual(events, [picker.Click(12, 5)])

    def test_unknown_sequences_and_keys_are_ignored(self):
        self.assertEqual(picker.decode(picker.Idle(), b"\x1b[1;5Ax"), (picker.Idle(), []))


class Keyboard(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.events = []
        self.keyboard = picker.Keyboard(asyncio.get_running_loop(), self.events.append)

    async def wait_past_esc(self):
        await asyncio.sleep(picker.ESC_WAIT * 3)

    async def test_lone_esc_cancels_after_the_wait(self):
        self.keyboard.feed(b"\x1b")
        self.assertEqual(self.events, [])
        await self.wait_past_esc()
        self.assertEqual(self.events, [picker.Cancel()])

    async def test_sequence_completed_in_time_is_not_cancel(self):
        self.keyboard.feed(b"\x1b[")
        self.keyboard.feed(b"C")
        await self.wait_past_esc()
        self.assertEqual(self.events, [picker.Move(step=1)])


class Update(unittest.TestCase):
    def test_move_wraps(self):
        new, effects = update(state(selected=0), picker.Move(step=-1))
        self.assertEqual((new.selected, effects), (2, []))

    def test_choose_out_of_range_does_nothing(self):
        s = state()
        self.assertEqual(update(s, picker.Choose(index=7)), (s, []))

    def test_confirm_applies_once(self):
        s, effects = update(state(selected=1), picker.Confirm())
        self.assertEqual((s.phase, effects), (picker.Applying(), [picker.Apply(name="main-vertical")]))
        self.assertEqual(update(s, picker.Confirm()), (s, []))

    def test_failure_shows_the_error_and_allows_retry(self):
        s, _ = update(state(), picker.Confirm())
        s, effects = update(s, picker.ApplyFailed(error="boom"))
        self.assertEqual((s.phase, effects), (picker.Failed(error="boom"), []))
        s, effects = update(s, picker.Confirm())
        self.assertEqual((s.phase, effects), (picker.Applying(), [picker.Apply(name="even-horizontal")]))

    def test_success_and_cancel_exit(self):
        self.assertEqual(update(state(), picker.Applied())[1], [picker.Exit()])
        self.assertEqual(update(state(phase=picker.Applying()), picker.Cancel())[1], [picker.Exit()])

    def test_click_on_a_thumbnail_selects_and_applies_it(self):
        s = state()
        g = picker.geometry(PROPS, s.size)
        col = g.left + 1 + 2 * (g.width + picker.GAP) + 1  # inside the third thumbnail
        new, effects = update(s, picker.Click(col, g.top + 2))
        self.assertEqual((new.selected, new.phase), (2, picker.Applying()))
        self.assertEqual(effects, [picker.Apply(name="even-vertical")])

    def test_click_outside_does_nothing(self):
        s = state()
        self.assertEqual(update(s, picker.Click(1, 1)), (s, []))

    def test_resize_changes_only_the_size(self):
        new, effects = update(state(selected=1), picker.Resize(size=picker.Size(80, 24)))
        self.assertEqual((new, effects), (state(selected=1, size=picker.Size(80, 24)), []))


class Render(unittest.TestCase):
    def test_hint_follows_the_phase(self):
        self.assertIn("Enter / click apply", picker.render(PROPS, state()))
        self.assertIn("applying…", picker.render(PROPS, state(phase=picker.Applying())))
        self.assertIn("boom", picker.render(PROPS, state(phase=picker.Failed(error="boom"))))

    def test_current_layout_is_marked(self):
        props = replace(PROPS, current=1)
        self.assertIn("main-vertical •", picker.render(props, state()))
        self.assertNotIn("•", picker.render(PROPS, state()).replace("• current", ""))


class Thumbnail(unittest.TestCase):
    def test_main_vertical(self):
        [layout] = picker.parse_layouts([MAIN_VERTICAL_3])
        self.assertEqual(
            picker.thumbnail(layout.rects, 16, 7),
            [
                "┌────────┬─────┐",
                "│        │  2  │",
                "│        │     │",
                "│   1    ├─────┤",
                "│        │  3  │",
                "│        │     │",
                "└────────┴─────┘",
            ],
        )

    def test_labels_never_overwrite_borders(self):
        [layout] = picker.parse_layouts([EVEN_VERTICAL_5])
        for line in picker.thumbnail(layout.rects, 16, 7):
            if "─" in line:
                self.assertFalse(any(ch.isdigit() for ch in line), line)

    def test_fits_grows_until_every_pane_has_a_row(self):
        layouts = picker.parse_layouts([EVEN_VERTICAL_5])
        self.assertFalse(picker.fits(layouts, 7))
        self.assertTrue(picker.fits(layouts, 11))


if __name__ == "__main__":
    unittest.main()
