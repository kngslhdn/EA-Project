# XAU APEX V9.1

## Why V9.1 exists

The latest V8.1 real-tick test did not provide a meaningful edge:

- Net profit: -154.41 on $5,000
- Profit Factor: 1.02
- Expected Payoff: 0.12
- 454 trades
- Win rate: 36.56%
- Max equity DD: 8.98%

The earlier V6 test was materially stronger:

- Net profit: +272.60 on $5,000
- Profit Factor: 1.10
- Expected Payoff: 0.97
- 281 trades
- Win rate: 38.43%
- Max equity DD: 5.94%

V9.1 therefore does **not** add another large collection of filters. It returns to the simpler V6-style trend/pullback core and changes only the parts that can plausibly improve robustness.

## Core design

1. H1 50/200 EMA regime.
2. H1 ADX + DI confirmation.
3. M15 20/50 EMA alignment.
4. M15 pullback/rejection entry.
5. M15 ADX and RSI location filter.
6. Session VWAP alignment, 07:00-22:00.
7. ATR-normalized stop and risk sizing.
8. Break-even at 1R.
9. Lock +0.5R at 1.5R.
10. ATR trail from 2R.
11. Time-stop for stagnant trades.
12. Daily loss, equity DD, trade-count, and consecutive-loss protection.

## Important difference from V8

The breakout engine is **removed from the V9.1 baseline**. The V8 report shows many breakout entries followed by rapid stop-outs. We will only reintroduce breakout logic after an isolated breakout-only test proves positive expectancy.

## Baseline inputs

- EntryTF: M15
- RegimeTF: H1
- Entry EMA: 20/50
- Regime EMA: 50/200
- ADX: 18 minimum
- Pullback touch: 0.15 ATR
- Pullback maximum distance: 0.35 ATR
- SL: 1.60 ATR
- Normal TP: 2.80R
- Strong TP: 3.60R
- Risk: 0.50%
- Session: 07:00-22:00
- Max trades/day: 5
- Max consecutive losses: 3

## Test protocol

Run XAUUSDm M15 using **Every tick based on real ticks**.

Primary comparison:

- V6 original
- V8.1
- V9.1

Do not optimize first. The first objective is to establish whether V9.1 improves out-of-sample expectancy rather than merely producing a prettier equity curve.

Required report metrics:

- Net Profit
- Profit Factor
- Expected Payoff
- Sharpe
- Max Equity DD
- Win rate
- Long vs Short
- Monthly result
- Entry hour
- MAE/MFE
- Consecutive losses

## Research basis

The architecture is deliberately centered on trend/momentum because long-run commodity-futures research provides substantially stronger evidence for trend following than for an arbitrary collection of short-term indicators. Intraday filters are used as execution/quality controls, not as claims of a guaranteed edge.

V9.1 is an experiment. It is not represented as guaranteed profitable and must be validated on real-tick out-of-sample data before live use.
