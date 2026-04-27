# Tout Wars Onroto scrapers

Two Python scrapers that pull final standings and end-of-season rosters
for all three Tout Wars leagues (`toutal`, `toutnl`, `toutmixed`) from
[Onroto](https://onroto.fangraphs.com). Output goes to
`../standings/{year}-{league}.csv` and `../rosters/{year}-{league}.csv`.

The site accepts `session_id=guest` for all read pages — no credentials.

## Setup

```bash
cd data-raw/sources/tout-wars/scrape
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

Full scrape (45 league-years, ~1 minute):

```bash
python run_all.py
```

Single scraper:

```bash
python standings.py        # writes ../standings/*.csv
python rosters.py          # writes ../rosters/*.csv
```

## Tests

```bash
pytest tests/
```

Tests run the parsers against saved HTML fixtures in `tests/fixtures/` —
they don't hit the network.

## Year coverage

| League        | Years      |
|---------------|------------|
| `toutal` (AL) | 2010–2025  |
| `toutnl` (NL) | 2010–2025  |
| `toutmixed`   | 2013–2025  |
