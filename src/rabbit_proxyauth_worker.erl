-module(rabbit_proxyauth_worker).
-behaviour(gen_server).

-export([start/0, start/2, stop/0, stop/1, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-record(state, {endpoint, channel, exchange, queue, message_count=0, outstanding = []}).
-define(DEFAULT_CONFIG, [{endpoint, {<<"guest">>, <<"guest">>, direct, 5672, <<"/">>, <<"proxyauth">>}}]).


connect_to_endpoint(Endpoint) ->
    {User, Pass, Host, Port, Vhost, Exchange} = Endpoint,
    Params = #amqp_params{username = User, password = Pass, host = Host, virtual_host = Vhost, port = Port},
    Connection = case Host of
        direct ->
            amqp_connection:start_direct(Params);
        Host ->
            amqp_connection:start_network(Params)
    end,
    Channel = amqp_connection:open_channel(Connection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = Exchange, type = <<"topic">>}),
    #'queue.declare_ok'{queue = Queue} = amqp_channel:call(Channel, #'queue.declare'{auto_delete = true, exclusive = true}),
    amqp_channel:subscribe(Channel, #'basic.consume'{queue = Queue, exclusive = true}, self()),
    {ok, Channel, Exchange, Queue}.

build_message({login, User, Pass}, Id) ->
    list_to_binary(lists:flatten([
                "id:", integer_to_list(Id), "\n",
                "action:", "login", "\n",
                "user:", binary_to_list(User), "\n",
                "pass:", binary_to_list(Pass), "\n"])).
        

send_request(State = #state{message_count = MessageCount, outstanding = Outstanding}, Id, From, Message) ->
    BP = #'basic.publish'{exchange = State#state.exchange},
    Content = #amqp_msg{payload = Message, props = #'P_basic'{reply_to = State#state.queue}},
    amqp_channel:call(State#state.channel, BP, Content),
    NewState = State#state{message_count = MessageCount+1, outstanding = [{Id, From}|Outstanding]},
    {noreply, NewState}.

parse_payload(Payload) ->
    lists:foldl(
        fun(X, Acc) ->
            [Key,Value] = string:tokens(X, ":"),
            [{Key, Value} | Acc]
        end, [], string:tokens(Payload, "\n")).

send_reply(State = #state{outstanding = Outstanding}, Reply) ->
    Id = list_to_integer(proplists:get_value("id", Reply)),
    NewOutstanding = case lists:keytake(Id, 1, Outstanding) of
        {value, {Id, From}, NewList} ->
            gen_server:reply(From, error),
            NewList;
        _ -> Outstanding
    end,
    NewOutstanding.


%%%%%%%%%%%%%
%% GEN SERVER
%%%%%%%%%%%%%

start() ->
    start_link(),
    ok.

start(normal, []) ->
    start_link().

stop() ->
    ok.

stop(_State) ->
    stop().

start_link() ->
    gen_server:start_link({local, rabbitmq_proxyauth}, ?MODULE, [], []).

init([]) ->
    Config = case application:get_env(rabbit, proxyauth) of
        {ok, Value} ->
            Value;
        _         ->
            io:format("no proxyauth config found, using default", []),
            ?DEFAULT_CONFIG
    end,
    io:format("Config: ~p~n", [Config]),
    Endpoint = proplists:get_value(endpoint, Config),
    {ok, Channel, Exchange, Queue} = connect_to_endpoint(Endpoint),
    State = #state{endpoint = Endpoint, channel = Channel, exchange = Exchange, queue = Queue},
    io:format("State: ~p~n", [State]),
    {ok, State}.

handle_call({login, User, Pass}, From, State = #state{message_count = MessageCount}) ->
    Id = MessageCount + 1,
    Message = build_message({login, User, Pass}, Id),
    send_request(State, Id, From, Message);

handle_call(_Msg, _From, State) ->
    io:format("Call: ~p~n", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    io:format("Cast: ~p~n", [_Msg]),
    {noreply, State}.

handle_info({Header = #'basic.deliver'{}, Message = #amqp_msg{payload = Payload}}, State) ->
    io:format("Payload: ~p~n", [Payload]),
    Reply = parse_payload(binary_to_list(Payload)),
    NewOutstanding = send_reply(State, Reply),
    {noreply, State#state{outstanding = NewOutstanding}};

handle_info(_Info, State) ->
    io:format("Info: ~p~n", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    io:format("Terminate: ~p~n", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
