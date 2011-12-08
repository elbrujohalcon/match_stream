%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @copyright (C) 2011 Inaka Labs SRL
%%% @doc Match Stream Database Reader.
%%% It uses a Redis backend.
%%% @end
%%%-------------------------------------------------------------------
-module(match_stream_db_reader).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').

-behaviour(gen_server).

-include("match_stream.hrl").

-define(REDIS_CONNECTIONS, 10).

-record(state, {redis :: [pid()]}).
-opaque state() :: #state{}.

-export([start_link/0, make_call/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% =================================================================================================
%% Internal (i.e. used only by other modules) functions
%% =================================================================================================
%% @hidden
-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @hidden
-spec make_call(tuple()) -> term().
make_call(Call) ->
  case gen_server:call(?MODULE, Call) of
    {ok, Result} -> Result;
    {throw, Exception} -> throw(Exception)
  end.

%% =================================================================================================
%% Server functions
%% =================================================================================================
%% @hidden
-spec init([]) -> {ok, state()}.
init([]) ->
  Host = case application:get_env(erldis, host) of
           {ok, H} -> H;
           undefined -> "localhost"
         end,
  Port = case application:get_env(erldis, port) of
           {ok, P} -> P;
           undefined -> 6379
         end,
  Timeout = case application:get_env(erldis, timeout) of
              {ok, T} -> T;
              undefined -> 500
            end,
  Redis =
    lists:map(
      fun(_) ->
              {ok, Conn} =
                case {application:get_env(redis_pwd), application:get_env(redis_db)} of
                  {undefined, undefined} ->
                    erldis_client:start_link();
                  {undefined, {ok, Db}} ->
                    erldis_client:start_link(Db);
                  {{ok, Pwd}, undefined} ->
                    erldis_client:start_link(Host, Port, Pwd);
                  {{ok, Pwd}, {ok, Db}} ->
                    erldis_client:start_link(Host, Port, Pwd, [{timeout, Timeout}], Db)
                end,
              Conn
      end, lists:seq(1, ?REDIS_CONNECTIONS)),
  ?INFO("Database reader initialized~n", []),
  {ok, #state{redis = Redis}}.

%% @hidden
-spec handle_call(tuple(), reference(), state()) -> {noreply, state()}.
handle_call(Request, From, State) ->
  [RedisConn|Redis] = lists:reverse(State#state.redis),
  proc_lib:spawn_link(
    fun() ->
            Res =
              try handle_call(Request, RedisConn) of
                ok -> ok;
                Result -> {ok, Result}
              catch
                throw:Error ->
                  {throw, Error}
              end,
            gen_server:reply(From, Res)
    end),
  {noreply, State#state{redis = [RedisConn|lists:reverse(Redis)]}}.

%% @hidden
-spec handle_cast(_, state()) -> {noreply, state()}.
handle_cast(_, State) -> {noreply, State}.

%% @hidden
-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_, State) -> {noreply, State}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_, _) -> ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% =================================================================================================
%% Private functions
%% =================================================================================================
-spec handle_call(term(), pid()) -> term().
handle_call({all, Prefix}, RedisConn) ->
  PrefixLength = length(Prefix) - 1,
  Res =
    case erldis:keys(RedisConn, Prefix) of
      [] -> [];
      [Bin1] -> binary:split(Bin1, <<" ">>, [global, trim]);
      Ids -> Ids
    end,
  lists:map(fun(<<_:PrefixLength/binary, MatchId/binary>>) -> MatchId end, Res);
handle_call({match_history, MatchId}, RedisConn) ->
  Keys =
    case erldis:keys(RedisConn, "event-" ++ binary_to_list(MatchId) ++ "-*") of
      [] -> [];
      [Bin1] -> binary:split(Bin1, <<" ">>, [global, trim]);
      Ids -> Ids
    end,
  lists:keysort(
    #match_stream_event.timestamp,
    lists:foldl(
      fun(Key, Acc) ->
              case erldis:get(RedisConn, Key) of
                nil -> Acc;
                Bin -> [erlang:binary_to_term(Bin)|Acc]
              end
      end, [], Keys));
handle_call({get, Key}, RedisConn) ->
  case erldis:get(RedisConn, Key) of
    nil -> not_found;
    MatchBin -> erlang:binary_to_term(MatchBin)
  end.