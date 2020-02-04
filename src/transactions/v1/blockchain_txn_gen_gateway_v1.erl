%%%-------------------------------------------------------------------
%% @doc
%% == Blockchain Transaction Genesis Gateway ==
%% @end
%%%-------------------------------------------------------------------
-module(blockchain_txn_gen_gateway_v1).

-behavior(blockchain_txn).

-include("blockchain_utils.hrl").
-include_lib("helium_proto/src/pb/blockchain_txn_gen_gateway_v1_pb.hrl").

-export([
    new/4,
    hash/1,
    sign/2,
    gateway/1,
    owner/1,
    location/1,
    nonce/1,
    fee/1,
    is_valid/2,
    absorb/2,
    print/1,
    absorbed/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type txn_genesis_gateway() :: #blockchain_txn_gen_gateway_v1_pb{}.
-export_type([txn_genesis_gateway/0]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec new(Gateway :: libp2p_crypto:pubkey_bin(),
          Owner :: libp2p_crypto:pubkey_bin(),
          Location :: undefined | h3:h3index(),
          Nonce :: non_neg_integer()) -> txn_genesis_gateway().
new(Gateway, Owner, Location, Nonce) ->
    L = case Location of
            undefined -> undefined;
            _ -> h3:to_string(Location)
        end,
    #blockchain_txn_gen_gateway_v1_pb{gateway=Gateway,
                                      owner=Owner,
                                      location=L,
                                      nonce=Nonce}.


%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec hash(txn_genesis_gateway()) -> blockchain_txn:hash().
hash(Txn) ->
    EncodedTxn = blockchain_txn_gen_gateway_v1_pb:encode_msg(Txn),
    crypto:hash(sha256, EncodedTxn).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec sign(txn_genesis_gateway(), libp2p_crypto:sig_fun()) -> txn_genesis_gateway().
sign(Txn, _SigFun) ->
    Txn.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec gateway(txn_genesis_gateway()) -> libp2p_crypto:pubkey_bin().
gateway(Txn) ->
    Txn#blockchain_txn_gen_gateway_v1_pb.gateway.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec owner(txn_genesis_gateway()) -> libp2p_crypto:pubkey_bin().
owner(Txn) ->
    Txn#blockchain_txn_gen_gateway_v1_pb.owner.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec location(txn_genesis_gateway()) -> h3:h3index().
location(#blockchain_txn_gen_gateway_v1_pb{location=[]}) ->
    undefined;
location(Txn) ->
    h3:from_string(Txn#blockchain_txn_gen_gateway_v1_pb.location).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec nonce(txn_genesis_gateway()) -> non_neg_integer().
nonce(Txn) ->
    Txn#blockchain_txn_gen_gateway_v1_pb.nonce.


%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec fee(txn_genesis_gateway()) -> non_neg_integer().
fee(_Txn) ->
    0.

%%--------------------------------------------------------------------
%% @doc
%% This transaction should only be absorbed when it's in the genesis block
%% @end
%%--------------------------------------------------------------------
-spec is_valid(txn_genesis_gateway(), blockchain:blockchain()) -> ok | {error, any()}.
is_valid(_Txn, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:current_height(Ledger) of
        {ok, 0} ->
            ok;
        _ ->
            {error, not_in_genesis_block}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec absorb(txn_genesis_gateway(), blockchain:blockchain()) -> ok | {error, not_in_genesis_block}.
absorb(Txn, Chain) ->
    Ledger = blockchain:ledger(Chain),
    Gateway = ?MODULE:gateway(Txn),
    Owner = ?MODULE:owner(Txn),
    Location = ?MODULE:location(Txn),
    Nonce = ?MODULE:nonce(Txn),
    blockchain_ledger_v1:add_gateway(Owner,
                                     Gateway,
                                     Location,
                                     Nonce,
                                     Ledger).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec print(txn_genesis_gateway()) -> iodata().
print(undefined) -> <<"type=genesis_gateway, undefined">>;
print(#blockchain_txn_gen_gateway_v1_pb{
         gateway=Gateway, owner=Owner,
         location=L, nonce=Nonce}) ->
    io_lib:format("type=genesis_gateway gateway=~p, owner=~p, location=~p, nonce=~p",
                  [?TO_ANIMAL_NAME(Gateway), ?TO_B58(Owner), L, Nonce]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec absorbed(txn_genesis_gateway(), blockchain:blockchain()) -> true | false.
absorbed(Txn, Chain)->
    Ledger = blockchain:ledger(Chain),
    GatewayAddress = ?MODULE:gateway(Txn),
    case blockchain_ledger_v1:find_gateway_info(GatewayAddress, Ledger) of
        {ok, GW} ->
            TxnNonce = ?MODULE:nonce(Txn),
            blockchain_ledger_gateway_v2:nonce(GW) >= TxnNonce;
        _ ->
            false
    end.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

-define(TEST_LOCATION, 631210968840687103).

new_test() ->
    Tx = #blockchain_txn_gen_gateway_v1_pb{gateway = <<"0">>,
                                           owner = <<"1">>,
                                           location = h3:to_string(?TEST_LOCATION),
                                           nonce=10},
    ?assertEqual(Tx, new(<<"0">>, <<"1">>, ?TEST_LOCATION, 10)).

gateway_test() ->
    Tx = new(<<"0">>, <<"1">>, ?TEST_LOCATION, 10),
    ?assertEqual(<<"0">>, gateway(Tx)).

owner_test() ->
    Tx = new(<<"0">>, <<"1">>, ?TEST_LOCATION, 10),
    ?assertEqual(<<"1">>, owner(Tx)).

location_test() ->
    Tx = new(<<"0">>, <<"1">>, ?TEST_LOCATION, 10),
    ?assertEqual(?TEST_LOCATION, location(Tx)).

nonce_test() ->
    Tx = new(<<"0">>, <<"1">>, ?TEST_LOCATION, 10),
    ?assertEqual(10, nonce(Tx)).

-endif.
