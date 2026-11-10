from __future__ import annotations

import pytest


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """A skipped test is not a passed test: fail the run if anything was skipped."""
    reporter = session.config.pluginmanager.get_plugin("terminalreporter")
    if reporter is not None and reporter.stats.get("skipped"):
        session.exitstatus = pytest.ExitCode.TESTS_FAILED
