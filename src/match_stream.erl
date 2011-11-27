%%-------------------------------------------------------------------
%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%% @copyright (C) 2011 InakaLabs SRL
%% @doc Match Stream main interface
%% @end
%%-------------------------------------------------------------------
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
-module(match_stream).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').
-vsn('0.1').

-behaviour(application).

-include("match_stream.hrl").

-export([start/0, stop/0]).
-export([start/2, stop/1]).
-export([new_match/3, cancel_match/3, register_event/5, cancel_match/1, register_event/3,
         matches/0, history/1, history/3, match/1]).
-export([timestamp/0]).

-type date() :: {2000..3000, 1..12, 1..31}.
-type time() :: {0..23, 0..59, 0..59}.
-type datetime() :: {date(), time()}.
-type team() :: binary().
-type match_id() :: binary().
-type user_id() :: binary().
-type event_kind() :: status | start | stop | halftime_start | halftime_stop | extratime |
                      shot | save | goal | corner | goalkick |
                      offside | foul | penalty | freekick | card |
                      substitution | throwin.
-type event() :: #match_stream_event{}.
-type player() :: {pos_integer(), binary()}. %% Number and name
-type match() :: #match_stream_match{}.
-type user() :: #match_stream_user{}.
-type period() :: not_started | first | last | halftime | first_extra | halftime_extra | last_extra | ended.

-type data() :: {home,            team()} |
                {home_players,    [player()]} |
                {home_score,      non_neg_integer()} |
                {visit,           team()} |
                {visit_players,   [player()]} |
                {visit_score,     non_neg_integer()} |
                {period,          period()} |
                {start_time,      datetime()} |
                {team,            team()} |
                {player_team,     team()} |
                {player,          player()} |
                {player_out,      player()} |
                {player_in,       player()} |
                {card,            red | yellow} |
                {comment,         binary()}.

-export_type([team/0, match_id/0, user_id/0, event_kind/0, event/0, player/0, data/0, match/0, user/0,
              datetime/0, date/0, period/0]).

%%-------------------------------------------------------------------
%% ADMIN API
%%-------------------------------------------------------------------
%% @doc Starts the application
-spec start() -> ok | {error, {already_started, match_stream}}.
start() ->
  _ = application:start(public_key),
  _ = application:start(ssl),
  application:start(?MODULE).

%% @doc Stops the application
-spec stop() -> ok.
stop() -> application:stop(?MODULE).

%%-------------------------------------------------------------------
%% SERVER API
%%-------------------------------------------------------------------
%% @doc Registers a match.
%%      StartDate is expected to be an UTC datetime
-spec new_match(team(), team(), date()) -> {ok, match_id()} | {error, {duplicated, match_id()}}.
new_match(Home, Visit, StartDate) ->
  MatchId = build_id(Home, Visit, StartDate),
  try match_stream_db:create(
        #match_stream_match{match_id  = MatchId,
                            home      = Home,
                            visit     = Visit,
                            start_time= StartDate}) of
    ok -> {ok, MatchId}
  catch
    _:duplicated ->
      {error, {duplicated, MatchId}}
  end.

%% @doc Cancels a match
-spec cancel_match(team(), team(), date()) -> ok.
cancel_match(Home, Visit, StartDate) ->
  cancel_match(build_id(Home, Visit, StartDate)).

%% @doc Cancels a match
-spec cancel_match(match_id()) -> ok.
cancel_match(MatchId) ->
  match_stream_match_sup:stop_match(MatchId),
  match_stream_db:match_delete(MatchId).

%% @doc Something happened in a match
-spec register_event(team(), team(), date(), event_kind(), [{atom(), binary()}]) -> ok.
register_event(Home, Visit, StartDate, Kind, Data) ->
  register_event(build_id(Home, Visit, StartDate), Kind, Data).

%% @doc Something happened in a match
-spec register_event(match_id(), event_kind(), [{atom(), binary()}]) -> ok.
register_event(MatchId, Kind, Data) ->
  Event = #match_stream_event{timestamp = timestamp(),
                              match_id  = MatchId,
                              kind      = Kind,
                              data      = Data},
  match_stream_match:apply(Event).

%% @doc List of available matches
-spec matches() -> [match_id()].
matches() ->
  match_stream_db:match_all().

%% @doc List of available matches
-spec match(match_id()) -> not_found | match_stream:match().
match(MatchId) ->
  match_stream_db:match(MatchId).

%% @doc List of match events
-spec history(match_id()) -> [event()].
history(MatchId) ->
  match_stream_db:match_history(MatchId).

%% @doc List of match events
-spec history(team(), team(), date()) -> [event()].
history(Home, Visit, StartDate) ->
  history(build_id(Home, Visit, StartDate)).

%% @doc now in milliseconds
-spec timestamp() -> pos_integer().
timestamp() ->
  {_, _, MicroSecs} = erlang:now(),
  Millis = erlang:trunc(MicroSecs/1000),
  calendar:datetime_to_gregorian_seconds(
    calendar:universal_time()) * 1000 + Millis.

%%-------------------------------------------------------------------
%% BEHAVIOUR CALLBACKS
%%-------------------------------------------------------------------
%% @private
-spec start(any(), any()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
  match_stream_sup:start_link().

%% @private
-spec stop(any()) -> ok.
stop(_State) -> ok.

%% @private
-spec build_id(team(), team(), date()) -> match_id().
build_id(Home, Visit, {Year, Month, Day}) ->
  <<Home/binary, $-, Visit/binary, $-,
    (to_binary(Year))/binary, $-,
    (to_binary(Month))/binary, $-,
    (to_binary(Day))/binary>>.

-spec to_binary(pos_integer()) -> binary().
to_binary(Number) when Number < 10 ->
  <<$0, (list_to_binary(integer_to_list(Number)))/binary>>;
to_binary(Number) ->
  list_to_binary(integer_to_list(Number)).