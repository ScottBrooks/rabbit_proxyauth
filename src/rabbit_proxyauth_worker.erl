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
    {obj, [{id, Id}, {action, login}, {user, User}, {pass, Pass}]};

build_message({vhost, User, Vhost}, Id) ->
    {obj, [{id, Id}, {action, vhost}, {user, User}, {vhost, Vhost}]};

build_message({resource_access, User, Vhost, Item, Permission}, Id) ->
    {obj, [{id, Id}, {action, resource_access}, {user, User}, {vhost, Vhost}, {item, Item}, {permission, Permission}]}.

send_request(State = #state{message_count = MessageCount, outstanding = Outstanding}, Id, From, Message) ->
    BP = #'basic.publish'{exchange = State#state.exchange},
    Content = #amqp_msg{payload = Message, props = #'P_basic'{reply_to = State#state.queue}},
    amqp_channel:call(State#state.channel, BP, Content),
    NewState = State#state{message_count = MessageCount+1, outstanding = [{Id, From}|Outstanding]},
    {noreply, NewState}.

send_reply(#state{outstanding = Outstanding}, Reply) ->
    Id = proplists:get_value("id", Reply),
    NewOutstanding = case lists:keytake(Id, 1, Outstanding) of
        {value, {Id, From}, NewList} ->
            case proplists:get_value("code", Reply) of
                200 ->
                    gen_server:reply(From, ok);
                _   ->
                    gen_server:reply(From, error)
            end,
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
    io:format("starting ~-60s ...", ["proxyauth plugin"]),
    Config = case application:get_env(rabbit, proxyauth) of
        {ok, Value} ->
            Value;
        _         ->
            io:format("no proxyauth config found, using default ...", []),
            ?DEFAULT_CONFIG
    end,
    Endpoint = proplists:get_value(endpoint, Config),
    {ok, Channel, Exchange, Queue} = connect_to_endpoint(Endpoint),
    State = #state{endpoint = Endpoint, channel = Channel, exchange = Exchange, queue = Queue},
    io:format("done~n", []),
    {ok, State}.

handle_call(Msg, From, State = #state{message_count = MessageCount}) ->
    Id = MessageCount + 1,
    Message = build_message(Msg, Id),
    send_request(State, Id, From, list_to_binary(rfc4627:encode(Message))).

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({#'basic.deliver'{}, #amqp_msg{payload = Payload}}, State) ->
    {ok, {obj, Reply}, _} = rfc4627:decode(binary_to_list(Payload)),
    NewOutstanding = send_reply(State, Reply),
    {noreply, State#state{outstanding = NewOutstanding}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    io:format("Terminate: ~p~n", [_Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
