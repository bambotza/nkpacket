%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Connection Client Pool server
%% It resolves periodically the destinations and assign weights
%% When a pid is requested, one destination is selected randomly based on weight
%% We see if we are already at full pool capacity for that destination,
%% in that case one of the connections is selected randomly. If not,
%% a new connection is started
%% If we cannot connect to a destination, is marked as failed and retried later
%% @see nkpacket_httpc_pool for sample

-module(nkpacket_pool).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get_conn_pid/1, get_exclusive_pid/1, release_exclusive_pid/2]).
-export([start_link/2, get_status/1]).
-export([get_all/0, find/1]).
-export([conn_resolve_fun/3, conn_start_fun/1, conn_stop_fun/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-include("nkpacket.hrl").


-define(DEBUG(Txt, Args, State),
    case State#state.debug of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkPACKET Pool (~p) "++Txt, [State#state.id|Args])).

-define(NUM_TRIES, 2).
-define(INITIAL_DELAY_SECS, 5).    % Secs
-define(MAX_DELAY_SECS, 60).    % Secs

%% ===================================================================
%% Types
%% ===================================================================

-type conn_resolve_fun() ::
    fun((Target::map(), Config::map(), pid()) ->
        {ok, [#nkconn{}]} | {error, term()}).

-type conn_start_fun() :: fun((#nkconn{}) -> {ok, pid()} | {error, term()}).

-type conn_stop_fun() :: fun((pid()) -> ok).

-type id() :: term().

-type config() ::
    #{
        targets => [
            #{
                url => binary(),                    % Can resolve to multiple IPs
                opts => nkpacket:connect_opts(),    % Can include debug
                weigth => integer(),                % Shared weight for all IPs
                pool => integer                     % Connections to start
            }
        ],
        debug => boolean(),
        resolve_interval => integer(),               % Secs, 0 to avoid
        conn_resolve_fun => conn_resolve_fun(),
        conn_start_fun => conn_start_fun(),
        conn_stop_fun => conn_stop_fun()
    }.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec start_link(id(), config()) ->
    {ok, pid()} | {error, term()}.

start_link(Id, Config) ->
   gen_server:start_link(?MODULE, [Id, Config], []).


%% @private
get_conn_pid(P) ->
    gen_server:call(find(P), get_conn_pid).


%% @private
get_exclusive_pid(P) ->
    gen_server:call(find(P), {get_exclusive_pid, self()}).


%% @private
release_exclusive_pid(P, ConnPid) ->
    gen_server:cast(find(P), {release_exclusive_pid, ConnPid}).


%% @private
get_status(P) ->
    gen_server:call(find(P), get_status).


%% @private
get_all() ->
    nklib_proc:values(?MODULE).


%% @private
find(Pid) when is_pid(Pid) ->
    Pid;

find(Id) ->
    case nklib_proc:values({?MODULE, Id}) of
        [{_, Pid}] ->
            Pid;
        [] ->
            undefined
    end.

% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(conn_spec, {
    id :: conn_id(),
    nkconn :: #nkconn{},
    pool :: integer()
}).

-record(conn_status, {
    conn_pids = [] :: [pid()],
    status = active :: active | inactive,
    errors = 0 :: integer(),
    delay = 0 :: integer(),
    next_try = 0 :: nklib_util:timestamp()
}).

-type conn_id() :: {nkpacket:transport(), inet:ip_address(), inet:port_number()}.

-record(state, {
    id :: term(),
    config :: map(),
    conn_spec :: #{conn_id() => #conn_spec{}},
    conn_weight :: [{Start::integer(), Stop::integer(), conn_id()}],
    conn_status :: #{conn_id() => #conn_status{}},
    conn_pids2 :: #{pid() => {conn_id(), Mon::reference()|undefined}},
    conn_user_mons :: #{reference() => pid()},
    max_weight :: integer(),
    resolve_interval :: integer(),
    conn_resolve_fun :: conn_resolve_fun(),
    conn_start_fun :: conn_start_fun(),
    conn_stop_fun :: conn_start_fun(),
    debug :: boolean(),
    headers :: [{binary(), binary()}]
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([Id, Config]) ->
    State1 = #state{
        id = Id,
        config = Config,
        conn_spec = #{},
        conn_weight = [],
        conn_status = #{},
        conn_pids2 = #{},
        conn_user_mons = #{},
        debug = maps:get(debug, Config, false),
        headers = maps:get(headers, Config, []),
        resolve_interval = maps:get(resolve_interval, Config, 0),
        conn_resolve_fun = maps:get(conn_resolve_fun, Config, fun ?MODULE:conn_resolve_fun/3),
        conn_start_fun = maps:get(conn_start_fun, Config, fun ?MODULE:conn_start_fun/1),
        conn_stop_fun = maps:get(conn_stop_fun, Config, fun ?MODULE:conn_stop_fun/1)
    },
    process_flag(trap_exit, true),
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    self() ! launch_resolve,
    {ok, State1}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call(get_conn_pid, From, State) ->
    State2 = find_conn_pid(?NUM_TRIES, From, false, State),
    {noreply, State2};

handle_call({get_exclusive_pid, Pid}, From, State) ->
    State2 = find_conn_pid(?NUM_TRIES, From, {true, Pid}, State),
    {noreply, State2};

handle_call(get_status, _From, #state{conn_status=ConnStatus}=State) ->
    {reply, {ok, ConnStatus}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({release_exclusive_pid, ConnPid}, State) ->
    #state{conn_pids2=ConnPids, conn_user_mons=Mons} = State,
    case maps:find(ConnPid, ConnPids) of
        {ok, {ConnId, Mon}} when is_reference(Mon) ->
            ?DEBUG("releasing connection: ~p", [ConnId], State),
            demonitor(Mon),
            ConnPids2 = ConnPids#{ConnPid => {ConnId, undefined}},
            Mons2 = maps:remove(Mon, Mons),
            State2 = State#state{conn_pids2=ConnPids2, conn_user_mons=Mons2},
            {noreply, State2};
        _ ->
            ?LLOG(notice, "received release for invalid connection", [], State),
            {noreply, State}
    end;

handle_cast({retry_get_conn_pid, Tries, From, Exclusive}, State) when Tries > 0 ->
    ?DEBUG("retrying get pid (remaining tries:~p)", [Tries], State),
    State2 = find_conn_pid(Tries, From, Exclusive, State),
    {noreply, State2};

handle_cast({retry_get_conn_pid, _Tries, From, _Exclusive}, State) ->
    ?DEBUG("retrying get pid: too many retries", [], State),
    gen_server:reply(From, {error, no_connections}),
    {noreply, State};

 handle_cast({resolve_data, {Specs, Weights, Max}}, State) ->
    case Weights of
        [] ->
            ?LLOG(warning, "no connections spec", [], State);
        _ ->
            ?DEBUG("new resolved spec: ~p", [Specs], State),
            ?DEBUG("new resolved weights: ~p", [Weights], State),
            ok
    end,
    #state{resolve_interval=Time} = State,
    case Time > 0 of
        true ->
            erlang:send_after(Time*1000, self(), launch_resolve);
        false ->
            ok
    end,
    State2 = State#state{
        conn_spec = Specs,
        conn_weight = Weights,
        max_weight = Max
    },
    {noreply, State2};

handle_cast({new_connection_ok, ConnId, Pid, Tries, From, Exclusive}, State) ->
    {noreply, do_connect_ok(ConnId, Pid, Tries, From, Exclusive, State)};

handle_cast({new_connection_error, ConnId, Error, Tries, From, Exclusive}, State) ->
    {noreply, do_connect_error(ConnId, Error, Tries, From, Exclusive, State)};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(launch_resolve, #state{config=Config, conn_resolve_fun =Fun}=State) ->
    Self = self(),
    spawn_link(fun() -> resolve(Self, Fun, Config) end),
    {noreply, State};

handle_info({'EXIT', _Pid, normal}, State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, State) ->
    ?DEBUG("EXIT from ~p: ~p", [Pid, Reason], State),
    {noreply, State};

handle_info({'DOWN', Mon, process, Pid, Reason}=Msg, State) ->
    #state{conn_pids2=ConnPids, conn_user_mons=Mons, conn_status=ConnStatus} = State,
    case maps:take(Pid, ConnPids) of
        {{ConnId, UserMon}, ConnPids2} ->
            ?DEBUG("connection ~p down (~p)", [ConnId, Reason], State),
            Status1 = maps:get(ConnId, ConnStatus),
            #conn_status{conn_pids=Pids}= Status1,
            Status2 = Status1#conn_status{conn_pids=Pids -- [Pid]},
            ConnStatus2 = ConnStatus#{ConnId => Status2},
            Mons2 = case UserMon of
                undefined ->
                    Mons;
                _ ->
                    erlang:demonitor(UserMon),
                    maps:remove(UserMon, Mons)
            end,
            State2 = State#state{
                conn_pids2 = ConnPids2,
                conn_user_mons = Mons2,
                conn_status = ConnStatus2
            },
            {noreply, State2};
        error ->
            case maps:take(Mon, Mons) of
                {ConnPid, Mons2} ->
                    {ConnId, Mon} = maps:get(ConnPid, ConnPids),
                    ?DEBUG("user ~p down, releasing ~p", [Pid, ConnId], State),
                    ConnPids2 = ConnPids#{ConnPid => {ConnId, undefined}},
                    State2 = State#state{conn_pids2=ConnPids2, conn_user_mons=Mons2},
                    {noreply, State2};
                error ->
                    lager:warning("Module ~p received unexpected info: ~p (~p)",
                                  [?MODULE, Msg, State]),
                    {noreply, State}
            end
    end;

handle_info(Info, State) ->
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, #state{conn_pids2=ConnPids, conn_stop_fun=Fun}=State) ->
    Pids = maps:keys(ConnPids),
    ?DEBUG("stopping pids: ~p", [Pids], State),
    lists:foreach(fun(Pid) -> Fun(Pid) end, Pids),
    ok.



% ===================================================================
%% Internal
%% ===================================================================

%% @private
resolve(Pid, Fun, #{targets:=Targets}=Config) ->
    Data = do_resolve(Targets, Config, Pid, Fun, #{}, []),
    gen_server:cast(Pid, {resolve_data, Data}).


%% @private
do_resolve([], _Config, _Pid, _Fun, Specs, Weights) ->
    Max = case Weights of
        [{_Start, Stop, _}|_] ->
            Stop;
        [] ->
            0
    end,
    {Specs, lists:reverse(Weights), Max};

do_resolve([Target|Rest], Config, Pid, Fun, Specs, Weights) ->
    Pool = maps:get(pool, Target, 1),
    ConnList = case Fun(Target, Config, Pid) of
        {ok, ConnList0} ->
            ConnList0;
        {error, Error} ->
            lager:error("NKLOG Error resolving ~s: ~p", [Target, Error]),
            []
    end,
    Specs2 = lists:foldl(
        fun(#nkconn{transp=Transp, ip=Ip, port=Port}=NkConn, Acc) ->
            ConnId = {Transp, Ip, Port},
            ConnSpec = #conn_spec{id=ConnId, nkconn=NkConn, pool=Pool},
            Acc#{ConnId => ConnSpec}
        end,
        Specs,
        ConnList),
    Weights2 = case ConnList of
        [] ->
            Weights;
        _ ->
            GroupWeight = maps:get(weight, Target, 100),
            ConnWeight = GroupWeight div length(ConnList),
            lists:foldl(
                fun(#nkconn{transp=Transp, ip=Ip, port=Port}, Acc) ->
                    ConnId = {Transp, Ip, Port},
                    case Acc of
                        [] ->
                            [{1, ConnWeight, ConnId}];
                        [{_Start, Stop, _ConnId}|_] ->
                            [{Stop+1, Stop+ConnWeight, ConnId}|Acc]
                    end
                end,
                Weights,
                ConnList)
    end,
    do_resolve(Rest, Config, Pid, Fun, Specs2, Weights2).


%% @private
find_conn_pid(_Tries, From, _Exclusive, #state{conn_weight=[]}=State) ->
    gen_server:reply(From, {error, no_connections}),
    State;

find_conn_pid(Tries, From, Exclusive, State) ->
    #state{
        max_weight = Max,
        conn_spec = ConnSpec,
        conn_weight = Weights,
        conn_status = ConnStatus
    } = State,
    Pos = rand:uniform(Max),
    ConnId = do_find_conn(Pos, Weights),
    Spec = maps:get(ConnId, ConnSpec),
    #conn_spec{id=ConnId, pool=Pool} = Spec,
    ?DEBUG("selected weight ~p: ~p", [Pos, ConnId], State),
    case maps:find(ConnId, ConnStatus) of
        {ok, #conn_status{status=active, conn_pids=Pids}} ->
            case length(Pids) < Pool of
                true ->
                    % Slots still available
                    connect(Spec, Tries, From, Exclusive, State);
                false when Exclusive==false ->
                    ?DEBUG("selecting existing pid ~p: ~p", [Pos, ConnId], State),
                    gen_server:reply(From, {ok, do_get_pid(Pids)}),
                    State;
                false ->
                    % We reached all possible connections
                    case do_get_exclusive_pid(Pids, Exclusive, State) of
                        {ok, Pid, State2} ->
                            ?DEBUG("selecting and locking existing pid ~p: ~p",
                                   [Pos, ConnId], State),
                            gen_server:reply(From, {ok, Pid}),
                            State2;
                        false ->
                            ?DEBUG("max connections reached", [], State),
                            gen_server:reply(From, {error, max_connections_reached}),
                            State
                    end
            end;
        _ ->
            % If inactive or not yet created
            connect(Spec, Tries, From, Exclusive, State)
    end.


%% @private
connect(#conn_spec{id=ConnId, nkconn=Conn}, Tries, From, Exclusive, State) ->
    #state{conn_status=ConnStatus} = State,
    Status = maps:get(ConnId, ConnStatus, #conn_status{}),
    case Status of
        #conn_status{status=active} ->
            ?DEBUG("connecting to active: ~p (tries:~p)", [ConnId, Tries], State),
            spawn_connect(ConnId, Conn, Tries, From, Exclusive, State);
        #conn_status{status=inactive, next_try=Next} ->
            case Next - nklib_util:timestamp() of
                Time when Time < 0 ->
                    ?DEBUG("reconnecting to inactive: ~p", [ConnId], State),
                    spawn_connect(ConnId, Conn, Tries, From, Exclusive, State);
                Time ->
                    ?DEBUG("not yet time to recconnect to: ~p (~p secs remaining)",
                           [ConnId, Time], State),
                    retry(Tries, From, Exclusive)
            end
    end,
    ConnStatus2 = ConnStatus#{ConnId => Status},
    State#state{conn_status=ConnStatus2}.


%% @private
%% WARNING: if this process fails, From will never get a response!
%% if we receive an EXIT, it will fail silently
%% do we set process_flag? do we track it?
spawn_connect(ConnId, Conn, Tries, From, Exclusive, #state{conn_start_fun=Fun}) ->
    Self = self(),
    spawn_link(
        fun() ->
            Msg = case Fun(Conn) of
                {ok, Pid} ->
                    {new_connection_ok, ConnId, Pid, Tries, From, Exclusive};
                {error, Error} ->
                    {new_connection_error, ConnId, Error, Tries, From, Exclusive}
            end,
            gen_server:cast(Self, Msg)
        end).


%% @private
do_connect_ok(ConnId, Pid, Tries, From, Exclusive, State) ->
    #state{
        conn_spec = ConnSpec,
        conn_status = ConnStatus,
        conn_pids2 = ConnPids,
        conn_user_mons = Mons,
        conn_stop_fun = StopFun
    } = State,
    case maps:find(ConnId, ConnSpec) of
        {ok, #conn_spec{pool=Pool}} ->
            Status1 = maps:get(ConnId, ConnStatus),
            #conn_status{conn_pids=Pids} = Status1,
            case length(Pids) < Pool of
                true ->
                    % We still had some slot available
                    % Most backends will react to our exit and stop
                    link(Pid),
                    ?DEBUG("connected to ~p (~p) (~p/~p pids started)",
                        [ConnId, Pid, length(Pids)+1, Pool], State),
                    gen_server:reply(From, {ok, Pid}),
                    monitor(process, Pid),
                    Status2 = Status1#conn_status{
                        status = active,
                        conn_pids = [Pid|Pids],
                        errors = 0,
                        delay = 0
                    },
                    Mon = case Exclusive of
                        false ->
                            undefined;
                        {true, UserPid} ->
                            monitor(process, UserPid)
                    end,
                    Mons2 = case Mon of
                        undefined ->
                            Mons;
                        _ ->
                            Mons#{Mon => Pid}
                    end,
                    State#state{
                        conn_status = ConnStatus#{ConnId => Status2},
                        conn_pids2 = ConnPids#{Pid => {ConnId, Mon}},
                        conn_user_mons = Mons2
                    };
                false when Exclusive==false ->
                    % We started too much
                    ?DEBUG("selecting existing pid: ~p", [ConnId], State),
                    gen_server:reply(From, {ok, do_get_pid(Pids)}),
                    StopFun(Pid),
                    State;
                false ->
                    ?DEBUG("max connections reached", [], State),
                    gen_server:reply(From, {error, max_connections_reached}),
                    StopFun(Pid),
                    State
            end;
        error ->
            % It could have disappeared in new resolve
            retry(Tries, From, Exclusive),
            State
    end.


%% @private
do_connect_error(ConnId, Error, Tries, From, Exclusive, State) ->
    #state{conn_status = ConnStatus} = State,
    Status1 = maps:get(ConnId, ConnStatus),
    #conn_status{errors=Errors, delay=Delay} = Status1,
    Delay2 = case Delay of
        0 -> ?INITIAL_DELAY_SECS;
        _ -> min(2*Delay, ?MAX_DELAY_SECS)
    end,
    Status2 = Status1#conn_status{
        status = inactive,
        errors = Errors + 1,
        delay = Delay2,
        next_try = nklib_util:timestamp() + Delay2
    },
    ?LLOG(notice, "error connecting to ~p: ~p (~p errors, next try in ~p)",
          [ConnId, Error, Errors+1, Delay2], State),
    retry(Tries, From, Exclusive),
    State#state{conn_status = ConnStatus#{ConnId => Status2}}.


%% @private
do_find_conn(Pos, [{Min, Max, ConnSpec}|_]) when Pos >= Min, Pos =< Max ->
    ConnSpec;

do_find_conn(Pos, [_|Rest]) ->
    do_find_conn(Pos, Rest).


%% @private
do_get_pid([Pid]) ->
    Pid;
do_get_pid(Pids) ->
    lists:nth(rand:uniform(length(Pids)), Pids).


%% @private
do_get_exclusive_pid(Pids, {true, UserPid}, State) ->
    #state{conn_pids2=ConnPids, conn_user_mons=Mons} = State,
    Pids2 = lists:filter(
        fun(Pid) ->
            case maps:get(Pid, ConnPids) of
                {_ConnId, undefined} -> true;
                {_ConnId, _OldRef} -> false
            end
        end,
        Pids),
    case Pids2 of
        [] ->
            false;
        _ ->
            Pid = do_get_pid(Pids2),
            {ConnId, undefined} = maps:get(Pid, ConnPids),
            Mon = monitor(process, UserPid),
            State2 = State#state{
                conn_pids2 = ConnPids#{Pid => {ConnId, Mon}},
                conn_user_mons = Mons#{Mon => Pid}
            },
            {ok, Pid, State2}
    end.


%% @private
retry(Tries, From, Exclusive) ->
    gen_server:cast(self(), {retry_get_conn_pid, Tries-1, From, Exclusive}).


%% @private
conn_resolve_fun(#{url:=Url}=Target, _Config, Pid) ->
    Opts1 = maps:get(opts, Target, #{}),
    Opts2 = Opts1#{monitor => Pid},
    nkpacket_resolve:resolve(Url, Opts2).


%% @private
conn_start_fun(NkConn) ->
    nkpacket_transport:connect([NkConn]).


%% @private
conn_stop_fun(Pid) ->
    nkpacket_connection:stop(Pid).
