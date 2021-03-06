-module(blockchain_election).

-export([
         new_group/4,
         has_new_group/1,
         election_info/2
        ]).

-include("blockchain_vars.hrl").

new_group(Ledger, Hash, Size, Delay) ->
    case blockchain_ledger_v1:config(?election_version, Ledger) of
        {error, not_found} ->
            new_group_v1(Ledger, Hash, Size, Delay);
        {ok, N} when N >= 2 ->
            new_group_v2(Ledger, Hash, Size, Delay)
    end.

new_group_v1(Ledger, Hash, Size, Delay) ->
    Gateways0 = blockchain_ledger_v1:active_gateways(Ledger),

    {ok, OldGroup0} = blockchain_ledger_v1:consensus_members(Ledger),

    {ok, SelectPct} = blockchain_ledger_v1:config(?election_selection_pct, Ledger),

    OldLen = length(OldGroup0),
    {Remove, Replace} = determine_sizes(Size, OldLen, Delay, Ledger),

    {OldGroupScored, GatewaysScored} = score_dedup(OldGroup0, Gateways0, none, Ledger),

    lager:debug("scored old group: ~p scored gateways: ~p",
                [tup_to_animal(OldGroupScored), tup_to_animal(GatewaysScored)]),

    %% sort high to low to prioritize high-scoring gateways for selection
    Gateways = lists:reverse(lists:sort(GatewaysScored)),
    blockchain_utils:rand_from_hash(Hash),
    New = select(Gateways, Gateways, min(Replace, length(Gateways)), SelectPct, []),

    %% sort low to high to prioritize low scoring and down gateways
    %% for removal from the group
    OldGroup = lists:sort(OldGroupScored),
    Rem = OldGroup0 -- select(OldGroup, OldGroup, min(Remove, length(New)), SelectPct, []),
    Rem ++ New.

new_group_v2(Ledger, Hash, Size, Delay) ->
    Gateways0 = blockchain_ledger_v1:active_gateways(Ledger),

    {ok, OldGroup0} = blockchain_ledger_v1:consensus_members(Ledger),

    {ok, SelectPct} = blockchain_ledger_v1:config(?election_selection_pct, Ledger),
    {ok, RemovePct} = blockchain_ledger_v1:config(?election_removal_pct, Ledger),
    {ok, ClusterRes} = blockchain_ledger_v1:config(?election_cluster_res, Ledger),

    OldLen = length(OldGroup0),
    {Remove, Replace} = determine_sizes(Size, OldLen, Delay, Ledger),

    %% annotate with score while removing dupes
    {OldGroupScored, GatewaysScored} = score_dedup(OldGroup0, Gateways0, ClusterRes, Ledger),

    lager:debug("scored old group: ~p scored gateways: ~p",
                [tup_to_animal(OldGroupScored), tup_to_animal(GatewaysScored)]),

    %% get the locations of the current consensus group at a particular h3 resolution
    Locations = locations(ClusterRes, OldGroup0, Gateways0),

    %% sort high to low to prioritize high-scoring gateways for selection
    Gateways = lists:reverse(lists:sort(GatewaysScored)),
    blockchain_utils:rand_from_hash(Hash),
    New = select(Gateways, Gateways, min(Replace, length(Gateways)), SelectPct, [], Locations),

    %% sort low to high to prioritize low scoring and down gateways
    %% for removal from the group
    OldGroup = lists:sort(OldGroupScored),
    Rem = OldGroup0 -- select(OldGroup, OldGroup, min(Remove, length(New)), RemovePct, []),
    Rem ++ New.

determine_sizes(Size, OldLen, Delay, Ledger) ->
    {ok, ReplacementFactor} = blockchain_ledger_v1:config(?election_replacement_factor, Ledger),
    %% increase this to make removal more gradual, decrease to make it less so
    {ok, ReplacementSlope} = blockchain_ledger_v1:config(?election_replacement_slope, Ledger),
    {ok, Interval} = blockchain:config(?election_restart_interval, Ledger),
    case Size == OldLen of
        true ->
            MinSize = ((OldLen - 1) div 3) + 1, % smallest remainder we will allow
            BaseRemove =  floor(Size/ReplacementFactor), % initial remove size
            Removable = OldLen - MinSize - BaseRemove,
            %% use tanh to get a gradually increasing (but still clamped to 1) value for
            %% scaling the size of removal as delay increases
            %% vihu argues for the logistic function here, for better
            %% control, but tanh is simple
            AdditionalRemove = floor(Removable * math:tanh((Delay/Interval) / ReplacementSlope)),

            Remove = Replace = BaseRemove + AdditionalRemove;
        %% growing
        false when Size > OldLen ->
            Remove = 0,
            Replace = Size - OldLen;
        %% shrinking
        false ->
            Remove = OldLen - Size,
            Replace = 0
    end,
    {Remove, Replace}.

score_dedup(OldGroup0, Gateways0, ClusterRes, Ledger) ->
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    PoCInterval = blockchain_utils:challenge_interval(Ledger),

    maps:fold(
      fun(Addr, Gw, {Old, Candidates} = Acc) ->
              Last0 = last(blockchain_ledger_gateway_v2:last_poc_challenge(Gw)),
              Loc = location(ClusterRes, Gw),
              {_, _, Score} = blockchain_ledger_gateway_v2:score(Addr, Gw, Height, Ledger),
              Last = Height - Last0,
              Missing = Last > 3 * PoCInterval,
              case lists:member(Addr, OldGroup0) of
                  true ->
                      OldGw =
                          case Missing of
                              %% make sure that non-functioning
                              %% nodes sort first regardless of score
                              true ->
                                  {Score - 5, Loc, Addr};
                              _ ->
                                  {Score, Loc, Addr}
                          end,
                      {[OldGw | Old], Candidates};
                  _ ->
                      case Missing of
                          %% don't bother to add to the candidate list
                          true ->
                              Acc;
                          _ ->
                              {Old, [{Score, Loc, Addr} | Candidates]}
                      end
              end
      end,
      {[], []},
      Gateways0).

locations(Res, Group, Gws) ->
    GroupGws = maps:with(Group, Gws),
    maps:fold(
      fun(_Addr, Gw, Acc) ->
              P = location(Res, Gw),
              Acc#{P => true}
      end,
      #{},
      GroupGws).

%% for backwards compatibility, generate a location that can never match
location(none, _Gw) ->
    none;
location(Res, Gw) ->
    case blockchain_ledger_gateway_v2:location(Gw) of
        undefined ->
            no_location;
        Loc ->
            h3:parent(Loc, Res)
    end.

tup_to_animal(TL) ->
    lists:map(fun({Scr, _Loc, Addr}) ->
                      {Scr, blockchain_utils:addr2name(Addr)}
              end,
              TL).

last(undefined) ->
    0;
last(N) when is_integer(N) ->
    N.

select(Candidates, Gateways, Size, Pct, Acc) ->
    select(Candidates, Gateways, Size, Pct, Acc, no_loc).


select(_, [], _, _Pct, Acc, _Locs) ->
    lists:reverse(Acc);
select(_, _, 0, _Pct, Acc, _Locs) ->
    lists:reverse(Acc);
select([], Gateways, Size, Pct, Acc, Locs) ->
    select(Gateways, Gateways, Size, Pct, Acc, Locs);
select([{_Score, Loc, Gw} | Rest], Gateways, Size, Pct, Acc, Locs) ->
    case rand:uniform(100) of
        N when N =< Pct ->
            case Locs of
                no_loc ->
                    select(Rest, lists:keydelete(Gw, 3, Gateways), Size - 1, Pct, [Gw | Acc], Locs);
                _ ->
                    %% check if we already have a group member in this h3 hex
                    case maps:is_key(Loc, Locs) of
                        true ->
                            select(Rest, lists:keydelete(Gw, 3, Gateways), Size, Pct, Acc, Locs);
                        _ ->
                            select(Rest, lists:keydelete(Gw, 3, Gateways), Size - 1, Pct,
                                   [Gw | Acc], Locs#{Loc => true})
                    end
            end;
        _ ->
            select(Rest, Gateways, Size, Pct, Acc, Locs)
    end.

has_new_group(Txns) ->
    MyAddress = blockchain_swarm:pubkey_bin(),
    case lists:filter(fun(T) ->
                              %% TODO: ideally move to versionless types?
                              blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                      end, Txns) of
        [Txn] ->
            Height = blockchain_txn_consensus_group_v1:height(Txn),
            Delay = blockchain_txn_consensus_group_v1:delay(Txn),
            {true,
             lists:member(MyAddress, blockchain_txn_consensus_group_v1:members(Txn)),
             Txn,
             {Height, Delay}};
        [_|_] ->
            lists:foreach(fun(T) ->
                                  case blockchain_txn:type(T) == blockchain_txn_consensus_group_v1 of
                                      true ->
                                          lager:info("txn ~s", [blockchain_txn:print(T)]);
                                      _ -> ok
                                  end
                          end, Txns),
            error(duplicate_group_txn);
        [] ->
            false
    end.

election_info(Ledger, Chain) ->
    %% grab the current height and get the block.
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    {ok, Block} = blockchain:get_block(Height, Chain),

    %% get the election info
    {Epoch, StartHeight0} = blockchain_block_v1:election_info(Block),

    %% genesis block thinks that the start height is 0, but it is
    %% block 1, so force it.
    StartHeight = max(1, StartHeight0),

    %% get the election txn
    {ok, StartBlock} = blockchain:get_block(StartHeight, Chain),
    {ok, Txn} = get_election_txn(StartBlock),
    lager:debug("txn ~s", [blockchain_txn:print(Txn)]),
    ElectionHeight = blockchain_txn_consensus_group_v1:height(Txn),
    ElectionDelay = blockchain_txn_consensus_group_v1:delay(Txn),

    %% wrap it all up as a map

    #{
      epoch => Epoch,
      start_height => StartHeight,
      election_height => ElectionHeight,
      election_delay => ElectionDelay
     }.

get_election_txn(Block) ->
    Txns = blockchain_block:transactions(Block),
    case lists:filter(
           fun(T) ->
                   blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
           end, Txns) of
        [Txn] ->
            {ok, Txn};
        _ ->
            {error, no_group_txn}
    end.
