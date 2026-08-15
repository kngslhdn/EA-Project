#property strict
#property version "6.00"
#property description "XAU APEX V6 - regime + session VWAP + pullback/breakout engine with volatility-aware risk"
#include <Trade/Trade.mqh>
CTrade trade;

enum Direction { NONE=0, BUY_SIGNAL=1, SELL_SIGNAL=-1 };

//---------- CORE
input ENUM_TIMEFRAMES EntryTF=PERIOD_M15;
input ENUM_TIMEFRAMES RegimeTF=PERIOD_H1;
input ulong Magic=26081606;
input string CommentText="XAU APEX V6";
input bool AllowBuy=true;
input bool AllowSell=true;

//---------- TREND REGIME
input int EntryFastEMA=20;
input int EntrySlowEMA=50;
input int RegimeFastEMA=50;
input int RegimeSlowEMA=200;
input int ADXPeriod=14;
input double ADXMin=18.0;
input bool UseADX=true;
input double MinTrendSeparationATR=0.08;

//---------- SESSION VWAP
input bool UseSessionVWAP=true;
input int SessionStartHour=7;
input int SessionEndHour=22;
input double VWAPToleranceATR=0.35;

//---------- VOLATILITY
input int ATRPeriod=14;
input double ATRMin=0.80;
input double ATRMax=40.0;
input double ExhaustionATR=3.0;

//---------- ENTRY
input double PullbackATR=0.60;
input double BreakoutATR=0.05;
input bool EnablePullback=true;
input bool EnableBreakout=true;
input int SignalBars=2;
input double MinBodyFraction=0.45;

//---------- EXIT
input double SL_ATR=1.60;
input double TP_ATR=3.00;
input double BE_R=1.00;
input double LockStart_R=1.50;
input double Lock_R=0.50;
input double TrailStart_R=2.00;
input double TrailATR=1.50;

//---------- RISK
input double RiskPercent=0.50;
input double MaxDailyLossPercent=2.0;
input double MaxEquityDDPercent=10.0;
input int MaxTradesPerDay=4;
input int MaxConsecutiveLosses=3;
input int CooldownMinutes=45;
input bool OnePositionOnly=true;

//---------- EXECUTION
input double MaxSpreadPrice=1.50;
input int SlippagePoints=80;
input bool BlockFridayLate=true;
input int FridayStopHour=19;
input bool DebugMode=true;

int hEFast=-1,hESlow=-1,hRFast=-1,hRSlow=-1,hADX=-1,hATR=-1;
datetime lastBar=0,cooldownUntil=0;
double peakEquity=0.0;
int dayKey=-1,consecutiveLosses=0;

void Log(string s){if(DebugMode)Print("XAU APEX V6 | ",s);}
int VolDigits(){double s=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);int d=0;while(d<8&&MathAbs(s-MathRound(s))>1e-10){s*=10.0;d++;}return d;}
double NPrice(double p){return NormalizeDouble(p,_Digits);}
double NVol(double v){double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(mn<=0||mx<=0||st<=0)return 0;v=MathMax(mn,MathMin(mx,v));v=MathFloor(v/st+1e-9)*st;if(v<mn)v=mn;return NormalizeDouble(v,VolDigits());}
bool Buf(int h,int buffer,int shift,double &v){double a[1];if(h<0||CopyBuffer(h,buffer,shift,1,a)!=1)return false;v=a[0];return v!=EMPTY_VALUE;}
bool NewBar(){datetime t[1];if(CopyTime(_Symbol,EntryTF,0,1,t)!=1)return false;if(t[0]==lastBar)return false;lastBar=t[0];return true;}
int Day(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);return d.year*10000+d.mon*100+d.day;}
void DailyReset(){int d=Day();if(d!=dayKey){dayKey=d;consecutiveLosses=0;cooldownUntil=0;Log("NEW DAY");}}
int Positions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t&&PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==Magic)n++;}return n;}
void UpdatePeak(){double e=AccountInfoDouble(ACCOUNT_EQUITY);if(e>peakEquity)peakEquity=e;}

void DayWindow(datetime &a,datetime &b){MqlDateTime d;TimeToStruct(TimeCurrent(),d);d.hour=0;d.min=0;d.sec=0;a=StructToTime(d);b=TimeCurrent();}
double TodayPnL(){datetime a,b;DayWindow(a,b);if(!HistorySelect(a,b))return 0;double p=0;uint n=HistoryDealsTotal();for(uint i=0;i<n;i++){ulong t=HistoryDealGetTicket(i);if(!t)continue;if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=Magic)continue;long e=HistoryDealGetInteger(t,DEAL_ENTRY);if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY)p+=HistoryDealGetDouble(t,DEAL_PROFIT)+HistoryDealGetDouble(t,DEAL_SWAP)+HistoryDealGetDouble(t,DEAL_COMMISSION);}return p;}
int TradesToday(){datetime a,b;DayWindow(a,b);if(!HistorySelect(a,b))return 0;int n=0;uint total=HistoryDealsTotal();for(uint i=0;i<total;i++){ulong t=HistoryDealGetTicket(i);if(!t)continue;if(HistoryDealGetString(t,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(t,DEAL_MAGIC)!=Magic)continue;if(HistoryDealGetInteger(t,DEAL_ENTRY)==DEAL_ENTRY_IN)n++;}return n;}
bool RiskBlocked(){double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);if(bal<=0)return true;if(MaxDailyLossPercent>0&&TodayPnL()<=-bal*MaxDailyLossPercent/100.0){Log("BLOCK DAILY LOSS");return true;}if(MaxEquityDDPercent>0&&peakEquity>0&&(peakEquity-eq)>=peakEquity*MaxEquityDDPercent/100.0){Log("BLOCK EQUITY DD");return true;}if(MaxTradesPerDay>0&&TradesToday()>=MaxTradesPerDay){Log("BLOCK MAX TRADES");return true;}if(MaxConsecutiveLosses>0&&consecutiveLosses>=MaxConsecutiveLosses){Log("BLOCK CONSECUTIVE LOSSES");return true;}if(cooldownUntil>TimeCurrent())return true;return false;}
bool SessionOK(){MqlDateTime d;TimeToStruct(TimeCurrent(),d);if(d.day_of_week==0||d.day_of_week==6)return false;if(BlockFridayLate&&d.day_of_week==5&&d.hour>=FridayStopHour)return false;if(SessionStartHour==SessionEndHour)return true;if(SessionStartHour<SessionEndHour)return d.hour>=SessionStartHour&&d.hour<SessionEndHour;return d.hour>=SessionStartHour||d.hour<SessionEndHour;}
bool SpreadOK(){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;return MaxSpreadPrice<=0||(t.ask-t.bid)<=MaxSpreadPrice;}

bool SessionVWAP(double &vwap){datetime now=TimeCurrent();MqlDateTime d;TimeToStruct(now,d);d.hour=SessionStartHour;d.min=0;d.sec=0;datetime from=StructToTime(d);if(now<from)from-=86400;MqlRates r[];int n=CopyRates(_Symbol,EntryTF,from,now,r);if(n<3)return false;double pv=0,vol=0;for(int i=0;i<n;i++){double tv=(double)r[i].tick_volume;double typical=(r[i].high+r[i].low+r[i].close)/3.0;pv+=typical*tv;vol+=tv;}if(vol<=0)return false;vwap=pv/vol;return true;}

bool Regime(Direction &dir,double &atr){double rf,rs,ef,es,adx; if(!Buf(hRFast,0,1,rf)||!Buf(hRSlow,0,1,rs)||!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es)||!Buf(hATR,0,1,atr)||!Buf(hADX,0,1,adx))return false; if(atr<ATRMin||atr>ATRMax){Log("BLOCK ATR="+DoubleToString(atr,2));return false;}double sep=MathAbs(rf-rs)/atr;if(sep<MinTrendSeparationATR){Log("BLOCK weak regime sep="+DoubleToString(sep,2));return false;}if(UseADX&&adx<ADXMin){Log("BLOCK ADX="+DoubleToString(adx,1));return false;}double c=iClose(_Symbol,RegimeTF,1);if(c<=0)return false;if(rf>rs&&c>rf){dir=BUY_SIGNAL;return true;}if(rf<rs&&c<rf){dir=SELL_SIGNAL;return true;}dir=NONE;return false;}

Direction Signal(Direction regime,double atr){MqlRates r[4];if(CopyRates(_Symbol,EntryTF,1,4,r)!=4){Log("BLOCK rates");return NONE;}double ef,es;if(!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es))return NONE;double vwap=0;if(UseSessionVWAP&&!SessionVWAP(vwap)){Log("BLOCK VWAP");return NONE;}double c=r[0].close,o=r[0].open,h=r[0].high,l=r[0].low,prevH=r[1].high,prevL=r[1].low,range=h-l,body=MathAbs(c-o);if(range<=0||range>atr*ExhaustionATR){Log("BLOCK candle range");return NONE;}if(body/range<MinBodyFraction)return NONE;
bool sideOK=true;if(UseSessionVWAP){double tol=atr*VWAPToleranceATR;if(regime==BUY_SIGNAL)sideOK=c>=vwap-tol;else sideOK=c<=vwap+tol;}
bool trend=regime==BUY_SIGNAL?(ef>es&&c>ef):(ef<es&&c<ef);if(!trend||!sideOK)return NONE;
bool pull=false,brk=false;if(regime==BUY_SIGNAL){pull=l<=ef+atr*PullbackATR&&c>ef&&c>o;brk=c>prevH+atr*BreakoutATR&&c>ef&&c>o;}else{pull=h>=ef-atr*PullbackATR&&c<ef&&c<o;brk=c<prevL-atr*BreakoutATR&&c<ef&&c<o;}
if(EnablePullback&&pull){Log(regime==BUY_SIGNAL?"BUY PULLBACK":"SELL PULLBACK");return regime;}if(EnableBreakout&&brk){Log(regime==BUY_SIGNAL?"BUY BREAKOUT":"SELL BREAKOUT");return regime;}return NONE;}

double LotForRisk(ENUM_ORDER_TYPE type,double entry,double sl){double risk=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;if(risk<=0)return 0;double pnl;if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,pnl))return 0;double one=MathAbs(pnl);if(one<=0)return 0;return NVol(risk/one);}
bool StopOK(ENUM_ORDER_TYPE type,double entry,double sl){double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(minDist<=0)return true;return type==ORDER_TYPE_BUY?entry-sl>=minDist:sl-entry>=minDist;}
void Enter(Direction dir,double atr){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;ENUM_ORDER_TYPE type=dir==BUY_SIGNAL?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double entry=type==ORDER_TYPE_BUY?t.ask:t.bid;double sd=atr*SL_ATR,td=atr*TP_ATR;if(sd<=0||td<=sd)return;double sl=NPrice(type==ORDER_TYPE_BUY?entry-sd:entry+sd);double tp=NPrice(type==ORDER_TYPE_BUY?entry+td:entry-td);if(!StopOK(type,entry,sl)){Log("BLOCK stop");return;}double lot=LotForRisk(type,entry,sl);if(lot<=0){Log("BLOCK lot");return;}trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool ok=type==ORDER_TYPE_BUY?trade.Buy(lot,_Symbol,0,sl,tp,CommentText):trade.Sell(lot,_Symbol,0,sl,tp,CommentText);if(!ok)Print("XAU APEX V6 ORDER FAIL ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());else Print("XAU APEX V6 OPEN ",dir==BUY_SIGNAL?"BUY":"SELL"," lot=",DoubleToString(lot,VolDigits())," SL=",DoubleToString(sl,_Digits)," TP=",DoubleToString(tp,_Digits));}

void Manage(){if(!PositionSelect(_Symbol))return;if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)return;ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),atr;if(!Buf(hATR,0,1,atr))return;MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;double price=type==POSITION_TYPE_BUY?t.bid:t.ask;double riskDist=atr*SL_ATR;double move=type==POSITION_TYPE_BUY?price-open:open-price;if(move<=0)return;double ns=sl;bool change=false;if(move>=riskDist*BE_R){double be=NPrice(open);if((type==POSITION_TYPE_BUY&&(sl==0||be>sl))||(type==POSITION_TYPE_SELL&&(sl==0||be<sl))){ns=be;change=true;}}if(move>=riskDist*LockStart_R){double lock=NPrice(type==POSITION_TYPE_BUY?open+riskDist*Lock_R:open-riskDist*Lock_R);if((type==POSITION_TYPE_BUY&&(lock>ns))||(type==POSITION_TYPE_SELL&&(ns==0||lock<ns))){ns=lock;change=true;}}if(move>=riskDist*TrailStart_R){double tr=NPrice(type==POSITION_TYPE_BUY?price-atr*TrailATR:price+atr*TrailATR);if(type==POSITION_TYPE_BUY&&tr>ns&&tr<price){ns=tr;change=true;}if(type==POSITION_TYPE_SELL&&(ns==0||tr<ns)&&tr>price){ns=tr;change=true;}}if(!change)return;double md=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(type==POSITION_TYPE_BUY)ns=MathMin(ns,NPrice(price-md));else ns=MathMax(ns,NPrice(price+md));if(sl!=0&&MathAbs(ns-sl)<_Point)return;trade.PositionModify(_Symbol,ns,tp);}

int OnInit(){trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);hEFast=iMA(_Symbol,EntryTF,EntryFastEMA,0,MODE_EMA,PRICE_CLOSE);hESlow=iMA(_Symbol,EntryTF,EntrySlowEMA,0,MODE_EMA,PRICE_CLOSE);hRFast=iMA(_Symbol,RegimeTF,RegimeFastEMA,0,MODE_EMA,PRICE_CLOSE);hRSlow=iMA(_Symbol,RegimeTF,RegimeSlowEMA,0,MODE_EMA,PRICE_CLOSE);hADX=iADX(_Symbol,RegimeTF,ADXPeriod);hATR=iATR(_Symbol,EntryTF,ATRPeriod);if(hEFast<0||hESlow<0||hRFast<0||hRSlow<0||hADX<0||hATR<0)return INIT_FAILED;peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);DailyReset();Print("XAU APEX V6 READY ",_Symbol);return INIT_SUCCEEDED;}
void OnDeinit(const int reason){if(hEFast>=0)IndicatorRelease(hEFast);if(hESlow>=0)IndicatorRelease(hESlow);if(hRFast>=0)IndicatorRelease(hRFast);if(hRSlow>=0)IndicatorRelease(hRSlow);if(hADX>=0)IndicatorRelease(hADX);if(hATR>=0)IndicatorRelease(hATR);}
void OnTick(){DailyReset();UpdatePeak();Manage();if(!NewBar())return;if(!SessionOK()||!SpreadOK()||RiskBlocked())return;if(OnePositionOnly&&Positions()>0)return;Direction regime;double atr;if(!Regime(regime,atr))return;if(regime==BUY_SIGNAL&&!AllowBuy)return;if(regime==SELL_SIGNAL&&!AllowSell)return;Direction sig=Signal(regime,atr);if(sig!=NONE)Enter(sig,atr);}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res){if(trans.type!=TRADE_TRANSACTION_DEAL_ADD||trans.deal==0)return;ulong d=trans.deal;if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(d,DEAL_MAGIC)!=Magic)return;long e=HistoryDealGetInteger(d,DEAL_ENTRY);if(e==DEAL_ENTRY_OUT||e==DEAL_ENTRY_OUT_BY){double p=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);if(p<0){consecutiveLosses++;cooldownUntil=TimeCurrent()+CooldownMinutes*60;}else if(p>0){consecutiveLosses=0;cooldownUntil=TimeCurrent()+900;}}}
