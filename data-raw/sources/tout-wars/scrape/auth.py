"""Onroto guest-session helper for Tout Wars scrapers.

Onroto accepts session_id=guest for all read-only pages — no login required.
"""

import requests

BASE_URL = "https://onroto.fangraphs.com"
GUEST_SESSION_ID = "guest"


def guest_session() -> tuple[requests.Session, str]:
    """Return a fresh requests.Session and the guest session id.

    The session has a UA header set so we don't look like a default
    python-requests user agent.
    """
    session = requests.Session()
    session.headers.update(
        {"User-Agent": "rotostats-tout-scraper/0.1 (+https://github.com/jdennen/rotostats)"}
    )
    return session, GUEST_SESSION_ID
