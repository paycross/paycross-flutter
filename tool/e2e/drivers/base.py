"""The action vocabulary a cell file can use, as one interface."""

from __future__ import annotations

import os
import re
import time
from abc import ABC, abstractmethod
from datetime import datetime
from pathlib import Path
from typing import Callable

from .. import tree
from ..cells import Card


def rig_path(name: str, default: str) -> str:
    """A rig constant, overridable from the environment; blank counts as unset."""
    return os.environ.get(name) or default


class DriverError(RuntimeError):
    """The device did not do what was asked. Names what was being looked for."""


# The token reaches an Android device shell that re-splits it, so its
# shape is checked first.
JWT_SHAPE = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){2,}")


def read_token(token_path: Path, *, verb: str) -> str:
    """Returns the token in `token_path`, refusing one that is empty or not a JWT."""
    text = Path(token_path).read_text(encoding="utf-8").strip()
    if not text:
        raise DriverError(f"{token_path} is empty: there is no token to {verb}")
    if not JWT_SHAPE.fullmatch(text):
        raise DriverError(
            f"{token_path} does not hold a JWT: {len(text)} characters in "
            f"{text.count('.') + 1} dot-separated segments, and not all of "
            f"them are base64url. Refusing to {verb} it."
        )
    return text


def device_text(raw: bytes) -> str:
    """Decodes device output as UTF-8 with CRLF line endings normalised."""
    # iOS console capture arrives through a pty, which puts a CR before every LF.
    return raw.decode("utf-8", errors="replace").replace("\r\n", "\n")


class Driver(ABC):
    device_noun = "device"

    def __init__(self, *, package: str, sleep: Callable[[float], None]):
        self.package = package
        self._sleep = sleep

    @staticmethod
    @abstractmethod
    def _parse_dump(dump: bytes) -> list[tree.Node]:
        """Turns one accessibility dump into nodes."""

    def no_label_error(self, timeout: float) -> DriverError:
        """Explains a missing label, naming the build define if that is the cause."""
        if tree.label_from_tree(self._nodes(tolerate=True), tree.LEGACY_LABEL_PREFIXES):
            return DriverError(
                f"no contract label within {timeout}s, but the app is showing "
                "its human-readable outcome: this build is missing "
                "--dart-define=PAYCROSS_E2E=true"
            )
        return DriverError(f"no contract label within {timeout}s")

    def _nodes(self, tolerate: bool = False) -> list[tree.Node]:
        """Returns the current tree; `[]` with `tolerate` if the device won't dump."""
        try:
            return self._parse_dump(self.dump_tree())
        except DriverError:
            if not tolerate:
                raise
            return []

    def _poll(self, look, timeout: float, interval: float):
        """Runs `look` over the tree until it answers or the deadline passes."""
        deadline = time.monotonic() + timeout
        while True:
            live = time.monotonic() < deadline
            found = look(self._nodes(tolerate=live))
            if found is not None:
                return found
            if not live:
                return None
            self._sleep(interval)

    @abstractmethod
    def install(self, app_path: str) -> None:
        """Replaces any existing build of the example app."""

    @abstractmethod
    def launch(self) -> None:
        """Cold-starts the example app and asserts the rig's preconditions."""

    @abstractmethod
    def paste_token(self, token_path: Path) -> None:
        """Enters the session token, taps the example's Pay, waits for the sheet."""

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

    def _blame_the_amount(self, amount_text: str) -> None:
        """Raises when a re-arm failed only because the amount is spelled elsewise."""
        showing = tree.rearm_amount_mismatch(self._nodes(tolerate=True), amount_text)
        if showing is not None:
            raise DriverError(
                f"the sheet re-armed showing {showing!r} where this cell expects "
                f"{amount_text!r}: the {self.device_noun} is not drawing amounts "
                "in the spelling `tree.format_amount_en_us` computes, so the "
                "re-arm check cannot answer. This is the rig, not the SDK."
            )

    @abstractmethod
    def wait_rearmed(self, amount_text: str, timeout: float) -> bool:
        """Blocks until the sheet re-arms after a retryable decline."""

    def wait_no_label(self, timeout: float, *, interval: float = 2) -> str | None:
        """Watches for `timeout` seconds and returns the label that appeared, if any."""
        return self._poll(tree.label_from_tree, timeout, interval)

    def relaunch(self) -> None:
        """Cold-starts the app again mid-cell, without losing the log window."""
        self.launch()

    @abstractmethod
    def dump_tree(self) -> bytes:
        """The accessibility dump, as UTF-8."""

    @abstractmethod
    def screenshot(self) -> bytes:
        """PNG bytes. Only ever called while the sheet is foreground."""

    @abstractmethod
    def logs_since(self, since: datetime) -> str:
        """Device log from `since` to now."""

    def close(self) -> None:  # noqa: B027 - a default of "nothing to release"
        """Releases whatever this driver is holding on the host. Idempotent."""

    def background(self, seconds: float) -> None:
        raise NotImplementedError("background is a D3 action; Phase 0 does not use it")

    def rotate(self) -> None:
        raise NotImplementedError("rotate is a D3 action; Phase 0 does not use it")

    def airplane(self, on: bool) -> None:
        raise NotImplementedError("airplane is a D2 action; this driver has none")

    def kill_activity(self) -> None:
        raise NotImplementedError(
            "kill_activity is a D3 action; Phase 0 does not use it"
        )

    def dont_keep_activities(self, on: bool) -> None:
        raise NotImplementedError("dont_keep_activities is a D3 action, Android only")

    def device_language(self, tag: str) -> None:
        raise NotImplementedError("device_language is a D6 action")

    def type_cvv(self, cvv: str) -> None:
        raise NotImplementedError(
            "type_cvv is a D5 action, for retyping a saved card's CVV"
        )

    def tap_google_pay(self) -> None:
        raise NotImplementedError("tap_google_pay is a D4 action, Android only")

    def select_saved_card(self) -> None:
        raise NotImplementedError("select_saved_card is a D5 action")

    def remove_saved_card(self) -> None:
        raise NotImplementedError("remove_saved_card is a D5 action")

    def save_card(self) -> None:
        raise NotImplementedError("save_card is a D5 action")

    def dismiss_cancel(self) -> None:
        raise NotImplementedError("dismiss_cancel is a D2 action")

    def wait_acs(self, timeout: float) -> bool:
        raise NotImplementedError("wait_acs is a D2 predicate; this driver has none")

    def wait_google_pay(self, timeout: float) -> bool:
        raise NotImplementedError("wait_google_pay is a D4 expectation, Android only")

    def wait_no_google_pay(self, timeout: float) -> bool:
        raise NotImplementedError(
            "wait_no_google_pay is a D4 expectation, Android only"
        )

    def wait_saved_card(self, timeout: float) -> bool:
        raise NotImplementedError("wait_saved_card is a D5 expectation")

    def _pay_buttons(self, nodes: list[tree.Node]) -> list[tree.Node]:
        """Returns the nodes in `nodes` that are the sheet's Pay button."""
        raise NotImplementedError("this driver cannot name its Pay button")

    def wait_french_sheet(self, timeout: float, *, interval: float = 2) -> bool:
        """Whether the sheet is drawing the SDK's own copy of the Pay verb in French."""

        def french(nodes: list[tree.Node]) -> bool | None:
            for button in self._pay_buttons(nodes):
                if tree.caption(nodes, button).startswith(tree.FRENCH_PAY_VERB):
                    return True
            return None

        return self._poll(french, timeout, interval) is True
