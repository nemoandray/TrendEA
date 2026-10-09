# Technical Specification: Trend-Following Expert Advisor (EA) for MetaTrader 5

## 1. Goal
Write an MQL5 Expert Advisor that trades with the trend across multiple timeframes using strictly formalized rules. No discretionary logic: all conditions are calculated on closed bars. Initial instrument: EURUSD. All thresholds must be exposed as `input` parameters.

## 2. Timeframe Structure
| TF | Role |
|---|---|
| H1 | Higher-timeframe trend filter (direction) |
| M15 | Trading TF: setup (pullback within the trend) |
| M5 | Entry point (trigger) |

## 3. Indicators
- EMA 20, 50, 200 on Close (on H1, M15, M5).
- Stochastic (5,3,3), Low/High, SMA (on M15 and M5). Zones: oversold `< 30`, overbought `> 70` (parameters).
- ADX (14) with +DI and −DI (on H1 and M15).

All values must be taken at `shift = 1` (the last closed bar) to avoid repainting.

## 4. Signal Logic (Buy; Sell is the mirror image)

### 4.1 H1 Filter (trend)
All conditions simultaneously:
1. Close H1 > EMA200 H1.
2. EMA20 > EMA50 > EMA200 on H1.
3. EMA50 H1 slopes upward: `EMA50[1] > EMA50[1 + SlopeBars]` (default SlopeBars = 5).
4. ADX H1 > `ADX_H1_Min` (default 20) and +DI > −DI.

If the conditions are not met, trading in that direction is forbidden.

### 4.2 M15 Setup (pullback within the trend)
Conditions:
1. EMA20 > EMA50 > EMA200 on M15.
2. ADX M15 > `ADX_M15_Min` (default 18).
3. A pullback occurred: within the last `PullbackBars` (default 8) M15 bars, Low touched the zone between EMA20 and EMA50 (Low ≤ EMA20).
4. The pullback did not break the trend: no M15 Close during this period was below EMA50.
5. Stochastic M15 dropped below `Stoch_OS` (30) within the last `PullbackBars` bars.

The setup is considered active until its expiry `SetupExpiryBars` (default 8 M15 bars) or until conditions 1 and 4 are violated.

### 4.3 M5 Trigger (entry)
While the setup is active, enter at market on the open of the next M5 bar if, on the M5 bar that has just closed:
1. Stochastic M5 %K crossed %D from below, and the cross occurred below `Stoch_OS` (30) or on exit from that zone.
2. The candle is bullish (Close > Open).
3. Close M5 > EMA20 M5.

One setup produces no more than one entry.

## 5. Stop Loss and Exit
- **SL:** beyond the low (for Sell: the high) of the last `SwingBars` (default 10) M5 bars, plus a buffer `SL_BufferPips` (default 1.0 pip) plus the current spread.
- Stop size limits: `SL_MinPips` = 6, `SL_MaxPips` = 25. If the stop is outside this range, skip the trade and write the reason to the log.
- **TP:** fixed, `TP_R` = 2.0 (RR 1:2). TP = entry price ± 2 × distance to SL. Set immediately when the order is opened.
- **No** partial closing, **no** moving the stop to breakeven, **no** trailing stop. SL and TP do not move after opening.
- **Early exit on direction change:** the position is closed at market if, on bar close, any of the enabled conditions is met:
  1. `ExitOnH1Break` (default true): H1 Close crossed EMA50 H1 against the position, i.e., the H1 filter (section 4.1) for the position's direction no longer holds.
  2. `ExitOnOppositeSignal` (default true): a full signal in the opposite direction has appeared (the H1 filter, M15 setup, and M5 trigger from section 4 are all passed for the opposite direction).
  After closing on a signal, a new entry is allowed under the normal rules (sections 4, 6, 7). Write the reason for closing (TP, SL, direction change) to the log.

## 6. Risk Management
- Risk per trade: `RiskPercent` = 1.0% of balance. Calculate lot size from the distance to SL and the symbol's tick value, rounding down to the lot step.
- No more than 1 position per symbol at a time.
- Maximum `MaxTradesPerDay` = 4 trades per day.
- Daily loss limit `DailyLossLimit` = 3% of the balance at the start of the day: when reached, close everything and do not trade until the next day.
- After `MaxConsecLosses` = 3 consecutive losses, pause until the next day.
- Emergency switch: `input bool TradingEnabled`.

## 7. Filters
- **Spread:** do not open if spread > `MaxSpreadPips` (default 1.5).
- **Session:** trade only within the window `SessionStart`–`SessionEnd` (default 08:00–20:00 server time, a parameter that accounts for the broker's offset). Determine the offset automatically or set it via the `GMTOffset` input.
- **News:** do not open trades within `NewsBeforeMin` = 30 minutes before and `NewsAfterMin` = 30 minutes after high-impact events for USD and EUR (via the built-in MQL5 calendar: `CalendarValueHistory`). Do not close open positions automatically; only block new entries.
- **Friday:** do not open new trades after `FridayCutoff` (default 18:00).
- **Overheating:** do not enter if ADX H1 > `ADX_H1_Max` (default 50); this parameter can be disabled.

## 8. Technical Requirements
- A single `.mq5` file with a clean structure: functions `CheckH1Filter()`, `CheckM15Setup()`, `CheckM5Trigger()`, `CalcLot()`, `ManagePosition()`, `RiskGuard()`.
- New-bar detector for each TF; logic runs on closed bars only.
- Magic number as a parameter, order comment.
- `OrderSend` error handling: no more than 3 retries, parse the retcode, write to the log.
- Use `CTrade`; check `SymbolInfoDouble`, `SYMBOL_TRADE_STOPS_LEVEL`, `SYMBOL_VOLUME_STEP`.
- Detailed CSV log (`MQL5/Files`): time, TF, indicator values, which condition triggered or rejected the signal, lot, SL, TP, result.
- Draw entry and exit arrows on the chart for visual verification.
- Code comments; all thresholds in `input` with groups (`input group`).

## 9. Development Order (in stages, verify each separately)
1. **Stage 1.** Indicators and logger: the EA trades nothing, only writes to the log and draws arrows where signals fired. I will manually check on the chart that the signals match my understanding of the strategy.
2. **Stage 2.** Trading logic: entry, SL, fixed 1:2 TP, exit on direction change.
3. **Stage 3.** Risk management, daily limits, spread, session, and news filters.
4. **Stage 4.** Testing and report.

## 10. Testing
- MT5 Strategy Tester, "Every tick based on real ticks" mode, real spread, broker commission.
- Period: at least 3 years. Split it: optimize on the first part (e.g., 2023–2024), validate on the held-out part (2025–2026), with no re-fitting afterward.
- Optimize no more than 4–5 parameters within narrow ranges (`ADX_M15_Min`, `PullbackBars`, `SwingBars`); keep the rest fixed. Show a sensitivity map: the result must remain stable under small parameter changes.
- Report metrics: number of trades, Profit Factor, expectancy per trade in R, win rate, maximum drawdown, maximum losing streak, breakdown by year and by session.
- Acceptance criteria: at least 200 trades, PF > 1.3 on the held-out sample, drawdown < 15%, and the result does not depend on one or two large trades.
- Next: demo account for 1–2 months, compare with the tester, and only then live with the minimum lot.

## 11. What Not To Do
- Do not use martingale, averaging, grids, trailing, breakeven, partial closing, or moving or removing the stop.
- Do not use data from an unclosed bar.
- Do not add indicators or conditions beyond those described without approval.
- Do not optimize parameters over the entire history without a held-out sample.

## 12. Deliverables
1. An `.mq5` file with comments.
2. A default parameter set file `.set`.
3. A brief description: what each input does.
4. A test report (section 10) with an equity curve and conclusions on where the strategy performs poorly.
