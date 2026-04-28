"""Run all Tout Wars scrapers end-to-end.

Usage: python run_all.py
"""

import standings
import team_stats


def main() -> None:
    print("=== Standings ===")
    standings.main()
    print("\n=== Team Stats ===")
    team_stats.main()
    print("\nDone.")


if __name__ == "__main__":
    main()
