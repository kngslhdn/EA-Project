#property strict
#property version "7.10"
#property description "XAU APEX V7.1 - warning-free entry engine with true pullback/breakout and initial-R management"
#include <Trade/Trade.mqh>
CTrade trade;

enum Direction { NONE=0, BUY_SIGNAL=1, SELL_SIGNAL=-1 };
enum SetupType { SETUP_NONE=0, SETUP_PULLBACK=1, SETUP_BREAKOUT=2 };

//---------- CORE
input ENUM_TIMEFRAMES EntryTF=PERIOD_M15;
input ENUM_TIMEFRAMES RegimeTF=PERIOD_H1;
input ulong Magic=26081710;
input string CommentText="XAU APEX V7.1";
input bool AllowBuy=true;
input bool AllowSell=true;

//---------- REGIME
input int EntryFastEMA=20;
input int EntrySlowEMA=50;
input int RegimeFastEMA=50;
input int RegimeSlowEMA=200;
input int ADXPeriod=14;
input bool UseADX=true;
input double BuyADXMin=22.0;
input double SellADXMin=18.0;
input double BuyMinTrendScore=75.0;
input double SellMinTrendScore=65.0;
input double MinTrendSeparationATR=0.08;

//---------- VWAP / VOLATILITY
input bool UseSessionVWAP=true;
input int SessionStartHour=7;
input int SessionEndHour=22;
input double VWAPToleranceATR=0.30;
input int ATRPeriod=14;
input double ATRMin=0.80;
input double ATRMax=40.0;
input double ExhaustionATR=3.0;

//---------- ENTRY QUALITY
input bool EnablePullback=true;
input bool EnableBreakout=true;
input double PullbackTouchATR=0.12;
input double PullbackMaxDistanceATR=0.35;
input double BreakoutATR=0.15;
input double BreakoutMaxATR=0.80;
input double MinBodyFraction=0.50;
input double MinCloseLocation=0.65;
input bool RequireVWAPAlignment=true;
input bool RequireBreakoutVolume=true;
input double BreakoutVolumeFactor=1.05;

//---------- EXIT / INITIAL R
input double SL_ATR=1.60;
input double NormalTP_R=2.80;
input double StrongTP_R=3.60;
input double StrongTrendScore=85.0;
input double BE_R=1.00;
input double LockStart_R=1.50;
input double Lock_R=0.50;
input double TrailStart_R=2.00;
input double TrailATR=1.50;
input bool UseAdaptiveTP=true;

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

void Log(const string s){if(DebugMode)Print("XAU APEX V7.1 | ",s);}
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
bool SpreadOK(){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;return MaxSpreadPrice<=0||(t.ask-t.bid)<=MaxSpreadPrice;}
bool SessionVWAP(double &vwap){datetime now=TimeCurrent();MqlDateTime d;TimeToStruct(now,d);d.hour=SessionStartHour;d.min=0;d.sec=0;datetime from=StructToTime(d);if(now<from)from-=86400;MqlRates r[];int n=CopyRates(_Symbol,EntryTF,from,now,r);if(n<3)return false;double pv=0,vol=0;for(int i=0;i<n;i++){double tv=(double)r[i].tick_volume;double typical=(r[i].high+r[i].low+r[i].close)/3.0;pv+=typical*tv;vol+=tv;}if(vol<=0)return false;vwap=pv/vol;return true;}

bool Regime(Direction &dir,double &atr,double &score){double rf,rs,ef,es,adx;if(!Buf(hRFast,0,1,rf)||!Buf(hRSlow,0,1,rs)||!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es)||!Buf(hATR,0,1,atr)||!Buf(hADX,0,1,adx))return false;if(atr<ATRMin||atr>ATRMax)return false;double sep=MathAbs(rf-rs)/atr;if(sep<MinTrendSeparationATR)return false;double c=iClose(_Symbol,RegimeTF,1);if(c<=0)return false;double sepScore=MathMin(25.0,sep/0.25*25.0);double adxScore=MathMin(25.0,MathMax(0.0,(adx-10.0)/20.0*25.0));double emaScore=(rf!=rs)?25.0:0.0;double priceScore=0.0;if((rf>rs&&c>rf)||(rf<rs&&c<rf))priceScore=25.0;score=sepScore+adxScore+emaScore+priceScore;if(rf>rs&&c>rf&&adx>=BuyADXMin&&score>=BuyMinTrendScore){dir=BUY_SIGNAL;return true;}if(rf<rs&&c<rf&&adx>=SellADXMin&&score>=SellMinTrendScore){dir=SELL_SIGNAL;return true;}dir=NONE;return false;}

bool VolumeConfirm(const MqlRates &r[],const int count){if(count<6)return true;double avg=0;for(int i=2;i<6;i++)avg+=(double)r[i].tick_volume;avg/=4.0;if(avg<=0)return true;return (double)r[0].tick_volume>=avg*BreakoutVolumeFactor;}

Direction Signal(const Direction regime,const double atr,const double regimeScore,SetupType &setup){setup=SETUP_NONE;MqlRates r[];ArraySetAsSeries(r,true);if(CopyRates(_Symbol,EntryTF,1,8,r)<8){Log("BLOCK rates");return NONE;}double ef,es;if(!Buf(hEFast,0,1,ef)||!Buf(hESlow,0,1,es))return NONE;double vwap=0;if(UseSessionVWAP&&!SessionVWAP(vwap))return NONE;MqlRates s=r[0];double c=s.close,o=s.open,h=s.high,l=s.low,range=h-l,body=MathAbs(c-o);if(range<=0||range>atr*ExhaustionATR)return NONE;if(body/range<MinBodyFraction)return NONE;double closeLocation=(c-l)/range;if(regime==BUY_SIGNAL&&closeLocation<MinCloseLocation)return NONE;if(regime==SELL_SIGNAL&&closeLocation>(1.0-MinCloseLocation))return NONE;bool trend=regime==BUY_SIGNAL?(ef>es&&c>ef):(ef<es&&c<ef);if(!trend)return NONE;if(UseSessionVWAP&&RequireVWAPAlignment){double tol=atr*VWAPToleranceATR;if(regime==BUY_SIGNAL&&c<vwap-tol)return NONE;if(regime==SELL_SIGNAL&&c>vwap+tol)return NONE;}
if(regime==BUY_SIGNAL){double touch=atr*PullbackTouchATR,maxDist=atr*PullbackMaxDistanceATR;bool touched=l<=ef+touch&&l>=ef-maxDist;bool rejection=c>ef&&c>o&&closeLocation>=MinCloseLocation;bool pull=touched&&rejection;bool brk=c>r[1].high+atr*BreakoutATR&&c>ef&&c>o&&(c-r[1].high)<=atr*BreakoutMaxATR;if(EnablePullback&&pull){setup=SETUP_PULLBACK;Log("BUY TRUE PULLBACK score="+DoubleToString(regimeScore,1));return BUY_SIGNAL;}if(EnableBreakout&&brk&&(!RequireBreakoutVolume||VolumeConfirm(r,8))){setup=SETUP_BREAKOUT;Log("BUY BREAKOUT score="+DoubleToString(regimeScore,1));return BUY_SIGNAL;}}
else{double touch=atr*PullbackTouchATR,maxDist=atr*PullbackMaxDistanceATR;bool touched=h>=ef-touch&&h<=ef+maxDist;bool rejection=c<ef&&c<o&&closeLocation<=(1.0-MinCloseLocation);bool pull=touched&&rejection;bool brk=c<r[1].low-atr*BreakoutATR&&c<ef&&c<o&&(r[1].low-c)<=atr*BreakoutMaxATR;if(EnablePullback&&pull){setup=SETUP_PULLBACK;Log("SELL TRUE PULLBACK score="+DoubleToString(regimeScore,1));return SELL_SIGNAL;}if(EnableBreakout&&brk&&(!RequireBreakoutVolume||VolumeConfirm(r,8))){setup=SETUP_BREAKOUT;Log("SELL BREAKOUT score="+DoubleToString(regimeScore,1));return SELL_SIGNAL;}}return NONE;}

double LotForRisk(const ENUM_ORDER_TYPE type,const double entry,const double sl){double risk=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;if(risk<=0)return 0;double pnl;if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,pnl))return 0;double one=MathAbs(pnl);if(one<=0)return 0;return NVol(risk/one);}
bool StopOK(const ENUM_ORDER_TYPE type,const double entry,const double sl){double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(minDist<=0)return true;return type==ORDER_TYPE_BUY?entry-sl>=minDist:sl-entry>=minDist;}
string RKey(const ulong ticket){return "XAU_APEX_V7_1_R_"+(string)ticket;}
void SaveInitialRisk(const ulong ticket,const double r){if(ticket>0&&r>0)GlobalVariableSet(RKey(ticket),r);}
double LoadInitialRisk(const ulong ticket){if(ticket==0||!GlobalVariableCheck(RKey(ticket)))return 0;return GlobalVariableGet(RKey(ticket));}
void DeleteInitialRisk(const ulong ticket){if(ticket>0&&GlobalVariableCheck(RKey(ticket)))GlobalVariableDel(RKey(ticket));}

void Enter(const Direction dir,const double atr,const double regimeScore,const SetupType setup){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;ENUM_ORDER_TYPE type=dir==BUY_SIGNAL?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double entry=type==ORDER_TYPE_BUY?t.ask:t.bid;double sd=atr*SL_ATR;if(sd<=0)return;double tpR=UseAdaptiveTP&&regimeScore>=StrongTrendScore?StrongTP_R:NormalTP_R;double sl=NPrice(type==ORDER_TYPE_BUY?entry-sd:entry+sd);double tp=NPrice(type==ORDER_TYPE_BUY?entry+sd*tpR:entry-sd*tpR);if(!StopOK(type,entry,sl))return;double lot=LotForRisk(type,entry,sl);if(lot<=0)return;string c=CommentText+" "+(setup==SETUP_PULLBACK?"PULLBACK":"BREAKOUT");trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool ok=type==ORDER_TYPE_BUY?trade.Buy(lot,_Symbol,0,sl,tp,c):trade.Sell(lot,_Symbol,0,sl,tp,c);if(!ok){Print("XAU APEX V7.1 ORDER FAIL ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());return;}ulong ticket=trade.ResultOrder();if(ticket==0&&PositionSelect(_Symbol))ticket=(ulong)PositionGetInteger(POSITION_TICKET);SaveInitialRisk(ticket,sd);Log("OPEN "+(dir==BUY_SIGNAL?"BUY":"SELL")+" "+(setup==SETUP_PULLBACK?"PULLBACK":"BREAKOUT")+" score="+DoubleToString(regimeScore,1));}

void Manage(){if(!PositionSelect(_Symbol))return;if((ulong)PositionGetInteger(POSITION_MAGIC)!=Magic)return;ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);double riskDist=LoadInitialRisk(ticket);if(riskDist<=0){if(sl<=0)return;riskDist=MathAbs(open-sl);SaveInitialRisk(ticket,riskDist);}MqlTick t;if(!SymbolInfoTick(_Symbol,t))return;double price=type==POSITION_TYPE_BUY?t.bid:t.ask;double move=type==POSITION_TYPE_BUY?price-open:open-price;if(move<=0)return;double atr;if(!Buf(hATR,0,1,atr))return;double ns=sl;bool change=false;if(move>=riskDist*BE_R){double be=NPrice(open);if((type==POSITION_TYPE_BUY&&(sl==0||be>sl))||(type==POSITION_TYPE_SELL&&(sl==0||be<sl))){ns=be;change=true;}}if(move>=riskDist*LockStart_R){double lock=NPrice(type==POSITION_TYPE_BUY?open+riskDist*Lock_R:open-riskDist*Lock_R);if((type==POSITION_TYPE_BUY&&lock>ns)||(type==POSITION_TYPE_SELL&&(ns==0||lock<ns))){ns=lock;change=true;}}if(move>=riskDist*TrailStart_R){double tr=NPrice(type==POSITION_TYPE_BUY?price-atr*TrailATR:price+atr*TrailATR);if(type==POSITION_TYPE_BUY&&tr>ns&&tr<price){ns=tr;change=true;}if(type==POSITION_TYPE_SELL&&(ns==0||tr<ns)&&tr>price){ns=tr;change=true;}}if(!change)return;double md=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;if(type==POSITION_TYPE_BUY)ns=MathMin(ns,NPrice(price-md));else ns=MathMax(ns,NPrice(price+md));if(sl!=0&&MathAbs(ns-sl)<_Point)return;trade.PositionModify(_Symbol,ns,tp);}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result){if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)return;ulong deal=trans.deal;if(deal==0||!HistoryDealSelect(deal))return;if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol||(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=Magic)return;long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);if(entry!=DEAL_ENTRY_OUT&&entry!=DEAL_ENTRY_OUT_BY)return;double p=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);if(p<0){consecutiveLosses++;cooldownUntil=TimeCurrent()+CooldownMinutes*60;}else if(p>0)consecutiveLosses=0;if(trans.position>0)DeleteInitialRisk(trans.position);}

int OnInit(){trade.SetExpertMagicNumber(Magic);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);hEFast=iMA(_Symbol,EntryTF,EntryFastEMA,0,MODE_EMA,PRICE_CLOSE);hESlow=iMA(_Symbol,EntryTF,EntrySlowEMA,0,MODE_EMA,PRICE_CLOSE);hRFast=iMA(_Symbol,RegimeTF,RegimeFastEMA,0,MODE_EMA,PRICE_CLOSE);hRSlow=iMA(_Symbol,RegimeTF,RegimeSlowEMA,0,MODE_EMA,PRICE_CLOSE);hADX=iADX(_Symbol,RegimeTF,ADXPeriod);hATR=iATR(_Symbol,EntryTF,ATRPeriod);if(hEFast<0||hESlow<0||hRFast<0||hRSlow<0||hADX<0||hATR<0)return INIT_FAILED;peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);DailyReset();Print("XAU APEX V7.1 READY ",_Symbol);return INIT_SUCCEEDED;}
void OnDeinit(const int reason){if(hEFast>=0)IndicatorRelease(hEFast);if(hESlow>=0)IndicatorRelease(hESlow);if(hRFast>=0)IndicatorRelease(hRFast);if(hRSlow>=0)IndicatorRelease(hRSlow);if(hADX>=0)IndicatorRelease(hADX);if(hATR>=0)IndicatorRelease(hATR);}
void OnTick(){DailyReset();UpdatePeak();Manage();if(!NewBar())return;if(!SessionOK()||!SpreadOK()||RiskBlocked())return;if(OnePositionOnly&&Positions()>0)return;Direction regime;double atr,score;if(!Regime(regime,atr,score))return;if(regime==BUY_SIGNAL&&!AllowBuy)return;if(regime==SELL_SIGNAL&&!AllowSell)return;SetupType setup;Direction signal=Signal(regime,atr,score,setup);if(signal==NONE)return;if(signal==BUY_SIGNAL&&!AllowBuy)return;if(signal==SELL_SIGNAL&&!AllowSell)return;Enter(signal,atr,score,setup);}
