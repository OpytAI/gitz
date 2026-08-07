"""Phase id ranking and helpers for inventory checkers."""

from __future__ import annotations

from typing import Union

PhaseId = Union[str, int]


def phase_rank(phase: PhaseId) -> int:
    """Map phase id to integer rank. g=0, 1=1, … 13=13."""
    if phase is None:
        raise ValueError("phase is required")
    if isinstance(phase, bool):
        # bool is a subclass of int; reject to avoid True→1 surprises
        raise ValueError(f"unknown phase id: {phase!r}")
    if isinstance(phase, int):
        return phase
    s = str(phase).strip().lower()
    if s == "":
        raise ValueError("phase is required")
    if s == "g":
        return 0
    if s.isdigit():
        return int(s)
    raise ValueError(f"unknown phase id: {phase!r}")


def phase_due(package_phase: PhaseId, current_phase: PhaseId) -> bool:
    """True if package_phase must be present for current_phase."""
    return phase_rank(package_phase) <= phase_rank(current_phase)


def self_test() -> None:
    assert phase_rank("g") == 0
    assert phase_rank("G") == 0
    assert phase_rank(1) == 1
    assert phase_rank("1") == 1
    assert phase_rank("13") == 13
    assert phase_due(1, "g") is False
    assert phase_due("g", "g") is True
    assert phase_due(1, 1) is True
    assert phase_due(1, "1") is True
    assert phase_due(2, 1) is False
    try:
        phase_rank("nope")
        raise AssertionError("expected ValueError")
    except ValueError:
        pass
    try:
        phase_rank(None)  # type: ignore[arg-type]
        raise AssertionError("expected ValueError")
    except ValueError:
        pass
    try:
        phase_rank("")
        raise AssertionError("expected ValueError")
    except ValueError:
        pass
    print("phase_util self_test OK")


if __name__ == "__main__":
    self_test()
