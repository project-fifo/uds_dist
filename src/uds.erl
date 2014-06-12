%%% @author Jean Parpaillon <jean.parpaillon@free.fr>
%%% @copyright (C) 2014, Jean Parpaillon
%%% @doc
%%%
%%% @end
%%% Created : 11 Jun 2014 by Jean Parpaillon <jean.parpaillon@free.fr>
-module(uds).

-behaviour(gen_server).

-export([connect/1]).

-export([listen/1, 
	 accept/1,
	 send/2,
	 recv/1,
	 close/1,
	 get_status_counters/1,
	 set_mode/2,
	 set_active/2]).

% exported for spawning
-export([select/3]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DRIVER_NAME, "uds_drv").

-define(decode(A,B,C,D), (((A) bsl 24) bor 
			  ((B) bsl 16) bor ((C) bsl 8) bor (D))).
-define(encode(N), [(((N) bsr 24) band 16#FF), (((N) bsr 16) band 16#FF),  
		    (((N) bsr 8) band 16#FF), ((N) band 16#FF)]).

-type uds_mode() :: command | intermediate | data.
-type uds_active() :: once | true | false.
-record(state, {port                   :: port(), 
		passive   = undefined  :: pid(),
		active    = true       :: uds_active()}).

%%%
%%% Socket-like API
%%%
-spec listen(string()) -> {ok, pid()} | ignore | {error, term()}.
listen(Name) ->
    gen_server:start_link(?MODULE, {listen, Name}, []).

-spec connect(string()) -> {ok, pid()} | ignore | {error, term()}.
connect(Name) ->
    gen_server:start_link(?MODULE, {connect, Name}, []).

-spec accept(pid()) -> ok | {error, term()}.
accept(Port) ->
    gen_server:call(Port, accept).

-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Port,Data) ->
    gen_server:call(Port, {send, Data}).

-spec recv(pid()) -> {ok, iodata()} | {error, term()}.
recv(Port) ->
    gen_server:call(Port, recv).

-spec close(pid()) -> ok.
close(Port) ->
    gen_server:call(Port, close).

-spec get_status_counters(term()) -> {ok, {integer(), integer(), integer()}} | {error, term()}.
get_status_counters(Port) ->
    gen_server:call(Port, status_counters).

-spec set_mode(pid(), uds_mode()) -> ok | {error, term()}.
set_mode(Port, Mode) -> 
    gen_server:call(Port, {mode, Mode}).

-spec set_active(pid(), uds_active()) -> ok | {error, term()}.
set_active(Port, Active) ->
    gen_server:call(Port, {active, Active}).

%%%
%%% gen_server callbacks
%%%
init({Command, Name}) ->
    process_flag(trap_exit,true),
    case load_driver() of
	{ok, _Status} ->
	    case get_port() of
		{ok, P} -> do_init(Command, Name, #state{port=P});
		{error, Err} -> {stop, Err}
	    end;
	{error, already_loaded} ->
	    case get_port() of
		{ok, P} -> do_init(Command, Name, #state{port=P});
		{error, Err} -> {stop, Err}
	    end;
	{error, Err} ->
	    {stop, Err}
    end.

%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call(accept, _From, State) ->
    case control($N, State) of
	{reply, {ok, N}, S2} -> command($A, N, S2);
	Else -> Else
    end;

handle_call({send, Data}, _From, State) ->
    command($S, Data, State);

handle_call(recv, _From, State) ->
    command($R, [], State);

handle_call(close, _From, #state{port=Port}=State) ->
    (catch unlink(Port)), %% Avoids problem with trap exits.
    try erlang:port_close(Port) of
	true -> {stop, normal, State}
    catch
	'EXIT':_Err -> {stop, {error, closed}, State}
    end;

handle_call(status_counters, _From, State) ->
    control($S, State);

handle_call({mode, command}, _From, State) ->
    control($C, State);

handle_call({mode, intermediate}, _From, State) ->
    control($I, State);

handle_call({mode, data}, _From, State) ->
    control($D, State);

handle_call({active, true}, _From, #state{passive=Pid}=State) ->
    kill(Pid),
    {reply, ok, State#state{active=true, passive=undefined}};

handle_call({active, FalseOrOnce}, {Owner, _}, #state{port=Port, passive=Pid}=State) ->
    kill(Pid),
    process_flag(trap_exit, true),
    NewPid = spawn_link(?MODULE, select, [Port, Owner, FalseOrOnce]),
    {reply, ok, State#state{active=false, passive=NewPid}};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info({'EXIT', _Pid, normal}, State) ->
    % Input was received, back to active mode
    {noreply, State#state{active=true, passive=undefined}};

handle_info({'EXIT', _Pid, {error, Err}}, State) ->
    {stop, {error, Err}, State#state{passive=undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(_Reason, _State) ->
    %erl_ddll:unload_driver(?DRIVER_NAME),
    ok.

%%----------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%----------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
do_init(Cmd, Name, State) ->
    case command(Cmd, Name, State) of
	{reply, ok, S2} -> {ok, S2};
	{reply, {error, Err}, _S2} -> {stop, Err};
	{stop, Err, _S2} -> {stop, Err}
    end.

control(Command, #state{port=Port}=State) ->
    try erlang:port_control(Port, Command, []) of
	[0] ->
	    {reply, ok, State};
	[0,A] ->
	    {reply, {ok, A}, State};
	[0,A,B,C,D] ->
	    {reply, {ok, [A,B,C,D]}, State};
	[0,A1,B1,C1,D1,A2,B2,C2,D2,A3,B3,C3,D3] ->
	    {reply, {ok, {?decode(A1,B1,C1,D1),?decode(A2,B2,C2,D2),
			  ?decode(A3,B3,C3,D3)}}, State};
	[1|Error] ->
	    {reply, {error, list_to_atom(Error)}, State};
	Else ->
	    {reply, {error, {unexpected_driver_response, Else}}, State}
    catch 
	'EXIT':{badarg, _} ->
	    {stop, {error, closed}, State}
    end.
	    

command(Command, Parameters, #state{port=Port}=State) ->
    SavedTrapExit = process_flag(trap_exit, true),
    try erlang:port_command(Port, [Command | Parameters]) of
	true ->
	    receive
		{Port, {data, [Command, $o, $k]}} ->
		    process_flag(trap_exit, SavedTrapExit),
		    {reply, ok, State#state{port=Port}};
		{Port, {data, [Command |T]}} ->
		    process_flag(trap_exit, SavedTrapExit),
		    {reply, T, State#state{port=Port}};
		{Port, Else} ->
		    process_flag(trap_exit, SavedTrapExit),
		    {stop, {error, {unexpected_driver_response, Else}}, State};
		{'EXIT', Port, normal} ->
		    process_flag(trap_exit, SavedTrapExit),
		    {stop, {error, closed}, State};
		{'EXIT', Port, Error} -> 
		    process_flag(trap_exit, SavedTrapExit),
		    {stop, {error, Error}, State}
	    end;
	Unexpected ->
	    process_flag(trap_exit,SavedTrapExit),
	    {reply, {error, {unexpected_driver_response, Unexpected}}, State}
    catch
	'EXIT':{badarg, _} ->
	    process_flag(trap_exit,SavedTrapExit),
	    {stop, {error, closed}, State}
    end.

get_port() ->
    SavedTrapExit = process_flag(trap_exit,true),
    case open_port({spawn, "uds_drv"},[]) of
	P when is_port(P) ->
	    process_flag(trap_exit, SavedTrapExit),
	    {ok, P};
	{'EXIT',Error} ->
	    process_flag(trap_exit, SavedTrapExit),
	    {error, Error};
	Else ->
	    process_flag(trap_exit, SavedTrapExit),
	    {error, {unexpected_driver_response, Else}}
    end.

%%
%% handlers for passive mode
%%
kill(undefined) ->
    ok;
kill(Pid) when is_pid(Pid) ->
    exit(Pid, normal).

select(Port, Owner, FalseOrOnce) ->
    SavedTrapExit = process_flag(trap_exit, true),
    try erlang:port_command(Port, [ $R | []]) of
	true ->
	    receive
		{Port, {data, [ $R | Data]}} ->
		    process_flag(trap_exit, SavedTrapExit),
		    Owner ! {unix, Port, Data},
		    case FalseOrOnce of
			false ->
			    select(Port, Owner, false);
			once ->
			    exit(normal)
		    end;
		{Port, Else} ->
		    process_flag(trap_exit, SavedTrapExit),
		    exit({error, {unexpected_driver_response, Else}});
		{'EXIT', Port, normal} ->
		    process_flag(trap_exit, SavedTrapExit),
		    exit({error, closed});
		{'EXIT', Port, Error} -> 
		    process_flag(trap_exit, SavedTrapExit),
		    exit({error, Error})
	    end
    catch
	'EXIT':{badarg, Err} ->
	    process_flag(trap_exit, SavedTrapExit),
	    exit({error, {unexpected_driver_response, Err}})
    end.	

%%
%% Actually load the driver.
%%
load_driver() ->
    Dir = find_priv_lib(),
    erl_ddll:try_load(Dir, ?DRIVER_NAME, []).

%%
%% As this server may be started by the distribution, it is not safe to assume 
%% a working code server, neither a working file server.
%% I try to utilize the most primitive interfaces available to determine
%% the directory of the port_program.
%%
find_priv_lib() ->
    case code:priv_dir(?MODULE) of
        {error, _} ->
            EbinDir = filename:dirname(code:which(?MODULE)),
            AppPath = filename:dirname(EbinDir),
            filename:join(AppPath, "priv");
        Path ->
            Path
    end.

