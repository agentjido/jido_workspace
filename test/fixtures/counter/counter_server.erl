-module(counter_server).
-behaviour(gen_server).
-vsn(?VSN).
-export([start_link/0, add/1, inspect/0, preflight/1]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
add(N) -> gen_server:call(?MODULE, {add, N}).
inspect() -> gen_server:call(?MODULE, inspect).
preflight(true) -> ok;
preflight(false) -> {error, invalid_migration}.
init([]) -> {ok, #{count => 10, requests => 0}}.
handle_call(inspect, _, State) -> {reply, {self(), ?VSN, State}, State};
handle_call({add, N}, _, State) ->
    Key = case maps:is_key(total, State) of true -> total; false -> count end,
    Next = State#{Key := maps:get(Key, State) + ?FACTOR * N,
                  requests := maps:get(requests, State) + 1},
    {reply, Next, Next}.
handle_cast(_, State) -> {noreply, State}.
code_change({down, _}, State, _) ->
    {ok, #{count => maps:get(total, State), requests => maps:get(requests, State)}};
code_change(_, State, _) ->
    case ?FACTOR of
        1 -> {ok, #{count => maps:get(total, State), requests => maps:get(requests, State)}};
        2 -> {ok, #{total => maps:get(count, State), requests => maps:get(requests, State)}};
        3 -> {error, injected_callback_failure}
    end.
