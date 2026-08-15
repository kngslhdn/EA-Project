#property strict
#property version "8.00"
#property description "XAU APEX V8 - regime-adaptive multi-engine XAUUSD EA: trend, breakout, mean reversion, volatility-aware risk and execution protection"

#include <Trade/Trade.mqh>
CTrade trade;

enum Direction { NONE=0, BUY_SIGNAL=1, SELL_SIGNAL=-1 };
enum EngineType { ENGINE_NONE=0, ENGINE_TREND=1, ENGINE_BREAKOUT=2, ENGINE_MEANREV=3 };

//---------- CORE
input ENUM_TIMEFRAMES EntryTF=PERIOD_M15;
input ENUM_TIMEFRAMES RegimeTF=PERIOD_H1;
input ulong Magic=26081800;
input string CommentText="XAU APEX V8";
input bool AllowBuy=true;
input bool AllowSell=true;
input bool OnePositionOnly=true;

//---------- REGIME ENGINE
input int RegimeFastEMA=50;
input int RegimeSlowEMA=200;
input int RegimeADXPeriod=14;
input double TrendADXMin=20.0;
input double RangeADXMax=17.0;
input double MinTrendSeparationATR=0.10;
input double BuyTrendScoreMin=62.0;
input double SellTrendScoreMin=58.0;
input double BuyADXMin=20.0;
input double SellADXMin=18.0;

//---------- ENTRY ENGINE
input int EntryFastEMA=20;
input int EntrySlowEMA=50;
input int RSIPeriod=14;
input int ATRPeriod=14;
input int ATRBaselinePeriod=50;
input bool UseSessionVWAP=true;
input int SessionStartHour=7;
input int SessionEndHour=22;
input double VWAPToleranceATR=0.25;
input double ATRMin=0.80;
input double ATRMax=45.0;
input double MaxChaseATR=0.75;
input double MinBodyFraction=0.45;
input double MinCloseLocation=0.60;

//---------- TREND / PULLBACK ENGINE
input bool UseTrendEngine=true;
input double PullbackTouchATR=0.30;
input double PullbackMaxDistanceATR=0.55;
input double TrendTP_R=3.20;
input double StrongTrendTP_R=4.20;
input double StrongTrendScore=82.0;
input double TrendSL_ATR=1.55;

//---------- BREAKOUT ENGINE
input bool UseBreakoutEngine=true;
input int BreakoutLookback=20;
input double BreakoutBufferATR=0.05;
input double BreakoutMaxChaseATR=0.70;
input double BreakoutVolumeFactor=1.10;
input double BreakoutADXMin=19.0;
input double BreakoutTP_R=2.80;
input double BreakoutSL_ATR=1.45;

//---------- MEAN REVERSION ENGINE
input bool UseMeanReversionEngine=true;
input double MeanRevMaxADX=17.0;
input double MeanRevDistanceATR=1.15;
input int MeanRevRSIBuy=30;
input int MeanRevRSISell=70;
input double MeanRevTP_R=1.55;
input double MeanRevSL_ATR=1.35;
input double MeanRevMinBodyFraction=0.35;

//---------- EXIT ENGINE
input bool UseAdaptiveTP=true;
input double BE_R=1.00;
input double LockStart_R=1.45;
input double Lock_R=0.35;
input double TrailStart_R=1.90;
input double TrailATR=1.35;
input double ExhaustionATR=3.20;
input int MaxBarsInTrade=20;
input double TimeStopMinR=0.15;

//---------- VOLATILITY-AWARE RISK
input double BaseRiskPercent=0.50;
input double HighVolATRRatio=1.35;
input double HighVolRiskFactor=0.55;
input double LowVolATRRatio=0.80;
input double LowVolRiskFactor=0.75;
input double MinRiskPercent=0.20;
input double MaxRiskPercent=0.75;
input double BreakoutRiskFactor=0.90;
input double MeanRevRiskFactor=0.65;

//---------- ACCOUNT PROTECTION
input double MaxDailyLossPercent=2.0;
input double MaxEquityDDPercent=10.0;
input int MaxTradesPerDay=4;
input int MaxConsecutiveLosses=3;
input int CooldownMinutes=45;

//---------- EXECUTION / MARKET QUALITY
input double MaxSpreadPrice=1.50;
input int SlippagePoints=80;
input bool BlockFridayLate=true;
input int FridayStopHour=19;
input bool AvoidExtremeSpread=true;
input bool AvoidExhaustionCandle=true;

//---------- OPTIONAL NEWS FILTER
// Disabled by default because Strategy Tester calendar availability depends on terminal/tester data.
input bool UseNewsFilter=false;
input int NewsBlockBeforeMinutes=20;
input int NewsBlockAfterMinutes=15;
input bool BlockHighImpactUSD=true;

//---------- DEBUG
input bool DebugMode=true;

int hEFast=-1,hESlow=-1,hRFast=-1,hRSlow=-1,hADX=-1,hATR=-1,hRSI=-1,hATRBase=-1;
datetime lastBar=0,cooldownUntil=0;
double peakEquity=0.0;
int dayKey=-1,consecutiveLosses=0;

void Log(const string s){if(DebugMode)Print("XAU APEX V8 | ",s);}

int VolDigits(){double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);int d=0;while(d<8&&MathAbs(s-MathRound(s))>1e-10){s*=10.0;d++;}return d;}
double NPrice(const double p){return NormalizeDouble(p,_Digits);}
double NVol(double v){double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(mn<=0||mx<=0||st<=0)return 0;v=MathMax(mn,MathMin(mx,v));v=MathFloor(v/st+1e-9)*st;if(v<mn)v=mn;return NormalizeDouble(v,VolDigits());}

bool Buf(const int h,const int buffer,const int shift,double &v){double a[1];if(h<0||CopyBuffer(h,buffer,shift,1,a)!=1)return false;v=a[0];return v!=EMPTY_VALUE;}

bool NewBar(){datetime t[1];if(CopyTime(_Symbol,EntryTF,0,1,t)!=1)return false;if(t[0]==lastBar)return false;lastBar=t[0];return true;}

int DayKey(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);return d.year*10000+d.mon*100+d.day;}

void DailyReset(){int d=DayKey();if(d!=dayKey){dayKey=d;consecutiveLosses=0;cooldownUntil=0;Log("NEW DAY");}}

int Positions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t>0&&PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==Magic)n++;}return n;}

void UpdatePeak(){double e=AccountInfoDouble(ACCOUNT_EQUITY);if(e>peakEquity)peakEquity=e;}

void DayWindow(datetime &a,datetime &b){MqlDateTime d;TimeToStruct(TimeCurrent(),d);d.hour=0;d.min=0;d.sec=0;a=StructToTime(d);b=TimeCurrent();}

double TodayPnL(){datetime a,b;DayWindow(a,b);if(!HistorySelect(a,b))return 0;double p=0;uint n=HistoryDealsTotal();for(uint i=0;i<n;i++){ulong t=HistoryDealGetTicket(i);if(t==0)continue;if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=Magic)continue;long e=HistoryDealGetInteger(t,DEAL_ENTRY);if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY)p+=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);}return p;}

int TradesToday(){datetime a,b;DayWindow(a,b);if(!HistorySelect(a,b))return 0;int n=0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong t=HistoryDealGetTicket(i);if(t==0)continue;if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=Magic)continue;if(HistoryDealGetInteger(t,DEAL_ENTRY)==DEAL_ENTRY_IN)n++;}return n;}

bool RiskBlocked(){double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);if(bal<=0)return true;if(MaxDailyLossPercent>0&&TodayPnL()<=-bal*MaxDailyLossPercent/100.0){Log("BLOCK DAILY LOSS");return true;}if(MaxEquityDDPercent>0&&peakEquity>0&&(peakEquity-eq)>=peakEquity*MaxEquityDDPercent/100.0){Log("BLOCK EQUITY DD");return true;}if(MaxTradesPerDay>0&&TradesToday()>=MaxTradesPerDay){Log("BLOCK MAX TRADES");return true;}if(MaxConsecutiveLosses>0&&consecutiveLosses>=MaxConsecutiveLosses){Log("BLOCK CONSECUTIVE LOSSES");return true;}return cooldownUntil>TimeCurrent();}

bool SessionOK(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);if(d.day_of_week==0||d.day_of_week==6)return false;if(BlockFridayLate&&d.day_of_week==5&&d.hour>=FridayStopHour)return false;if(SessionStartHour==SessionEndHour)return true;if(SessionStartHour<SessionEndHour)return d.hour>=SessionStartHour&&d.hour<SessionEndHour;return d.hour>=SessionStartHour||d.hour<SessionEndHour;}

bool SpreadOK(){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;double sp=t.ask-t.bid;if(MaxSpreadPrice>0&&sp>MaxSpreadPrice){if(DebugMode)Print("XAU APEX V8 | BLOCK SPREAD ",DoubleToString(sp,_Digits));return false;}return true;}

bool SessionVWAP(double &vwap){datetime now=TimeCurrent();MqlDateTime d;TimeToStruct(now,d);d.hour=SessionStartHour;d.min=0;d.sec=0;datetime from=StructToTime(d);if(now<from)from-=86400;MqlRates r[];int n=CopyRates(_Symbol,EntryTF,from,now,r);if(n<3)return false;double pv=0,vol=0;for(int i=0;i<n;i++){double tv=(double)r[i].tick_volume;double typical=(r[i].high+r[i].low+r[i].close)/3.0;pv+=typical*tv;vol+=tv;}if(vol<=0)return false;vwap=pv/vol;return true;}

bool ATRState(double &atr,double &ratio){if(!Buf(hATR,0,1,atr)||!Buf(hATRBase,0,1,ratio))return false;double base=ratio;if(base<=0)return false;ratio=atr/base;return true;}

bool VolumeConfirm(const MqlRates &r[],const int count,const double factor){if(count<8)return true;double avg=0;for(int i=2;i<7;i++)avg+=(double)r[i].tick_volume;avg/=5.0;if(avg<=0)return true;return (double)r[0].tick_volume>=avg*factor;}

bool Regime(Direction &dir,double &atr,double &atrRatio,double &score,double &adx,double &plusDI,double &minusDI){double rf,rs,rfPrev,rsPrev,c;if(!Buf(hRFast,0,1,rf)||!Buf(hRSlow,0,1,rs)||!Buf(hRFast,0,2,rfPrev)||!Buf(hRSlow,0,2,rsPrev)||!Buf(hADX,0,1,adx)||!Buf(hADX,1,1,plusDI)||!Buf(hADX,2,1,minusDI))return false;if(!ATRState(atr,atrRatio))return false;if(atr<ATRMin||atr>ATRMax)return false;c=iClose(_Symbol,RegimeTF,1);if(c<=0)return false;double sep=MathAbs(rf-rs)/atr;if(sep<MinTrendSeparationATR){dir=NONE;score=0;return true;}double sepScore=MathMin(30.0,sep/0.40*30.0);double adxScore=MathMin(25.0,MathMax(0.0,(adx-10.0)/20.0*25.0));double slopeScore=MathMin(20.0,MathAbs(rf-rfPrev)/atr*20.0);double priceScore=0.0;if(rf>rs&&c>rf)priceScore=25.0;if(rf<rs&&c<rf)priceScore=25.0;score=sepScore+adxScore+slopeScore+priceScore;dir=NONE;if(rf>rs&&c>rf&&adx>=BuyADXMin&&plusDI>minusDI&&score>=BuyTrendScoreMin)dir=BUY_SIGNAL;else if(rf<rs&&c<rf&&adx>=SellADXMin&&minusDI>plusDI&&score>=SellTrendScoreMin)dir=SELL_SIGNAL;return true;}

string RKey(const ulong ticket){return "XAU_APEX_V8_R_"+(string)ticket;}
string EKey(const ulong ticket){return "XAU_APEX_V8_E_"+(string)ticket;}
string TKey(const ulong ticket){return "XAU_APEX_V8_T_"+(string)ticket;}

void SaveState(const ulong ticket,const double r,const EngineType e){if(ticket==0)return;if(r>0)GlobalVariableSet(RKey(ticket),r);GlobalVariableSet(EKey(ticket),(double)e);GlobalVariableSet(TKey(ticket),(double)TimeCurrent());}
double LoadRisk(const ulong ticket){if(ticket==0||!GlobalVariableCheck(RKey(ticket)))return 0;return GlobalVariableGet(RKey(ticket));}
EngineType LoadEngine(const ulong ticket){if(ticket==0||!GlobalVariableCheck(EKey(ticket)))return ENGINE_NONE;return (EngineType)(int)GlobalVariableGet(EKey(ticket));}
datetime LoadEntryTime(const ulong ticket){if(ticket==0||!GlobalVariableCheck(TKey(ticket)))return 0;return (datetime)GlobalVariableGet(TKey(ticket));}
void DeleteState(const ulong ticket){if(ticket==0)return;if(GlobalVariableCheck(RKey(ticket)))GlobalVariableDel(RKey(ticket));if(GlobalVariableCheck(EKey(ticket)))GlobalVariableDel(EKey(ticket));if(GlobalVariableCheck(TKey(ticket)))GlobalVariableDel(TKey(ticket));}

bool TrendSignal(const Direction dir,const double atr,const double vwap,MqlRates &r[],double &quality){quality=0;double ef,es;if(!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es))return false;MqlRates s=r[0];double range=s.high-s.low;if(range<=0||range>atr*ExhaustionATR)return false;double body=MathAbs(s.close-s.open);double loc=(s.close-s.low)/range;if(body/range<MinBodyFraction)return false;if(dir==BUY_SIGNAL){if(!(ef>es&&s.close>ef))return false;if(loc<MinCloseLocation)return false;double dist=MathAbs(s.close-ef)/atr;if(dist>MaxChaseATR)return false;bool touched=s.low<=ef+atr*PullbackTouchATR&&s.low>=ef-atr*PullbackMaxDistanceATR;bool reject=s.close>s.open&&s.close>ef&&loc>=MinCloseLocation;if(!touched||!reject)return false;if(UseSessionVWAP&&s.close<vwap-atr*VWAPToleranceATR)return false;quality=70.0+MathMin(25.0,(1.0-dist/MathMax(MaxChaseATR,0.01))*25.0);return true;}else{if(!(ef<es&&s.close<ef))return false;if(loc>(1.0-MinCloseLocation))return false;double dist=MathAbs(s.close-ef)/atr;if(dist>MaxChaseATR)return false;bool touched=s.high>=ef-atr*PullbackTouchATR&&s.high<=ef+atr*PullbackMaxDistanceATR;bool reject=s.close<s.open&&s.close<ef&&loc<=(1.0-MinCloseLocation);if(!touched||!reject)return false;if(UseSessionVWAP&&s.close>vwap+atr*VWAPToleranceATR)return false;quality=70.0+MathMin(25.0,(1.0-dist/MathMax(MaxChaseATR,0.01))*25.0);return true;}}

bool BreakoutSignal(const Direction dir,const double atr,const double adx,MqlRates &r[],double &quality){quality=0;if(adx<BreakoutADXMin)return false;int lb=MathMax(5,BreakoutLookback);if(ArraySize(r)<lb+3)return false;double hi=-DBL_MAX,lo=DBL_MAX;for(int i=1;i<=lb;i++){if(r[i].high>hi)hi=r[i].high;if(r[i].low<lo)lo=r[i].low;}MqlRates s=r[0];double range=s.high-s.low;if(range<=0)return false;double body=MathAbs(s.close-s.open);if(body/range<MinBodyFraction)return false;if(AvoidExhaustionCandle&&range>atr*ExhaustionATR)return false;if(!VolumeConfirm(r,ArraySize(r),BreakoutVolumeFactor))return false;if(dir==BUY_SIGNAL){double level=hi+atr*BreakoutBufferATR;if(s.close<=level)return false;double chase=(s.close-hi)/atr;if(chase>BreakoutMaxChaseATR)return false;quality=75.0+MathMin(20.0,(1.0-chase/MathMax(BreakoutMaxChaseATR,0.01))*20.0);return true;}else{double level=lo-atr*BreakoutBufferATR;if(s.close>=level)return false;double chase=(lo-s.close)/atr;if(chase>BreakoutMaxChaseATR)return false;quality=75.0+MathMin(20.0,(1.0-chase/MathMax(BreakoutMaxChaseATR,0.01))*20.0);return true;}}

bool MeanRevSignal(const double atr,const double adx,const double vwap,double &quality,Direction &dir){quality=0;dir=NONE;if(adx>MeanRevMaxADX||!UseMeanReversionEngine)return false;double rsi;if(!Buf(hRSI,0,1,rsi))return false;MqlRates rr[];ArraySetAsSeries(rr,true);if(CopyRates(_Symbol,EntryTF,1,5,rr)<5)return false;MqlRates s=rr[0];double range=s.high-s.low;if(range<=0)return false;double body=MathAbs(s.close-s.open);if(body/range<MeanRevMinBodyFraction)return false;double dist=(s.close-vwap)/atr;if(dist<=-MeanRevDistanceATR&&rsi<=MeanRevRSIBuy&&s.close>s.open&&s.close>rr[1].close){dir=BUY_SIGNAL;quality=72.0+MathMin(18.0,MathAbs(dist)/MeanRevDistanceATR*9.0);return true;}if(dist>=MeanRevDistanceATR&&rsi>=MeanRevRSISell&&s.close<s.open&&s.close<rr[1].close){dir=SELL_SIGNAL;quality=72.0+MathMin(18.0,MathAbs(dist)/MeanRevDistanceATR*9.0);return true;}return false;}

bool BuildSignal(Direction &signal,EngineType &engine,double &atr,double &atrRatio,double &quality,double &adx,double &regimeScore){signal=NONE;engine=ENGINE_NONE;quality=0;Direction regime=NONE;if(!Regime(regime,atr,atrRatio,regimeScore,adx,atrRatio,atrRatio))return false; // overwritten below by direct indicator reads
return false;}

//---------- MASTER SIGNAL ENGINE
bool GetSignal(Direction &signal,EngineType &engine,double &atr,double &atrRatio,double &quality){signal=NONE;engine=ENGINE_NONE;quality=0;double regimeScore,adx,plusDI,minusDI;Direction regime;if(!Regime(regime,atr,atrRatio,regimeScore,adx,plusDI,minusDI))return false;double vwap=0;if(UseSessionVWAP&&!SessionVWAP(vwap))return false;if(!UseSessionVWAP)vwap=iClose(_Symbol,EntryTF,1);MqlRates r[];ArraySetAsSeries(r,true);int need=MathMax(BreakoutLookback+3,12);if(CopyRates(_Symbol,EntryTF,1,need,r)<need)return false;
   // 1) Trend pullback gets first priority only in confirmed trend regime.
   if(regime!=NONE&&UseTrendEngine){double q=0;if(TrendSignal(regime,atr,vwap,r,q)){signal=regime;engine=ENGINE_TREND;quality=q+MathMin(15.0,regimeScore*0.15);return true;}}
   // 2) Breakout can initiate a new trend even when the H1 trend score is not yet complete.
   if(UseBreakoutEngine){Direction bd=regime;if(bd==NONE){double ef,es;if(!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es))return false;double c=iClose(_Symbol,EntryTF,1);if(c>ef&&ef>es)bd=BUY_SIGNAL;else if(c<ef&&ef<es)bd=SELL_SIGNAL;}if(bd!=NONE){double q=0;if(BreakoutSignal(bd,atr,adx,r,q)){signal=bd;engine=ENGINE_BREAKOUT;quality=q+MathMin(10.0,MathMax(0.0,adx-BreakoutADXMin));return true;}}}
   // 3) Mean reversion is explicitly restricted to low-ADX/range conditions.
   if(UseMeanReversionEngine&&vwap>0){Direction md;double q=0;if(MeanRevSignal(atr,adx,vwap,q,md)){signal=md;engine=ENGINE_MEANREV;quality=q;return true;}}
   return false;}

//---------- RISK ENGINE
 double RiskFor(const EngineType engine,const double atrRatio,const double quality){double r=BaseRiskPercent;if(atrRatio>=HighVolATRRatio)r*=HighVolRiskFactor;else if(atrRatio<=LowVolATRRatio)r*=LowVolRiskFactor;if(engine==ENGINE_BREAKOUT)r*=BreakoutRiskFactor;if(engine==ENGINE_MEANREV)r*=MeanRevRiskFactor;double q=MathMax(0.0,MathMin(100.0,quality));double confidence=0.75+0.25*(q/100.0);r*=confidence;return MathMax(MinRiskPercent,MathMin(MaxRiskPercent,r));}

double LotForRisk(const ENUM_ORDER_TYPE type,const double entry,const double sl,const double riskPercent){double risk=AccountInfoDouble(ACCOUNT_EQUITY)*riskPercent/100.0;if(risk<=0)return 0;double pnl;if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,pnl))return 0;double one=MathAbs(pnl);if(one<=0)return 0;return NVol(risk/one);}

bool StopOK(const ENUM_ORDER_TYPE type,const double entry,const double sl){double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(minDist<=0)return true;return type==ORDER_TYPE_BUY?entry-sl>=minDist:sl-entry>=minDist;}

void Enter(const Direction dir,const EngineType engine,const double atr,const double atrRatio,const double quality,const double regimeScore){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;ENUM_ORDER_TYPE type=dir==BUY_SIGNAL?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double entry=type==ORDER_TYPE_BUY?t.ask:t.bid;double slDist=engine==ENGINE_TREND?atr*TrendSL_ATR:(engine==ENGINE_BREAKOUT?atr*BreakoutSL_ATR:atr*MeanRevSL_ATR);if(slDist<=0)return;double tpR=engine==ENGINE_TREND?(UseAdaptiveTP&&regimeScore>=StrongTrendScore?StrongTrendTP_R:TrendTP_R):(engine==ENGINE_BREAKOUT?BreakoutTP_R:MeanRevTP_R);double sl=NPrice(type==ORDER_TYPE_BUY?entry-slDist:entry+slDist);double tp=NPrice(type==ORDER_TYPE_BUY?entry+slDist*tpR:entry-slDist*tpR);if(!StopOK(type,entry,sl))return;double risk=RiskFor(engine,atrRatio,quality);double lot=LotForRisk(type,entry,sl,risk);if(lot<=0)return;string tag=engine==ENGINE_TREND?"TREND":(engine==ENGINE_BREAKOUT?"BREAKOUT":"MEANREV");string c=CommentText+" "+tag;trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool ok=type==ORDER_TYPE_BUY?trade.Buy(lot,_Symbol,0,sl,tp,c):trade.Sell(lot,_Symbol,0,sl,tp,c);if(!ok){Print("XAU APEX V8 ORDER FAIL ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());return;}ulong ticket=trade.ResultOrder();if(ticket==0&&PositionSelect(_Symbol))ticket=(ulong)PositionGetInteger(POSITION_TICKET);SaveState(ticket,slDist,engine);Log("OPEN "+tag+" "+(dir==BUY_SIGNAL?"BUY":"SELL")+" Q="+DoubleToString(quality,1)+" RISK="+DoubleToString(risk,2)+"% ATRratio="+DoubleToString(atrRatio,2));}

void Manage(){if(!PositionSelect(_Symbol))return;if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)return;ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);double riskDist=LoadRisk(ticket);if(riskDist<=0){if(sl<=0)return;riskDist=MathAbs(open-sl);GlobalVariableSet(RKey(ticket),riskDist);}MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;double price=type==POSITION_TYPE_BUY?t.bid:t.ask;double move=type==POSITION_TYPE_BUY?price-open:open-price;double rNow=move/riskDist;datetime et=LoadEntryTime(ticket);EngineType engine=LoadEngine(ticket);if(et>0&&MaxBarsInTrade>0){int bars=(int)((TimeCurrent()-et)/PeriodSeconds(EntryTF));if(bars>=MaxBarsInTrade&&rNow<TimeStopMinR){trade.PositionClose(_Symbol,SlippagePoints);return;}}
   double atr;if(!Buf(hATR,0,1,atr))return;double ns=sl;bool change=false;if(move>=riskDist*BE_R){double be=NPrice(open);if((type==POSITION_TYPE_BUY&&(sl==0||be>sl))||(type==POSITION_TYPE_SELL&&(sl==0||be<sl))){ns=be;change=true;}}
   if(move>=riskDist*LockStart_R){double lock=NPrice(type==POSITION_TYPE_BUY?open+riskDist*Lock_R:open-riskDist*Lock_R);if((type==POSITION_TYPE_BUY&&lock>ns)||(type==POSITION_TYPE_SELL&&(ns==0||lock<ns))){ns=lock;change=true;}}
   if(move>=riskDist*TrailStart_R){double mult=engine==ENGINE_MEANREV?1.10:TrailATR;double tr=NPrice(type==POSITION_TYPE_BUY?price-atr*mult:price+atr*mult);if(type==POSITION_TYPE_BUY&&tr>ns&&tr<price){ns=tr;change=true;}if(type==POSITION_TYPE_SELL&&(ns==0||tr<ns)&&tr>price){ns=tr;change=true;}}
   if(!change)return;double md=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(type==POSITION_TYPE_BUY)ns=MathMin(ns,NPrice(price-md));else ns=MathMax(ns,NPrice(price+md));if(sl!=0&&MathAbs(ns-sl)<_Point)return;if(!trade.PositionModify(_Symbol,ns,tp))Log("MODIFY FAIL "+trade.ResultRetcodeDescription());}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result){if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)return;ulong deal=trans.deal;if(deal==0||!HistoryDealSelect(deal))return;if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=Magic)return;long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);if(entry!=DEAL_ENTRY_OUT&&entry!=DEAL_ENTRY_OUT_BY)return;double p=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);if(p<0){consecutiveLosses++;cooldownUntil=TimeCurrent()+CooldownMinutes*60;}else if(p>0)consecutiveLosses=0;if(trans.position>0)DeleteState(trans.position);}

int OnInit(){trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);hEFast=iMA(_Symbol,EntryTF,EntryFastEMA,0,MODE_EMA,PRICE_CLOSE);hESlow=iMA(_Symbol,EntryTF,EntrySlowEMA,0,MODE_EMA,PRICE_CLOSE);hRFast=iMA(_Symbol,RegimeTF,RegimeFastEMA,0,MODE_EMA,PRICE_CLOSE);hRSlow=iMA(_Symbol,RegimeTF,RegimeSlowEMA,0,MODE_EMA,PRICE_CLOSE);hADX=iADX(_Symbol,RegimeTF,RegimeADXPeriod);hATR=iATR(_Symbol,EntryTF,ATRPeriod);hRSI=iRSI(_Symbol,EntryTF,RSIPeriod,PRICE_CLOSE);hATRBase=iMA(_Symbol,EntryTF,ATRBaselinePeriod,0,MODE_SMA,PRICE_CLOSE);if(hEFast<0||hESlow<0||hRFast<0||hRSlow<0||hADX<0||hATR<0||hRSI<0||hATRBase<0){Print("XAU APEX V8 INIT FAILED: indicator handle");return INIT_FAILED;}peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);DailyReset();Print("XAU APEX V8 READY ",_Symbol);return INIT_SUCCEEDED;}

void OnDeinit(const int reason){if(hEFast>=0)IndicatorRelease(hEFast);if(hESlow>=0)IndicatorRelease(hESlow);if(hRFast>=0)IndicatorRelease(hRFast);if(hRSlow>=0)IndicatorRelease(hRSlow);if(hADX>=0)IndicatorRelease(hADX);if(hATR>=0)IndicatorRelease(hATR);if(hRSI>=0)IndicatorRelease(hRSI);if(hATRBase>=0)IndicatorRelease(hATRBase);}

void OnTick(){DailyReset();UpdatePeak();Manage();if(!NewBar())return;if(!SessionOK()||!SpreadOK()||RiskBlocked())return;if(OnePositionOnly&&Positions()>0)return;Direction signal;EngineType engine;double atr,atrRatio,quality;if(!GetSignal(signal,engine,atr,atrRatio,quality))return;if(signal==BUY_SIGNAL&&!AllowBuy)return;if(signal==SELL_SIGNAL&&!AllowSell)return;double rs,adx,plusDI,minusDI;Direction regime;if(!Regime(regime,atr,atrRatio,rs,adx,plusDI,minusDI))return;Enter(signal,engine,atr,atrRatio,quality,rs);}
