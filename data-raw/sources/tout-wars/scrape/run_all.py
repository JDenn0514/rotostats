"""Run both scrapers end-to-end.

Usage: python run_all.py
"""

import standings
import rosters


def main() -> None:
    print("=== Standings ===")
    standings.main()
    print("\n=== Rosters ===")
    rosters.main()
    print("\nDone.")


if __name__ == "__main__":
    main()
