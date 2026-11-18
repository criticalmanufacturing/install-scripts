%% Helm test entry point. The test pod compiles this file using the AMQP client
%% in the RabbitMQ image and supplies the service, credentials and CA at runtime.
%% Verify AMQPS and a persistent message round trip on a temporary classic
%% priority queue. Clean up the queue, channel and connection on normal errors.
-module(amqp_test).
-export([run/0]).
-include_lib("amqp_client/include/amqp_client.hrl").
run() ->
    application:ensure_all_started(amqp_client),
    Host = os:getenv("RABBIT_HOST"),
    Queue = list_to_binary("cmmes-helm-test-" ++ integer_to_list(erlang:system_time(microsecond))),
    % Resolve the service as an absolute DNS name; retain Host for TLS SNI below.
    Params = #amqp_params_network{host=Host ++ ".", port=5671,
        username=list_to_binary(os:getenv("RABBIT_USER")),
        password=list_to_binary(os:getenv("RABBIT_PASSWORD")),
        virtual_host=list_to_binary(os:getenv("RABBIT_VHOST")),
        ssl_options=[{verify, verify_peer}, {cacertfile,"/cm/tls/ca.crt"},
            {server_name_indication,Host},
            {customize_hostname_check,[{match_fun,public_key:pkix_verify_hostname_match_fun(https)}]}]},
    {ok, Conn} = amqp_connection:start(Params),
    try
        {ok, Ch} = amqp_connection:open_channel(Conn),
        try
            #'queue.declare_ok'{} = amqp_channel:call(Ch,#'queue.declare'{queue=Queue,durable=true,
                arguments=[{<<"x-queue-type">>,longstr,<<"classic">>},{<<"x-max-priority">>,byte,10}]}),
            try
                #'confirm.select_ok'{} = amqp_channel:call(Ch,#'confirm.select'{}),
                ok = amqp_channel:cast(Ch,#'basic.publish'{routing_key=Queue},
                    #amqp_msg{props=#'P_basic'{delivery_mode=2,priority=5},payload = <<"cmmes">>}),
                true = amqp_channel:wait_for_confirms(Ch,10000),
                {#'basic.get_ok'{delivery_tag=Tag},#amqp_msg{payload = <<"cmmes">>}} =
                    amqp_channel:call(Ch,#'basic.get'{queue=Queue}),
                ok = amqp_channel:cast(Ch,#'basic.ack'{delivery_tag=Tag}),
                io:format("OK: AMQPS, classic priority queue and publish/consume~n")
            after amqp_channel:call(Ch,#'queue.delete'{queue=Queue}) end
        after amqp_channel:close(Ch) end
    after amqp_connection:close(Conn) end.
