# XAU APEX V4

V4 fixes the zero-trade design problem by simplifying the entry engine. It uses M15 EMA50/EMA200 regime plus either an EMA50 pullback/reclaim or a controlled previous-candle breakout. H1 and ADX filters are optional and disabled by default. V4 also adds diagnostic journal messages and a minimum-lot fallback so the risk engine cannot silently suppress every trade on small contract specifications.

Risk controls remain: 0.5% target equity risk, 2% daily closed-loss guard, 10% peak-equity drawdown guard, max 5 entries/day, consecutive-loss cooldown, spread and session protection. No grid, martingale, or averaging down.

The screenshot that motivated V4 showed a tester window around 2-3 January 2025 with zero trades. That is not enough data to judge profitability. First verify that V4 actually executes trades, then run a long real-tick test.

V1, V2 and V3 remain untouched.