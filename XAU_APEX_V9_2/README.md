# XAU APEX V9.2

## Objective
V9.2 is a structural correction to V9.1. It is designed to improve expectancy and reduce the failure mode seen in the V9.1 report rather than adding another large stack of indicators.

## Evidence driving V9.2
The V9.1 backtest showed a negative equity slope, PF 0.71 and a material loss concentration in 2026 BUY trades. The report also showed several trades surviving for multiple days before stopping out. V9.2 therefore changes the architecture in four areas:

1. **Asymmetric regime confirmation** — BUY requires stronger H1 trend confirmation than SELL because V9.1 BUY performance was materially weaker.
2. **Pullback-only entry** — breakout logic is intentionally excluded from this baseline.
3. **Session discipline** — default session is 08:00-17:00 and Friday is blocked. These defaults are based on the observed V9.1 time/weekday distribution and must be revalidated out-of-sample.
4. **Disciplined exits** — 1.6 ATR initial SL, 2.2R TP, BE at 1R, +0.5R lock at 1.5R, ATR trailing from 2R, a soft stagnation stop and a hard maximum trade age.

## Core logic

### H1 regime
- EMA 50 / EMA 200
- Fast EMA slope confirmation
- Slow EMA direction confirmation
- Close must be on the regime side of EMA 50
- ADX + DI confirmation
- BUY threshold: ADX >= 22 and separation >= 0.12 ATR
- SELL threshold: ADX >= 18 and separation >= 0.08 ATR

### M15 entry
- EMA 20 / EMA 50 alignment
- EMA 20 slope
- ADX >= 18
- Closed candle rejection/pullback into EMA 20
- Candle body and close-location quality
- Maximum chase distance
- Session VWAP alignment

### Exit
- Initial SL = 1.60 ATR
- TP = 2.20R
- BE = 1.00R with +0.05R offset
- Lock = +0.50R at 1.50R
- ATR trail = 1.50 ATR from 2.00R
- Soft time stop = 16 M15 bars if R < 0.10
- Hard maximum age = 24 M15 bars

### Risk
- Risk per trade = 0.50%
- Daily loss stop = 2%
- Equity drawdown stop = 10%
- Maximum 4 entries/day
- Maximum 3 consecutive losses
- 45-minute loss cooldown
- One position at a time

## Important
V9.2 is **not claimed to be guaranteed profitable**. The purpose of this version is to test whether the structural corrections improve expectancy. Do not optimize parameters until a clean real-tick baseline has been completed.

## Required validation
Run the same XAUUSDm M15 real-tick period used for V9.1 and compare:

- Net Profit
- Profit Factor
- Expected Payoff
- Sharpe
- Max Equity DD
- Win rate
- BUY vs SELL
- Monthly P/L
- Hourly P/L
- MFE / MAE
- Average R
- Maximum trade duration
- Consecutive losses

Then run an untouched out-of-sample period. A profitable in-sample result alone is not sufficient for promotion to live trading.
