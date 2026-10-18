%% Target-side release execution. No Elixir runtime is required on the target.
-module(jido_workspace_deploy_target).
-behaviour(gen_server).
-export([start/0, identity/0, install/5, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        Error -> Error
    end.
identity() -> gen_server:call(?MODULE, identity).
install(Id, Expected, Version, Guard, Recovery) ->
    gen_server:call(?MODULE, {install, Id, Expected, Version, Guard, Recovery}, 10000).
status(Id) -> gen_server:call(?MODULE, {status, Id}).

init([]) ->
    {ok, #{generation => make_ref(), operations => #{}, busy => false, blocked => false}}.

handle_call(identity, _, State) -> {reply, observation(State), State};
handle_call({status, Id}, _, State) ->
    {reply, maps:find(Id, maps:get(operations, State)), State};
handle_call({install, Id, Expected, Version, Guard, Recovery}, _, State) ->
    Ops = maps:get(operations, State),
    case maps:find(Id, Ops) of
        {ok, _} -> {reply, {ok, Id}, State};
        error ->
            Current = observation(State),
            case {maps:get(busy, State), maps:get(blocked, State) andalso not Recovery,
                  maps:with([generation, release], Current) =:= Expected} of
                {true, _, _} -> {reply, {error, busy}, State};
                {_, true, _} -> {reply, {error, recovery_required}, State};
                {_, _, false} -> {reply, {error, stale_target}, State};
                _ ->
                    Parent = self(),
                    {_, Ref} = spawn_monitor(fun() ->
                        Result = transition(Version, Guard),
                        Parent ! {completed, Id, Result}
                    end),
                    Entry = #{status => running, monitor => Ref, version => Version},
                    {reply, {ok, Id}, State#{busy => true, operations => Ops#{Id => Entry}}}
            end
    end;
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

handle_cast(_, State) -> {noreply, State}.
handle_info({completed, Id, Result}, State) ->
    Ops = maps:get(operations, State),
    Entry = maps:get(Id, Ops),
    erlang:demonitor(maps:get(monitor, Entry), [flush]),
    Status = case Result of
        {ok, _, _} -> succeeded;
        {refused, _} -> failed;
        _ -> recovery_required
    end,
    Next = Entry#{status => Status, result => Result},
    Blocked = Status =:= recovery_required orelse
        (maps:get(blocked, State) andalso Status =/= succeeded),
    {noreply, State#{busy => false, blocked => Blocked,
                    operations => Ops#{Id => Next}}};
handle_info({'DOWN', Ref, process, _, Reason}, State) ->
    Ops = maps:map(fun(_, Entry) ->
        case Entry of
            #{monitor := Ref, status := running} ->
                Entry#{status => recovery_required, result => {worker_exit, Reason}};
            _ -> Entry
        end
    end, maps:get(operations, State)),
    {noreply, State#{busy => false, blocked => true, operations => Ops}};
handle_info(_, State) -> {noreply, State}.

observation(State) ->
    Releases = release_handler:which_releases(),
    Current = case [V || {_, V, _, current} <- Releases] of
        [V | _] -> V;
        [] -> case [V || {_, V, _, permanent} <- Releases] of
            [V | _] -> V;
            [] -> undefined
        end
    end,
    #{generation => maps:get(generation, State), release => Current,
      releases => Releases, os_pid => os:getpid(), blocked => maps:get(blocked, State)}.

transition(Version, Guard) ->
    try
        case guard(Guard) of
            ok ->
                case release_handler:check_install_release(Version) of
                    {ok, _, _} -> release_handler:install_release(Version,
                        [{suspend_timeout, 5000}, {code_change_timeout, 5000}, {update_paths, true}]);
                    Error -> {refused, {release_check, Error}}
                end;
            Error -> {refused, {preflight, Error}}
        end
    catch Class:Reason -> {uncertain, {Class, Reason}}
    end.

guard(undefined) -> ok;
guard(nil) -> ok;
guard({Module, Function, Args}) -> apply(Module, Function, Args).
