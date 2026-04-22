# Plan: Novel Rotisserie Valuation Methods Beyond PVM / SGP / Z-Score

> **Goal:** Catalog thirteen candidate valuation methods that break the shared assumption
> stack underlying PVM, SGP, and z-score. For each, specify the conceptual framework, the
> statistical method, and the data requirements (projections only vs. historical league
> data vs. live roster state). This is an ideation plan — it precedes implementation,
> benchmarking against the autoresearch valuation harness, and eventual integration into
> `rotostats`.

---

## Background: What the Three Canonical Methods Share

**PVM** (Percentage Valuation Method), **SGP** (Standings Gain Points), and **z-score**
all translate projected stats into a scalar dollar value via the same three-step recipe:

1. Pick a reference baseline (replacement-level player, historical standings spacing,
   pool mean/σ).
2. Measure each player's production relative to that baseline.
3. Normalize so totals match the league budget.

They differ in the cross-category unit (% of category dollars, standings points, σ), but
they agree on six deeper assumptions — the **shared assumption stack**:

1. **Linearity** — value is additive across categories; each marginal HR equals the last.
2. **Rule 5 equivalence** — within a category, every unit counts equally.
3. **Average opponent** — baselines are static; opponents' rosters don't enter.
4. **Deterministic projections** — mean is priced; variance is ignored or bolted on.
5. **Context-free scalar output** — one number per player, independent of roster.
6. **Expected-value objective** — maximize E[standings], not finish distribution.

Empirical benchmark (BaseballHQ 10k simulated 15-team NFBC drafts, 2016):
**z-score > SGP > PVM** on final points (85.6 / 77.9 / 76.5), driven almost entirely by
z-score's category balance rather than dominance in any one stat.

Every method below violates at least one assumption in the stack.

---

## Data-Requirement Tiers

Three tiers govern when each method is usable:

- **Tier A — Projections only.** Works in any league, pre-draft, no history, no
  keepers, no opponent data. Drop-in replacement for PVM / z-score.
- **Tier B — Projections + notional league parameters.** Needs league size, roster
  slots, and prize/budget structure, but no historical standings or specific rosters.
- **Tier C — Draft-state / roster-dependent.** Requires your current roster, opponents'
  rosters, or historical league standings to deliver its intended edge.

---

# Tier A — Projections Only

These five methods are the closest analogues to PVM / z-score: they take a projection
table in, emit a per-player value out, and require no league history or roster state.

## 1. Kelly / Log-Utility Valuation

**Conceptual framework.** Replace the expected-points objective with expected
log-points. Log utility approaches −∞ as a category total approaches zero, so the
objective *endogenously* enforces category balance — you cannot afford to zero any
category. This gives z-score's best empirical property (balance) as a mathematical
consequence of the objective rather than a coincidence of summing standardized units.

**Statistical method.** Given projection distributions for each player's category
contributions, define a notional roster's total in each category as
*T<sub>c</sub> = Σ x<sub>i,c</sub>*. Player *i*'s value is the marginal contribution to
*E[Σ<sub>c</sub> log(T<sub>c</sub>)]* over random draws from the projection
distribution, evaluated at a notional balanced roster.

**Data requirements.** Projections with uncertainty (point projections alone can be
used with an assumed σ).

**Breaks:** linearity (log is concave), expected-value objective.

## 2. Copeland / Pairwise-Dominance Valuation

**Conceptual framework.** Treat valuation as a round-robin tournament among draftable
players. For every pair *(i, j)*, count categories where *i* beats *j*. Value is the
Copeland score — total pairwise wins, optionally weighted by margin. Fundamentally
ordinal: no σ, no standardization, no distributional assumptions. Immune to the
skewed-category pathology that inflates z-score on SB specialists with 50+ SB outliers.

**Statistical method.** Let *w<sub>ij</sub>* = #{*c* : *x<sub>i,c</sub>* > *x<sub>j,c</sub>*}.
Copeland score *C<sub>i</sub>* = *Σ<sub>j ≠ i</sub>* **1**[*w<sub>ij</sub>* > *K*/2],
where *K* is the number of categories. Weighted variant: replace the indicator with
*w<sub>ij</sub>* − *w<sub>ji</sub>*. Convert to dollars by proportional allocation
against the budget.

**Data requirements.** Projections only.

**Breaks:** linearity, Rule 5 equivalence implicitly (category scales no longer need to
be commensurable).

## 3. Pareto-Frontier / Dominance-Depth Valuation

**Conceptual framework.** A player is either on the Pareto frontier (no other player
strictly dominates them across all categories) or below it. Peel the frontier
iteratively: rank 1 = initial frontier, rank 2 = frontier after removing rank 1, etc.
Value is dominance depth, with distance-to-next-frontier as tiebreaker. Rewards *unique
category profiles*: a balanced player and an SB specialist can both sit on rank 1 for
different reasons, while a strictly-worse version of either is buried.

**Statistical method.** Iterative non-dominated sorting (NSGA-II-style). Depth
*d<sub>i</sub>* gives coarse rank; within each frontier, rank by minimum Euclidean
distance (on standardized stats) to the next-deeper frontier. Convert depth-adjusted
scores to dollars.

**Data requirements.** Projections only.

**Breaks:** linearity, Rule 5 equivalence, commensurability between categories.

## 4. PCA / Factor Valuation

**Conceptual framework.** Run PCA on the standardized projection matrix
(*players × categories*). Leading components tend to recover latent talent axes —
overall offense, power-vs-speed, contact-vs-strikeout, SV-concentration. Player value
is a weighted sum of factor scores, with factor weights reflecting explained variance
or a simulator-derived standings impact. Exposes *why* a player has value rather than
collapsing everything into one scalar.

**Statistical method.** SVD of the standardized *n × K* projection matrix. For each
player, compute component scores *ξ<sub>i,k</sub>*. Value is
*V<sub>i</sub> = Σ<sub>k</sub> w<sub>k</sub> ξ<sub>i,k</sub>*. Weights *w<sub>k</sub>*
can be λ<sub>k</sub> (explained variance), learned from a simulator, or set by prior.

**Data requirements.** Projections only. Factor weights optionally informed by a
simulator (still projection-only, just expensive to compute).

**Breaks:** Rule 5 equivalence (factors re-weight categories), independence assumption
(PCA decorrelates).

## 5. Copula-Adjusted Valuation

**Conceptual framework.** Z-score implicitly assumes category contributions are
independent. They aren't — HR / R / RBI are strongly positively correlated within a
player, so summing independent z-scores over-credits power hitters and under-credits
contact + speed players. Fit a joint distribution via a copula to account for this and
price each player's contribution to the *joint* distribution rather than the marginals.

**Statistical method.** Fit marginal CDFs *F<sub>c</sub>* per category across the pool.
Transform projections to copula space *u<sub>i,c</sub>* = *F<sub>c</sub>(x<sub>i,c</sub>)*.
Fit a Gaussian or Student-*t* copula on *(u<sub>i,1</sub>, …, u<sub>i,K</sub>)*. Player
value is the log-likelihood gain over a notional roster, evaluated against an
independence baseline.

**Data requirements.** Projections only (copula is fit within the current projection
pool).

**Breaks:** independence of categories (decorrelates), Rule 5 equivalence.

## 6. Category-Rarity Weighted Valuation

**Conceptual framework.** Categories differ in scarcity. SB and SV production is
concentrated in 20–30 players; R and K production is diffuse across hundreds. Existing
methods weight all categories equally per budget-share. Weight categories instead by a
rarity metric derived *from the projection pool itself* — Gini coefficient or Shannon
entropy of the production distribution. One SB unit prices higher than one R unit
because SB supply is concentrated.

**Statistical method.** For each category *c*, compute a concentration measure
*ρ<sub>c</sub>* — Gini(*x<sub>·,c</sub>*) or *H(x<sub>·,c</sub>)*. Set category weights
*w<sub>c</sub> ∝ ρ<sub>c</sub>* (rarer → higher weight). Value = weighted z-score (or
weighted PVM share).

**Data requirements.** Projections only. Weights update endogenously when the projection
environment shifts (e.g., low-SB MLB era → higher SB weight automatically).

**Breaks:** within-category equivalence of effort (still preserves Rule 5 *within* a
category); breaks the equal-budget-share convention *across* categories.

---

# Tier B — Projections + Notional League Parameters

These three price variance or distribution-of-finish and need league size / roster
slots / prize structure, but no historical standings or specific rosters.

## 7. Portfolio (Mean-Variance) Valuation

**Conceptual framework.** Treat players as assets with expected return *μ<sub>i</sub>*
(standings points added vs. replacement) and covariance Σ driven by shared exposures:
park effects, lineup dependencies, bullpen workload correlates, injury risk. Solve
Markowitz for the efficient frontier; player value is the marginal contribution to the
Sharpe-optimal portfolio at the chosen risk tolerance.

Two Dodgers with identical projections are worth less jointly than a Dodger + a
Guardian: the first pair's R/RBI outcomes are correlated. PVM/SGP/z-score cannot see
this.

**Statistical method.** Estimate μ from projections. Estimate Σ either from (a)
prior-season residuals (projection minus actual) by player, (b) exposure loadings on
park / team / league factors, or (c) sampling from projection distributions if
available. Solve
*max<sub>w</sub>* (*μ<sup>T</sup> w − γ w<sup>T</sup> Σ w*) subject to roster
constraints. Player value = ∂(objective)/∂*w<sub>i</sub>* at the optimum.

**Data requirements.** Projections + notional league (slots, budget, risk tolerance γ).
Covariance structure can be estimated from a single prior season of actuals-vs-projections
— no league-specific history required, just MLB-level data.

**Breaks:** deterministic-projection assumption, independence across players.

## 8. Options-Pricing Volatility Valuation

**Conceptual framework.** A player with high projection variance has *optionality*: the
upside tail lifts the roster, and the downside is bounded because waiver-wire
replacements exist. Price each player as intrinsic value (expected production above
replacement) + volatility premium (upside above replaceability threshold, weighted by
breakout probability). Formalizes the "ceiling plays" heuristic for late-round picks and
$1 endgame bids.

**Statistical method.** Let *R* be replacement-level production. Intrinsic value
*I<sub>i</sub>* = max(*μ<sub>i</sub>* − *R*, 0). Volatility premium
*O<sub>i</sub>* = *E*[max(*x<sub>i</sub>* − *R*, 0)] − *I<sub>i</sub>*, computed from
the projection distribution. Total value *V<sub>i</sub>* = *I<sub>i</sub>* + *λO<sub>i</sub>*
where *λ* reflects the cost of in-season replacement (lower *λ* in deep leagues with
thin waivers).

**Data requirements.** Projections with uncertainty + notional league (replacement
level and waiver-depth parameter).

**Breaks:** variance-as-liability assumption, expected-value objective.

## 9. Finish-Distribution (Prize-Weighted) Valuation

**Conceptual framework.** Most leagues pay only top 1–3. Optimal strategy maximizes
*prize-weighted* finish probability, not expected points. High-variance rosters have
better top-3 probability at the same mean. Formally values ceiling over floor below the
money line — a different objective function, not a different estimator.

**Statistical method.** For each player *i*,
*V<sub>i</sub>* = *Σ<sub>r=1</sub><sup>R</sup>* *w<sub>r</sub>* [*P*(finish = *r* |
roster ∋ *i*) − *P*(finish = *r* | roster ∋ replacement)], where *w<sub>r</sub>* is the
prize payout at rank *r*. Probabilities come from Monte Carlo season simulation using
projection distributions, run against a notional 11-opponent field.

**Data requirements.** Projections with uncertainty + notional league (size, prize
structure, opponent model for the simulated field). Opponent model can be as simple as
"everyone drafts by z-score from the same projections."

**Breaks:** expected-value objective, variance-as-liability.

---

# Tier C — Draft-State or Historical League Data Required

These four need your current roster, opponents' rosters, or multi-year league history.
They are the most powerful but only work in specific contexts — keepers, second-year+
leagues, or during an active draft.

## 10. Monte Carlo Standings-Finish Valuation (MCSFV)

**Conceptual framework.** Simulate the full season *N* ≈ 10k times using projection
distributions. For each candidate player, compute *E*[final standings points] with them
on *your actual projected roster* vs. replacement. Captures diminishing returns
(the 40th HR on a power-heavy team is worth less), category stacking, and roster
interactions natively — all invisible to SGP's fixed-denominator assumption.

**Statistical method.** For your roster *R* and each candidate *i*:
1. Simulate 10k season outcomes for *R* ∪ {*i*} and for *R* ∪ {replacement}.
2. In each simulation, score category standings against a notional 11-opponent field
   drawn from the same projection pool.
3. Value *V<sub>i</sub>* = *E*[points | *i*] − *E*[points | replacement].

**Data requirements.** Projections with uncertainty + **your current / projected
roster** + notional opponent model. Context-free variant: run against a generic
"average drafter" roster, but loses most of the edge.

**Breaks:** linearity, context-free output.

## 11. Shapley-Value Roster Contribution

**Conceptual framework.** From cooperative game theory. A player's value is their
average marginal contribution to standings points across all possible coalitions of
roster-mates. The same player has different Shapley values on different rosters: a pure
SB specialist is worth more to a HR-heavy team stuck last in SB than to a balanced one.

**Statistical method.**
*φ<sub>i</sub>* = *Σ<sub>S ⊆ N \ {i}</sub>* [|*S*|!(*n* − |*S*| − 1)! / *n*!] ·
[*v*(*S* ∪ {*i*}) − *v*(*S*)], where *v* is a standings-points function. Exact
computation is intractable; use MC sampling over coalitions, with roster constraints
enforced during sampling.

**Data requirements.** Projections + **current / projected roster** to define the
coalition space of interest. Can be computed against a generic roster but loses
context-sensitivity.

**Breaks:** linearity, context-free output, Rule 5 equivalence.

## 12. Nash-Equilibrium Draft Valuation

**Conceptual framework.** Standard values assume opponents draft with canonical
(NFBC-derived) baselines. But if your league systematically undervalues catchers, the
market-clearing price collapses and the player who grabs tier-1 C at discount gains the
largest edge. Solve for a Nash equilibrium over draft strategies given the league's
known tendencies; player value is the equilibrium shadow price.

**Statistical method.** Fit a Bayesian model of each opponent's category preferences
and position-tier biases from prior draft records. Best-respond iteratively until draft
prices converge to equilibrium. Player value at equilibrium is the marginal auction
price at which they clear.

**Data requirements.** Projections + **multi-year history of this specific league's
drafts** (auction results, roster compositions, category emphases). Does not
generalize — must be refit per league.

**Breaks:** average-opponent assumption.

## 13. Q-Function / Self-Play RL Valuation

**Conceptual framework.** Train an RL agent via self-play on simulated drafts. The
learned Q-function *Q*(*s*, *a*) — expected reward (final standings) given drafting
player *a* in draft state *s* — *is* the valuation. Not a single dollar figure but a
function of (player, pick number, available pool, your roster, opponents' rosters).
Conceptually closest to how strong human drafters actually think.

**Statistical method.** Deep RL (policy gradient or DQN) over an auction-draft
simulator. Reward = simulated final standings points. State encoder handles variable
roster sizes via set-embedding (DeepSets or transformer over roster). Training is
expensive; inference is cheap. Pre-draft values are recovered by evaluating
*Q*(*s*<sub>0</sub>, *a*) at the empty-roster state — so once trained, the agent
produces a *context-free* pre-draft value table in addition to live pick
recommendations.

**Data requirements.** Projections only at *inference* time, but training requires a
simulator (which itself needs a notional league). No historical league data strictly
required if the opponent model is self-play; optional fine-tuning on real league
histories improves deployment accuracy.

**Breaks:** all six shared-stack assumptions (at training time), none at inference for
pre-draft values.

---

# Summary Table

| # | Method | Tier | Breaks (from shared stack) | Core statistical tool |
|---|---|---|---|---|
| 1 | Kelly / Log-Utility | A | Linearity, EV objective | Log-utility maximization over projection distributions |
| 2 | Copeland | A | Linearity, commensurability | Pairwise-dominance round-robin |
| 3 | Pareto-Frontier | A | Linearity, commensurability | Non-dominated sorting |
| 4 | PCA / Factor | A | Rule 5, independence | Singular value decomposition |
| 5 | Copula-Adjusted | A | Independence, Rule 5 | Gaussian / *t*-copula fitting |
| 6 | Rarity-Weighted | A | Equal category weighting | Gini / entropy on pool |
| 7 | Portfolio | B | Determinism, independence | Markowitz mean-variance |
| 8 | Options-Pricing | B | Variance-as-liability, EV | Option-value decomposition |
| 9 | Finish-Distribution | B | EV objective | Monte Carlo with prize weights |
| 10 | MCSFV | C | Linearity, context-free | Monte Carlo season simulation |
| 11 | Shapley | C | Linearity, context-free | Coalitional game theory |
| 12 | Nash Equilibrium | C | Average-opponent | Best-response iteration |
| 13 | Q-Function RL | C (A at inference) | All six | Deep RL self-play |

---

# Recommended Build Order

1. **#6 Rarity-Weighted** — smallest delta from existing z-score code; likely
   addresses the SB/SV under-valuation shown in the BaseballHQ simulations.
2. **#1 Kelly / Log-Utility** — gives the balance property of z-score *by design*.
3. **#9 Finish-Distribution** — changes the objective to match how Moonlight Graham
   (and most leagues) actually pay prizes; composes naturally with the existing
   autoresearch harness.
4. **#2 Copeland** — trivially easy to implement; serves as a distribution-free
   sanity check against the parametric methods.
5. **#7 Portfolio** — requires fitting a covariance structure but is a principled
   answer to "why are two same-team stars worth less than one star on each of two
   teams?"
6. **#10 MCSFV** — most powerful deployed method; build last, once the simulator
   infrastructure exists for #9.

Methods 11–13 are research-grade and should be benchmarked against the top-4 build
order before investing in implementation.

---

# Integration Notes

- All Tier A methods can be evaluated by the existing autoresearch valuation harness
  (see `autoresearch-valuation.md`) using per-player earned-$ MAE and Spearman ρ as
  the primary metrics. They are drop-in replacements for PVM / z-score in the grid.
- Tier B methods require extending the harness with a season simulator; the
  Podhorzer team-total-vs-standings cross-check (already secondary in the existing
  plan) becomes more natural here.
- Tier C methods need draft-state instrumentation that does not currently exist in
  `rotostats` and should be scoped as a separate infrastructure plan.
