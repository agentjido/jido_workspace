-module(counter_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    Child = #{id => counter_server, start => {counter_server, start_link, []}},
    {ok, {{one_for_one, 3, 10}, [Child]}}.
