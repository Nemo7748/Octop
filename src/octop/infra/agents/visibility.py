"""Visibility and review-state rules for published agents.

An agent belongs to one user and is private to that user until an administrator publishes it.
These functions are pure so both the HTTP routers and the repository layer can share one truth
table, and so the rules can be tested without a database or a running server.

`shared` is modelled as a per-user whitelist. If the platform later adopts department or role
scopes, replace the ``shared_user_ids`` argument and keep the same return values.
"""

from __future__ import annotations

from dataclasses import dataclass, field

VISIBILITIES: tuple[str, ...] = ("private", "shared", "public")
REVIEW_STATES: tuple[str, ...] = ("draft", "pending", "approved", "rejected")

#: Illegal transitions raise; `approved --submit--> pending` sends an edited published agent back
#: through review instead of letting the edit go live unreviewed.
_NEXT_REVIEW_STATE: dict[tuple[str, str], str] = {
    ("draft", "submit"): "pending",
    ("pending", "approve"): "approved",
    ("pending", "reject"): "rejected",
    ("rejected", "submit"): "pending",
    ("approved", "submit"): "pending",
}


@dataclass(frozen=True)
class AgentView:
    """The subset of an `agents` row that the visibility rules read."""

    agent_id: str
    owner_id: int | None
    visibility: str = "private"
    review_status: str = "draft"
    enabled: bool = True
    shared_user_ids: frozenset[int] = field(default_factory=frozenset)

    def __post_init__(self) -> None:
        if self.visibility not in VISIBILITIES:
            raise ValueError(f"invalid visibility: {self.visibility!r}")
        if self.review_status not in REVIEW_STATES:
            raise ValueError(f"invalid review_status: {self.review_status!r}")


def is_owner(agent: AgentView, viewer_id: int) -> bool:
    """Return whether `viewer_id` created the agent."""
    return agent.owner_id is not None and agent.owner_id == viewer_id


def is_visible_to(
    agent: AgentView,
    viewer_id: int,
    shared_user_ids: frozenset[int] = frozenset(),
) -> bool:
    """Return whether `viewer_id` may open, chat with, or inspect the agent.

    The owner always sees their own agent in any state. Everyone else needs an approved agent that
    is either public or shared with them.
    """
    if is_owner(agent, viewer_id):
        return True
    if agent.review_status != "approved":
        return False
    if agent.visibility == "public":
        return True
    if agent.visibility == "shared":
        return viewer_id in shared_user_ids
    return False


def is_published_to(
    agent: AgentView,
    viewer_id: int,
    shared_user_ids: frozenset[int] = frozenset(),
) -> bool:
    """Return whether the agent belongs in the workbench catalog of `viewer_id`.

    Disabled agents never appear. The author's own agents are excluded because they are already
    listed under "mine"; listing them twice makes both lists unreliable.
    """
    if not agent.enabled:
        return False
    if agent.review_status != "approved":
        return False
    if is_owner(agent, viewer_id):
        return False
    if agent.visibility == "public":
        return True
    if agent.visibility == "shared":
        return viewer_id in shared_user_ids
    return False


def can_manage(agent: AgentView, viewer_id: int, is_admin: bool) -> bool:
    """Return whether `viewer_id` may change visibility or review state."""
    return is_admin or is_owner(agent, viewer_id)


def can_publish(agent: AgentView, viewer_id: int, is_admin: bool) -> bool:
    """Return whether `viewer_id` may approve the agent.

    Only an administrator publishes, and only from the pending state, so an agent cannot skip
    review by being edited straight into `approved`.
    """
    return is_admin and agent.review_status == "pending"


def next_review_status(current: str, action: str) -> str:
    """Return the review state after `action`, or raise for an illegal transition."""
    if current not in REVIEW_STATES:
        raise ValueError(f"invalid review_status: {current!r}")
    try:
        return _NEXT_REVIEW_STATE[(current, action)]
    except KeyError:
        raise ValueError(f"illegal transition: {current} --{action}-->") from None
