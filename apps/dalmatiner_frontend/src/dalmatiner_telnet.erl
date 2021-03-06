-module(dalmatiner_telnet).

-behaviour(ranch_protocol).

-define(KEEPALIVE, 0).
-define(LIST, 1).
-define(GET, 2).
-define(QRY, $q).


-export([start_link/4]).
-export([init/4]).

start_link(Ref, Socket, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
    {ok, Pid}.

init(Ref, Socket, Transport, _Opts = []) ->
    ok = ranch:accept_ack(Ref),
    Transport:setopts(Socket, [{packet, line}]),
    loop(Socket, Transport).

loop(Socket, Transport) ->
    case Transport:recv(Socket, 0, 5000) of
        %% Simple keepalive
        {ok, <<"quit\r\n">>} ->
            Transport:send(Socket, <<"bye!\r\n">>),
            ok = Transport:close(Socket);
        {ok, <<"q\r\n">>} ->
            Transport:send(Socket, <<"bye!\r\n">>),
            ok = Transport:close(Socket);
        {ok, <<"metrics\r\n">>} ->
            {ok, Ms} = dalmatiner_connection:list(),
            Ms1 = string:join([binary_to_list(M) || M <- Ms], ", "),
            Ms2 = list_to_binary(Ms1),
            Transport:send(Socket, <<Ms2/binary, "\r\n">>),
            loop(Socket, Transport);
        {ok, <<"e ", D/binary>>} ->
            QT = do_query_prep(D),
            R = io_lib:format("~p\n\r", [QT]),
            Transport:send(Socket, list_to_binary(R)),
            loop(Socket, Transport);
        {ok, <<"explain ", D/binary>>} ->
            QT = do_query_prep(D),
            R = io_lib:format("~p\n\r", [QT]),
            Transport:send(Socket, list_to_binary(R)),
            loop(Socket, Transport);
        {ok, <<"SELECT ", _/binary>> = Q} ->
            _Now = {Mega, Sec, Micro} = now(),
            NowMs = ((Mega * 1000000  + Sec) * 1000000 + Micro) div 1000,
            case timer:tc(dqe, run, [Q]) of
                {T, {ok, Ls}} ->
                    [begin
                         Now = (NowMs div Resolution) * Resolution,
                         TL = << <<$\t, (to_s(Now + E*Resolution))/binary>> ||
                                  E <- lists:seq(0, mmath_bin:length(Data) - 1) >>,
                         Transport:send(Socket, <<"Time", TL/binary, "\n\r">>),
                         BL = << <<$\t, (to_s(E))/binary>> ||
                                  E <- mmath_bin:to_list(Data) >>,
                         Transport:send(Socket, <<Name/binary, BL/binary, "\n\r">>)
                     end || {Name, Data, Resolution} <- Ls],
                    Transport:send(Socket, <<"Query completed in ",
                                             (to_s(T/1000))/binary,
                                             "ms\n\r">>);
                {T, {error, E}} ->
                    io:format("E: ~p", [E]),
                    Transport:send(Socket, <<"Error after ",
                                             (to_s(T/1000))/binary,
                                             "ms: ", E/binary, "\n\r">>)
            end,
            loop(Socket, Transport);
        {ok, What} ->
            Transport:send(Socket, <<"I do not understand: ", What/binary>>),
            loop(Socket, Transport);

        {error,timeout} ->
            loop(Socket, Transport);
        E ->
            io:format("E: ~p~n", [E]),
            ok = Transport:close(Socket)
    end.

do_query_prep(D) ->
    S = byte_size(D) - 2,
    <<Q:S/binary, "\r\n">> = D,
    R1 = dalmatiner_qry_parser:parse(Q),
    {to_list, R1}.

to_s(E) when is_integer(E) ->
    erlang:integer_to_binary(E);
to_s(E) when is_float(E) ->
    erlang:float_to_binary(E, [{decimals, 2}]).
