//+------------------------------------------------------------------+
//|                                                      TrendEA.mq5 |
//|  Trend-following EA: H1 trend filter / M15 pullback setup /      |
//|  M5 stochastic trigger. Implements TZ_trend_EA_EN.md (stages 1-3)|
//+------------------------------------------------------------------+
#property copyright "TrendEA"
#property version   "1.00"
#property description "H1 filter + M15 setup + M5 trigger. Closed bars only (shift = 1)."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ASSUMPTIONS (where the specification is ambiguous)               |
//|  1. "Full opposite signal" (exit) = H1 filter + M15 setup + M5   |
//|     trigger only. Spread/session/news/risk filters are NOT part  |
//|     of it.                                                       |
//|  2. ExitOnH1Break = the H1 filter (4.1) of the position's        |
//|     direction no longer holds (the "i.e." formal definition).    |
//|  3. M15 stochastic = %K line.                                    |
//|  4. Pullback (Buy): Low <= EMA20 on any of the last PullbackBars |
//|     closed M15 bars (Sell: High >= EMA20).                       |
//|  5. M5 cross (Buy): K[2]<=D[2] && K[1]>D[1] and (K[1]<OS or     |
//|     K[2]<OS). Sell is the mirror image with OB.                  |
//|  6. A setup starts when M15 conditions 1-5 become true; it ends |
//|     on expiry, on violation of conditions 1/4, or after an entry.|
//|     A new setup of the same direction needs conditions 1-5 to    |
//|     become false at least once first (one setup = one entry).    |
//|  7. Session/Friday times are in "reference time"; server time =  |
//|     reference time + GMTOffset hours. GMTOffset=0 -> server time.|
//|  8. Daily loss limit uses equity vs balance at start of the      |
//|     server day. Pauses last until the next server day.           |
//|  9. TradingEnabled=false blocks new entries only; an open        |
//|     position is still managed (exits, SL/TP).                    |
//| 10. 1 pip = 10 points on 3/5-digit symbols, else 1 point.        |
//| 11. M5 EMA50/EMA200 are not used by any rule -> not created.     |
//| 12. If the MQL5 calendar is unavailable the news filter does not |
//|     block (one warning is printed).                              |
//| 13. SignalOnly=true keeps a VIRTUAL position (SL/TP/exit rules   |
//|     are simulated on ticks) so exit arrows and risk counters     |
//|     work without sending orders.                                 |
//+------------------------------------------------------------------+

//--- direction constants
#define DIR_BUY   1
#define DIR_SELL -1

//--- setup state machine
enum ENUM_SETUP_STATE
{
   SETUP_IDLE     = 0,   // waiting for conditions 1-5
   SETUP_ACTIVE   = 1,   // setup is valid
   SETUP_COOLDOWN = 2    // ended; waiting for conditions to clear
};

//--- non-tunable technical constants
const int    SECONDS_PER_DAY   = 86400;
const int    SECONDS_PER_HOUR  = 3600;
const int    SECONDS_PER_MIN   = 60;
const int    MINUTES_PER_HOUR  = 60;
const int    PIP_POINT_FACTOR  = 10;
const int    FRIDAY_DOW        = 5;
const double EPS               = 1e-8;
const string ARROW_PREFIX      = "TrendEA_";
const int    MAX_FINALIZE_TRIES= 100;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input bool   TradingEnabled  = true;     // Emergency switch (false = no new entries)
input bool   SignalOnly      = false;    // true = log + arrows only, no orders
input long   MagicNumber     = 240901;   // Magic number
input string OrderComment    = "TrendEA";// Order comment
input ulong  DeviationPoints = 20;       // Max slippage, points
input int    MaxOrderRetries = 3;        // Retries after a failed order (max)
input int    RetryDelayMs    = 300;      // Delay between retries, ms

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES TF_Trend   = PERIOD_H1;   // Trend filter TF
input ENUM_TIMEFRAMES TF_Setup   = PERIOD_M15;  // Setup TF
input ENUM_TIMEFRAMES TF_Trigger = PERIOD_M5;   // Trigger TF

input group "=== Indicators ==="
input int    EMA_Fast        = 20;       // EMA fast period
input int    EMA_Mid         = 50;       // EMA mid period
input int    EMA_Slow        = 200;      // EMA slow period
input int    Stoch_K         = 5;        // Stochastic %K period
input int    Stoch_D         = 3;        // Stochastic %D period
input int    Stoch_Slowing   = 3;        // Stochastic slowing
input int    ADX_Period      = 14;       // ADX period
input double Stoch_OS        = 30.0;     // Stochastic oversold level
input double Stoch_OB        = 70.0;     // Stochastic overbought level

input group "=== H1 trend filter (4.1) ==="
input int    SlopeBars       = 5;        // EMA50 slope lookback (bars)
input double ADX_H1_Min      = 20.0;     // Min ADX on H1

input group "=== M15 setup (4.2) ==="
input double ADX_M15_Min     = 18.0;     // Min ADX on M15
input int    PullbackBars    = 8;        // Pullback window (M15 bars)
input int    SetupExpiryBars = 8;        // Setup lifetime (M15 bars)

input group "=== Stop Loss / Take Profit (5) ==="
input int    SwingBars       = 10;       // Swing lookback for SL (M5 bars)
input double SL_BufferPips   = 1.0;      // SL buffer, pips
input double SL_MinPips      = 6.0;      // Min stop size, pips
input double SL_MaxPips      = 25.0;     // Max stop size, pips
input double TP_R            = 2.0;      // TP in R multiples

input group "=== Early exit (5) ==="
input bool   ExitOnH1Break        = true;  // Exit when H1 filter fails
input bool   ExitOnOppositeSignal = true;  // Exit on full opposite signal

input group "=== Risk management (6) ==="
input double RiskPercent     = 1.0;      // Risk per trade, % of balance
input int    MaxTradesPerDay = 4;        // Max trades per day
input double DailyLossLimit  = 3.0;      // Daily loss limit, % of day-start balance
input int    MaxConsecLosses = 3;        // Pause after N consecutive losses

input group "=== Filters (7) ==="
input double MaxSpreadPips   = 1.5;      // Max spread, pips
input string SessionStart    = "08:00";  // Session start (HH:MM, reference time)
input string SessionEnd      = "20:00";  // Session end (HH:MM, reference time)
input int    GMTOffset       = 0;        // Server time = reference time + this (hours)
input string FridayCutoff    = "18:00";  // No new trades on Friday after (HH:MM)
input bool   NewsFilterEnabled = true;   // Enable news filter (MQL5 calendar)
input int    NewsBeforeMin   = 30;       // Minutes before high-impact news
input int    NewsAfterMin    = 30;       // Minutes after high-impact news
input string NewsCurrency1   = "USD";    // News currency 1
input string NewsCurrency2   = "EUR";    // News currency 2
input bool   ADX_H1_MaxEnabled = true;   // Enable overheating filter
input double ADX_H1_Max      = 50.0;     // Max ADX on H1 for entry

input group "=== Logging / drawing (8) ==="
input bool   LogEnabled      = true;     // Write CSV log
input bool   LogVerbose      = false;    // Log every evaluation (large file)
input bool   LogInCommonFolder = false;  // Put CSV in the common Files folder
input bool   DrawArrows      = true;     // Draw entry/exit arrows

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade   g_trade;

//--- indicator handles
int hTrEma20 = INVALID_HANDLE, hTrEma50 = INVALID_HANDLE, hTrEma200 = INVALID_HANDLE, hTrAdx = INVALID_HANDLE;
int hSeEma20 = INVALID_HANDLE, hSeEma50 = INVALID_HANDLE, hSeEma200 = INVALID_HANDLE, hSeAdx = INVALID_HANDLE;
int hSeStoch = INVALID_HANDLE;
int hTgEma20 = INVALID_HANDLE, hTgStoch = INVALID_HANDLE;

//--- symbol constants
double g_point = 0.0, g_pip = 0.0, g_tickSize = 0.0;

//--- parsed time inputs (minutes since midnight)
int g_sessStartMin = 0, g_sessEndMin = 0, g_fridayCutMin = 0;

//--- new-bar detectors
datetime g_lastBarTrend = 0, g_lastBarSetup = 0, g_lastBarTrig = 0;

//--- indicator snapshot (all values at shift = 1 unless noted)
struct SSnap
{
   bool   valid;
   double h1Close, h1E20, h1E50, h1E200, h1E50Old, h1Adx, h1Pdi, h1Mdi;
   double m15E20, m15E50, m15E200, m15Adx, m15K;
   double m5K, m5D, m5KPrev, m5DPrev, m5Close, m5Open, m5E20;
};
SSnap g_s;

//--- setup state per direction (index 0 = Buy, 1 = Sell)
int      g_setupState[2];
datetime g_setupTime[2];

//--- per-bar evaluation results (index 0 = Buy, 1 = Sell)
bool g_h1ok[2];
bool g_sig[2];

//--- current trade (real or virtual)
bool     g_open = false;
bool     g_virt = false;
ulong    g_ticket = 0;
long     g_posId = 0;
int      g_dir = 0;
double   g_entry = 0.0, g_sl = 0.0, g_tp = 0.0, g_lot = 0.0, g_dist = 0.0, g_riskMoney = 0.0;
datetime g_openTime = 0;
string   g_closeReason = "";
int      g_finalizeTries = 0;
datetime g_lastCloseTry = 0;

//--- risk counters
datetime g_day = 0;
double   g_dayStartBal = 0.0;
int      g_tradesToday = 0;
bool     g_dailyLossHit = false;
int      g_consecLosses = 0;
bool     g_consecPause = false;
double   g_virtPnL = 0.0;          // realized virtual P/L (SignalOnly)

//--- misc
int  g_logHandle = INVALID_HANDLE;
bool g_newsWarned = false;
int  g_arrowSeq = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
int DirIdx(const int dir) { return (dir > 0) ? 0 : 1; }

string DirStr(const int dir)
{
   if(dir > 0) return "BUY";
   if(dir < 0) return "SELL";
   return "-";
}

string Fmt(const double v, const int digits = 5) { return DoubleToString(v, digits); }

datetime DayStart(const datetime t) { return t - (t % SECONDS_PER_DAY); }

// "HH:MM" -> minutes since midnight, -1 on error
int ParseHHMM(const string s)
{
   int p = StringFind(s, ":");
   if(p < 1) return -1;
   int h = (int)StringToInteger(StringSubstr(s, 0, p));
   int m = (int)StringToInteger(StringSubstr(s, p + 1));
   if(h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * MINUTES_PER_HOUR + m;
}

// Round a price to the symbol tick size
double RoundTick(const double price)
{
   return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, _Digits);
}

// Read one indicator buffer value
bool Rd(const int handle, const int buf, const int shift, double &out)
{
   double a[];
   if(CopyBuffer(handle, buf, shift, 1, a) != 1) return false;
   out = a[0];
   return true;
}

// New-bar detector for a timeframe
bool IsNewBar(const ENUM_TIMEFRAMES tf, datetime &last)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t == 0) return false;
   if(t != last) { last = t; return true; }
   return false;
}

bool IsSuccessRetcode(const uint rc)
{
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
}

bool IsRetriableRetcode(const uint rc)
{
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT ||
           rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TOO_MANY_REQUESTS);
}

//+------------------------------------------------------------------+
//| CSV logger                                                       |
//+------------------------------------------------------------------+
string LogFileName()
{
   return "TrendEA_" + _Symbol + "_" + IntegerToString(MagicNumber) + ".csv";
}

void LogOpen()
{
   if(!LogEnabled) return;
   int common = LogInCommonFolder ? FILE_COMMON : 0;
   // in the tester every run starts with a clean file
   if(MQLInfoInteger(MQL_TESTER)) FileDelete(LogFileName(), common);
   g_logHandle = FileOpen(LogFileName(), FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | common);
   if(g_logHandle == INVALID_HANDLE)
   {
      Print("TrendEA: cannot open log file, error ", GetLastError());
      return;
   }
   FileSeek(g_logHandle, 0, SEEK_END);
   if(FileSize(g_logHandle) == 0)
      FileWriteString(g_logHandle,
         "time;event;dir;h1_close;h1_ema20;h1_ema50;h1_ema200;h1_adx;h1_pdi;h1_mdi;"
         "m15_ema20;m15_ema50;m15_ema200;m15_adx;m15_stochK;"
         "m5_K;m5_D;m5_close;m5_ema20;bid;ask;spread_pips;"
         "lot;entry;sl;tp;sl_pips;result;details\r\n");
}

void LogClose()
{
   if(g_logHandle != INVALID_HANDLE) { FileClose(g_logHandle); g_logHandle = INVALID_HANDLE; }
}

// One CSV row with the current indicator snapshot
void LogRow(const string ev, const int dir, const string details,
            const double lot = 0.0, const double entry = 0.0, const double sl = 0.0,
            const double tp = 0.0, const double slPips = 0.0, const string result = "")
{
   string det = details;
   StringReplace(det, ";", ",");
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spr = (g_pip > 0.0) ? (ask - bid) / g_pip : 0.0;

   if(ev != "EVAL")
      Print("TrendEA ", ev, " ", DirStr(dir), " ", det, " ", result);

   if(g_logHandle == INVALID_HANDLE) return;

   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + ";" + ev + ";" + DirStr(dir) + ";" +
      Fmt(g_s.h1Close) + ";" + Fmt(g_s.h1E20) + ";" + Fmt(g_s.h1E50) + ";" + Fmt(g_s.h1E200) + ";" +
      Fmt(g_s.h1Adx, 2) + ";" + Fmt(g_s.h1Pdi, 2) + ";" + Fmt(g_s.h1Mdi, 2) + ";" +
      Fmt(g_s.m15E20) + ";" + Fmt(g_s.m15E50) + ";" + Fmt(g_s.m15E200) + ";" +
      Fmt(g_s.m15Adx, 2) + ";" + Fmt(g_s.m15K, 2) + ";" +
      Fmt(g_s.m5K, 2) + ";" + Fmt(g_s.m5D, 2) + ";" + Fmt(g_s.m5Close) + ";" + Fmt(g_s.m5E20) + ";" +
      Fmt(bid) + ";" + Fmt(ask) + ";" + Fmt(spr, 2) + ";" +
      Fmt(lot, 2) + ";" + Fmt(entry) + ";" + Fmt(sl) + ";" + Fmt(tp) + ";" + Fmt(slPips, 1) + ";" +
      result + ";" + det + "\r\n";
   FileWriteString(g_logHandle, line);
   FileFlush(g_logHandle);
}

//+------------------------------------------------------------------+
//| Arrows                                                           |
//+------------------------------------------------------------------+
void DrawArrow(const bool isEntry, const int dir, const datetime t, const double price,
               const color clr, const string text)
{
   if(!DrawArrows) return;
   g_arrowSeq++;
   string name = ARROW_PREFIX + IntegerToString(MagicNumber) + "_" + (isEntry ? "IN" : "OUT") + "_" +
                 IntegerToString((long)TimeCurrent()) + "_" + IntegerToString(g_arrowSeq);
   ENUM_OBJECT type = isEntry ? ((dir > 0) ? OBJ_ARROW_BUY : OBJ_ARROW_SELL) : OBJ_ARROW_CHECK;
   if(!ObjectCreate(0, name, type, 0, t, price)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
//| Balance / equity (virtual P/L is included in SignalOnly mode)    |
//+------------------------------------------------------------------+
double GetBalance()
{
   double b = AccountInfoDouble(ACCOUNT_BALANCE);
   if(SignalOnly) b += g_virtPnL;
   return b;
}

double GetEquity()
{
   double e = AccountInfoDouble(ACCOUNT_EQUITY);
   if(SignalOnly)
   {
      e += g_virtPnL;
      if(g_open && g_virt && g_dist > 0.0)
      {
         double px = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         e += (px - g_entry) * g_dir / g_dist * g_riskMoney;
      }
   }
   return e;
}

//+------------------------------------------------------------------+
//| Snapshot of indicator values (shift = 1)                         |
//+------------------------------------------------------------------+
bool LoadSnapshot()
{
   g_s.valid = false;
   g_s.h1Close = iClose(_Symbol, TF_Trend, 1);
   g_s.m5Close = iClose(_Symbol, TF_Trigger, 1);
   g_s.m5Open  = iOpen(_Symbol, TF_Trigger, 1);
   if(g_s.h1Close <= 0.0 || g_s.m5Close <= 0.0 || g_s.m5Open <= 0.0) return false;

   bool ok = true;
   ok = ok && Rd(hTrEma20, 0, 1, g_s.h1E20);
   ok = ok && Rd(hTrEma50, 0, 1, g_s.h1E50);
   ok = ok && Rd(hTrEma200, 0, 1, g_s.h1E200);
   ok = ok && Rd(hTrEma50, 0, 1 + SlopeBars, g_s.h1E50Old);
   ok = ok && Rd(hTrAdx, MAIN_LINE, 1, g_s.h1Adx);
   ok = ok && Rd(hTrAdx, PLUSDI_LINE, 1, g_s.h1Pdi);
   ok = ok && Rd(hTrAdx, MINUSDI_LINE, 1, g_s.h1Mdi);
   ok = ok && Rd(hSeEma20, 0, 1, g_s.m15E20);
   ok = ok && Rd(hSeEma50, 0, 1, g_s.m15E50);
   ok = ok && Rd(hSeEma200, 0, 1, g_s.m15E200);
   ok = ok && Rd(hSeAdx, MAIN_LINE, 1, g_s.m15Adx);
   ok = ok && Rd(hSeStoch, MAIN_LINE, 1, g_s.m15K);
   ok = ok && Rd(hTgStoch, MAIN_LINE, 1, g_s.m5K);
   ok = ok && Rd(hTgStoch, SIGNAL_LINE, 1, g_s.m5D);
   ok = ok && Rd(hTgStoch, MAIN_LINE, 2, g_s.m5KPrev);
   ok = ok && Rd(hTgStoch, SIGNAL_LINE, 2, g_s.m5DPrev);
   ok = ok && Rd(hTgEma20, 0, 1, g_s.m5E20);
   g_s.valid = ok;
   return ok;
}

//+------------------------------------------------------------------+
//| 4.1 H1 trend filter                                              |
//+------------------------------------------------------------------+
bool CheckH1Filter(const int dir, string &why)
{
   why = "";
   bool c1, c2, c3, c4;
   if(dir > 0)
   {
      c1 = (g_s.h1Close > g_s.h1E200);
      c2 = (g_s.h1E20 > g_s.h1E50 && g_s.h1E50 > g_s.h1E200);
      c3 = (g_s.h1E50 > g_s.h1E50Old);
      c4 = (g_s.h1Adx > ADX_H1_Min && g_s.h1Pdi > g_s.h1Mdi);
   }
   else
   {
      c1 = (g_s.h1Close < g_s.h1E200);
      c2 = (g_s.h1E20 < g_s.h1E50 && g_s.h1E50 < g_s.h1E200);
      c3 = (g_s.h1E50 < g_s.h1E50Old);
      c4 = (g_s.h1Adx > ADX_H1_Min && g_s.h1Mdi > g_s.h1Pdi);
   }
   if(!c1) why += "H1.close/EMA200 ";
   if(!c2) why += "H1.EMA order ";
   if(!c3) why += "H1.EMA50 slope ";
   if(!c4) why += "H1.ADX/DI ";
   return (c1 && c2 && c3 && c4);
}

//+------------------------------------------------------------------+
//| 4.2 M15 setup                                                    |
//+------------------------------------------------------------------+
// Evaluates M15 conditions 1-5. Conditions 3 and 5 use the last
// PullbackBars bars; condition 4 uses `lookback` bars.
bool M15Conditions(const int dir, const int lookback,
                   bool &c1, bool &c2, bool &c3, bool &c4, bool &c5)
{
   double e20[], e50[], k[], hi[], lo[], cl[];
   ArraySetAsSeries(e20, true); ArraySetAsSeries(e50, true); ArraySetAsSeries(k, true);
   ArraySetAsSeries(hi, true);  ArraySetAsSeries(lo, true);  ArraySetAsSeries(cl, true);

   if(CopyBuffer(hSeEma20, 0, 1, lookback, e20) != lookback) return false;
   if(CopyBuffer(hSeEma50, 0, 1, lookback, e50) != lookback) return false;
   if(CopyBuffer(hSeStoch, MAIN_LINE, 1, lookback, k) != lookback) return false;
   if(CopyHigh(_Symbol, TF_Setup, 1, lookback, hi) != lookback) return false;
   if(CopyLow(_Symbol, TF_Setup, 1, lookback, lo) != lookback) return false;
   if(CopyClose(_Symbol, TF_Setup, 1, lookback, cl) != lookback) return false;

   if(dir > 0) c1 = (g_s.m15E20 > g_s.m15E50 && g_s.m15E50 > g_s.m15E200);
   else        c1 = (g_s.m15E20 < g_s.m15E50 && g_s.m15E50 < g_s.m15E200);
   c2 = (g_s.m15Adx > ADX_M15_Min);
   c3 = false;
   c4 = true;
   c5 = false;
   for(int i = 0; i < lookback; i++)
   {
      bool inWindow = (i < PullbackBars);
      if(dir > 0)
      {
         if(inWindow && lo[i] <= e20[i]) c3 = true;
         if(cl[i] < e50[i]) c4 = false;
         if(inWindow && k[i] < Stoch_OS) c5 = true;
      }
      else
      {
         if(inWindow && hi[i] >= e20[i]) c3 = true;
         if(cl[i] > e50[i]) c4 = false;
         if(inWindow && k[i] > Stoch_OB) c5 = true;
      }
   }
   return true;
}

// Called on every new M15 bar: advances the setup state machine
void UpdateSetups()
{
   datetime t1 = iTime(_Symbol, TF_Setup, 1);
   for(int d = 0; d < 2; d++)
   {
      int dir = (d == 0) ? DIR_BUY : DIR_SELL;
      bool c1, c2, c3, c4, c5;
      if(!M15Conditions(dir, PullbackBars, c1, c2, c3, c4, c5)) continue;
      bool all = (c1 && c2 && c3 && c4 && c5);
      string flags = "c1=" + (string)c1 + " c2=" + (string)c2 + " c3=" + (string)c3 +
                     " c4=" + (string)c4 + " c5=" + (string)c5;

      if(g_setupState[d] == SETUP_IDLE)
      {
         if(all)
         {
            g_setupState[d] = SETUP_ACTIVE;
            g_setupTime[d] = t1;
            LogRow("SETUP_START", dir, flags);
         }
      }
      else if(g_setupState[d] == SETUP_ACTIVE)
      {
         int age = (int)((t1 - g_setupTime[d]) / PeriodSeconds(TF_Setup));
         if(age >= SetupExpiryBars)
         {
            g_setupState[d] = SETUP_COOLDOWN;
            LogRow("SETUP_END", dir, "expired after " + IntegerToString(age) + " bars");
         }
         else
         {
            // re-check conditions 1 and 4 over the whole life of the setup
            bool a1, a2, a3, a4, a5;
            int lb = MathMax(PullbackBars, age + 1);
            if(M15Conditions(dir, lb, a1, a2, a3, a4, a5) && (!a1 || !a4))
            {
               g_setupState[d] = SETUP_COOLDOWN;
               LogRow("SETUP_END", dir, "violated: " + (!a1 ? "cond1(EMA order) " : "") + (!a4 ? "cond4(close beyond EMA50)" : ""));
            }
         }
      }
      else // SETUP_COOLDOWN
      {
         if(!all) g_setupState[d] = SETUP_IDLE;
      }
   }
}

bool CheckM15Setup(const int dir)
{
   return (g_setupState[DirIdx(dir)] == SETUP_ACTIVE);
}

//+------------------------------------------------------------------+
//| 4.3 M5 trigger                                                   |
//+------------------------------------------------------------------+
bool CheckM5Trigger(const int dir, string &why)
{
   why = "";
   bool cross, zone, candle, aboveEma;
   if(dir > 0)
   {
      cross    = (g_s.m5KPrev <= g_s.m5DPrev && g_s.m5K > g_s.m5D);
      zone     = (g_s.m5K < Stoch_OS || g_s.m5KPrev < Stoch_OS);
      candle   = (g_s.m5Close > g_s.m5Open);
      aboveEma = (g_s.m5Close > g_s.m5E20);
   }
   else
   {
      cross    = (g_s.m5KPrev >= g_s.m5DPrev && g_s.m5K < g_s.m5D);
      zone     = (g_s.m5K > Stoch_OB || g_s.m5KPrev > Stoch_OB);
      candle   = (g_s.m5Close < g_s.m5Open);
      aboveEma = (g_s.m5Close < g_s.m5E20);
   }
   if(!cross)    why += "M5.no K/D cross ";
   if(!zone)     why += "M5.cross not in OS/OB zone ";
   if(!candle)   why += "M5.candle direction ";
   if(!aboveEma) why += "M5.close vs EMA20 ";
   return (cross && zone && candle && aboveEma);
}

//+------------------------------------------------------------------+
//| Position lookup (by symbol + magic)                              |
//+------------------------------------------------------------------+
bool FindPosition(ulong &ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      ticket = t;
      return true;
   }
   return false;
}

// Loss in account currency for 1 lot at the given price distance
double LossPerLot(const double dist)
{
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0.0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickVal <= 0.0 || g_tickSize <= 0.0) return 0.0;
   return dist / g_tickSize * tickVal;
}

// Copy a selected real position into the global trade state
bool AdoptPosition(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   g_open = true;
   g_virt = false;
   g_ticket = ticket;
   g_posId = PositionGetInteger(POSITION_IDENTIFIER);
   g_dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? DIR_BUY : DIR_SELL;
   g_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_sl = PositionGetDouble(POSITION_SL);
   g_tp = PositionGetDouble(POSITION_TP);
   g_lot = PositionGetDouble(POSITION_VOLUME);
   g_openTime = (datetime)PositionGetInteger(POSITION_TIME);
   g_dist = MathAbs(g_entry - g_sl);
   g_riskMoney = g_lot * LossPerLot(g_dist);
   g_closeReason = "";
   g_finalizeTries = 0;
   return true;
}

void ClearTrade()
{
   g_open = false;
   g_virt = false;
   g_ticket = 0;
   g_posId = 0;
   g_dir = 0;
   g_closeReason = "";
   g_finalizeTries = 0;
}

//+------------------------------------------------------------------+
//| CalcLot: risk-based volume rounded DOWN to the volume step       |
//+------------------------------------------------------------------+
double CalcLot(const double slDistance)
{
   double lossPerLot = LossPerLot(slDistance);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lossPerLot <= 0.0 || step <= 0.0 || minV <= 0.0 || maxV <= 0.0) return 0.0;

   double riskMoney = GetBalance() * RiskPercent / 100.0;
   double lots = riskMoney / lossPerLot;
   lots = MathFloor(lots / step + EPS) * step;
   if(lots < minV) return 0.0;           // would exceed the allowed risk
   if(lots > maxV) lots = maxV;

   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > EPS) { s *= 10.0; digits++; }
   return NormalizeDouble(lots, digits);
}

//+------------------------------------------------------------------+
//| Entry price, SL and TP (section 5)                               |
//+------------------------------------------------------------------+
bool BuildStops(const int dir, double &entry, double &sl, double &tp, double &slPips, string &why)
{
   why = "";
   entry = 0.0; sl = 0.0; tp = 0.0; slPips = 0.0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) { why = "no quotes"; return false; }

   double lows[], highs[];
   ArraySetAsSeries(lows, true); ArraySetAsSeries(highs, true);
   if(CopyLow(_Symbol, TF_Trigger, 1, SwingBars, lows) != SwingBars ||
      CopyHigh(_Symbol, TF_Trigger, 1, SwingBars, highs) != SwingBars)
   { why = "no swing data"; return false; }

   double spread = ask - bid;
   double buffer = SL_BufferPips * g_pip;
   if(dir > 0)
   {
      double lowest = lows[0];
      for(int i = 1; i < SwingBars; i++) lowest = MathMin(lowest, lows[i]);
      entry = ask;
      sl = RoundTick(lowest - buffer - spread);
   }
   else
   {
      double highest = highs[0];
      for(int i = 1; i < SwingBars; i++) highest = MathMax(highest, highs[i]);
      entry = bid;
      sl = RoundTick(highest + buffer + spread);
   }

   double dist = MathAbs(entry - sl);
   slPips = dist / g_pip;
   tp = RoundTick(entry + dir * TP_R * dist);

   if(slPips < SL_MinPips || slPips > SL_MaxPips)
   {
      why = "SL size " + Fmt(slPips, 1) + " pips outside [" + Fmt(SL_MinPips, 1) + ", " + Fmt(SL_MaxPips, 1) + "]";
      return false;
   }
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   if(dist < minDist || MathAbs(tp - entry) < minDist)
   {
      why = "stops level violated (min distance " + Fmt(minDist) + ")";
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| News filter (MQL5 economic calendar)                             |
//+------------------------------------------------------------------+
bool IsNewsBlocked(string &why)
{
   why = "";
   if(!NewsFilterEnabled) return false;
   datetime now = TimeCurrent();
   datetime from = now - (datetime)(NewsAfterMin * SECONDS_PER_MIN);
   datetime to   = now + (datetime)(NewsBeforeMin * SECONDS_PER_MIN);
   string cur[2];
   cur[0] = NewsCurrency1;
   cur[1] = NewsCurrency2;
   for(int i = 0; i < 2; i++)
   {
      if(cur[i] == "") continue;
      MqlCalendarValue vals[];
      ResetLastError();
      if(!CalendarValueHistory(vals, from, to, NULL, cur[i]))
      {
         if(!g_newsWarned)
         {
            g_newsWarned = true;
            Print("TrendEA: calendar unavailable (error ", GetLastError(), "), news filter will not block");
         }
         continue;
      }
      for(int k = 0; k < ArraySize(vals); k++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[k].event_id, ev)) continue;
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
         {
            why = "news " + cur[i] + ": " + ev.name + ";";
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Day rollover                                                     |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime d = DayStart(TimeCurrent());
   if(d == g_day) return;
   g_day = d;
   g_dayStartBal = GetBalance();
   g_tradesToday = 0;
   g_dailyLossHit = false;
   if(g_consecPause) { g_consecPause = false; g_consecLosses = 0; }
   LogRow("NEW_DAY", 0, "start balance=" + Fmt(g_dayStartBal, 2));
}

//+------------------------------------------------------------------+
//| Trade closing                                                    |
//+------------------------------------------------------------------+
// Statistics, log and arrow after a trade is finished
void OnTradeClosed(const double exitPrice, const datetime exitTime, const double net, const string reason)
{
   double r = (g_riskMoney > 0.0) ? net / g_riskMoney : 0.0;
   color clr = (reason == "TP") ? clrLime : ((reason == "SL") ? clrRed : clrOrange);
   DrawArrow(false, g_dir, exitTime, exitPrice, clr, "EXIT " + reason);
   LogRow("EXIT", g_dir, "reason=" + reason + (g_virt ? " (virtual)" : ""),
          g_lot, exitPrice, g_sl, g_tp, 0.0, "net=" + Fmt(net, 2) + "|R=" + Fmt(r, 2));

   if(net < 0.0) g_consecLosses++; else g_consecLosses = 0;
   if(g_consecLosses >= MaxConsecLosses && !g_consecPause)
   {
      g_consecPause = true;
      LogRow("PAUSE", 0, "consecutive losses=" + IntegerToString(g_consecLosses) + ", pause until next day");
   }
   if(g_virt) g_virtPnL += net;
   ClearTrade();
}

// Finalize a closed REAL position from deal history
bool FinalizeReal()
{
   if(!HistorySelectByPosition(g_posId)) return false;
   int n = HistoryDealsTotal();
   double net = 0.0, exitPrice = 0.0;
   datetime exitTime = 0;
   long dealReason = -1;
   bool found = false;
   for(int i = 0; i < n; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      net += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_COMMISSION) +
             HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_FEE);
      long entryType = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_OUT_BY)
      {
         found = true;
         exitPrice = HistoryDealGetDouble(t, DEAL_PRICE);
         exitTime = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
         dealReason = HistoryDealGetInteger(t, DEAL_REASON);
      }
   }
   if(!found) return false;

   string reason = g_closeReason;
   if(reason == "")
   {
      if(dealReason == DEAL_REASON_SL)      reason = "SL";
      else if(dealReason == DEAL_REASON_TP) reason = "TP";
      else reason = "OTHER_" + EnumToString((ENUM_DEAL_REASON)dealReason);
   }
   OnTradeClosed(exitPrice, exitTime, net, reason);
   return true;
}

// Detects that the real position has disappeared (SL/TP/manual/our close)
void CheckClosedReal()
{
   if(!g_open || g_virt) return;
   if(PositionSelectByTicket(g_ticket)) return;
   if(FinalizeReal()) return;
   g_finalizeTries++;
   if(g_finalizeTries >= MAX_FINALIZE_TRIES)
   {
      LogRow("ERROR", g_dir, "closed position deal not found in history, state reset");
      ClearTrade();
   }
}

// Virtual position: SL/TP check on every tick (SignalOnly)
void FinalizeVirtual(const double price, const string reason)
{
   double r = (g_dist > 0.0) ? (price - g_entry) * g_dir / g_dist : 0.0;
   OnTradeClosed(price, TimeCurrent(), r * g_riskMoney, reason);
}

void CheckVirtual()
{
   if(!g_open || !g_virt) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_dir > 0)
   {
      if(bid <= g_sl)      FinalizeVirtual(g_sl, "SL");
      else if(bid >= g_tp) FinalizeVirtual(g_tp, "TP");
   }
   else
   {
      if(ask >= g_sl)      FinalizeVirtual(g_sl, "SL");
      else if(ask <= g_tp) FinalizeVirtual(g_tp, "TP");
   }
}

// Close the current trade at market (real) or at the quote (virtual)
bool CloseTrade(const string reason)
{
   if(!g_open) return false;
   if(g_virt)
   {
      double px = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      FinalizeVirtual(px, reason);
      return true;
   }

   g_closeReason = reason;
   for(int a = 0; a <= MaxOrderRetries; a++)
   {
      bool sent = g_trade.PositionClose(g_ticket, DeviationPoints);
      uint rc = g_trade.ResultRetcode();
      LogRow("ORDER_CLOSE", g_dir, "attempt " + IntegerToString(a + 1) + " retcode=" + IntegerToString((int)rc) +
             " " + g_trade.ResultRetcodeDescription() + " reason=" + reason);
      if(sent && IsSuccessRetcode(rc)) { CheckClosedReal(); return true; }
      if(!PositionSelectByTicket(g_ticket)) { CheckClosedReal(); return true; }
      if(!IsRetriableRetcode(rc)) break;
      Sleep(RetryDelayMs);
   }
   g_closeReason = "";
   LogRow("ERROR", g_dir, "failed to close position, reason=" + reason);
   return false;
}

//+------------------------------------------------------------------+
//| RiskGuard: day counters, daily loss limit; true = entries OK     |
//+------------------------------------------------------------------+
bool RiskGuard(string &why)
{
   why = "";
   if(!g_dailyLossHit && g_dayStartBal > 0.0)
   {
      double loss = g_dayStartBal - GetEquity();
      if(loss >= g_dayStartBal * DailyLossLimit / 100.0)
      {
         g_dailyLossHit = true;
         LogRow("DAILY_LOSS_LIMIT", 0, "loss=" + Fmt(loss, 2) + " limit=" + Fmt(g_dayStartBal * DailyLossLimit / 100.0, 2));
      }
   }
   // close everything once the limit is hit (retry at most once per second)
   if(g_dailyLossHit && g_open && TimeCurrent() != g_lastCloseTry)
   {
      g_lastCloseTry = TimeCurrent();
      CloseTrade("DAILY_LOSS_LIMIT");
   }
   if(g_dailyLossHit)                    why += "daily loss limit;";
   if(g_consecPause)                     why += "consecutive losses pause;";
   if(g_tradesToday >= MaxTradesPerDay)  why += "max trades per day;";
   return (why == "");
}

//+------------------------------------------------------------------+
//| Entry filters (section 7 + risk)                                 |
//+------------------------------------------------------------------+
bool EntryFilters(string &why)
{
   why = "";
   if(!TradingEnabled) why += "TradingEnabled=false;";

   string rw;
   if(!RiskGuard(rw)) why += rw;

   // reference time = server time - GMTOffset
   datetime refT = TimeCurrent() - (datetime)(GMTOffset * SECONDS_PER_HOUR);
   MqlDateTime dt;
   TimeToStruct(refT, dt);
   int nowMin = dt.hour * MINUTES_PER_HOUR + dt.min;

   bool inSession;
   if(g_sessStartMin == g_sessEndMin)      inSession = true;
   else if(g_sessStartMin < g_sessEndMin)  inSession = (nowMin >= g_sessStartMin && nowMin < g_sessEndMin);
   else                                    inSession = (nowMin >= g_sessStartMin || nowMin < g_sessEndMin);
   if(!inSession) why += "outside session;";

   if(dt.day_of_week == FRIDAY_DOW && nowMin >= g_fridayCutMin) why += "friday cutoff;";

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPips = (ask - bid) / g_pip;
   if(spreadPips > MaxSpreadPips) why += "spread " + Fmt(spreadPips, 2) + " pips;";

   if(ADX_H1_MaxEnabled && g_s.h1Adx > ADX_H1_Max) why += "ADX H1 overheated " + Fmt(g_s.h1Adx, 1) + ";";

   string nw;
   if(IsNewsBlocked(nw)) why += nw;

   return (why == "");
}

//+------------------------------------------------------------------+
//| Opening a trade                                                  |
//+------------------------------------------------------------------+
bool OpenReal(const int dir, const double lot, const double sl, const double tp)
{
   for(int a = 0; a <= MaxOrderRetries; a++)
   {
      bool sent = (dir > 0) ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, OrderComment)
                            : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, OrderComment);
      uint rc = g_trade.ResultRetcode();
      LogRow("ORDER_OPEN", dir, "attempt " + IntegerToString(a + 1) + " retcode=" + IntegerToString((int)rc) +
             " " + g_trade.ResultRetcodeDescription(), lot, g_trade.ResultPrice(), sl, tp);

      ulong tk = 0;
      if(sent && IsSuccessRetcode(rc)) { if(FindPosition(tk)) return AdoptPosition(tk); return false; }
      // e.g. timeout: the order may still have been executed
      if(FindPosition(tk)) return AdoptPosition(tk);
      if(!IsRetriableRetcode(rc)) break;
      Sleep(RetryDelayMs);
   }
   return false;
}

void OpenVirtual(const int dir, const double entry, const double sl, const double tp, const double lot)
{
   g_open = true;
   g_virt = true;
   g_ticket = 0;
   g_posId = 0;
   g_dir = dir;
   g_entry = entry;
   g_sl = sl;
   g_tp = tp;
   g_lot = lot;
   g_openTime = TimeCurrent();
   g_dist = MathAbs(entry - sl);
   g_riskMoney = lot * LossPerLot(g_dist);
   g_closeReason = "";
}

void TryEntry()
{
   for(int d = 0; d < 2; d++)
   {
      if(!g_sig[d]) continue;
      int dir = (d == 0) ? DIR_BUY : DIR_SELL;

      if(g_open) { LogRow("ENTRY_SKIP", dir, "position already open"); continue; }

      string why;
      if(!EntryFilters(why)) { LogRow("ENTRY_SKIP", dir, "filters: " + why); continue; }

      double entry, sl, tp, slPips;
      if(!BuildStops(dir, entry, sl, tp, slPips, why))
      { LogRow("ENTRY_SKIP", dir, why, 0.0, entry, sl, tp, slPips); continue; }

      double lot = CalcLot(MathAbs(entry - sl));
      if(lot <= 0.0)
      { LogRow("ENTRY_SKIP", dir, "lot below minimum volume for the risk limit", 0.0, entry, sl, tp, slPips); continue; }

      bool opened;
      if(SignalOnly) { OpenVirtual(dir, entry, sl, tp, lot); opened = true; }
      else           opened = OpenReal(dir, lot, sl, tp);

      if(!opened)
      { LogRow("ENTRY_SKIP", dir, "order failed after retries", lot, entry, sl, tp, slPips); continue; }

      // safety: make sure SL/TP are attached (some servers ignore them in market requests)
      if(!g_virt && (g_sl == 0.0 || g_tp == 0.0))
      {
         if(g_trade.PositionModify(g_ticket, sl, tp)) { g_sl = sl; g_tp = tp; }
         LogRow("ORDER_MODIFY", dir, "SL/TP attached after open, retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
      }

      g_tradesToday++;
      g_setupState[d] = SETUP_COOLDOWN;      // one setup = one entry
      DrawArrow(true, dir, iTime(_Symbol, TF_Trigger, 0), g_entry, (dir > 0) ? clrDodgerBlue : clrTomato,
                "ENTRY " + DirStr(dir));
      LogRow("ENTRY", dir, g_virt ? "virtual (SignalOnly)" : "real order", g_lot, g_entry, g_sl, g_tp, slPips,
             "risk=" + Fmt(g_riskMoney, 2));
      break;
   }
}

//+------------------------------------------------------------------+
//| ManagePosition: early exit on direction change (section 5)       |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!g_open) return;
   int idx = DirIdx(g_dir);
   int opp = 1 - idx;
   if(ExitOnH1Break && !g_h1ok[idx])
   {
      CloseTrade("DIRECTION_CHANGE_H1_BREAK");
      return;
   }
   if(ExitOnOppositeSignal && g_sig[opp])
      CloseTrade("DIRECTION_CHANGE_OPPOSITE_SIGNAL");
}

//+------------------------------------------------------------------+
//| Logic executed on every new trigger-TF bar                       |
//+------------------------------------------------------------------+
void OnTriggerBar()
{
   for(int d = 0; d < 2; d++)
   {
      int dir = (d == 0) ? DIR_BUY : DIR_SELL;
      string wh, wt;
      g_h1ok[d] = CheckH1Filter(dir, wh);
      bool su = CheckM15Setup(dir);
      bool tr = CheckM5Trigger(dir, wt);
      g_sig[d] = (g_h1ok[d] && su && tr);

      if(LogVerbose && (g_h1ok[d] || su))
         LogRow("EVAL", dir, "h1ok=" + (string)g_h1ok[d] + " setup=" + (string)su + " trigger=" + (string)tr +
                " | rejected: " + wh + wt);
      if(g_sig[d])
         LogRow("SIGNAL", dir, "H1 filter + M15 setup + M5 trigger passed");
   }
   ManagePosition();
   TryEntry();
}

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   g_sessStartMin = ParseHHMM(SessionStart);
   g_sessEndMin   = ParseHHMM(SessionEnd);
   g_fridayCutMin = ParseHHMM(FridayCutoff);
   if(g_sessStartMin < 0 || g_sessEndMin < 0 || g_fridayCutMin < 0)
   { Print("TrendEA: time inputs must be HH:MM"); return false; }
   if(PullbackBars < 1 || SetupExpiryBars < 1 || SwingBars < 1 || SlopeBars < 1)
   { Print("TrendEA: PullbackBars, SetupExpiryBars, SwingBars, SlopeBars must be >= 1"); return false; }
   if(RiskPercent <= 0.0 || TP_R <= 0.0 || SL_MinPips <= 0.0 || SL_MaxPips <= SL_MinPips)
   { Print("TrendEA: invalid risk / SL / TP inputs"); return false; }
   if(MaxOrderRetries < 0 || MaxTradesPerDay < 1 || MaxConsecLosses < 1)
   { Print("TrendEA: invalid retry / limit inputs"); return false; }
   if(!(EMA_Fast < EMA_Mid && EMA_Mid < EMA_Slow))
   { Print("TrendEA: EMA periods must satisfy Fast < Mid < Slow"); return false; }
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;

   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0) g_tickSize = g_point;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (digits == 3 || digits == 5) ? g_point * PIP_POINT_FACTOR : g_point;
   if(g_point <= 0.0 || g_pip <= 0.0) { Print("TrendEA: invalid symbol point size"); return INIT_FAILED; }

   hTrEma20  = iMA(_Symbol, TF_Trend, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hTrEma50  = iMA(_Symbol, TF_Trend, EMA_Mid, 0, MODE_EMA, PRICE_CLOSE);
   hTrEma200 = iMA(_Symbol, TF_Trend, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hTrAdx    = iADX(_Symbol, TF_Trend, ADX_Period);
   hSeEma20  = iMA(_Symbol, TF_Setup, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hSeEma50  = iMA(_Symbol, TF_Setup, EMA_Mid, 0, MODE_EMA, PRICE_CLOSE);
   hSeEma200 = iMA(_Symbol, TF_Setup, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hSeAdx    = iADX(_Symbol, TF_Setup, ADX_Period);
   hSeStoch  = iStochastic(_Symbol, TF_Setup, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   hTgEma20  = iMA(_Symbol, TF_Trigger, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hTgStoch  = iStochastic(_Symbol, TF_Trigger, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   if(hTrEma20 == INVALID_HANDLE || hTrEma50 == INVALID_HANDLE || hTrEma200 == INVALID_HANDLE ||
      hTrAdx == INVALID_HANDLE || hSeEma20 == INVALID_HANDLE || hSeEma50 == INVALID_HANDLE ||
      hSeEma200 == INVALID_HANDLE || hSeAdx == INVALID_HANDLE || hSeStoch == INVALID_HANDLE ||
      hTgEma20 == INVALID_HANDLE || hTgStoch == INVALID_HANDLE)
   {
      Print("TrendEA: failed to create indicator handles, error ", GetLastError());
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints(DeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ZeroMemory(g_s);
   for(int i = 0; i < 2; i++)
   {
      g_setupState[i] = SETUP_IDLE;
      g_setupTime[i] = 0;
      g_h1ok[i] = false;
      g_sig[i] = false;
   }

   LogOpen();

   // adopt an already open position (EA restart)
   ulong tk = 0;
   if(!SignalOnly && FindPosition(tk) && AdoptPosition(tk))
      LogRow("ADOPT", g_dir, "existing position adopted", g_lot, g_entry, g_sl, g_tp);

   CheckNewDay();
   LogRow("INIT", 0, "SignalOnly=" + (string)SignalOnly + " TradingEnabled=" + (string)TradingEnabled +
          " pip=" + Fmt(g_pip));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   int handles[] = {hTrEma20, hTrEma50, hTrEma200, hTrAdx, hSeEma20, hSeEma50, hSeEma200,
                    hSeAdx, hSeStoch, hTgEma20, hTgStoch};
   for(int i = 0; i < ArraySize(handles); i++)
      if(handles[i] != INVALID_HANDLE) IndicatorRelease(handles[i]);
   LogClose();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();

   // per-tick duties: SL/TP detection and risk limits
   if(g_open)
   {
      if(g_virt) CheckVirtual();
      else       CheckClosedReal();
   }
   string rw;
   RiskGuard(rw);

   // new-bar detectors (one per timeframe)
   bool newTrend = IsNewBar(TF_Trend, g_lastBarTrend);
   bool newSetup = IsNewBar(TF_Setup, g_lastBarSetup);
   bool newTrig  = IsNewBar(TF_Trigger, g_lastBarTrig);
   if(!(newTrend || newSetup || newTrig)) return;

   if(!LoadSnapshot())
   {
      if(LogVerbose) LogRow("DATA", 0, "indicator data not ready");
      return;
   }
   if(newSetup) UpdateSetups();   // M15 state first, then the M5 trigger
   if(newTrig)  OnTriggerBar();
}
//+------------------------------------------------------------------+
