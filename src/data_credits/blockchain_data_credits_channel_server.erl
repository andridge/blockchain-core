%%%-------------------------------------------------------------------
%% @doc
%% == Blockchain Data Credits Channel Server ==
%% @end
%%%-------------------------------------------------------------------
-module(blockchain_data_credits_channel_server).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1,
    credits/1,
    payment_req/3
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("blockchain.hrl").
-include("pb/blockchain_data_credits_pb.hrl").

-define(SERVER, ?MODULE).

-record(state, {
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    keys :: libp2p_crypto:key_map(),
    credits = 0 :: non_neg_integer()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start(Args) ->
    gen_server:start(?SERVER, Args, []).

credits(Pid) ->
    gen_statem:call(Pid, credits).

payment_req(Pid, Payee, Amount) ->
    gen_statem:cast(Pid, {payment_req, Payee, Amount}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([DB, CF, Keys, Credits]=Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    {ok, #state{
        db=DB,
        cf=CF,
        keys=Keys,
        credits=Credits
    }}.

handle_call(credits, _From, #state{credits=Credits}=State) ->
    {reply, {ok, Credits}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({payment_req, Payee, Amount}, #state{db=DB, cf=CF, keys=#{secret := PrivKey, public := PubKey},
                                                 credits=Credits}=State) ->
    % TODO: Broadcast this
    Payment0 = #blockchain_data_credits_payment_pb{
        key=libp2p_crypto:pubkey_to_bin(PubKey) ,
        payer=blockchain_swarm:pubkey_bin(),
        payee=Payee,
        amount=Amount
    },
    EncodedPayment0 = blockchain_data_credits_pb:encode_msg(Payment0),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Signature = SigFun(EncodedPayment0),
    Payment1 = Payment0#blockchain_data_credits_payment_pb{signature=Signature},
    EncodedPayment1 = blockchain_data_credits_pb:encode_msg(Payment1),
    ok = rocksdb:put(DB, CF, Signature, EncodedPayment1, []),
    lager:info("got payment request from ~p for ~p (leftover: ~p)", [Payee, Amount, Credits-Amount]),
    {noreply, State#state{credits=Credits-Amount}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------