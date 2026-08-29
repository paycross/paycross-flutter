"""The action vocabulary a cell file can use, as one interface.

Every method a Phase-0 cell needs is implemented on both drivers. The four
lifecycle actions at the bottom -- background, rotate, airplane, kill_activity
-- are declared here and raise NotImplementedError: they belong to D3, they are
in the vocabulary so cell files can be written against a stable interface, and
a stub that raises is honest where a stub that silently does nothing is not.

`_nodes` and `_poll` live here too. They were written twice, once per driver,
and were identical but for which parser turned a dump into nodes; the runner is
the first thing to drive both, and one waiting rule is one place to be wrong.
"""

from __future__ import annotations

import time
from abc import ABC, abstractmethod
from datetime import datetime
from pathlib import Path
from typing import Callable

from .. import tree
from ..cells import Card


class DriverError(RuntimeError):
    """The device did not do what was asked. Names what was being looked for."""


class Driver(ABC):
    #: What `verify.crash_lines` matches `ANR in <package>` against. Log
    #: capture does not use it -- it is deliberately device-wide, because
    #: an ANR is logged by system_server rather than by the app.
    package: str

    #: Every wait goes through this. The concrete drivers inject it so their
    #: tests can pin the rig's real timings without spending them.
    _sleep: Callable[[float], None]

    @staticmethod
    @abstractmethod
    def _parse_dump(dump: bytes) -> list[tree.Node]:
        """Turns one accessibility dump into nodes.

        `tree.parse_uiautomator` on Android and `tree.parse_wda` on iOS -- the
        only difference the two drivers' `_nodes` ever had.
        """

    # -- waiting -------------------------------------------------------------

    def _nodes(self, tolerate: bool = False) -> list[tree.Node]:
        """The current tree, or `[]` if `tolerate` and the device would not dump.

        `uiautomator` refuses while the UI animates and WebDriverAgent answers
        mid-transition with a truncated body, which is precisely what they are
        doing through the waits that matter -- the 120 s ACS wait, the 60 s
        wait for the sheet. A polling caller has its own deadline and should
        spend it, so it tolerates a refusal and looks again. A one-shot read
        has no second chance and must not silently see an empty screen: the
        PAN check would call it a formatter bug and the token check a truncated
        paste, when the truth is that nothing was read at all.
        """
        try:
            return self._parse_dump(self.dump_tree())
        except DriverError:
            if not tolerate:
                raise
            return []

    def _poll(self, look, timeout: float, interval: float):
        """Runs `look` over the tree until it answers, or the deadline passes.

        `look` returns what it found, or None for "not yet"; `_poll` hands back
        the same, so each caller decides whether nothing is an error. The one
        rule that lives here rather than once per caller: a refused dump reads
        as an empty tree while the deadline is live and raises once it is not,
        so a device that will not dump is reported as itself rather than as
        whatever happened to be waited for.

        The deadline is real time while the interval is not: with a no-op
        sleep injected this busy-waits, so a test that means to reach the
        deadline passes `timeout=0` or patches the constant that supplies it.

        The deadline bounds when the next look *starts*, not how long one
        takes: a look's own transport timeout is spent on top of it. That is
        why WDA_TIMEOUT_SECONDS is 30 rather than the ssh ceiling -- a 120 s
        curl would let a 10 s wait run for two minutes -- and why the runner
        gives each cell a wall-clock budget with slack in it.
        """
        deadline = time.monotonic() + timeout
        while True:
            live = time.monotonic() < deadline
            found = look(self._nodes(tolerate=live))
            if found is not None:
                return found
            if not live:
                return None
            self._sleep(interval)

    # -- lifecycle -----------------------------------------------------------

    @abstractmethod
    def install(self, app_path: str) -> None:
        """Replaces any existing build of the example app."""

    @abstractmethod
    def launch(self) -> None:
        """Cold-starts the example app and asserts the rig's preconditions."""

    # -- the cell's actions --------------------------------------------------

    @abstractmethod
    def paste_token(self, token_path: Path) -> None:
        """Enters the session token, taps the example's Pay, waits for the sheet.

        Takes a path rather than the token so the credential is never held by
        the runner and never reaches its argv, nor adb's. It is still typed
        into the device, where the shell that receives it can see it; that
        exposure is unavoidable and lasts as long as the keystrokes do.
        """

    @abstractmethod
    def type_card(self, card: Card) -> None:
        """Fills the SDK's card form through the real fields. No prefill."""

    @abstractmethod
    def tap_pay(self, amount_text: str) -> None:
        """Taps the *sheet's* Pay button."""

    @abstractmethod
    def wait_label(self, timeout: float) -> str:
        """Blocks until the example app renders a contract label."""

    @abstractmethod
    def acs(self, outcome: str) -> None:
        """Waits for the sandbox ACS page and taps one outcome button."""

    @abstractmethod
    def cancel_challenge(self) -> None:
        """Abandons an in-flight 3-D Secure challenge, confirming the prompt."""

    @abstractmethod
    def cancel_form(self) -> None:
        """Abandons the sheet from the card form, confirming the prompt."""

    @abstractmethod
    def wait_rearmed(self, amount_text: str, timeout: float) -> bool:
        """Blocks until the sheet re-arms after a retryable decline."""

    # -- evidence ------------------------------------------------------------

    @abstractmethod
    def dump_tree(self) -> bytes:
        """The accessibility dump, as UTF-8.

        Not byte-identical to what the device produced: the Android transport
        decodes with replacement and re-encodes, so an undecodable byte
        arrives here as U+FFFD.
        """

    @abstractmethod
    def screenshot(self) -> bytes:
        """PNG bytes. Only ever called while the sheet is foreground."""

    @abstractmethod
    def logs_since(self, since: datetime) -> str:
        """Device log from `since` to now."""

    def close(self) -> None:
        """Releases whatever this driver is holding on the host. Idempotent.

        Concrete rather than abstract because only iOS holds anything: its
        console capture is a process on the Mac that outlives the app, and
        launch() only ever clears the *previous* cell's, so the last one of a
        run would outlive the run. There is no Android equivalent -- logcat is
        read on demand -- so the default does nothing.

        May raise DriverError when the thing it is releasing will not go. A
        caller running this in a `finally` should take care not to let that
        stand in for the failure it was already reporting.
        """

    # -- D3, declared now so the vocabulary is stable -------------------------

    def background(self, seconds: float) -> None:
        raise NotImplementedError("background is a D3 action; Phase 0 does not use it")

    def rotate(self) -> None:
        raise NotImplementedError("rotate is a D3 action; Phase 0 does not use it")

    def airplane(self, on: bool) -> None:
        raise NotImplementedError("airplane is a D2 action; Phase 0 does not use it")

    def kill_activity(self) -> None:
        raise NotImplementedError("kill_activity is a D3 action; Phase 0 does not use it")
