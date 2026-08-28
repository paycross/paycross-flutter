"""The action vocabulary a cell file can use, as one interface.

Every method a Phase-0 cell needs is implemented on both drivers. The four
lifecycle actions at the bottom -- background, rotate, airplane, kill_activity
-- are declared here and raise NotImplementedError: they belong to D3, they are
in the vocabulary so cell files can be written against a stable interface, and
a stub that raises is honest where a stub that silently does nothing is not.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime
from pathlib import Path

from ..cells import Card


class DriverError(RuntimeError):
    """The device did not do what was asked. Names what was being looked for."""


class Driver(ABC):
    #: Used by crash scanning and by log capture.
    package: str

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

        Takes a path rather than the token itself so the credential never
        becomes a command-line argument.
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
        """The raw accessibility dump, as it came off the device."""

    @abstractmethod
    def screenshot(self) -> bytes:
        """PNG bytes. Only ever called while the sheet is foreground."""

    @abstractmethod
    def logs_since(self, since: datetime) -> str:
        """Device log from `since` to now."""

    # -- D3, declared now so the vocabulary is stable -------------------------

    def background(self, seconds: float) -> None:
        raise NotImplementedError("background is a D3 action; Phase 0 does not use it")

    def rotate(self) -> None:
        raise NotImplementedError("rotate is a D3 action; Phase 0 does not use it")

    def airplane(self, on: bool) -> None:
        raise NotImplementedError("airplane is a D2 action; Phase 0 does not use it")

    def kill_activity(self) -> None:
        raise NotImplementedError("kill_activity is a D3 action; Phase 0 does not use it")
