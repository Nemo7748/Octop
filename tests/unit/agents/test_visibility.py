"""Tests for the agent visibility and review-state rules."""

from __future__ import annotations

import pytest

from octop.infra.agents.visibility import (
    AgentView,
    can_manage,
    can_publish,
    is_published_to,
    is_visible_to,
    next_review_status,
)

ALICE = 1
BOB = 2
ADMIN = 3


def _agent(**overrides: object) -> AgentView:
    defaults: dict[str, object] = {
        "agent_id": "agt_test",
        "owner_id": ALICE,
        "visibility": "private",
        "review_status": "draft",
        "enabled": True,
    }
    defaults.update(overrides)
    return AgentView(**defaults)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("description", "agent", "viewer", "shares", "expected"),
    [
        ("owner sees own draft", _agent(), ALICE, frozenset(), True),
        ("other cannot see draft", _agent(), BOB, frozenset(), False),
        (
            "pending is invisible even when public",
            _agent(visibility="public", review_status="pending"),
            BOB,
            frozenset(),
            False,
        ),
        (
            "rejected is invisible even when public",
            _agent(visibility="public", review_status="rejected"),
            BOB,
            frozenset(),
            False,
        ),
        (
            "approved public is visible",
            _agent(visibility="public", review_status="approved"),
            BOB,
            frozenset(),
            True,
        ),
        (
            "shared needs the whitelist",
            _agent(visibility="shared", review_status="approved"),
            BOB,
            frozenset(),
            False,
        ),
        (
            "shared with whitelist is visible",
            _agent(visibility="shared", review_status="approved"),
            BOB,
            frozenset({BOB}),
            True,
        ),
        (
            "approved private stays hidden",
            _agent(visibility="private", review_status="approved"),
            BOB,
            frozenset(),
            False,
        ),
    ],
)
def test_is_visible_to(
    description: str,
    agent: AgentView,
    viewer: int,
    shares: frozenset[int],
    expected: bool,
) -> None:
    assert is_visible_to(agent, viewer, shares) is expected, description


@pytest.mark.parametrize(
    ("description", "agent", "viewer", "shares", "expected"),
    [
        (
            "approved public appears in the catalog",
            _agent(visibility="public", review_status="approved"),
            BOB,
            frozenset(),
            True,
        ),
        (
            "disabled agents never appear",
            _agent(visibility="public", review_status="approved", enabled=False),
            BOB,
            frozenset(),
            False,
        ),
        (
            "the author's own agent is not duplicated",
            _agent(visibility="public", review_status="approved"),
            ALICE,
            frozenset(),
            False,
        ),
        (
            "shared with whitelist appears",
            _agent(visibility="shared", review_status="approved"),
            BOB,
            frozenset({BOB}),
            True,
        ),
        (
            "pending never appears",
            _agent(visibility="public", review_status="pending"),
            BOB,
            frozenset(),
            False,
        ),
    ],
)
def test_is_published_to(
    description: str,
    agent: AgentView,
    viewer: int,
    shares: frozenset[int],
    expected: bool,
) -> None:
    assert is_published_to(agent, viewer, shares) is expected, description


def test_owner_and_admin_may_manage() -> None:
    agent = _agent()
    assert can_manage(agent, ALICE, is_admin=False) is True
    assert can_manage(agent, BOB, is_admin=False) is False
    assert can_manage(agent, ADMIN, is_admin=True) is True


def test_only_admin_publishes_and_only_from_pending() -> None:
    pending = _agent(review_status="pending")
    assert can_publish(pending, ALICE, is_admin=False) is False
    assert can_publish(pending, ADMIN, is_admin=True) is True
    assert can_publish(_agent(review_status="draft"), ADMIN, is_admin=True) is False


@pytest.mark.parametrize(
    ("current", "action", "expected"),
    [
        ("draft", "submit", "pending"),
        ("pending", "approve", "approved"),
        ("pending", "reject", "rejected"),
        ("rejected", "submit", "pending"),
        ("approved", "submit", "pending"),
    ],
)
def test_legal_review_transitions(current: str, action: str, expected: str) -> None:
    assert next_review_status(current, action) == expected


@pytest.mark.parametrize(
    ("current", "action"),
    [
        ("draft", "approve"),
        ("draft", "reject"),
        ("approved", "reject"),
        ("rejected", "approve"),
    ],
)
def test_illegal_review_transitions_raise(current: str, action: str) -> None:
    with pytest.raises(ValueError):
        next_review_status(current, action)


def test_unknown_states_are_rejected() -> None:
    with pytest.raises(ValueError):
        AgentView(agent_id="agt_bad", owner_id=ALICE, visibility="everyone")
    with pytest.raises(ValueError):
        AgentView(agent_id="agt_bad", owner_id=ALICE, review_status="published")
    with pytest.raises(ValueError):
        next_review_status("published", "submit")
