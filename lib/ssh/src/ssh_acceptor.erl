%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2020. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%

-module(ssh_acceptor).

-include("ssh.hrl").

%% Internal application API
-export([start_link/4,
	 number_of_connections/1,
	 listen/2]).

%% spawn export  
-export([acceptor_init/5, acceptor_loop/6]).

-behaviour(ssh_dbg).
-export([ssh_dbg_trace_points/0, ssh_dbg_flags/1, ssh_dbg_on/1, ssh_dbg_off/1, ssh_dbg_format/2]).

-define(SLEEP_TIME, 200).

%%====================================================================
%% Internal application API
%%====================================================================
start_link(Port, Address, Options, AcceptTimeout) ->
    Args = [self(), Port, Address, Options, AcceptTimeout],
    proc_lib:start_link(?MODULE, acceptor_init, Args).

%%%----------------------------------------------------------------
number_of_connections(SysSup) ->
    length([S || S <- supervisor:which_children(SysSup),
                 has_worker(SysSup,S)]).


has_worker(SysSup, {R,SubSysSup,supervisor,[ssh_subsystem_sup]}) when is_reference(R),
                                                                      is_pid(SubSysSup) ->
    try
        {{server, ssh_connection_sup, _, _}, Pid, supervisor, [ssh_connection_sup]} =
            lists:keyfind([ssh_connection_sup], 4, supervisor:which_children(SubSysSup)),
        {Pid, supervisor:which_children(Pid)}
    of
        {ConnSup,[]} ->
            %% Strange. Since the connection supervisor exists, there should have been
            %% a connection here.
            %% It might be that the connection_handler worker has "just died", maybe
            %% due to a exit(_,kill). It might also be so that the worker is starting.
            %% Spawn a killer that redo the test and kills it if the problem persists.
            %% TODO: Fix this better in the supervisor tree....
            spawn(fun() ->
                          timer:sleep(10),
                          try supervisor:which_children(ConnSup)
                          of
                              [] ->
                                  %% we are on the server-side:
                                  ssh_system_sup:stop_subsystem(SysSup, SubSysSup);
                              [_] ->
                                  %% is ok now
                                  ok;
                          _ ->
                                  %% What??
                                  error
                          catch _:_ ->
                                  %% What??
                                  error
                          end
                  end),
            false;
        {_ConnSup,[_]}->
            true;
         _ ->
            %% What??
            false
    catch _:_ ->
            %% What??
            false
    end;

has_worker(_,_) ->
    false.

%%%----------------------------------------------------------------
listen(Port, Options) ->
    {_, Callback, _} = ?GET_OPT(transport, Options),
    SockOpts = [{active, false}, {reuseaddr,true} | ?GET_OPT(socket_options, Options)],
    case Callback:listen(Port, SockOpts) of
	{error, nxdomain} ->
	    Callback:listen(Port, lists:delete(inet6, SockOpts));
	{error, enetunreach} ->
	    Callback:listen(Port, lists:delete(inet6, SockOpts));
	{error, eafnosupport} ->
	    Callback:listen(Port, lists:delete(inet6, SockOpts));
	Other ->
	    Other
    end.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
acceptor_init(Parent, Port, Address, Opts, AcceptTimeout) ->
    try
        ?GET_INTERNAL_OPT(lsocket, Opts)
    of
        {LSock, SockOwner} ->
            case inet:sockname(LSock) of
                {ok,{_,Port}} -> % A usable, open LSock
                    proc_lib:init_ack(Parent, {ok, self()}),
                    request_ownership(LSock, SockOwner),
                    {_, Callback, _} =  ?GET_OPT(transport, Opts),
                    acceptor_loop(Callback, Port, Address, Opts, LSock, AcceptTimeout);

                {error,_} -> % Not open, a restart
                    %% Allow gen_tcp:listen to fail 4 times if eaddrinuse:
                    {ok,NewLSock} = try_listen(Port, Opts, 4),
                    proc_lib:init_ack(Parent, {ok, self()}),
                    Opts1 = ?DELETE_INTERNAL_OPT(lsocket, Opts),
                    {_, Callback, _} =  ?GET_OPT(transport, Opts1),
                    acceptor_loop(Callback, Port, Address, Opts1, NewLSock, AcceptTimeout)
            end
    catch
        _:_ ->
            {error,use_existing_socket_failed}
    end.


try_listen(Port, Opts, NtriesLeft) ->
    try_listen(Port, Opts, 1, NtriesLeft).

try_listen(Port, Opts, N, Nmax) ->
    case listen(Port, Opts) of
        {error,eaddrinuse} when N<Nmax ->
            timer:sleep(10*N), % Sleep 10, 20, 30,... ms
            try_listen(Port, Opts, N+1, Nmax);
        Other ->
            Other
    end.


request_ownership(LSock, SockOwner) ->
    SockOwner ! {request_control,LSock,self()},
    receive
	{its_yours,LSock} -> ok
    end.
    
%%%----------------------------------------------------------------    
acceptor_loop(Callback, Port, Address, Opts, ListenSocket, AcceptTimeout) ->
    case Callback:accept(ListenSocket, AcceptTimeout) of
        {ok,Socket} ->
            {ok, {FromIP,FromPort}} = inet:peername(Socket), % Just in case of error in next line:
            case handle_connection(Address, Port, Opts, Socket) of
                {error,Error} ->
                    catch Callback:close(Socket),
                    handle_error(Error, Address, Port, FromIP, FromPort);
                _ ->
                    ok
            end;
        {error,Error} ->
            handle_error(Error, Address, Port)
    end,
    ?MODULE:acceptor_loop(Callback, Port, Address, Opts, ListenSocket, AcceptTimeout).

%%%----------------------------------------------------------------
handle_connection(Address, Port, Options, Socket) ->
    Profile =  ?GET_OPT(profile, Options),
    SystemSup = ssh_system_sup:system_supervisor(Address, Port, Profile),

    MaxSessions = ?GET_OPT(max_sessions, Options),
    case number_of_connections(SystemSup) < MaxSessions of
	true ->
	    NegTimeout = ?GET_OPT(negotiation_timeout, Options),
            ssh_connection_handler:start_link(server, Address, Port, Socket, Options, NegTimeout);
	false ->
	    {error,{max_sessions,MaxSessions}}
    end.

%%%----------------------------------------------------------------
handle_error(Reason, ToAddress, ToPort) ->
    handle_error(Reason, ToAddress, ToPort, undefined, undefined).


handle_error(Reason, ToAddress, ToPort, FromAddress, FromPort) ->
    case Reason of
        {max_sessions, MaxSessions} ->
            error_logger:info_report(
              lists:concat(["Ssh login attempt to ",ssh_lib:format_address_port(ToAddress,ToPort),
                            " from ",ssh_lib:format_address_port(FromAddress,FromPort),
                            " denied due to option max_sessions limits to ",
                            MaxSessions, " sessions."
                           ])
             );

        Limit when Limit==enfile ; Limit==emfile ->
            %% Out of sockets...
            error_logger:info_report([atom_to_list(Limit),": out of accept sockets on ",
                                      ssh_lib:format_address_port(ToAddress, ToPort),
                                      " - retrying"]),
            timer:sleep(?SLEEP_TIME);

        closed ->
            error_logger:info_report(["The ssh accept socket on ",ssh_lib:format_address_port(ToAddress,ToPort),
                                      "was closed by a third party."]
                                    );

        timeout ->
            ok;

        Error when is_list(Error) ->
            ok;
        Error when FromAddress=/=undefined,
                   FromPort=/=undefined ->
            error_logger:info_report(["Accept failed on ",ssh_lib:format_address_port(ToAddress,ToPort),
                                      " for connect from ",ssh_lib:format_address_port(FromAddress,FromPort),
                                      io_lib:format(": ~p", [Error])]);
        Error ->
            error_logger:info_report(["Accept failed on ",ssh_lib:format_address_port(ToAddress,ToPort),
                                      io_lib:format(": ~p", [Error])])
    end.

%%%################################################################
%%%#
%%%# Tracing
%%%#

ssh_dbg_trace_points() -> [connections].

ssh_dbg_flags(connections) -> [c].

ssh_dbg_on(connections) -> dbg:tp(?MODULE,  acceptor_init, 5, x),
                           dbg:tpl(?MODULE, handle_connection, 4, x).

ssh_dbg_off(connections) -> dbg:ctp(?MODULE, acceptor_init, 5),
                            dbg:ctp(?MODULE, handle_connection, 4).

ssh_dbg_format(connections, {call, {?MODULE,acceptor_init,
                                    [_Parent, Port, Address, _Opts, _AcceptTimeout]}}) ->
    [io_lib:format("Starting LISTENER on ~s:~p\n", [ssh_lib:format_address(Address),Port])
    ];
ssh_dbg_format(connections, {return_from, {?MODULE,acceptor_init,5}, _Ret}) ->
    skip;

ssh_dbg_format(connections, {call, {?MODULE,handle_connection,[_,_,_,_]}}) ->
    skip;
ssh_dbg_format(connections, {return_from, {?MODULE,handle_connection,4}, {error,Error}}) ->
    ["Starting connection to server failed:\n",
     io_lib:format("Error = ~p", [Error])
    ].
