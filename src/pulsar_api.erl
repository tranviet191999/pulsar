%%%-------------------------------------------------------------------
%%% @author root
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. 4ζ 2021 δΈε6:03
%%%-------------------------------------------------------------------
-module(pulsar_api).
-author("root").

-module(pulsar_client).

-behaviour(gen_server).

-export([start_link/3]).

-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-export([get_topic_metadata/2, lookup_topic/2]).

-export([get_status/1]).

-record(state,
{sock,
  servers,
  opts,
  producers = #{},
  request_id = 0,
  requests = #{},
  from,
  last_bin = <<>>}).

-vsn("4.2.5").

start_link(ClientId, Servers, Opts) ->
  gen_server:start_link({local, ClientId},
    pulsar_client,
    [Servers, Opts],
    []).

get_topic_metadata(Pid, Topic) ->
  Call = self(),
  gen_server:call(Pid, {get_topic_metadata, Topic, Call}).

lookup_topic(Pid, PartitionTopic) ->
  gen_server:call(Pid,
    {lookup_topic, PartitionTopic},
    30000).

get_status(Pid) ->
  gen_server:call(Pid, get_status, 5000).

init([Servers, Opts]) ->
  State = #state{servers = Servers, opts = Opts},
  case get_sock(Servers, undefined) of
    error -> {error, fail_to_connect_pulser_server};
    Sock -> {ok, State#state{sock = Sock}}
  end.

handle_call({get_topic_metadata, Topic, Call}, From,
    State = #state{sock = Sock, request_id = RequestId,
      requests = Reqs, producers = Producers,
      servers = Servers}) ->
  case get_sock(Servers, Sock) of
    error ->
      log_error("Servers: ~p down", [Servers]),
      {noreply, State};
    Sock1 ->
      Metadata = topic_metadata(Sock1, Topic, RequestId),
      {noreply,
        next_request_id(State#state{requests =
        maps:put(RequestId,
          {From, Metadata},
          Reqs),
          producers =
          maps:put(Topic, Call, Producers),
          sock = Sock1})}
  end;
handle_call({lookup_topic, PartitionTopic}, From,
    State = #state{sock = Sock, request_id = RequestId,
      requests = Reqs, servers = Servers}) ->
  case get_sock(Servers, Sock) of
    error ->
      log_error("Servers: ~p down", [Servers]),
      {noreply, State};
    Sock1 ->
      LookupTopic = lookup_topic(Sock1,
        PartitionTopic,
        RequestId),
      {noreply,
        next_request_id(State#state{requests =
        maps:put(RequestId,
          {From, LookupTopic},
          Reqs),
          sock = Sock1})}
  end;
handle_call(get_status, From,
    State = #state{sock = undefined, servers = Servers}) ->
  case get_sock(Servers, undefined) of
    error -> {reply, false, State};
    Sock -> {noreply, State#state{from = From, sock = Sock}}
  end;
handle_call(get_status, _From, State) ->
  {reply, true, State};
handle_call(_Req, _From, State) ->
  {reply, ok, State, hibernate}.

handle_cast(_Req, State) -> {noreply, State, hibernate}.

handle_info({tcp, _, Bin},
    State = #state{last_bin = LastBin}) ->
  parse(pulsar_protocol_frame:parse(<<LastBin/binary,
    Bin/binary>>),
    State);
handle_info({tcp_closed, Sock},
    State = #state{sock = Sock}) ->
  {noreply, State#state{sock = undefined}, hibernate};
handle_info(ping, State = #state{sock = Sock}) ->
  ping(Sock),
  {noreply, State, hibernate};
handle_info(_Info, State) ->
  log_error("Pulsar_client Receive unknown message:~p~n",
    [_Info]),
  {noreply, State, hibernate}.

terminate(_Reason, #state{}) -> ok.

code_change(_, State, _) -> {ok, State}.

parse({undefined, Bin}, State) ->
  {noreply, State#state{last_bin = Bin}};
parse({Cmd, <<>>}, State) ->
  handle_response(Cmd, State#state{last_bin = <<>>});
parse({Cmd, LastBin}, State) ->
  State2 = case handle_response(Cmd, State) of
             {_, State1} -> State1;
             {_, State1, _} -> State1
           end,
  parse(pulsar_protocol_frame:parse(LastBin), State2).

handle_response({connected, _ConnectedData},
    State = #state{from = undefined}) ->
  start_keepalive(),
  {noreply, State, hibernate};
handle_response({connected, _ConnectedData},
    State = #state{from = From}) ->
  start_keepalive(),
  gen_server:reply(From, true),
  {noreply, State#state{from = undefined}, hibernate};
handle_response({partitionMetadataResponse,
  #{partitions := Partitions, request_id := RequestId}},
    State = #state{requests = Reqs}) ->
  case maps:get(RequestId, Reqs, undefined) of
    {From, #{topic := Topic}} ->
      gen_server:reply(From, {Topic, Partitions}),
      {noreply,
        State#state{requests = maps:remove(RequestId, Reqs)},
        hibernate};
    undefined -> {noreply, State, hibernate}
  end;
handle_response({lookupTopicResponse,
  #{brokerServiceUrl := BrokerServiceUrl,
    request_id := RequestId}},
    State = #state{requests = Reqs}) ->
  case maps:get(RequestId, Reqs, undefined) of
    {From, #{}} ->
      gen_server:reply(From, BrokerServiceUrl),
      {noreply,
        State#state{requests = maps:remove(RequestId, Reqs)},
        hibernate};
    undefined -> {noreply, State, hibernate}
  end;
handle_response({ping, #{}},
    State = #state{sock = Sock}) ->
  pong(Sock),
  {noreply, State, hibernate};
handle_response({pong, #{}}, State) ->
  start_keepalive(),
  {noreply, State, hibernate};
handle_response(_Info, State) ->
  log_error("Client handle_response unknown message:~p~n",
    [_Info]),
  {noreply, State, hibernate}.

tune_buffer(Sock) ->
  {ok, [{recbuf, RecBuf}, {sndbuf, SndBuf}]} =
    inet:getopts(Sock, [recbuf, sndbuf]),
  inet:setopts(Sock, [{buffer, max(RecBuf, SndBuf)}]).

get_sock(Servers, undefined) -> try_connect(Servers);
get_sock(_Servers, Sock) -> Sock.

try_connect([]) -> error;
try_connect([{Host, Port} | Servers]) ->
  case gen_tcp:connect(Host,
    Port,
    [binary,
      {packet, raw},
      {reuseaddr, true},
      {nodelay, true},
      {active, true},
      {reuseaddr, true},
      {send_timeout, 60000}],
    60000)
  of
    {ok, Sock} ->
      tune_buffer(Sock),
      gen_tcp:controlling_process(Sock, self()),
      connect(Sock),
      Sock;
    _Error -> try_connect(Servers)
  end.

connect(Sock) ->
  Conn = #{client_version =>
  "Pulsar-Client-Erlang-v0.0.1",
    protocol_version => 6},
  gen_tcp:send(Sock, pulsar_protocol_frame:connect(Conn)).

topic_metadata(Sock, Topic, RequestId) ->
  Metadata = #{topic => Topic, request_id => RequestId},
  gen_tcp:send(Sock,
    pulsar_protocol_frame:topic_metadata(Metadata)),
  Metadata.

lookup_topic(Sock, Topic, RequestId) ->
  LookupTopic = #{topic => Topic,
    request_id => RequestId},
  gen_tcp:send(Sock,
    pulsar_protocol_frame:lookup_topic(LookupTopic)),
  LookupTopic.

next_request_id(State = #state{request_id = 65535}) ->
  State#state{request_id = 1};
next_request_id(State = #state{request_id =
RequestId}) ->
  State#state{request_id = RequestId + 1}.

log_error(Fmt, Args) ->
  error_logger:error_msg(Fmt, Args).

start_keepalive() ->
  erlang:send_after(30 * 1000, self(), ping).

ping(Sock) ->
  gen_tcp:send(Sock, pulsar_protocol_frame:ping()).

pong(Sock) ->
  gen_tcp:send(Sock, pulsar_protocol_frame:pong()).


ok
3>
BREAK: (a)bort (A)bort with dump (c)ontinue (p)roc info (i)nfo
(l)oaded (v)ersion (k)ill (D)b-tables (d)istribution
^Ctlc@tlc-OptiPlex-9020:~/emqx/lib/pulsar-0.4.2/ebin$ erl -pa
Erlang/OTP 23 [erts-11.0] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1] [hipe]

Eshell V11.0  (abort with ^G)
1> {ok,{_,[{abstract_code,{_,AC}}]}} = beam_lib:chunks(pulsar_api,[abstract_code]).
{ok,{pulsar_api,[{abstract_code,{raw_abstract_v1,[{attribute,1,
file,
{"pulsar_api.erl",1}},
{attribute,5,module,pulsar_api},
{attribute,7,export,[{encode_msg,2},{encode_msg,3}]},
{attribute,8,export,[{decode_msg,2},{decode_msg,3}]},
{attribute,9,export,[{merge_msgs,3},{merge_msgs,4}]},
{attribute,10,export,[{verify_msg,2},{verify_msg,3}]},
{attribute,11,export,[{get_msg_defs,0}]},
{attribute,12,export,[{get_msg_names,0}]},
{attribute,13,export,[{get_group_names,0}]},
{attribute,14,export,[{get_msg_or_group_names,0}]},
{attribute,15,export,[{get_enum_names,0}]},
{attribute,16,export,[{find_msg_def,1},{fetch_msg_def,1}]},
{attribute,17,export,
[{find_enum_def,1},{fetch_enum_def,...}]},
{attribute,18,export,[{enum_symbol_by_value,...},{...}]},
{attribute,19,export,[{...}|...]},
{attribute,20,export,[...]},
{attribute,21,export,...},
{attribute,22,...},
{attribute,...},
{...}|...]}}]}}
2> io:fwrite("~s~n", [erl_prettypr:format(erl_syntax:form_list(AC))]).
-file("pulsar_api.erl", 1).

-module(pulsar_api).

-export([encode_msg/2, encode_msg/3]).

-export([decode_msg/2, decode_msg/3]).

-export([merge_msgs/3, merge_msgs/4]).

-export([verify_msg/2, verify_msg/3]).

-export([get_msg_defs/0]).

-export([get_msg_names/0]).

-export([get_group_names/0]).

-export([get_msg_or_group_names/0]).

-export([get_enum_names/0]).

-export([find_msg_def/1, fetch_msg_def/1]).

-export([find_enum_def/1, fetch_enum_def/1]).

-export([enum_symbol_by_value/2,
  enum_value_by_symbol/2]).

-export(['enum_symbol_by_value_Schema.Type'/1,
  'enum_value_by_symbol_Schema.Type'/1]).

-export([enum_symbol_by_value_CompressionType/1,
  enum_value_by_symbol_CompressionType/1]).

-export([enum_symbol_by_value_ServerError/1,
  enum_value_by_symbol_ServerError/1]).

-export([enum_symbol_by_value_AuthMethod/1,
  enum_value_by_symbol_AuthMethod/1]).

-export([enum_symbol_by_value_ProtocolVersion/1,
  enum_value_by_symbol_ProtocolVersion/1]).

-export(['enum_symbol_by_value_CommandSubscribe.SubType'/1,
  'enum_value_by_symbol_CommandSubscribe.SubType'/1]).

-export(['enum_symbol_by_value_CommandSubscribe.InitialPosition'/1,
  'enum_value_by_symbol_CommandSubscribe.InitialPosition'/1]).

-export(['enum_symbol_by_value_CommandPartitionedTopicMetadataResponse.LookupType'/1,
  'enum_value_by_symbol_CommandPartitionedTopicMetadataResponse.LookupType'/1]).

-export(['enum_symbol_by_value_CommandLookupTopicResponse.LookupType'/1,
  'enum_value_by_symbol_CommandLookupTopicResponse.LookupType'/1]).

-export(['enum_symbol_by_value_CommandAck.AckType'/1,
  'enum_value_by_symbol_CommandAck.AckType'/1]).

-export(['enum_symbol_by_value_CommandAck.ValidationError'/1,
  'enum_value_by_symbol_CommandAck.ValidationError'/1]).

-export(['enum_symbol_by_value_CommandGetTopicsOfNamespace.Mode'/1,
  'enum_value_by_symbol_CommandGetTopicsOfNamespace.Mode'/1]).

-export(['enum_symbol_by_value_BaseCommand.Type'/1,
  'enum_value_by_symbol_BaseCommand.Type'/1]).

-export([get_service_names/0]).

-export([get_service_def/1]).

-export([get_rpc_names/1]).

-export([find_rpc_def/2, fetch_rpc_def/2]).

-export([fqbin_to_service_name/1]).

-export([service_name_to_fqbin/1]).

-export([fqbins_to_service_and_rpc_name/2]).

-export([service_and_rpc_name_to_fqbins/2]).

-export([fqbin_to_msg_name/1]).

-export([msg_name_to_fqbin/1]).

-export([fqbin_to_enum_name/1]).

-export([enum_name_to_fqbin/1]).

-export([get_package_name/0]).

-export([uses_packages/0]).

-export([source_basename/0]).

-export([get_all_source_basenames/0]).

-export([get_all_proto_names/0]).

-export([get_msg_containment/1]).

-export([get_pkg_containment/1]).

-export([get_service_containment/1]).

-export([get_rpc_containment/1]).

-export([get_enum_containment/1]).

-export([get_proto_by_msg_name_as_fqbin/1]).

-export([get_proto_by_service_name_as_fqbin/1]).

-export([get_proto_by_enum_name_as_fqbin/1]).

-export([get_protos_by_pkg_name_as_fqbin/1]).

-export([gpb_version_as_string/0,
  gpb_version_as_list/0]).

-type 'Schema.Type'() :: 'None' |
'String' |
'Json' |
'Protobuf' |
'Avro' |
'Bool' |
'Int8' |
'Int16' |
'Int32' |
'Int64' |
'Float' |
'Double' |
'Date' |
'Time' |
'Timestamp' |
'KeyValue'.

-type 'CompressionType'() :: 'NONE' |
'LZ4' |
'ZLIB' |
'ZSTD'.

-type 'ServerError'() :: 'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError'.

-type 'AuthMethod'() :: 'AuthMethodNone' |
'AuthMethodYcaV1' |
'AuthMethodAthens'.

-type 'ProtocolVersion'() :: v0 |
v1 |
v2 |
v3 |
v4 |
v5 |
v6 |
v7 |
v8 |
v9 |
v10 |
v11 |
v12 |
v13 |
v14.

-type 'CommandSubscribe.SubType'() :: 'Exclusive' |
'Shared' |
'Failover' |
'Key_Shared'.

-type 'CommandSubscribe.InitialPosition'() :: 'Latest' |
'Earliest'.

-type
'CommandPartitionedTopicMetadataResponse.LookupType'() :: 'Success' |
'Failed'.

-type
'CommandLookupTopicResponse.LookupType'() :: 'Redirect' |
'Connect' |
'Failed'.

-type 'CommandAck.AckType'() :: 'Individual' |
'Cumulative'.

-type
'CommandAck.ValidationError'() :: 'UncompressedSizeCorruption' |
'DecompressionError' |
'ChecksumMismatch' |
'BatchDeSerializeError' |
'DecryptionError'.

-type
'CommandGetTopicsOfNamespace.Mode'() :: 'PERSISTENT' |
'NON_PERSISTENT' |
'ALL'.

-type 'BaseCommand.Type'() :: 'CONNECT' |
'CONNECTED' |
'SUBSCRIBE' |
'PRODUCER' |
'SEND' |
'SEND_RECEIPT' |
'SEND_ERROR' |
'MESSAGE' |
'ACK' |
'FLOW' |
'UNSUBSCRIBE' |
'SUCCESS' |
'ERROR' |
'CLOSE_PRODUCER' |
'CLOSE_CONSUMER' |
'PRODUCER_SUCCESS' |
'PING' |
'PONG' |
'REDELIVER_UNACKNOWLEDGED_MESSAGES' |
'PARTITIONED_METADATA' |
'PARTITIONED_METADATA_RESPONSE' |
'LOOKUP' |
'LOOKUP_RESPONSE' |
'CONSUMER_STATS' |
'CONSUMER_STATS_RESPONSE' |
'REACHED_END_OF_TOPIC' |
'SEEK' |
'GET_LAST_MESSAGE_ID' |
'GET_LAST_MESSAGE_ID_RESPONSE' |
'ACTIVE_CONSUMER_CHANGE' |
'GET_TOPICS_OF_NAMESPACE' |
'GET_TOPICS_OF_NAMESPACE_RESPONSE' |
'GET_SCHEMA' |
'GET_SCHEMA_RESPONSE' |
'AUTH_CHALLENGE' |
'AUTH_RESPONSE'.

-export_type(['Schema.Type'/0,
  'CompressionType'/0,
  'ServerError'/0,
  'AuthMethod'/0,
  'ProtocolVersion'/0,
  'CommandSubscribe.SubType'/0,
  'CommandSubscribe.InitialPosition'/0,
  'CommandPartitionedTopicMetadataResponse.LookupType'/0,
  'CommandLookupTopicResponse.LookupType'/0,
  'CommandAck.AckType'/0,
  'CommandAck.ValidationError'/0,
  'CommandGetTopicsOfNamespace.Mode'/0,
  'BaseCommand.Type'/0]).

-type 'Schema'() :: #{name := iodata(),
schema_data := iodata(),
type :=
'None' |
'String' |
'Json' |
'Protobuf' |
'Avro' |
'Bool' |
'Int8' |
'Int16' |
'Int32' |
'Int64' |
'Float' |
'Double' |
'Date' |
'Time' |
'Timestamp' |
'KeyValue' |
integer(),
properties => ['KeyValue'()]}.

-type 'MessageIdData'() :: #{ledgerId :=
non_neg_integer(),
entryId := non_neg_integer(),
partition => integer(), batch_index => integer()}.

-type 'KeyValue'() :: #{key := iodata(),
value := iodata()}.

-type 'KeyLongValue'() :: #{key := iodata(),
value := non_neg_integer()}.

-type 'EncryptionKeys'() :: #{key := iodata(),
value := iodata(), metadata => ['KeyValue'()]}.

-type 'MessageMetadata'() :: #{producer_name :=
iodata(),
sequence_id := non_neg_integer(),
publish_time := non_neg_integer(),
properties => ['KeyValue'()],
replicated_from => iodata(),
partition_key => iodata(),
replicate_to => [iodata()],
compression =>
'NONE' | 'LZ4' | 'ZLIB' | 'ZSTD' | integer(),
uncompressed_size => non_neg_integer(),
num_messages_in_batch => integer(),
event_time => non_neg_integer(),
encryption_keys => ['EncryptionKeys'()],
encryption_algo => iodata(),
encryption_param => iodata(),
schema_version => iodata(),
partition_key_b64_encoded => boolean() | 0 | 1,
ordering_key => iodata()}.

-type 'SingleMessageMetadata'() :: #{properties =>
['KeyValue'()],
partition_key => iodata(),
payload_size := integer(),
compacted_out => boolean() | 0 | 1,
event_time => non_neg_integer(),
partition_key_b64_encoded =>
boolean() | 0 | 1,
ordering_key => iodata()}.

-type 'CommandConnect'() :: #{client_version :=
iodata(),
auth_method =>
'AuthMethodNone' |
'AuthMethodYcaV1' |
'AuthMethodAthens' |
integer(),
auth_method_name => iodata(),
auth_data => iodata(),
protocol_version => integer(),
proxy_to_broker_url => iodata(),
original_principal => iodata(),
original_auth_data => iodata(),
original_auth_method => iodata()}.

-type 'CommandConnected'() :: #{server_version :=
iodata(),
protocol_version => integer()}.

-type 'CommandAuthResponse'() :: #{client_version =>
iodata(),
response => 'AuthData'(),
protocol_version => integer()}.

-type 'CommandAuthChallenge'() :: #{server_version =>
iodata(),
challenge => 'AuthData'(),
protocol_version => integer()}.

-type 'AuthData'() :: #{auth_method_name => iodata(),
auth_data => iodata()}.

-type 'CommandSubscribe'() :: #{topic := iodata(),
subscription := iodata(),
subType :=
'Exclusive' |
'Shared' |
'Failover' |
'Key_Shared' |
integer(),
consumer_id := non_neg_integer(),
request_id := non_neg_integer(),
consumer_name => iodata(),
priority_level => integer(),
durable => boolean() | 0 | 1,
start_message_id => 'MessageIdData'(),
metadata => ['KeyValue'()],
read_compacted => boolean() | 0 | 1,
schema => 'Schema'(),
initialPosition =>
'Latest' | 'Earliest' | integer()}.

-type 'CommandPartitionedTopicMetadata'() :: #{topic :=
iodata(),
request_id := non_neg_integer(),
original_principal => iodata(),
original_auth_data => iodata(),
original_auth_method =>
iodata()}.

-type
'CommandPartitionedTopicMetadataResponse'() :: #{partitions
=> non_neg_integer(),
request_id :=
non_neg_integer(),
response =>
'Success' |
'Failed' |
integer(),
error =>
'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError' |
integer(),
message => iodata()}.

-type 'CommandLookupTopic'() :: #{topic := iodata(),
request_id := non_neg_integer(),
authoritative => boolean() | 0 | 1,
original_principal => iodata(),
original_auth_data => iodata(),
original_auth_method => iodata()}.

-type
'CommandLookupTopicResponse'() :: #{brokerServiceUrl =>
iodata(),
brokerServiceUrlTls => iodata(),
response =>
'Redirect' |
'Connect' |
'Failed' |
integer(),
request_id := non_neg_integer(),
authoritative => boolean() | 0 | 1,
error =>
'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError' |
integer(),
message => iodata(),
proxy_through_service_url =>
boolean() | 0 | 1}.

-type 'CommandProducer'() :: #{topic := iodata(),
producer_id := non_neg_integer(),
request_id := non_neg_integer(),
producer_name => iodata(),
encrypted => boolean() | 0 | 1,
metadata => ['KeyValue'()],
schema => 'Schema'()}.

-type 'CommandSend'() :: #{producer_id :=
non_neg_integer(),
sequence_id := non_neg_integer(),
num_messages => integer()}.

-type 'CommandSendReceipt'() :: #{producer_id :=
non_neg_integer(),
sequence_id := non_neg_integer(),
message_id => 'MessageIdData'()}.

-type 'CommandSendError'() :: #{producer_id :=
non_neg_integer(),
sequence_id := non_neg_integer(),
error :=
'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError' |
integer(),
message := iodata()}.

-type 'CommandMessage'() :: #{consumer_id :=
non_neg_integer(),
message_id := 'MessageIdData'(),
redelivery_count => non_neg_integer()}.

-type 'CommandAck'() :: #{consumer_id :=
non_neg_integer(),
ack_type := 'Individual' | 'Cumulative' | integer(),
message_id => ['MessageIdData'()],
validation_error =>
'UncompressedSizeCorruption' |
'DecompressionError' |
'ChecksumMismatch' |
'BatchDeSerializeError' |
'DecryptionError' |
integer(),
properties => ['KeyLongValue'()]}.

-type 'CommandActiveConsumerChange'() :: #{consumer_id
:= non_neg_integer(),
is_active => boolean() | 0 | 1}.

-type 'CommandFlow'() :: #{consumer_id :=
non_neg_integer(),
messagePermits := non_neg_integer()}.

-type 'CommandUnsubscribe'() :: #{consumer_id :=
non_neg_integer(),
request_id := non_neg_integer()}.

-type 'CommandSeek'() :: #{consumer_id :=
non_neg_integer(),
request_id := non_neg_integer(),
message_id => 'MessageIdData'(),
message_publish_time => non_neg_integer()}.

-type 'CommandReachedEndOfTopic'() :: #{consumer_id :=
non_neg_integer()}.

-type 'CommandCloseProducer'() :: #{producer_id :=
non_neg_integer(),
request_id := non_neg_integer()}.

-type 'CommandCloseConsumer'() :: #{consumer_id :=
non_neg_integer(),
request_id := non_neg_integer()}.

-type
'CommandRedeliverUnacknowledgedMessages'() :: #{consumer_id
:= non_neg_integer(),
message_ids =>
['MessageIdData'()]}.

-type 'CommandSuccess'() :: #{request_id :=
non_neg_integer(),
schema => 'Schema'()}.

-type 'CommandProducerSuccess'() :: #{request_id :=
non_neg_integer(),
producer_name := iodata(),
last_sequence_id => integer(),
schema_version => iodata()}.

-type 'CommandError'() :: #{request_id :=
non_neg_integer(),
error :=
'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError' |
integer(),
message := iodata()}.

-type 'CommandPing'() :: #{}.

-type 'CommandPong'() :: #{}.

-type 'CommandConsumerStats'() :: #{request_id :=
non_neg_integer(),
consumer_id := non_neg_integer()}.

-type 'CommandConsumerStatsResponse'() :: #{request_id
:= non_neg_integer(),
error_code =>
'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError' |
integer(),
error_message => iodata(),
msgRateOut =>
float() |
integer() |
infinity |
'-infinity' |
nan,
msgThroughputOut =>
float() |
integer() |
infinity |
'-infinity' |
nan,
msgRateRedeliver =>
float() |
integer() |
infinity |
'-infinity' |
nan,
consumerName => iodata(),
availablePermits =>
non_neg_integer(),
unackedMessages =>
non_neg_integer(),
blockedConsumerOnUnackedMsgs =>
boolean() | 0 | 1,
address => iodata(),
connectedSince => iodata(),
type => iodata(),
msgRateExpired =>
float() |
integer() |
infinity |
'-infinity' |
nan,
msgBacklog => non_neg_integer()}.

-type 'CommandGetLastMessageId'() :: #{consumer_id :=
non_neg_integer(),
request_id := non_neg_integer()}.

-type
'CommandGetLastMessageIdResponse'() :: #{last_message_id
:= 'MessageIdData'(),
request_id := non_neg_integer()}.

-type 'CommandGetTopicsOfNamespace'() :: #{request_id :=
non_neg_integer(),
namespace := iodata(),
mode =>
'PERSISTENT' |
'NON_PERSISTENT' |
'ALL' |
integer()}.

-type
'CommandGetTopicsOfNamespaceResponse'() :: #{request_id
:= non_neg_integer(),
topics => [iodata()]}.

-type 'CommandGetSchema'() :: #{request_id :=
non_neg_integer(),
topic := iodata(), schema_version => iodata()}.

-type 'CommandGetSchemaResponse'() :: #{request_id :=
non_neg_integer(),
error_code =>
'UnknownError' |
'MetadataError' |
'PersistenceError' |
'AuthenticationError' |
'AuthorizationError' |
'ConsumerBusy' |
'ServiceNotReady' |
'ProducerBlockedQuotaExceededError' |
'ProducerBlockedQuotaExceededException' |
'ChecksumError' |
'UnsupportedVersionError' |
'TopicNotFound' |
'SubscriptionNotFound' |
'ConsumerNotFound' |
'TooManyRequests' |
'TopicTerminatedError' |
'ProducerBusy' |
'InvalidTopicName' |
'IncompatibleSchema' |
'ConsumerAssignError' |
integer(),
error_message => iodata(),
schema => 'Schema'(),
schema_version => iodata()}.

-type 'BaseCommand'() :: #{type :=
'CONNECT' |
'CONNECTED' |
'SUBSCRIBE' |
'PRODUCER' |
'SEND' |
'SEND_RECEIPT' |
'SEND_ERROR' |
'MESSAGE' |
'ACK' |
'FLOW' |
'UNSUBSCRIBE' |
'SUCCESS' |
'ERROR' |
'CLOSE_PRODUCER' |
'CLOSE_CONSUMER' |
'PRODUCER_SUCCESS' |
'PING' |
'PONG' |
'REDELIVER_UNACKNOWLEDGED_MESSAGES' |
'PARTITIONED_METADATA' |
'PARTITIONED_METADATA_RESPONSE' |
'LOOKUP' |
'LOOKUP_RESPONSE' |
'CONSUMER_STATS' |
'CONSUMER_STATS_RESPONSE' |
'REACHED_END_OF_TOPIC' |
'SEEK' |
'GET_LAST_MESSAGE_ID' |
'GET_LAST_MESSAGE_ID_RESPONSE' |
'ACTIVE_CONSUMER_CHANGE' |
'GET_TOPICS_OF_NAMESPACE' |
'GET_TOPICS_OF_NAMESPACE_RESPONSE' |
'GET_SCHEMA' |
'GET_SCHEMA_RESPONSE' |
'AUTH_CHALLENGE' |
'AUTH_RESPONSE' |
integer(),
connect => 'CommandConnect'(),
connected => 'CommandConnected'(),
subscribe => 'CommandSubscribe'(),
producer => 'CommandProducer'(),
send => 'CommandSend'(),
send_receipt => 'CommandSendReceipt'(),
send_error => 'CommandSendError'(),
message => 'CommandMessage'(), ack => 'CommandAck'(),
flow => 'CommandFlow'(),
unsubscribe => 'CommandUnsubscribe'(),
success => 'CommandSuccess'(),
error => 'CommandError'(),
close_producer => 'CommandCloseProducer'(),
close_consumer => 'CommandCloseConsumer'(),
producer_success => 'CommandProducerSuccess'(),
ping => 'CommandPing'(), pong => 'CommandPong'(),
redeliverUnacknowledgedMessages =>
'CommandRedeliverUnacknowledgedMessages'(),
partitionMetadata =>
'CommandPartitionedTopicMetadata'(),
partitionMetadataResponse =>
'CommandPartitionedTopicMetadataResponse'(),
lookupTopic => 'CommandLookupTopic'(),
lookupTopicResponse =>
'CommandLookupTopicResponse'(),
consumerStats => 'CommandConsumerStats'(),
consumerStatsResponse =>
'CommandConsumerStatsResponse'(),
reachedEndOfTopic => 'CommandReachedEndOfTopic'(),
seek => 'CommandSeek'(),
getLastMessageId => 'CommandGetLastMessageId'(),
getLastMessageIdResponse =>
'CommandGetLastMessageIdResponse'(),
active_consumer_change =>
'CommandActiveConsumerChange'(),
getTopicsOfNamespace =>
'CommandGetTopicsOfNamespace'(),
getTopicsOfNamespaceResponse =>
'CommandGetTopicsOfNamespaceResponse'(),
getSchema => 'CommandGetSchema'(),
getSchemaResponse => 'CommandGetSchemaResponse'(),
authChallenge => 'CommandAuthChallenge'(),
authResponse => 'CommandAuthResponse'()}.

-export_type(['Schema'/0,
  'MessageIdData'/0,
  'KeyValue'/0,
  'KeyLongValue'/0,
  'EncryptionKeys'/0,
  'MessageMetadata'/0,
  'SingleMessageMetadata'/0,
  'CommandConnect'/0,
  'CommandConnected'/0,
  'CommandAuthResponse'/0,
  'CommandAuthChallenge'/0,
  'AuthData'/0,
  'CommandSubscribe'/0,
  'CommandPartitionedTopicMetadata'/0,
  'CommandPartitionedTopicMetadataResponse'/0,
  'CommandLookupTopic'/0,
  'CommandLookupTopicResponse'/0,
  'CommandProducer'/0,
  'CommandSend'/0,
  'CommandSendReceipt'/0,
  'CommandSendError'/0,
  'CommandMessage'/0,
  'CommandAck'/0,
  'CommandActiveConsumerChange'/0,
  'CommandFlow'/0,
  'CommandUnsubscribe'/0,
  'CommandSeek'/0,
  'CommandReachedEndOfTopic'/0,
  'CommandCloseProducer'/0,
  'CommandCloseConsumer'/0,
  'CommandRedeliverUnacknowledgedMessages'/0,
  'CommandSuccess'/0,
  'CommandProducerSuccess'/0,
  'CommandError'/0,
  'CommandPing'/0,
  'CommandPong'/0,
  'CommandConsumerStats'/0,
  'CommandConsumerStatsResponse'/0,
  'CommandGetLastMessageId'/0,
  'CommandGetLastMessageIdResponse'/0,
  'CommandGetTopicsOfNamespace'/0,
  'CommandGetTopicsOfNamespaceResponse'/0,
  'CommandGetSchema'/0,
  'CommandGetSchemaResponse'/0,
  'BaseCommand'/0]).

-spec encode_msg('Schema'() |
'MessageIdData'() |
'KeyValue'() |
'KeyLongValue'() |
'EncryptionKeys'() |
'MessageMetadata'() |
'SingleMessageMetadata'() |
'CommandConnect'() |
'CommandConnected'() |
'CommandAuthResponse'() |
'CommandAuthChallenge'() |
'AuthData'() |
'CommandSubscribe'() |
'CommandPartitionedTopicMetadata'() |
'CommandPartitionedTopicMetadataResponse'() |
'CommandLookupTopic'() |
'CommandLookupTopicResponse'() |
'CommandProducer'() |
'CommandSend'() |
'CommandSendReceipt'() |
'CommandSendError'() |
'CommandMessage'() |
'CommandAck'() |
'CommandActiveConsumerChange'() |
'CommandFlow'() |
'CommandUnsubscribe'() |
'CommandSeek'() |
'CommandReachedEndOfTopic'() |
'CommandCloseProducer'() |
'CommandCloseConsumer'() |
'CommandRedeliverUnacknowledgedMessages'() |
'CommandSuccess'() |
'CommandProducerSuccess'() |
'CommandError'() |
'CommandPing'() |
'CommandPong'() |
'CommandConsumerStats'() |
'CommandConsumerStatsResponse'() |
'CommandGetLastMessageId'() |
'CommandGetLastMessageIdResponse'() |
'CommandGetTopicsOfNamespace'() |
'CommandGetTopicsOfNamespaceResponse'() |
'CommandGetSchema'() |
'CommandGetSchemaResponse'() |
'BaseCommand'(),
    atom()) -> binary().

-vsn("4.2.5").

encode_msg(Msg, MsgName) when is_atom(MsgName) ->
  encode_msg(Msg, MsgName, []).

-spec encode_msg('Schema'() |
'MessageIdData'() |
'KeyValue'() |
'KeyLongValue'() |
'EncryptionKeys'() |
'MessageMetadata'() |
'SingleMessageMetadata'() |
'CommandConnect'() |
'CommandConnected'() |
'CommandAuthResponse'() |
'CommandAuthChallenge'() |
'AuthData'() |
'CommandSubscribe'() |
'CommandPartitionedTopicMetadata'() |
'CommandPartitionedTopicMetadataResponse'() |
'CommandLookupTopic'() |
'CommandLookupTopicResponse'() |
'CommandProducer'() |
'CommandSend'() |
'CommandSendReceipt'() |
'CommandSendError'() |
'CommandMessage'() |
'CommandAck'() |
'CommandActiveConsumerChange'() |
'CommandFlow'() |
'CommandUnsubscribe'() |
'CommandSeek'() |
'CommandReachedEndOfTopic'() |
'CommandCloseProducer'() |
'CommandCloseConsumer'() |
'CommandRedeliverUnacknowledgedMessages'() |
'CommandSuccess'() |
'CommandProducerSuccess'() |
'CommandError'() |
'CommandPing'() |
'CommandPong'() |
'CommandConsumerStats'() |
'CommandConsumerStatsResponse'() |
'CommandGetLastMessageId'() |
'CommandGetLastMessageIdResponse'() |
'CommandGetTopicsOfNamespace'() |
'CommandGetTopicsOfNamespaceResponse'() |
'CommandGetSchema'() |
'CommandGetSchemaResponse'() |
'BaseCommand'(),
    atom(), list()) -> binary().

encode_msg(Msg, MsgName, Opts) ->
  verify_msg(Msg, MsgName, Opts),
  TrUserData = proplists:get_value(user_data, Opts),
  case MsgName of
    'Schema' ->
      encode_msg_Schema(id(Msg, TrUserData), TrUserData);
    'MessageIdData' ->
      encode_msg_MessageIdData(id(Msg, TrUserData),
        TrUserData);
    'KeyValue' ->
      encode_msg_KeyValue(id(Msg, TrUserData), TrUserData);
    'KeyLongValue' ->
      encode_msg_KeyLongValue(id(Msg, TrUserData),
        TrUserData);
    'EncryptionKeys' ->
      encode_msg_EncryptionKeys(id(Msg, TrUserData),
        TrUserData);
    'MessageMetadata' ->
      encode_msg_MessageMetadata(id(Msg, TrUserData),
        TrUserData);
    'SingleMessageMetadata' ->
      encode_msg_SingleMessageMetadata(id(Msg, TrUserData),
        TrUserData);
    'CommandConnect' ->
      encode_msg_CommandConnect(id(Msg, TrUserData),
        TrUserData);
    'CommandConnected' ->
      encode_msg_CommandConnected(id(Msg, TrUserData),
        TrUserData);
    'CommandAuthResponse' ->
      encode_msg_CommandAuthResponse(id(Msg, TrUserData),
        TrUserData);
    'CommandAuthChallenge' ->
      encode_msg_CommandAuthChallenge(id(Msg, TrUserData),
        TrUserData);
    'AuthData' ->
      encode_msg_AuthData(id(Msg, TrUserData), TrUserData);
    'CommandSubscribe' ->
      encode_msg_CommandSubscribe(id(Msg, TrUserData),
        TrUserData);
    'CommandPartitionedTopicMetadata' ->
      encode_msg_CommandPartitionedTopicMetadata(id(Msg,
        TrUserData),
        TrUserData);
    'CommandPartitionedTopicMetadataResponse' ->
      encode_msg_CommandPartitionedTopicMetadataResponse(id(Msg,
        TrUserData),
        TrUserData);
    'CommandLookupTopic' ->
      encode_msg_CommandLookupTopic(id(Msg, TrUserData),
        TrUserData);
    'CommandLookupTopicResponse' ->
      encode_msg_CommandLookupTopicResponse(id(Msg,
        TrUserData),
        TrUserData);
    'CommandProducer' ->
      encode_msg_CommandProducer(id(Msg, TrUserData),
        TrUserData);
    'CommandSend' ->
      encode_msg_CommandSend(id(Msg, TrUserData), TrUserData);
    'CommandSendReceipt' ->
      encode_msg_CommandSendReceipt(id(Msg, TrUserData),
        TrUserData);
    'CommandSendError' ->
      encode_msg_CommandSendError(id(Msg, TrUserData),
        TrUserData);
    'CommandMessage' ->
      encode_msg_CommandMessage(id(Msg, TrUserData),
        TrUserData);
    'CommandAck' ->
      encode_msg_CommandAck(id(Msg, TrUserData), TrUserData);
    'CommandActiveConsumerChange' ->
      encode_msg_CommandActiveConsumerChange(id(Msg,
        TrUserData),
        TrUserData);
    'CommandFlow' ->
      encode_msg_CommandFlow(id(Msg, TrUserData), TrUserData);
    'CommandUnsubscribe' ->
      encode_msg_CommandUnsubscribe(id(Msg, TrUserData),
        TrUserData);
    'CommandSeek' ->
      encode_msg_CommandSeek(id(Msg, TrUserData), TrUserData);
    'CommandReachedEndOfTopic' ->
      encode_msg_CommandReachedEndOfTopic(id(Msg, TrUserData),
        TrUserData);
    'CommandCloseProducer' ->
      encode_msg_CommandCloseProducer(id(Msg, TrUserData),
        TrUserData);
    'CommandCloseConsumer' ->
      encode_msg_CommandCloseConsumer(id(Msg, TrUserData),
        TrUserData);
    'CommandRedeliverUnacknowledgedMessages' ->
      encode_msg_CommandRedeliverUnacknowledgedMessages(id(Msg,
        TrUserData),
        TrUserData);
    'CommandSuccess' ->
      encode_msg_CommandSuccess(id(Msg, TrUserData),
        TrUserData);
    'CommandProducerSuccess' ->
      encode_msg_CommandProducerSuccess(id(Msg, TrUserData),
        TrUserData);
    'CommandError' ->
      encode_msg_CommandError(id(Msg, TrUserData),
        TrUserData);
    'CommandPing' ->
      encode_msg_CommandPing(id(Msg, TrUserData), TrUserData);
    'CommandPong' ->
      encode_msg_CommandPong(id(Msg, TrUserData), TrUserData);
    'CommandConsumerStats' ->
      encode_msg_CommandConsumerStats(id(Msg, TrUserData),
        TrUserData);
    'CommandConsumerStatsResponse' ->
      encode_msg_CommandConsumerStatsResponse(id(Msg,
        TrUserData),
        TrUserData);
    'CommandGetLastMessageId' ->
      encode_msg_CommandGetLastMessageId(id(Msg, TrUserData),
        TrUserData);
    'CommandGetLastMessageIdResponse' ->
      encode_msg_CommandGetLastMessageIdResponse(id(Msg,
        TrUserData),
        TrUserData);
    'CommandGetTopicsOfNamespace' ->
      encode_msg_CommandGetTopicsOfNamespace(id(Msg,
        TrUserData),
        TrUserData);
    'CommandGetTopicsOfNamespaceResponse' ->
      encode_msg_CommandGetTopicsOfNamespaceResponse(id(Msg,
        TrUserData),
        TrUserData);
    'CommandGetSchema' ->
      encode_msg_CommandGetSchema(id(Msg, TrUserData),
        TrUserData);
    'CommandGetSchemaResponse' ->
      encode_msg_CommandGetSchemaResponse(id(Msg, TrUserData),
        TrUserData);
    'BaseCommand' ->
      encode_msg_BaseCommand(id(Msg, TrUserData), TrUserData)
  end.

encode_msg_Schema(Msg, TrUserData) ->
  encode_msg_Schema(Msg, <<>>, TrUserData).

encode_msg_Schema(#{name := F1, schema_data := F2,
  type := F3} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_type_bytes(TrF2, <<B1/binary, 26>>, TrUserData)
       end,
  B3 = begin
         TrF3 = id(F3, TrUserData),
         'e_enum_Schema.Type'(TrF3,
           <<B2/binary, 32>>,
           TrUserData)
       end,
  case M of
    #{properties := F4} ->
      TrF4 = id(F4, TrUserData),
      if TrF4 == [] -> B3;
        true -> e_field_Schema_properties(TrF4, B3, TrUserData)
      end;
    _ -> B3
  end.

encode_msg_MessageIdData(Msg, TrUserData) ->
  encode_msg_MessageIdData(Msg, <<>>, TrUserData).

encode_msg_MessageIdData(#{ledgerId := F1,
  entryId := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = case M of
         #{partition := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_int32(TrF3, <<B2/binary, 24>>, TrUserData)
           end;
         _ -> B2
       end,
  case M of
    #{batch_index := F4} ->
      begin
        TrF4 = id(F4, TrUserData),
        e_type_int32(TrF4, <<B3/binary, 32>>, TrUserData)
      end;
    _ -> B3
  end.

encode_msg_KeyValue(Msg, TrUserData) ->
  encode_msg_KeyValue(Msg, <<>>, TrUserData).

encode_msg_KeyValue(#{key := F1, value := F2}, Bin,
    TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
  end.

encode_msg_KeyLongValue(Msg, TrUserData) ->
  encode_msg_KeyLongValue(Msg, <<>>, TrUserData).

encode_msg_KeyLongValue(#{key := F1, value := F2}, Bin,
    TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_EncryptionKeys(Msg, TrUserData) ->
  encode_msg_EncryptionKeys(Msg, <<>>, TrUserData).

encode_msg_EncryptionKeys(#{key := F1, value := F2} = M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_type_bytes(TrF2, <<B1/binary, 18>>, TrUserData)
       end,
  case M of
    #{metadata := F3} ->
      TrF3 = id(F3, TrUserData),
      if TrF3 == [] -> B2;
        true ->
          e_field_EncryptionKeys_metadata(TrF3, B2, TrUserData)
      end;
    _ -> B2
  end.

encode_msg_MessageMetadata(Msg, TrUserData) ->
  encode_msg_MessageMetadata(Msg, <<>>, TrUserData).

encode_msg_MessageMetadata(#{producer_name := F1,
  sequence_id := F2, publish_time := F3} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = begin
         TrF3 = id(F3, TrUserData),
         e_varint(TrF3, <<B2/binary, 24>>, TrUserData)
       end,
  B4 = case M of
         #{properties := F4} ->
           TrF4 = id(F4, TrUserData),
           if TrF4 == [] -> B3;
             true ->
               e_field_MessageMetadata_properties(TrF4, B3, TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{replicated_from := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_type_string(TrF5, <<B4/binary, 42>>, TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{partition_key := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_type_string(TrF6, <<B5/binary, 50>>, TrUserData)
           end;
         _ -> B5
       end,
  B7 = case M of
         #{replicate_to := F7} ->
           TrF7 = id(F7, TrUserData),
           if TrF7 == [] -> B6;
             true ->
               e_field_MessageMetadata_replicate_to(TrF7,
                 B6,
                 TrUserData)
           end;
         _ -> B6
       end,
  B8 = case M of
         #{compression := F8} ->
           begin
             TrF8 = id(F8, TrUserData),
             e_enum_CompressionType(TrF8,
               <<B7/binary, 64>>,
               TrUserData)
           end;
         _ -> B7
       end,
  B9 = case M of
         #{uncompressed_size := F9} ->
           begin
             TrF9 = id(F9, TrUserData),
             e_varint(TrF9, <<B8/binary, 72>>, TrUserData)
           end;
         _ -> B8
       end,
  B10 = case M of
          #{num_messages_in_batch := F10} ->
            begin
              TrF10 = id(F10, TrUserData),
              e_type_int32(TrF10, <<B9/binary, 88>>, TrUserData)
            end;
          _ -> B9
        end,
  B11 = case M of
          #{event_time := F11} ->
            begin
              TrF11 = id(F11, TrUserData),
              e_varint(TrF11, <<B10/binary, 96>>, TrUserData)
            end;
          _ -> B10
        end,
  B12 = case M of
          #{encryption_keys := F12} ->
            TrF12 = id(F12, TrUserData),
            if TrF12 == [] -> B11;
              true ->
                e_field_MessageMetadata_encryption_keys(TrF12,
                  B11,
                  TrUserData)
            end;
          _ -> B11
        end,
  B13 = case M of
          #{encryption_algo := F13} ->
            begin
              TrF13 = id(F13, TrUserData),
              e_type_string(TrF13, <<B12/binary, 114>>, TrUserData)
            end;
          _ -> B12
        end,
  B14 = case M of
          #{encryption_param := F14} ->
            begin
              TrF14 = id(F14, TrUserData),
              e_type_bytes(TrF14, <<B13/binary, 122>>, TrUserData)
            end;
          _ -> B13
        end,
  B15 = case M of
          #{schema_version := F15} ->
            begin
              TrF15 = id(F15, TrUserData),
              e_type_bytes(TrF15, <<B14/binary, 130, 1>>, TrUserData)
            end;
          _ -> B14
        end,
  B16 = case M of
          #{partition_key_b64_encoded := F16} ->
            begin
              TrF16 = id(F16, TrUserData),
              e_type_bool(TrF16, <<B15/binary, 136, 1>>, TrUserData)
            end;
          _ -> B15
        end,
  case M of
    #{ordering_key := F17} ->
      begin
        TrF17 = id(F17, TrUserData),
        e_type_bytes(TrF17, <<B16/binary, 146, 1>>, TrUserData)
      end;
    _ -> B16
  end.

encode_msg_SingleMessageMetadata(Msg, TrUserData) ->
  encode_msg_SingleMessageMetadata(Msg, <<>>, TrUserData).

encode_msg_SingleMessageMetadata(#{payload_size := F3} =
  M,
    Bin, TrUserData) ->
  B1 = case M of
         #{properties := F1} ->
           TrF1 = id(F1, TrUserData),
           if TrF1 == [] -> Bin;
             true ->
               e_field_SingleMessageMetadata_properties(TrF1,
                 Bin,
                 TrUserData)
           end;
         _ -> Bin
       end,
  B2 = case M of
         #{partition_key := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
           end;
         _ -> B1
       end,
  B3 = begin
         TrF3 = id(F3, TrUserData),
         e_type_int32(TrF3, <<B2/binary, 24>>, TrUserData)
       end,
  B4 = case M of
         #{compacted_out := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_type_bool(TrF4, <<B3/binary, 32>>, TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{event_time := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_varint(TrF5, <<B4/binary, 40>>, TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{partition_key_b64_encoded := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_type_bool(TrF6, <<B5/binary, 48>>, TrUserData)
           end;
         _ -> B5
       end,
  case M of
    #{ordering_key := F7} ->
      begin
        TrF7 = id(F7, TrUserData),
        e_type_bytes(TrF7, <<B6/binary, 58>>, TrUserData)
      end;
    _ -> B6
  end.

encode_msg_CommandConnect(Msg, TrUserData) ->
  encode_msg_CommandConnect(Msg, <<>>, TrUserData).

encode_msg_CommandConnect(#{client_version := F1} = M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = case M of
         #{auth_method := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_enum_AuthMethod(TrF2, <<B1/binary, 16>>, TrUserData)
           end;
         _ -> B1
       end,
  B3 = case M of
         #{auth_method_name := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_string(TrF3, <<B2/binary, 42>>, TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{auth_data := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_type_bytes(TrF4, <<B3/binary, 26>>, TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{protocol_version := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_type_int32(TrF5, <<B4/binary, 32>>, TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{proxy_to_broker_url := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_type_string(TrF6, <<B5/binary, 50>>, TrUserData)
           end;
         _ -> B5
       end,
  B7 = case M of
         #{original_principal := F7} ->
           begin
             TrF7 = id(F7, TrUserData),
             e_type_string(TrF7, <<B6/binary, 58>>, TrUserData)
           end;
         _ -> B6
       end,
  B8 = case M of
         #{original_auth_data := F8} ->
           begin
             TrF8 = id(F8, TrUserData),
             e_type_string(TrF8, <<B7/binary, 66>>, TrUserData)
           end;
         _ -> B7
       end,
  case M of
    #{original_auth_method := F9} ->
      begin
        TrF9 = id(F9, TrUserData),
        e_type_string(TrF9, <<B8/binary, 74>>, TrUserData)
      end;
    _ -> B8
  end.

encode_msg_CommandConnected(Msg, TrUserData) ->
  encode_msg_CommandConnected(Msg, <<>>, TrUserData).

encode_msg_CommandConnected(#{server_version := F1} = M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  case M of
    #{protocol_version := F2} ->
      begin
        TrF2 = id(F2, TrUserData),
        e_type_int32(TrF2, <<B1/binary, 16>>, TrUserData)
      end;
    _ -> B1
  end.

encode_msg_CommandAuthResponse(Msg, TrUserData) ->
  encode_msg_CommandAuthResponse(Msg, <<>>, TrUserData).

encode_msg_CommandAuthResponse(#{} = M, Bin,
    TrUserData) ->
  B1 = case M of
         #{client_version := F1} ->
           begin
             TrF1 = id(F1, TrUserData),
             e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
           end;
         _ -> Bin
       end,
  B2 = case M of
         #{response := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_mfield_CommandAuthResponse_response(TrF2,
               <<B1/binary, 18>>,
               TrUserData)
           end;
         _ -> B1
       end,
  case M of
    #{protocol_version := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        e_type_int32(TrF3, <<B2/binary, 24>>, TrUserData)
      end;
    _ -> B2
  end.

encode_msg_CommandAuthChallenge(Msg, TrUserData) ->
  encode_msg_CommandAuthChallenge(Msg, <<>>, TrUserData).

encode_msg_CommandAuthChallenge(#{} = M, Bin,
    TrUserData) ->
  B1 = case M of
         #{server_version := F1} ->
           begin
             TrF1 = id(F1, TrUserData),
             e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
           end;
         _ -> Bin
       end,
  B2 = case M of
         #{challenge := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_mfield_CommandAuthChallenge_challenge(TrF2,
               <<B1/binary, 18>>,
               TrUserData)
           end;
         _ -> B1
       end,
  case M of
    #{protocol_version := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        e_type_int32(TrF3, <<B2/binary, 24>>, TrUserData)
      end;
    _ -> B2
  end.

encode_msg_AuthData(Msg, TrUserData) ->
  encode_msg_AuthData(Msg, <<>>, TrUserData).

encode_msg_AuthData(#{} = M, Bin, TrUserData) ->
  B1 = case M of
         #{auth_method_name := F1} ->
           begin
             TrF1 = id(F1, TrUserData),
             e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
           end;
         _ -> Bin
       end,
  case M of
    #{auth_data := F2} ->
      begin
        TrF2 = id(F2, TrUserData),
        e_type_bytes(TrF2, <<B1/binary, 18>>, TrUserData)
      end;
    _ -> B1
  end.

encode_msg_CommandSubscribe(Msg, TrUserData) ->
  encode_msg_CommandSubscribe(Msg, <<>>, TrUserData).

encode_msg_CommandSubscribe(#{topic := F1,
  subscription := F2, subType := F3,
  consumer_id := F4, request_id := F5} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
       end,
  B3 = begin
         TrF3 = id(F3, TrUserData),
         'e_enum_CommandSubscribe.SubType'(TrF3,
           <<B2/binary, 24>>,
           TrUserData)
       end,
  B4 = begin
         TrF4 = id(F4, TrUserData),
         e_varint(TrF4, <<B3/binary, 32>>, TrUserData)
       end,
  B5 = begin
         TrF5 = id(F5, TrUserData),
         e_varint(TrF5, <<B4/binary, 40>>, TrUserData)
       end,
  B6 = case M of
         #{consumer_name := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_type_string(TrF6, <<B5/binary, 50>>, TrUserData)
           end;
         _ -> B5
       end,
  B7 = case M of
         #{priority_level := F7} ->
           begin
             TrF7 = id(F7, TrUserData),
             e_type_int32(TrF7, <<B6/binary, 56>>, TrUserData)
           end;
         _ -> B6
       end,
  B8 = case M of
         #{durable := F8} ->
           begin
             TrF8 = id(F8, TrUserData),
             e_type_bool(TrF8, <<B7/binary, 64>>, TrUserData)
           end;
         _ -> B7
       end,
  B9 = case M of
         #{start_message_id := F9} ->
           begin
             TrF9 = id(F9, TrUserData),
             e_mfield_CommandSubscribe_start_message_id(TrF9,
               <<B8/binary,
                 74>>,
               TrUserData)
           end;
         _ -> B8
       end,
  B10 = case M of
          #{metadata := F10} ->
            TrF10 = id(F10, TrUserData),
            if TrF10 == [] -> B9;
              true ->
                e_field_CommandSubscribe_metadata(TrF10,
                  B9,
                  TrUserData)
            end;
          _ -> B9
        end,
  B11 = case M of
          #{read_compacted := F11} ->
            begin
              TrF11 = id(F11, TrUserData),
              e_type_bool(TrF11, <<B10/binary, 88>>, TrUserData)
            end;
          _ -> B10
        end,
  B12 = case M of
          #{schema := F12} ->
            begin
              TrF12 = id(F12, TrUserData),
              e_mfield_CommandSubscribe_schema(TrF12,
                <<B11/binary, 98>>,
                TrUserData)
            end;
          _ -> B11
        end,
  case M of
    #{initialPosition := F13} ->
      begin
        TrF13 = id(F13, TrUserData),
        'e_enum_CommandSubscribe.InitialPosition'(TrF13,
          <<B12/binary, 104>>,
          TrUserData)
      end;
    _ -> B12
  end.

encode_msg_CommandPartitionedTopicMetadata(Msg,
    TrUserData) ->
  encode_msg_CommandPartitionedTopicMetadata(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandPartitionedTopicMetadata(#{topic :=
F1,
  request_id := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = case M of
         #{original_principal := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_string(TrF3, <<B2/binary, 26>>, TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{original_auth_data := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_type_string(TrF4, <<B3/binary, 34>>, TrUserData)
           end;
         _ -> B3
       end,
  case M of
    #{original_auth_method := F5} ->
      begin
        TrF5 = id(F5, TrUserData),
        e_type_string(TrF5, <<B4/binary, 42>>, TrUserData)
      end;
    _ -> B4
  end.

encode_msg_CommandPartitionedTopicMetadataResponse(Msg,
    TrUserData) ->
  encode_msg_CommandPartitionedTopicMetadataResponse(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandPartitionedTopicMetadataResponse(#{request_id
:= F2} =
  M,
    Bin, TrUserData) ->
  B1 = case M of
         #{partitions := F1} ->
           begin
             TrF1 = id(F1, TrUserData),
             e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
           end;
         _ -> Bin
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = case M of
         #{response := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             'e_enum_CommandPartitionedTopicMetadataResponse.LookupType'(TrF3,
               <<B2/binary,
                 24>>,
               TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{error := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_enum_ServerError(TrF4, <<B3/binary, 32>>, TrUserData)
           end;
         _ -> B3
       end,
  case M of
    #{message := F5} ->
      begin
        TrF5 = id(F5, TrUserData),
        e_type_string(TrF5, <<B4/binary, 42>>, TrUserData)
      end;
    _ -> B4
  end.

encode_msg_CommandLookupTopic(Msg, TrUserData) ->
  encode_msg_CommandLookupTopic(Msg, <<>>, TrUserData).

encode_msg_CommandLookupTopic(#{topic := F1,
  request_id := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = case M of
         #{authoritative := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_bool(TrF3, <<B2/binary, 24>>, TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{original_principal := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_type_string(TrF4, <<B3/binary, 34>>, TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{original_auth_data := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_type_string(TrF5, <<B4/binary, 42>>, TrUserData)
           end;
         _ -> B4
       end,
  case M of
    #{original_auth_method := F6} ->
      begin
        TrF6 = id(F6, TrUserData),
        e_type_string(TrF6, <<B5/binary, 50>>, TrUserData)
      end;
    _ -> B5
  end.

encode_msg_CommandLookupTopicResponse(Msg,
    TrUserData) ->
  encode_msg_CommandLookupTopicResponse(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandLookupTopicResponse(#{request_id :=
F4} =
  M,
    Bin, TrUserData) ->
  B1 = case M of
         #{brokerServiceUrl := F1} ->
           begin
             TrF1 = id(F1, TrUserData),
             e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
           end;
         _ -> Bin
       end,
  B2 = case M of
         #{brokerServiceUrlTls := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
           end;
         _ -> B1
       end,
  B3 = case M of
         #{response := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             'e_enum_CommandLookupTopicResponse.LookupType'(TrF3,
               <<B2/binary,
                 24>>,
               TrUserData)
           end;
         _ -> B2
       end,
  B4 = begin
         TrF4 = id(F4, TrUserData),
         e_varint(TrF4, <<B3/binary, 32>>, TrUserData)
       end,
  B5 = case M of
         #{authoritative := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_type_bool(TrF5, <<B4/binary, 40>>, TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{error := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_enum_ServerError(TrF6, <<B5/binary, 48>>, TrUserData)
           end;
         _ -> B5
       end,
  B7 = case M of
         #{message := F7} ->
           begin
             TrF7 = id(F7, TrUserData),
             e_type_string(TrF7, <<B6/binary, 58>>, TrUserData)
           end;
         _ -> B6
       end,
  case M of
    #{proxy_through_service_url := F8} ->
      begin
        TrF8 = id(F8, TrUserData),
        e_type_bool(TrF8, <<B7/binary, 64>>, TrUserData)
      end;
    _ -> B7
  end.

encode_msg_CommandProducer(Msg, TrUserData) ->
  encode_msg_CommandProducer(Msg, <<>>, TrUserData).

encode_msg_CommandProducer(#{topic := F1,
  producer_id := F2, request_id := F3} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_type_string(TrF1, <<Bin/binary, 10>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = begin
         TrF3 = id(F3, TrUserData),
         e_varint(TrF3, <<B2/binary, 24>>, TrUserData)
       end,
  B4 = case M of
         #{producer_name := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_type_string(TrF4, <<B3/binary, 34>>, TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{encrypted := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_type_bool(TrF5, <<B4/binary, 40>>, TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{metadata := F6} ->
           TrF6 = id(F6, TrUserData),
           if TrF6 == [] -> B5;
             true ->
               e_field_CommandProducer_metadata(TrF6, B5, TrUserData)
           end;
         _ -> B5
       end,
  case M of
    #{schema := F7} ->
      begin
        TrF7 = id(F7, TrUserData),
        e_mfield_CommandProducer_schema(TrF7,
          <<B6/binary, 58>>,
          TrUserData)
      end;
    _ -> B6
  end.

encode_msg_CommandSend(Msg, TrUserData) ->
  encode_msg_CommandSend(Msg, <<>>, TrUserData).

encode_msg_CommandSend(#{producer_id := F1,
  sequence_id := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  case M of
    #{num_messages := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        e_type_int32(TrF3, <<B2/binary, 24>>, TrUserData)
      end;
    _ -> B2
  end.

encode_msg_CommandSendReceipt(Msg, TrUserData) ->
  encode_msg_CommandSendReceipt(Msg, <<>>, TrUserData).

encode_msg_CommandSendReceipt(#{producer_id := F1,
  sequence_id := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  case M of
    #{message_id := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        e_mfield_CommandSendReceipt_message_id(TrF3,
          <<B2/binary, 26>>,
          TrUserData)
      end;
    _ -> B2
  end.

encode_msg_CommandSendError(Msg, TrUserData) ->
  encode_msg_CommandSendError(Msg, <<>>, TrUserData).

encode_msg_CommandSendError(#{producer_id := F1,
  sequence_id := F2, error := F3, message := F4},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = begin
         TrF3 = id(F3, TrUserData),
         e_enum_ServerError(TrF3, <<B2/binary, 24>>, TrUserData)
       end,
  begin
    TrF4 = id(F4, TrUserData),
    e_type_string(TrF4, <<B3/binary, 34>>, TrUserData)
  end.

encode_msg_CommandMessage(Msg, TrUserData) ->
  encode_msg_CommandMessage(Msg, <<>>, TrUserData).

encode_msg_CommandMessage(#{consumer_id := F1,
  message_id := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_mfield_CommandMessage_message_id(TrF2,
           <<B1/binary, 18>>,
           TrUserData)
       end,
  case M of
    #{redelivery_count := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        e_varint(TrF3, <<B2/binary, 24>>, TrUserData)
      end;
    _ -> B2
  end.

encode_msg_CommandAck(Msg, TrUserData) ->
  encode_msg_CommandAck(Msg, <<>>, TrUserData).

encode_msg_CommandAck(#{consumer_id := F1,
  ack_type := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         'e_enum_CommandAck.AckType'(TrF2,
           <<B1/binary, 16>>,
           TrUserData)
       end,
  B3 = case M of
         #{message_id := F3} ->
           TrF3 = id(F3, TrUserData),
           if TrF3 == [] -> B2;
             true ->
               e_field_CommandAck_message_id(TrF3, B2, TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{validation_error := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             'e_enum_CommandAck.ValidationError'(TrF4,
               <<B3/binary, 32>>,
               TrUserData)
           end;
         _ -> B3
       end,
  case M of
    #{properties := F5} ->
      TrF5 = id(F5, TrUserData),
      if TrF5 == [] -> B4;
        true ->
          e_field_CommandAck_properties(TrF5, B4, TrUserData)
      end;
    _ -> B4
  end.

encode_msg_CommandActiveConsumerChange(Msg,
    TrUserData) ->
  encode_msg_CommandActiveConsumerChange(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandActiveConsumerChange(#{consumer_id :=
F1} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  case M of
    #{is_active := F2} ->
      begin
        TrF2 = id(F2, TrUserData),
        e_type_bool(TrF2, <<B1/binary, 16>>, TrUserData)
      end;
    _ -> B1
  end.

encode_msg_CommandFlow(Msg, TrUserData) ->
  encode_msg_CommandFlow(Msg, <<>>, TrUserData).

encode_msg_CommandFlow(#{consumer_id := F1,
  messagePermits := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_CommandUnsubscribe(Msg, TrUserData) ->
  encode_msg_CommandUnsubscribe(Msg, <<>>, TrUserData).

encode_msg_CommandUnsubscribe(#{consumer_id := F1,
  request_id := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_CommandSeek(Msg, TrUserData) ->
  encode_msg_CommandSeek(Msg, <<>>, TrUserData).

encode_msg_CommandSeek(#{consumer_id := F1,
  request_id := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  B3 = case M of
         #{message_id := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_mfield_CommandSeek_message_id(TrF3,
               <<B2/binary, 26>>,
               TrUserData)
           end;
         _ -> B2
       end,
  case M of
    #{message_publish_time := F4} ->
      begin
        TrF4 = id(F4, TrUserData),
        e_varint(TrF4, <<B3/binary, 32>>, TrUserData)
      end;
    _ -> B3
  end.

encode_msg_CommandReachedEndOfTopic(Msg, TrUserData) ->
  encode_msg_CommandReachedEndOfTopic(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandReachedEndOfTopic(#{consumer_id :=
F1},
    Bin, TrUserData) ->
  begin
    TrF1 = id(F1, TrUserData),
    e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
  end.

encode_msg_CommandCloseProducer(Msg, TrUserData) ->
  encode_msg_CommandCloseProducer(Msg, <<>>, TrUserData).

encode_msg_CommandCloseProducer(#{producer_id := F1,
  request_id := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_CommandCloseConsumer(Msg, TrUserData) ->
  encode_msg_CommandCloseConsumer(Msg, <<>>, TrUserData).

encode_msg_CommandCloseConsumer(#{consumer_id := F1,
  request_id := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_CommandRedeliverUnacknowledgedMessages(Msg,
    TrUserData) ->
  encode_msg_CommandRedeliverUnacknowledgedMessages(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandRedeliverUnacknowledgedMessages(#{consumer_id
:= F1} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  case M of
    #{message_ids := F2} ->
      TrF2 = id(F2, TrUserData),
      if TrF2 == [] -> B1;
        true ->
          e_field_CommandRedeliverUnacknowledgedMessages_message_ids(TrF2,
            B1,
            TrUserData)
      end;
    _ -> B1
  end.

encode_msg_CommandSuccess(Msg, TrUserData) ->
  encode_msg_CommandSuccess(Msg, <<>>, TrUserData).

encode_msg_CommandSuccess(#{request_id := F1} = M, Bin,
    TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  case M of
    #{schema := F2} ->
      begin
        TrF2 = id(F2, TrUserData),
        e_mfield_CommandSuccess_schema(TrF2,
          <<B1/binary, 18>>,
          TrUserData)
      end;
    _ -> B1
  end.

encode_msg_CommandProducerSuccess(Msg, TrUserData) ->
  encode_msg_CommandProducerSuccess(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandProducerSuccess(#{request_id := F1,
  producer_name := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
       end,
  B3 = case M of
         #{last_sequence_id := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_int64(TrF3, <<B2/binary, 24>>, TrUserData)
           end;
         _ -> B2
       end,
  case M of
    #{schema_version := F4} ->
      begin
        TrF4 = id(F4, TrUserData),
        e_type_bytes(TrF4, <<B3/binary, 34>>, TrUserData)
      end;
    _ -> B3
  end.

encode_msg_CommandError(Msg, TrUserData) ->
  encode_msg_CommandError(Msg, <<>>, TrUserData).

encode_msg_CommandError(#{request_id := F1, error := F2,
  message := F3},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_enum_ServerError(TrF2, <<B1/binary, 16>>, TrUserData)
       end,
  begin
    TrF3 = id(F3, TrUserData),
    e_type_string(TrF3, <<B2/binary, 26>>, TrUserData)
  end.

encode_msg_CommandPing(_Msg, _TrUserData) -> <<>>.

encode_msg_CommandPong(_Msg, _TrUserData) -> <<>>.

encode_msg_CommandConsumerStats(Msg, TrUserData) ->
  encode_msg_CommandConsumerStats(Msg, <<>>, TrUserData).

encode_msg_CommandConsumerStats(#{request_id := F1,
  consumer_id := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 32>>, TrUserData)
  end.

encode_msg_CommandConsumerStatsResponse(Msg,
    TrUserData) ->
  encode_msg_CommandConsumerStatsResponse(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandConsumerStatsResponse(#{request_id :=
F1} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = case M of
         #{error_code := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_enum_ServerError(TrF2, <<B1/binary, 16>>, TrUserData)
           end;
         _ -> B1
       end,
  B3 = case M of
         #{error_message := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_string(TrF3, <<B2/binary, 26>>, TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{msgRateOut := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_type_double(TrF4, <<B3/binary, 33>>, TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{msgThroughputOut := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_type_double(TrF5, <<B4/binary, 41>>, TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{msgRateRedeliver := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_type_double(TrF6, <<B5/binary, 49>>, TrUserData)
           end;
         _ -> B5
       end,
  B7 = case M of
         #{consumerName := F7} ->
           begin
             TrF7 = id(F7, TrUserData),
             e_type_string(TrF7, <<B6/binary, 58>>, TrUserData)
           end;
         _ -> B6
       end,
  B8 = case M of
         #{availablePermits := F8} ->
           begin
             TrF8 = id(F8, TrUserData),
             e_varint(TrF8, <<B7/binary, 64>>, TrUserData)
           end;
         _ -> B7
       end,
  B9 = case M of
         #{unackedMessages := F9} ->
           begin
             TrF9 = id(F9, TrUserData),
             e_varint(TrF9, <<B8/binary, 72>>, TrUserData)
           end;
         _ -> B8
       end,
  B10 = case M of
          #{blockedConsumerOnUnackedMsgs := F10} ->
            begin
              TrF10 = id(F10, TrUserData),
              e_type_bool(TrF10, <<B9/binary, 80>>, TrUserData)
            end;
          _ -> B9
        end,
  B11 = case M of
          #{address := F11} ->
            begin
              TrF11 = id(F11, TrUserData),
              e_type_string(TrF11, <<B10/binary, 90>>, TrUserData)
            end;
          _ -> B10
        end,
  B12 = case M of
          #{connectedSince := F12} ->
            begin
              TrF12 = id(F12, TrUserData),
              e_type_string(TrF12, <<B11/binary, 98>>, TrUserData)
            end;
          _ -> B11
        end,
  B13 = case M of
          #{type := F13} ->
            begin
              TrF13 = id(F13, TrUserData),
              e_type_string(TrF13, <<B12/binary, 106>>, TrUserData)
            end;
          _ -> B12
        end,
  B14 = case M of
          #{msgRateExpired := F14} ->
            begin
              TrF14 = id(F14, TrUserData),
              e_type_double(TrF14, <<B13/binary, 113>>, TrUserData)
            end;
          _ -> B13
        end,
  case M of
    #{msgBacklog := F15} ->
      begin
        TrF15 = id(F15, TrUserData),
        e_varint(TrF15, <<B14/binary, 120>>, TrUserData)
      end;
    _ -> B14
  end.

encode_msg_CommandGetLastMessageId(Msg, TrUserData) ->
  encode_msg_CommandGetLastMessageId(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandGetLastMessageId(#{consumer_id := F1,
  request_id := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_CommandGetLastMessageIdResponse(Msg,
    TrUserData) ->
  encode_msg_CommandGetLastMessageIdResponse(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandGetLastMessageIdResponse(#{last_message_id
:= F1,
  request_id := F2},
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_mfield_CommandGetLastMessageIdResponse_last_message_id(TrF1,
           <<Bin/binary,
             10>>,
           TrUserData)
       end,
  begin
    TrF2 = id(F2, TrUserData),
    e_varint(TrF2, <<B1/binary, 16>>, TrUserData)
  end.

encode_msg_CommandGetTopicsOfNamespace(Msg,
    TrUserData) ->
  encode_msg_CommandGetTopicsOfNamespace(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandGetTopicsOfNamespace(#{request_id :=
F1,
  namespace := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
       end,
  case M of
    #{mode := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        'e_enum_CommandGetTopicsOfNamespace.Mode'(TrF3,
          <<B2/binary, 24>>,
          TrUserData)
      end;
    _ -> B2
  end.

encode_msg_CommandGetTopicsOfNamespaceResponse(Msg,
    TrUserData) ->
  encode_msg_CommandGetTopicsOfNamespaceResponse(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandGetTopicsOfNamespaceResponse(#{request_id
:= F1} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  case M of
    #{topics := F2} ->
      TrF2 = id(F2, TrUserData),
      if TrF2 == [] -> B1;
        true ->
          e_field_CommandGetTopicsOfNamespaceResponse_topics(TrF2,
            B1,
            TrUserData)
      end;
    _ -> B1
  end.

encode_msg_CommandGetSchema(Msg, TrUserData) ->
  encode_msg_CommandGetSchema(Msg, <<>>, TrUserData).

encode_msg_CommandGetSchema(#{request_id := F1,
  topic := F2} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = begin
         TrF2 = id(F2, TrUserData),
         e_type_string(TrF2, <<B1/binary, 18>>, TrUserData)
       end,
  case M of
    #{schema_version := F3} ->
      begin
        TrF3 = id(F3, TrUserData),
        e_type_bytes(TrF3, <<B2/binary, 26>>, TrUserData)
      end;
    _ -> B2
  end.

encode_msg_CommandGetSchemaResponse(Msg, TrUserData) ->
  encode_msg_CommandGetSchemaResponse(Msg,
    <<>>,
    TrUserData).

encode_msg_CommandGetSchemaResponse(#{request_id :=
F1} =
  M,
    Bin, TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         e_varint(TrF1, <<Bin/binary, 8>>, TrUserData)
       end,
  B2 = case M of
         #{error_code := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_enum_ServerError(TrF2, <<B1/binary, 16>>, TrUserData)
           end;
         _ -> B1
       end,
  B3 = case M of
         #{error_message := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_type_string(TrF3, <<B2/binary, 26>>, TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{schema := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_mfield_CommandGetSchemaResponse_schema(TrF4,
               <<B3/binary, 34>>,
               TrUserData)
           end;
         _ -> B3
       end,
  case M of
    #{schema_version := F5} ->
      begin
        TrF5 = id(F5, TrUserData),
        e_type_bytes(TrF5, <<B4/binary, 42>>, TrUserData)
      end;
    _ -> B4
  end.

encode_msg_BaseCommand(Msg, TrUserData) ->
  encode_msg_BaseCommand(Msg, <<>>, TrUserData).

encode_msg_BaseCommand(#{type := F1} = M, Bin,
    TrUserData) ->
  B1 = begin
         TrF1 = id(F1, TrUserData),
         'e_enum_BaseCommand.Type'(TrF1,
           <<Bin/binary, 8>>,
           TrUserData)
       end,
  B2 = case M of
         #{connect := F2} ->
           begin
             TrF2 = id(F2, TrUserData),
             e_mfield_BaseCommand_connect(TrF2,
               <<B1/binary, 18>>,
               TrUserData)
           end;
         _ -> B1
       end,
  B3 = case M of
         #{connected := F3} ->
           begin
             TrF3 = id(F3, TrUserData),
             e_mfield_BaseCommand_connected(TrF3,
               <<B2/binary, 26>>,
               TrUserData)
           end;
         _ -> B2
       end,
  B4 = case M of
         #{subscribe := F4} ->
           begin
             TrF4 = id(F4, TrUserData),
             e_mfield_BaseCommand_subscribe(TrF4,
               <<B3/binary, 34>>,
               TrUserData)
           end;
         _ -> B3
       end,
  B5 = case M of
         #{producer := F5} ->
           begin
             TrF5 = id(F5, TrUserData),
             e_mfield_BaseCommand_producer(TrF5,
               <<B4/binary, 42>>,
               TrUserData)
           end;
         _ -> B4
       end,
  B6 = case M of
         #{send := F6} ->
           begin
             TrF6 = id(F6, TrUserData),
             e_mfield_BaseCommand_send(TrF6,
               <<B5/binary, 50>>,
               TrUserData)
           end;
         _ -> B5
       end,
  B7 = case M of
         #{send_receipt := F7} ->
           begin
             TrF7 = id(F7, TrUserData),
             e_mfield_BaseCommand_send_receipt(TrF7,
               <<B6/binary, 58>>,
               TrUserData)
           end;
         _ -> B6
       end,
  B8 = case M of
         #{send_error := F8} ->
           begin
             TrF8 = id(F8, TrUserData),
             e_mfield_BaseCommand_send_error(TrF8,
               <<B7/binary, 66>>,
               TrUserData)
           end;
         _ -> B7
       end,
  B9 = case M of
         #{message := F9} ->
           begin
             TrF9 = id(F9, TrUserData),
             e_mfield_BaseCommand_message(TrF9,
               <<B8/binary, 74>>,
               TrUserData)
           end;
         _ -> B8
       end,
  B10 = case M of
          #{ack := F10} ->
            begin
              TrF10 = id(F10, TrUserData),
              e_mfield_BaseCommand_ack(TrF10,
                <<B9/binary, 82>>,
                TrUserData)
            end;
          _ -> B9
        end,
  B11 = case M of
          #{flow := F11} ->
            begin
              TrF11 = id(F11, TrUserData),
              e_mfield_BaseCommand_flow(TrF11,
                <<B10/binary, 90>>,
                TrUserData)
            end;
          _ -> B10
        end,
  B12 = case M of
          #{unsubscribe := F12} ->
            begin
              TrF12 = id(F12, TrUserData),
              e_mfield_BaseCommand_unsubscribe(TrF12,
                <<B11/binary, 98>>,
                TrUserData)
            end;
          _ -> B11
        end,
  B13 = case M of
          #{success := F13} ->
            begin
              TrF13 = id(F13, TrUserData),
              e_mfield_BaseCommand_success(TrF13,
                <<B12/binary, 106>>,
                TrUserData)
            end;
          _ -> B12
        end,
  B14 = case M of
          #{error := F14} ->
            begin
              TrF14 = id(F14, TrUserData),
              e_mfield_BaseCommand_error(TrF14,
                <<B13/binary, 114>>,
                TrUserData)
            end;
          _ -> B13
        end,
  B15 = case M of
          #{close_producer := F15} ->
            begin
              TrF15 = id(F15, TrUserData),
              e_mfield_BaseCommand_close_producer(TrF15,
                <<B14/binary, 122>>,
                TrUserData)
            end;
          _ -> B14
        end,
  B16 = case M of
          #{close_consumer := F16} ->
            begin
              TrF16 = id(F16, TrUserData),
              e_mfield_BaseCommand_close_consumer(TrF16,
                <<B15/binary, 130,
                  1>>,
                TrUserData)
            end;
          _ -> B15
        end,
  B17 = case M of
          #{producer_success := F17} ->
            begin
              TrF17 = id(F17, TrUserData),
              e_mfield_BaseCommand_producer_success(TrF17,
                <<B16/binary, 138,
                  1>>,
                TrUserData)
            end;
          _ -> B16
        end,
  B18 = case M of
          #{ping := F18} ->
            begin
              TrF18 = id(F18, TrUserData),
              e_mfield_BaseCommand_ping(TrF18,
                <<B17/binary, 146, 1>>,
                TrUserData)
            end;
          _ -> B17
        end,
  B19 = case M of
          #{pong := F19} ->
            begin
              TrF19 = id(F19, TrUserData),
              e_mfield_BaseCommand_pong(TrF19,
                <<B18/binary, 154, 1>>,
                TrUserData)
            end;
          _ -> B18
        end,
  B20 = case M of
          #{redeliverUnacknowledgedMessages := F20} ->
            begin
              TrF20 = id(F20, TrUserData),
              e_mfield_BaseCommand_redeliverUnacknowledgedMessages(TrF20,
                <<B19/binary,
                  162,
                  1>>,
                TrUserData)
            end;
          _ -> B19
        end,
  B21 = case M of
          #{partitionMetadata := F21} ->
            begin
              TrF21 = id(F21, TrUserData),
              e_mfield_BaseCommand_partitionMetadata(TrF21,
                <<B20/binary, 170,
                  1>>,
                TrUserData)
            end;
          _ -> B20
        end,
  B22 = case M of
          #{partitionMetadataResponse := F22} ->
            begin
              TrF22 = id(F22, TrUserData),
              e_mfield_BaseCommand_partitionMetadataResponse(TrF22,
                <<B21/binary,
                  178, 1>>,
                TrUserData)
            end;
          _ -> B21
        end,
  B23 = case M of
          #{lookupTopic := F23} ->
            begin
              TrF23 = id(F23, TrUserData),
              e_mfield_BaseCommand_lookupTopic(TrF23,
                <<B22/binary, 186, 1>>,
                TrUserData)
            end;
          _ -> B22
        end,
  B24 = case M of
          #{lookupTopicResponse := F24} ->
            begin
              TrF24 = id(F24, TrUserData),
              e_mfield_BaseCommand_lookupTopicResponse(TrF24,
                <<B23/binary,
                  194, 1>>,
                TrUserData)
            end;
          _ -> B23
        end,
  B25 = case M of
          #{consumerStats := F25} ->
            begin
              TrF25 = id(F25, TrUserData),
              e_mfield_BaseCommand_consumerStats(TrF25,
                <<B24/binary, 202, 1>>,
                TrUserData)
            end;
          _ -> B24
        end,
  B26 = case M of
          #{consumerStatsResponse := F26} ->
            begin
              TrF26 = id(F26, TrUserData),
              e_mfield_BaseCommand_consumerStatsResponse(TrF26,
                <<B25/binary,
                  210, 1>>,
                TrUserData)
            end;
          _ -> B25
        end,
  B27 = case M of
          #{reachedEndOfTopic := F27} ->
            begin
              TrF27 = id(F27, TrUserData),
              e_mfield_BaseCommand_reachedEndOfTopic(TrF27,
                <<B26/binary, 218,
                  1>>,
                TrUserData)
            end;
          _ -> B26
        end,
  B28 = case M of
          #{seek := F28} ->
            begin
              TrF28 = id(F28, TrUserData),
              e_mfield_BaseCommand_seek(TrF28,
                <<B27/binary, 226, 1>>,
                TrUserData)
            end;
          _ -> B27
        end,
  B29 = case M of
          #{getLastMessageId := F29} ->
            begin
              TrF29 = id(F29, TrUserData),
              e_mfield_BaseCommand_getLastMessageId(TrF29,
                <<B28/binary, 234,
                  1>>,
                TrUserData)
            end;
          _ -> B28
        end,
  B30 = case M of
          #{getLastMessageIdResponse := F30} ->
            begin
              TrF30 = id(F30, TrUserData),
              e_mfield_BaseCommand_getLastMessageIdResponse(TrF30,
                <<B29/binary,
                  242, 1>>,
                TrUserData)
            end;
          _ -> B29
        end,
  B31 = case M of
          #{active_consumer_change := F31} ->
            begin
              TrF31 = id(F31, TrUserData),
              e_mfield_BaseCommand_active_consumer_change(TrF31,
                <<B30/binary,
                  250, 1>>,
                TrUserData)
            end;
          _ -> B30
        end,
  B32 = case M of
          #{getTopicsOfNamespace := F32} ->
            begin
              TrF32 = id(F32, TrUserData),
              e_mfield_BaseCommand_getTopicsOfNamespace(TrF32,
                <<B31/binary,
                  130, 2>>,
                TrUserData)
            end;
          _ -> B31
        end,
  B33 = case M of
          #{getTopicsOfNamespaceResponse := F33} ->
            begin
              TrF33 = id(F33, TrUserData),
              e_mfield_BaseCommand_getTopicsOfNamespaceResponse(TrF33,
                <<B32/binary,
                  138,
                  2>>,
                TrUserData)
            end;
          _ -> B32
        end,
  B34 = case M of
          #{getSchema := F34} ->
            begin
              TrF34 = id(F34, TrUserData),
              e_mfield_BaseCommand_getSchema(TrF34,
                <<B33/binary, 146, 2>>,
                TrUserData)
            end;
          _ -> B33
        end,
  B35 = case M of
          #{getSchemaResponse := F35} ->
            begin
              TrF35 = id(F35, TrUserData),
              e_mfield_BaseCommand_getSchemaResponse(TrF35,
                <<B34/binary, 154,
                  2>>,
                TrUserData)
            end;
          _ -> B34
        end,
  B36 = case M of
          #{authChallenge := F36} ->
            begin
              TrF36 = id(F36, TrUserData),
              e_mfield_BaseCommand_authChallenge(TrF36,
                <<B35/binary, 162, 2>>,
                TrUserData)
            end;
          _ -> B35
        end,
  case M of
    #{authResponse := F37} ->
      begin
        TrF37 = id(F37, TrUserData),
        e_mfield_BaseCommand_authResponse(TrF37,
          <<B36/binary, 170, 2>>,
          TrUserData)
      end;
    _ -> B36
  end.

e_mfield_Schema_properties(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_KeyValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_Schema_properties([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 42>>,
  Bin3 = e_mfield_Schema_properties(id(Elem, TrUserData),
    Bin2,
    TrUserData),
  e_field_Schema_properties(Rest, Bin3, TrUserData);
e_field_Schema_properties([], Bin, _TrUserData) -> Bin.

e_mfield_EncryptionKeys_metadata(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_KeyValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_EncryptionKeys_metadata([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 26>>,
  Bin3 = e_mfield_EncryptionKeys_metadata(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_EncryptionKeys_metadata(Rest, Bin3, TrUserData);
e_field_EncryptionKeys_metadata([], Bin, _TrUserData) ->
  Bin.

e_mfield_MessageMetadata_properties(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_KeyValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_MessageMetadata_properties([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 34>>,
  Bin3 = e_mfield_MessageMetadata_properties(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_MessageMetadata_properties(Rest,
    Bin3,
    TrUserData);
e_field_MessageMetadata_properties([], Bin,
    _TrUserData) ->
  Bin.

e_field_MessageMetadata_replicate_to([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 58>>,
  Bin3 = e_type_string(id(Elem, TrUserData),
    Bin2,
    TrUserData),
  e_field_MessageMetadata_replicate_to(Rest,
    Bin3,
    TrUserData);
e_field_MessageMetadata_replicate_to([], Bin,
    _TrUserData) ->
  Bin.

e_mfield_MessageMetadata_encryption_keys(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_EncryptionKeys(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_MessageMetadata_encryption_keys([Elem | Rest],
    Bin, TrUserData) ->
  Bin2 = <<Bin/binary, 106>>,
  Bin3 = e_mfield_MessageMetadata_encryption_keys(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_MessageMetadata_encryption_keys(Rest,
    Bin3,
    TrUserData);
e_field_MessageMetadata_encryption_keys([], Bin,
    _TrUserData) ->
  Bin.

e_mfield_SingleMessageMetadata_properties(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_KeyValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_SingleMessageMetadata_properties([Elem | Rest],
    Bin, TrUserData) ->
  Bin2 = <<Bin/binary, 10>>,
  Bin3 =
    e_mfield_SingleMessageMetadata_properties(id(Elem,
      TrUserData),
      Bin2,
      TrUserData),
  e_field_SingleMessageMetadata_properties(Rest,
    Bin3,
    TrUserData);
e_field_SingleMessageMetadata_properties([], Bin,
    _TrUserData) ->
  Bin.

e_mfield_CommandAuthResponse_response(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_AuthData(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandAuthChallenge_challenge(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_AuthData(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandSubscribe_start_message_id(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandSubscribe_metadata(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_KeyValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_CommandSubscribe_metadata([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 82>>,
  Bin3 = e_mfield_CommandSubscribe_metadata(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_CommandSubscribe_metadata(Rest,
    Bin3,
    TrUserData);
e_field_CommandSubscribe_metadata([], Bin,
    _TrUserData) ->
  Bin.

e_mfield_CommandSubscribe_schema(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_Schema(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandProducer_metadata(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_KeyValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_CommandProducer_metadata([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 50>>,
  Bin3 = e_mfield_CommandProducer_metadata(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_CommandProducer_metadata(Rest,
    Bin3,
    TrUserData);
e_field_CommandProducer_metadata([], Bin,
    _TrUserData) ->
  Bin.

e_mfield_CommandProducer_schema(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_Schema(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandSendReceipt_message_id(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandMessage_message_id(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandAck_message_id(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_CommandAck_message_id([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 26>>,
  Bin3 = e_mfield_CommandAck_message_id(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_CommandAck_message_id(Rest, Bin3, TrUserData);
e_field_CommandAck_message_id([], Bin, _TrUserData) ->
  Bin.

e_mfield_CommandAck_properties(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_KeyLongValue(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_CommandAck_properties([Elem | Rest], Bin,
    TrUserData) ->
  Bin2 = <<Bin/binary, 42>>,
  Bin3 = e_mfield_CommandAck_properties(id(Elem,
    TrUserData),
    Bin2,
    TrUserData),
  e_field_CommandAck_properties(Rest, Bin3, TrUserData);
e_field_CommandAck_properties([], Bin, _TrUserData) ->
  Bin.

e_mfield_CommandSeek_message_id(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandRedeliverUnacknowledgedMessages_message_ids(Msg,
    Bin, TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_CommandRedeliverUnacknowledgedMessages_message_ids([Elem
  | Rest],
    Bin, TrUserData) ->
  Bin2 = <<Bin/binary, 18>>,
  Bin3 =
    e_mfield_CommandRedeliverUnacknowledgedMessages_message_ids(id(Elem,
      TrUserData),
      Bin2,
      TrUserData),
  e_field_CommandRedeliverUnacknowledgedMessages_message_ids(Rest,
    Bin3,
    TrUserData);
e_field_CommandRedeliverUnacknowledgedMessages_message_ids([],
    Bin, _TrUserData) ->
  Bin.

e_mfield_CommandSuccess_schema(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_Schema(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_CommandGetLastMessageIdResponse_last_message_id(Msg,
    Bin, TrUserData) ->
  SubBin = encode_msg_MessageIdData(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_field_CommandGetTopicsOfNamespaceResponse_topics([Elem
  | Rest],
    Bin, TrUserData) ->
  Bin2 = <<Bin/binary, 18>>,
  Bin3 = e_type_string(id(Elem, TrUserData),
    Bin2,
    TrUserData),
  e_field_CommandGetTopicsOfNamespaceResponse_topics(Rest,
    Bin3,
    TrUserData);
e_field_CommandGetTopicsOfNamespaceResponse_topics([],
    Bin, _TrUserData) ->
  Bin.

e_mfield_CommandGetSchemaResponse_schema(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_Schema(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_connect(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandConnect(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_connected(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandConnected(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_subscribe(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandSubscribe(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_producer(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandProducer(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_send(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandSend(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_send_receipt(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandSendReceipt(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_send_error(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandSendError(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_message(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandMessage(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_ack(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandAck(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_flow(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandFlow(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_unsubscribe(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandUnsubscribe(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_success(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandSuccess(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_error(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandError(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_close_producer(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandCloseProducer(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_close_consumer(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandCloseConsumer(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_producer_success(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandProducerSuccess(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_ping(_Msg, Bin, _TrUserData) ->
  <<Bin/binary, 0>>.

e_mfield_BaseCommand_pong(_Msg, Bin, _TrUserData) ->
  <<Bin/binary, 0>>.

e_mfield_BaseCommand_redeliverUnacknowledgedMessages(Msg,
    Bin, TrUserData) ->
  SubBin =
    encode_msg_CommandRedeliverUnacknowledgedMessages(Msg,
      <<>>,
      TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_partitionMetadata(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandPartitionedTopicMetadata(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_partitionMetadataResponse(Msg, Bin,
    TrUserData) ->
  SubBin =
    encode_msg_CommandPartitionedTopicMetadataResponse(Msg,
      <<>>,
      TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_lookupTopic(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandLookupTopic(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_lookupTopicResponse(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandLookupTopicResponse(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_consumerStats(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandConsumerStats(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_consumerStatsResponse(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandConsumerStatsResponse(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_reachedEndOfTopic(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandReachedEndOfTopic(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_seek(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandSeek(Msg, <<>>, TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_getLastMessageId(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandGetLastMessageId(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_getLastMessageIdResponse(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandGetLastMessageIdResponse(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_active_consumer_change(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandActiveConsumerChange(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_getTopicsOfNamespace(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandGetTopicsOfNamespace(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_getTopicsOfNamespaceResponse(Msg,
    Bin, TrUserData) ->
  SubBin =
    encode_msg_CommandGetTopicsOfNamespaceResponse(Msg,
      <<>>,
      TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_getSchema(Msg, Bin, TrUserData) ->
  SubBin = encode_msg_CommandGetSchema(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_getSchemaResponse(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandGetSchemaResponse(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_authChallenge(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandAuthChallenge(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

e_mfield_BaseCommand_authResponse(Msg, Bin,
    TrUserData) ->
  SubBin = encode_msg_CommandAuthResponse(Msg,
    <<>>,
    TrUserData),
  Bin2 = e_varint(byte_size(SubBin), Bin),
  <<Bin2/binary, SubBin/binary>>.

'e_enum_Schema.Type'('None', Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_Schema.Type'('String', Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_Schema.Type'('Json', Bin, _TrUserData) ->
  <<Bin/binary, 2>>;
'e_enum_Schema.Type'('Protobuf', Bin, _TrUserData) ->
  <<Bin/binary, 3>>;
'e_enum_Schema.Type'('Avro', Bin, _TrUserData) ->
  <<Bin/binary, 4>>;
'e_enum_Schema.Type'('Bool', Bin, _TrUserData) ->
  <<Bin/binary, 5>>;
'e_enum_Schema.Type'('Int8', Bin, _TrUserData) ->
  <<Bin/binary, 6>>;
'e_enum_Schema.Type'('Int16', Bin, _TrUserData) ->
  <<Bin/binary, 7>>;
'e_enum_Schema.Type'('Int32', Bin, _TrUserData) ->
  <<Bin/binary, 8>>;
'e_enum_Schema.Type'('Int64', Bin, _TrUserData) ->
  <<Bin/binary, 9>>;
'e_enum_Schema.Type'('Float', Bin, _TrUserData) ->
  <<Bin/binary, 10>>;
'e_enum_Schema.Type'('Double', Bin, _TrUserData) ->
  <<Bin/binary, 11>>;
'e_enum_Schema.Type'('Date', Bin, _TrUserData) ->
  <<Bin/binary, 12>>;
'e_enum_Schema.Type'('Time', Bin, _TrUserData) ->
  <<Bin/binary, 13>>;
'e_enum_Schema.Type'('Timestamp', Bin, _TrUserData) ->
  <<Bin/binary, 14>>;
'e_enum_Schema.Type'('KeyValue', Bin, _TrUserData) ->
  <<Bin/binary, 15>>;
'e_enum_Schema.Type'(V, Bin, _TrUserData) ->
  e_varint(V, Bin).

e_enum_CompressionType('NONE', Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
e_enum_CompressionType('LZ4', Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
e_enum_CompressionType('ZLIB', Bin, _TrUserData) ->
  <<Bin/binary, 2>>;
e_enum_CompressionType('ZSTD', Bin, _TrUserData) ->
  <<Bin/binary, 3>>;
e_enum_CompressionType(V, Bin, _TrUserData) ->
  e_varint(V, Bin).

e_enum_ServerError('UnknownError', Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
e_enum_ServerError('MetadataError', Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
e_enum_ServerError('PersistenceError', Bin,
    _TrUserData) ->
  <<Bin/binary, 2>>;
e_enum_ServerError('AuthenticationError', Bin,
    _TrUserData) ->
  <<Bin/binary, 3>>;
e_enum_ServerError('AuthorizationError', Bin,
    _TrUserData) ->
  <<Bin/binary, 4>>;
e_enum_ServerError('ConsumerBusy', Bin, _TrUserData) ->
  <<Bin/binary, 5>>;
e_enum_ServerError('ServiceNotReady', Bin,
    _TrUserData) ->
  <<Bin/binary, 6>>;
e_enum_ServerError('ProducerBlockedQuotaExceededError',
    Bin, _TrUserData) ->
  <<Bin/binary, 7>>;
e_enum_ServerError('ProducerBlockedQuotaExceededException',
    Bin, _TrUserData) ->
  <<Bin/binary, 8>>;
e_enum_ServerError('ChecksumError', Bin, _TrUserData) ->
  <<Bin/binary, 9>>;
e_enum_ServerError('UnsupportedVersionError', Bin,
    _TrUserData) ->
  <<Bin/binary, 10>>;
e_enum_ServerError('TopicNotFound', Bin, _TrUserData) ->
  <<Bin/binary, 11>>;
e_enum_ServerError('SubscriptionNotFound', Bin,
    _TrUserData) ->
  <<Bin/binary, 12>>;
e_enum_ServerError('ConsumerNotFound', Bin,
    _TrUserData) ->
  <<Bin/binary, 13>>;
e_enum_ServerError('TooManyRequests', Bin,
    _TrUserData) ->
  <<Bin/binary, 14>>;
e_enum_ServerError('TopicTerminatedError', Bin,
    _TrUserData) ->
  <<Bin/binary, 15>>;
e_enum_ServerError('ProducerBusy', Bin, _TrUserData) ->
  <<Bin/binary, 16>>;
e_enum_ServerError('InvalidTopicName', Bin,
    _TrUserData) ->
  <<Bin/binary, 17>>;
e_enum_ServerError('IncompatibleSchema', Bin,
    _TrUserData) ->
  <<Bin/binary, 18>>;
e_enum_ServerError('ConsumerAssignError', Bin,
    _TrUserData) ->
  <<Bin/binary, 19>>;
e_enum_ServerError(V, Bin, _TrUserData) ->
  e_varint(V, Bin).

e_enum_AuthMethod('AuthMethodNone', Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
e_enum_AuthMethod('AuthMethodYcaV1', Bin,
    _TrUserData) ->
  <<Bin/binary, 1>>;
e_enum_AuthMethod('AuthMethodAthens', Bin,
    _TrUserData) ->
  <<Bin/binary, 2>>;
e_enum_AuthMethod(V, Bin, _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandSubscribe.SubType'('Exclusive', Bin,
    _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandSubscribe.SubType'('Shared', Bin,
    _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandSubscribe.SubType'('Failover', Bin,
    _TrUserData) ->
  <<Bin/binary, 2>>;
'e_enum_CommandSubscribe.SubType'('Key_Shared', Bin,
    _TrUserData) ->
  <<Bin/binary, 3>>;
'e_enum_CommandSubscribe.SubType'(V, Bin,
    _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandSubscribe.InitialPosition'('Latest', Bin,
    _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandSubscribe.InitialPosition'('Earliest',
    Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandSubscribe.InitialPosition'(V, Bin,
    _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandPartitionedTopicMetadataResponse.LookupType'('Success',
    Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandPartitionedTopicMetadataResponse.LookupType'('Failed',
    Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandPartitionedTopicMetadataResponse.LookupType'(V,
    Bin, _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandLookupTopicResponse.LookupType'('Redirect',
    Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandLookupTopicResponse.LookupType'('Connect',
    Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandLookupTopicResponse.LookupType'('Failed',
    Bin, _TrUserData) ->
  <<Bin/binary, 2>>;
'e_enum_CommandLookupTopicResponse.LookupType'(V, Bin,
    _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandAck.AckType'('Individual', Bin,
    _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandAck.AckType'('Cumulative', Bin,
    _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandAck.AckType'(V, Bin, _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandAck.ValidationError'('UncompressedSizeCorruption',
    Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandAck.ValidationError'('DecompressionError',
    Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandAck.ValidationError'('ChecksumMismatch',
    Bin, _TrUserData) ->
  <<Bin/binary, 2>>;
'e_enum_CommandAck.ValidationError'('BatchDeSerializeError',
    Bin, _TrUserData) ->
  <<Bin/binary, 3>>;
'e_enum_CommandAck.ValidationError'('DecryptionError',
    Bin, _TrUserData) ->
  <<Bin/binary, 4>>;
'e_enum_CommandAck.ValidationError'(V, Bin,
    _TrUserData) ->
  e_varint(V, Bin).

'e_enum_CommandGetTopicsOfNamespace.Mode'('PERSISTENT',
    Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
'e_enum_CommandGetTopicsOfNamespace.Mode'('NON_PERSISTENT',
    Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
'e_enum_CommandGetTopicsOfNamespace.Mode'('ALL', Bin,
    _TrUserData) ->
  <<Bin/binary, 2>>;
'e_enum_CommandGetTopicsOfNamespace.Mode'(V, Bin,
    _TrUserData) ->
  e_varint(V, Bin).

'e_enum_BaseCommand.Type'('CONNECT', Bin,
    _TrUserData) ->
  <<Bin/binary, 2>>;
'e_enum_BaseCommand.Type'('CONNECTED', Bin,
    _TrUserData) ->
  <<Bin/binary, 3>>;
'e_enum_BaseCommand.Type'('SUBSCRIBE', Bin,
    _TrUserData) ->
  <<Bin/binary, 4>>;
'e_enum_BaseCommand.Type'('PRODUCER', Bin,
    _TrUserData) ->
  <<Bin/binary, 5>>;
'e_enum_BaseCommand.Type'('SEND', Bin, _TrUserData) ->
  <<Bin/binary, 6>>;
'e_enum_BaseCommand.Type'('SEND_RECEIPT', Bin,
    _TrUserData) ->
  <<Bin/binary, 7>>;
'e_enum_BaseCommand.Type'('SEND_ERROR', Bin,
    _TrUserData) ->
  <<Bin/binary, 8>>;
'e_enum_BaseCommand.Type'('MESSAGE', Bin,
    _TrUserData) ->
  <<Bin/binary, 9>>;
'e_enum_BaseCommand.Type'('ACK', Bin, _TrUserData) ->
  <<Bin/binary, 10>>;
'e_enum_BaseCommand.Type'('FLOW', Bin, _TrUserData) ->
  <<Bin/binary, 11>>;
'e_enum_BaseCommand.Type'('UNSUBSCRIBE', Bin,
    _TrUserData) ->
  <<Bin/binary, 12>>;
'e_enum_BaseCommand.Type'('SUCCESS', Bin,
    _TrUserData) ->
  <<Bin/binary, 13>>;
'e_enum_BaseCommand.Type'('ERROR', Bin, _TrUserData) ->
  <<Bin/binary, 14>>;
'e_enum_BaseCommand.Type'('CLOSE_PRODUCER', Bin,
    _TrUserData) ->
  <<Bin/binary, 15>>;
'e_enum_BaseCommand.Type'('CLOSE_CONSUMER', Bin,
    _TrUserData) ->
  <<Bin/binary, 16>>;
'e_enum_BaseCommand.Type'('PRODUCER_SUCCESS', Bin,
    _TrUserData) ->
  <<Bin/binary, 17>>;
'e_enum_BaseCommand.Type'('PING', Bin, _TrUserData) ->
  <<Bin/binary, 18>>;
'e_enum_BaseCommand.Type'('PONG', Bin, _TrUserData) ->
  <<Bin/binary, 19>>;
'e_enum_BaseCommand.Type'('REDELIVER_UNACKNOWLEDGED_MESSAGES',
    Bin, _TrUserData) ->
  <<Bin/binary, 20>>;
'e_enum_BaseCommand.Type'('PARTITIONED_METADATA', Bin,
    _TrUserData) ->
  <<Bin/binary, 21>>;
'e_enum_BaseCommand.Type'('PARTITIONED_METADATA_RESPONSE',
    Bin, _TrUserData) ->
  <<Bin/binary, 22>>;
'e_enum_BaseCommand.Type'('LOOKUP', Bin, _TrUserData) ->
  <<Bin/binary, 23>>;
'e_enum_BaseCommand.Type'('LOOKUP_RESPONSE', Bin,
    _TrUserData) ->
  <<Bin/binary, 24>>;
'e_enum_BaseCommand.Type'('CONSUMER_STATS', Bin,
    _TrUserData) ->
  <<Bin/binary, 25>>;
'e_enum_BaseCommand.Type'('CONSUMER_STATS_RESPONSE',
    Bin, _TrUserData) ->
  <<Bin/binary, 26>>;
'e_enum_BaseCommand.Type'('REACHED_END_OF_TOPIC', Bin,
    _TrUserData) ->
  <<Bin/binary, 27>>;
'e_enum_BaseCommand.Type'('SEEK', Bin, _TrUserData) ->
  <<Bin/binary, 28>>;
'e_enum_BaseCommand.Type'('GET_LAST_MESSAGE_ID', Bin,
    _TrUserData) ->
  <<Bin/binary, 29>>;
'e_enum_BaseCommand.Type'('GET_LAST_MESSAGE_ID_RESPONSE',
    Bin, _TrUserData) ->
  <<Bin/binary, 30>>;
'e_enum_BaseCommand.Type'('ACTIVE_CONSUMER_CHANGE', Bin,
    _TrUserData) ->
  <<Bin/binary, 31>>;
'e_enum_BaseCommand.Type'('GET_TOPICS_OF_NAMESPACE',
    Bin, _TrUserData) ->
  <<Bin/binary, 32>>;
'e_enum_BaseCommand.Type'('GET_TOPICS_OF_NAMESPACE_RESPONSE',
    Bin, _TrUserData) ->
  <<Bin/binary, 33>>;
'e_enum_BaseCommand.Type'('GET_SCHEMA', Bin,
    _TrUserData) ->
  <<Bin/binary, 34>>;
'e_enum_BaseCommand.Type'('GET_SCHEMA_RESPONSE', Bin,
    _TrUserData) ->
  <<Bin/binary, 35>>;
'e_enum_BaseCommand.Type'('AUTH_CHALLENGE', Bin,
    _TrUserData) ->
  <<Bin/binary, 36>>;
'e_enum_BaseCommand.Type'('AUTH_RESPONSE', Bin,
    _TrUserData) ->
  <<Bin/binary, 37>>;
'e_enum_BaseCommand.Type'(V, Bin, _TrUserData) ->
  e_varint(V, Bin).

-compile({nowarn_unused_function, {e_type_sint, 3}}).

e_type_sint(Value, Bin, _TrUserData) when Value >= 0 ->
  e_varint(Value * 2, Bin);
e_type_sint(Value, Bin, _TrUserData) ->
  e_varint(Value * -2 - 1, Bin).

-compile({nowarn_unused_function, {e_type_int32, 3}}).

e_type_int32(Value, Bin, _TrUserData)
  when 0 =< Value, Value =< 127 ->
  <<Bin/binary, Value>>;
e_type_int32(Value, Bin, _TrUserData) ->
  <<N:64/unsigned-native>> = <<Value:64/signed-native>>,
  e_varint(N, Bin).

-compile({nowarn_unused_function, {e_type_int64, 3}}).

e_type_int64(Value, Bin, _TrUserData)
  when 0 =< Value, Value =< 127 ->
  <<Bin/binary, Value>>;
e_type_int64(Value, Bin, _TrUserData) ->
  <<N:64/unsigned-native>> = <<Value:64/signed-native>>,
  e_varint(N, Bin).

-compile({nowarn_unused_function, {e_type_bool, 3}}).

e_type_bool(true, Bin, _TrUserData) ->
  <<Bin/binary, 1>>;
e_type_bool(false, Bin, _TrUserData) ->
  <<Bin/binary, 0>>;
e_type_bool(1, Bin, _TrUserData) -> <<Bin/binary, 1>>;
e_type_bool(0, Bin, _TrUserData) -> <<Bin/binary, 0>>.

-compile({nowarn_unused_function, {e_type_string, 3}}).

e_type_string(S, Bin, _TrUserData) ->
  Utf8 = unicode:characters_to_binary(S),
  Bin2 = e_varint(byte_size(Utf8), Bin),
  <<Bin2/binary, Utf8/binary>>.

-compile({nowarn_unused_function, {e_type_bytes, 3}}).

e_type_bytes(Bytes, Bin, _TrUserData)
  when is_binary(Bytes) ->
  Bin2 = e_varint(byte_size(Bytes), Bin),
  <<Bin2/binary, Bytes/binary>>;
e_type_bytes(Bytes, Bin, _TrUserData)
  when is_list(Bytes) ->
  BytesBin = iolist_to_binary(Bytes),
  Bin2 = e_varint(byte_size(BytesBin), Bin),
  <<Bin2/binary, BytesBin/binary>>.

-compile({nowarn_unused_function, {e_type_fixed32, 3}}).

e_type_fixed32(Value, Bin, _TrUserData) ->
  <<Bin/binary, Value:32/little>>.

-compile({nowarn_unused_function,
  {e_type_sfixed32, 3}}).

e_type_sfixed32(Value, Bin, _TrUserData) ->
  <<Bin/binary, Value:32/little-signed>>.

-compile({nowarn_unused_function, {e_type_fixed64, 3}}).

e_type_fixed64(Value, Bin, _TrUserData) ->
  <<Bin/binary, Value:64/little>>.

-compile({nowarn_unused_function,
  {e_type_sfixed64, 3}}).

e_type_sfixed64(Value, Bin, _TrUserData) ->
  <<Bin/binary, Value:64/little-signed>>.

-compile({nowarn_unused_function, {e_type_float, 3}}).

e_type_float(V, Bin, _) when is_number(V) ->
  <<Bin/binary, V:32/little-float>>;
e_type_float(infinity, Bin, _) ->
  <<Bin/binary, 0:16, 128, 127>>;
e_type_float('-infinity', Bin, _) ->
  <<Bin/binary, 0:16, 128, 255>>;
e_type_float(nan, Bin, _) ->
  <<Bin/binary, 0:16, 192, 127>>.

-compile({nowarn_unused_function, {e_type_double, 3}}).

e_type_double(V, Bin, _) when is_number(V) ->
  <<Bin/binary, V:64/little-float>>;
e_type_double(infinity, Bin, _) ->
  <<Bin/binary, 0:48, 240, 127>>;
e_type_double('-infinity', Bin, _) ->
  <<Bin/binary, 0:48, 240, 255>>;
e_type_double(nan, Bin, _) ->
  <<Bin/binary, 0:48, 248, 127>>.

-compile({nowarn_unused_function, {e_varint, 3}}).

e_varint(N, Bin, _TrUserData) -> e_varint(N, Bin).

-compile({nowarn_unused_function, {e_varint, 2}}).

e_varint(N, Bin) when N =< 127 -> <<Bin/binary, N>>;
e_varint(N, Bin) ->
  Bin2 = <<Bin/binary, (N band 127 bor 128)>>,
  e_varint(N bsr 7, Bin2).

decode_msg(Bin, MsgName) when is_binary(Bin) ->
  decode_msg(Bin, MsgName, []).

decode_msg(Bin, MsgName, Opts) when is_binary(Bin) ->
  TrUserData = proplists:get_value(user_data, Opts),
  decode_msg_1_catch(Bin, MsgName, TrUserData).

decode_msg_1_catch(Bin, MsgName, TrUserData) ->
  try decode_msg_2_doit(MsgName, Bin, TrUserData) catch
    Class:Reason:StackTrace ->
      error({gpb_error,
        {decoding_failure,
          {Bin, MsgName, {Class, Reason, StackTrace}}}})
  end.

decode_msg_2_doit('Schema', Bin, TrUserData) ->
  id(decode_msg_Schema(Bin, TrUserData), TrUserData);
decode_msg_2_doit('MessageIdData', Bin, TrUserData) ->
  id(decode_msg_MessageIdData(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('KeyValue', Bin, TrUserData) ->
  id(decode_msg_KeyValue(Bin, TrUserData), TrUserData);
decode_msg_2_doit('KeyLongValue', Bin, TrUserData) ->
  id(decode_msg_KeyLongValue(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('EncryptionKeys', Bin, TrUserData) ->
  id(decode_msg_EncryptionKeys(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('MessageMetadata', Bin, TrUserData) ->
  id(decode_msg_MessageMetadata(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('SingleMessageMetadata', Bin,
    TrUserData) ->
  id(decode_msg_SingleMessageMetadata(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandConnect', Bin, TrUserData) ->
  id(decode_msg_CommandConnect(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandConnected', Bin,
    TrUserData) ->
  id(decode_msg_CommandConnected(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandAuthResponse', Bin,
    TrUserData) ->
  id(decode_msg_CommandAuthResponse(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandAuthChallenge', Bin,
    TrUserData) ->
  id(decode_msg_CommandAuthChallenge(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('AuthData', Bin, TrUserData) ->
  id(decode_msg_AuthData(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandSubscribe', Bin,
    TrUserData) ->
  id(decode_msg_CommandSubscribe(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandPartitionedTopicMetadata',
    Bin, TrUserData) ->
  id(decode_msg_CommandPartitionedTopicMetadata(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandPartitionedTopicMetadataResponse',
    Bin, TrUserData) ->
  id(decode_msg_CommandPartitionedTopicMetadataResponse(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandLookupTopic', Bin,
    TrUserData) ->
  id(decode_msg_CommandLookupTopic(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandLookupTopicResponse', Bin,
    TrUserData) ->
  id(decode_msg_CommandLookupTopicResponse(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandProducer', Bin, TrUserData) ->
  id(decode_msg_CommandProducer(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandSend', Bin, TrUserData) ->
  id(decode_msg_CommandSend(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandSendReceipt', Bin,
    TrUserData) ->
  id(decode_msg_CommandSendReceipt(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandSendError', Bin,
    TrUserData) ->
  id(decode_msg_CommandSendError(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandMessage', Bin, TrUserData) ->
  id(decode_msg_CommandMessage(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandAck', Bin, TrUserData) ->
  id(decode_msg_CommandAck(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandActiveConsumerChange', Bin,
    TrUserData) ->
  id(decode_msg_CommandActiveConsumerChange(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandFlow', Bin, TrUserData) ->
  id(decode_msg_CommandFlow(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandUnsubscribe', Bin,
    TrUserData) ->
  id(decode_msg_CommandUnsubscribe(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandSeek', Bin, TrUserData) ->
  id(decode_msg_CommandSeek(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandReachedEndOfTopic', Bin,
    TrUserData) ->
  id(decode_msg_CommandReachedEndOfTopic(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandCloseProducer', Bin,
    TrUserData) ->
  id(decode_msg_CommandCloseProducer(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandCloseConsumer', Bin,
    TrUserData) ->
  id(decode_msg_CommandCloseConsumer(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandRedeliverUnacknowledgedMessages',
    Bin, TrUserData) ->
  id(decode_msg_CommandRedeliverUnacknowledgedMessages(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandSuccess', Bin, TrUserData) ->
  id(decode_msg_CommandSuccess(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandProducerSuccess', Bin,
    TrUserData) ->
  id(decode_msg_CommandProducerSuccess(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandError', Bin, TrUserData) ->
  id(decode_msg_CommandError(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandPing', Bin, TrUserData) ->
  id(decode_msg_CommandPing(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandPong', Bin, TrUserData) ->
  id(decode_msg_CommandPong(Bin, TrUserData), TrUserData);
decode_msg_2_doit('CommandConsumerStats', Bin,
    TrUserData) ->
  id(decode_msg_CommandConsumerStats(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandConsumerStatsResponse', Bin,
    TrUserData) ->
  id(decode_msg_CommandConsumerStatsResponse(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandGetLastMessageId', Bin,
    TrUserData) ->
  id(decode_msg_CommandGetLastMessageId(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandGetLastMessageIdResponse',
    Bin, TrUserData) ->
  id(decode_msg_CommandGetLastMessageIdResponse(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandGetTopicsOfNamespace', Bin,
    TrUserData) ->
  id(decode_msg_CommandGetTopicsOfNamespace(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandGetTopicsOfNamespaceResponse',
    Bin, TrUserData) ->
  id(decode_msg_CommandGetTopicsOfNamespaceResponse(Bin,
    TrUserData),
    TrUserData);
decode_msg_2_doit('CommandGetSchema', Bin,
    TrUserData) ->
  id(decode_msg_CommandGetSchema(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('CommandGetSchemaResponse', Bin,
    TrUserData) ->
  id(decode_msg_CommandGetSchemaResponse(Bin, TrUserData),
    TrUserData);
decode_msg_2_doit('BaseCommand', Bin, TrUserData) ->
  id(decode_msg_BaseCommand(Bin, TrUserData), TrUserData).

decode_msg_Schema(Bin, TrUserData) ->
  dfp_read_field_def_Schema(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    TrUserData).

dfp_read_field_def_Schema(<<10, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_Schema_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_Schema(<<26, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_Schema_schema_data(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_Schema(<<32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_Schema_type(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_Schema(<<42, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_Schema_properties(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_Schema(<<>>, 0, 0, F@_1, F@_2, F@_3,
    R1, TrUserData) ->
  S1 = #{name => F@_1, schema_data => F@_2, type => F@_3},
  if R1 == '$undef' -> S1;
    true -> S1#{properties => lists_reverse(R1, TrUserData)}
  end;
dfp_read_field_def_Schema(Other, Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, TrUserData) ->
  dg_read_field_def_Schema(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

dg_read_field_def_Schema(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_Schema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dg_read_field_def_Schema(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_Schema_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    26 ->
      d_field_Schema_schema_data(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    32 ->
      d_field_Schema_type(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    42 ->
      d_field_Schema_properties(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_Schema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        1 ->
          skip_64_Schema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        2 ->
          skip_length_delimited_Schema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        3 ->
          skip_group_Schema(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        5 ->
          skip_32_Schema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData)
      end
  end;
dg_read_field_def_Schema(<<>>, 0, 0, F@_1, F@_2, F@_3,
    R1, TrUserData) ->
  S1 = #{name => F@_1, schema_data => F@_2, type => F@_3},
  if R1 == '$undef' -> S1;
    true -> S1#{properties => lists_reverse(R1, TrUserData)}
  end.

d_field_Schema_name(<<1:1, X:7, Rest/binary>>, N, Acc,
    F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_Schema_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_Schema_name(<<0:1, X:7, Rest/binary>>, N, Acc,
    _, F@_2, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_Schema(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

d_field_Schema_schema_data(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_Schema_schema_data(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_Schema_schema_data(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, _, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_Schema(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    TrUserData).

d_field_Schema_type(<<1:1, X:7, Rest/binary>>, N, Acc,
    F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_Schema_type(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_Schema_type(<<0:1, X:7, Rest/binary>>, N, Acc,
    F@_1, F@_2, _, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id('d_enum_Schema.Type'(begin
                                                  <<Res:32/signed-native>> =
                                                    <<(X bsl N +
                                                      Acc):32/unsigned-native>>,
                                                  id(Res, TrUserData)
                                                end),
    TrUserData),
    Rest},
  dfp_read_field_def_Schema(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    TrUserData).

d_field_Schema_properties(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_Schema_properties(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_Schema_properties(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, Prev, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_Schema(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    cons(NewFValue, Prev, TrUserData),
    TrUserData).

skip_varint_Schema(<<1:1, _:7, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  skip_varint_Schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_varint_Schema(<<0:1, _:7, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_Schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_length_delimited_Schema(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  skip_length_delimited_Schema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_length_delimited_Schema(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_Schema(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_group_Schema(Bin, FNum, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_Schema(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_32_Schema(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_Schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_64_Schema(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_Schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

decode_msg_MessageIdData(Bin, TrUserData) ->
  dfp_read_field_def_MessageIdData(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_MessageIdData(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_MessageIdData_ledgerId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_MessageIdData(<<16, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_MessageIdData_entryId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_MessageIdData(<<24, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_MessageIdData_partition(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_MessageIdData(<<32, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_MessageIdData_batch_index(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_MessageIdData(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, _) ->
  S1 = #{ledgerId => F@_1, entryId => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{partition => F@_3}
       end,
  if F@_4 == '$undef' -> S2;
    true -> S2#{batch_index => F@_4}
  end;
dfp_read_field_def_MessageIdData(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dg_read_field_def_MessageIdData(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

dg_read_field_def_MessageIdData(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_MessageIdData(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dg_read_field_def_MessageIdData(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_MessageIdData_ledgerId(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    16 ->
      d_field_MessageIdData_entryId(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    24 ->
      d_field_MessageIdData_partition(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    32 ->
      d_field_MessageIdData_batch_index(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_MessageIdData(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        1 ->
          skip_64_MessageIdData(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        2 ->
          skip_length_delimited_MessageIdData(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        3 ->
          skip_group_MessageIdData(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        5 ->
          skip_32_MessageIdData(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData)
      end
  end;
dg_read_field_def_MessageIdData(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, _) ->
  S1 = #{ledgerId => F@_1, entryId => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{partition => F@_3}
       end,
  if F@_4 == '$undef' -> S2;
    true -> S2#{batch_index => F@_4}
  end.

d_field_MessageIdData_ledgerId(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_MessageIdData_ledgerId(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_MessageIdData_ledgerId(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_MessageIdData(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

d_field_MessageIdData_entryId(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_MessageIdData_entryId(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_MessageIdData_entryId(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_MessageIdData(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    TrUserData).

d_field_MessageIdData_partition(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_MessageIdData_partition(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_MessageIdData_partition(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_MessageIdData(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    TrUserData).

d_field_MessageIdData_batch_index(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_MessageIdData_batch_index(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_MessageIdData_batch_index(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_MessageIdData(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    TrUserData).

skip_varint_MessageIdData(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  skip_varint_MessageIdData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_varint_MessageIdData(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_MessageIdData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_length_delimited_MessageIdData(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  skip_length_delimited_MessageIdData(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_length_delimited_MessageIdData(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_MessageIdData(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_group_MessageIdData(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_MessageIdData(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_32_MessageIdData(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_MessageIdData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_64_MessageIdData(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_MessageIdData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

decode_msg_KeyValue(Bin, TrUserData) ->
  dfp_read_field_def_KeyValue(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_KeyValue(<<10, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  d_field_KeyValue_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_KeyValue(<<18, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  d_field_KeyValue_value(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_KeyValue(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  #{key => F@_1, value => F@_2};
dfp_read_field_def_KeyValue(Other, Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dg_read_field_def_KeyValue(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_KeyValue(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_KeyValue(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_KeyValue(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_KeyValue_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    18 ->
      d_field_KeyValue_value(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_KeyValue(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_KeyValue(Rest, 0, 0, F@_1, F@_2, TrUserData);
        2 ->
          skip_length_delimited_KeyValue(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_KeyValue(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_KeyValue(Rest, 0, 0, F@_1, F@_2, TrUserData)
      end
  end;
dg_read_field_def_KeyValue(<<>>, 0, 0, F@_1, F@_2, _) ->
  #{key => F@_1, value => F@_2}.

d_field_KeyValue_key(<<1:1, X:7, Rest/binary>>, N, Acc,
    F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_KeyValue_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_KeyValue_key(<<0:1, X:7, Rest/binary>>, N, Acc,
    _, F@_2, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_KeyValue(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_KeyValue_value(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_KeyValue_value(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_KeyValue_value(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_KeyValue(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_KeyValue(<<1:1, _:7, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  skip_varint_KeyValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_KeyValue(<<0:1, _:7, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_KeyValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_KeyValue(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_KeyValue(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_KeyValue(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_KeyValue(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_KeyValue(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_KeyValue(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_KeyValue(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dfp_read_field_def_KeyValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_KeyValue(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dfp_read_field_def_KeyValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_KeyLongValue(Bin, TrUserData) ->
  dfp_read_field_def_KeyLongValue(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_KeyLongValue(<<10, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  d_field_KeyLongValue_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_KeyLongValue(<<16, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  d_field_KeyLongValue_value(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_KeyLongValue(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  #{key => F@_1, value => F@_2};
dfp_read_field_def_KeyLongValue(Other, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dg_read_field_def_KeyLongValue(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_KeyLongValue(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_KeyLongValue(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_KeyLongValue(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_KeyLongValue_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_KeyLongValue_value(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_KeyLongValue(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_KeyLongValue(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_KeyLongValue(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_KeyLongValue(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_KeyLongValue(Rest, 0, 0, F@_1, F@_2, TrUserData)
      end
  end;
dg_read_field_def_KeyLongValue(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  #{key => F@_1, value => F@_2}.

d_field_KeyLongValue_key(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_KeyLongValue_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_KeyLongValue_key(<<0:1, X:7, Rest/binary>>, N,
    Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_KeyLongValue(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_KeyLongValue_value(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_KeyLongValue_value(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_KeyLongValue_value(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_KeyLongValue(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_KeyLongValue(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_KeyLongValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_KeyLongValue(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_KeyLongValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_KeyLongValue(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_KeyLongValue(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_KeyLongValue(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_KeyLongValue(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_KeyLongValue(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_KeyLongValue(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_KeyLongValue(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_KeyLongValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_KeyLongValue(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_KeyLongValue(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_EncryptionKeys(Bin, TrUserData) ->
  dfp_read_field_def_EncryptionKeys(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    TrUserData).

dfp_read_field_def_EncryptionKeys(<<10, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_EncryptionKeys_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_EncryptionKeys(<<18, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_EncryptionKeys_value(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_EncryptionKeys(<<26, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_EncryptionKeys_metadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_EncryptionKeys(<<>>, 0, 0, F@_1,
    F@_2, R1, TrUserData) ->
  S1 = #{key => F@_1, value => F@_2},
  if R1 == '$undef' -> S1;
    true -> S1#{metadata => lists_reverse(R1, TrUserData)}
  end;
dfp_read_field_def_EncryptionKeys(Other, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dg_read_field_def_EncryptionKeys(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_EncryptionKeys(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_EncryptionKeys(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_EncryptionKeys(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_EncryptionKeys_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    18 ->
      d_field_EncryptionKeys_value(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    26 ->
      d_field_EncryptionKeys_metadata(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_EncryptionKeys(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_EncryptionKeys(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_EncryptionKeys(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_EncryptionKeys(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_EncryptionKeys(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_EncryptionKeys(<<>>, 0, 0, F@_1, F@_2,
    R1, TrUserData) ->
  S1 = #{key => F@_1, value => F@_2},
  if R1 == '$undef' -> S1;
    true -> S1#{metadata => lists_reverse(R1, TrUserData)}
  end.

d_field_EncryptionKeys_key(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_EncryptionKeys_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_EncryptionKeys_key(<<0:1, X:7, Rest/binary>>, N,
    Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_EncryptionKeys(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_EncryptionKeys_value(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_EncryptionKeys_value(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_EncryptionKeys_value(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_EncryptionKeys(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    TrUserData).

d_field_EncryptionKeys_metadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_EncryptionKeys_metadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_EncryptionKeys_metadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, Prev, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_EncryptionKeys(RestF,
    0,
    0,
    F@_1,
    F@_2,
    cons(NewFValue, Prev, TrUserData),
    TrUserData).

skip_varint_EncryptionKeys(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_EncryptionKeys(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_EncryptionKeys(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_EncryptionKeys(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_EncryptionKeys(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_EncryptionKeys(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_EncryptionKeys(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_EncryptionKeys(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_EncryptionKeys(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_EncryptionKeys(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_EncryptionKeys(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_EncryptionKeys(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_EncryptionKeys(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_EncryptionKeys(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_MessageMetadata(Bin, TrUserData) ->
  dfp_read_field_def_MessageMetadata(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_MessageMetadata(<<10, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_producer_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<16, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_sequence_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<24, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_publish_time(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<34, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_properties(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<42, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_replicated_from(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<50, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_partition_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<58, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_replicate_to(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<64, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_compression(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<72, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_uncompressed_size(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<88, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_num_messages_in_batch(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<96, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_event_time(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<106, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_encryption_keys(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<114, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_encryption_algo(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<122, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_encryption_param(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<130, 1,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_schema_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<136, 1,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_partition_key_b64_encoded(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<146, 1,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  d_field_MessageMetadata_ordering_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dfp_read_field_def_MessageMetadata(<<>>, 0, 0, F@_1,
    F@_2, F@_3, R1, F@_5, F@_6, R2, F@_8, F@_9,
    F@_10, F@_11, R3, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData) ->
  S1 = #{producer_name => F@_1, sequence_id => F@_2,
    publish_time => F@_3,
    replicate_to => lists_reverse(R2, TrUserData)},
  S2 = if R1 == '$undef' -> S1;
         true -> S1#{properties => lists_reverse(R1, TrUserData)}
       end,
  S3 = if F@_5 == '$undef' -> S2;
         true -> S2#{replicated_from => F@_5}
       end,
  S4 = if F@_6 == '$undef' -> S3;
         true -> S3#{partition_key => F@_6}
       end,
  S5 = if F@_8 == '$undef' -> S4;
         true -> S4#{compression => F@_8}
       end,
  S6 = if F@_9 == '$undef' -> S5;
         true -> S5#{uncompressed_size => F@_9}
       end,
  S7 = if F@_10 == '$undef' -> S6;
         true -> S6#{num_messages_in_batch => F@_10}
       end,
  S8 = if F@_11 == '$undef' -> S7;
         true -> S7#{event_time => F@_11}
       end,
  S9 = if R3 == '$undef' -> S8;
         true ->
           S8#{encryption_keys => lists_reverse(R3, TrUserData)}
       end,
  S10 = if F@_13 == '$undef' -> S9;
          true -> S9#{encryption_algo => F@_13}
        end,
  S11 = if F@_14 == '$undef' -> S10;
          true -> S10#{encryption_param => F@_14}
        end,
  S12 = if F@_15 == '$undef' -> S11;
          true -> S11#{schema_version => F@_15}
        end,
  S13 = if F@_16 == '$undef' -> S12;
          true -> S12#{partition_key_b64_encoded => F@_16}
        end,
  if F@_17 == '$undef' -> S13;
    true -> S13#{ordering_key => F@_17}
  end;
dfp_read_field_def_MessageMetadata(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, TrUserData) ->
  dg_read_field_def_MessageMetadata(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

dg_read_field_def_MessageMetadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_MessageMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
dg_read_field_def_MessageMetadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_MessageMetadata_producer_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    16 ->
      d_field_MessageMetadata_sequence_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    24 ->
      d_field_MessageMetadata_publish_time(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    34 ->
      d_field_MessageMetadata_properties(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    42 ->
      d_field_MessageMetadata_replicated_from(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    50 ->
      d_field_MessageMetadata_partition_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    58 ->
      d_field_MessageMetadata_replicate_to(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    64 ->
      d_field_MessageMetadata_compression(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    72 ->
      d_field_MessageMetadata_uncompressed_size(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    88 ->
      d_field_MessageMetadata_num_messages_in_batch(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    96 ->
      d_field_MessageMetadata_event_time(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    106 ->
      d_field_MessageMetadata_encryption_keys(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    114 ->
      d_field_MessageMetadata_encryption_algo(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    122 ->
      d_field_MessageMetadata_encryption_param(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    130 ->
      d_field_MessageMetadata_schema_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    136 ->
      d_field_MessageMetadata_partition_key_b64_encoded(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    146 ->
      d_field_MessageMetadata_ordering_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_MessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            TrUserData);
        1 ->
          skip_64_MessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            TrUserData);
        2 ->
          skip_length_delimited_MessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            TrUserData);
        3 ->
          skip_group_MessageMetadata(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            TrUserData);
        5 ->
          skip_32_MessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            TrUserData)
      end
  end;
dg_read_field_def_MessageMetadata(<<>>, 0, 0, F@_1,
    F@_2, F@_3, R1, F@_5, F@_6, R2, F@_8, F@_9,
    F@_10, F@_11, R3, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData) ->
  S1 = #{producer_name => F@_1, sequence_id => F@_2,
    publish_time => F@_3,
    replicate_to => lists_reverse(R2, TrUserData)},
  S2 = if R1 == '$undef' -> S1;
         true -> S1#{properties => lists_reverse(R1, TrUserData)}
       end,
  S3 = if F@_5 == '$undef' -> S2;
         true -> S2#{replicated_from => F@_5}
       end,
  S4 = if F@_6 == '$undef' -> S3;
         true -> S3#{partition_key => F@_6}
       end,
  S5 = if F@_8 == '$undef' -> S4;
         true -> S4#{compression => F@_8}
       end,
  S6 = if F@_9 == '$undef' -> S5;
         true -> S5#{uncompressed_size => F@_9}
       end,
  S7 = if F@_10 == '$undef' -> S6;
         true -> S6#{num_messages_in_batch => F@_10}
       end,
  S8 = if F@_11 == '$undef' -> S7;
         true -> S7#{event_time => F@_11}
       end,
  S9 = if R3 == '$undef' -> S8;
         true ->
           S8#{encryption_keys => lists_reverse(R3, TrUserData)}
       end,
  S10 = if F@_13 == '$undef' -> S9;
          true -> S9#{encryption_algo => F@_13}
        end,
  S11 = if F@_14 == '$undef' -> S10;
          true -> S10#{encryption_param => F@_14}
        end,
  S12 = if F@_15 == '$undef' -> S11;
          true -> S11#{schema_version => F@_15}
        end,
  S13 = if F@_16 == '$undef' -> S12;
          true -> S12#{partition_key_b64_encoded => F@_16}
        end,
  if F@_17 == '$undef' -> S13;
    true -> S13#{ordering_key => F@_17}
  end.

d_field_MessageMetadata_producer_name(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_producer_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_producer_name(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_sequence_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_sequence_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_sequence_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_publish_time(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_publish_time(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_publish_time(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_properties(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_properties(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_properties(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, Prev, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    cons(NewFValue, Prev, TrUserData),
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_replicated_from(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_replicated_from(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_replicated_from(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, _, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_partition_key(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_partition_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_partition_key(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, _,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    NewFValue,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_replicate_to(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_replicate_to(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_replicate_to(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    Prev, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    cons(NewFValue, Prev, TrUserData),
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_compression(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_compression(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_compression(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, _, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_CompressionType(begin
                                                    <<Res:32/signed-native>> =
                                                      <<(X bsl N +
                                                        Acc):32/unsigned-native>>,
                                                    id(Res, TrUserData)
                                                  end),
    TrUserData),
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    NewFValue,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_uncompressed_size(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_uncompressed_size(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_uncompressed_size(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, _, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    NewFValue,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_num_messages_in_batch(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_num_messages_in_batch(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_num_messages_in_batch(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9, _,
    F@_11, F@_12, F@_13, F@_14, F@_15,
    F@_16, F@_17, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    NewFValue,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_event_time(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_event_time(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_event_time(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, _, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    NewFValue,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_encryption_keys(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_encryption_keys(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_encryption_keys(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    Prev, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_EncryptionKeys(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    cons(NewFValue, Prev, TrUserData),
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_encryption_algo(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_encryption_algo(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_encryption_algo(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, _, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    NewFValue,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_encryption_param(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_encryption_param(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_encryption_param(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, _, F@_15, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    NewFValue,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_schema_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_schema_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_schema_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, _, F@_16, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    NewFValue,
    F@_16,
    F@_17,
    TrUserData).

d_field_MessageMetadata_partition_key_b64_encoded(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16,
    F@_17, TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_partition_key_b64_encoded(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_partition_key_b64_encoded(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, _, F@_17,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    NewFValue,
    F@_17,
    TrUserData).

d_field_MessageMetadata_ordering_key(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  d_field_MessageMetadata_ordering_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
d_field_MessageMetadata_ordering_key(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, _,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_MessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    NewFValue,
    TrUserData).

skip_varint_MessageMetadata(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, TrUserData) ->
  skip_varint_MessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
skip_varint_MessageMetadata(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, TrUserData) ->
  dfp_read_field_def_MessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

skip_length_delimited_MessageMetadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_MessageMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData);
skip_length_delimited_MessageMetadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_MessageMetadata(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

skip_group_MessageMetadata(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_MessageMetadata(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

skip_32_MessageMetadata(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  dfp_read_field_def_MessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

skip_64_MessageMetadata(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    TrUserData) ->
  dfp_read_field_def_MessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    TrUserData).

decode_msg_SingleMessageMetadata(Bin, TrUserData) ->
  dfp_read_field_def_SingleMessageMetadata(Bin,
    0,
    0,
    id([], TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_SingleMessageMetadata(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_properties(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_partition_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_payload_size(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_compacted_out(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<40,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_event_time(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<48,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_partition_key_b64_encoded(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<58,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  d_field_SingleMessageMetadata_ordering_key(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_SingleMessageMetadata(<<>>, 0, 0, R1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  S1 = #{payload_size => F@_3},
  S2 = if R1 == '$undef' -> S1;
         true -> S1#{properties => lists_reverse(R1, TrUserData)}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{partition_key => F@_2}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{compacted_out => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{event_time => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{partition_key_b64_encoded => F@_6}
       end,
  if F@_7 == '$undef' -> S6;
    true -> S6#{ordering_key => F@_7}
  end;
dfp_read_field_def_SingleMessageMetadata(Other, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  dg_read_field_def_SingleMessageMetadata(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

dg_read_field_def_SingleMessageMetadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_SingleMessageMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dg_read_field_def_SingleMessageMetadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_SingleMessageMetadata_properties(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    18 ->
      d_field_SingleMessageMetadata_partition_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    24 ->
      d_field_SingleMessageMetadata_payload_size(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    32 ->
      d_field_SingleMessageMetadata_compacted_out(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    40 ->
      d_field_SingleMessageMetadata_event_time(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    48 ->
      d_field_SingleMessageMetadata_partition_key_b64_encoded(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    58 ->
      d_field_SingleMessageMetadata_ordering_key(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_SingleMessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        1 ->
          skip_64_SingleMessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        2 ->
          skip_length_delimited_SingleMessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        3 ->
          skip_group_SingleMessageMetadata(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        5 ->
          skip_32_SingleMessageMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData)
      end
  end;
dg_read_field_def_SingleMessageMetadata(<<>>, 0, 0, R1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  S1 = #{payload_size => F@_3},
  S2 = if R1 == '$undef' -> S1;
         true -> S1#{properties => lists_reverse(R1, TrUserData)}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{partition_key => F@_2}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{compacted_out => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{event_time => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{partition_key_b64_encoded => F@_6}
       end,
  if F@_7 == '$undef' -> S6;
    true -> S6#{ordering_key => F@_7}
  end.

d_field_SingleMessageMetadata_properties(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_properties(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_properties(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, Prev, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    cons(NewFValue, Prev, TrUserData),
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_SingleMessageMetadata_partition_key(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_partition_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_partition_key(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_SingleMessageMetadata_payload_size(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_payload_size(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_payload_size(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_SingleMessageMetadata_compacted_out(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_compacted_out(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_compacted_out(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5,
    F@_6, F@_7, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_SingleMessageMetadata_event_time(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_event_time(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_event_time(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, _,
    F@_6, F@_7, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    F@_7,
    TrUserData).

d_field_SingleMessageMetadata_partition_key_b64_encoded(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_partition_key_b64_encoded(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_partition_key_b64_encoded(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5, _,
    F@_7, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    NewFValue,
    F@_7,
    TrUserData).

d_field_SingleMessageMetadata_ordering_key(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_SingleMessageMetadata_ordering_key(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_SingleMessageMetadata_ordering_key(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_SingleMessageMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    NewFValue,
    TrUserData).

skip_varint_SingleMessageMetadata(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  skip_varint_SingleMessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
skip_varint_SingleMessageMetadata(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  dfp_read_field_def_SingleMessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_length_delimited_SingleMessageMetadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, TrUserData)
  when N < 57 ->
  skip_length_delimited_SingleMessageMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
skip_length_delimited_SingleMessageMetadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_SingleMessageMetadata(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_group_SingleMessageMetadata(Bin, FNum, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_SingleMessageMetadata(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_32_SingleMessageMetadata(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  dfp_read_field_def_SingleMessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_64_SingleMessageMetadata(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  dfp_read_field_def_SingleMessageMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

decode_msg_CommandConnect(Bin, TrUserData) ->
  dfp_read_field_def_CommandConnect(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandConnect(<<10, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_client_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<16, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_auth_method(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<42, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_auth_method_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<26, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_auth_data(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<32, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_protocol_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<50, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_proxy_to_broker_url(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<58, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_original_principal(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<66, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_original_auth_data(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<74, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  d_field_CommandConnect_original_auth_method(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dfp_read_field_def_CommandConnect(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, _) ->
  S1 = #{client_version => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{auth_method => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{auth_method_name => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{auth_data => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{protocol_version => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{proxy_to_broker_url => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{original_principal => F@_7}
       end,
  S8 = if F@_8 == '$undef' -> S7;
         true -> S7#{original_auth_data => F@_8}
       end,
  if F@_9 == '$undef' -> S8;
    true -> S8#{original_auth_method => F@_9}
  end;
dfp_read_field_def_CommandConnect(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, TrUserData) ->
  dg_read_field_def_CommandConnect(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

dg_read_field_def_CommandConnect(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandConnect(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
dg_read_field_def_CommandConnect(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandConnect_client_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    16 ->
      d_field_CommandConnect_auth_method(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    42 ->
      d_field_CommandConnect_auth_method_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    26 ->
      d_field_CommandConnect_auth_data(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    32 ->
      d_field_CommandConnect_protocol_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    50 ->
      d_field_CommandConnect_proxy_to_broker_url(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    58 ->
      d_field_CommandConnect_original_principal(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    66 ->
      d_field_CommandConnect_original_auth_data(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    74 ->
      d_field_CommandConnect_original_auth_method(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandConnect(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            TrUserData);
        1 ->
          skip_64_CommandConnect(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            TrUserData);
        2 ->
          skip_length_delimited_CommandConnect(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            TrUserData);
        3 ->
          skip_group_CommandConnect(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            TrUserData);
        5 ->
          skip_32_CommandConnect(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            TrUserData)
      end
  end;
dg_read_field_def_CommandConnect(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, _) ->
  S1 = #{client_version => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{auth_method => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{auth_method_name => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{auth_data => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{protocol_version => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{proxy_to_broker_url => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{original_principal => F@_7}
       end,
  S8 = if F@_8 == '$undef' -> S7;
         true -> S7#{original_auth_data => F@_8}
       end,
  if F@_9 == '$undef' -> S8;
    true -> S8#{original_auth_method => F@_9}
  end.

d_field_CommandConnect_client_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_client_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_client_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_auth_method(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_auth_method(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_auth_method(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_AuthMethod(begin
                                               <<Res:32/signed-native>> =
                                                 <<(X bsl N +
                                                   Acc):32/unsigned-native>>,
                                               id(Res, TrUserData)
                                             end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_auth_method_name(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_auth_method_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_auth_method_name(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_auth_data(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_auth_data(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_auth_data(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5, F@_6, F@_7,
    F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_protocol_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_protocol_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_protocol_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, _, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_proxy_to_broker_url(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_proxy_to_broker_url(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_proxy_to_broker_url(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    _, F@_7, F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    NewFValue,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_original_principal(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_original_principal(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_original_principal(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, _, F@_8, F@_9, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    NewFValue,
    F@_8,
    F@_9,
    TrUserData).

d_field_CommandConnect_original_auth_data(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  d_field_CommandConnect_original_auth_data(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_original_auth_data(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, _, F@_9, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    NewFValue,
    F@_9,
    TrUserData).

d_field_CommandConnect_original_auth_method(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    TrUserData)
  when N < 57 ->
  d_field_CommandConnect_original_auth_method(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
d_field_CommandConnect_original_auth_method(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, _,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnect(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    NewFValue,
    TrUserData).

skip_varint_CommandConnect(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, TrUserData) ->
  skip_varint_CommandConnect(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
skip_varint_CommandConnect(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, TrUserData) ->
  dfp_read_field_def_CommandConnect(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

skip_length_delimited_CommandConnect(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandConnect(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData);
skip_length_delimited_CommandConnect(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandConnect(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

skip_group_CommandConnect(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandConnect(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

skip_32_CommandConnect(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    TrUserData) ->
  dfp_read_field_def_CommandConnect(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

skip_64_CommandConnect(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    TrUserData) ->
  dfp_read_field_def_CommandConnect(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    TrUserData).

decode_msg_CommandConnected(Bin, TrUserData) ->
  dfp_read_field_def_CommandConnected(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandConnected(<<10, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandConnected_server_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandConnected(<<16, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandConnected_protocol_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandConnected(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  S1 = #{server_version => F@_1},
  if F@_2 == '$undef' -> S1;
    true -> S1#{protocol_version => F@_2}
  end;
dfp_read_field_def_CommandConnected(Other, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dg_read_field_def_CommandConnected(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandConnected(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandConnected(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandConnected(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandConnected_server_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandConnected_protocol_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandConnected(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandConnected(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandConnected(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandConnected(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandConnected(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandConnected(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  S1 = #{server_version => F@_1},
  if F@_2 == '$undef' -> S1;
    true -> S1#{protocol_version => F@_2}
  end.

d_field_CommandConnected_server_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandConnected_server_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandConnected_server_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConnected(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandConnected_protocol_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandConnected_protocol_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandConnected_protocol_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandConnected(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandConnected(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandConnected(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandConnected(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandConnected(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandConnected(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandConnected(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandConnected(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandConnected(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandConnected(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandConnected(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandConnected(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandConnected(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandConnected(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandConnected(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandAuthResponse(Bin, TrUserData) ->
  dfp_read_field_def_CommandAuthResponse(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandAuthResponse(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandAuthResponse_client_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandAuthResponse(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandAuthResponse_response(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandAuthResponse(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandAuthResponse_protocol_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandAuthResponse(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{client_version => F@_1}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{response => F@_2}
       end,
  if F@_3 == '$undef' -> S3;
    true -> S3#{protocol_version => F@_3}
  end;
dfp_read_field_def_CommandAuthResponse(Other, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandAuthResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandAuthResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandAuthResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandAuthResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandAuthResponse_client_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    18 ->
      d_field_CommandAuthResponse_response(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    24 ->
      d_field_CommandAuthResponse_protocol_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandAuthResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandAuthResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandAuthResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandAuthResponse(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandAuthResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandAuthResponse(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{client_version => F@_1}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{response => F@_2}
       end,
  if F@_3 == '$undef' -> S3;
    true -> S3#{protocol_version => F@_3}
  end.

d_field_CommandAuthResponse_client_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandAuthResponse_client_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandAuthResponse_client_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandAuthResponse(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandAuthResponse_response(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandAuthResponse_response(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandAuthResponse_response(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, Prev, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_AuthData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandAuthResponse(RestF,
    0,
    0,
    F@_1,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_AuthData(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_3,
    TrUserData).

d_field_CommandAuthResponse_protocol_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 57 ->
  d_field_CommandAuthResponse_protocol_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandAuthResponse_protocol_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _,
    TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandAuthResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandAuthResponse(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandAuthResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandAuthResponse(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandAuthResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandAuthResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandAuthResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandAuthResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandAuthResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandAuthResponse(Bin, FNum, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandAuthResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandAuthResponse(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandAuthResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandAuthResponse(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandAuthResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandAuthChallenge(Bin, TrUserData) ->
  dfp_read_field_def_CommandAuthChallenge(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandAuthChallenge(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandAuthChallenge_server_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandAuthChallenge(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandAuthChallenge_challenge(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandAuthChallenge(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandAuthChallenge_protocol_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandAuthChallenge(<<>>, 0, 0,
    F@_1, F@_2, F@_3, _) ->
  S1 = #{},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{server_version => F@_1}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{challenge => F@_2}
       end,
  if F@_3 == '$undef' -> S3;
    true -> S3#{protocol_version => F@_3}
  end;
dfp_read_field_def_CommandAuthChallenge(Other, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandAuthChallenge(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandAuthChallenge(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandAuthChallenge(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandAuthChallenge(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandAuthChallenge_server_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    18 ->
      d_field_CommandAuthChallenge_challenge(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    24 ->
      d_field_CommandAuthChallenge_protocol_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandAuthChallenge(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandAuthChallenge(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandAuthChallenge(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandAuthChallenge(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandAuthChallenge(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandAuthChallenge(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{server_version => F@_1}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{challenge => F@_2}
       end,
  if F@_3 == '$undef' -> S3;
    true -> S3#{protocol_version => F@_3}
  end.

d_field_CommandAuthChallenge_server_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 57 ->
  d_field_CommandAuthChallenge_server_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandAuthChallenge_server_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandAuthChallenge(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandAuthChallenge_challenge(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandAuthChallenge_challenge(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandAuthChallenge_challenge(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, Prev, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_AuthData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandAuthChallenge(RestF,
    0,
    0,
    F@_1,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_AuthData(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_3,
    TrUserData).

d_field_CommandAuthChallenge_protocol_version(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 57 ->
  d_field_CommandAuthChallenge_protocol_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandAuthChallenge_protocol_version(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, _,
    TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandAuthChallenge(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandAuthChallenge(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandAuthChallenge(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandAuthChallenge(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandAuthChallenge(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandAuthChallenge(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandAuthChallenge(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandAuthChallenge(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandAuthChallenge(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandAuthChallenge(Bin, FNum, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandAuthChallenge(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandAuthChallenge(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandAuthChallenge(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandAuthChallenge(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandAuthChallenge(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_AuthData(Bin, TrUserData) ->
  dfp_read_field_def_AuthData(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_AuthData(<<10, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  d_field_AuthData_auth_method_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_AuthData(<<18, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  d_field_AuthData_auth_data(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_AuthData(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  S1 = #{},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{auth_method_name => F@_1}
       end,
  if F@_2 == '$undef' -> S2;
    true -> S2#{auth_data => F@_2}
  end;
dfp_read_field_def_AuthData(Other, Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dg_read_field_def_AuthData(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_AuthData(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_AuthData(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_AuthData(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_AuthData_auth_method_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    18 ->
      d_field_AuthData_auth_data(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_AuthData(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_AuthData(Rest, 0, 0, F@_1, F@_2, TrUserData);
        2 ->
          skip_length_delimited_AuthData(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_AuthData(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_AuthData(Rest, 0, 0, F@_1, F@_2, TrUserData)
      end
  end;
dg_read_field_def_AuthData(<<>>, 0, 0, F@_1, F@_2, _) ->
  S1 = #{},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{auth_method_name => F@_1}
       end,
  if F@_2 == '$undef' -> S2;
    true -> S2#{auth_data => F@_2}
  end.

d_field_AuthData_auth_method_name(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_AuthData_auth_method_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_AuthData_auth_method_name(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_AuthData(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_AuthData_auth_data(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_AuthData_auth_data(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_AuthData_auth_data(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_AuthData(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_AuthData(<<1:1, _:7, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  skip_varint_AuthData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_AuthData(<<0:1, _:7, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_AuthData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_AuthData(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_AuthData(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_AuthData(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_AuthData(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_AuthData(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_AuthData(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_AuthData(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dfp_read_field_def_AuthData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_AuthData(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dfp_read_field_def_AuthData(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandSubscribe(Bin, TrUserData) ->
  dfp_read_field_def_CommandSubscribe(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandSubscribe(<<10, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_topic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<18, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_subscription(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<24, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_subType(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<32, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<40, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<50, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_consumer_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<56, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_priority_level(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<64, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_durable(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<74, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_start_message_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<82, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_metadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<88, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_read_compacted(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<98, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<104,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  d_field_CommandSubscribe_initialPosition(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dfp_read_field_def_CommandSubscribe(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, R1, F@_11, F@_12, F@_13,
    TrUserData) ->
  S1 = #{topic => F@_1, subscription => F@_2,
    subType => F@_3, consumer_id => F@_4,
    request_id => F@_5},
  S2 = if F@_6 == '$undef' -> S1;
         true -> S1#{consumer_name => F@_6}
       end,
  S3 = if F@_7 == '$undef' -> S2;
         true -> S2#{priority_level => F@_7}
       end,
  S4 = if F@_8 == '$undef' -> S3;
         true -> S3#{durable => F@_8}
       end,
  S5 = if F@_9 == '$undef' -> S4;
         true -> S4#{start_message_id => F@_9}
       end,
  S6 = if R1 == '$undef' -> S5;
         true -> S5#{metadata => lists_reverse(R1, TrUserData)}
       end,
  S7 = if F@_11 == '$undef' -> S6;
         true -> S6#{read_compacted => F@_11}
       end,
  S8 = if F@_12 == '$undef' -> S7;
         true -> S7#{schema => F@_12}
       end,
  if F@_13 == '$undef' -> S8;
    true -> S8#{initialPosition => F@_13}
  end;
dfp_read_field_def_CommandSubscribe(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  dg_read_field_def_CommandSubscribe(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

dg_read_field_def_CommandSubscribe(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandSubscribe(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
dg_read_field_def_CommandSubscribe(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandSubscribe_topic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    18 ->
      d_field_CommandSubscribe_subscription(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    24 ->
      d_field_CommandSubscribe_subType(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    32 ->
      d_field_CommandSubscribe_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    40 ->
      d_field_CommandSubscribe_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    50 ->
      d_field_CommandSubscribe_consumer_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    56 ->
      d_field_CommandSubscribe_priority_level(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    64 ->
      d_field_CommandSubscribe_durable(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    74 ->
      d_field_CommandSubscribe_start_message_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    82 ->
      d_field_CommandSubscribe_metadata(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    88 ->
      d_field_CommandSubscribe_read_compacted(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    98 ->
      d_field_CommandSubscribe_schema(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    104 ->
      d_field_CommandSubscribe_initialPosition(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandSubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            TrUserData);
        1 ->
          skip_64_CommandSubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            TrUserData);
        2 ->
          skip_length_delimited_CommandSubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            TrUserData);
        3 ->
          skip_group_CommandSubscribe(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            TrUserData);
        5 ->
          skip_32_CommandSubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            TrUserData)
      end
  end;
dg_read_field_def_CommandSubscribe(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, R1, F@_11, F@_12, F@_13, TrUserData) ->
  S1 = #{topic => F@_1, subscription => F@_2,
    subType => F@_3, consumer_id => F@_4,
    request_id => F@_5},
  S2 = if F@_6 == '$undef' -> S1;
         true -> S1#{consumer_name => F@_6}
       end,
  S3 = if F@_7 == '$undef' -> S2;
         true -> S2#{priority_level => F@_7}
       end,
  S4 = if F@_8 == '$undef' -> S3;
         true -> S3#{durable => F@_8}
       end,
  S5 = if F@_9 == '$undef' -> S4;
         true -> S4#{start_message_id => F@_9}
       end,
  S6 = if R1 == '$undef' -> S5;
         true -> S5#{metadata => lists_reverse(R1, TrUserData)}
       end,
  S7 = if F@_11 == '$undef' -> S6;
         true -> S6#{read_compacted => F@_11}
       end,
  S8 = if F@_12 == '$undef' -> S7;
         true -> S7#{schema => F@_12}
       end,
  if F@_13 == '$undef' -> S8;
    true -> S8#{initialPosition => F@_13}
  end.

d_field_CommandSubscribe_topic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_topic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_topic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_subscription(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_subscription(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_subscription(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_subType(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_subType(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_subType(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandSubscribe.SubType'(begin
                                            <<Res:32/signed-native>> =
                                              <<(X bsl N +
                                                Acc):32/unsigned-native>>,
                                            id(Res, TrUserData)
                                          end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, _, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_consumer_name(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_consumer_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_consumer_name(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, _,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    NewFValue,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_priority_level(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_priority_level(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_priority_level(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, _, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    NewFValue,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_durable(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_durable(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_durable(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, _, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    NewFValue,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_start_message_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_start_message_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_start_message_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, Prev, F@_10, F@_11,
    F@_12, F@_13, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_MessageIdData(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_metadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_metadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_metadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, Prev, F@_11, F@_12, F@_13,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    cons(NewFValue, Prev, TrUserData),
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_read_compacted(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_read_compacted(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_read_compacted(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, _, F@_12,
    F@_13, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    NewFValue,
    F@_12,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_schema(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_schema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_schema(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, Prev, F@_13,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_Schema(Bs, TrUserData), TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_Schema(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_13,
    TrUserData).

d_field_CommandSubscribe_initialPosition(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  d_field_CommandSubscribe_initialPosition(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
d_field_CommandSubscribe_initialPosition(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, _, TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandSubscribe.InitialPosition'(begin
                                                    <<Res:32/signed-native>> =
                                                      <<(X bsl N +
                                                        Acc):32/unsigned-native>>,
                                                    id(Res, TrUserData)
                                                  end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandSubscribe(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    NewFValue,
    TrUserData).

skip_varint_CommandSubscribe(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  skip_varint_CommandSubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
skip_varint_CommandSubscribe(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    TrUserData) ->
  dfp_read_field_def_CommandSubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

skip_length_delimited_CommandSubscribe(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandSubscribe(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData);
skip_length_delimited_CommandSubscribe(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandSubscribe(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

skip_group_CommandSubscribe(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandSubscribe(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

skip_32_CommandSubscribe(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, TrUserData) ->
  dfp_read_field_def_CommandSubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

skip_64_CommandSubscribe(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, TrUserData) ->
  dfp_read_field_def_CommandSubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    TrUserData).

decode_msg_CommandPartitionedTopicMetadata(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadata(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandPartitionedTopicMetadata(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  d_field_CommandPartitionedTopicMetadata_topic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadata(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  d_field_CommandPartitionedTopicMetadata_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadata(<<26,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  d_field_CommandPartitionedTopicMetadata_original_principal(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadata(<<34,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  d_field_CommandPartitionedTopicMetadata_original_auth_data(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadata(<<42,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  d_field_CommandPartitionedTopicMetadata_original_auth_method(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadata(<<>>,
    0, 0, F@_1, F@_2, F@_3, F@_4,
    F@_5, _) ->
  S1 = #{topic => F@_1, request_id => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{original_principal => F@_3}
       end,
  S3 = if F@_4 == '$undef' -> S2;
         true -> S2#{original_auth_data => F@_4}
       end,
  if F@_5 == '$undef' -> S3;
    true -> S3#{original_auth_method => F@_5}
  end;
dfp_read_field_def_CommandPartitionedTopicMetadata(Other,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  dg_read_field_def_CommandPartitionedTopicMetadata(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

dg_read_field_def_CommandPartitionedTopicMetadata(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandPartitionedTopicMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dg_read_field_def_CommandPartitionedTopicMetadata(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandPartitionedTopicMetadata_topic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    16 ->
      d_field_CommandPartitionedTopicMetadata_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    26 ->
      d_field_CommandPartitionedTopicMetadata_original_principal(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    34 ->
      d_field_CommandPartitionedTopicMetadata_original_auth_data(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    42 ->
      d_field_CommandPartitionedTopicMetadata_original_auth_method(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandPartitionedTopicMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        1 ->
          skip_64_CommandPartitionedTopicMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        2 ->
          skip_length_delimited_CommandPartitionedTopicMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        3 ->
          skip_group_CommandPartitionedTopicMetadata(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        5 ->
          skip_32_CommandPartitionedTopicMetadata(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData)
      end
  end;
dg_read_field_def_CommandPartitionedTopicMetadata(<<>>,
    0, 0, F@_1, F@_2, F@_3, F@_4,
    F@_5, _) ->
  S1 = #{topic => F@_1, request_id => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{original_principal => F@_3}
       end,
  S3 = if F@_4 == '$undef' -> S2;
         true -> S2#{original_auth_data => F@_4}
       end,
  if F@_5 == '$undef' -> S3;
    true -> S3#{original_auth_method => F@_5}
  end.

d_field_CommandPartitionedTopicMetadata_topic(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadata_topic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadata_topic(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandPartitionedTopicMetadata(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadata_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadata_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadata_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4,
    F@_5, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandPartitionedTopicMetadata(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadata_original_principal(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadata_original_principal(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadata_original_principal(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    _, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandPartitionedTopicMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadata_original_auth_data(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadata_original_auth_data(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadata_original_auth_data(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, _, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandPartitionedTopicMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadata_original_auth_method(<<1:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadata_original_auth_method(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadata_original_auth_method(<<0:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, _,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandPartitionedTopicMetadata(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    TrUserData).

skip_varint_CommandPartitionedTopicMetadata(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  skip_varint_CommandPartitionedTopicMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_varint_CommandPartitionedTopicMetadata(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_length_delimited_CommandPartitionedTopicMetadata(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandPartitionedTopicMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_length_delimited_CommandPartitionedTopicMetadata(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandPartitionedTopicMetadata(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_group_CommandPartitionedTopicMetadata(Bin, FNum,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandPartitionedTopicMetadata(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_32_CommandPartitionedTopicMetadata(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_64_CommandPartitionedTopicMetadata(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

decode_msg_CommandPartitionedTopicMetadataResponse(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Bin,
    0,
    0,
    id('$undef',
      TrUserData),
    id('$undef',
      TrUserData),
    id('$undef',
      TrUserData),
    id('$undef',
      TrUserData),
    id('$undef',
      TrUserData),
    TrUserData).

dfp_read_field_def_CommandPartitionedTopicMetadataResponse(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  d_field_CommandPartitionedTopicMetadataResponse_partitions(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadataResponse(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  d_field_CommandPartitionedTopicMetadataResponse_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadataResponse(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  d_field_CommandPartitionedTopicMetadataResponse_response(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadataResponse(<<32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  d_field_CommandPartitionedTopicMetadataResponse_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadataResponse(<<42,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  d_field_CommandPartitionedTopicMetadataResponse_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandPartitionedTopicMetadataResponse(<<>>,
    0, 0, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    _) ->
  S1 = #{request_id => F@_2},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{partitions => F@_1}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{response => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{error => F@_4}
       end,
  if F@_5 == '$undef' -> S4;
    true -> S4#{message => F@_5}
  end;
dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Other,
    Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  dg_read_field_def_CommandPartitionedTopicMetadataResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

dg_read_field_def_CommandPartitionedTopicMetadataResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandPartitionedTopicMetadataResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dg_read_field_def_CommandPartitionedTopicMetadataResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandPartitionedTopicMetadataResponse_partitions(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    16 ->
      d_field_CommandPartitionedTopicMetadataResponse_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    24 ->
      d_field_CommandPartitionedTopicMetadataResponse_response(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    32 ->
      d_field_CommandPartitionedTopicMetadataResponse_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    42 ->
      d_field_CommandPartitionedTopicMetadataResponse_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandPartitionedTopicMetadataResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        1 ->
          skip_64_CommandPartitionedTopicMetadataResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        2 ->
          skip_length_delimited_CommandPartitionedTopicMetadataResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        3 ->
          skip_group_CommandPartitionedTopicMetadataResponse(Rest,
            Key bsr
              3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        5 ->
          skip_32_CommandPartitionedTopicMetadataResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData)
      end
  end;
dg_read_field_def_CommandPartitionedTopicMetadataResponse(<<>>,
    0, 0, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    _) ->
  S1 = #{request_id => F@_2},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{partitions => F@_1}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{response => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{error => F@_4}
       end,
  if F@_5 == '$undef' -> S4;
    true -> S4#{message => F@_5}
  end.

d_field_CommandPartitionedTopicMetadataResponse_partitions(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadataResponse_partitions(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadataResponse_partitions(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadataResponse_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadataResponse_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadataResponse_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _,
    F@_3, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadataResponse_response(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadataResponse_response(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadataResponse_response(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, _,
    F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandPartitionedTopicMetadataResponse.LookupType'(begin
                                                                      <<Res:32/signed-native>> =
                                                                        <<(X
                                                                          bsl
                                                                          N
                                                                          +
                                                                          Acc):32/unsigned-native>>,
                                                                      id(Res,
                                                                        TrUserData)
                                                                    end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadataResponse_error(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadataResponse_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadataResponse_error(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    _, F@_5, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_ServerError(begin
                                                <<Res:32/signed-native>> =
                                                  <<(X bsl N +
                                                    Acc):32/unsigned-native>>,
                                                id(Res, TrUserData)
                                              end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    TrUserData).

d_field_CommandPartitionedTopicMetadataResponse_message(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandPartitionedTopicMetadataResponse_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandPartitionedTopicMetadataResponse_message(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, _,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    TrUserData).

skip_varint_CommandPartitionedTopicMetadataResponse(<<1:1,
  _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  skip_varint_CommandPartitionedTopicMetadataResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_varint_CommandPartitionedTopicMetadataResponse(<<0:1,
  _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_length_delimited_CommandPartitionedTopicMetadataResponse(<<1:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1,
    F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandPartitionedTopicMetadataResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_length_delimited_CommandPartitionedTopicMetadataResponse(<<0:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1,
    F@_2, F@_3, F@_4,
    F@_5,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_group_CommandPartitionedTopicMetadataResponse(Bin,
    FNum, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_32_CommandPartitionedTopicMetadataResponse(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_64_CommandPartitionedTopicMetadataResponse(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  dfp_read_field_def_CommandPartitionedTopicMetadataResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

decode_msg_CommandLookupTopic(Bin, TrUserData) ->
  dfp_read_field_def_CommandLookupTopic(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandLookupTopic(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  d_field_CommandLookupTopic_topic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dfp_read_field_def_CommandLookupTopic(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  d_field_CommandLookupTopic_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dfp_read_field_def_CommandLookupTopic(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  d_field_CommandLookupTopic_authoritative(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dfp_read_field_def_CommandLookupTopic(<<34,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  d_field_CommandLookupTopic_original_principal(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dfp_read_field_def_CommandLookupTopic(<<42,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  d_field_CommandLookupTopic_original_auth_data(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dfp_read_field_def_CommandLookupTopic(<<50,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  d_field_CommandLookupTopic_original_auth_method(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dfp_read_field_def_CommandLookupTopic(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, _) ->
  S1 = #{topic => F@_1, request_id => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{authoritative => F@_3}
       end,
  S3 = if F@_4 == '$undef' -> S2;
         true -> S2#{original_principal => F@_4}
       end,
  S4 = if F@_5 == '$undef' -> S3;
         true -> S3#{original_auth_data => F@_5}
       end,
  if F@_6 == '$undef' -> S4;
    true -> S4#{original_auth_method => F@_6}
  end;
dfp_read_field_def_CommandLookupTopic(Other, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  dg_read_field_def_CommandLookupTopic(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

dg_read_field_def_CommandLookupTopic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandLookupTopic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
dg_read_field_def_CommandLookupTopic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandLookupTopic_topic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        TrUserData);
    16 ->
      d_field_CommandLookupTopic_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        TrUserData);
    24 ->
      d_field_CommandLookupTopic_authoritative(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        TrUserData);
    34 ->
      d_field_CommandLookupTopic_original_principal(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        TrUserData);
    42 ->
      d_field_CommandLookupTopic_original_auth_data(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        TrUserData);
    50 ->
      d_field_CommandLookupTopic_original_auth_method(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandLookupTopic(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            TrUserData);
        1 ->
          skip_64_CommandLookupTopic(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            TrUserData);
        2 ->
          skip_length_delimited_CommandLookupTopic(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            TrUserData);
        3 ->
          skip_group_CommandLookupTopic(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            TrUserData);
        5 ->
          skip_32_CommandLookupTopic(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            TrUserData)
      end
  end;
dg_read_field_def_CommandLookupTopic(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, _) ->
  S1 = #{topic => F@_1, request_id => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{authoritative => F@_3}
       end,
  S3 = if F@_4 == '$undef' -> S2;
         true -> S2#{original_principal => F@_4}
       end,
  S4 = if F@_5 == '$undef' -> S3;
         true -> S3#{original_auth_data => F@_5}
       end,
  if F@_6 == '$undef' -> S4;
    true -> S4#{original_auth_method => F@_6}
  end.

d_field_CommandLookupTopic_topic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopic_topic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
d_field_CommandLookupTopic_topic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopic(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

d_field_CommandLookupTopic_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopic_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
d_field_CommandLookupTopic_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandLookupTopic(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

d_field_CommandLookupTopic_authoritative(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopic_authoritative(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
d_field_CommandLookupTopic_authoritative(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5,
    F@_6, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandLookupTopic(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

d_field_CommandLookupTopic_original_principal(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopic_original_principal(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
d_field_CommandLookupTopic_original_principal(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5,
    F@_6, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopic(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    F@_6,
    TrUserData).

d_field_CommandLookupTopic_original_auth_data(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopic_original_auth_data(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
d_field_CommandLookupTopic_original_auth_data(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, _,
    F@_6, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopic(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    TrUserData).

d_field_CommandLookupTopic_original_auth_method(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopic_original_auth_method(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
d_field_CommandLookupTopic_original_auth_method(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopic(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    NewFValue,
    TrUserData).

skip_varint_CommandLookupTopic(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  skip_varint_CommandLookupTopic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
skip_varint_CommandLookupTopic(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  dfp_read_field_def_CommandLookupTopic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

skip_length_delimited_CommandLookupTopic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandLookupTopic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData);
skip_length_delimited_CommandLookupTopic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandLookupTopic(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

skip_group_CommandLookupTopic(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandLookupTopic(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

skip_32_CommandLookupTopic(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  dfp_read_field_def_CommandLookupTopic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

skip_64_CommandLookupTopic(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    TrUserData) ->
  dfp_read_field_def_CommandLookupTopic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    TrUserData).

decode_msg_CommandLookupTopicResponse(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandLookupTopicResponse(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandLookupTopicResponse(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_brokerServiceUrl(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_brokerServiceUrlTls(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_response(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<40,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_authoritative(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<48,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<58,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  d_field_CommandLookupTopicResponse_proxy_through_service_url(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dfp_read_field_def_CommandLookupTopicResponse(<<>>, 0,
    0, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, _) ->
  S1 = #{request_id => F@_4},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{brokerServiceUrl => F@_1}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{brokerServiceUrlTls => F@_2}
       end,
  S4 = if F@_3 == '$undef' -> S3;
         true -> S3#{response => F@_3}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{authoritative => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{error => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{message => F@_7}
       end,
  if F@_8 == '$undef' -> S7;
    true -> S7#{proxy_through_service_url => F@_8}
  end;
dfp_read_field_def_CommandLookupTopicResponse(Other, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, TrUserData) ->
  dg_read_field_def_CommandLookupTopicResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

dg_read_field_def_CommandLookupTopicResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandLookupTopicResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
dg_read_field_def_CommandLookupTopicResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandLookupTopicResponse_brokerServiceUrl(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    18 ->
      d_field_CommandLookupTopicResponse_brokerServiceUrlTls(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    24 ->
      d_field_CommandLookupTopicResponse_response(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    32 ->
      d_field_CommandLookupTopicResponse_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    40 ->
      d_field_CommandLookupTopicResponse_authoritative(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    48 ->
      d_field_CommandLookupTopicResponse_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    58 ->
      d_field_CommandLookupTopicResponse_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    64 ->
      d_field_CommandLookupTopicResponse_proxy_through_service_url(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandLookupTopicResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            TrUserData);
        1 ->
          skip_64_CommandLookupTopicResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            TrUserData);
        2 ->
          skip_length_delimited_CommandLookupTopicResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            TrUserData);
        3 ->
          skip_group_CommandLookupTopicResponse(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            TrUserData);
        5 ->
          skip_32_CommandLookupTopicResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            TrUserData)
      end
  end;
dg_read_field_def_CommandLookupTopicResponse(<<>>, 0, 0,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, _) ->
  S1 = #{request_id => F@_4},
  S2 = if F@_1 == '$undef' -> S1;
         true -> S1#{brokerServiceUrl => F@_1}
       end,
  S3 = if F@_2 == '$undef' -> S2;
         true -> S2#{brokerServiceUrlTls => F@_2}
       end,
  S4 = if F@_3 == '$undef' -> S3;
         true -> S3#{response => F@_3}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{authoritative => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{error => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{message => F@_7}
       end,
  if F@_8 == '$undef' -> S7;
    true -> S7#{proxy_through_service_url => F@_8}
  end.

d_field_CommandLookupTopicResponse_brokerServiceUrl(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_brokerServiceUrl(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_brokerServiceUrl(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_brokerServiceUrlTls(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_brokerServiceUrlTls(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_brokerServiceUrlTls(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_response(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_response(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_response(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5,
    F@_6, F@_7, F@_8, TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandLookupTopicResponse.LookupType'(begin
                                                         <<Res:32/signed-native>> =
                                                           <<(X bsl N +
                                                             Acc):32/unsigned-native>>,
                                                         id(Res,
                                                           TrUserData)
                                                       end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5,
    F@_6, F@_7, F@_8, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_authoritative(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_authoritative(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_authoritative(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    _, F@_6, F@_7, F@_8,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_error(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_error(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    _, F@_7, F@_8, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_ServerError(begin
                                                <<Res:32/signed-native>> =
                                                  <<(X bsl N +
                                                    Acc):32/unsigned-native>>,
                                                id(Res, TrUserData)
                                              end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    NewFValue,
    F@_7,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_message(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_message(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, _, F@_8, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    NewFValue,
    F@_8,
    TrUserData).

d_field_CommandLookupTopicResponse_proxy_through_service_url(<<1:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8,
    TrUserData)
  when N < 57 ->
  d_field_CommandLookupTopicResponse_proxy_through_service_url(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
d_field_CommandLookupTopicResponse_proxy_through_service_url(<<0:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2,
    F@_3, F@_4, F@_5,
    F@_6, F@_7, _,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandLookupTopicResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    NewFValue,
    TrUserData).

skip_varint_CommandLookupTopicResponse(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, TrUserData) ->
  skip_varint_CommandLookupTopicResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
skip_varint_CommandLookupTopicResponse(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, TrUserData) ->
  dfp_read_field_def_CommandLookupTopicResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

skip_length_delimited_CommandLookupTopicResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandLookupTopicResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData);
skip_length_delimited_CommandLookupTopicResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandLookupTopicResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

skip_group_CommandLookupTopicResponse(Bin, FNum, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandLookupTopicResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

skip_32_CommandLookupTopicResponse(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, TrUserData) ->
  dfp_read_field_def_CommandLookupTopicResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

skip_64_CommandLookupTopicResponse(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, TrUserData) ->
  dfp_read_field_def_CommandLookupTopicResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    TrUserData).

decode_msg_CommandProducer(Bin, TrUserData) ->
  dfp_read_field_def_CommandProducer(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandProducer(<<10, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_topic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<16, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_producer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<24, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<34, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_producer_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<40, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_encrypted(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<50, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_metadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<58, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  d_field_CommandProducer_schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dfp_read_field_def_CommandProducer(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, R1, F@_7,
    TrUserData) ->
  S1 = #{topic => F@_1, producer_id => F@_2,
    request_id => F@_3},
  S2 = if F@_4 == '$undef' -> S1;
         true -> S1#{producer_name => F@_4}
       end,
  S3 = if F@_5 == '$undef' -> S2;
         true -> S2#{encrypted => F@_5}
       end,
  S4 = if R1 == '$undef' -> S3;
         true -> S3#{metadata => lists_reverse(R1, TrUserData)}
       end,
  if F@_7 == '$undef' -> S4;
    true -> S4#{schema => F@_7}
  end;
dfp_read_field_def_CommandProducer(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  dg_read_field_def_CommandProducer(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

dg_read_field_def_CommandProducer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandProducer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
dg_read_field_def_CommandProducer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandProducer_topic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    16 ->
      d_field_CommandProducer_producer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    24 ->
      d_field_CommandProducer_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    34 ->
      d_field_CommandProducer_producer_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    40 ->
      d_field_CommandProducer_encrypted(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    50 ->
      d_field_CommandProducer_metadata(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    58 ->
      d_field_CommandProducer_schema(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        1 ->
          skip_64_CommandProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        2 ->
          skip_length_delimited_CommandProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        3 ->
          skip_group_CommandProducer(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData);
        5 ->
          skip_32_CommandProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            TrUserData)
      end
  end;
dg_read_field_def_CommandProducer(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, F@_5, R1, F@_7,
    TrUserData) ->
  S1 = #{topic => F@_1, producer_id => F@_2,
    request_id => F@_3},
  S2 = if F@_4 == '$undef' -> S1;
         true -> S1#{producer_name => F@_4}
       end,
  S3 = if F@_5 == '$undef' -> S2;
         true -> S2#{encrypted => F@_5}
       end,
  S4 = if R1 == '$undef' -> S3;
         true -> S3#{metadata => lists_reverse(R1, TrUserData)}
       end,
  if F@_7 == '$undef' -> S4;
    true -> S4#{schema => F@_7}
  end.

d_field_CommandProducer_topic(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData)
  when N < 57 ->
  d_field_CommandProducer_topic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_topic(<<0:1, X:7, Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_CommandProducer_producer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData)
  when N < 57 ->
  d_field_CommandProducer_producer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_producer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_CommandProducer_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData)
  when N < 57 ->
  d_field_CommandProducer_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, F@_5, F@_6,
    F@_7, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_CommandProducer_producer_name(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 57 ->
  d_field_CommandProducer_producer_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_producer_name(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5, F@_6,
    F@_7, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

d_field_CommandProducer_encrypted(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData)
  when N < 57 ->
  d_field_CommandProducer_encrypted(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_encrypted(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, _, F@_6, F@_7,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    F@_6,
    F@_7,
    TrUserData).

d_field_CommandProducer_metadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, TrUserData)
  when N < 57 ->
  d_field_CommandProducer_metadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_metadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, Prev,
    F@_7, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    cons(NewFValue, Prev, TrUserData),
    F@_7,
    TrUserData).

d_field_CommandProducer_schema(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData)
  when N < 57 ->
  d_field_CommandProducer_schema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
d_field_CommandProducer_schema(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, Prev,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_Schema(Bs, TrUserData), TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandProducer(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_Schema(Prev,
          NewFValue,
          TrUserData)
    end,
    TrUserData).

skip_varint_CommandProducer(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  skip_varint_CommandProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
skip_varint_CommandProducer(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    TrUserData) ->
  dfp_read_field_def_CommandProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_length_delimited_CommandProducer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandProducer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData);
skip_length_delimited_CommandProducer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandProducer(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_group_CommandProducer(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandProducer(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_32_CommandProducer(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, TrUserData) ->
  dfp_read_field_def_CommandProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

skip_64_CommandProducer(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, TrUserData) ->
  dfp_read_field_def_CommandProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    TrUserData).

decode_msg_CommandSend(Bin, TrUserData) ->
  dfp_read_field_def_CommandSend(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandSend(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandSend_producer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandSend(<<16, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandSend_sequence_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandSend(<<24, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandSend_num_messages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandSend(<<>>, 0, 0, F@_1, F@_2,
    F@_3, _) ->
  S1 = #{producer_id => F@_1, sequence_id => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{num_messages => F@_3}
  end;
dfp_read_field_def_CommandSend(Other, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandSend(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandSend(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandSend(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandSend(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandSend_producer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    16 ->
      d_field_CommandSend_sequence_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    24 ->
      d_field_CommandSend_num_messages(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandSend(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandSend(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandSend(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandSend(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandSend(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandSend(<<>>, 0, 0, F@_1, F@_2,
    F@_3, _) ->
  S1 = #{producer_id => F@_1, sequence_id => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{num_messages => F@_3}
  end.

d_field_CommandSend_producer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandSend_producer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandSend_producer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSend(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandSend_sequence_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandSend_sequence_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandSend_sequence_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSend(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    TrUserData).

d_field_CommandSend_num_messages(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandSend_num_messages(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandSend_num_messages(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:32/signed-native>> = <<(X bsl N +
                            Acc):32/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandSend(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandSend(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandSend(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandSend(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandSend(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandSend(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandSend(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandSend(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandSend(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandSend(Bin, FNum, Z2, F@_1, F@_2, F@_3,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandSend(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandSend(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandSend(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandSend(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandSend(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandSendReceipt(Bin, TrUserData) ->
  dfp_read_field_def_CommandSendReceipt(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandSendReceipt(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandSendReceipt_producer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandSendReceipt(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandSendReceipt_sequence_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandSendReceipt(<<26,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandSendReceipt_message_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandSendReceipt(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{producer_id => F@_1, sequence_id => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{message_id => F@_3}
  end;
dfp_read_field_def_CommandSendReceipt(Other, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandSendReceipt(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandSendReceipt(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandSendReceipt(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandSendReceipt(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandSendReceipt_producer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    16 ->
      d_field_CommandSendReceipt_sequence_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    26 ->
      d_field_CommandSendReceipt_message_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandSendReceipt(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandSendReceipt(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandSendReceipt(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandSendReceipt(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandSendReceipt(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandSendReceipt(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{producer_id => F@_1, sequence_id => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{message_id => F@_3}
  end.

d_field_CommandSendReceipt_producer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandSendReceipt_producer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandSendReceipt_producer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSendReceipt(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandSendReceipt_sequence_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandSendReceipt_sequence_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandSendReceipt_sequence_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSendReceipt(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    TrUserData).

d_field_CommandSendReceipt_message_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandSendReceipt_message_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandSendReceipt_message_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, Prev, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandSendReceipt(RestF,
    0,
    0,
    F@_1,
    F@_2,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_MessageIdData(Prev,
          NewFValue,
          TrUserData)
    end,
    TrUserData).

skip_varint_CommandSendReceipt(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandSendReceipt(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandSendReceipt(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandSendReceipt(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandSendReceipt(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandSendReceipt(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandSendReceipt(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandSendReceipt(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandSendReceipt(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandSendReceipt(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandSendReceipt(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandSendReceipt(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandSendReceipt(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandSendReceipt(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandSendError(Bin, TrUserData) ->
  dfp_read_field_def_CommandSendError(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandSendError(<<8, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandSendError_producer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSendError(<<16, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandSendError_sequence_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSendError(<<24, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandSendError_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSendError(<<34, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandSendError_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSendError(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, _) ->
  #{producer_id => F@_1, sequence_id => F@_2,
    error => F@_3, message => F@_4};
dfp_read_field_def_CommandSendError(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dg_read_field_def_CommandSendError(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

dg_read_field_def_CommandSendError(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandSendError(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dg_read_field_def_CommandSendError(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandSendError_producer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    16 ->
      d_field_CommandSendError_sequence_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    24 ->
      d_field_CommandSendError_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    34 ->
      d_field_CommandSendError_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandSendError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        1 ->
          skip_64_CommandSendError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        2 ->
          skip_length_delimited_CommandSendError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        3 ->
          skip_group_CommandSendError(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        5 ->
          skip_32_CommandSendError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData)
      end
  end;
dg_read_field_def_CommandSendError(<<>>, 0, 0, F@_1,
    F@_2, F@_3, F@_4, _) ->
  #{producer_id => F@_1, sequence_id => F@_2,
    error => F@_3, message => F@_4}.

d_field_CommandSendError_producer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSendError_producer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSendError_producer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSendError(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

d_field_CommandSendError_sequence_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSendError_sequence_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSendError_sequence_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSendError(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    TrUserData).

d_field_CommandSendError_error(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSendError_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSendError_error(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_ServerError(begin
                                                <<Res:32/signed-native>> =
                                                  <<(X bsl N +
                                                    Acc):32/unsigned-native>>,
                                                id(Res, TrUserData)
                                              end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandSendError(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    TrUserData).

d_field_CommandSendError_message(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSendError_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSendError_message(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandSendError(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    TrUserData).

skip_varint_CommandSendError(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  skip_varint_CommandSendError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_varint_CommandSendError(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandSendError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_length_delimited_CommandSendError(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandSendError(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_length_delimited_CommandSendError(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandSendError(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_group_CommandSendError(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, F@_4, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandSendError(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_32_CommandSendError(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandSendError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_64_CommandSendError(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandSendError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

decode_msg_CommandMessage(Bin, TrUserData) ->
  dfp_read_field_def_CommandMessage(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandMessage(<<8, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandMessage_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandMessage(<<18, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandMessage_message_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandMessage(<<24, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandMessage_redelivery_count(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandMessage(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{consumer_id => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{message_id => F@_2}
       end,
  if F@_3 == '$undef' -> S2;
    true -> S2#{redelivery_count => F@_3}
  end;
dfp_read_field_def_CommandMessage(Other, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandMessage(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandMessage(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandMessage(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandMessage(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandMessage_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    18 ->
      d_field_CommandMessage_message_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    24 ->
      d_field_CommandMessage_redelivery_count(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandMessage(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandMessage(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandMessage(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandMessage(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandMessage(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandMessage(<<>>, 0, 0, F@_1, F@_2,
    F@_3, _) ->
  S1 = #{consumer_id => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{message_id => F@_2}
       end,
  if F@_3 == '$undef' -> S2;
    true -> S2#{redelivery_count => F@_3}
  end.

d_field_CommandMessage_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandMessage_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandMessage_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandMessage(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandMessage_message_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandMessage_message_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandMessage_message_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, Prev, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandMessage(RestF,
    0,
    0,
    F@_1,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_MessageIdData(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_3,
    TrUserData).

d_field_CommandMessage_redelivery_count(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandMessage_redelivery_count(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandMessage_redelivery_count(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandMessage(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandMessage(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandMessage(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandMessage(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandMessage(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandMessage(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandMessage(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandMessage(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandMessage(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandMessage(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandMessage(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandMessage(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandMessage(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandMessage(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandMessage(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandAck(Bin, TrUserData) ->
  dfp_read_field_def_CommandAck(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    id('$undef', TrUserData),
    id([], TrUserData),
    TrUserData).

dfp_read_field_def_CommandAck(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  d_field_CommandAck_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandAck(<<16, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  d_field_CommandAck_ack_type(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandAck(<<26, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  d_field_CommandAck_message_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandAck(<<32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  d_field_CommandAck_validation_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandAck(<<42, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  d_field_CommandAck_properties(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandAck(<<>>, 0, 0, F@_1, F@_2,
    R1, F@_4, R2, TrUserData) ->
  S1 = #{consumer_id => F@_1, ack_type => F@_2},
  S2 = if R1 == '$undef' -> S1;
         true -> S1#{message_id => lists_reverse(R1, TrUserData)}
       end,
  S3 = if F@_4 == '$undef' -> S2;
         true -> S2#{validation_error => F@_4}
       end,
  if R2 == '$undef' -> S3;
    true -> S3#{properties => lists_reverse(R2, TrUserData)}
  end;
dfp_read_field_def_CommandAck(Other, Z1, Z2, F@_1, F@_2,
    F@_3, F@_4, F@_5, TrUserData) ->
  dg_read_field_def_CommandAck(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

dg_read_field_def_CommandAck(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandAck(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dg_read_field_def_CommandAck(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandAck_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    16 ->
      d_field_CommandAck_ack_type(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    26 ->
      d_field_CommandAck_message_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    32 ->
      d_field_CommandAck_validation_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    42 ->
      d_field_CommandAck_properties(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandAck(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        1 ->
          skip_64_CommandAck(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        2 ->
          skip_length_delimited_CommandAck(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        3 ->
          skip_group_CommandAck(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        5 ->
          skip_32_CommandAck(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData)
      end
  end;
dg_read_field_def_CommandAck(<<>>, 0, 0, F@_1, F@_2, R1,
    F@_4, R2, TrUserData) ->
  S1 = #{consumer_id => F@_1, ack_type => F@_2},
  S2 = if R1 == '$undef' -> S1;
         true -> S1#{message_id => lists_reverse(R1, TrUserData)}
       end,
  S3 = if F@_4 == '$undef' -> S2;
         true -> S2#{validation_error => F@_4}
       end,
  if R2 == '$undef' -> S3;
    true -> S3#{properties => lists_reverse(R2, TrUserData)}
  end.

d_field_CommandAck_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandAck_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandAck_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandAck(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandAck_ack_type(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandAck_ack_type(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandAck_ack_type(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5, TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandAck.AckType'(begin
                                      <<Res:32/signed-native>> = <<(X bsl
                                        N
                                        +
                                        Acc):32/unsigned-native>>,
                                      id(Res, TrUserData)
                                    end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandAck(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandAck_message_id(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandAck_message_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandAck_message_id(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, Prev, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandAck(RestF,
    0,
    0,
    F@_1,
    F@_2,
    cons(NewFValue, Prev, TrUserData),
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandAck_validation_error(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandAck_validation_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandAck_validation_error(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _, F@_5,
    TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandAck.ValidationError'(begin
                                              <<Res:32/signed-native>> =
                                                <<(X bsl N +
                                                  Acc):32/unsigned-native>>,
                                              id(Res, TrUserData)
                                            end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandAck(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    F@_5,
    TrUserData).

d_field_CommandAck_properties(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandAck_properties(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandAck_properties(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, Prev,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_KeyLongValue(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandAck(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    cons(NewFValue, Prev, TrUserData),
    TrUserData).

skip_varint_CommandAck(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  skip_varint_CommandAck(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_varint_CommandAck(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  dfp_read_field_def_CommandAck(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_length_delimited_CommandAck(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandAck(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_length_delimited_CommandAck(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandAck(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_group_CommandAck(Bin, FNum, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandAck(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_32_CommandAck(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  dfp_read_field_def_CommandAck(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_64_CommandAck(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  dfp_read_field_def_CommandAck(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

decode_msg_CommandActiveConsumerChange(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandActiveConsumerChange(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandActiveConsumerChange(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandActiveConsumerChange_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandActiveConsumerChange(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandActiveConsumerChange_is_active(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandActiveConsumerChange(<<>>, 0,
    0, F@_1, F@_2, _) ->
  S1 = #{consumer_id => F@_1},
  if F@_2 == '$undef' -> S1;
    true -> S1#{is_active => F@_2}
  end;
dfp_read_field_def_CommandActiveConsumerChange(Other,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dg_read_field_def_CommandActiveConsumerChange(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandActiveConsumerChange(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandActiveConsumerChange(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandActiveConsumerChange(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandActiveConsumerChange_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandActiveConsumerChange_is_active(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandActiveConsumerChange(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandActiveConsumerChange(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandActiveConsumerChange(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandActiveConsumerChange(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandActiveConsumerChange(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandActiveConsumerChange(<<>>, 0,
    0, F@_1, F@_2, _) ->
  S1 = #{consumer_id => F@_1},
  if F@_2 == '$undef' -> S1;
    true -> S1#{is_active => F@_2}
  end.

d_field_CommandActiveConsumerChange_consumer_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandActiveConsumerChange_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandActiveConsumerChange_consumer_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandActiveConsumerChange(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandActiveConsumerChange_is_active(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandActiveConsumerChange_is_active(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandActiveConsumerChange_is_active(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandActiveConsumerChange(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandActiveConsumerChange(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandActiveConsumerChange(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandActiveConsumerChange(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandActiveConsumerChange(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandActiveConsumerChange(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandActiveConsumerChange(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandActiveConsumerChange(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandActiveConsumerChange(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandActiveConsumerChange(Bin, FNum, Z2,
    F@_1, F@_2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandActiveConsumerChange(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandActiveConsumerChange(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandActiveConsumerChange(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandActiveConsumerChange(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandActiveConsumerChange(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandFlow(Bin, TrUserData) ->
  dfp_read_field_def_CommandFlow(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandFlow(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandFlow_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandFlow(<<16, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandFlow_messagePermits(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandFlow(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  #{consumer_id => F@_1, messagePermits => F@_2};
dfp_read_field_def_CommandFlow(Other, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dg_read_field_def_CommandFlow(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandFlow(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandFlow(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandFlow(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandFlow_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandFlow_messagePermits(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandFlow(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandFlow(Rest, 0, 0, F@_1, F@_2, TrUserData);
        2 ->
          skip_length_delimited_CommandFlow(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandFlow(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandFlow(Rest, 0, 0, F@_1, F@_2, TrUserData)
      end
  end;
dg_read_field_def_CommandFlow(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  #{consumer_id => F@_1, messagePermits => F@_2}.

d_field_CommandFlow_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandFlow_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandFlow_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandFlow(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandFlow_messagePermits(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandFlow_messagePermits(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandFlow_messagePermits(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandFlow(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandFlow(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandFlow(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandFlow(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandFlow(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandFlow(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandFlow(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandFlow(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandFlow(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandFlow(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandFlow(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandFlow(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dfp_read_field_def_CommandFlow(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandFlow(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dfp_read_field_def_CommandFlow(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandUnsubscribe(Bin, TrUserData) ->
  dfp_read_field_def_CommandUnsubscribe(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandUnsubscribe(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandUnsubscribe_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandUnsubscribe(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandUnsubscribe_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandUnsubscribe(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  #{consumer_id => F@_1, request_id => F@_2};
dfp_read_field_def_CommandUnsubscribe(Other, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dg_read_field_def_CommandUnsubscribe(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandUnsubscribe(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandUnsubscribe(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandUnsubscribe(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandUnsubscribe_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandUnsubscribe_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandUnsubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandUnsubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandUnsubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandUnsubscribe(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandUnsubscribe(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandUnsubscribe(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  #{consumer_id => F@_1, request_id => F@_2}.

d_field_CommandUnsubscribe_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandUnsubscribe_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandUnsubscribe_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandUnsubscribe(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandUnsubscribe_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandUnsubscribe_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandUnsubscribe_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandUnsubscribe(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandUnsubscribe(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandUnsubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandUnsubscribe(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandUnsubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandUnsubscribe(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandUnsubscribe(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandUnsubscribe(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandUnsubscribe(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandUnsubscribe(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandUnsubscribe(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandUnsubscribe(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandUnsubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandUnsubscribe(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandUnsubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandSeek(Bin, TrUserData) ->
  dfp_read_field_def_CommandSeek(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandSeek(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_CommandSeek_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSeek(<<16, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_CommandSeek_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSeek(<<26, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_CommandSeek_message_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSeek(<<32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  d_field_CommandSeek_message_publish_time(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandSeek(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, _) ->
  S1 = #{consumer_id => F@_1, request_id => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{message_id => F@_3}
       end,
  if F@_4 == '$undef' -> S2;
    true -> S2#{message_publish_time => F@_4}
  end;
dfp_read_field_def_CommandSeek(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dg_read_field_def_CommandSeek(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

dg_read_field_def_CommandSeek(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandSeek(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dg_read_field_def_CommandSeek(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandSeek_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    16 ->
      d_field_CommandSeek_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    26 ->
      d_field_CommandSeek_message_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    32 ->
      d_field_CommandSeek_message_publish_time(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandSeek(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        1 ->
          skip_64_CommandSeek(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        2 ->
          skip_length_delimited_CommandSeek(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        3 ->
          skip_group_CommandSeek(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        5 ->
          skip_32_CommandSeek(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData)
      end
  end;
dg_read_field_def_CommandSeek(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, _) ->
  S1 = #{consumer_id => F@_1, request_id => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{message_id => F@_3}
       end,
  if F@_4 == '$undef' -> S2;
    true -> S2#{message_publish_time => F@_4}
  end.

d_field_CommandSeek_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSeek_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSeek_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSeek(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

d_field_CommandSeek_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSeek_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSeek_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSeek(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    TrUserData).

d_field_CommandSeek_message_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  d_field_CommandSeek_message_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSeek_message_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, Prev, F@_4, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandSeek(RestF,
    0,
    0,
    F@_1,
    F@_2,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_MessageIdData(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_4,
    TrUserData).

d_field_CommandSeek_message_publish_time(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  d_field_CommandSeek_message_publish_time(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandSeek_message_publish_time(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSeek(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    TrUserData).

skip_varint_CommandSeek(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  skip_varint_CommandSeek(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_varint_CommandSeek(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandSeek(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_length_delimited_CommandSeek(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandSeek(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_length_delimited_CommandSeek(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandSeek(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_group_CommandSeek(Bin, FNum, Z2, F@_1, F@_2, F@_3,
    F@_4, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandSeek(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_32_CommandSeek(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandSeek(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_64_CommandSeek(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandSeek(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

decode_msg_CommandReachedEndOfTopic(Bin, TrUserData) ->
  dfp_read_field_def_CommandReachedEndOfTopic(Bin,
    0,
    0,
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandReachedEndOfTopic(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, TrUserData) ->
  d_field_CommandReachedEndOfTopic_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    TrUserData);
dfp_read_field_def_CommandReachedEndOfTopic(<<>>, 0, 0,
    F@_1, _) ->
  #{consumer_id => F@_1};
dfp_read_field_def_CommandReachedEndOfTopic(Other, Z1,
    Z2, F@_1, TrUserData) ->
  dg_read_field_def_CommandReachedEndOfTopic(Other,
    Z1,
    Z2,
    F@_1,
    TrUserData).

dg_read_field_def_CommandReachedEndOfTopic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandReachedEndOfTopic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    TrUserData);
dg_read_field_def_CommandReachedEndOfTopic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandReachedEndOfTopic_consumer_id(Rest,
        0,
        0,
        F@_1,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandReachedEndOfTopic(Rest,
            0,
            0,
            F@_1,
            TrUserData);
        1 ->
          skip_64_CommandReachedEndOfTopic(Rest,
            0,
            0,
            F@_1,
            TrUserData);
        2 ->
          skip_length_delimited_CommandReachedEndOfTopic(Rest,
            0,
            0,
            F@_1,
            TrUserData);
        3 ->
          skip_group_CommandReachedEndOfTopic(Rest,
            Key bsr 3,
            0,
            F@_1,
            TrUserData);
        5 ->
          skip_32_CommandReachedEndOfTopic(Rest,
            0,
            0,
            F@_1,
            TrUserData)
      end
  end;
dg_read_field_def_CommandReachedEndOfTopic(<<>>, 0, 0,
    F@_1, _) ->
  #{consumer_id => F@_1}.

d_field_CommandReachedEndOfTopic_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, TrUserData)
  when N < 57 ->
  d_field_CommandReachedEndOfTopic_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    TrUserData);
d_field_CommandReachedEndOfTopic_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandReachedEndOfTopic(RestF,
    0,
    0,
    NewFValue,
    TrUserData).

skip_varint_CommandReachedEndOfTopic(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, TrUserData) ->
  skip_varint_CommandReachedEndOfTopic(Rest,
    Z1,
    Z2,
    F@_1,
    TrUserData);
skip_varint_CommandReachedEndOfTopic(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, TrUserData) ->
  dfp_read_field_def_CommandReachedEndOfTopic(Rest,
    Z1,
    Z2,
    F@_1,
    TrUserData).

skip_length_delimited_CommandReachedEndOfTopic(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandReachedEndOfTopic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    TrUserData);
skip_length_delimited_CommandReachedEndOfTopic(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandReachedEndOfTopic(Rest2,
    0,
    0,
    F@_1,
    TrUserData).

skip_group_CommandReachedEndOfTopic(Bin, FNum, Z2, F@_1,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandReachedEndOfTopic(Rest,
    0,
    Z2,
    F@_1,
    TrUserData).

skip_32_CommandReachedEndOfTopic(<<_:32, Rest/binary>>,
    Z1, Z2, F@_1, TrUserData) ->
  dfp_read_field_def_CommandReachedEndOfTopic(Rest,
    Z1,
    Z2,
    F@_1,
    TrUserData).

skip_64_CommandReachedEndOfTopic(<<_:64, Rest/binary>>,
    Z1, Z2, F@_1, TrUserData) ->
  dfp_read_field_def_CommandReachedEndOfTopic(Rest,
    Z1,
    Z2,
    F@_1,
    TrUserData).

decode_msg_CommandCloseProducer(Bin, TrUserData) ->
  dfp_read_field_def_CommandCloseProducer(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandCloseProducer(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandCloseProducer_producer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandCloseProducer(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandCloseProducer_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandCloseProducer(<<>>, 0, 0,
    F@_1, F@_2, _) ->
  #{producer_id => F@_1, request_id => F@_2};
dfp_read_field_def_CommandCloseProducer(Other, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dg_read_field_def_CommandCloseProducer(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandCloseProducer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandCloseProducer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandCloseProducer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandCloseProducer_producer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandCloseProducer_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandCloseProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandCloseProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandCloseProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandCloseProducer(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandCloseProducer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandCloseProducer(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  #{producer_id => F@_1, request_id => F@_2}.

d_field_CommandCloseProducer_producer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandCloseProducer_producer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandCloseProducer_producer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandCloseProducer(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandCloseProducer_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandCloseProducer_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandCloseProducer_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandCloseProducer(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandCloseProducer(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandCloseProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandCloseProducer(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandCloseProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandCloseProducer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandCloseProducer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandCloseProducer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandCloseProducer(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandCloseProducer(Bin, FNum, Z2, F@_1,
    F@_2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandCloseProducer(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandCloseProducer(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandCloseProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandCloseProducer(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandCloseProducer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandCloseConsumer(Bin, TrUserData) ->
  dfp_read_field_def_CommandCloseConsumer(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandCloseConsumer(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandCloseConsumer_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandCloseConsumer(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandCloseConsumer_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandCloseConsumer(<<>>, 0, 0,
    F@_1, F@_2, _) ->
  #{consumer_id => F@_1, request_id => F@_2};
dfp_read_field_def_CommandCloseConsumer(Other, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dg_read_field_def_CommandCloseConsumer(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandCloseConsumer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandCloseConsumer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandCloseConsumer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandCloseConsumer_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandCloseConsumer_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandCloseConsumer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandCloseConsumer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandCloseConsumer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandCloseConsumer(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandCloseConsumer(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandCloseConsumer(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  #{consumer_id => F@_1, request_id => F@_2}.

d_field_CommandCloseConsumer_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandCloseConsumer_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandCloseConsumer_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandCloseConsumer(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandCloseConsumer_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandCloseConsumer_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandCloseConsumer_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandCloseConsumer(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandCloseConsumer(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandCloseConsumer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandCloseConsumer(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandCloseConsumer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandCloseConsumer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandCloseConsumer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandCloseConsumer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandCloseConsumer(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandCloseConsumer(Bin, FNum, Z2, F@_1,
    F@_2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandCloseConsumer(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandCloseConsumer(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandCloseConsumer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandCloseConsumer(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandCloseConsumer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandRedeliverUnacknowledgedMessages(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Bin,
    0,
    0,
    id('$undef',
      TrUserData),
    id([],
      TrUserData),
    TrUserData).

dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandRedeliverUnacknowledgedMessages_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandRedeliverUnacknowledgedMessages_message_ids(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(<<>>,
    0, 0, F@_1, R1,
    TrUserData) ->
  S1 = #{consumer_id => F@_1},
  if R1 == '$undef' -> S1;
    true ->
      S1#{message_ids => lists_reverse(R1, TrUserData)}
  end;
dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Other,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dg_read_field_def_CommandRedeliverUnacknowledgedMessages(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandRedeliverUnacknowledgedMessages(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandRedeliverUnacknowledgedMessages(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandRedeliverUnacknowledgedMessages(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandRedeliverUnacknowledgedMessages_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    18 ->
      d_field_CommandRedeliverUnacknowledgedMessages_message_ids(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandRedeliverUnacknowledgedMessages(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandRedeliverUnacknowledgedMessages(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandRedeliverUnacknowledgedMessages(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandRedeliverUnacknowledgedMessages(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandRedeliverUnacknowledgedMessages(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandRedeliverUnacknowledgedMessages(<<>>,
    0, 0, F@_1, R1,
    TrUserData) ->
  S1 = #{consumer_id => F@_1},
  if R1 == '$undef' -> S1;
    true ->
      S1#{message_ids => lists_reverse(R1, TrUserData)}
  end.

d_field_CommandRedeliverUnacknowledgedMessages_consumer_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  d_field_CommandRedeliverUnacknowledgedMessages_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandRedeliverUnacknowledgedMessages_consumer_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandRedeliverUnacknowledgedMessages_message_ids(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  d_field_CommandRedeliverUnacknowledgedMessages_message_ids(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandRedeliverUnacknowledgedMessages_message_ids(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, Prev,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(RestF,
    0,
    0,
    F@_1,
    cons(NewFValue,
      Prev,
      TrUserData),
    TrUserData).

skip_varint_CommandRedeliverUnacknowledgedMessages(<<1:1,
  _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  skip_varint_CommandRedeliverUnacknowledgedMessages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandRedeliverUnacknowledgedMessages(<<0:1,
  _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandRedeliverUnacknowledgedMessages(<<1:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandRedeliverUnacknowledgedMessages(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandRedeliverUnacknowledgedMessages(<<0:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandRedeliverUnacknowledgedMessages(Bin,
    FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandRedeliverUnacknowledgedMessages(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandRedeliverUnacknowledgedMessages(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dfp_read_field_def_CommandRedeliverUnacknowledgedMessages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandSuccess(Bin, TrUserData) ->
  dfp_read_field_def_CommandSuccess(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandSuccess(<<8, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandSuccess_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandSuccess(<<18, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandSuccess_schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandSuccess(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  S1 = #{request_id => F@_1},
  if F@_2 == '$undef' -> S1;
    true -> S1#{schema => F@_2}
  end;
dfp_read_field_def_CommandSuccess(Other, Z1, Z2, F@_1,
    F@_2, TrUserData) ->
  dg_read_field_def_CommandSuccess(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandSuccess(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandSuccess(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandSuccess(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandSuccess_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    18 ->
      d_field_CommandSuccess_schema(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandSuccess(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandSuccess(<<>>, 0, 0, F@_1, F@_2,
    _) ->
  S1 = #{request_id => F@_1},
  if F@_2 == '$undef' -> S1;
    true -> S1#{schema => F@_2}
  end.

d_field_CommandSuccess_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandSuccess_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandSuccess_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandSuccess(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandSuccess_schema(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandSuccess_schema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandSuccess_schema(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, Prev, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_Schema(Bs, TrUserData), TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandSuccess(RestF,
    0,
    0,
    F@_1,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_Schema(Prev,
          NewFValue,
          TrUserData)
    end,
    TrUserData).

skip_varint_CommandSuccess(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandSuccess(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandSuccess(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandSuccess(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandSuccess(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandSuccess(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandSuccess(Bin, FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandSuccess(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandSuccess(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandSuccess(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandProducerSuccess(Bin, TrUserData) ->
  dfp_read_field_def_CommandProducerSuccess(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandProducerSuccess(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandProducerSuccess_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandProducerSuccess(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandProducerSuccess_producer_name(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandProducerSuccess(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandProducerSuccess_last_sequence_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandProducerSuccess(<<34,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  d_field_CommandProducerSuccess_schema_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dfp_read_field_def_CommandProducerSuccess(<<>>, 0, 0,
    F@_1, F@_2, F@_3, F@_4, _) ->
  S1 = #{request_id => F@_1, producer_name => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{last_sequence_id => F@_3}
       end,
  if F@_4 == '$undef' -> S2;
    true -> S2#{schema_version => F@_4}
  end;
dfp_read_field_def_CommandProducerSuccess(Other, Z1, Z2,
    F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dg_read_field_def_CommandProducerSuccess(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

dg_read_field_def_CommandProducerSuccess(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandProducerSuccess(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
dg_read_field_def_CommandProducerSuccess(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandProducerSuccess_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    18 ->
      d_field_CommandProducerSuccess_producer_name(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    24 ->
      d_field_CommandProducerSuccess_last_sequence_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    34 ->
      d_field_CommandProducerSuccess_schema_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandProducerSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        1 ->
          skip_64_CommandProducerSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        2 ->
          skip_length_delimited_CommandProducerSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        3 ->
          skip_group_CommandProducerSuccess(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData);
        5 ->
          skip_32_CommandProducerSuccess(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            TrUserData)
      end
  end;
dg_read_field_def_CommandProducerSuccess(<<>>, 0, 0,
    F@_1, F@_2, F@_3, F@_4, _) ->
  S1 = #{request_id => F@_1, producer_name => F@_2},
  S2 = if F@_3 == '$undef' -> S1;
         true -> S1#{last_sequence_id => F@_3}
       end,
  if F@_4 == '$undef' -> S2;
    true -> S2#{schema_version => F@_4}
  end.

d_field_CommandProducerSuccess_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  d_field_CommandProducerSuccess_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandProducerSuccess_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandProducerSuccess(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

d_field_CommandProducerSuccess_producer_name(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  d_field_CommandProducerSuccess_producer_name(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandProducerSuccess_producer_name(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandProducerSuccess(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    TrUserData).

d_field_CommandProducerSuccess_last_sequence_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  d_field_CommandProducerSuccess_last_sequence_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandProducerSuccess_last_sequence_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4,
    TrUserData) ->
  {NewFValue, RestF} = {begin
                          <<Res:64/signed-native>> = <<(X bsl N +
                            Acc):64/unsigned-native>>,
                          id(Res, TrUserData)
                        end,
    Rest},
  dfp_read_field_def_CommandProducerSuccess(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    TrUserData).

d_field_CommandProducerSuccess_schema_version(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  d_field_CommandProducerSuccess_schema_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
d_field_CommandProducerSuccess_schema_version(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, _,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandProducerSuccess(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    NewFValue,
    TrUserData).

skip_varint_CommandProducerSuccess(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  skip_varint_CommandProducerSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_varint_CommandProducerSuccess(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  dfp_read_field_def_CommandProducerSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_length_delimited_CommandProducerSuccess(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandProducerSuccess(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData);
skip_length_delimited_CommandProducerSuccess(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandProducerSuccess(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_group_CommandProducerSuccess(Bin, FNum, Z2, F@_1,
    F@_2, F@_3, F@_4, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandProducerSuccess(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_32_CommandProducerSuccess(<<_:32, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandProducerSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

skip_64_CommandProducerSuccess(<<_:64, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, TrUserData) ->
  dfp_read_field_def_CommandProducerSuccess(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    TrUserData).

decode_msg_CommandError(Bin, TrUserData) ->
  dfp_read_field_def_CommandError(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandError(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandError_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandError(<<16, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandError_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandError(<<26, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandError_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandError(<<>>, 0, 0, F@_1, F@_2,
    F@_3, _) ->
  #{request_id => F@_1, error => F@_2, message => F@_3};
dfp_read_field_def_CommandError(Other, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandError(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandError(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandError(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandError(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandError_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    16 ->
      d_field_CommandError_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    26 ->
      d_field_CommandError_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandError(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandError(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandError(<<>>, 0, 0, F@_1, F@_2,
    F@_3, _) ->
  #{request_id => F@_1, error => F@_2, message => F@_3}.

d_field_CommandError_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandError_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandError_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandError(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandError_error(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandError_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandError_error(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, _, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_ServerError(begin
                                                <<Res:32/signed-native>> =
                                                  <<(X bsl N +
                                                    Acc):32/unsigned-native>>,
                                                id(Res, TrUserData)
                                              end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandError(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    TrUserData).

d_field_CommandError_message(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandError_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandError_message(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandError(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandError(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandError(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandError(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandError(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandError(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandError(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandError(Bin, FNum, Z2, F@_1, F@_2, F@_3,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandError(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandError(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandError(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandError(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandPing(Bin, TrUserData) ->
  dfp_read_field_def_CommandPing(Bin, 0, 0, TrUserData).

dfp_read_field_def_CommandPing(<<>>, 0, 0, _) -> #{};
dfp_read_field_def_CommandPing(Other, Z1, Z2,
    TrUserData) ->
  dg_read_field_def_CommandPing(Other,
    Z1,
    Z2,
    TrUserData).

dg_read_field_def_CommandPing(<<1:1, X:7, Rest/binary>>,
    N, Acc, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandPing(Rest,
    N + 7,
    X bsl N + Acc,
    TrUserData);
dg_read_field_def_CommandPing(<<0:1, X:7, Rest/binary>>,
    N, Acc, TrUserData) ->
  Key = X bsl N + Acc,
  case Key band 7 of
    0 -> skip_varint_CommandPing(Rest, 0, 0, TrUserData);
    1 -> skip_64_CommandPing(Rest, 0, 0, TrUserData);
    2 ->
      skip_length_delimited_CommandPing(Rest,
        0,
        0,
        TrUserData);
    3 ->
      skip_group_CommandPing(Rest, Key bsr 3, 0, TrUserData);
    5 -> skip_32_CommandPing(Rest, 0, 0, TrUserData)
  end;
dg_read_field_def_CommandPing(<<>>, 0, 0, _) -> #{}.

skip_varint_CommandPing(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, TrUserData) ->
  skip_varint_CommandPing(Rest, Z1, Z2, TrUserData);
skip_varint_CommandPing(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, TrUserData) ->
  dfp_read_field_def_CommandPing(Rest,
    Z1,
    Z2,
    TrUserData).

skip_length_delimited_CommandPing(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandPing(Rest,
    N + 7,
    X bsl N + Acc,
    TrUserData);
skip_length_delimited_CommandPing(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandPing(Rest2, 0, 0, TrUserData).

skip_group_CommandPing(Bin, FNum, Z2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandPing(Rest, 0, Z2, TrUserData).

skip_32_CommandPing(<<_:32, Rest/binary>>, Z1, Z2,
    TrUserData) ->
  dfp_read_field_def_CommandPing(Rest,
    Z1,
    Z2,
    TrUserData).

skip_64_CommandPing(<<_:64, Rest/binary>>, Z1, Z2,
    TrUserData) ->
  dfp_read_field_def_CommandPing(Rest,
    Z1,
    Z2,
    TrUserData).

decode_msg_CommandPong(Bin, TrUserData) ->
  dfp_read_field_def_CommandPong(Bin, 0, 0, TrUserData).

dfp_read_field_def_CommandPong(<<>>, 0, 0, _) -> #{};
dfp_read_field_def_CommandPong(Other, Z1, Z2,
    TrUserData) ->
  dg_read_field_def_CommandPong(Other,
    Z1,
    Z2,
    TrUserData).

dg_read_field_def_CommandPong(<<1:1, X:7, Rest/binary>>,
    N, Acc, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandPong(Rest,
    N + 7,
    X bsl N + Acc,
    TrUserData);
dg_read_field_def_CommandPong(<<0:1, X:7, Rest/binary>>,
    N, Acc, TrUserData) ->
  Key = X bsl N + Acc,
  case Key band 7 of
    0 -> skip_varint_CommandPong(Rest, 0, 0, TrUserData);
    1 -> skip_64_CommandPong(Rest, 0, 0, TrUserData);
    2 ->
      skip_length_delimited_CommandPong(Rest,
        0,
        0,
        TrUserData);
    3 ->
      skip_group_CommandPong(Rest, Key bsr 3, 0, TrUserData);
    5 -> skip_32_CommandPong(Rest, 0, 0, TrUserData)
  end;
dg_read_field_def_CommandPong(<<>>, 0, 0, _) -> #{}.

skip_varint_CommandPong(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, TrUserData) ->
  skip_varint_CommandPong(Rest, Z1, Z2, TrUserData);
skip_varint_CommandPong(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, TrUserData) ->
  dfp_read_field_def_CommandPong(Rest,
    Z1,
    Z2,
    TrUserData).

skip_length_delimited_CommandPong(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandPong(Rest,
    N + 7,
    X bsl N + Acc,
    TrUserData);
skip_length_delimited_CommandPong(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandPong(Rest2, 0, 0, TrUserData).

skip_group_CommandPong(Bin, FNum, Z2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandPong(Rest, 0, Z2, TrUserData).

skip_32_CommandPong(<<_:32, Rest/binary>>, Z1, Z2,
    TrUserData) ->
  dfp_read_field_def_CommandPong(Rest,
    Z1,
    Z2,
    TrUserData).

skip_64_CommandPong(<<_:64, Rest/binary>>, Z1, Z2,
    TrUserData) ->
  dfp_read_field_def_CommandPong(Rest,
    Z1,
    Z2,
    TrUserData).

decode_msg_CommandConsumerStats(Bin, TrUserData) ->
  dfp_read_field_def_CommandConsumerStats(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandConsumerStats(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandConsumerStats_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandConsumerStats(<<32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandConsumerStats_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandConsumerStats(<<>>, 0, 0,
    F@_1, F@_2, _) ->
  #{request_id => F@_1, consumer_id => F@_2};
dfp_read_field_def_CommandConsumerStats(Other, Z1, Z2,
    F@_1, F@_2, TrUserData) ->
  dg_read_field_def_CommandConsumerStats(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandConsumerStats(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandConsumerStats(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandConsumerStats(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandConsumerStats_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    32 ->
      d_field_CommandConsumerStats_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandConsumerStats(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandConsumerStats(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandConsumerStats(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandConsumerStats(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandConsumerStats(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandConsumerStats(<<>>, 0, 0, F@_1,
    F@_2, _) ->
  #{request_id => F@_1, consumer_id => F@_2}.

d_field_CommandConsumerStats_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStats_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandConsumerStats_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStats(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandConsumerStats_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStats_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandConsumerStats_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStats(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandConsumerStats(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandConsumerStats(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandConsumerStats(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandConsumerStats(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandConsumerStats(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandConsumerStats(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandConsumerStats(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandConsumerStats(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandConsumerStats(Bin, FNum, Z2, F@_1,
    F@_2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandConsumerStats(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandConsumerStats(<<_:32, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandConsumerStats(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandConsumerStats(<<_:64, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandConsumerStats(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandConsumerStatsResponse(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandConsumerStatsResponse(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_error_code(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<26,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_error_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<33,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_msgRateOut(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<41,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_msgThroughputOut(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<49,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_msgRateRedeliver(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<58,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_consumerName(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_availablePermits(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<72,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_unackedMessages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<80,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_blockedConsumerOnUnackedMsgs(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<90,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_address(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<98,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_connectedSince(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<106,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_type(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<113,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_msgRateExpired(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<120,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  d_field_CommandConsumerStatsResponse_msgBacklog(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dfp_read_field_def_CommandConsumerStatsResponse(<<>>, 0,
    0, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14,
    F@_15, _) ->
  S1 = #{request_id => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{error_code => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{error_message => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{msgRateOut => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{msgThroughputOut => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{msgRateRedeliver => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{consumerName => F@_7}
       end,
  S8 = if F@_8 == '$undef' -> S7;
         true -> S7#{availablePermits => F@_8}
       end,
  S9 = if F@_9 == '$undef' -> S8;
         true -> S8#{unackedMessages => F@_9}
       end,
  S10 = if F@_10 == '$undef' -> S9;
          true -> S9#{blockedConsumerOnUnackedMsgs => F@_10}
        end,
  S11 = if F@_11 == '$undef' -> S10;
          true -> S10#{address => F@_11}
        end,
  S12 = if F@_12 == '$undef' -> S11;
          true -> S11#{connectedSince => F@_12}
        end,
  S13 = if F@_13 == '$undef' -> S12;
          true -> S12#{type => F@_13}
        end,
  S14 = if F@_14 == '$undef' -> S13;
          true -> S13#{msgRateExpired => F@_14}
        end,
  if F@_15 == '$undef' -> S14;
    true -> S14#{msgBacklog => F@_15}
  end;
dfp_read_field_def_CommandConsumerStatsResponse(Other,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  dg_read_field_def_CommandConsumerStatsResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

dg_read_field_def_CommandConsumerStatsResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandConsumerStatsResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
dg_read_field_def_CommandConsumerStatsResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandConsumerStatsResponse_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    16 ->
      d_field_CommandConsumerStatsResponse_error_code(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    26 ->
      d_field_CommandConsumerStatsResponse_error_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    33 ->
      d_field_CommandConsumerStatsResponse_msgRateOut(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    41 ->
      d_field_CommandConsumerStatsResponse_msgThroughputOut(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    49 ->
      d_field_CommandConsumerStatsResponse_msgRateRedeliver(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    58 ->
      d_field_CommandConsumerStatsResponse_consumerName(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    64 ->
      d_field_CommandConsumerStatsResponse_availablePermits(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    72 ->
      d_field_CommandConsumerStatsResponse_unackedMessages(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    80 ->
      d_field_CommandConsumerStatsResponse_blockedConsumerOnUnackedMsgs(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    90 ->
      d_field_CommandConsumerStatsResponse_address(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    98 ->
      d_field_CommandConsumerStatsResponse_connectedSince(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    106 ->
      d_field_CommandConsumerStatsResponse_type(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    113 ->
      d_field_CommandConsumerStatsResponse_msgRateExpired(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    120 ->
      d_field_CommandConsumerStatsResponse_msgBacklog(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandConsumerStatsResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            TrUserData);
        1 ->
          skip_64_CommandConsumerStatsResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            TrUserData);
        2 ->
          skip_length_delimited_CommandConsumerStatsResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            TrUserData);
        3 ->
          skip_group_CommandConsumerStatsResponse(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            TrUserData);
        5 ->
          skip_32_CommandConsumerStatsResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            TrUserData)
      end
  end;
dg_read_field_def_CommandConsumerStatsResponse(<<>>, 0,
    0, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14,
    F@_15, _) ->
  S1 = #{request_id => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{error_code => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{error_message => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{msgRateOut => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{msgThroughputOut => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{msgRateRedeliver => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{consumerName => F@_7}
       end,
  S8 = if F@_8 == '$undef' -> S7;
         true -> S7#{availablePermits => F@_8}
       end,
  S9 = if F@_9 == '$undef' -> S8;
         true -> S8#{unackedMessages => F@_9}
       end,
  S10 = if F@_10 == '$undef' -> S9;
          true -> S9#{blockedConsumerOnUnackedMsgs => F@_10}
        end,
  S11 = if F@_11 == '$undef' -> S10;
          true -> S10#{address => F@_11}
        end,
  S12 = if F@_12 == '$undef' -> S11;
          true -> S11#{connectedSince => F@_12}
        end,
  S13 = if F@_13 == '$undef' -> S12;
          true -> S12#{type => F@_13}
        end,
  S14 = if F@_14 == '$undef' -> S13;
          true -> S13#{msgRateExpired => F@_14}
        end,
  if F@_15 == '$undef' -> S14;
    true -> S14#{msgBacklog => F@_15}
  end.

d_field_CommandConsumerStatsResponse_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_error_code(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_error_code(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_error_code(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_ServerError(begin
                                                <<Res:32/signed-native>> =
                                                  <<(X bsl N +
                                                    Acc):32/unsigned-native>>,
                                                id(Res, TrUserData)
                                              end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_error_message(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_error_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_error_message(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_msgRateOut(<<0:48,
  240, 127, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, _,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    id(infinity, TrUserData),
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateOut(<<0:48,
  240, 255, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, _,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    id('-infinity', TrUserData),
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateOut(<<_:48,
  15:4, _:4, _:1, 127:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, _,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    id(nan, TrUserData),
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateOut(<<Value:64/little-float,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, _,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    id(Value, TrUserData),
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_msgThroughputOut(<<0:48,
  240, 127, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, _, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    id(infinity, TrUserData),
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgThroughputOut(<<0:48,
  240, 255, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, _, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    id('-infinity', TrUserData),
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgThroughputOut(<<_:48,
  15:4, _:4, _:1, 127:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, _, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    id(nan, TrUserData),
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgThroughputOut(<<Value:64/little-float,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, _, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    id(Value, TrUserData),
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_msgRateRedeliver(<<0:48,
  240, 127, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, _, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    id(infinity, TrUserData),
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateRedeliver(<<0:48,
  240, 255, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, _, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    id('-infinity', TrUserData),
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateRedeliver(<<_:48,
  15:4, _:4, _:1, 127:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, _, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    id(nan, TrUserData),
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateRedeliver(<<Value:64/little-float,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, _, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    id(Value, TrUserData),
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_consumerName(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_consumerName(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_consumerName(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, _, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    NewFValue,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_availablePermits(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14,
    F@_15, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_availablePermits(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_availablePermits(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, _,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    NewFValue,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_unackedMessages(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_unackedMessages(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_unackedMessages(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, _, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    NewFValue,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_blockedConsumerOnUnackedMsgs(<<1:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1,
    F@_2, F@_3,
    F@_4, F@_5,
    F@_6, F@_7,
    F@_8, F@_9,
    F@_10, F@_11,
    F@_12, F@_13,
    F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_blockedConsumerOnUnackedMsgs(Rest,
    N + 7,
    X bsl N +
      Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_blockedConsumerOnUnackedMsgs(<<0:1,
  X:7,
  Rest/binary>>,
    N, Acc, F@_1,
    F@_2, F@_3,
    F@_4, F@_5,
    F@_6, F@_7,
    F@_8, F@_9, _,
    F@_11, F@_12,
    F@_13, F@_14,
    F@_15,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc =/= 0,
    TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    NewFValue,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_address(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_address(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_address(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, _, F@_12, F@_13, F@_14,
    F@_15, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    NewFValue,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_connectedSince(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_connectedSince(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_connectedSince(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, _,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    NewFValue,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_type(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_type(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_type(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, _, F@_14, F@_15, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    NewFValue,
    F@_14,
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_msgRateExpired(<<0:48,
  240, 127, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, _, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    id(infinity, TrUserData),
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateExpired(<<0:48,
  240, 255, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, _, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    id('-infinity', TrUserData),
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateExpired(<<_:48,
  15:4, _:4, _:1, 127:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, _, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    id(nan, TrUserData),
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgRateExpired(<<Value:64/little-float,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, _, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    id(Value, TrUserData),
    F@_15,
    TrUserData).

d_field_CommandConsumerStatsResponse_msgBacklog(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, TrUserData)
  when N < 57 ->
  d_field_CommandConsumerStatsResponse_msgBacklog(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
d_field_CommandConsumerStatsResponse_msgBacklog(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandConsumerStatsResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    NewFValue,
    TrUserData).

skip_varint_CommandConsumerStatsResponse(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    TrUserData) ->
  skip_varint_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
skip_varint_CommandConsumerStatsResponse(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

skip_length_delimited_CommandConsumerStatsResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandConsumerStatsResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData);
skip_length_delimited_CommandConsumerStatsResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandConsumerStatsResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

skip_group_CommandConsumerStatsResponse(Bin, FNum, Z2,
    F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

skip_32_CommandConsumerStatsResponse(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

skip_64_CommandConsumerStatsResponse(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, TrUserData) ->
  dfp_read_field_def_CommandConsumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    TrUserData).

decode_msg_CommandGetLastMessageId(Bin, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageId(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandGetLastMessageId(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandGetLastMessageId_consumer_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandGetLastMessageId(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  d_field_CommandGetLastMessageId_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandGetLastMessageId(<<>>, 0, 0,
    F@_1, F@_2, _) ->
  #{consumer_id => F@_1, request_id => F@_2};
dfp_read_field_def_CommandGetLastMessageId(Other, Z1,
    Z2, F@_1, F@_2, TrUserData) ->
  dg_read_field_def_CommandGetLastMessageId(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandGetLastMessageId(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandGetLastMessageId(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandGetLastMessageId(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandGetLastMessageId_consumer_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandGetLastMessageId_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandGetLastMessageId(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandGetLastMessageId(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandGetLastMessageId(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandGetLastMessageId(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandGetLastMessageId(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandGetLastMessageId(<<>>, 0, 0,
    F@_1, F@_2, _) ->
  #{consumer_id => F@_1, request_id => F@_2}.

d_field_CommandGetLastMessageId_consumer_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandGetLastMessageId_consumer_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandGetLastMessageId_consumer_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetLastMessageId(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandGetLastMessageId_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  d_field_CommandGetLastMessageId_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandGetLastMessageId_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetLastMessageId(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandGetLastMessageId(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandGetLastMessageId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandGetLastMessageId(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandGetLastMessageId(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandGetLastMessageId(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandGetLastMessageId(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandGetLastMessageId(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandGetLastMessageId(Bin, FNum, Z2, F@_1,
    F@_2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandGetLastMessageId(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandGetLastMessageId(<<_:32, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandGetLastMessageId(<<_:64, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandGetLastMessageIdResponse(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageIdResponse(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandGetLastMessageIdResponse(<<10,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandGetLastMessageIdResponse_last_message_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandGetLastMessageIdResponse(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandGetLastMessageIdResponse_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandGetLastMessageIdResponse(<<>>,
    0, 0, F@_1, F@_2, _) ->
  S1 = #{request_id => F@_2},
  if F@_1 == '$undef' -> S1;
    true -> S1#{last_message_id => F@_1}
  end;
dfp_read_field_def_CommandGetLastMessageIdResponse(Other,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dg_read_field_def_CommandGetLastMessageIdResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandGetLastMessageIdResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandGetLastMessageIdResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandGetLastMessageIdResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    10 ->
      d_field_CommandGetLastMessageIdResponse_last_message_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    16 ->
      d_field_CommandGetLastMessageIdResponse_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandGetLastMessageIdResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandGetLastMessageIdResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandGetLastMessageIdResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandGetLastMessageIdResponse(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandGetLastMessageIdResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandGetLastMessageIdResponse(<<>>,
    0, 0, F@_1, F@_2, _) ->
  S1 = #{request_id => F@_2},
  if F@_1 == '$undef' -> S1;
    true -> S1#{last_message_id => F@_1}
  end.

d_field_CommandGetLastMessageIdResponse_last_message_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetLastMessageIdResponse_last_message_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandGetLastMessageIdResponse_last_message_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, Prev, F@_2,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_MessageIdData(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandGetLastMessageIdResponse(RestF,
    0,
    0,
    if Prev == '$undef' ->
      NewFValue;
      true ->
        merge_msg_MessageIdData(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_2,
    TrUserData).

d_field_CommandGetLastMessageIdResponse_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetLastMessageIdResponse_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandGetLastMessageIdResponse_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetLastMessageIdResponse(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    TrUserData).

skip_varint_CommandGetLastMessageIdResponse(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  skip_varint_CommandGetLastMessageIdResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandGetLastMessageIdResponse(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageIdResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandGetLastMessageIdResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandGetLastMessageIdResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandGetLastMessageIdResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandGetLastMessageIdResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandGetLastMessageIdResponse(Bin, FNum,
    Z2, F@_1, F@_2, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandGetLastMessageIdResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandGetLastMessageIdResponse(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageIdResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandGetLastMessageIdResponse(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetLastMessageIdResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandGetTopicsOfNamespace(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespace(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandGetTopicsOfNamespace(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    TrUserData) ->
  d_field_CommandGetTopicsOfNamespace_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandGetTopicsOfNamespace(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    TrUserData) ->
  d_field_CommandGetTopicsOfNamespace_namespace(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandGetTopicsOfNamespace(<<24,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3,
    TrUserData) ->
  d_field_CommandGetTopicsOfNamespace_mode(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandGetTopicsOfNamespace(<<>>, 0,
    0, F@_1, F@_2, F@_3, _) ->
  S1 = #{request_id => F@_1, namespace => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{mode => F@_3}
  end;
dfp_read_field_def_CommandGetTopicsOfNamespace(Other,
    Z1, Z2, F@_1, F@_2, F@_3,
    TrUserData) ->
  dg_read_field_def_CommandGetTopicsOfNamespace(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandGetTopicsOfNamespace(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandGetTopicsOfNamespace(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandGetTopicsOfNamespace(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandGetTopicsOfNamespace_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    18 ->
      d_field_CommandGetTopicsOfNamespace_namespace(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    24 ->
      d_field_CommandGetTopicsOfNamespace_mode(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandGetTopicsOfNamespace(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandGetTopicsOfNamespace(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandGetTopicsOfNamespace(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandGetTopicsOfNamespace(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandGetTopicsOfNamespace(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandGetTopicsOfNamespace(<<>>, 0,
    0, F@_1, F@_2, F@_3, _) ->
  S1 = #{request_id => F@_1, namespace => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{mode => F@_3}
  end.

d_field_CommandGetTopicsOfNamespace_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetTopicsOfNamespace_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandGetTopicsOfNamespace_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2, F@_3,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetTopicsOfNamespace(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandGetTopicsOfNamespace_namespace(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetTopicsOfNamespace_namespace(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandGetTopicsOfNamespace_namespace(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, _, F@_3,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandGetTopicsOfNamespace(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    TrUserData).

d_field_CommandGetTopicsOfNamespace_mode(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandGetTopicsOfNamespace_mode(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandGetTopicsOfNamespace_mode(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, TrUserData) ->
  {NewFValue, RestF} =
    {id('d_enum_CommandGetTopicsOfNamespace.Mode'(begin
                                                    <<Res:32/signed-native>> =
                                                      <<(X bsl N +
                                                        Acc):32/unsigned-native>>,
                                                    id(Res, TrUserData)
                                                  end),
      TrUserData),
      Rest},
  dfp_read_field_def_CommandGetTopicsOfNamespace(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandGetTopicsOfNamespace(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandGetTopicsOfNamespace(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandGetTopicsOfNamespace(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespace(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandGetTopicsOfNamespace(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandGetTopicsOfNamespace(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandGetTopicsOfNamespace(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandGetTopicsOfNamespace(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandGetTopicsOfNamespace(Bin, FNum, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandGetTopicsOfNamespace(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandGetTopicsOfNamespace(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespace(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandGetTopicsOfNamespace(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespace(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandGetTopicsOfNamespaceResponse(Bin,
    TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Bin,
    0,
    0,
    id('$undef',
      TrUserData),
    id([], TrUserData),
    TrUserData).

dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandGetTopicsOfNamespaceResponse_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(<<18,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  d_field_CommandGetTopicsOfNamespaceResponse_topics(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(<<>>,
    0, 0, F@_1, R1,
    TrUserData) ->
  #{request_id => F@_1,
    topics => lists_reverse(R1, TrUserData)};
dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Other,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dg_read_field_def_CommandGetTopicsOfNamespaceResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

dg_read_field_def_CommandGetTopicsOfNamespaceResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandGetTopicsOfNamespaceResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
dg_read_field_def_CommandGetTopicsOfNamespaceResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandGetTopicsOfNamespaceResponse_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    18 ->
      d_field_CommandGetTopicsOfNamespaceResponse_topics(Rest,
        0,
        0,
        F@_1,
        F@_2,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandGetTopicsOfNamespaceResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        1 ->
          skip_64_CommandGetTopicsOfNamespaceResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        2 ->
          skip_length_delimited_CommandGetTopicsOfNamespaceResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData);
        3 ->
          skip_group_CommandGetTopicsOfNamespaceResponse(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            TrUserData);
        5 ->
          skip_32_CommandGetTopicsOfNamespaceResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            TrUserData)
      end
  end;
dg_read_field_def_CommandGetTopicsOfNamespaceResponse(<<>>,
    0, 0, F@_1, R1,
    TrUserData) ->
  #{request_id => F@_1,
    topics => lists_reverse(R1, TrUserData)}.

d_field_CommandGetTopicsOfNamespaceResponse_request_id(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetTopicsOfNamespaceResponse_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandGetTopicsOfNamespaceResponse_request_id(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, _, F@_2,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    TrUserData).

d_field_CommandGetTopicsOfNamespaceResponse_topics(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetTopicsOfNamespaceResponse_topics(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
d_field_CommandGetTopicsOfNamespaceResponse_topics(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, Prev,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(RestF,
    0,
    0,
    F@_1,
    cons(NewFValue,
      Prev,
      TrUserData),
    TrUserData).

skip_varint_CommandGetTopicsOfNamespaceResponse(<<1:1,
  _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  skip_varint_CommandGetTopicsOfNamespaceResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData);
skip_varint_CommandGetTopicsOfNamespaceResponse(<<0:1,
  _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2,
    TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_length_delimited_CommandGetTopicsOfNamespaceResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandGetTopicsOfNamespaceResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    TrUserData);
skip_length_delimited_CommandGetTopicsOfNamespaceResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    TrUserData).

skip_group_CommandGetTopicsOfNamespaceResponse(Bin,
    FNum, Z2, F@_1, F@_2,
    TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_32_CommandGetTopicsOfNamespaceResponse(<<_:32,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

skip_64_CommandGetTopicsOfNamespaceResponse(<<_:64,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, TrUserData) ->
  dfp_read_field_def_CommandGetTopicsOfNamespaceResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    TrUserData).

decode_msg_CommandGetSchema(Bin, TrUserData) ->
  dfp_read_field_def_CommandGetSchema(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandGetSchema(<<8, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandGetSchema_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandGetSchema(<<18, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandGetSchema_topic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandGetSchema(<<26, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  d_field_CommandGetSchema_schema_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dfp_read_field_def_CommandGetSchema(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{request_id => F@_1, topic => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{schema_version => F@_3}
  end;
dfp_read_field_def_CommandGetSchema(Other, Z1, Z2, F@_1,
    F@_2, F@_3, TrUserData) ->
  dg_read_field_def_CommandGetSchema(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

dg_read_field_def_CommandGetSchema(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandGetSchema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
dg_read_field_def_CommandGetSchema(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandGetSchema_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    18 ->
      d_field_CommandGetSchema_topic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    26 ->
      d_field_CommandGetSchema_schema_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandGetSchema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        1 ->
          skip_64_CommandGetSchema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        2 ->
          skip_length_delimited_CommandGetSchema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        3 ->
          skip_group_CommandGetSchema(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData);
        5 ->
          skip_32_CommandGetSchema(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            TrUserData)
      end
  end;
dg_read_field_def_CommandGetSchema(<<>>, 0, 0, F@_1,
    F@_2, F@_3, _) ->
  S1 = #{request_id => F@_1, topic => F@_2},
  if F@_3 == '$undef' -> S1;
    true -> S1#{schema_version => F@_3}
  end.

d_field_CommandGetSchema_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchema_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandGetSchema_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetSchema(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    TrUserData).

d_field_CommandGetSchema_topic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchema_topic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandGetSchema_topic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandGetSchema(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    TrUserData).

d_field_CommandGetSchema_schema_version(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchema_schema_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
d_field_CommandGetSchema_schema_version(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandGetSchema(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    TrUserData).

skip_varint_CommandGetSchema(<<1:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  skip_varint_CommandGetSchema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_varint_CommandGetSchema(<<0:1, _:7, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandGetSchema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_length_delimited_CommandGetSchema(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandGetSchema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    TrUserData);
skip_length_delimited_CommandGetSchema(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandGetSchema(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_group_CommandGetSchema(Bin, FNum, Z2, F@_1, F@_2,
    F@_3, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandGetSchema(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_32_CommandGetSchema(<<_:32, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandGetSchema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

skip_64_CommandGetSchema(<<_:64, Rest/binary>>, Z1, Z2,
    F@_1, F@_2, F@_3, TrUserData) ->
  dfp_read_field_def_CommandGetSchema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    TrUserData).

decode_msg_CommandGetSchemaResponse(Bin, TrUserData) ->
  dfp_read_field_def_CommandGetSchemaResponse(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_CommandGetSchemaResponse(<<8,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  d_field_CommandGetSchemaResponse_request_id(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandGetSchemaResponse(<<16,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  d_field_CommandGetSchemaResponse_error_code(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandGetSchemaResponse(<<26,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  d_field_CommandGetSchemaResponse_error_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandGetSchemaResponse(<<34,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  d_field_CommandGetSchemaResponse_schema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandGetSchemaResponse(<<42,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  d_field_CommandGetSchemaResponse_schema_version(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dfp_read_field_def_CommandGetSchemaResponse(<<>>, 0, 0,
    F@_1, F@_2, F@_3, F@_4, F@_5, _) ->
  S1 = #{request_id => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{error_code => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{error_message => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{schema => F@_4}
       end,
  if F@_5 == '$undef' -> S4;
    true -> S4#{schema_version => F@_5}
  end;
dfp_read_field_def_CommandGetSchemaResponse(Other, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  dg_read_field_def_CommandGetSchemaResponse(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

dg_read_field_def_CommandGetSchemaResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_CommandGetSchemaResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
dg_read_field_def_CommandGetSchemaResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_CommandGetSchemaResponse_request_id(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    16 ->
      d_field_CommandGetSchemaResponse_error_code(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    26 ->
      d_field_CommandGetSchemaResponse_error_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    34 ->
      d_field_CommandGetSchemaResponse_schema(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    42 ->
      d_field_CommandGetSchemaResponse_schema_version(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_CommandGetSchemaResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        1 ->
          skip_64_CommandGetSchemaResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        2 ->
          skip_length_delimited_CommandGetSchemaResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        3 ->
          skip_group_CommandGetSchemaResponse(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData);
        5 ->
          skip_32_CommandGetSchemaResponse(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            TrUserData)
      end
  end;
dg_read_field_def_CommandGetSchemaResponse(<<>>, 0, 0,
    F@_1, F@_2, F@_3, F@_4, F@_5, _) ->
  S1 = #{request_id => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{error_code => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{error_message => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{schema => F@_4}
       end,
  if F@_5 == '$undef' -> S4;
    true -> S4#{schema_version => F@_5}
  end.

d_field_CommandGetSchemaResponse_request_id(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchemaResponse_request_id(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandGetSchemaResponse_request_id(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, _, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = {id(X bsl N + Acc, TrUserData),
    Rest},
  dfp_read_field_def_CommandGetSchemaResponse(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandGetSchemaResponse_error_code(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchemaResponse_error_code(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandGetSchemaResponse_error_code(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, _, F@_3, F@_4, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = {id(d_enum_ServerError(begin
                                                <<Res:32/signed-native>> =
                                                  <<(X bsl N +
                                                    Acc):32/unsigned-native>>,
                                                id(Res, TrUserData)
                                              end),
    TrUserData),
    Rest},
  dfp_read_field_def_CommandGetSchemaResponse(RestF,
    0,
    0,
    F@_1,
    NewFValue,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandGetSchemaResponse_error_message(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchemaResponse_error_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandGetSchemaResponse_error_message(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, _, F@_4,
    F@_5, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandGetSchemaResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    NewFValue,
    F@_4,
    F@_5,
    TrUserData).

d_field_CommandGetSchemaResponse_schema(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData)
  when N < 57 ->
  d_field_CommandGetSchemaResponse_schema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandGetSchemaResponse_schema(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, Prev, F@_5,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_Schema(Bs, TrUserData), TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_CommandGetSchemaResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    if Prev == '$undef' ->
      NewFValue;
      true ->
        merge_msg_Schema(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_5,
    TrUserData).

d_field_CommandGetSchemaResponse_schema_version(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  d_field_CommandGetSchemaResponse_schema_version(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
d_field_CommandGetSchemaResponse_schema_version(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    _, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bytes:Len/binary, Rest2/binary>> = Rest,
                         {id(binary:copy(Bytes), TrUserData), Rest2}
                       end,
  dfp_read_field_def_CommandGetSchemaResponse(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    NewFValue,
    TrUserData).

skip_varint_CommandGetSchemaResponse(<<1:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  skip_varint_CommandGetSchemaResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_varint_CommandGetSchemaResponse(<<0:1, _:7,
  Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  dfp_read_field_def_CommandGetSchemaResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_length_delimited_CommandGetSchemaResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData)
  when N < 57 ->
  skip_length_delimited_CommandGetSchemaResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData);
skip_length_delimited_CommandGetSchemaResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_CommandGetSchemaResponse(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_group_CommandGetSchemaResponse(Bin, FNum, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_CommandGetSchemaResponse(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_32_CommandGetSchemaResponse(<<_:32, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  dfp_read_field_def_CommandGetSchemaResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

skip_64_CommandGetSchemaResponse(<<_:64, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5,
    TrUserData) ->
  dfp_read_field_def_CommandGetSchemaResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    TrUserData).

decode_msg_BaseCommand(Bin, TrUserData) ->
  dfp_read_field_def_BaseCommand(Bin,
    0,
    0,
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    id('$undef', TrUserData),
    TrUserData).

dfp_read_field_def_BaseCommand(<<8, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_type(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<18, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_connect(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<26, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_connected(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<34, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_subscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<42, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_producer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<50, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_send(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<58, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_send_receipt(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<66, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_send_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<74, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_message(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<82, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_ack(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<90, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_flow(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<98, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_unsubscribe(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<106, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_success(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<114, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_error(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<122, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_close_producer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<130, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_close_consumer(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<138, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_producer_success(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<146, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_ping(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<154, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_pong(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<162, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_redeliverUnacknowledgedMessages(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<170, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_partitionMetadata(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<178, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_partitionMetadataResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<186, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_lookupTopic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<194, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_lookupTopicResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<202, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_consumerStats(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<210, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_consumerStatsResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<218, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_reachedEndOfTopic(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<226, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_seek(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<234, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_getLastMessageId(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<242, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_getLastMessageIdResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<250, 1, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_active_consumer_change(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<130, 2, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_getTopicsOfNamespace(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<138, 2, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_getTopicsOfNamespaceResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<146, 2, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_getSchema(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<154, 2, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_getSchemaResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<162, 2, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_authChallenge(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<170, 2, Rest/binary>>,
    Z1, Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  d_field_BaseCommand_authResponse(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dfp_read_field_def_BaseCommand(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37, _) ->
  S1 = #{type => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{connect => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{connected => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{subscribe => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{producer => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{send => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{send_receipt => F@_7}
       end,
  S8 = if F@_8 == '$undef' -> S7;
         true -> S7#{send_error => F@_8}
       end,
  S9 = if F@_9 == '$undef' -> S8;
         true -> S8#{message => F@_9}
       end,
  S10 = if F@_10 == '$undef' -> S9;
          true -> S9#{ack => F@_10}
        end,
  S11 = if F@_11 == '$undef' -> S10;
          true -> S10#{flow => F@_11}
        end,
  S12 = if F@_12 == '$undef' -> S11;
          true -> S11#{unsubscribe => F@_12}
        end,
  S13 = if F@_13 == '$undef' -> S12;
          true -> S12#{success => F@_13}
        end,
  S14 = if F@_14 == '$undef' -> S13;
          true -> S13#{error => F@_14}
        end,
  S15 = if F@_15 == '$undef' -> S14;
          true -> S14#{close_producer => F@_15}
        end,
  S16 = if F@_16 == '$undef' -> S15;
          true -> S15#{close_consumer => F@_16}
        end,
  S17 = if F@_17 == '$undef' -> S16;
          true -> S16#{producer_success => F@_17}
        end,
  S18 = if F@_18 == '$undef' -> S17;
          true -> S17#{ping => F@_18}
        end,
  S19 = if F@_19 == '$undef' -> S18;
          true -> S18#{pong => F@_19}
        end,
  S20 = if F@_20 == '$undef' -> S19;
          true -> S19#{redeliverUnacknowledgedMessages => F@_20}
        end,
  S21 = if F@_21 == '$undef' -> S20;
          true -> S20#{partitionMetadata => F@_21}
        end,
  S22 = if F@_22 == '$undef' -> S21;
          true -> S21#{partitionMetadataResponse => F@_22}
        end,
  S23 = if F@_23 == '$undef' -> S22;
          true -> S22#{lookupTopic => F@_23}
        end,
  S24 = if F@_24 == '$undef' -> S23;
          true -> S23#{lookupTopicResponse => F@_24}
        end,
  S25 = if F@_25 == '$undef' -> S24;
          true -> S24#{consumerStats => F@_25}
        end,
  S26 = if F@_26 == '$undef' -> S25;
          true -> S25#{consumerStatsResponse => F@_26}
        end,
  S27 = if F@_27 == '$undef' -> S26;
          true -> S26#{reachedEndOfTopic => F@_27}
        end,
  S28 = if F@_28 == '$undef' -> S27;
          true -> S27#{seek => F@_28}
        end,
  S29 = if F@_29 == '$undef' -> S28;
          true -> S28#{getLastMessageId => F@_29}
        end,
  S30 = if F@_30 == '$undef' -> S29;
          true -> S29#{getLastMessageIdResponse => F@_30}
        end,
  S31 = if F@_31 == '$undef' -> S30;
          true -> S30#{active_consumer_change => F@_31}
        end,
  S32 = if F@_32 == '$undef' -> S31;
          true -> S31#{getTopicsOfNamespace => F@_32}
        end,
  S33 = if F@_33 == '$undef' -> S32;
          true -> S32#{getTopicsOfNamespaceResponse => F@_33}
        end,
  S34 = if F@_34 == '$undef' -> S33;
          true -> S33#{getSchema => F@_34}
        end,
  S35 = if F@_35 == '$undef' -> S34;
          true -> S34#{getSchemaResponse => F@_35}
        end,
  S36 = if F@_36 == '$undef' -> S35;
          true -> S35#{authChallenge => F@_36}
        end,
  if F@_37 == '$undef' -> S36;
    true -> S36#{authResponse => F@_37}
  end;
dfp_read_field_def_BaseCommand(Other, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  dg_read_field_def_BaseCommand(Other,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

dg_read_field_def_BaseCommand(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 32 - 7 ->
  dg_read_field_def_BaseCommand(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
dg_read_field_def_BaseCommand(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  Key = X bsl N + Acc,
  case Key of
    8 ->
      d_field_BaseCommand_type(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    18 ->
      d_field_BaseCommand_connect(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    26 ->
      d_field_BaseCommand_connected(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    34 ->
      d_field_BaseCommand_subscribe(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    42 ->
      d_field_BaseCommand_producer(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    50 ->
      d_field_BaseCommand_send(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    58 ->
      d_field_BaseCommand_send_receipt(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    66 ->
      d_field_BaseCommand_send_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    74 ->
      d_field_BaseCommand_message(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    82 ->
      d_field_BaseCommand_ack(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    90 ->
      d_field_BaseCommand_flow(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    98 ->
      d_field_BaseCommand_unsubscribe(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    106 ->
      d_field_BaseCommand_success(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    114 ->
      d_field_BaseCommand_error(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    122 ->
      d_field_BaseCommand_close_producer(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    130 ->
      d_field_BaseCommand_close_consumer(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    138 ->
      d_field_BaseCommand_producer_success(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    146 ->
      d_field_BaseCommand_ping(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    154 ->
      d_field_BaseCommand_pong(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    162 ->
      d_field_BaseCommand_redeliverUnacknowledgedMessages(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    170 ->
      d_field_BaseCommand_partitionMetadata(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    178 ->
      d_field_BaseCommand_partitionMetadataResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    186 ->
      d_field_BaseCommand_lookupTopic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    194 ->
      d_field_BaseCommand_lookupTopicResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    202 ->
      d_field_BaseCommand_consumerStats(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    210 ->
      d_field_BaseCommand_consumerStatsResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    218 ->
      d_field_BaseCommand_reachedEndOfTopic(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    226 ->
      d_field_BaseCommand_seek(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    234 ->
      d_field_BaseCommand_getLastMessageId(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    242 ->
      d_field_BaseCommand_getLastMessageIdResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    250 ->
      d_field_BaseCommand_active_consumer_change(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    258 ->
      d_field_BaseCommand_getTopicsOfNamespace(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    266 ->
      d_field_BaseCommand_getTopicsOfNamespaceResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    274 ->
      d_field_BaseCommand_getSchema(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    282 ->
      d_field_BaseCommand_getSchemaResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    290 ->
      d_field_BaseCommand_authChallenge(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    298 ->
      d_field_BaseCommand_authResponse(Rest,
        0,
        0,
        F@_1,
        F@_2,
        F@_3,
        F@_4,
        F@_5,
        F@_6,
        F@_7,
        F@_8,
        F@_9,
        F@_10,
        F@_11,
        F@_12,
        F@_13,
        F@_14,
        F@_15,
        F@_16,
        F@_17,
        F@_18,
        F@_19,
        F@_20,
        F@_21,
        F@_22,
        F@_23,
        F@_24,
        F@_25,
        F@_26,
        F@_27,
        F@_28,
        F@_29,
        F@_30,
        F@_31,
        F@_32,
        F@_33,
        F@_34,
        F@_35,
        F@_36,
        F@_37,
        TrUserData);
    _ ->
      case Key band 7 of
        0 ->
          skip_varint_BaseCommand(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            F@_18,
            F@_19,
            F@_20,
            F@_21,
            F@_22,
            F@_23,
            F@_24,
            F@_25,
            F@_26,
            F@_27,
            F@_28,
            F@_29,
            F@_30,
            F@_31,
            F@_32,
            F@_33,
            F@_34,
            F@_35,
            F@_36,
            F@_37,
            TrUserData);
        1 ->
          skip_64_BaseCommand(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            F@_18,
            F@_19,
            F@_20,
            F@_21,
            F@_22,
            F@_23,
            F@_24,
            F@_25,
            F@_26,
            F@_27,
            F@_28,
            F@_29,
            F@_30,
            F@_31,
            F@_32,
            F@_33,
            F@_34,
            F@_35,
            F@_36,
            F@_37,
            TrUserData);
        2 ->
          skip_length_delimited_BaseCommand(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            F@_18,
            F@_19,
            F@_20,
            F@_21,
            F@_22,
            F@_23,
            F@_24,
            F@_25,
            F@_26,
            F@_27,
            F@_28,
            F@_29,
            F@_30,
            F@_31,
            F@_32,
            F@_33,
            F@_34,
            F@_35,
            F@_36,
            F@_37,
            TrUserData);
        3 ->
          skip_group_BaseCommand(Rest,
            Key bsr 3,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            F@_18,
            F@_19,
            F@_20,
            F@_21,
            F@_22,
            F@_23,
            F@_24,
            F@_25,
            F@_26,
            F@_27,
            F@_28,
            F@_29,
            F@_30,
            F@_31,
            F@_32,
            F@_33,
            F@_34,
            F@_35,
            F@_36,
            F@_37,
            TrUserData);
        5 ->
          skip_32_BaseCommand(Rest,
            0,
            0,
            F@_1,
            F@_2,
            F@_3,
            F@_4,
            F@_5,
            F@_6,
            F@_7,
            F@_8,
            F@_9,
            F@_10,
            F@_11,
            F@_12,
            F@_13,
            F@_14,
            F@_15,
            F@_16,
            F@_17,
            F@_18,
            F@_19,
            F@_20,
            F@_21,
            F@_22,
            F@_23,
            F@_24,
            F@_25,
            F@_26,
            F@_27,
            F@_28,
            F@_29,
            F@_30,
            F@_31,
            F@_32,
            F@_33,
            F@_34,
            F@_35,
            F@_36,
            F@_37,
            TrUserData)
      end
  end;
dg_read_field_def_BaseCommand(<<>>, 0, 0, F@_1, F@_2,
    F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37, _) ->
  S1 = #{type => F@_1},
  S2 = if F@_2 == '$undef' -> S1;
         true -> S1#{connect => F@_2}
       end,
  S3 = if F@_3 == '$undef' -> S2;
         true -> S2#{connected => F@_3}
       end,
  S4 = if F@_4 == '$undef' -> S3;
         true -> S3#{subscribe => F@_4}
       end,
  S5 = if F@_5 == '$undef' -> S4;
         true -> S4#{producer => F@_5}
       end,
  S6 = if F@_6 == '$undef' -> S5;
         true -> S5#{send => F@_6}
       end,
  S7 = if F@_7 == '$undef' -> S6;
         true -> S6#{send_receipt => F@_7}
       end,
  S8 = if F@_8 == '$undef' -> S7;
         true -> S7#{send_error => F@_8}
       end,
  S9 = if F@_9 == '$undef' -> S8;
         true -> S8#{message => F@_9}
       end,
  S10 = if F@_10 == '$undef' -> S9;
          true -> S9#{ack => F@_10}
        end,
  S11 = if F@_11 == '$undef' -> S10;
          true -> S10#{flow => F@_11}
        end,
  S12 = if F@_12 == '$undef' -> S11;
          true -> S11#{unsubscribe => F@_12}
        end,
  S13 = if F@_13 == '$undef' -> S12;
          true -> S12#{success => F@_13}
        end,
  S14 = if F@_14 == '$undef' -> S13;
          true -> S13#{error => F@_14}
        end,
  S15 = if F@_15 == '$undef' -> S14;
          true -> S14#{close_producer => F@_15}
        end,
  S16 = if F@_16 == '$undef' -> S15;
          true -> S15#{close_consumer => F@_16}
        end,
  S17 = if F@_17 == '$undef' -> S16;
          true -> S16#{producer_success => F@_17}
        end,
  S18 = if F@_18 == '$undef' -> S17;
          true -> S17#{ping => F@_18}
        end,
  S19 = if F@_19 == '$undef' -> S18;
          true -> S18#{pong => F@_19}
        end,
  S20 = if F@_20 == '$undef' -> S19;
          true -> S19#{redeliverUnacknowledgedMessages => F@_20}
        end,
  S21 = if F@_21 == '$undef' -> S20;
          true -> S20#{partitionMetadata => F@_21}
        end,
  S22 = if F@_22 == '$undef' -> S21;
          true -> S21#{partitionMetadataResponse => F@_22}
        end,
  S23 = if F@_23 == '$undef' -> S22;
          true -> S22#{lookupTopic => F@_23}
        end,
  S24 = if F@_24 == '$undef' -> S23;
          true -> S23#{lookupTopicResponse => F@_24}
        end,
  S25 = if F@_25 == '$undef' -> S24;
          true -> S24#{consumerStats => F@_25}
        end,
  S26 = if F@_26 == '$undef' -> S25;
          true -> S25#{consumerStatsResponse => F@_26}
        end,
  S27 = if F@_27 == '$undef' -> S26;
          true -> S26#{reachedEndOfTopic => F@_27}
        end,
  S28 = if F@_28 == '$undef' -> S27;
          true -> S27#{seek => F@_28}
        end,
  S29 = if F@_29 == '$undef' -> S28;
          true -> S28#{getLastMessageId => F@_29}
        end,
  S30 = if F@_30 == '$undef' -> S29;
          true -> S29#{getLastMessageIdResponse => F@_30}
        end,
  S31 = if F@_31 == '$undef' -> S30;
          true -> S30#{active_consumer_change => F@_31}
        end,
  S32 = if F@_32 == '$undef' -> S31;
          true -> S31#{getTopicsOfNamespace => F@_32}
        end,
  S33 = if F@_33 == '$undef' -> S32;
          true -> S32#{getTopicsOfNamespaceResponse => F@_33}
        end,
  S34 = if F@_34 == '$undef' -> S33;
          true -> S33#{getSchema => F@_34}
        end,
  S35 = if F@_35 == '$undef' -> S34;
          true -> S34#{getSchemaResponse => F@_35}
        end,
  S36 = if F@_36 == '$undef' -> S35;
          true -> S35#{authChallenge => F@_36}
        end,
  if F@_37 == '$undef' -> S36;
    true -> S36#{authResponse => F@_37}
  end.

d_field_BaseCommand_type(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_type(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_type(<<0:1, X:7, Rest/binary>>, N,
    Acc, _, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32, F@_33,
    F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = {id('d_enum_BaseCommand.Type'(begin
                                                       <<Res:32/signed-native>> =
                                                         <<(X bsl N +
                                                           Acc):32/unsigned-native>>,
                                                       id(Res, TrUserData)
                                                     end),
    TrUserData),
    Rest},
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    NewFValue,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_connect(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_connect(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_connect(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, Prev, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandConnect(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandConnect(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_connected(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_connected(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_connected(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, Prev, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandConnected(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandConnected(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_subscribe(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_subscribe(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_subscribe(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, Prev, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandSubscribe(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandSubscribe(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_producer(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_producer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_producer(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, Prev, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandProducer(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandProducer(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_send(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_send(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_send(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, Prev, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandSend(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandSend(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_send_receipt(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_send_receipt(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_send_receipt(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    Prev, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandSendReceipt(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandSendReceipt(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_send_error(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_send_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_send_error(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    Prev, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandSendError(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandSendError(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_message(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_message(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_message(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, Prev, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandMessage(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandMessage(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_ack(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_ack(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_ack(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, Prev, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandAck(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandAck(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_flow(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_flow(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_flow(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, Prev, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandFlow(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandFlow(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_unsubscribe(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19, F@_20,
    F@_21, F@_22, F@_23, F@_24, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_unsubscribe(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_unsubscribe(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, Prev, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19, F@_20,
    F@_21, F@_22, F@_23, F@_24, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandUnsubscribe(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandUnsubscribe(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_success(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_success(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_success(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, Prev, F@_14, F@_15,
    F@_16, F@_17, F@_18, F@_19, F@_20, F@_21, F@_22,
    F@_23, F@_24, F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandSuccess(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandSuccess(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_error(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_error(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_error(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, Prev, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandError(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandError(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_close_producer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_close_producer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_close_producer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, Prev, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandCloseProducer(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandCloseProducer(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_close_consumer(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_close_consumer(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_close_consumer(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, Prev, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandCloseConsumer(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandCloseConsumer(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_producer_success(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17, F@_18,
    F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_producer_success(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_producer_success(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, Prev, F@_18,
    F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandProducerSuccess(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandProducerSuccess(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_ping(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_ping(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_ping(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, Prev, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandPing(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandPing(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_pong(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_pong(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_pong(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, Prev, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandPong(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandPong(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_redeliverUnacknowledgedMessages(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_redeliverUnacknowledgedMessages(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_redeliverUnacknowledgedMessages(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15,
    F@_16, F@_17, F@_18, F@_19,
    Prev, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandRedeliverUnacknowledgedMessages(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandRedeliverUnacknowledgedMessages(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_partitionMetadata(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_partitionMetadata(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_partitionMetadata(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, Prev, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandPartitionedTopicMetadata(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandPartitionedTopicMetadata(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_partitionMetadataResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_partitionMetadataResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_partitionMetadataResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, Prev, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandPartitionedTopicMetadataResponse(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandPartitionedTopicMetadataResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_lookupTopic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19, F@_20,
    F@_21, F@_22, F@_23, F@_24, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_lookupTopic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_lookupTopic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19, F@_20,
    F@_21, F@_22, Prev, F@_24, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandLookupTopic(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandLookupTopic(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_lookupTopicResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_lookupTopicResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_lookupTopicResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, Prev, F@_25, F@_26, F@_27,
    F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandLookupTopicResponse(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandLookupTopicResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_consumerStats(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_consumerStats(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_consumerStats(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, Prev,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandConsumerStats(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandConsumerStats(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_consumerStatsResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_consumerStatsResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_consumerStatsResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, Prev,
    F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandConsumerStatsResponse(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandConsumerStatsResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_reachedEndOfTopic(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_reachedEndOfTopic(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_reachedEndOfTopic(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, Prev, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandReachedEndOfTopic(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandReachedEndOfTopic(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_seek(<<1:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_seek(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_seek(<<0:1, X:7, Rest/binary>>, N,
    Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, Prev, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandSeek(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandSeek(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_getLastMessageId(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17, F@_18,
    F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_getLastMessageId(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_getLastMessageId(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17, F@_18,
    F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, Prev, F@_30,
    F@_31, F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandGetLastMessageId(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandGetLastMessageId(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_getLastMessageIdResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_getLastMessageIdResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_getLastMessageIdResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29,
    Prev, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandGetLastMessageIdResponse(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandGetLastMessageIdResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_active_consumer_change(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_active_consumer_change(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_active_consumer_change(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, Prev,
    F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandActiveConsumerChange(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandActiveConsumerChange(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_getTopicsOfNamespace(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_getTopicsOfNamespace(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_getTopicsOfNamespace(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31,
    Prev, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandGetTopicsOfNamespace(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandGetTopicsOfNamespace(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_getTopicsOfNamespaceResponse(<<1:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33,
    F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_getTopicsOfNamespaceResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_getTopicsOfNamespaceResponse(<<0:1,
  X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4,
    F@_5, F@_6, F@_7, F@_8, F@_9,
    F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, Prev,
    F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandGetTopicsOfNamespaceResponse(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandGetTopicsOfNamespaceResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_getSchema(<<1:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_getSchema(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_getSchema(<<0:1, X:7, Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7,
    F@_8, F@_9, F@_10, F@_11, F@_12, F@_13, F@_14,
    F@_15, F@_16, F@_17, F@_18, F@_19, F@_20, F@_21,
    F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, Prev, F@_35,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandGetSchema(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandGetSchema(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_getSchemaResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, F@_35,
    F@_36, F@_37, TrUserData)
  when N < 57 ->
  d_field_BaseCommand_getSchemaResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_getSchemaResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5,
    F@_6, F@_7, F@_8, F@_9, F@_10, F@_11,
    F@_12, F@_13, F@_14, F@_15, F@_16, F@_17,
    F@_18, F@_19, F@_20, F@_21, F@_22, F@_23,
    F@_24, F@_25, F@_26, F@_27, F@_28, F@_29,
    F@_30, F@_31, F@_32, F@_33, F@_34, Prev,
    F@_36, F@_37, TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandGetSchemaResponse(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandGetSchemaResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_36,
    F@_37,
    TrUserData).

d_field_BaseCommand_authChallenge(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_authChallenge(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_authChallenge(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, Prev, F@_37,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandAuthChallenge(Bs,
                           TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandAuthChallenge(Prev,
          NewFValue,
          TrUserData)
    end,
    F@_37,
    TrUserData).

d_field_BaseCommand_authResponse(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  d_field_BaseCommand_authResponse(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
d_field_BaseCommand_authResponse(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, Prev,
    TrUserData) ->
  {NewFValue, RestF} = begin
                         Len = X bsl N + Acc,
                         <<Bs:Len/binary, Rest2/binary>> = Rest,
                         {id(decode_msg_CommandAuthResponse(Bs, TrUserData),
                           TrUserData),
                           Rest2}
                       end,
  dfp_read_field_def_BaseCommand(RestF,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    if Prev == '$undef' -> NewFValue;
      true ->
        merge_msg_CommandAuthResponse(Prev,
          NewFValue,
          TrUserData)
    end,
    TrUserData).

skip_varint_BaseCommand(<<1:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  skip_varint_BaseCommand(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
skip_varint_BaseCommand(<<0:1, _:7, Rest/binary>>, Z1,
    Z2, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8,
    F@_9, F@_10, F@_11, F@_12, F@_13, F@_14, F@_15, F@_16,
    F@_17, F@_18, F@_19, F@_20, F@_21, F@_22, F@_23, F@_24,
    F@_25, F@_26, F@_27, F@_28, F@_29, F@_30, F@_31, F@_32,
    F@_33, F@_34, F@_35, F@_36, F@_37, TrUserData) ->
  dfp_read_field_def_BaseCommand(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

skip_length_delimited_BaseCommand(<<1:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData)
  when N < 57 ->
  skip_length_delimited_BaseCommand(Rest,
    N + 7,
    X bsl N + Acc,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData);
skip_length_delimited_BaseCommand(<<0:1, X:7,
  Rest/binary>>,
    N, Acc, F@_1, F@_2, F@_3, F@_4, F@_5, F@_6,
    F@_7, F@_8, F@_9, F@_10, F@_11, F@_12, F@_13,
    F@_14, F@_15, F@_16, F@_17, F@_18, F@_19,
    F@_20, F@_21, F@_22, F@_23, F@_24, F@_25,
    F@_26, F@_27, F@_28, F@_29, F@_30, F@_31,
    F@_32, F@_33, F@_34, F@_35, F@_36, F@_37,
    TrUserData) ->
  Length = X bsl N + Acc,
  <<_:Length/binary, Rest2/binary>> = Rest,
  dfp_read_field_def_BaseCommand(Rest2,
    0,
    0,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

skip_group_BaseCommand(Bin, FNum, Z2, F@_1, F@_2, F@_3,
    F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10, F@_11, F@_12,
    F@_13, F@_14, F@_15, F@_16, F@_17, F@_18, F@_19, F@_20,
    F@_21, F@_22, F@_23, F@_24, F@_25, F@_26, F@_27, F@_28,
    F@_29, F@_30, F@_31, F@_32, F@_33, F@_34, F@_35, F@_36,
    F@_37, TrUserData) ->
  {_, Rest} = read_group(Bin, FNum),
  dfp_read_field_def_BaseCommand(Rest,
    0,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

skip_32_BaseCommand(<<_:32, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17, F@_18,
    F@_19, F@_20, F@_21, F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData) ->
  dfp_read_field_def_BaseCommand(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

skip_64_BaseCommand(<<_:64, Rest/binary>>, Z1, Z2, F@_1,
    F@_2, F@_3, F@_4, F@_5, F@_6, F@_7, F@_8, F@_9, F@_10,
    F@_11, F@_12, F@_13, F@_14, F@_15, F@_16, F@_17, F@_18,
    F@_19, F@_20, F@_21, F@_22, F@_23, F@_24, F@_25, F@_26,
    F@_27, F@_28, F@_29, F@_30, F@_31, F@_32, F@_33, F@_34,
    F@_35, F@_36, F@_37, TrUserData) ->
  dfp_read_field_def_BaseCommand(Rest,
    Z1,
    Z2,
    F@_1,
    F@_2,
    F@_3,
    F@_4,
    F@_5,
    F@_6,
    F@_7,
    F@_8,
    F@_9,
    F@_10,
    F@_11,
    F@_12,
    F@_13,
    F@_14,
    F@_15,
    F@_16,
    F@_17,
    F@_18,
    F@_19,
    F@_20,
    F@_21,
    F@_22,
    F@_23,
    F@_24,
    F@_25,
    F@_26,
    F@_27,
    F@_28,
    F@_29,
    F@_30,
    F@_31,
    F@_32,
    F@_33,
    F@_34,
    F@_35,
    F@_36,
    F@_37,
    TrUserData).

'd_enum_Schema.Type'(0) -> 'None';
'd_enum_Schema.Type'(1) -> 'String';
'd_enum_Schema.Type'(2) -> 'Json';
'd_enum_Schema.Type'(3) -> 'Protobuf';
'd_enum_Schema.Type'(4) -> 'Avro';
'd_enum_Schema.Type'(5) -> 'Bool';
'd_enum_Schema.Type'(6) -> 'Int8';
'd_enum_Schema.Type'(7) -> 'Int16';
'd_enum_Schema.Type'(8) -> 'Int32';
'd_enum_Schema.Type'(9) -> 'Int64';
'd_enum_Schema.Type'(10) -> 'Float';
'd_enum_Schema.Type'(11) -> 'Double';
'd_enum_Schema.Type'(12) -> 'Date';
'd_enum_Schema.Type'(13) -> 'Time';
'd_enum_Schema.Type'(14) -> 'Timestamp';
'd_enum_Schema.Type'(15) -> 'KeyValue';
'd_enum_Schema.Type'(V) -> V.

d_enum_CompressionType(0) -> 'NONE';
d_enum_CompressionType(1) -> 'LZ4';
d_enum_CompressionType(2) -> 'ZLIB';
d_enum_CompressionType(3) -> 'ZSTD';
d_enum_CompressionType(V) -> V.

d_enum_ServerError(0) -> 'UnknownError';
d_enum_ServerError(1) -> 'MetadataError';
d_enum_ServerError(2) -> 'PersistenceError';
d_enum_ServerError(3) -> 'AuthenticationError';
d_enum_ServerError(4) -> 'AuthorizationError';
d_enum_ServerError(5) -> 'ConsumerBusy';
d_enum_ServerError(6) -> 'ServiceNotReady';
d_enum_ServerError(7) ->
  'ProducerBlockedQuotaExceededError';
d_enum_ServerError(8) ->
  'ProducerBlockedQuotaExceededException';
d_enum_ServerError(9) -> 'ChecksumError';
d_enum_ServerError(10) -> 'UnsupportedVersionError';
d_enum_ServerError(11) -> 'TopicNotFound';
d_enum_ServerError(12) -> 'SubscriptionNotFound';
d_enum_ServerError(13) -> 'ConsumerNotFound';
d_enum_ServerError(14) -> 'TooManyRequests';
d_enum_ServerError(15) -> 'TopicTerminatedError';
d_enum_ServerError(16) -> 'ProducerBusy';
d_enum_ServerError(17) -> 'InvalidTopicName';
d_enum_ServerError(18) -> 'IncompatibleSchema';
d_enum_ServerError(19) -> 'ConsumerAssignError';
d_enum_ServerError(V) -> V.

d_enum_AuthMethod(0) -> 'AuthMethodNone';
d_enum_AuthMethod(1) -> 'AuthMethodYcaV1';
d_enum_AuthMethod(2) -> 'AuthMethodAthens';
d_enum_AuthMethod(V) -> V.

'd_enum_CommandSubscribe.SubType'(0) -> 'Exclusive';
'd_enum_CommandSubscribe.SubType'(1) -> 'Shared';
'd_enum_CommandSubscribe.SubType'(2) -> 'Failover';
'd_enum_CommandSubscribe.SubType'(3) -> 'Key_Shared';
'd_enum_CommandSubscribe.SubType'(V) -> V.

'd_enum_CommandSubscribe.InitialPosition'(0) ->
  'Latest';
'd_enum_CommandSubscribe.InitialPosition'(1) ->
  'Earliest';
'd_enum_CommandSubscribe.InitialPosition'(V) -> V.

'd_enum_CommandPartitionedTopicMetadataResponse.LookupType'(0) ->
  'Success';
'd_enum_CommandPartitionedTopicMetadataResponse.LookupType'(1) ->
  'Failed';
'd_enum_CommandPartitionedTopicMetadataResponse.LookupType'(V) ->
  V.

'd_enum_CommandLookupTopicResponse.LookupType'(0) ->
  'Redirect';
'd_enum_CommandLookupTopicResponse.LookupType'(1) ->
  'Connect';
'd_enum_CommandLookupTopicResponse.LookupType'(2) ->
  'Failed';
'd_enum_CommandLookupTopicResponse.LookupType'(V) -> V.

'd_enum_CommandAck.AckType'(0) -> 'Individual';
'd_enum_CommandAck.AckType'(1) -> 'Cumulative';
'd_enum_CommandAck.AckType'(V) -> V.

'd_enum_CommandAck.ValidationError'(0) ->
  'UncompressedSizeCorruption';
'd_enum_CommandAck.ValidationError'(1) ->
  'DecompressionError';
'd_enum_CommandAck.ValidationError'(2) ->
  'ChecksumMismatch';
'd_enum_CommandAck.ValidationError'(3) ->
  'BatchDeSerializeError';
'd_enum_CommandAck.ValidationError'(4) ->
  'DecryptionError';
'd_enum_CommandAck.ValidationError'(V) -> V.

'd_enum_CommandGetTopicsOfNamespace.Mode'(0) ->
  'PERSISTENT';
'd_enum_CommandGetTopicsOfNamespace.Mode'(1) ->
  'NON_PERSISTENT';
'd_enum_CommandGetTopicsOfNamespace.Mode'(2) -> 'ALL';
'd_enum_CommandGetTopicsOfNamespace.Mode'(V) -> V.

'd_enum_BaseCommand.Type'(2) -> 'CONNECT';
'd_enum_BaseCommand.Type'(3) -> 'CONNECTED';
'd_enum_BaseCommand.Type'(4) -> 'SUBSCRIBE';
'd_enum_BaseCommand.Type'(5) -> 'PRODUCER';
'd_enum_BaseCommand.Type'(6) -> 'SEND';
'd_enum_BaseCommand.Type'(7) -> 'SEND_RECEIPT';
'd_enum_BaseCommand.Type'(8) -> 'SEND_ERROR';
'd_enum_BaseCommand.Type'(9) -> 'MESSAGE';
'd_enum_BaseCommand.Type'(10) -> 'ACK';
'd_enum_BaseCommand.Type'(11) -> 'FLOW';
'd_enum_BaseCommand.Type'(12) -> 'UNSUBSCRIBE';
'd_enum_BaseCommand.Type'(13) -> 'SUCCESS';
'd_enum_BaseCommand.Type'(14) -> 'ERROR';
'd_enum_BaseCommand.Type'(15) -> 'CLOSE_PRODUCER';
'd_enum_BaseCommand.Type'(16) -> 'CLOSE_CONSUMER';
'd_enum_BaseCommand.Type'(17) -> 'PRODUCER_SUCCESS';
'd_enum_BaseCommand.Type'(18) -> 'PING';
'd_enum_BaseCommand.Type'(19) -> 'PONG';
'd_enum_BaseCommand.Type'(20) ->
  'REDELIVER_UNACKNOWLEDGED_MESSAGES';
'd_enum_BaseCommand.Type'(21) -> 'PARTITIONED_METADATA';
'd_enum_BaseCommand.Type'(22) ->
  'PARTITIONED_METADATA_RESPONSE';
'd_enum_BaseCommand.Type'(23) -> 'LOOKUP';
'd_enum_BaseCommand.Type'(24) -> 'LOOKUP_RESPONSE';
'd_enum_BaseCommand.Type'(25) -> 'CONSUMER_STATS';
'd_enum_BaseCommand.Type'(26) ->
  'CONSUMER_STATS_RESPONSE';
'd_enum_BaseCommand.Type'(27) -> 'REACHED_END_OF_TOPIC';
'd_enum_BaseCommand.Type'(28) -> 'SEEK';
'd_enum_BaseCommand.Type'(29) -> 'GET_LAST_MESSAGE_ID';
'd_enum_BaseCommand.Type'(30) ->
  'GET_LAST_MESSAGE_ID_RESPONSE';
'd_enum_BaseCommand.Type'(31) ->
  'ACTIVE_CONSUMER_CHANGE';
'd_enum_BaseCommand.Type'(32) ->
  'GET_TOPICS_OF_NAMESPACE';
'd_enum_BaseCommand.Type'(33) ->
  'GET_TOPICS_OF_NAMESPACE_RESPONSE';
'd_enum_BaseCommand.Type'(34) -> 'GET_SCHEMA';
'd_enum_BaseCommand.Type'(35) -> 'GET_SCHEMA_RESPONSE';
'd_enum_BaseCommand.Type'(36) -> 'AUTH_CHALLENGE';
'd_enum_BaseCommand.Type'(37) -> 'AUTH_RESPONSE';
'd_enum_BaseCommand.Type'(V) -> V.

read_group(Bin, FieldNum) ->
  {NumBytes, EndTagLen} = read_gr_b(Bin,
    0,
    0,
    0,
    0,
    FieldNum),
  <<Group:NumBytes/binary, _:EndTagLen/binary,
    Rest/binary>> =
    Bin,
  {Group, Rest}.

read_gr_b(<<1:1, X:7, Tl/binary>>, N, Acc, NumBytes,
    TagLen, FieldNum)
  when N < 32 - 7 ->
  read_gr_b(Tl,
    N + 7,
    X bsl N + Acc,
    NumBytes,
    TagLen + 1,
    FieldNum);
read_gr_b(<<0:1, X:7, Tl/binary>>, N, Acc, NumBytes,
    TagLen, FieldNum) ->
  Key = X bsl N + Acc,
  TagLen1 = TagLen + 1,
  case {Key bsr 3, Key band 7} of
    {FieldNum, 4} -> {NumBytes, TagLen1};
    {_, 0} ->
      read_gr_vi(Tl, 0, NumBytes + TagLen1, FieldNum);
    {_, 1} ->
      <<_:64, Tl2/binary>> = Tl,
      read_gr_b(Tl2,
        0,
        0,
        NumBytes + TagLen1 + 8,
        0,
        FieldNum);
    {_, 2} ->
      read_gr_ld(Tl, 0, 0, NumBytes + TagLen1, FieldNum);
    {_, 3} ->
      read_gr_b(Tl, 0, 0, NumBytes + TagLen1, 0, FieldNum);
    {_, 4} ->
      read_gr_b(Tl, 0, 0, NumBytes + TagLen1, 0, FieldNum);
    {_, 5} ->
      <<_:32, Tl2/binary>> = Tl,
      read_gr_b(Tl2,
        0,
        0,
        NumBytes + TagLen1 + 4,
        0,
        FieldNum)
  end.

read_gr_vi(<<1:1, _:7, Tl/binary>>, N, NumBytes,
    FieldNum)
  when N < 64 - 7 ->
  read_gr_vi(Tl, N + 7, NumBytes + 1, FieldNum);
read_gr_vi(<<0:1, _:7, Tl/binary>>, _, NumBytes,
    FieldNum) ->
  read_gr_b(Tl, 0, 0, NumBytes + 1, 0, FieldNum).

read_gr_ld(<<1:1, X:7, Tl/binary>>, N, Acc, NumBytes,
    FieldNum)
  when N < 64 - 7 ->
  read_gr_ld(Tl,
    N + 7,
    X bsl N + Acc,
    NumBytes + 1,
    FieldNum);
read_gr_ld(<<0:1, X:7, Tl/binary>>, N, Acc, NumBytes,
    FieldNum) ->
  Len = X bsl N + Acc,
  NumBytes1 = NumBytes + 1,
  <<_:Len/binary, Tl2/binary>> = Tl,
  read_gr_b(Tl2, 0, 0, NumBytes1 + Len, 0, FieldNum).

merge_msgs(Prev, New, MsgName) when is_atom(MsgName) ->
  merge_msgs(Prev, New, MsgName, []).

merge_msgs(Prev, New, MsgName, Opts) ->
  TrUserData = proplists:get_value(user_data, Opts),
  case MsgName of
    'Schema' -> merge_msg_Schema(Prev, New, TrUserData);
    'MessageIdData' ->
      merge_msg_MessageIdData(Prev, New, TrUserData);
    'KeyValue' -> merge_msg_KeyValue(Prev, New, TrUserData);
    'KeyLongValue' ->
      merge_msg_KeyLongValue(Prev, New, TrUserData);
    'EncryptionKeys' ->
      merge_msg_EncryptionKeys(Prev, New, TrUserData);
    'MessageMetadata' ->
      merge_msg_MessageMetadata(Prev, New, TrUserData);
    'SingleMessageMetadata' ->
      merge_msg_SingleMessageMetadata(Prev, New, TrUserData);
    'CommandConnect' ->
      merge_msg_CommandConnect(Prev, New, TrUserData);
    'CommandConnected' ->
      merge_msg_CommandConnected(Prev, New, TrUserData);
    'CommandAuthResponse' ->
      merge_msg_CommandAuthResponse(Prev, New, TrUserData);
    'CommandAuthChallenge' ->
      merge_msg_CommandAuthChallenge(Prev, New, TrUserData);
    'AuthData' -> merge_msg_AuthData(Prev, New, TrUserData);
    'CommandSubscribe' ->
      merge_msg_CommandSubscribe(Prev, New, TrUserData);
    'CommandPartitionedTopicMetadata' ->
      merge_msg_CommandPartitionedTopicMetadata(Prev,
        New,
        TrUserData);
    'CommandPartitionedTopicMetadataResponse' ->
      merge_msg_CommandPartitionedTopicMetadataResponse(Prev,
        New,
        TrUserData);
    'CommandLookupTopic' ->
      merge_msg_CommandLookupTopic(Prev, New, TrUserData);
    'CommandLookupTopicResponse' ->
      merge_msg_CommandLookupTopicResponse(Prev,
        New,
        TrUserData);
    'CommandProducer' ->
      merge_msg_CommandProducer(Prev, New, TrUserData);
    'CommandSend' ->
      merge_msg_CommandSend(Prev, New, TrUserData);
    'CommandSendReceipt' ->
      merge_msg_CommandSendReceipt(Prev, New, TrUserData);
    'CommandSendError' ->
      merge_msg_CommandSendError(Prev, New, TrUserData);
    'CommandMessage' ->
      merge_msg_CommandMessage(Prev, New, TrUserData);
    'CommandAck' ->
      merge_msg_CommandAck(Prev, New, TrUserData);
    'CommandActiveConsumerChange' ->
      merge_msg_CommandActiveConsumerChange(Prev,
        New,
        TrUserData);
    'CommandFlow' ->
      merge_msg_CommandFlow(Prev, New, TrUserData);
    'CommandUnsubscribe' ->
      merge_msg_CommandUnsubscribe(Prev, New, TrUserData);
    'CommandSeek' ->
      merge_msg_CommandSeek(Prev, New, TrUserData);
    'CommandReachedEndOfTopic' ->
      merge_msg_CommandReachedEndOfTopic(Prev,
        New,
        TrUserData);
    'CommandCloseProducer' ->
      merge_msg_CommandCloseProducer(Prev, New, TrUserData);
    'CommandCloseConsumer' ->
      merge_msg_CommandCloseConsumer(Prev, New, TrUserData);
    'CommandRedeliverUnacknowledgedMessages' ->
      merge_msg_CommandRedeliverUnacknowledgedMessages(Prev,
        New,
        TrUserData);
    'CommandSuccess' ->
      merge_msg_CommandSuccess(Prev, New, TrUserData);
    'CommandProducerSuccess' ->
      merge_msg_CommandProducerSuccess(Prev, New, TrUserData);
    'CommandError' ->
      merge_msg_CommandError(Prev, New, TrUserData);
    'CommandPing' ->
      merge_msg_CommandPing(Prev, New, TrUserData);
    'CommandPong' ->
      merge_msg_CommandPong(Prev, New, TrUserData);
    'CommandConsumerStats' ->
      merge_msg_CommandConsumerStats(Prev, New, TrUserData);
    'CommandConsumerStatsResponse' ->
      merge_msg_CommandConsumerStatsResponse(Prev,
        New,
        TrUserData);
    'CommandGetLastMessageId' ->
      merge_msg_CommandGetLastMessageId(Prev,
        New,
        TrUserData);
    'CommandGetLastMessageIdResponse' ->
      merge_msg_CommandGetLastMessageIdResponse(Prev,
        New,
        TrUserData);
    'CommandGetTopicsOfNamespace' ->
      merge_msg_CommandGetTopicsOfNamespace(Prev,
        New,
        TrUserData);
    'CommandGetTopicsOfNamespaceResponse' ->
      merge_msg_CommandGetTopicsOfNamespaceResponse(Prev,
        New,
        TrUserData);
    'CommandGetSchema' ->
      merge_msg_CommandGetSchema(Prev, New, TrUserData);
    'CommandGetSchemaResponse' ->
      merge_msg_CommandGetSchemaResponse(Prev,
        New,
        TrUserData);
    'BaseCommand' ->
      merge_msg_BaseCommand(Prev, New, TrUserData)
  end.

-compile({nowarn_unused_function,
  {merge_msg_Schema, 3}}).

merge_msg_Schema(#{} = PMsg,
    #{name := NFname, schema_data := NFschema_data,
      type := NFtype} =
      NMsg,
    TrUserData) ->
  S1 = #{name => NFname, schema_data => NFschema_data,
    type => NFtype},
  case {PMsg, NMsg} of
    {#{properties := PFproperties},
      #{properties := NFproperties}} ->
      S1#{properties =>
      'erlang_++'(PFproperties, NFproperties, TrUserData)};
    {_, #{properties := NFproperties}} ->
      S1#{properties => NFproperties};
    {#{properties := PFproperties}, _} ->
      S1#{properties => PFproperties};
    {_, _} -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_MessageIdData, 3}}).

merge_msg_MessageIdData(#{} = PMsg,
    #{ledgerId := NFledgerId, entryId := NFentryId} = NMsg,
    _) ->
  S1 = #{ledgerId => NFledgerId, entryId => NFentryId},
  S2 = case {PMsg, NMsg} of
         {_, #{partition := NFpartition}} ->
           S1#{partition => NFpartition};
         {#{partition := PFpartition}, _} ->
           S1#{partition => PFpartition};
         _ -> S1
       end,
  case {PMsg, NMsg} of
    {_, #{batch_index := NFbatch_index}} ->
      S2#{batch_index => NFbatch_index};
    {#{batch_index := PFbatch_index}, _} ->
      S2#{batch_index => PFbatch_index};
    _ -> S2
  end.

-compile({nowarn_unused_function,
  {merge_msg_KeyValue, 3}}).

merge_msg_KeyValue(#{},
    #{key := NFkey, value := NFvalue}, _) ->
  #{key => NFkey, value => NFvalue}.

-compile({nowarn_unused_function,
  {merge_msg_KeyLongValue, 3}}).

merge_msg_KeyLongValue(#{},
    #{key := NFkey, value := NFvalue}, _) ->
  #{key => NFkey, value => NFvalue}.

-compile({nowarn_unused_function,
  {merge_msg_EncryptionKeys, 3}}).

merge_msg_EncryptionKeys(#{} = PMsg,
    #{key := NFkey, value := NFvalue} = NMsg,
    TrUserData) ->
  S1 = #{key => NFkey, value => NFvalue},
  case {PMsg, NMsg} of
    {#{metadata := PFmetadata},
      #{metadata := NFmetadata}} ->
      S1#{metadata =>
      'erlang_++'(PFmetadata, NFmetadata, TrUserData)};
    {_, #{metadata := NFmetadata}} ->
      S1#{metadata => NFmetadata};
    {#{metadata := PFmetadata}, _} ->
      S1#{metadata => PFmetadata};
    {_, _} -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_MessageMetadata, 3}}).

merge_msg_MessageMetadata(#{} = PMsg,
    #{producer_name := NFproducer_name,
      sequence_id := NFsequence_id,
      publish_time := NFpublish_time} =
      NMsg,
    TrUserData) ->
  S1 = #{producer_name => NFproducer_name,
    sequence_id => NFsequence_id,
    publish_time => NFpublish_time},
  S2 = case {PMsg, NMsg} of
         {#{properties := PFproperties},
           #{properties := NFproperties}} ->
           S1#{properties =>
           'erlang_++'(PFproperties, NFproperties, TrUserData)};
         {_, #{properties := NFproperties}} ->
           S1#{properties => NFproperties};
         {#{properties := PFproperties}, _} ->
           S1#{properties => PFproperties};
         {_, _} -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{replicated_from := NFreplicated_from}} ->
           S2#{replicated_from => NFreplicated_from};
         {#{replicated_from := PFreplicated_from}, _} ->
           S2#{replicated_from => PFreplicated_from};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{partition_key := NFpartition_key}} ->
           S3#{partition_key => NFpartition_key};
         {#{partition_key := PFpartition_key}, _} ->
           S3#{partition_key => PFpartition_key};
         _ -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {#{replicate_to := PFreplicate_to},
           #{replicate_to := NFreplicate_to}} ->
           S4#{replicate_to =>
           'erlang_++'(PFreplicate_to,
             NFreplicate_to,
             TrUserData)};
         {_, #{replicate_to := NFreplicate_to}} ->
           S4#{replicate_to => NFreplicate_to};
         {#{replicate_to := PFreplicate_to}, _} ->
           S4#{replicate_to => PFreplicate_to};
         {_, _} -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {_, #{compression := NFcompression}} ->
           S5#{compression => NFcompression};
         {#{compression := PFcompression}, _} ->
           S5#{compression => PFcompression};
         _ -> S5
       end,
  S7 = case {PMsg, NMsg} of
         {_, #{uncompressed_size := NFuncompressed_size}} ->
           S6#{uncompressed_size => NFuncompressed_size};
         {#{uncompressed_size := PFuncompressed_size}, _} ->
           S6#{uncompressed_size => PFuncompressed_size};
         _ -> S6
       end,
  S8 = case {PMsg, NMsg} of
         {_,
           #{num_messages_in_batch := NFnum_messages_in_batch}} ->
           S7#{num_messages_in_batch => NFnum_messages_in_batch};
         {#{num_messages_in_batch := PFnum_messages_in_batch},
           _} ->
           S7#{num_messages_in_batch => PFnum_messages_in_batch};
         _ -> S7
       end,
  S9 = case {PMsg, NMsg} of
         {_, #{event_time := NFevent_time}} ->
           S8#{event_time => NFevent_time};
         {#{event_time := PFevent_time}, _} ->
           S8#{event_time => PFevent_time};
         _ -> S8
       end,
  S10 = case {PMsg, NMsg} of
          {#{encryption_keys := PFencryption_keys},
            #{encryption_keys := NFencryption_keys}} ->
            S9#{encryption_keys =>
            'erlang_++'(PFencryption_keys,
              NFencryption_keys,
              TrUserData)};
          {_, #{encryption_keys := NFencryption_keys}} ->
            S9#{encryption_keys => NFencryption_keys};
          {#{encryption_keys := PFencryption_keys}, _} ->
            S9#{encryption_keys => PFencryption_keys};
          {_, _} -> S9
        end,
  S11 = case {PMsg, NMsg} of
          {_, #{encryption_algo := NFencryption_algo}} ->
            S10#{encryption_algo => NFencryption_algo};
          {#{encryption_algo := PFencryption_algo}, _} ->
            S10#{encryption_algo => PFencryption_algo};
          _ -> S10
        end,
  S12 = case {PMsg, NMsg} of
          {_, #{encryption_param := NFencryption_param}} ->
            S11#{encryption_param => NFencryption_param};
          {#{encryption_param := PFencryption_param}, _} ->
            S11#{encryption_param => PFencryption_param};
          _ -> S11
        end,
  S13 = case {PMsg, NMsg} of
          {_, #{schema_version := NFschema_version}} ->
            S12#{schema_version => NFschema_version};
          {#{schema_version := PFschema_version}, _} ->
            S12#{schema_version => PFschema_version};
          _ -> S12
        end,
  S14 = case {PMsg, NMsg} of
          {_,
            #{partition_key_b64_encoded :=
            NFpartition_key_b64_encoded}} ->
            S13#{partition_key_b64_encoded =>
            NFpartition_key_b64_encoded};
          {#{partition_key_b64_encoded :=
          PFpartition_key_b64_encoded},
            _} ->
            S13#{partition_key_b64_encoded =>
            PFpartition_key_b64_encoded};
          _ -> S13
        end,
  case {PMsg, NMsg} of
    {_, #{ordering_key := NFordering_key}} ->
      S14#{ordering_key => NFordering_key};
    {#{ordering_key := PFordering_key}, _} ->
      S14#{ordering_key => PFordering_key};
    _ -> S14
  end.

-compile({nowarn_unused_function,
  {merge_msg_SingleMessageMetadata, 3}}).

merge_msg_SingleMessageMetadata(#{} = PMsg,
    #{payload_size := NFpayload_size} = NMsg,
    TrUserData) ->
  S1 = #{payload_size => NFpayload_size},
  S2 = case {PMsg, NMsg} of
         {#{properties := PFproperties},
           #{properties := NFproperties}} ->
           S1#{properties =>
           'erlang_++'(PFproperties, NFproperties, TrUserData)};
         {_, #{properties := NFproperties}} ->
           S1#{properties => NFproperties};
         {#{properties := PFproperties}, _} ->
           S1#{properties => PFproperties};
         {_, _} -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{partition_key := NFpartition_key}} ->
           S2#{partition_key => NFpartition_key};
         {#{partition_key := PFpartition_key}, _} ->
           S2#{partition_key => PFpartition_key};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{compacted_out := NFcompacted_out}} ->
           S3#{compacted_out => NFcompacted_out};
         {#{compacted_out := PFcompacted_out}, _} ->
           S3#{compacted_out => PFcompacted_out};
         _ -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {_, #{event_time := NFevent_time}} ->
           S4#{event_time => NFevent_time};
         {#{event_time := PFevent_time}, _} ->
           S4#{event_time => PFevent_time};
         _ -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {_,
           #{partition_key_b64_encoded :=
           NFpartition_key_b64_encoded}} ->
           S5#{partition_key_b64_encoded =>
           NFpartition_key_b64_encoded};
         {#{partition_key_b64_encoded :=
         PFpartition_key_b64_encoded},
           _} ->
           S5#{partition_key_b64_encoded =>
           PFpartition_key_b64_encoded};
         _ -> S5
       end,
  case {PMsg, NMsg} of
    {_, #{ordering_key := NFordering_key}} ->
      S6#{ordering_key => NFordering_key};
    {#{ordering_key := PFordering_key}, _} ->
      S6#{ordering_key => PFordering_key};
    _ -> S6
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandConnect, 3}}).

merge_msg_CommandConnect(#{} = PMsg,
    #{client_version := NFclient_version} = NMsg, _) ->
  S1 = #{client_version => NFclient_version},
  S2 = case {PMsg, NMsg} of
         {_, #{auth_method := NFauth_method}} ->
           S1#{auth_method => NFauth_method};
         {#{auth_method := PFauth_method}, _} ->
           S1#{auth_method => PFauth_method};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{auth_method_name := NFauth_method_name}} ->
           S2#{auth_method_name => NFauth_method_name};
         {#{auth_method_name := PFauth_method_name}, _} ->
           S2#{auth_method_name => PFauth_method_name};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{auth_data := NFauth_data}} ->
           S3#{auth_data => NFauth_data};
         {#{auth_data := PFauth_data}, _} ->
           S3#{auth_data => PFauth_data};
         _ -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {_, #{protocol_version := NFprotocol_version}} ->
           S4#{protocol_version => NFprotocol_version};
         {#{protocol_version := PFprotocol_version}, _} ->
           S4#{protocol_version => PFprotocol_version};
         _ -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {_, #{proxy_to_broker_url := NFproxy_to_broker_url}} ->
           S5#{proxy_to_broker_url => NFproxy_to_broker_url};
         {#{proxy_to_broker_url := PFproxy_to_broker_url}, _} ->
           S5#{proxy_to_broker_url => PFproxy_to_broker_url};
         _ -> S5
       end,
  S7 = case {PMsg, NMsg} of
         {_, #{original_principal := NForiginal_principal}} ->
           S6#{original_principal => NForiginal_principal};
         {#{original_principal := PForiginal_principal}, _} ->
           S6#{original_principal => PForiginal_principal};
         _ -> S6
       end,
  S8 = case {PMsg, NMsg} of
         {_, #{original_auth_data := NForiginal_auth_data}} ->
           S7#{original_auth_data => NForiginal_auth_data};
         {#{original_auth_data := PForiginal_auth_data}, _} ->
           S7#{original_auth_data => PForiginal_auth_data};
         _ -> S7
       end,
  case {PMsg, NMsg} of
    {_,
      #{original_auth_method := NForiginal_auth_method}} ->
      S8#{original_auth_method => NForiginal_auth_method};
    {#{original_auth_method := PForiginal_auth_method},
      _} ->
      S8#{original_auth_method => PForiginal_auth_method};
    _ -> S8
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandConnected, 3}}).

merge_msg_CommandConnected(#{} = PMsg,
    #{server_version := NFserver_version} = NMsg, _) ->
  S1 = #{server_version => NFserver_version},
  case {PMsg, NMsg} of
    {_, #{protocol_version := NFprotocol_version}} ->
      S1#{protocol_version => NFprotocol_version};
    {#{protocol_version := PFprotocol_version}, _} ->
      S1#{protocol_version => PFprotocol_version};
    _ -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandAuthResponse, 3}}).

merge_msg_CommandAuthResponse(PMsg, NMsg, TrUserData) ->
  S1 = #{},
  S2 = case {PMsg, NMsg} of
         {_, #{client_version := NFclient_version}} ->
           S1#{client_version => NFclient_version};
         {#{client_version := PFclient_version}, _} ->
           S1#{client_version => PFclient_version};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {#{response := PFresponse},
           #{response := NFresponse}} ->
           S2#{response =>
           merge_msg_AuthData(PFresponse,
             NFresponse,
             TrUserData)};
         {_, #{response := NFresponse}} ->
           S2#{response => NFresponse};
         {#{response := PFresponse}, _} ->
           S2#{response => PFresponse};
         {_, _} -> S2
       end,
  case {PMsg, NMsg} of
    {_, #{protocol_version := NFprotocol_version}} ->
      S3#{protocol_version => NFprotocol_version};
    {#{protocol_version := PFprotocol_version}, _} ->
      S3#{protocol_version => PFprotocol_version};
    _ -> S3
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandAuthChallenge, 3}}).

merge_msg_CommandAuthChallenge(PMsg, NMsg,
    TrUserData) ->
  S1 = #{},
  S2 = case {PMsg, NMsg} of
         {_, #{server_version := NFserver_version}} ->
           S1#{server_version => NFserver_version};
         {#{server_version := PFserver_version}, _} ->
           S1#{server_version => PFserver_version};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {#{challenge := PFchallenge},
           #{challenge := NFchallenge}} ->
           S2#{challenge =>
           merge_msg_AuthData(PFchallenge,
             NFchallenge,
             TrUserData)};
         {_, #{challenge := NFchallenge}} ->
           S2#{challenge => NFchallenge};
         {#{challenge := PFchallenge}, _} ->
           S2#{challenge => PFchallenge};
         {_, _} -> S2
       end,
  case {PMsg, NMsg} of
    {_, #{protocol_version := NFprotocol_version}} ->
      S3#{protocol_version => NFprotocol_version};
    {#{protocol_version := PFprotocol_version}, _} ->
      S3#{protocol_version => PFprotocol_version};
    _ -> S3
  end.

-compile({nowarn_unused_function,
  {merge_msg_AuthData, 3}}).

merge_msg_AuthData(PMsg, NMsg, _) ->
  S1 = #{},
  S2 = case {PMsg, NMsg} of
         {_, #{auth_method_name := NFauth_method_name}} ->
           S1#{auth_method_name => NFauth_method_name};
         {#{auth_method_name := PFauth_method_name}, _} ->
           S1#{auth_method_name => PFauth_method_name};
         _ -> S1
       end,
  case {PMsg, NMsg} of
    {_, #{auth_data := NFauth_data}} ->
      S2#{auth_data => NFauth_data};
    {#{auth_data := PFauth_data}, _} ->
      S2#{auth_data => PFauth_data};
    _ -> S2
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandSubscribe, 3}}).

merge_msg_CommandSubscribe(#{} = PMsg,
    #{topic := NFtopic, subscription := NFsubscription,
      subType := NFsubType, consumer_id := NFconsumer_id,
      request_id := NFrequest_id} =
      NMsg,
    TrUserData) ->
  S1 = #{topic => NFtopic, subscription => NFsubscription,
    subType => NFsubType, consumer_id => NFconsumer_id,
    request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{consumer_name := NFconsumer_name}} ->
           S1#{consumer_name => NFconsumer_name};
         {#{consumer_name := PFconsumer_name}, _} ->
           S1#{consumer_name => PFconsumer_name};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{priority_level := NFpriority_level}} ->
           S2#{priority_level => NFpriority_level};
         {#{priority_level := PFpriority_level}, _} ->
           S2#{priority_level => PFpriority_level};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{durable := NFdurable}} ->
           S3#{durable => NFdurable};
         {#{durable := PFdurable}, _} ->
           S3#{durable => PFdurable};
         _ -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {#{start_message_id := PFstart_message_id},
           #{start_message_id := NFstart_message_id}} ->
           S4#{start_message_id =>
           merge_msg_MessageIdData(PFstart_message_id,
             NFstart_message_id,
             TrUserData)};
         {_, #{start_message_id := NFstart_message_id}} ->
           S4#{start_message_id => NFstart_message_id};
         {#{start_message_id := PFstart_message_id}, _} ->
           S4#{start_message_id => PFstart_message_id};
         {_, _} -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {#{metadata := PFmetadata},
           #{metadata := NFmetadata}} ->
           S5#{metadata =>
           'erlang_++'(PFmetadata, NFmetadata, TrUserData)};
         {_, #{metadata := NFmetadata}} ->
           S5#{metadata => NFmetadata};
         {#{metadata := PFmetadata}, _} ->
           S5#{metadata => PFmetadata};
         {_, _} -> S5
       end,
  S7 = case {PMsg, NMsg} of
         {_, #{read_compacted := NFread_compacted}} ->
           S6#{read_compacted => NFread_compacted};
         {#{read_compacted := PFread_compacted}, _} ->
           S6#{read_compacted => PFread_compacted};
         _ -> S6
       end,
  S8 = case {PMsg, NMsg} of
         {#{schema := PFschema}, #{schema := NFschema}} ->
           S7#{schema =>
           merge_msg_Schema(PFschema, NFschema, TrUserData)};
         {_, #{schema := NFschema}} -> S7#{schema => NFschema};
         {#{schema := PFschema}, _} -> S7#{schema => PFschema};
         {_, _} -> S7
       end,
  case {PMsg, NMsg} of
    {_, #{initialPosition := NFinitialPosition}} ->
      S8#{initialPosition => NFinitialPosition};
    {#{initialPosition := PFinitialPosition}, _} ->
      S8#{initialPosition => PFinitialPosition};
    _ -> S8
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandPartitionedTopicMetadata, 3}}).

merge_msg_CommandPartitionedTopicMetadata(#{} = PMsg,
    #{topic := NFtopic,
      request_id := NFrequest_id} =
      NMsg,
    _) ->
  S1 = #{topic => NFtopic, request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{original_principal := NForiginal_principal}} ->
           S1#{original_principal => NForiginal_principal};
         {#{original_principal := PForiginal_principal}, _} ->
           S1#{original_principal => PForiginal_principal};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{original_auth_data := NForiginal_auth_data}} ->
           S2#{original_auth_data => NForiginal_auth_data};
         {#{original_auth_data := PForiginal_auth_data}, _} ->
           S2#{original_auth_data => PForiginal_auth_data};
         _ -> S2
       end,
  case {PMsg, NMsg} of
    {_,
      #{original_auth_method := NForiginal_auth_method}} ->
      S3#{original_auth_method => NForiginal_auth_method};
    {#{original_auth_method := PForiginal_auth_method},
      _} ->
      S3#{original_auth_method => PForiginal_auth_method};
    _ -> S3
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandPartitionedTopicMetadataResponse,
    3}}).

merge_msg_CommandPartitionedTopicMetadataResponse(#{} =
  PMsg,
    #{request_id :=
    NFrequest_id} =
      NMsg,
    _) ->
  S1 = #{request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{partitions := NFpartitions}} ->
           S1#{partitions => NFpartitions};
         {#{partitions := PFpartitions}, _} ->
           S1#{partitions => PFpartitions};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{response := NFresponse}} ->
           S2#{response => NFresponse};
         {#{response := PFresponse}, _} ->
           S2#{response => PFresponse};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{error := NFerror}} -> S3#{error => NFerror};
         {#{error := PFerror}, _} -> S3#{error => PFerror};
         _ -> S3
       end,
  case {PMsg, NMsg} of
    {_, #{message := NFmessage}} ->
      S4#{message => NFmessage};
    {#{message := PFmessage}, _} ->
      S4#{message => PFmessage};
    _ -> S4
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandLookupTopic, 3}}).

merge_msg_CommandLookupTopic(#{} = PMsg,
    #{topic := NFtopic, request_id := NFrequest_id} =
      NMsg,
    _) ->
  S1 = #{topic => NFtopic, request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{authoritative := NFauthoritative}} ->
           S1#{authoritative => NFauthoritative};
         {#{authoritative := PFauthoritative}, _} ->
           S1#{authoritative => PFauthoritative};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{original_principal := NForiginal_principal}} ->
           S2#{original_principal => NForiginal_principal};
         {#{original_principal := PForiginal_principal}, _} ->
           S2#{original_principal => PForiginal_principal};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{original_auth_data := NForiginal_auth_data}} ->
           S3#{original_auth_data => NForiginal_auth_data};
         {#{original_auth_data := PForiginal_auth_data}, _} ->
           S3#{original_auth_data => PForiginal_auth_data};
         _ -> S3
       end,
  case {PMsg, NMsg} of
    {_,
      #{original_auth_method := NForiginal_auth_method}} ->
      S4#{original_auth_method => NForiginal_auth_method};
    {#{original_auth_method := PForiginal_auth_method},
      _} ->
      S4#{original_auth_method => PForiginal_auth_method};
    _ -> S4
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandLookupTopicResponse, 3}}).

merge_msg_CommandLookupTopicResponse(#{} = PMsg,
    #{request_id := NFrequest_id} = NMsg, _) ->
  S1 = #{request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{brokerServiceUrl := NFbrokerServiceUrl}} ->
           S1#{brokerServiceUrl => NFbrokerServiceUrl};
         {#{brokerServiceUrl := PFbrokerServiceUrl}, _} ->
           S1#{brokerServiceUrl => PFbrokerServiceUrl};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{brokerServiceUrlTls := NFbrokerServiceUrlTls}} ->
           S2#{brokerServiceUrlTls => NFbrokerServiceUrlTls};
         {#{brokerServiceUrlTls := PFbrokerServiceUrlTls}, _} ->
           S2#{brokerServiceUrlTls => PFbrokerServiceUrlTls};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{response := NFresponse}} ->
           S3#{response => NFresponse};
         {#{response := PFresponse}, _} ->
           S3#{response => PFresponse};
         _ -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {_, #{authoritative := NFauthoritative}} ->
           S4#{authoritative => NFauthoritative};
         {#{authoritative := PFauthoritative}, _} ->
           S4#{authoritative => PFauthoritative};
         _ -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {_, #{error := NFerror}} -> S5#{error => NFerror};
         {#{error := PFerror}, _} -> S5#{error => PFerror};
         _ -> S5
       end,
  S7 = case {PMsg, NMsg} of
         {_, #{message := NFmessage}} ->
           S6#{message => NFmessage};
         {#{message := PFmessage}, _} ->
           S6#{message => PFmessage};
         _ -> S6
       end,
  case {PMsg, NMsg} of
    {_,
      #{proxy_through_service_url :=
      NFproxy_through_service_url}} ->
      S7#{proxy_through_service_url =>
      NFproxy_through_service_url};
    {#{proxy_through_service_url :=
    PFproxy_through_service_url},
      _} ->
      S7#{proxy_through_service_url =>
      PFproxy_through_service_url};
    _ -> S7
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandProducer, 3}}).

merge_msg_CommandProducer(#{} = PMsg,
    #{topic := NFtopic, producer_id := NFproducer_id,
      request_id := NFrequest_id} =
      NMsg,
    TrUserData) ->
  S1 = #{topic => NFtopic, producer_id => NFproducer_id,
    request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{producer_name := NFproducer_name}} ->
           S1#{producer_name => NFproducer_name};
         {#{producer_name := PFproducer_name}, _} ->
           S1#{producer_name => PFproducer_name};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{encrypted := NFencrypted}} ->
           S2#{encrypted => NFencrypted};
         {#{encrypted := PFencrypted}, _} ->
           S2#{encrypted => PFencrypted};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {#{metadata := PFmetadata},
           #{metadata := NFmetadata}} ->
           S3#{metadata =>
           'erlang_++'(PFmetadata, NFmetadata, TrUserData)};
         {_, #{metadata := NFmetadata}} ->
           S3#{metadata => NFmetadata};
         {#{metadata := PFmetadata}, _} ->
           S3#{metadata => PFmetadata};
         {_, _} -> S3
       end,
  case {PMsg, NMsg} of
    {#{schema := PFschema}, #{schema := NFschema}} ->
      S4#{schema =>
      merge_msg_Schema(PFschema, NFschema, TrUserData)};
    {_, #{schema := NFschema}} -> S4#{schema => NFschema};
    {#{schema := PFschema}, _} -> S4#{schema => PFschema};
    {_, _} -> S4
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandSend, 3}}).

merge_msg_CommandSend(#{} = PMsg,
    #{producer_id := NFproducer_id,
      sequence_id := NFsequence_id} =
      NMsg,
    _) ->
  S1 = #{producer_id => NFproducer_id,
    sequence_id => NFsequence_id},
  case {PMsg, NMsg} of
    {_, #{num_messages := NFnum_messages}} ->
      S1#{num_messages => NFnum_messages};
    {#{num_messages := PFnum_messages}, _} ->
      S1#{num_messages => PFnum_messages};
    _ -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandSendReceipt, 3}}).

merge_msg_CommandSendReceipt(#{} = PMsg,
    #{producer_id := NFproducer_id,
      sequence_id := NFsequence_id} =
      NMsg,
    TrUserData) ->
  S1 = #{producer_id => NFproducer_id,
    sequence_id => NFsequence_id},
  case {PMsg, NMsg} of
    {#{message_id := PFmessage_id},
      #{message_id := NFmessage_id}} ->
      S1#{message_id =>
      merge_msg_MessageIdData(PFmessage_id,
        NFmessage_id,
        TrUserData)};
    {_, #{message_id := NFmessage_id}} ->
      S1#{message_id => NFmessage_id};
    {#{message_id := PFmessage_id}, _} ->
      S1#{message_id => PFmessage_id};
    {_, _} -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandSendError, 3}}).

merge_msg_CommandSendError(#{},
    #{producer_id := NFproducer_id,
      sequence_id := NFsequence_id, error := NFerror,
      message := NFmessage},
    _) ->
  #{producer_id => NFproducer_id,
    sequence_id => NFsequence_id, error => NFerror,
    message => NFmessage}.

-compile({nowarn_unused_function,
  {merge_msg_CommandMessage, 3}}).

merge_msg_CommandMessage(#{message_id := PFmessage_id} =
  PMsg,
    #{consumer_id := NFconsumer_id,
      message_id := NFmessage_id} =
      NMsg,
    TrUserData) ->
  S1 = #{consumer_id => NFconsumer_id,
    message_id =>
    merge_msg_MessageIdData(PFmessage_id,
      NFmessage_id,
      TrUserData)},
  case {PMsg, NMsg} of
    {_, #{redelivery_count := NFredelivery_count}} ->
      S1#{redelivery_count => NFredelivery_count};
    {#{redelivery_count := PFredelivery_count}, _} ->
      S1#{redelivery_count => PFredelivery_count};
    _ -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandAck, 3}}).

merge_msg_CommandAck(#{} = PMsg,
    #{consumer_id := NFconsumer_id,
      ack_type := NFack_type} =
      NMsg,
    TrUserData) ->
  S1 = #{consumer_id => NFconsumer_id,
    ack_type => NFack_type},
  S2 = case {PMsg, NMsg} of
         {#{message_id := PFmessage_id},
           #{message_id := NFmessage_id}} ->
           S1#{message_id =>
           'erlang_++'(PFmessage_id, NFmessage_id, TrUserData)};
         {_, #{message_id := NFmessage_id}} ->
           S1#{message_id => NFmessage_id};
         {#{message_id := PFmessage_id}, _} ->
           S1#{message_id => PFmessage_id};
         {_, _} -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{validation_error := NFvalidation_error}} ->
           S2#{validation_error => NFvalidation_error};
         {#{validation_error := PFvalidation_error}, _} ->
           S2#{validation_error => PFvalidation_error};
         _ -> S2
       end,
  case {PMsg, NMsg} of
    {#{properties := PFproperties},
      #{properties := NFproperties}} ->
      S3#{properties =>
      'erlang_++'(PFproperties, NFproperties, TrUserData)};
    {_, #{properties := NFproperties}} ->
      S3#{properties => NFproperties};
    {#{properties := PFproperties}, _} ->
      S3#{properties => PFproperties};
    {_, _} -> S3
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandActiveConsumerChange, 3}}).

merge_msg_CommandActiveConsumerChange(#{} = PMsg,
    #{consumer_id := NFconsumer_id} = NMsg,
    _) ->
  S1 = #{consumer_id => NFconsumer_id},
  case {PMsg, NMsg} of
    {_, #{is_active := NFis_active}} ->
      S1#{is_active => NFis_active};
    {#{is_active := PFis_active}, _} ->
      S1#{is_active => PFis_active};
    _ -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandFlow, 3}}).

merge_msg_CommandFlow(#{},
    #{consumer_id := NFconsumer_id,
      messagePermits := NFmessagePermits},
    _) ->
  #{consumer_id => NFconsumer_id,
    messagePermits => NFmessagePermits}.

-compile({nowarn_unused_function,
  {merge_msg_CommandUnsubscribe, 3}}).

merge_msg_CommandUnsubscribe(#{},
    #{consumer_id := NFconsumer_id,
      request_id := NFrequest_id},
    _) ->
  #{consumer_id => NFconsumer_id,
    request_id => NFrequest_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandSeek, 3}}).

merge_msg_CommandSeek(#{} = PMsg,
    #{consumer_id := NFconsumer_id,
      request_id := NFrequest_id} =
      NMsg,
    TrUserData) ->
  S1 = #{consumer_id => NFconsumer_id,
    request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {#{message_id := PFmessage_id},
           #{message_id := NFmessage_id}} ->
           S1#{message_id =>
           merge_msg_MessageIdData(PFmessage_id,
             NFmessage_id,
             TrUserData)};
         {_, #{message_id := NFmessage_id}} ->
           S1#{message_id => NFmessage_id};
         {#{message_id := PFmessage_id}, _} ->
           S1#{message_id => PFmessage_id};
         {_, _} -> S1
       end,
  case {PMsg, NMsg} of
    {_,
      #{message_publish_time := NFmessage_publish_time}} ->
      S2#{message_publish_time => NFmessage_publish_time};
    {#{message_publish_time := PFmessage_publish_time},
      _} ->
      S2#{message_publish_time => PFmessage_publish_time};
    _ -> S2
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandReachedEndOfTopic, 3}}).

merge_msg_CommandReachedEndOfTopic(#{},
    #{consumer_id := NFconsumer_id}, _) ->
  #{consumer_id => NFconsumer_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandCloseProducer, 3}}).

merge_msg_CommandCloseProducer(#{},
    #{producer_id := NFproducer_id,
      request_id := NFrequest_id},
    _) ->
  #{producer_id => NFproducer_id,
    request_id => NFrequest_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandCloseConsumer, 3}}).

merge_msg_CommandCloseConsumer(#{},
    #{consumer_id := NFconsumer_id,
      request_id := NFrequest_id},
    _) ->
  #{consumer_id => NFconsumer_id,
    request_id => NFrequest_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandRedeliverUnacknowledgedMessages, 3}}).

merge_msg_CommandRedeliverUnacknowledgedMessages(#{} =
  PMsg,
    #{consumer_id :=
    NFconsumer_id} =
      NMsg,
    TrUserData) ->
  S1 = #{consumer_id => NFconsumer_id},
  case {PMsg, NMsg} of
    {#{message_ids := PFmessage_ids},
      #{message_ids := NFmessage_ids}} ->
      S1#{message_ids =>
      'erlang_++'(PFmessage_ids, NFmessage_ids, TrUserData)};
    {_, #{message_ids := NFmessage_ids}} ->
      S1#{message_ids => NFmessage_ids};
    {#{message_ids := PFmessage_ids}, _} ->
      S1#{message_ids => PFmessage_ids};
    {_, _} -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandSuccess, 3}}).

merge_msg_CommandSuccess(#{} = PMsg,
    #{request_id := NFrequest_id} = NMsg, TrUserData) ->
  S1 = #{request_id => NFrequest_id},
  case {PMsg, NMsg} of
    {#{schema := PFschema}, #{schema := NFschema}} ->
      S1#{schema =>
      merge_msg_Schema(PFschema, NFschema, TrUserData)};
    {_, #{schema := NFschema}} -> S1#{schema => NFschema};
    {#{schema := PFschema}, _} -> S1#{schema => PFschema};
    {_, _} -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandProducerSuccess, 3}}).

merge_msg_CommandProducerSuccess(#{} = PMsg,
    #{request_id := NFrequest_id,
      producer_name := NFproducer_name} =
      NMsg,
    _) ->
  S1 = #{request_id => NFrequest_id,
    producer_name => NFproducer_name},
  S2 = case {PMsg, NMsg} of
         {_, #{last_sequence_id := NFlast_sequence_id}} ->
           S1#{last_sequence_id => NFlast_sequence_id};
         {#{last_sequence_id := PFlast_sequence_id}, _} ->
           S1#{last_sequence_id => PFlast_sequence_id};
         _ -> S1
       end,
  case {PMsg, NMsg} of
    {_, #{schema_version := NFschema_version}} ->
      S2#{schema_version => NFschema_version};
    {#{schema_version := PFschema_version}, _} ->
      S2#{schema_version => PFschema_version};
    _ -> S2
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandError, 3}}).

merge_msg_CommandError(#{},
    #{request_id := NFrequest_id, error := NFerror,
      message := NFmessage},
    _) ->
  #{request_id => NFrequest_id, error => NFerror,
    message => NFmessage}.

-compile({nowarn_unused_function,
  {merge_msg_CommandPing, 3}}).

merge_msg_CommandPing(_Prev, New, _TrUserData) -> New.

-compile({nowarn_unused_function,
  {merge_msg_CommandPong, 3}}).

merge_msg_CommandPong(_Prev, New, _TrUserData) -> New.

-compile({nowarn_unused_function,
  {merge_msg_CommandConsumerStats, 3}}).

merge_msg_CommandConsumerStats(#{},
    #{request_id := NFrequest_id,
      consumer_id := NFconsumer_id},
    _) ->
  #{request_id => NFrequest_id,
    consumer_id => NFconsumer_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandConsumerStatsResponse, 3}}).

merge_msg_CommandConsumerStatsResponse(#{} = PMsg,
    #{request_id := NFrequest_id} = NMsg,
    _) ->
  S1 = #{request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{error_code := NFerror_code}} ->
           S1#{error_code => NFerror_code};
         {#{error_code := PFerror_code}, _} ->
           S1#{error_code => PFerror_code};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{error_message := NFerror_message}} ->
           S2#{error_message => NFerror_message};
         {#{error_message := PFerror_message}, _} ->
           S2#{error_message => PFerror_message};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {_, #{msgRateOut := NFmsgRateOut}} ->
           S3#{msgRateOut => NFmsgRateOut};
         {#{msgRateOut := PFmsgRateOut}, _} ->
           S3#{msgRateOut => PFmsgRateOut};
         _ -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {_, #{msgThroughputOut := NFmsgThroughputOut}} ->
           S4#{msgThroughputOut => NFmsgThroughputOut};
         {#{msgThroughputOut := PFmsgThroughputOut}, _} ->
           S4#{msgThroughputOut => PFmsgThroughputOut};
         _ -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {_, #{msgRateRedeliver := NFmsgRateRedeliver}} ->
           S5#{msgRateRedeliver => NFmsgRateRedeliver};
         {#{msgRateRedeliver := PFmsgRateRedeliver}, _} ->
           S5#{msgRateRedeliver => PFmsgRateRedeliver};
         _ -> S5
       end,
  S7 = case {PMsg, NMsg} of
         {_, #{consumerName := NFconsumerName}} ->
           S6#{consumerName => NFconsumerName};
         {#{consumerName := PFconsumerName}, _} ->
           S6#{consumerName => PFconsumerName};
         _ -> S6
       end,
  S8 = case {PMsg, NMsg} of
         {_, #{availablePermits := NFavailablePermits}} ->
           S7#{availablePermits => NFavailablePermits};
         {#{availablePermits := PFavailablePermits}, _} ->
           S7#{availablePermits => PFavailablePermits};
         _ -> S7
       end,
  S9 = case {PMsg, NMsg} of
         {_, #{unackedMessages := NFunackedMessages}} ->
           S8#{unackedMessages => NFunackedMessages};
         {#{unackedMessages := PFunackedMessages}, _} ->
           S8#{unackedMessages => PFunackedMessages};
         _ -> S8
       end,
  S10 = case {PMsg, NMsg} of
          {_,
            #{blockedConsumerOnUnackedMsgs :=
            NFblockedConsumerOnUnackedMsgs}} ->
            S9#{blockedConsumerOnUnackedMsgs =>
            NFblockedConsumerOnUnackedMsgs};
          {#{blockedConsumerOnUnackedMsgs :=
          PFblockedConsumerOnUnackedMsgs},
            _} ->
            S9#{blockedConsumerOnUnackedMsgs =>
            PFblockedConsumerOnUnackedMsgs};
          _ -> S9
        end,
  S11 = case {PMsg, NMsg} of
          {_, #{address := NFaddress}} ->
            S10#{address => NFaddress};
          {#{address := PFaddress}, _} ->
            S10#{address => PFaddress};
          _ -> S10
        end,
  S12 = case {PMsg, NMsg} of
          {_, #{connectedSince := NFconnectedSince}} ->
            S11#{connectedSince => NFconnectedSince};
          {#{connectedSince := PFconnectedSince}, _} ->
            S11#{connectedSince => PFconnectedSince};
          _ -> S11
        end,
  S13 = case {PMsg, NMsg} of
          {_, #{type := NFtype}} -> S12#{type => NFtype};
          {#{type := PFtype}, _} -> S12#{type => PFtype};
          _ -> S12
        end,
  S14 = case {PMsg, NMsg} of
          {_, #{msgRateExpired := NFmsgRateExpired}} ->
            S13#{msgRateExpired => NFmsgRateExpired};
          {#{msgRateExpired := PFmsgRateExpired}, _} ->
            S13#{msgRateExpired => PFmsgRateExpired};
          _ -> S13
        end,
  case {PMsg, NMsg} of
    {_, #{msgBacklog := NFmsgBacklog}} ->
      S14#{msgBacklog => NFmsgBacklog};
    {#{msgBacklog := PFmsgBacklog}, _} ->
      S14#{msgBacklog => PFmsgBacklog};
    _ -> S14
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandGetLastMessageId, 3}}).

merge_msg_CommandGetLastMessageId(#{},
    #{consumer_id := NFconsumer_id,
      request_id := NFrequest_id},
    _) ->
  #{consumer_id => NFconsumer_id,
    request_id => NFrequest_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandGetLastMessageIdResponse, 3}}).

merge_msg_CommandGetLastMessageIdResponse(#{last_message_id
:= PFlast_message_id},
    #{last_message_id :=
    NFlast_message_id,
      request_id := NFrequest_id},
    TrUserData) ->
  #{last_message_id =>
  merge_msg_MessageIdData(PFlast_message_id,
    NFlast_message_id,
    TrUserData),
    request_id => NFrequest_id}.

-compile({nowarn_unused_function,
  {merge_msg_CommandGetTopicsOfNamespace, 3}}).

merge_msg_CommandGetTopicsOfNamespace(#{} = PMsg,
    #{request_id := NFrequest_id,
      namespace := NFnamespace} =
      NMsg,
    _) ->
  S1 = #{request_id => NFrequest_id,
    namespace => NFnamespace},
  case {PMsg, NMsg} of
    {_, #{mode := NFmode}} -> S1#{mode => NFmode};
    {#{mode := PFmode}, _} -> S1#{mode => PFmode};
    _ -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandGetTopicsOfNamespaceResponse, 3}}).

merge_msg_CommandGetTopicsOfNamespaceResponse(#{} =
  PMsg,
    #{request_id := NFrequest_id} =
      NMsg,
    TrUserData) ->
  S1 = #{request_id => NFrequest_id},
  case {PMsg, NMsg} of
    {#{topics := PFtopics}, #{topics := NFtopics}} ->
      S1#{topics =>
      'erlang_++'(PFtopics, NFtopics, TrUserData)};
    {_, #{topics := NFtopics}} -> S1#{topics => NFtopics};
    {#{topics := PFtopics}, _} -> S1#{topics => PFtopics};
    {_, _} -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandGetSchema, 3}}).

merge_msg_CommandGetSchema(#{} = PMsg,
    #{request_id := NFrequest_id, topic := NFtopic} =
      NMsg,
    _) ->
  S1 = #{request_id => NFrequest_id, topic => NFtopic},
  case {PMsg, NMsg} of
    {_, #{schema_version := NFschema_version}} ->
      S1#{schema_version => NFschema_version};
    {#{schema_version := PFschema_version}, _} ->
      S1#{schema_version => PFschema_version};
    _ -> S1
  end.

-compile({nowarn_unused_function,
  {merge_msg_CommandGetSchemaResponse, 3}}).

merge_msg_CommandGetSchemaResponse(#{} = PMsg,
    #{request_id := NFrequest_id} = NMsg,
    TrUserData) ->
  S1 = #{request_id => NFrequest_id},
  S2 = case {PMsg, NMsg} of
         {_, #{error_code := NFerror_code}} ->
           S1#{error_code => NFerror_code};
         {#{error_code := PFerror_code}, _} ->
           S1#{error_code => PFerror_code};
         _ -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {_, #{error_message := NFerror_message}} ->
           S2#{error_message => NFerror_message};
         {#{error_message := PFerror_message}, _} ->
           S2#{error_message => PFerror_message};
         _ -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {#{schema := PFschema}, #{schema := NFschema}} ->
           S3#{schema =>
           merge_msg_Schema(PFschema, NFschema, TrUserData)};
         {_, #{schema := NFschema}} -> S3#{schema => NFschema};
         {#{schema := PFschema}, _} -> S3#{schema => PFschema};
         {_, _} -> S3
       end,
  case {PMsg, NMsg} of
    {_, #{schema_version := NFschema_version}} ->
      S4#{schema_version => NFschema_version};
    {#{schema_version := PFschema_version}, _} ->
      S4#{schema_version => PFschema_version};
    _ -> S4
  end.

-compile({nowarn_unused_function,
  {merge_msg_BaseCommand, 3}}).

merge_msg_BaseCommand(#{} = PMsg,
    #{type := NFtype} = NMsg, TrUserData) ->
  S1 = #{type => NFtype},
  S2 = case {PMsg, NMsg} of
         {#{connect := PFconnect}, #{connect := NFconnect}} ->
           S1#{connect =>
           merge_msg_CommandConnect(PFconnect,
             NFconnect,
             TrUserData)};
         {_, #{connect := NFconnect}} ->
           S1#{connect => NFconnect};
         {#{connect := PFconnect}, _} ->
           S1#{connect => PFconnect};
         {_, _} -> S1
       end,
  S3 = case {PMsg, NMsg} of
         {#{connected := PFconnected},
           #{connected := NFconnected}} ->
           S2#{connected =>
           merge_msg_CommandConnected(PFconnected,
             NFconnected,
             TrUserData)};
         {_, #{connected := NFconnected}} ->
           S2#{connected => NFconnected};
         {#{connected := PFconnected}, _} ->
           S2#{connected => PFconnected};
         {_, _} -> S2
       end,
  S4 = case {PMsg, NMsg} of
         {#{subscribe := PFsubscribe},
           #{subscribe := NFsubscribe}} ->
           S3#{subscribe =>
           merge_msg_CommandSubscribe(PFsubscribe,
             NFsubscribe,
             TrUserData)};
         {_, #{subscribe := NFsubscribe}} ->
           S3#{subscribe => NFsubscribe};
         {#{subscribe := PFsubscribe}, _} ->
           S3#{subscribe => PFsubscribe};
         {_, _} -> S3
       end,
  S5 = case {PMsg, NMsg} of
         {#{producer := PFproducer},
           #{producer := NFproducer}} ->
           S4#{producer =>
           merge_msg_CommandProducer(PFproducer,
             NFproducer,
             TrUserData)};
         {_, #{producer := NFproducer}} ->
           S4#{producer => NFproducer};
         {#{producer := PFproducer}, _} ->
           S4#{producer => PFproducer};
         {_, _} -> S4
       end,
  S6 = case {PMsg, NMsg} of
         {#{send := PFsend}, #{send := NFsend}} ->
           S5#{send =>
           merge_msg_CommandSend(PFsend, NFsend, TrUserData)};
         {_, #{send := NFsend}} -> S5#{send => NFsend};
         {#{send := PFsend}, _} -> S5#{send => PFsend};
         {_, _} -> S5
       end,
  S7 = case {PMsg, NMsg} of
         {#{send_receipt := PFsend_receipt},
           #{send_receipt := NFsend_receipt}} ->
           S6#{send_receipt =>
           merge_msg_CommandSendReceipt(PFsend_receipt,
             NFsend_receipt,
             TrUserData)};
         {_, #{send_receipt := NFsend_receipt}} ->
           S6#{send_receipt => NFsend_receipt};
         {#{send_receipt := PFsend_receipt}, _} ->
           S6#{send_receipt => PFsend_receipt};
         {_, _} -> S6
       end,
  S8 = case {PMsg, NMsg} of
         {#{send_error := PFsend_error},
           #{send_error := NFsend_error}} ->
           S7#{send_error =>
           merge_msg_CommandSendError(PFsend_error,
             NFsend_error,
             TrUserData)};
         {_, #{send_error := NFsend_error}} ->
           S7#{send_error => NFsend_error};
         {#{send_error := PFsend_error}, _} ->
           S7#{send_error => PFsend_error};
         {_, _} -> S7
       end,
  S9 = case {PMsg, NMsg} of
         {#{message := PFmessage}, #{message := NFmessage}} ->
           S8#{message =>
           merge_msg_CommandMessage(PFmessage,
             NFmessage,
             TrUserData)};
         {_, #{message := NFmessage}} ->
           S8#{message => NFmessage};
         {#{message := PFmessage}, _} ->
           S8#{message => PFmessage};
         {_, _} -> S8
       end,
  S10 = case {PMsg, NMsg} of
          {#{ack := PFack}, #{ack := NFack}} ->
            S9#{ack =>
            merge_msg_CommandAck(PFack, NFack, TrUserData)};
          {_, #{ack := NFack}} -> S9#{ack => NFack};
          {#{ack := PFack}, _} -> S9#{ack => PFack};
          {_, _} -> S9
        end,
  S11 = case {PMsg, NMsg} of
          {#{flow := PFflow}, #{flow := NFflow}} ->
            S10#{flow =>
            merge_msg_CommandFlow(PFflow, NFflow, TrUserData)};
          {_, #{flow := NFflow}} -> S10#{flow => NFflow};
          {#{flow := PFflow}, _} -> S10#{flow => PFflow};
          {_, _} -> S10
        end,
  S12 = case {PMsg, NMsg} of
          {#{unsubscribe := PFunsubscribe},
            #{unsubscribe := NFunsubscribe}} ->
            S11#{unsubscribe =>
            merge_msg_CommandUnsubscribe(PFunsubscribe,
              NFunsubscribe,
              TrUserData)};
          {_, #{unsubscribe := NFunsubscribe}} ->
            S11#{unsubscribe => NFunsubscribe};
          {#{unsubscribe := PFunsubscribe}, _} ->
            S11#{unsubscribe => PFunsubscribe};
          {_, _} -> S11
        end,
  S13 = case {PMsg, NMsg} of
          {#{success := PFsuccess}, #{success := NFsuccess}} ->
            S12#{success =>
            merge_msg_CommandSuccess(PFsuccess,
              NFsuccess,
              TrUserData)};
          {_, #{success := NFsuccess}} ->
            S12#{success => NFsuccess};
          {#{success := PFsuccess}, _} ->
            S12#{success => PFsuccess};
          {_, _} -> S12
        end,
  S14 = case {PMsg, NMsg} of
          {#{error := PFerror}, #{error := NFerror}} ->
            S13#{error =>
            merge_msg_CommandError(PFerror,
              NFerror,
              TrUserData)};
          {_, #{error := NFerror}} -> S13#{error => NFerror};
          {#{error := PFerror}, _} -> S13#{error => PFerror};
          {_, _} -> S13
        end,
  S15 = case {PMsg, NMsg} of
          {#{close_producer := PFclose_producer},
            #{close_producer := NFclose_producer}} ->
            S14#{close_producer =>
            merge_msg_CommandCloseProducer(PFclose_producer,
              NFclose_producer,
              TrUserData)};
          {_, #{close_producer := NFclose_producer}} ->
            S14#{close_producer => NFclose_producer};
          {#{close_producer := PFclose_producer}, _} ->
            S14#{close_producer => PFclose_producer};
          {_, _} -> S14
        end,
  S16 = case {PMsg, NMsg} of
          {#{close_consumer := PFclose_consumer},
            #{close_consumer := NFclose_consumer}} ->
            S15#{close_consumer =>
            merge_msg_CommandCloseConsumer(PFclose_consumer,
              NFclose_consumer,
              TrUserData)};
          {_, #{close_consumer := NFclose_consumer}} ->
            S15#{close_consumer => NFclose_consumer};
          {#{close_consumer := PFclose_consumer}, _} ->
            S15#{close_consumer => PFclose_consumer};
          {_, _} -> S15
        end,
  S17 = case {PMsg, NMsg} of
          {#{producer_success := PFproducer_success},
            #{producer_success := NFproducer_success}} ->
            S16#{producer_success =>
            merge_msg_CommandProducerSuccess(PFproducer_success,
              NFproducer_success,
              TrUserData)};
          {_, #{producer_success := NFproducer_success}} ->
            S16#{producer_success => NFproducer_success};
          {#{producer_success := PFproducer_success}, _} ->
            S16#{producer_success => PFproducer_success};
          {_, _} -> S16
        end,
  S18 = case {PMsg, NMsg} of
          {#{ping := PFping}, #{ping := NFping}} ->
            S17#{ping =>
            merge_msg_CommandPing(PFping, NFping, TrUserData)};
          {_, #{ping := NFping}} -> S17#{ping => NFping};
          {#{ping := PFping}, _} -> S17#{ping => PFping};
          {_, _} -> S17
        end,
  S19 = case {PMsg, NMsg} of
          {#{pong := PFpong}, #{pong := NFpong}} ->
            S18#{pong =>
            merge_msg_CommandPong(PFpong, NFpong, TrUserData)};
          {_, #{pong := NFpong}} -> S18#{pong => NFpong};
          {#{pong := PFpong}, _} -> S18#{pong => PFpong};
          {_, _} -> S18
        end,
  S20 = case {PMsg, NMsg} of
          {#{redeliverUnacknowledgedMessages :=
          PFredeliverUnacknowledgedMessages},
            #{redeliverUnacknowledgedMessages :=
            NFredeliverUnacknowledgedMessages}} ->
            S19#{redeliverUnacknowledgedMessages =>
            merge_msg_CommandRedeliverUnacknowledgedMessages(PFredeliverUnacknowledgedMessages,
              NFredeliverUnacknowledgedMessages,
              TrUserData)};
          {_,
            #{redeliverUnacknowledgedMessages :=
            NFredeliverUnacknowledgedMessages}} ->
            S19#{redeliverUnacknowledgedMessages =>
            NFredeliverUnacknowledgedMessages};
          {#{redeliverUnacknowledgedMessages :=
          PFredeliverUnacknowledgedMessages},
            _} ->
            S19#{redeliverUnacknowledgedMessages =>
            PFredeliverUnacknowledgedMessages};
          {_, _} -> S19
        end,
  S21 = case {PMsg, NMsg} of
          {#{partitionMetadata := PFpartitionMetadata},
            #{partitionMetadata := NFpartitionMetadata}} ->
            S20#{partitionMetadata =>
            merge_msg_CommandPartitionedTopicMetadata(PFpartitionMetadata,
              NFpartitionMetadata,
              TrUserData)};
          {_, #{partitionMetadata := NFpartitionMetadata}} ->
            S20#{partitionMetadata => NFpartitionMetadata};
          {#{partitionMetadata := PFpartitionMetadata}, _} ->
            S20#{partitionMetadata => PFpartitionMetadata};
          {_, _} -> S20
        end,
  S22 = case {PMsg, NMsg} of
          {#{partitionMetadataResponse :=
          PFpartitionMetadataResponse},
            #{partitionMetadataResponse :=
            NFpartitionMetadataResponse}} ->
            S21#{partitionMetadataResponse =>
            merge_msg_CommandPartitionedTopicMetadataResponse(PFpartitionMetadataResponse,
              NFpartitionMetadataResponse,
              TrUserData)};
          {_,
            #{partitionMetadataResponse :=
            NFpartitionMetadataResponse}} ->
            S21#{partitionMetadataResponse =>
            NFpartitionMetadataResponse};
          {#{partitionMetadataResponse :=
          PFpartitionMetadataResponse},
            _} ->
            S21#{partitionMetadataResponse =>
            PFpartitionMetadataResponse};
          {_, _} -> S21
        end,
  S23 = case {PMsg, NMsg} of
          {#{lookupTopic := PFlookupTopic},
            #{lookupTopic := NFlookupTopic}} ->
            S22#{lookupTopic =>
            merge_msg_CommandLookupTopic(PFlookupTopic,
              NFlookupTopic,
              TrUserData)};
          {_, #{lookupTopic := NFlookupTopic}} ->
            S22#{lookupTopic => NFlookupTopic};
          {#{lookupTopic := PFlookupTopic}, _} ->
            S22#{lookupTopic => PFlookupTopic};
          {_, _} -> S22
        end,
  S24 = case {PMsg, NMsg} of
          {#{lookupTopicResponse := PFlookupTopicResponse},
            #{lookupTopicResponse := NFlookupTopicResponse}} ->
            S23#{lookupTopicResponse =>
            merge_msg_CommandLookupTopicResponse(PFlookupTopicResponse,
              NFlookupTopicResponse,
              TrUserData)};
          {_, #{lookupTopicResponse := NFlookupTopicResponse}} ->
            S23#{lookupTopicResponse => NFlookupTopicResponse};
          {#{lookupTopicResponse := PFlookupTopicResponse}, _} ->
            S23#{lookupTopicResponse => PFlookupTopicResponse};
          {_, _} -> S23
        end,
  S25 = case {PMsg, NMsg} of
          {#{consumerStats := PFconsumerStats},
            #{consumerStats := NFconsumerStats}} ->
            S24#{consumerStats =>
            merge_msg_CommandConsumerStats(PFconsumerStats,
              NFconsumerStats,
              TrUserData)};
          {_, #{consumerStats := NFconsumerStats}} ->
            S24#{consumerStats => NFconsumerStats};
          {#{consumerStats := PFconsumerStats}, _} ->
            S24#{consumerStats => PFconsumerStats};
          {_, _} -> S24
        end,
  S26 = case {PMsg, NMsg} of
          {#{consumerStatsResponse := PFconsumerStatsResponse},
            #{consumerStatsResponse := NFconsumerStatsResponse}} ->
            S25#{consumerStatsResponse =>
            merge_msg_CommandConsumerStatsResponse(PFconsumerStatsResponse,
              NFconsumerStatsResponse,
              TrUserData)};
          {_,
            #{consumerStatsResponse := NFconsumerStatsResponse}} ->
            S25#{consumerStatsResponse => NFconsumerStatsResponse};
          {#{consumerStatsResponse := PFconsumerStatsResponse},
            _} ->
            S25#{consumerStatsResponse => PFconsumerStatsResponse};
          {_, _} -> S25
        end,
  S27 = case {PMsg, NMsg} of
          {#{reachedEndOfTopic := PFreachedEndOfTopic},
            #{reachedEndOfTopic := NFreachedEndOfTopic}} ->
            S26#{reachedEndOfTopic =>
            merge_msg_CommandReachedEndOfTopic(PFreachedEndOfTopic,
              NFreachedEndOfTopic,
              TrUserData)};
          {_, #{reachedEndOfTopic := NFreachedEndOfTopic}} ->
            S26#{reachedEndOfTopic => NFreachedEndOfTopic};
          {#{reachedEndOfTopic := PFreachedEndOfTopic}, _} ->
            S26#{reachedEndOfTopic => PFreachedEndOfTopic};
          {_, _} -> S26
        end,
  S28 = case {PMsg, NMsg} of
          {#{seek := PFseek}, #{seek := NFseek}} ->
            S27#{seek =>
            merge_msg_CommandSeek(PFseek, NFseek, TrUserData)};
          {_, #{seek := NFseek}} -> S27#{seek => NFseek};
          {#{seek := PFseek}, _} -> S27#{seek => PFseek};
          {_, _} -> S27
        end,
  S29 = case {PMsg, NMsg} of
          {#{getLastMessageId := PFgetLastMessageId},
            #{getLastMessageId := NFgetLastMessageId}} ->
            S28#{getLastMessageId =>
            merge_msg_CommandGetLastMessageId(PFgetLastMessageId,
              NFgetLastMessageId,
              TrUserData)};
          {_, #{getLastMessageId := NFgetLastMessageId}} ->
            S28#{getLastMessageId => NFgetLastMessageId};
          {#{getLastMessageId := PFgetLastMessageId}, _} ->
            S28#{getLastMessageId => PFgetLastMessageId};
          {_, _} -> S28
        end,
  S30 = case {PMsg, NMsg} of
          {#{getLastMessageIdResponse :=
          PFgetLastMessageIdResponse},
            #{getLastMessageIdResponse :=
            NFgetLastMessageIdResponse}} ->
            S29#{getLastMessageIdResponse =>
            merge_msg_CommandGetLastMessageIdResponse(PFgetLastMessageIdResponse,
              NFgetLastMessageIdResponse,
              TrUserData)};
          {_,
            #{getLastMessageIdResponse :=
            NFgetLastMessageIdResponse}} ->
            S29#{getLastMessageIdResponse =>
            NFgetLastMessageIdResponse};
          {#{getLastMessageIdResponse :=
          PFgetLastMessageIdResponse},
            _} ->
            S29#{getLastMessageIdResponse =>
            PFgetLastMessageIdResponse};
          {_, _} -> S29
        end,
  S31 = case {PMsg, NMsg} of
          {#{active_consumer_change := PFactive_consumer_change},
            #{active_consumer_change :=
            NFactive_consumer_change}} ->
            S30#{active_consumer_change =>
            merge_msg_CommandActiveConsumerChange(PFactive_consumer_change,
              NFactive_consumer_change,
              TrUserData)};
          {_,
            #{active_consumer_change :=
            NFactive_consumer_change}} ->
            S30#{active_consumer_change =>
            NFactive_consumer_change};
          {#{active_consumer_change := PFactive_consumer_change},
            _} ->
            S30#{active_consumer_change =>
            PFactive_consumer_change};
          {_, _} -> S30
        end,
  S32 = case {PMsg, NMsg} of
          {#{getTopicsOfNamespace := PFgetTopicsOfNamespace},
            #{getTopicsOfNamespace := NFgetTopicsOfNamespace}} ->
            S31#{getTopicsOfNamespace =>
            merge_msg_CommandGetTopicsOfNamespace(PFgetTopicsOfNamespace,
              NFgetTopicsOfNamespace,
              TrUserData)};
          {_,
            #{getTopicsOfNamespace := NFgetTopicsOfNamespace}} ->
            S31#{getTopicsOfNamespace => NFgetTopicsOfNamespace};
          {#{getTopicsOfNamespace := PFgetTopicsOfNamespace},
            _} ->
            S31#{getTopicsOfNamespace => PFgetTopicsOfNamespace};
          {_, _} -> S31
        end,
  S33 = case {PMsg, NMsg} of
          {#{getTopicsOfNamespaceResponse :=
          PFgetTopicsOfNamespaceResponse},
            #{getTopicsOfNamespaceResponse :=
            NFgetTopicsOfNamespaceResponse}} ->
            S32#{getTopicsOfNamespaceResponse =>
            merge_msg_CommandGetTopicsOfNamespaceResponse(PFgetTopicsOfNamespaceResponse,
              NFgetTopicsOfNamespaceResponse,
              TrUserData)};
          {_,
            #{getTopicsOfNamespaceResponse :=
            NFgetTopicsOfNamespaceResponse}} ->
            S32#{getTopicsOfNamespaceResponse =>
            NFgetTopicsOfNamespaceResponse};
          {#{getTopicsOfNamespaceResponse :=
          PFgetTopicsOfNamespaceResponse},
            _} ->
            S32#{getTopicsOfNamespaceResponse =>
            PFgetTopicsOfNamespaceResponse};
          {_, _} -> S32
        end,
  S34 = case {PMsg, NMsg} of
          {#{getSchema := PFgetSchema},
            #{getSchema := NFgetSchema}} ->
            S33#{getSchema =>
            merge_msg_CommandGetSchema(PFgetSchema,
              NFgetSchema,
              TrUserData)};
          {_, #{getSchema := NFgetSchema}} ->
            S33#{getSchema => NFgetSchema};
          {#{getSchema := PFgetSchema}, _} ->
            S33#{getSchema => PFgetSchema};
          {_, _} -> S33
        end,
  S35 = case {PMsg, NMsg} of
          {#{getSchemaResponse := PFgetSchemaResponse},
            #{getSchemaResponse := NFgetSchemaResponse}} ->
            S34#{getSchemaResponse =>
            merge_msg_CommandGetSchemaResponse(PFgetSchemaResponse,
              NFgetSchemaResponse,
              TrUserData)};
          {_, #{getSchemaResponse := NFgetSchemaResponse}} ->
            S34#{getSchemaResponse => NFgetSchemaResponse};
          {#{getSchemaResponse := PFgetSchemaResponse}, _} ->
            S34#{getSchemaResponse => PFgetSchemaResponse};
          {_, _} -> S34
        end,
  S36 = case {PMsg, NMsg} of
          {#{authChallenge := PFauthChallenge},
            #{authChallenge := NFauthChallenge}} ->
            S35#{authChallenge =>
            merge_msg_CommandAuthChallenge(PFauthChallenge,
              NFauthChallenge,
              TrUserData)};
          {_, #{authChallenge := NFauthChallenge}} ->
            S35#{authChallenge => NFauthChallenge};
          {#{authChallenge := PFauthChallenge}, _} ->
            S35#{authChallenge => PFauthChallenge};
          {_, _} -> S35
        end,
  case {PMsg, NMsg} of
    {#{authResponse := PFauthResponse},
      #{authResponse := NFauthResponse}} ->
      S36#{authResponse =>
      merge_msg_CommandAuthResponse(PFauthResponse,
        NFauthResponse,
        TrUserData)};
    {_, #{authResponse := NFauthResponse}} ->
      S36#{authResponse => NFauthResponse};
    {#{authResponse := PFauthResponse}, _} ->
      S36#{authResponse => PFauthResponse};
    {_, _} -> S36
  end.

verify_msg(Msg, MsgName) when is_atom(MsgName) ->
  verify_msg(Msg, MsgName, []).

verify_msg(Msg, MsgName, Opts) ->
  TrUserData = proplists:get_value(user_data, Opts),
  case MsgName of
    'Schema' -> v_msg_Schema(Msg, [MsgName], TrUserData);
    'MessageIdData' ->
      v_msg_MessageIdData(Msg, [MsgName], TrUserData);
    'KeyValue' ->
      v_msg_KeyValue(Msg, [MsgName], TrUserData);
    'KeyLongValue' ->
      v_msg_KeyLongValue(Msg, [MsgName], TrUserData);
    'EncryptionKeys' ->
      v_msg_EncryptionKeys(Msg, [MsgName], TrUserData);
    'MessageMetadata' ->
      v_msg_MessageMetadata(Msg, [MsgName], TrUserData);
    'SingleMessageMetadata' ->
      v_msg_SingleMessageMetadata(Msg, [MsgName], TrUserData);
    'CommandConnect' ->
      v_msg_CommandConnect(Msg, [MsgName], TrUserData);
    'CommandConnected' ->
      v_msg_CommandConnected(Msg, [MsgName], TrUserData);
    'CommandAuthResponse' ->
      v_msg_CommandAuthResponse(Msg, [MsgName], TrUserData);
    'CommandAuthChallenge' ->
      v_msg_CommandAuthChallenge(Msg, [MsgName], TrUserData);
    'AuthData' ->
      v_msg_AuthData(Msg, [MsgName], TrUserData);
    'CommandSubscribe' ->
      v_msg_CommandSubscribe(Msg, [MsgName], TrUserData);
    'CommandPartitionedTopicMetadata' ->
      v_msg_CommandPartitionedTopicMetadata(Msg,
        [MsgName],
        TrUserData);
    'CommandPartitionedTopicMetadataResponse' ->
      v_msg_CommandPartitionedTopicMetadataResponse(Msg,
        [MsgName],
        TrUserData);
    'CommandLookupTopic' ->
      v_msg_CommandLookupTopic(Msg, [MsgName], TrUserData);
    'CommandLookupTopicResponse' ->
      v_msg_CommandLookupTopicResponse(Msg,
        [MsgName],
        TrUserData);
    'CommandProducer' ->
      v_msg_CommandProducer(Msg, [MsgName], TrUserData);
    'CommandSend' ->
      v_msg_CommandSend(Msg, [MsgName], TrUserData);
    'CommandSendReceipt' ->
      v_msg_CommandSendReceipt(Msg, [MsgName], TrUserData);
    'CommandSendError' ->
      v_msg_CommandSendError(Msg, [MsgName], TrUserData);
    'CommandMessage' ->
      v_msg_CommandMessage(Msg, [MsgName], TrUserData);
    'CommandAck' ->
      v_msg_CommandAck(Msg, [MsgName], TrUserData);
    'CommandActiveConsumerChange' ->
      v_msg_CommandActiveConsumerChange(Msg,
        [MsgName],
        TrUserData);
    'CommandFlow' ->
      v_msg_CommandFlow(Msg, [MsgName], TrUserData);
    'CommandUnsubscribe' ->
      v_msg_CommandUnsubscribe(Msg, [MsgName], TrUserData);
    'CommandSeek' ->
      v_msg_CommandSeek(Msg, [MsgName], TrUserData);
    'CommandReachedEndOfTopic' ->
      v_msg_CommandReachedEndOfTopic(Msg,
        [MsgName],
        TrUserData);
    'CommandCloseProducer' ->
      v_msg_CommandCloseProducer(Msg, [MsgName], TrUserData);
    'CommandCloseConsumer' ->
      v_msg_CommandCloseConsumer(Msg, [MsgName], TrUserData);
    'CommandRedeliverUnacknowledgedMessages' ->
      v_msg_CommandRedeliverUnacknowledgedMessages(Msg,
        [MsgName],
        TrUserData);
    'CommandSuccess' ->
      v_msg_CommandSuccess(Msg, [MsgName], TrUserData);
    'CommandProducerSuccess' ->
      v_msg_CommandProducerSuccess(Msg,
        [MsgName],
        TrUserData);
    'CommandError' ->
      v_msg_CommandError(Msg, [MsgName], TrUserData);
    'CommandPing' ->
      v_msg_CommandPing(Msg, [MsgName], TrUserData);
    'CommandPong' ->
      v_msg_CommandPong(Msg, [MsgName], TrUserData);
    'CommandConsumerStats' ->
      v_msg_CommandConsumerStats(Msg, [MsgName], TrUserData);
    'CommandConsumerStatsResponse' ->
      v_msg_CommandConsumerStatsResponse(Msg,
        [MsgName],
        TrUserData);
    'CommandGetLastMessageId' ->
      v_msg_CommandGetLastMessageId(Msg,
        [MsgName],
        TrUserData);
    'CommandGetLastMessageIdResponse' ->
      v_msg_CommandGetLastMessageIdResponse(Msg,
        [MsgName],
        TrUserData);
    'CommandGetTopicsOfNamespace' ->
      v_msg_CommandGetTopicsOfNamespace(Msg,
        [MsgName],
        TrUserData);
    'CommandGetTopicsOfNamespaceResponse' ->
      v_msg_CommandGetTopicsOfNamespaceResponse(Msg,
        [MsgName],
        TrUserData);
    'CommandGetSchema' ->
      v_msg_CommandGetSchema(Msg, [MsgName], TrUserData);
    'CommandGetSchemaResponse' ->
      v_msg_CommandGetSchemaResponse(Msg,
        [MsgName],
        TrUserData);
    'BaseCommand' ->
      v_msg_BaseCommand(Msg, [MsgName], TrUserData);
    _ -> mk_type_error(not_a_known_message, Msg, [])
  end.

-compile({nowarn_unused_function, {v_msg_Schema, 3}}).

-dialyzer({nowarn_function, {v_msg_Schema, 3}}).

v_msg_Schema(#{name := F1, schema_data := F2,
  type := F3} =
  M,
    Path, TrUserData) ->
  v_type_string(F1, [name | Path], TrUserData),
  v_type_bytes(F2, [schema_data | Path], TrUserData),
  'v_enum_Schema.Type'(F3, [type | Path], TrUserData),
  case M of
    #{properties := F4} ->
      if is_list(F4) ->
        _ = [v_msg_KeyValue(Elem,
          [properties | Path],
          TrUserData)
          || Elem <- F4],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyValue'}},
            F4,
            [properties | Path])
      end;
    _ -> ok
  end,
  lists:foreach(fun (name) -> ok;
    (schema_data) -> ok;
    (type) -> ok;
    (properties) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_Schema(M, Path, _TrUserData) when is_map(M) ->
  mk_type_error({missing_fields,
      [name, schema_data, type] -- maps:keys(M),
    'Schema'},
    M,
    Path);
v_msg_Schema(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'Schema'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_MessageIdData, 3}}).

-dialyzer({nowarn_function, {v_msg_MessageIdData, 3}}).

v_msg_MessageIdData(#{ledgerId := F1, entryId := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [ledgerId | Path], TrUserData),
  v_type_uint64(F2, [entryId | Path], TrUserData),
  case M of
    #{partition := F3} ->
      v_type_int32(F3, [partition | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{batch_index := F4} ->
      v_type_int32(F4, [batch_index | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (ledgerId) -> ok;
    (entryId) -> ok;
    (partition) -> ok;
    (batch_index) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_MessageIdData(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [ledgerId, entryId] -- maps:keys(M),
    'MessageIdData'},
    M,
    Path);
v_msg_MessageIdData(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'MessageIdData'}, X, Path).

-compile({nowarn_unused_function, {v_msg_KeyValue, 3}}).

-dialyzer({nowarn_function, {v_msg_KeyValue, 3}}).

v_msg_KeyValue(#{key := F1, value := F2} = M, Path,
    TrUserData) ->
  v_type_string(F1, [key | Path], TrUserData),
  v_type_string(F2, [value | Path], TrUserData),
  lists:foreach(fun (key) -> ok;
    (value) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_KeyValue(M, Path, _TrUserData) when is_map(M) ->
  mk_type_error({missing_fields,
      [key, value] -- maps:keys(M),
    'KeyValue'},
    M,
    Path);
v_msg_KeyValue(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'KeyValue'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_KeyLongValue, 3}}).

-dialyzer({nowarn_function, {v_msg_KeyLongValue, 3}}).

v_msg_KeyLongValue(#{key := F1, value := F2} = M, Path,
    TrUserData) ->
  v_type_string(F1, [key | Path], TrUserData),
  v_type_uint64(F2, [value | Path], TrUserData),
  lists:foreach(fun (key) -> ok;
    (value) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_KeyLongValue(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [key, value] -- maps:keys(M),
    'KeyLongValue'},
    M,
    Path);
v_msg_KeyLongValue(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'KeyLongValue'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_EncryptionKeys, 3}}).

-dialyzer({nowarn_function, {v_msg_EncryptionKeys, 3}}).

v_msg_EncryptionKeys(#{key := F1, value := F2} = M,
    Path, TrUserData) ->
  v_type_string(F1, [key | Path], TrUserData),
  v_type_bytes(F2, [value | Path], TrUserData),
  case M of
    #{metadata := F3} ->
      if is_list(F3) ->
        _ = [v_msg_KeyValue(Elem, [metadata | Path], TrUserData)
          || Elem <- F3],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyValue'}},
            F3,
            [metadata | Path])
      end;
    _ -> ok
  end,
  lists:foreach(fun (key) -> ok;
    (value) -> ok;
    (metadata) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_EncryptionKeys(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [key, value] -- maps:keys(M),
    'EncryptionKeys'},
    M,
    Path);
v_msg_EncryptionKeys(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'EncryptionKeys'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_MessageMetadata, 3}}).

-dialyzer({nowarn_function,
  {v_msg_MessageMetadata, 3}}).

v_msg_MessageMetadata(#{producer_name := F1,
  sequence_id := F2, publish_time := F3} =
  M,
    Path, TrUserData) ->
  v_type_string(F1, [producer_name | Path], TrUserData),
  v_type_uint64(F2, [sequence_id | Path], TrUserData),
  v_type_uint64(F3, [publish_time | Path], TrUserData),
  case M of
    #{properties := F4} ->
      if is_list(F4) ->
        _ = [v_msg_KeyValue(Elem,
          [properties | Path],
          TrUserData)
          || Elem <- F4],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyValue'}},
            F4,
            [properties | Path])
      end;
    _ -> ok
  end,
  case M of
    #{replicated_from := F5} ->
      v_type_string(F5, [replicated_from | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{partition_key := F6} ->
      v_type_string(F6, [partition_key | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{replicate_to := F7} ->
      if is_list(F7) ->
        _ = [v_type_string(Elem,
          [replicate_to | Path],
          TrUserData)
          || Elem <- F7],
        ok;
        true ->
          mk_type_error({invalid_list_of, string},
            F7,
            [replicate_to | Path])
      end;
    _ -> ok
  end,
  case M of
    #{compression := F8} ->
      v_enum_CompressionType(F8,
        [compression | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{uncompressed_size := F9} ->
      v_type_uint32(F9,
        [uncompressed_size | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{num_messages_in_batch := F10} ->
      v_type_int32(F10,
        [num_messages_in_batch | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{event_time := F11} ->
      v_type_uint64(F11, [event_time | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{encryption_keys := F12} ->
      if is_list(F12) ->
        _ = [v_msg_EncryptionKeys(Elem,
          [encryption_keys | Path],
          TrUserData)
          || Elem <- F12],
        ok;
        true ->
          mk_type_error({invalid_list_of,
            {msg, 'EncryptionKeys'}},
            F12,
            [encryption_keys | Path])
      end;
    _ -> ok
  end,
  case M of
    #{encryption_algo := F13} ->
      v_type_string(F13,
        [encryption_algo | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{encryption_param := F14} ->
      v_type_bytes(F14,
        [encryption_param | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{schema_version := F15} ->
      v_type_bytes(F15, [schema_version | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{partition_key_b64_encoded := F16} ->
      v_type_bool(F16,
        [partition_key_b64_encoded | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{ordering_key := F17} ->
      v_type_bytes(F17, [ordering_key | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (producer_name) -> ok;
    (sequence_id) -> ok;
    (publish_time) -> ok;
    (properties) -> ok;
    (replicated_from) -> ok;
    (partition_key) -> ok;
    (replicate_to) -> ok;
    (compression) -> ok;
    (uncompressed_size) -> ok;
    (num_messages_in_batch) -> ok;
    (event_time) -> ok;
    (encryption_keys) -> ok;
    (encryption_algo) -> ok;
    (encryption_param) -> ok;
    (schema_version) -> ok;
    (partition_key_b64_encoded) -> ok;
    (ordering_key) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_MessageMetadata(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [producer_name, sequence_id, publish_time] --
      maps:keys(M),
    'MessageMetadata'},
    M,
    Path);
v_msg_MessageMetadata(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'MessageMetadata'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_SingleMessageMetadata, 3}}).

-dialyzer({nowarn_function,
  {v_msg_SingleMessageMetadata, 3}}).

v_msg_SingleMessageMetadata(#{payload_size := F3} = M,
    Path, TrUserData) ->
  case M of
    #{properties := F1} ->
      if is_list(F1) ->
        _ = [v_msg_KeyValue(Elem,
          [properties | Path],
          TrUserData)
          || Elem <- F1],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyValue'}},
            F1,
            [properties | Path])
      end;
    _ -> ok
  end,
  case M of
    #{partition_key := F2} ->
      v_type_string(F2, [partition_key | Path], TrUserData);
    _ -> ok
  end,
  v_type_int32(F3, [payload_size | Path], TrUserData),
  case M of
    #{compacted_out := F4} ->
      v_type_bool(F4, [compacted_out | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{event_time := F5} ->
      v_type_uint64(F5, [event_time | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{partition_key_b64_encoded := F6} ->
      v_type_bool(F6,
        [partition_key_b64_encoded | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{ordering_key := F7} ->
      v_type_bytes(F7, [ordering_key | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (properties) -> ok;
    (partition_key) -> ok;
    (payload_size) -> ok;
    (compacted_out) -> ok;
    (event_time) -> ok;
    (partition_key_b64_encoded) -> ok;
    (ordering_key) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_SingleMessageMetadata(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [payload_size] -- maps:keys(M),
    'SingleMessageMetadata'},
    M,
    Path);
v_msg_SingleMessageMetadata(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'SingleMessageMetadata'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandConnect, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandConnect, 3}}).

v_msg_CommandConnect(#{client_version := F1} = M, Path,
    TrUserData) ->
  v_type_string(F1, [client_version | Path], TrUserData),
  case M of
    #{auth_method := F2} ->
      v_enum_AuthMethod(F2, [auth_method | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{auth_method_name := F3} ->
      v_type_string(F3,
        [auth_method_name | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{auth_data := F4} ->
      v_type_bytes(F4, [auth_data | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{protocol_version := F5} ->
      v_type_int32(F5, [protocol_version | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{proxy_to_broker_url := F6} ->
      v_type_string(F6,
        [proxy_to_broker_url | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_principal := F7} ->
      v_type_string(F7,
        [original_principal | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_auth_data := F8} ->
      v_type_string(F8,
        [original_auth_data | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_auth_method := F9} ->
      v_type_string(F9,
        [original_auth_method | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (client_version) -> ok;
    (auth_method) -> ok;
    (auth_method_name) -> ok;
    (auth_data) -> ok;
    (protocol_version) -> ok;
    (proxy_to_broker_url) -> ok;
    (original_principal) -> ok;
    (original_auth_data) -> ok;
    (original_auth_method) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandConnect(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [client_version] -- maps:keys(M),
    'CommandConnect'},
    M,
    Path);
v_msg_CommandConnect(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandConnect'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandConnected, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandConnected, 3}}).

v_msg_CommandConnected(#{server_version := F1} = M,
    Path, TrUserData) ->
  v_type_string(F1, [server_version | Path], TrUserData),
  case M of
    #{protocol_version := F2} ->
      v_type_int32(F2, [protocol_version | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (server_version) -> ok;
    (protocol_version) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandConnected(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [server_version] -- maps:keys(M),
    'CommandConnected'},
    M,
    Path);
v_msg_CommandConnected(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandConnected'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandAuthResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandAuthResponse, 3}}).

v_msg_CommandAuthResponse(#{} = M, Path, TrUserData) ->
  case M of
    #{client_version := F1} ->
      v_type_string(F1, [client_version | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{response := F2} ->
      v_msg_AuthData(F2, [response | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{protocol_version := F3} ->
      v_type_int32(F3, [protocol_version | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (client_version) -> ok;
    (response) -> ok;
    (protocol_version) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandAuthResponse(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [] -- maps:keys(M),
    'CommandAuthResponse'},
    M,
    Path);
v_msg_CommandAuthResponse(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandAuthResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandAuthChallenge, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandAuthChallenge, 3}}).

v_msg_CommandAuthChallenge(#{} = M, Path, TrUserData) ->
  case M of
    #{server_version := F1} ->
      v_type_string(F1, [server_version | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{challenge := F2} ->
      v_msg_AuthData(F2, [challenge | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{protocol_version := F3} ->
      v_type_int32(F3, [protocol_version | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (server_version) -> ok;
    (challenge) -> ok;
    (protocol_version) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandAuthChallenge(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [] -- maps:keys(M),
    'CommandAuthChallenge'},
    M,
    Path);
v_msg_CommandAuthChallenge(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandAuthChallenge'},
    X,
    Path).

-compile({nowarn_unused_function, {v_msg_AuthData, 3}}).

-dialyzer({nowarn_function, {v_msg_AuthData, 3}}).

v_msg_AuthData(#{} = M, Path, TrUserData) ->
  case M of
    #{auth_method_name := F1} ->
      v_type_string(F1,
        [auth_method_name | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{auth_data := F2} ->
      v_type_bytes(F2, [auth_data | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (auth_method_name) -> ok;
    (auth_data) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_AuthData(M, Path, _TrUserData) when is_map(M) ->
  mk_type_error({missing_fields,
      [] -- maps:keys(M),
    'AuthData'},
    M,
    Path);
v_msg_AuthData(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'AuthData'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandSubscribe, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandSubscribe, 3}}).

v_msg_CommandSubscribe(#{topic := F1,
  subscription := F2, subType := F3, consumer_id := F4,
  request_id := F5} =
  M,
    Path, TrUserData) ->
  v_type_string(F1, [topic | Path], TrUserData),
  v_type_string(F2, [subscription | Path], TrUserData),
  'v_enum_CommandSubscribe.SubType'(F3,
    [subType | Path],
    TrUserData),
  v_type_uint64(F4, [consumer_id | Path], TrUserData),
  v_type_uint64(F5, [request_id | Path], TrUserData),
  case M of
    #{consumer_name := F6} ->
      v_type_string(F6, [consumer_name | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{priority_level := F7} ->
      v_type_int32(F7, [priority_level | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{durable := F8} ->
      v_type_bool(F8, [durable | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{start_message_id := F9} ->
      v_msg_MessageIdData(F9,
        [start_message_id | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{metadata := F10} ->
      if is_list(F10) ->
        _ = [v_msg_KeyValue(Elem, [metadata | Path], TrUserData)
          || Elem <- F10],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyValue'}},
            F10,
            [metadata | Path])
      end;
    _ -> ok
  end,
  case M of
    #{read_compacted := F11} ->
      v_type_bool(F11, [read_compacted | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{schema := F12} ->
      v_msg_Schema(F12, [schema | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{initialPosition := F13} ->
      'v_enum_CommandSubscribe.InitialPosition'(F13,
        [initialPosition | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (topic) -> ok;
    (subscription) -> ok;
    (subType) -> ok;
    (consumer_id) -> ok;
    (request_id) -> ok;
    (consumer_name) -> ok;
    (priority_level) -> ok;
    (durable) -> ok;
    (start_message_id) -> ok;
    (metadata) -> ok;
    (read_compacted) -> ok;
    (schema) -> ok;
    (initialPosition) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandSubscribe(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [topic, subscription, subType, consumer_id, request_id]
      -- maps:keys(M),
    'CommandSubscribe'},
    M,
    Path);
v_msg_CommandSubscribe(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandSubscribe'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandPartitionedTopicMetadata, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandPartitionedTopicMetadata, 3}}).

v_msg_CommandPartitionedTopicMetadata(#{topic := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_string(F1, [topic | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  case M of
    #{original_principal := F3} ->
      v_type_string(F3,
        [original_principal | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_auth_data := F4} ->
      v_type_string(F4,
        [original_auth_data | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_auth_method := F5} ->
      v_type_string(F5,
        [original_auth_method | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (topic) -> ok;
    (request_id) -> ok;
    (original_principal) -> ok;
    (original_auth_data) -> ok;
    (original_auth_method) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandPartitionedTopicMetadata(M, Path,
    _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [topic, request_id] -- maps:keys(M),
    'CommandPartitionedTopicMetadata'},
    M,
    Path);
v_msg_CommandPartitionedTopicMetadata(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandPartitionedTopicMetadata'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandPartitionedTopicMetadataResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandPartitionedTopicMetadataResponse, 3}}).

v_msg_CommandPartitionedTopicMetadataResponse(#{request_id
:= F2} =
  M,
    Path, TrUserData) ->
  case M of
    #{partitions := F1} ->
      v_type_uint32(F1, [partitions | Path], TrUserData);
    _ -> ok
  end,
  v_type_uint64(F2, [request_id | Path], TrUserData),
  case M of
    #{response := F3} ->
      'v_enum_CommandPartitionedTopicMetadataResponse.LookupType'(F3,
        [response
          | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{error := F4} ->
      v_enum_ServerError(F4, [error | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{message := F5} ->
      v_type_string(F5, [message | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (partitions) -> ok;
    (request_id) -> ok;
    (response) -> ok;
    (error) -> ok;
    (message) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandPartitionedTopicMetadataResponse(M, Path,
    _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id] -- maps:keys(M),
    'CommandPartitionedTopicMetadataResponse'},
    M,
    Path);
v_msg_CommandPartitionedTopicMetadataResponse(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandPartitionedTopicMetadataResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandLookupTopic, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandLookupTopic, 3}}).

v_msg_CommandLookupTopic(#{topic := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_string(F1, [topic | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  case M of
    #{authoritative := F3} ->
      v_type_bool(F3, [authoritative | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{original_principal := F4} ->
      v_type_string(F4,
        [original_principal | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_auth_data := F5} ->
      v_type_string(F5,
        [original_auth_data | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{original_auth_method := F6} ->
      v_type_string(F6,
        [original_auth_method | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (topic) -> ok;
    (request_id) -> ok;
    (authoritative) -> ok;
    (original_principal) -> ok;
    (original_auth_data) -> ok;
    (original_auth_method) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandLookupTopic(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [topic, request_id] -- maps:keys(M),
    'CommandLookupTopic'},
    M,
    Path);
v_msg_CommandLookupTopic(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandLookupTopic'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandLookupTopicResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandLookupTopicResponse, 3}}).

v_msg_CommandLookupTopicResponse(#{request_id := F4} =
  M,
    Path, TrUserData) ->
  case M of
    #{brokerServiceUrl := F1} ->
      v_type_string(F1,
        [brokerServiceUrl | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{brokerServiceUrlTls := F2} ->
      v_type_string(F2,
        [brokerServiceUrlTls | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{response := F3} ->
      'v_enum_CommandLookupTopicResponse.LookupType'(F3,
        [response | Path],
        TrUserData);
    _ -> ok
  end,
  v_type_uint64(F4, [request_id | Path], TrUserData),
  case M of
    #{authoritative := F5} ->
      v_type_bool(F5, [authoritative | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{error := F6} ->
      v_enum_ServerError(F6, [error | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{message := F7} ->
      v_type_string(F7, [message | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{proxy_through_service_url := F8} ->
      v_type_bool(F8,
        [proxy_through_service_url | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (brokerServiceUrl) -> ok;
    (brokerServiceUrlTls) -> ok;
    (response) -> ok;
    (request_id) -> ok;
    (authoritative) -> ok;
    (error) -> ok;
    (message) -> ok;
    (proxy_through_service_url) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandLookupTopicResponse(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id] -- maps:keys(M),
    'CommandLookupTopicResponse'},
    M,
    Path);
v_msg_CommandLookupTopicResponse(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandLookupTopicResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandProducer, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandProducer, 3}}).

v_msg_CommandProducer(#{topic := F1, producer_id := F2,
  request_id := F3} =
  M,
    Path, TrUserData) ->
  v_type_string(F1, [topic | Path], TrUserData),
  v_type_uint64(F2, [producer_id | Path], TrUserData),
  v_type_uint64(F3, [request_id | Path], TrUserData),
  case M of
    #{producer_name := F4} ->
      v_type_string(F4, [producer_name | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{encrypted := F5} ->
      v_type_bool(F5, [encrypted | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{metadata := F6} ->
      if is_list(F6) ->
        _ = [v_msg_KeyValue(Elem, [metadata | Path], TrUserData)
          || Elem <- F6],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyValue'}},
            F6,
            [metadata | Path])
      end;
    _ -> ok
  end,
  case M of
    #{schema := F7} ->
      v_msg_Schema(F7, [schema | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (topic) -> ok;
    (producer_id) -> ok;
    (request_id) -> ok;
    (producer_name) -> ok;
    (encrypted) -> ok;
    (metadata) -> ok;
    (schema) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandProducer(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [topic, producer_id, request_id] -- maps:keys(M),
    'CommandProducer'},
    M,
    Path);
v_msg_CommandProducer(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandProducer'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandSend, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandSend, 3}}).

v_msg_CommandSend(#{producer_id := F1,
  sequence_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [producer_id | Path], TrUserData),
  v_type_uint64(F2, [sequence_id | Path], TrUserData),
  case M of
    #{num_messages := F3} ->
      v_type_int32(F3, [num_messages | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (producer_id) -> ok;
    (sequence_id) -> ok;
    (num_messages) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandSend(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [producer_id, sequence_id] -- maps:keys(M),
    'CommandSend'},
    M,
    Path);
v_msg_CommandSend(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandSend'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandSendReceipt, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandSendReceipt, 3}}).

v_msg_CommandSendReceipt(#{producer_id := F1,
  sequence_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [producer_id | Path], TrUserData),
  v_type_uint64(F2, [sequence_id | Path], TrUserData),
  case M of
    #{message_id := F3} ->
      v_msg_MessageIdData(F3,
        [message_id | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (producer_id) -> ok;
    (sequence_id) -> ok;
    (message_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandSendReceipt(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [producer_id, sequence_id] -- maps:keys(M),
    'CommandSendReceipt'},
    M,
    Path);
v_msg_CommandSendReceipt(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandSendReceipt'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandSendError, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandSendError, 3}}).

v_msg_CommandSendError(#{producer_id := F1,
  sequence_id := F2, error := F3, message := F4} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [producer_id | Path], TrUserData),
  v_type_uint64(F2, [sequence_id | Path], TrUserData),
  v_enum_ServerError(F3, [error | Path], TrUserData),
  v_type_string(F4, [message | Path], TrUserData),
  lists:foreach(fun (producer_id) -> ok;
    (sequence_id) -> ok;
    (error) -> ok;
    (message) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandSendError(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [producer_id, sequence_id, error, message] --
      maps:keys(M),
    'CommandSendError'},
    M,
    Path);
v_msg_CommandSendError(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandSendError'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandMessage, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandMessage, 3}}).

v_msg_CommandMessage(#{consumer_id := F1,
  message_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  v_msg_MessageIdData(F2,
    [message_id | Path],
    TrUserData),
  case M of
    #{redelivery_count := F3} ->
      v_type_uint32(F3,
        [redelivery_count | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (consumer_id) -> ok;
    (message_id) -> ok;
    (redelivery_count) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandMessage(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, message_id] -- maps:keys(M),
    'CommandMessage'},
    M,
    Path);
v_msg_CommandMessage(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandMessage'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandAck, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandAck, 3}}).

v_msg_CommandAck(#{consumer_id := F1, ack_type := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  'v_enum_CommandAck.AckType'(F2,
    [ack_type | Path],
    TrUserData),
  case M of
    #{message_id := F3} ->
      if is_list(F3) ->
        _ = [v_msg_MessageIdData(Elem,
          [message_id | Path],
          TrUserData)
          || Elem <- F3],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'MessageIdData'}},
            F3,
            [message_id | Path])
      end;
    _ -> ok
  end,
  case M of
    #{validation_error := F4} ->
      'v_enum_CommandAck.ValidationError'(F4,
        [validation_error | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{properties := F5} ->
      if is_list(F5) ->
        _ = [v_msg_KeyLongValue(Elem,
          [properties | Path],
          TrUserData)
          || Elem <- F5],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'KeyLongValue'}},
            F5,
            [properties | Path])
      end;
    _ -> ok
  end,
  lists:foreach(fun (consumer_id) -> ok;
    (ack_type) -> ok;
    (message_id) -> ok;
    (validation_error) -> ok;
    (properties) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandAck(M, Path, _TrUserData) when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, ack_type] -- maps:keys(M),
    'CommandAck'},
    M,
    Path);
v_msg_CommandAck(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandAck'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandActiveConsumerChange, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandActiveConsumerChange, 3}}).

v_msg_CommandActiveConsumerChange(#{consumer_id := F1} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  case M of
    #{is_active := F2} ->
      v_type_bool(F2, [is_active | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (consumer_id) -> ok;
    (is_active) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandActiveConsumerChange(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id] -- maps:keys(M),
    'CommandActiveConsumerChange'},
    M,
    Path);
v_msg_CommandActiveConsumerChange(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandActiveConsumerChange'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandFlow, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandFlow, 3}}).

v_msg_CommandFlow(#{consumer_id := F1,
  messagePermits := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  v_type_uint32(F2, [messagePermits | Path], TrUserData),
  lists:foreach(fun (consumer_id) -> ok;
    (messagePermits) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandFlow(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, messagePermits] -- maps:keys(M),
    'CommandFlow'},
    M,
    Path);
v_msg_CommandFlow(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandFlow'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandUnsubscribe, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandUnsubscribe, 3}}).

v_msg_CommandUnsubscribe(#{consumer_id := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  lists:foreach(fun (consumer_id) -> ok;
    (request_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandUnsubscribe(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, request_id] -- maps:keys(M),
    'CommandUnsubscribe'},
    M,
    Path);
v_msg_CommandUnsubscribe(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandUnsubscribe'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandSeek, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandSeek, 3}}).

v_msg_CommandSeek(#{consumer_id := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  case M of
    #{message_id := F3} ->
      v_msg_MessageIdData(F3,
        [message_id | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{message_publish_time := F4} ->
      v_type_uint64(F4,
        [message_publish_time | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (consumer_id) -> ok;
    (request_id) -> ok;
    (message_id) -> ok;
    (message_publish_time) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandSeek(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, request_id] -- maps:keys(M),
    'CommandSeek'},
    M,
    Path);
v_msg_CommandSeek(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandSeek'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandReachedEndOfTopic, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandReachedEndOfTopic, 3}}).

v_msg_CommandReachedEndOfTopic(#{consumer_id := F1} = M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  lists:foreach(fun (consumer_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandReachedEndOfTopic(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id] -- maps:keys(M),
    'CommandReachedEndOfTopic'},
    M,
    Path);
v_msg_CommandReachedEndOfTopic(X, Path, _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandReachedEndOfTopic'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandCloseProducer, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandCloseProducer, 3}}).

v_msg_CommandCloseProducer(#{producer_id := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [producer_id | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  lists:foreach(fun (producer_id) -> ok;
    (request_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandCloseProducer(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [producer_id, request_id] -- maps:keys(M),
    'CommandCloseProducer'},
    M,
    Path);
v_msg_CommandCloseProducer(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandCloseProducer'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandCloseConsumer, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandCloseConsumer, 3}}).

v_msg_CommandCloseConsumer(#{consumer_id := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  lists:foreach(fun (consumer_id) -> ok;
    (request_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandCloseConsumer(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, request_id] -- maps:keys(M),
    'CommandCloseConsumer'},
    M,
    Path);
v_msg_CommandCloseConsumer(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandCloseConsumer'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandRedeliverUnacknowledgedMessages, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandRedeliverUnacknowledgedMessages, 3}}).

v_msg_CommandRedeliverUnacknowledgedMessages(#{consumer_id
:= F1} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  case M of
    #{message_ids := F2} ->
      if is_list(F2) ->
        _ = [v_msg_MessageIdData(Elem,
          [message_ids | Path],
          TrUserData)
          || Elem <- F2],
        ok;
        true ->
          mk_type_error({invalid_list_of, {msg, 'MessageIdData'}},
            F2,
            [message_ids | Path])
      end;
    _ -> ok
  end,
  lists:foreach(fun (consumer_id) -> ok;
    (message_ids) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandRedeliverUnacknowledgedMessages(M, Path,
    _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id] -- maps:keys(M),
    'CommandRedeliverUnacknowledgedMessages'},
    M,
    Path);
v_msg_CommandRedeliverUnacknowledgedMessages(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandRedeliverUnacknowledgedMessages'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandSuccess, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandSuccess, 3}}).

v_msg_CommandSuccess(#{request_id := F1} = M, Path,
    TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  case M of
    #{schema := F2} ->
      v_msg_Schema(F2, [schema | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (schema) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandSuccess(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id] -- maps:keys(M),
    'CommandSuccess'},
    M,
    Path);
v_msg_CommandSuccess(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandSuccess'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandProducerSuccess, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandProducerSuccess, 3}}).

v_msg_CommandProducerSuccess(#{request_id := F1,
  producer_name := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  v_type_string(F2, [producer_name | Path], TrUserData),
  case M of
    #{last_sequence_id := F3} ->
      v_type_int64(F3, [last_sequence_id | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{schema_version := F4} ->
      v_type_bytes(F4, [schema_version | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (producer_name) -> ok;
    (last_sequence_id) -> ok;
    (schema_version) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandProducerSuccess(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id, producer_name] -- maps:keys(M),
    'CommandProducerSuccess'},
    M,
    Path);
v_msg_CommandProducerSuccess(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandProducerSuccess'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandError, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandError, 3}}).

v_msg_CommandError(#{request_id := F1, error := F2,
  message := F3} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  v_enum_ServerError(F2, [error | Path], TrUserData),
  v_type_string(F3, [message | Path], TrUserData),
  lists:foreach(fun (request_id) -> ok;
    (error) -> ok;
    (message) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandError(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id, error, message] -- maps:keys(M),
    'CommandError'},
    M,
    Path);
v_msg_CommandError(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandError'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandPing, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandPing, 3}}).

v_msg_CommandPing(#{} = M, Path, _) ->
  lists:foreach(fun (OtherKey) ->
    mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandPing(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [] -- maps:keys(M),
    'CommandPing'},
    M,
    Path);
v_msg_CommandPing(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandPing'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandPong, 3}}).

-dialyzer({nowarn_function, {v_msg_CommandPong, 3}}).

v_msg_CommandPong(#{} = M, Path, _) ->
  lists:foreach(fun (OtherKey) ->
    mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandPong(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [] -- maps:keys(M),
    'CommandPong'},
    M,
    Path);
v_msg_CommandPong(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandPong'}, X, Path).

-compile({nowarn_unused_function,
  {v_msg_CommandConsumerStats, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandConsumerStats, 3}}).

v_msg_CommandConsumerStats(#{request_id := F1,
  consumer_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  v_type_uint64(F2, [consumer_id | Path], TrUserData),
  lists:foreach(fun (request_id) -> ok;
    (consumer_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandConsumerStats(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id, consumer_id] -- maps:keys(M),
    'CommandConsumerStats'},
    M,
    Path);
v_msg_CommandConsumerStats(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandConsumerStats'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandConsumerStatsResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandConsumerStatsResponse, 3}}).

v_msg_CommandConsumerStatsResponse(#{request_id := F1} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  case M of
    #{error_code := F2} ->
      v_enum_ServerError(F2, [error_code | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{error_message := F3} ->
      v_type_string(F3, [error_message | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{msgRateOut := F4} ->
      v_type_double(F4, [msgRateOut | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{msgThroughputOut := F5} ->
      v_type_double(F5,
        [msgThroughputOut | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{msgRateRedeliver := F6} ->
      v_type_double(F6,
        [msgRateRedeliver | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{consumerName := F7} ->
      v_type_string(F7, [consumerName | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{availablePermits := F8} ->
      v_type_uint64(F8,
        [availablePermits | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{unackedMessages := F9} ->
      v_type_uint64(F9, [unackedMessages | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{blockedConsumerOnUnackedMsgs := F10} ->
      v_type_bool(F10,
        [blockedConsumerOnUnackedMsgs | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{address := F11} ->
      v_type_string(F11, [address | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{connectedSince := F12} ->
      v_type_string(F12, [connectedSince | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{type := F13} ->
      v_type_string(F13, [type | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{msgRateExpired := F14} ->
      v_type_double(F14, [msgRateExpired | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{msgBacklog := F15} ->
      v_type_uint64(F15, [msgBacklog | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (error_code) -> ok;
    (error_message) -> ok;
    (msgRateOut) -> ok;
    (msgThroughputOut) -> ok;
    (msgRateRedeliver) -> ok;
    (consumerName) -> ok;
    (availablePermits) -> ok;
    (unackedMessages) -> ok;
    (blockedConsumerOnUnackedMsgs) -> ok;
    (address) -> ok;
    (connectedSince) -> ok;
    (type) -> ok;
    (msgRateExpired) -> ok;
    (msgBacklog) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandConsumerStatsResponse(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id] -- maps:keys(M),
    'CommandConsumerStatsResponse'},
    M,
    Path);
v_msg_CommandConsumerStatsResponse(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandConsumerStatsResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandGetLastMessageId, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandGetLastMessageId, 3}}).

v_msg_CommandGetLastMessageId(#{consumer_id := F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [consumer_id | Path], TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  lists:foreach(fun (consumer_id) -> ok;
    (request_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandGetLastMessageId(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [consumer_id, request_id] -- maps:keys(M),
    'CommandGetLastMessageId'},
    M,
    Path);
v_msg_CommandGetLastMessageId(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandGetLastMessageId'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandGetLastMessageIdResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandGetLastMessageIdResponse, 3}}).

v_msg_CommandGetLastMessageIdResponse(#{last_message_id
:= F1,
  request_id := F2} =
  M,
    Path, TrUserData) ->
  v_msg_MessageIdData(F1,
    [last_message_id | Path],
    TrUserData),
  v_type_uint64(F2, [request_id | Path], TrUserData),
  lists:foreach(fun (last_message_id) -> ok;
    (request_id) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandGetLastMessageIdResponse(M, Path,
    _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [last_message_id, request_id] -- maps:keys(M),
    'CommandGetLastMessageIdResponse'},
    M,
    Path);
v_msg_CommandGetLastMessageIdResponse(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandGetLastMessageIdResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandGetTopicsOfNamespace, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandGetTopicsOfNamespace, 3}}).

v_msg_CommandGetTopicsOfNamespace(#{request_id := F1,
  namespace := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  v_type_string(F2, [namespace | Path], TrUserData),
  case M of
    #{mode := F3} ->
      'v_enum_CommandGetTopicsOfNamespace.Mode'(F3,
        [mode | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (namespace) -> ok;
    (mode) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandGetTopicsOfNamespace(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id, namespace] -- maps:keys(M),
    'CommandGetTopicsOfNamespace'},
    M,
    Path);
v_msg_CommandGetTopicsOfNamespace(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandGetTopicsOfNamespace'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandGetTopicsOfNamespaceResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandGetTopicsOfNamespaceResponse, 3}}).

v_msg_CommandGetTopicsOfNamespaceResponse(#{request_id
:= F1} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  case M of
    #{topics := F2} ->
      if is_list(F2) ->
        _ = [v_type_string(Elem, [topics | Path], TrUserData)
          || Elem <- F2],
        ok;
        true ->
          mk_type_error({invalid_list_of, string},
            F2,
            [topics | Path])
      end;
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (topics) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandGetTopicsOfNamespaceResponse(M, Path,
    _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id] -- maps:keys(M),
    'CommandGetTopicsOfNamespaceResponse'},
    M,
    Path);
v_msg_CommandGetTopicsOfNamespaceResponse(X, Path,
    _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandGetTopicsOfNamespaceResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandGetSchema, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandGetSchema, 3}}).

v_msg_CommandGetSchema(#{request_id := F1,
  topic := F2} =
  M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  v_type_string(F2, [topic | Path], TrUserData),
  case M of
    #{schema_version := F3} ->
      v_type_bytes(F3, [schema_version | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (topic) -> ok;
    (schema_version) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandGetSchema(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id, topic] -- maps:keys(M),
    'CommandGetSchema'},
    M,
    Path);
v_msg_CommandGetSchema(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'CommandGetSchema'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_CommandGetSchemaResponse, 3}}).

-dialyzer({nowarn_function,
  {v_msg_CommandGetSchemaResponse, 3}}).

v_msg_CommandGetSchemaResponse(#{request_id := F1} = M,
    Path, TrUserData) ->
  v_type_uint64(F1, [request_id | Path], TrUserData),
  case M of
    #{error_code := F2} ->
      v_enum_ServerError(F2, [error_code | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{error_message := F3} ->
      v_type_string(F3, [error_message | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{schema := F4} ->
      v_msg_Schema(F4, [schema | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{schema_version := F5} ->
      v_type_bytes(F5, [schema_version | Path], TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (request_id) -> ok;
    (error_code) -> ok;
    (error_message) -> ok;
    (schema) -> ok;
    (schema_version) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_CommandGetSchemaResponse(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [request_id] -- maps:keys(M),
    'CommandGetSchemaResponse'},
    M,
    Path);
v_msg_CommandGetSchemaResponse(X, Path, _TrUserData) ->
  mk_type_error({expected_msg,
    'CommandGetSchemaResponse'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_msg_BaseCommand, 3}}).

-dialyzer({nowarn_function, {v_msg_BaseCommand, 3}}).

v_msg_BaseCommand(#{type := F1} = M, Path,
    TrUserData) ->
  'v_enum_BaseCommand.Type'(F1,
    [type | Path],
    TrUserData),
  case M of
    #{connect := F2} ->
      v_msg_CommandConnect(F2, [connect | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{connected := F3} ->
      v_msg_CommandConnected(F3,
        [connected | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{subscribe := F4} ->
      v_msg_CommandSubscribe(F4,
        [subscribe | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{producer := F5} ->
      v_msg_CommandProducer(F5,
        [producer | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{send := F6} ->
      v_msg_CommandSend(F6, [send | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{send_receipt := F7} ->
      v_msg_CommandSendReceipt(F7,
        [send_receipt | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{send_error := F8} ->
      v_msg_CommandSendError(F8,
        [send_error | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{message := F9} ->
      v_msg_CommandMessage(F9, [message | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{ack := F10} ->
      v_msg_CommandAck(F10, [ack | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{flow := F11} ->
      v_msg_CommandFlow(F11, [flow | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{unsubscribe := F12} ->
      v_msg_CommandUnsubscribe(F12,
        [unsubscribe | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{success := F13} ->
      v_msg_CommandSuccess(F13, [success | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{error := F14} ->
      v_msg_CommandError(F14, [error | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{close_producer := F15} ->
      v_msg_CommandCloseProducer(F15,
        [close_producer | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{close_consumer := F16} ->
      v_msg_CommandCloseConsumer(F16,
        [close_consumer | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{producer_success := F17} ->
      v_msg_CommandProducerSuccess(F17,
        [producer_success | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{ping := F18} ->
      v_msg_CommandPing(F18, [ping | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{pong := F19} ->
      v_msg_CommandPong(F19, [pong | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{redeliverUnacknowledgedMessages := F20} ->
      v_msg_CommandRedeliverUnacknowledgedMessages(F20,
        [redeliverUnacknowledgedMessages
          | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{partitionMetadata := F21} ->
      v_msg_CommandPartitionedTopicMetadata(F21,
        [partitionMetadata | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{partitionMetadataResponse := F22} ->
      v_msg_CommandPartitionedTopicMetadataResponse(F22,
        [partitionMetadataResponse
          | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{lookupTopic := F23} ->
      v_msg_CommandLookupTopic(F23,
        [lookupTopic | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{lookupTopicResponse := F24} ->
      v_msg_CommandLookupTopicResponse(F24,
        [lookupTopicResponse | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{consumerStats := F25} ->
      v_msg_CommandConsumerStats(F25,
        [consumerStats | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{consumerStatsResponse := F26} ->
      v_msg_CommandConsumerStatsResponse(F26,
        [consumerStatsResponse | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{reachedEndOfTopic := F27} ->
      v_msg_CommandReachedEndOfTopic(F27,
        [reachedEndOfTopic | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{seek := F28} ->
      v_msg_CommandSeek(F28, [seek | Path], TrUserData);
    _ -> ok
  end,
  case M of
    #{getLastMessageId := F29} ->
      v_msg_CommandGetLastMessageId(F29,
        [getLastMessageId | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{getLastMessageIdResponse := F30} ->
      v_msg_CommandGetLastMessageIdResponse(F30,
        [getLastMessageIdResponse
          | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{active_consumer_change := F31} ->
      v_msg_CommandActiveConsumerChange(F31,
        [active_consumer_change | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{getTopicsOfNamespace := F32} ->
      v_msg_CommandGetTopicsOfNamespace(F32,
        [getTopicsOfNamespace | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{getTopicsOfNamespaceResponse := F33} ->
      v_msg_CommandGetTopicsOfNamespaceResponse(F33,
        [getTopicsOfNamespaceResponse
          | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{getSchema := F34} ->
      v_msg_CommandGetSchema(F34,
        [getSchema | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{getSchemaResponse := F35} ->
      v_msg_CommandGetSchemaResponse(F35,
        [getSchemaResponse | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{authChallenge := F36} ->
      v_msg_CommandAuthChallenge(F36,
        [authChallenge | Path],
        TrUserData);
    _ -> ok
  end,
  case M of
    #{authResponse := F37} ->
      v_msg_CommandAuthResponse(F37,
        [authResponse | Path],
        TrUserData);
    _ -> ok
  end,
  lists:foreach(fun (type) -> ok;
    (connect) -> ok;
    (connected) -> ok;
    (subscribe) -> ok;
    (producer) -> ok;
    (send) -> ok;
    (send_receipt) -> ok;
    (send_error) -> ok;
    (message) -> ok;
    (ack) -> ok;
    (flow) -> ok;
    (unsubscribe) -> ok;
    (success) -> ok;
    (error) -> ok;
    (close_producer) -> ok;
    (close_consumer) -> ok;
    (producer_success) -> ok;
    (ping) -> ok;
    (pong) -> ok;
    (redeliverUnacknowledgedMessages) -> ok;
    (partitionMetadata) -> ok;
    (partitionMetadataResponse) -> ok;
    (lookupTopic) -> ok;
    (lookupTopicResponse) -> ok;
    (consumerStats) -> ok;
    (consumerStatsResponse) -> ok;
    (reachedEndOfTopic) -> ok;
    (seek) -> ok;
    (getLastMessageId) -> ok;
    (getLastMessageIdResponse) -> ok;
    (active_consumer_change) -> ok;
    (getTopicsOfNamespace) -> ok;
    (getTopicsOfNamespaceResponse) -> ok;
    (getSchema) -> ok;
    (getSchemaResponse) -> ok;
    (authChallenge) -> ok;
    (authResponse) -> ok;
    (OtherKey) ->
      mk_type_error({extraneous_key, OtherKey}, M, Path)
                end,
    maps:keys(M)),
  ok;
v_msg_BaseCommand(M, Path, _TrUserData)
  when is_map(M) ->
  mk_type_error({missing_fields,
      [type] -- maps:keys(M),
    'BaseCommand'},
    M,
    Path);
v_msg_BaseCommand(X, Path, _TrUserData) ->
  mk_type_error({expected_msg, 'BaseCommand'}, X, Path).

-compile({nowarn_unused_function,
  {'v_enum_Schema.Type', 3}}).

-dialyzer({nowarn_function, {'v_enum_Schema.Type', 3}}).

'v_enum_Schema.Type'('None', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('String', _Path, _TrUserData) ->
  ok;
'v_enum_Schema.Type'('Json', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Protobuf', _Path, _TrUserData) ->
  ok;
'v_enum_Schema.Type'('Avro', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Bool', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Int8', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Int16', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Int32', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Int64', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Float', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Double', _Path, _TrUserData) ->
  ok;
'v_enum_Schema.Type'('Date', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Time', _Path, _TrUserData) -> ok;
'v_enum_Schema.Type'('Timestamp', _Path, _TrUserData) ->
  ok;
'v_enum_Schema.Type'('KeyValue', _Path, _TrUserData) ->
  ok;
'v_enum_Schema.Type'(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_Schema.Type'(X, Path, _TrUserData) ->
  mk_type_error({invalid_enum, 'Schema.Type'}, X, Path).

-compile({nowarn_unused_function,
  {v_enum_CompressionType, 3}}).

-dialyzer({nowarn_function,
  {v_enum_CompressionType, 3}}).

v_enum_CompressionType('NONE', _Path, _TrUserData) ->
  ok;
v_enum_CompressionType('LZ4', _Path, _TrUserData) -> ok;
v_enum_CompressionType('ZLIB', _Path, _TrUserData) ->
  ok;
v_enum_CompressionType('ZSTD', _Path, _TrUserData) ->
  ok;
v_enum_CompressionType(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
v_enum_CompressionType(X, Path, _TrUserData) ->
  mk_type_error({invalid_enum, 'CompressionType'},
    X,
    Path).

-compile({nowarn_unused_function,
  {v_enum_ServerError, 3}}).

-dialyzer({nowarn_function, {v_enum_ServerError, 3}}).

v_enum_ServerError('UnknownError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('MetadataError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('PersistenceError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('AuthenticationError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('AuthorizationError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('ConsumerBusy', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('ServiceNotReady', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('ProducerBlockedQuotaExceededError',
    _Path, _TrUserData) ->
  ok;
v_enum_ServerError('ProducerBlockedQuotaExceededException',
    _Path, _TrUserData) ->
  ok;
v_enum_ServerError('ChecksumError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('UnsupportedVersionError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('TopicNotFound', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('SubscriptionNotFound', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('ConsumerNotFound', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('TooManyRequests', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('TopicTerminatedError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('ProducerBusy', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('InvalidTopicName', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('IncompatibleSchema', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError('ConsumerAssignError', _Path,
    _TrUserData) ->
  ok;
v_enum_ServerError(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
v_enum_ServerError(X, Path, _TrUserData) ->
  mk_type_error({invalid_enum, 'ServerError'}, X, Path).

-compile({nowarn_unused_function,
  {v_enum_AuthMethod, 3}}).

-dialyzer({nowarn_function, {v_enum_AuthMethod, 3}}).

v_enum_AuthMethod('AuthMethodNone', _Path,
    _TrUserData) ->
  ok;
v_enum_AuthMethod('AuthMethodYcaV1', _Path,
    _TrUserData) ->
  ok;
v_enum_AuthMethod('AuthMethodAthens', _Path,
    _TrUserData) ->
  ok;
v_enum_AuthMethod(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
v_enum_AuthMethod(X, Path, _TrUserData) ->
  mk_type_error({invalid_enum, 'AuthMethod'}, X, Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandSubscribe.SubType', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandSubscribe.SubType', 3}}).

'v_enum_CommandSubscribe.SubType'('Exclusive', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandSubscribe.SubType'('Shared', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandSubscribe.SubType'('Failover', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandSubscribe.SubType'('Key_Shared', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandSubscribe.SubType'(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandSubscribe.SubType'(X, Path,
    _TrUserData) ->
  mk_type_error({invalid_enum,
    'CommandSubscribe.SubType'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandSubscribe.InitialPosition', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandSubscribe.InitialPosition', 3}}).

'v_enum_CommandSubscribe.InitialPosition'('Latest',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandSubscribe.InitialPosition'('Earliest',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandSubscribe.InitialPosition'(V, Path,
    TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandSubscribe.InitialPosition'(X, Path,
    _TrUserData) ->
  mk_type_error({invalid_enum,
    'CommandSubscribe.InitialPosition'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandPartitionedTopicMetadataResponse.LookupType',
    3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandPartitionedTopicMetadataResponse.LookupType',
    3}}).

'v_enum_CommandPartitionedTopicMetadataResponse.LookupType'('Success',
    _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandPartitionedTopicMetadataResponse.LookupType'('Failed',
    _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandPartitionedTopicMetadataResponse.LookupType'(V,
    Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandPartitionedTopicMetadataResponse.LookupType'(X,
    Path,
    _TrUserData) ->
  mk_type_error({invalid_enum,
    'CommandPartitionedTopicMetadataResponse.LookupType'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandLookupTopicResponse.LookupType', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandLookupTopicResponse.LookupType', 3}}).

'v_enum_CommandLookupTopicResponse.LookupType'('Redirect',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandLookupTopicResponse.LookupType'('Connect',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandLookupTopicResponse.LookupType'('Failed',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandLookupTopicResponse.LookupType'(V, Path,
    TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandLookupTopicResponse.LookupType'(X, Path,
    _TrUserData) ->
  mk_type_error({invalid_enum,
    'CommandLookupTopicResponse.LookupType'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandAck.AckType', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandAck.AckType', 3}}).

'v_enum_CommandAck.AckType'('Individual', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandAck.AckType'('Cumulative', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandAck.AckType'(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandAck.AckType'(X, Path, _TrUserData) ->
  mk_type_error({invalid_enum, 'CommandAck.AckType'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandAck.ValidationError', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandAck.ValidationError', 3}}).

'v_enum_CommandAck.ValidationError'('UncompressedSizeCorruption',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandAck.ValidationError'('DecompressionError',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandAck.ValidationError'('ChecksumMismatch',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandAck.ValidationError'('BatchDeSerializeError',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandAck.ValidationError'('DecryptionError',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandAck.ValidationError'(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandAck.ValidationError'(X, Path,
    _TrUserData) ->
  mk_type_error({invalid_enum,
    'CommandAck.ValidationError'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_CommandGetTopicsOfNamespace.Mode', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_CommandGetTopicsOfNamespace.Mode', 3}}).

'v_enum_CommandGetTopicsOfNamespace.Mode'('PERSISTENT',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandGetTopicsOfNamespace.Mode'('NON_PERSISTENT',
    _Path, _TrUserData) ->
  ok;
'v_enum_CommandGetTopicsOfNamespace.Mode'('ALL', _Path,
    _TrUserData) ->
  ok;
'v_enum_CommandGetTopicsOfNamespace.Mode'(V, Path,
    TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_CommandGetTopicsOfNamespace.Mode'(X, Path,
    _TrUserData) ->
  mk_type_error({invalid_enum,
    'CommandGetTopicsOfNamespace.Mode'},
    X,
    Path).

-compile({nowarn_unused_function,
  {'v_enum_BaseCommand.Type', 3}}).

-dialyzer({nowarn_function,
  {'v_enum_BaseCommand.Type', 3}}).

'v_enum_BaseCommand.Type'('CONNECT', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('CONNECTED', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('SUBSCRIBE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('PRODUCER', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('SEND', _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('SEND_RECEIPT', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('SEND_ERROR', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('MESSAGE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('ACK', _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('FLOW', _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('UNSUBSCRIBE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('SUCCESS', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('ERROR', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('CLOSE_PRODUCER', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('CLOSE_CONSUMER', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('PRODUCER_SUCCESS', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('PING', _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('PONG', _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('REDELIVER_UNACKNOWLEDGED_MESSAGES',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('PARTITIONED_METADATA', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('PARTITIONED_METADATA_RESPONSE',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('LOOKUP', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('LOOKUP_RESPONSE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('CONSUMER_STATS', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('CONSUMER_STATS_RESPONSE',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('REACHED_END_OF_TOPIC', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('SEEK', _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('GET_LAST_MESSAGE_ID', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('GET_LAST_MESSAGE_ID_RESPONSE',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('ACTIVE_CONSUMER_CHANGE',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('GET_TOPICS_OF_NAMESPACE',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('GET_TOPICS_OF_NAMESPACE_RESPONSE',
    _Path, _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('GET_SCHEMA', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('GET_SCHEMA_RESPONSE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('AUTH_CHALLENGE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'('AUTH_RESPONSE', _Path,
    _TrUserData) ->
  ok;
'v_enum_BaseCommand.Type'(V, Path, TrUserData)
  when is_integer(V) ->
  v_type_sint32(V, Path, TrUserData);
'v_enum_BaseCommand.Type'(X, Path, _TrUserData) ->
  mk_type_error({invalid_enum, 'BaseCommand.Type'},
    X,
    Path).

-compile({nowarn_unused_function, {v_type_sint32, 3}}).

-dialyzer({nowarn_function, {v_type_sint32, 3}}).

v_type_sint32(N, _Path, _TrUserData)
  when -2147483648 =< N, N =< 2147483647 ->
  ok;
v_type_sint32(N, Path, _TrUserData)
  when is_integer(N) ->
  mk_type_error({value_out_of_range, sint32, signed, 32},
    N,
    Path);
v_type_sint32(X, Path, _TrUserData) ->
  mk_type_error({bad_integer, sint32, signed, 32},
    X,
    Path).

-compile({nowarn_unused_function, {v_type_int32, 3}}).

-dialyzer({nowarn_function, {v_type_int32, 3}}).

v_type_int32(N, _Path, _TrUserData)
  when -2147483648 =< N, N =< 2147483647 ->
  ok;
v_type_int32(N, Path, _TrUserData) when is_integer(N) ->
  mk_type_error({value_out_of_range, int32, signed, 32},
    N,
    Path);
v_type_int32(X, Path, _TrUserData) ->
  mk_type_error({bad_integer, int32, signed, 32},
    X,
    Path).

-compile({nowarn_unused_function, {v_type_int64, 3}}).

-dialyzer({nowarn_function, {v_type_int64, 3}}).

v_type_int64(N, _Path, _TrUserData)
  when -9223372036854775808 =< N,
  N =< 9223372036854775807 ->
  ok;
v_type_int64(N, Path, _TrUserData) when is_integer(N) ->
  mk_type_error({value_out_of_range, int64, signed, 64},
    N,
    Path);
v_type_int64(X, Path, _TrUserData) ->
  mk_type_error({bad_integer, int64, signed, 64},
    X,
    Path).

-compile({nowarn_unused_function, {v_type_uint32, 3}}).

-dialyzer({nowarn_function, {v_type_uint32, 3}}).

v_type_uint32(N, _Path, _TrUserData)
  when 0 =< N, N =< 4294967295 ->
  ok;
v_type_uint32(N, Path, _TrUserData)
  when is_integer(N) ->
  mk_type_error({value_out_of_range,
    uint32,
    unsigned,
    32},
    N,
    Path);
v_type_uint32(X, Path, _TrUserData) ->
  mk_type_error({bad_integer, uint32, unsigned, 32},
    X,
    Path).

-compile({nowarn_unused_function, {v_type_uint64, 3}}).

-dialyzer({nowarn_function, {v_type_uint64, 3}}).

v_type_uint64(N, _Path, _TrUserData)
  when 0 =< N, N =< 18446744073709551615 ->
  ok;
v_type_uint64(N, Path, _TrUserData)
  when is_integer(N) ->
  mk_type_error({value_out_of_range,
    uint64,
    unsigned,
    64},
    N,
    Path);
v_type_uint64(X, Path, _TrUserData) ->
  mk_type_error({bad_integer, uint64, unsigned, 64},
    X,
    Path).

-compile({nowarn_unused_function, {v_type_bool, 3}}).

-dialyzer({nowarn_function, {v_type_bool, 3}}).

v_type_bool(false, _Path, _TrUserData) -> ok;
v_type_bool(true, _Path, _TrUserData) -> ok;
v_type_bool(0, _Path, _TrUserData) -> ok;
v_type_bool(1, _Path, _TrUserData) -> ok;
v_type_bool(X, Path, _TrUserData) ->
  mk_type_error(bad_boolean_value, X, Path).

-compile({nowarn_unused_function, {v_type_double, 3}}).

-dialyzer({nowarn_function, {v_type_double, 3}}).

v_type_double(N, _Path, _TrUserData) when is_float(N) ->
  ok;
v_type_double(N, _Path, _TrUserData)
  when is_integer(N) ->
  ok;
v_type_double(infinity, _Path, _TrUserData) -> ok;
v_type_double('-infinity', _Path, _TrUserData) -> ok;
v_type_double(nan, _Path, _TrUserData) -> ok;
v_type_double(X, Path, _TrUserData) ->
  mk_type_error(bad_double_value, X, Path).

-compile({nowarn_unused_function, {v_type_string, 3}}).

-dialyzer({nowarn_function, {v_type_string, 3}}).

v_type_string(S, Path, _TrUserData)
  when is_list(S); is_binary(S) ->
  try unicode:characters_to_binary(S) of
    B when is_binary(B) -> ok;
    {error, _, _} ->
      mk_type_error(bad_unicode_string, S, Path)
  catch
    error:badarg ->
      mk_type_error(bad_unicode_string, S, Path)
  end;
v_type_string(X, Path, _TrUserData) ->
  mk_type_error(bad_unicode_string, X, Path).

-compile({nowarn_unused_function, {v_type_bytes, 3}}).

-dialyzer({nowarn_function, {v_type_bytes, 3}}).

v_type_bytes(B, _Path, _TrUserData) when is_binary(B) ->
  ok;
v_type_bytes(B, _Path, _TrUserData) when is_list(B) ->
  ok;
v_type_bytes(X, Path, _TrUserData) ->
  mk_type_error(bad_binary_value, X, Path).

-compile({nowarn_unused_function, {mk_type_error, 3}}).

-spec mk_type_error(_, _, list()) -> no_return().

mk_type_error(Error, ValueSeen, Path) ->
  Path2 = prettify_path(Path),
  erlang:error({gpb_type_error,
    {Error, [{value, ValueSeen}, {path, Path2}]}}).

-compile({nowarn_unused_function, {prettify_path, 1}}).

-dialyzer({nowarn_function, {prettify_path, 1}}).

prettify_path([]) -> top_level;
prettify_path(PathR) ->
  list_to_atom(lists:append(lists:join(".",
    lists:map(fun atom_to_list/1,
      lists:reverse(PathR))))).

-compile({nowarn_unused_function, {id, 2}}).

-compile({inline, {id, 2}}).

id(X, _TrUserData) -> X.

-compile({nowarn_unused_function, {v_ok, 3}}).

-compile({inline, {v_ok, 3}}).

v_ok(_Value, _Path, _TrUserData) -> ok.

-compile({nowarn_unused_function, {m_overwrite, 3}}).

-compile({inline, {m_overwrite, 3}}).

m_overwrite(_Prev, New, _TrUserData) -> New.

-compile({nowarn_unused_function, {cons, 3}}).

-compile({inline, {cons, 3}}).

cons(Elem, Acc, _TrUserData) -> [Elem | Acc].

-compile({nowarn_unused_function, {lists_reverse, 2}}).

-compile({inline, {lists_reverse, 2}}).

lists_reverse(L, _TrUserData) -> lists:reverse(L).

-compile({nowarn_unused_function, {'erlang_++', 3}}).

-compile({inline, {'erlang_++', 3}}).

'erlang_++'(A, B, _TrUserData) -> A ++ B.

get_msg_defs() ->
  [{{enum, 'Schema.Type'},
    [{'None', 0},
      {'String', 1},
      {'Json', 2},
      {'Protobuf', 3},
      {'Avro', 4},
      {'Bool', 5},
      {'Int8', 6},
      {'Int16', 7},
      {'Int32', 8},
      {'Int64', 9},
      {'Float', 10},
      {'Double', 11},
      {'Date', 12},
      {'Time', 13},
      {'Timestamp', 14},
      {'KeyValue', 15}]},
    {{enum, 'CompressionType'},
      [{'NONE', 0}, {'LZ4', 1}, {'ZLIB', 2}, {'ZSTD', 3}]},
    {{enum, 'ServerError'},
      [{'UnknownError', 0},
        {'MetadataError', 1},
        {'PersistenceError', 2},
        {'AuthenticationError', 3},
        {'AuthorizationError', 4},
        {'ConsumerBusy', 5},
        {'ServiceNotReady', 6},
        {'ProducerBlockedQuotaExceededError', 7},
        {'ProducerBlockedQuotaExceededException', 8},
        {'ChecksumError', 9},
        {'UnsupportedVersionError', 10},
        {'TopicNotFound', 11},
        {'SubscriptionNotFound', 12},
        {'ConsumerNotFound', 13},
        {'TooManyRequests', 14},
        {'TopicTerminatedError', 15},
        {'ProducerBusy', 16},
        {'InvalidTopicName', 17},
        {'IncompatibleSchema', 18},
        {'ConsumerAssignError', 19}]},
    {{enum, 'AuthMethod'},
      [{'AuthMethodNone', 0},
        {'AuthMethodYcaV1', 1},
        {'AuthMethodAthens', 2}]},
    {{enum, 'ProtocolVersion'},
      [{v0, 0},
        {v1, 1},
        {v2, 2},
        {v3, 3},
        {v4, 4},
        {v5, 5},
        {v6, 6},
        {v7, 7},
        {v8, 8},
        {v9, 9},
        {v10, 10},
        {v11, 11},
        {v12, 12},
        {v13, 13},
        {v14, 14}]},
    {{enum, 'CommandSubscribe.SubType'},
      [{'Exclusive', 0},
        {'Shared', 1},
        {'Failover', 2},
        {'Key_Shared', 3}]},
    {{enum, 'CommandSubscribe.InitialPosition'},
      [{'Latest', 0}, {'Earliest', 1}]},
    {{enum,
      'CommandPartitionedTopicMetadataResponse.LookupType'},
      [{'Success', 0}, {'Failed', 1}]},
    {{enum, 'CommandLookupTopicResponse.LookupType'},
      [{'Redirect', 0}, {'Connect', 1}, {'Failed', 2}]},
    {{enum, 'CommandAck.AckType'},
      [{'Individual', 0}, {'Cumulative', 1}]},
    {{enum, 'CommandAck.ValidationError'},
      [{'UncompressedSizeCorruption', 0},
        {'DecompressionError', 1},
        {'ChecksumMismatch', 2},
        {'BatchDeSerializeError', 3},
        {'DecryptionError', 4}]},
    {{enum, 'CommandGetTopicsOfNamespace.Mode'},
      [{'PERSISTENT', 0}, {'NON_PERSISTENT', 1}, {'ALL', 2}]},
    {{enum, 'BaseCommand.Type'},
      [{'CONNECT', 2},
        {'CONNECTED', 3},
        {'SUBSCRIBE', 4},
        {'PRODUCER', 5},
        {'SEND', 6},
        {'SEND_RECEIPT', 7},
        {'SEND_ERROR', 8},
        {'MESSAGE', 9},
        {'ACK', 10},
        {'FLOW', 11},
        {'UNSUBSCRIBE', 12},
        {'SUCCESS', 13},
        {'ERROR', 14},
        {'CLOSE_PRODUCER', 15},
        {'CLOSE_CONSUMER', 16},
        {'PRODUCER_SUCCESS', 17},
        {'PING', 18},
        {'PONG', 19},
        {'REDELIVER_UNACKNOWLEDGED_MESSAGES', 20},
        {'PARTITIONED_METADATA', 21},
        {'PARTITIONED_METADATA_RESPONSE', 22},
        {'LOOKUP', 23},
        {'LOOKUP_RESPONSE', 24},
        {'CONSUMER_STATS', 25},
        {'CONSUMER_STATS_RESPONSE', 26},
        {'REACHED_END_OF_TOPIC', 27},
        {'SEEK', 28},
        {'GET_LAST_MESSAGE_ID', 29},
        {'GET_LAST_MESSAGE_ID_RESPONSE', 30},
        {'ACTIVE_CONSUMER_CHANGE', 31},
        {'GET_TOPICS_OF_NAMESPACE', 32},
        {'GET_TOPICS_OF_NAMESPACE_RESPONSE', 33},
        {'GET_SCHEMA', 34},
        {'GET_SCHEMA_RESPONSE', 35},
        {'AUTH_CHALLENGE', 36},
        {'AUTH_RESPONSE', 37}]},
    {{msg, 'Schema'},
      [#{name => name, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => schema_data, fnum => 3, rnum => 3,
          type => bytes, occurrence => required, opts => []},
        #{name => type, fnum => 4, rnum => 4,
          type => {enum, 'Schema.Type'}, occurrence => required,
          opts => []},
        #{name => properties, fnum => 5, rnum => 5,
          type => {msg, 'KeyValue'}, occurrence => repeated,
          opts => []}]},
    {{msg, 'MessageIdData'},
      [#{name => ledgerId, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => entryId, fnum => 2, rnum => 3, type => uint64,
          occurrence => required, opts => []},
        #{name => partition, fnum => 3, rnum => 4,
          type => int32, occurrence => optional,
          opts => [{default, -1}]},
        #{name => batch_index, fnum => 4, rnum => 5,
          type => int32, occurrence => optional,
          opts => [{default, -1}]}]},
    {{msg, 'KeyValue'},
      [#{name => key, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => value, fnum => 2, rnum => 3, type => string,
          occurrence => required, opts => []}]},
    {{msg, 'KeyLongValue'},
      [#{name => key, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => value, fnum => 2, rnum => 3, type => uint64,
          occurrence => required, opts => []}]},
    {{msg, 'EncryptionKeys'},
      [#{name => key, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => value, fnum => 2, rnum => 3, type => bytes,
          occurrence => required, opts => []},
        #{name => metadata, fnum => 3, rnum => 4,
          type => {msg, 'KeyValue'}, occurrence => repeated,
          opts => []}]},
    {{msg, 'MessageMetadata'},
      [#{name => producer_name, fnum => 1, rnum => 2,
        type => string, occurrence => required, opts => []},
        #{name => sequence_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => publish_time, fnum => 3, rnum => 4,
          type => uint64, occurrence => required, opts => []},
        #{name => properties, fnum => 4, rnum => 5,
          type => {msg, 'KeyValue'}, occurrence => repeated,
          opts => []},
        #{name => replicated_from, fnum => 5, rnum => 6,
          type => string, occurrence => optional, opts => []},
        #{name => partition_key, fnum => 6, rnum => 7,
          type => string, occurrence => optional, opts => []},
        #{name => replicate_to, fnum => 7, rnum => 8,
          type => string, occurrence => repeated, opts => []},
        #{name => compression, fnum => 8, rnum => 9,
          type => {enum, 'CompressionType'},
          occurrence => optional, opts => [{default, 'NONE'}]},
        #{name => uncompressed_size, fnum => 9, rnum => 10,
          type => uint32, occurrence => optional,
          opts => [{default, 0}]},
        #{name => num_messages_in_batch, fnum => 11, rnum => 11,
          type => int32, occurrence => optional,
          opts => [{default, 1}]},
        #{name => event_time, fnum => 12, rnum => 12,
          type => uint64, occurrence => optional,
          opts => [{default, 0}]},
        #{name => encryption_keys, fnum => 13, rnum => 13,
          type => {msg, 'EncryptionKeys'}, occurrence => repeated,
          opts => []},
        #{name => encryption_algo, fnum => 14, rnum => 14,
          type => string, occurrence => optional, opts => []},
        #{name => encryption_param, fnum => 15, rnum => 15,
          type => bytes, occurrence => optional, opts => []},
        #{name => schema_version, fnum => 16, rnum => 16,
          type => bytes, occurrence => optional, opts => []},
        #{name => partition_key_b64_encoded, fnum => 17,
          rnum => 17, type => bool, occurrence => optional,
          opts => [{default, false}]},
        #{name => ordering_key, fnum => 18, rnum => 18,
          type => bytes, occurrence => optional, opts => []}]},
    {{msg, 'SingleMessageMetadata'},
      [#{name => properties, fnum => 1, rnum => 2,
        type => {msg, 'KeyValue'}, occurrence => repeated,
        opts => []},
        #{name => partition_key, fnum => 2, rnum => 3,
          type => string, occurrence => optional, opts => []},
        #{name => payload_size, fnum => 3, rnum => 4,
          type => int32, occurrence => required, opts => []},
        #{name => compacted_out, fnum => 4, rnum => 5,
          type => bool, occurrence => optional,
          opts => [{default, false}]},
        #{name => event_time, fnum => 5, rnum => 6,
          type => uint64, occurrence => optional,
          opts => [{default, 0}]},
        #{name => partition_key_b64_encoded, fnum => 6,
          rnum => 7, type => bool, occurrence => optional,
          opts => [{default, false}]},
        #{name => ordering_key, fnum => 7, rnum => 8,
          type => bytes, occurrence => optional, opts => []}]},
    {{msg, 'CommandConnect'},
      [#{name => client_version, fnum => 1, rnum => 2,
        type => string, occurrence => required, opts => []},
        #{name => auth_method, fnum => 2, rnum => 3,
          type => {enum, 'AuthMethod'}, occurrence => optional,
          opts => []},
        #{name => auth_method_name, fnum => 5, rnum => 4,
          type => string, occurrence => optional, opts => []},
        #{name => auth_data, fnum => 3, rnum => 5,
          type => bytes, occurrence => optional, opts => []},
        #{name => protocol_version, fnum => 4, rnum => 6,
          type => int32, occurrence => optional,
          opts => [{default, 0}]},
        #{name => proxy_to_broker_url, fnum => 6, rnum => 7,
          type => string, occurrence => optional, opts => []},
        #{name => original_principal, fnum => 7, rnum => 8,
          type => string, occurrence => optional, opts => []},
        #{name => original_auth_data, fnum => 8, rnum => 9,
          type => string, occurrence => optional, opts => []},
        #{name => original_auth_method, fnum => 9, rnum => 10,
          type => string, occurrence => optional, opts => []}]},
    {{msg, 'CommandConnected'},
      [#{name => server_version, fnum => 1, rnum => 2,
        type => string, occurrence => required, opts => []},
        #{name => protocol_version, fnum => 2, rnum => 3,
          type => int32, occurrence => optional,
          opts => [{default, 0}]}]},
    {{msg, 'CommandAuthResponse'},
      [#{name => client_version, fnum => 1, rnum => 2,
        type => string, occurrence => optional, opts => []},
        #{name => response, fnum => 2, rnum => 3,
          type => {msg, 'AuthData'}, occurrence => optional,
          opts => []},
        #{name => protocol_version, fnum => 3, rnum => 4,
          type => int32, occurrence => optional,
          opts => [{default, 0}]}]},
    {{msg, 'CommandAuthChallenge'},
      [#{name => server_version, fnum => 1, rnum => 2,
        type => string, occurrence => optional, opts => []},
        #{name => challenge, fnum => 2, rnum => 3,
          type => {msg, 'AuthData'}, occurrence => optional,
          opts => []},
        #{name => protocol_version, fnum => 3, rnum => 4,
          type => int32, occurrence => optional,
          opts => [{default, 0}]}]},
    {{msg, 'AuthData'},
      [#{name => auth_method_name, fnum => 1, rnum => 2,
        type => string, occurrence => optional, opts => []},
        #{name => auth_data, fnum => 2, rnum => 3,
          type => bytes, occurrence => optional, opts => []}]},
    {{msg, 'CommandSubscribe'},
      [#{name => topic, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => subscription, fnum => 2, rnum => 3,
          type => string, occurrence => required, opts => []},
        #{name => subType, fnum => 3, rnum => 4,
          type => {enum, 'CommandSubscribe.SubType'},
          occurrence => required, opts => []},
        #{name => consumer_id, fnum => 4, rnum => 5,
          type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 5, rnum => 6,
          type => uint64, occurrence => required, opts => []},
        #{name => consumer_name, fnum => 6, rnum => 7,
          type => string, occurrence => optional, opts => []},
        #{name => priority_level, fnum => 7, rnum => 8,
          type => int32, occurrence => optional, opts => []},
        #{name => durable, fnum => 8, rnum => 9, type => bool,
          occurrence => optional, opts => [{default, true}]},
        #{name => start_message_id, fnum => 9, rnum => 10,
          type => {msg, 'MessageIdData'}, occurrence => optional,
          opts => []},
        #{name => metadata, fnum => 10, rnum => 11,
          type => {msg, 'KeyValue'}, occurrence => repeated,
          opts => []},
        #{name => read_compacted, fnum => 11, rnum => 12,
          type => bool, occurrence => optional, opts => []},
        #{name => schema, fnum => 12, rnum => 13,
          type => {msg, 'Schema'}, occurrence => optional,
          opts => []},
        #{name => initialPosition, fnum => 13, rnum => 14,
          type => {enum, 'CommandSubscribe.InitialPosition'},
          occurrence => optional,
          opts => [{default, 'Latest'}]}]},
    {{msg, 'CommandPartitionedTopicMetadata'},
      [#{name => topic, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => original_principal, fnum => 3, rnum => 4,
          type => string, occurrence => optional, opts => []},
        #{name => original_auth_data, fnum => 4, rnum => 5,
          type => string, occurrence => optional, opts => []},
        #{name => original_auth_method, fnum => 5, rnum => 6,
          type => string, occurrence => optional, opts => []}]},
    {{msg, 'CommandPartitionedTopicMetadataResponse'},
      [#{name => partitions, fnum => 1, rnum => 2,
        type => uint32, occurrence => optional, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => response, fnum => 3, rnum => 4,
          type =>
          {enum,
            'CommandPartitionedTopicMetadataResponse.LookupType'},
          occurrence => optional, opts => []},
        #{name => error, fnum => 4, rnum => 5,
          type => {enum, 'ServerError'}, occurrence => optional,
          opts => []},
        #{name => message, fnum => 5, rnum => 6, type => string,
          occurrence => optional, opts => []}]},
    {{msg, 'CommandLookupTopic'},
      [#{name => topic, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => authoritative, fnum => 3, rnum => 4,
          type => bool, occurrence => optional,
          opts => [{default, false}]},
        #{name => original_principal, fnum => 4, rnum => 5,
          type => string, occurrence => optional, opts => []},
        #{name => original_auth_data, fnum => 5, rnum => 6,
          type => string, occurrence => optional, opts => []},
        #{name => original_auth_method, fnum => 6, rnum => 7,
          type => string, occurrence => optional, opts => []}]},
    {{msg, 'CommandLookupTopicResponse'},
      [#{name => brokerServiceUrl, fnum => 1, rnum => 2,
        type => string, occurrence => optional, opts => []},
        #{name => brokerServiceUrlTls, fnum => 2, rnum => 3,
          type => string, occurrence => optional, opts => []},
        #{name => response, fnum => 3, rnum => 4,
          type => {enum, 'CommandLookupTopicResponse.LookupType'},
          occurrence => optional, opts => []},
        #{name => request_id, fnum => 4, rnum => 5,
          type => uint64, occurrence => required, opts => []},
        #{name => authoritative, fnum => 5, rnum => 6,
          type => bool, occurrence => optional,
          opts => [{default, false}]},
        #{name => error, fnum => 6, rnum => 7,
          type => {enum, 'ServerError'}, occurrence => optional,
          opts => []},
        #{name => message, fnum => 7, rnum => 8, type => string,
          occurrence => optional, opts => []},
        #{name => proxy_through_service_url, fnum => 8,
          rnum => 9, type => bool, occurrence => optional,
          opts => [{default, false}]}]},
    {{msg, 'CommandProducer'},
      [#{name => topic, fnum => 1, rnum => 2, type => string,
        occurrence => required, opts => []},
        #{name => producer_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 3, rnum => 4,
          type => uint64, occurrence => required, opts => []},
        #{name => producer_name, fnum => 4, rnum => 5,
          type => string, occurrence => optional, opts => []},
        #{name => encrypted, fnum => 5, rnum => 6, type => bool,
          occurrence => optional, opts => [{default, false}]},
        #{name => metadata, fnum => 6, rnum => 7,
          type => {msg, 'KeyValue'}, occurrence => repeated,
          opts => []},
        #{name => schema, fnum => 7, rnum => 8,
          type => {msg, 'Schema'}, occurrence => optional,
          opts => []}]},
    {{msg, 'CommandSend'},
      [#{name => producer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => sequence_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => num_messages, fnum => 3, rnum => 4,
          type => int32, occurrence => optional,
          opts => [{default, 1}]}]},
    {{msg, 'CommandSendReceipt'},
      [#{name => producer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => sequence_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => message_id, fnum => 3, rnum => 4,
          type => {msg, 'MessageIdData'}, occurrence => optional,
          opts => []}]},
    {{msg, 'CommandSendError'},
      [#{name => producer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => sequence_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => error, fnum => 3, rnum => 4,
          type => {enum, 'ServerError'}, occurrence => required,
          opts => []},
        #{name => message, fnum => 4, rnum => 5, type => string,
          occurrence => required, opts => []}]},
    {{msg, 'CommandMessage'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => message_id, fnum => 2, rnum => 3,
          type => {msg, 'MessageIdData'}, occurrence => required,
          opts => []},
        #{name => redelivery_count, fnum => 3, rnum => 4,
          type => uint32, occurrence => optional,
          opts => [{default, 0}]}]},
    {{msg, 'CommandAck'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => ack_type, fnum => 2, rnum => 3,
          type => {enum, 'CommandAck.AckType'},
          occurrence => required, opts => []},
        #{name => message_id, fnum => 3, rnum => 4,
          type => {msg, 'MessageIdData'}, occurrence => repeated,
          opts => []},
        #{name => validation_error, fnum => 4, rnum => 5,
          type => {enum, 'CommandAck.ValidationError'},
          occurrence => optional, opts => []},
        #{name => properties, fnum => 5, rnum => 6,
          type => {msg, 'KeyLongValue'}, occurrence => repeated,
          opts => []}]},
    {{msg, 'CommandActiveConsumerChange'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => is_active, fnum => 2, rnum => 3, type => bool,
          occurrence => optional, opts => [{default, false}]}]},
    {{msg, 'CommandFlow'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => messagePermits, fnum => 2, rnum => 3,
          type => uint32, occurrence => required, opts => []}]},
    {{msg, 'CommandUnsubscribe'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandSeek'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []},
        #{name => message_id, fnum => 3, rnum => 4,
          type => {msg, 'MessageIdData'}, occurrence => optional,
          opts => []},
        #{name => message_publish_time, fnum => 4, rnum => 5,
          type => uint64, occurrence => optional, opts => []}]},
    {{msg, 'CommandReachedEndOfTopic'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandCloseProducer'},
      [#{name => producer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandCloseConsumer'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandRedeliverUnacknowledgedMessages'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => message_ids, fnum => 2, rnum => 3,
          type => {msg, 'MessageIdData'}, occurrence => repeated,
          opts => []}]},
    {{msg, 'CommandSuccess'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => schema, fnum => 2, rnum => 3,
          type => {msg, 'Schema'}, occurrence => optional,
          opts => []}]},
    {{msg, 'CommandProducerSuccess'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => producer_name, fnum => 2, rnum => 3,
          type => string, occurrence => required, opts => []},
        #{name => last_sequence_id, fnum => 3, rnum => 4,
          type => int64, occurrence => optional,
          opts => [{default, -1}]},
        #{name => schema_version, fnum => 4, rnum => 5,
          type => bytes, occurrence => optional, opts => []}]},
    {{msg, 'CommandError'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => error, fnum => 2, rnum => 3,
          type => {enum, 'ServerError'}, occurrence => required,
          opts => []},
        #{name => message, fnum => 3, rnum => 4, type => string,
          occurrence => required, opts => []}]},
    {{msg, 'CommandPing'}, []},
    {{msg, 'CommandPong'}, []},
    {{msg, 'CommandConsumerStats'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => consumer_id, fnum => 4, rnum => 3,
          type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandConsumerStatsResponse'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => error_code, fnum => 2, rnum => 3,
          type => {enum, 'ServerError'}, occurrence => optional,
          opts => []},
        #{name => error_message, fnum => 3, rnum => 4,
          type => string, occurrence => optional, opts => []},
        #{name => msgRateOut, fnum => 4, rnum => 5,
          type => double, occurrence => optional, opts => []},
        #{name => msgThroughputOut, fnum => 5, rnum => 6,
          type => double, occurrence => optional, opts => []},
        #{name => msgRateRedeliver, fnum => 6, rnum => 7,
          type => double, occurrence => optional, opts => []},
        #{name => consumerName, fnum => 7, rnum => 8,
          type => string, occurrence => optional, opts => []},
        #{name => availablePermits, fnum => 8, rnum => 9,
          type => uint64, occurrence => optional, opts => []},
        #{name => unackedMessages, fnum => 9, rnum => 10,
          type => uint64, occurrence => optional, opts => []},
        #{name => blockedConsumerOnUnackedMsgs, fnum => 10,
          rnum => 11, type => bool, occurrence => optional,
          opts => []},
        #{name => address, fnum => 11, rnum => 12,
          type => string, occurrence => optional, opts => []},
        #{name => connectedSince, fnum => 12, rnum => 13,
          type => string, occurrence => optional, opts => []},
        #{name => type, fnum => 13, rnum => 14, type => string,
          occurrence => optional, opts => []},
        #{name => msgRateExpired, fnum => 14, rnum => 15,
          type => double, occurrence => optional, opts => []},
        #{name => msgBacklog, fnum => 15, rnum => 16,
          type => uint64, occurrence => optional, opts => []}]},
    {{msg, 'CommandGetLastMessageId'},
      [#{name => consumer_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandGetLastMessageIdResponse'},
      [#{name => last_message_id, fnum => 1, rnum => 2,
        type => {msg, 'MessageIdData'}, occurrence => required,
        opts => []},
        #{name => request_id, fnum => 2, rnum => 3,
          type => uint64, occurrence => required, opts => []}]},
    {{msg, 'CommandGetTopicsOfNamespace'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => namespace, fnum => 2, rnum => 3,
          type => string, occurrence => required, opts => []},
        #{name => mode, fnum => 3, rnum => 4,
          type => {enum, 'CommandGetTopicsOfNamespace.Mode'},
          occurrence => optional,
          opts => [{default, 'PERSISTENT'}]}]},
    {{msg, 'CommandGetTopicsOfNamespaceResponse'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => topics, fnum => 2, rnum => 3, type => string,
          occurrence => repeated, opts => []}]},
    {{msg, 'CommandGetSchema'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => topic, fnum => 2, rnum => 3, type => string,
          occurrence => required, opts => []},
        #{name => schema_version, fnum => 3, rnum => 4,
          type => bytes, occurrence => optional, opts => []}]},
    {{msg, 'CommandGetSchemaResponse'},
      [#{name => request_id, fnum => 1, rnum => 2,
        type => uint64, occurrence => required, opts => []},
        #{name => error_code, fnum => 2, rnum => 3,
          type => {enum, 'ServerError'}, occurrence => optional,
          opts => []},
        #{name => error_message, fnum => 3, rnum => 4,
          type => string, occurrence => optional, opts => []},
        #{name => schema, fnum => 4, rnum => 5,
          type => {msg, 'Schema'}, occurrence => optional,
          opts => []},
        #{name => schema_version, fnum => 5, rnum => 6,
          type => bytes, occurrence => optional, opts => []}]},
    {{msg, 'BaseCommand'},
      [#{name => type, fnum => 1, rnum => 2,
        type => {enum, 'BaseCommand.Type'},
        occurrence => required, opts => []},
        #{name => connect, fnum => 2, rnum => 3,
          type => {msg, 'CommandConnect'}, occurrence => optional,
          opts => []},
        #{name => connected, fnum => 3, rnum => 4,
          type => {msg, 'CommandConnected'},
          occurrence => optional, opts => []},
        #{name => subscribe, fnum => 4, rnum => 5,
          type => {msg, 'CommandSubscribe'},
          occurrence => optional, opts => []},
        #{name => producer, fnum => 5, rnum => 6,
          type => {msg, 'CommandProducer'},
          occurrence => optional, opts => []},
        #{name => send, fnum => 6, rnum => 7,
          type => {msg, 'CommandSend'}, occurrence => optional,
          opts => []},
        #{name => send_receipt, fnum => 7, rnum => 8,
          type => {msg, 'CommandSendReceipt'},
          occurrence => optional, opts => []},
        #{name => send_error, fnum => 8, rnum => 9,
          type => {msg, 'CommandSendError'},
          occurrence => optional, opts => []},
        #{name => message, fnum => 9, rnum => 10,
          type => {msg, 'CommandMessage'}, occurrence => optional,
          opts => []},
        #{name => ack, fnum => 10, rnum => 11,
          type => {msg, 'CommandAck'}, occurrence => optional,
          opts => []},
        #{name => flow, fnum => 11, rnum => 12,
          type => {msg, 'CommandFlow'}, occurrence => optional,
          opts => []},
        #{name => unsubscribe, fnum => 12, rnum => 13,
          type => {msg, 'CommandUnsubscribe'},
          occurrence => optional, opts => []},
        #{name => success, fnum => 13, rnum => 14,
          type => {msg, 'CommandSuccess'}, occurrence => optional,
          opts => []},
        #{name => error, fnum => 14, rnum => 15,
          type => {msg, 'CommandError'}, occurrence => optional,
          opts => []},
        #{name => close_producer, fnum => 15, rnum => 16,
          type => {msg, 'CommandCloseProducer'},
          occurrence => optional, opts => []},
        #{name => close_consumer, fnum => 16, rnum => 17,
          type => {msg, 'CommandCloseConsumer'},
          occurrence => optional, opts => []},
        #{name => producer_success, fnum => 17, rnum => 18,
          type => {msg, 'CommandProducerSuccess'},
          occurrence => optional, opts => []},
        #{name => ping, fnum => 18, rnum => 19,
          type => {msg, 'CommandPing'}, occurrence => optional,
          opts => []},
        #{name => pong, fnum => 19, rnum => 20,
          type => {msg, 'CommandPong'}, occurrence => optional,
          opts => []},
        #{name => redeliverUnacknowledgedMessages, fnum => 20,
          rnum => 21,
          type => {msg, 'CommandRedeliverUnacknowledgedMessages'},
          occurrence => optional, opts => []},
        #{name => partitionMetadata, fnum => 21, rnum => 22,
          type => {msg, 'CommandPartitionedTopicMetadata'},
          occurrence => optional, opts => []},
        #{name => partitionMetadataResponse, fnum => 22,
          rnum => 23,
          type =>
          {msg, 'CommandPartitionedTopicMetadataResponse'},
          occurrence => optional, opts => []},
        #{name => lookupTopic, fnum => 23, rnum => 24,
          type => {msg, 'CommandLookupTopic'},
          occurrence => optional, opts => []},
        #{name => lookupTopicResponse, fnum => 24, rnum => 25,
          type => {msg, 'CommandLookupTopicResponse'},
          occurrence => optional, opts => []},
        #{name => consumerStats, fnum => 25, rnum => 26,
          type => {msg, 'CommandConsumerStats'},
          occurrence => optional, opts => []},
        #{name => consumerStatsResponse, fnum => 26, rnum => 27,
          type => {msg, 'CommandConsumerStatsResponse'},
          occurrence => optional, opts => []},
        #{name => reachedEndOfTopic, fnum => 27, rnum => 28,
          type => {msg, 'CommandReachedEndOfTopic'},
          occurrence => optional, opts => []},
        #{name => seek, fnum => 28, rnum => 29,
          type => {msg, 'CommandSeek'}, occurrence => optional,
          opts => []},
        #{name => getLastMessageId, fnum => 29, rnum => 30,
          type => {msg, 'CommandGetLastMessageId'},
          occurrence => optional, opts => []},
        #{name => getLastMessageIdResponse, fnum => 30,
          rnum => 31,
          type => {msg, 'CommandGetLastMessageIdResponse'},
          occurrence => optional, opts => []},
        #{name => active_consumer_change, fnum => 31,
          rnum => 32,
          type => {msg, 'CommandActiveConsumerChange'},
          occurrence => optional, opts => []},
        #{name => getTopicsOfNamespace, fnum => 32, rnum => 33,
          type => {msg, 'CommandGetTopicsOfNamespace'},
          occurrence => optional, opts => []},
        #{name => getTopicsOfNamespaceResponse, fnum => 33,
          rnum => 34,
          type => {msg, 'CommandGetTopicsOfNamespaceResponse'},
          occurrence => optional, opts => []},
        #{name => getSchema, fnum => 34, rnum => 35,
          type => {msg, 'CommandGetSchema'},
          occurrence => optional, opts => []},
        #{name => getSchemaResponse, fnum => 35, rnum => 36,
          type => {msg, 'CommandGetSchemaResponse'},
          occurrence => optional, opts => []},
        #{name => authChallenge, fnum => 36, rnum => 37,
          type => {msg, 'CommandAuthChallenge'},
          occurrence => optional, opts => []},
        #{name => authResponse, fnum => 37, rnum => 38,
          type => {msg, 'CommandAuthResponse'},
          occurrence => optional, opts => []}]}].

get_msg_names() ->
  ['Schema',
    'MessageIdData',
    'KeyValue',
    'KeyLongValue',
    'EncryptionKeys',
    'MessageMetadata',
    'SingleMessageMetadata',
    'CommandConnect',
    'CommandConnected',
    'CommandAuthResponse',
    'CommandAuthChallenge',
    'AuthData',
    'CommandSubscribe',
    'CommandPartitionedTopicMetadata',
    'CommandPartitionedTopicMetadataResponse',
    'CommandLookupTopic',
    'CommandLookupTopicResponse',
    'CommandProducer',
    'CommandSend',
    'CommandSendReceipt',
    'CommandSendError',
    'CommandMessage',
    'CommandAck',
    'CommandActiveConsumerChange',
    'CommandFlow',
    'CommandUnsubscribe',
    'CommandSeek',
    'CommandReachedEndOfTopic',
    'CommandCloseProducer',
    'CommandCloseConsumer',
    'CommandRedeliverUnacknowledgedMessages',
    'CommandSuccess',
    'CommandProducerSuccess',
    'CommandError',
    'CommandPing',
    'CommandPong',
    'CommandConsumerStats',
    'CommandConsumerStatsResponse',
    'CommandGetLastMessageId',
    'CommandGetLastMessageIdResponse',
    'CommandGetTopicsOfNamespace',
    'CommandGetTopicsOfNamespaceResponse',
    'CommandGetSchema',
    'CommandGetSchemaResponse',
    'BaseCommand'].

get_group_names() -> [].

get_msg_or_group_names() ->
  ['Schema',
    'MessageIdData',
    'KeyValue',
    'KeyLongValue',
    'EncryptionKeys',
    'MessageMetadata',
    'SingleMessageMetadata',
    'CommandConnect',
    'CommandConnected',
    'CommandAuthResponse',
    'CommandAuthChallenge',
    'AuthData',
    'CommandSubscribe',
    'CommandPartitionedTopicMetadata',
    'CommandPartitionedTopicMetadataResponse',
    'CommandLookupTopic',
    'CommandLookupTopicResponse',
    'CommandProducer',
    'CommandSend',
    'CommandSendReceipt',
    'CommandSendError',
    'CommandMessage',
    'CommandAck',
    'CommandActiveConsumerChange',
    'CommandFlow',
    'CommandUnsubscribe',
    'CommandSeek',
    'CommandReachedEndOfTopic',
    'CommandCloseProducer',
    'CommandCloseConsumer',
    'CommandRedeliverUnacknowledgedMessages',
    'CommandSuccess',
    'CommandProducerSuccess',
    'CommandError',
    'CommandPing',
    'CommandPong',
    'CommandConsumerStats',
    'CommandConsumerStatsResponse',
    'CommandGetLastMessageId',
    'CommandGetLastMessageIdResponse',
    'CommandGetTopicsOfNamespace',
    'CommandGetTopicsOfNamespaceResponse',
    'CommandGetSchema',
    'CommandGetSchemaResponse',
    'BaseCommand'].

get_enum_names() ->
  ['Schema.Type',
    'CompressionType',
    'ServerError',
    'AuthMethod',
    'ProtocolVersion',
    'CommandSubscribe.SubType',
    'CommandSubscribe.InitialPosition',
    'CommandPartitionedTopicMetadataResponse.LookupType',
    'CommandLookupTopicResponse.LookupType',
    'CommandAck.AckType',
    'CommandAck.ValidationError',
    'CommandGetTopicsOfNamespace.Mode',
    'BaseCommand.Type'].

fetch_msg_def(MsgName) ->
  case find_msg_def(MsgName) of
    Fs when is_list(Fs) -> Fs;
    error -> erlang:error({no_such_msg, MsgName})
  end.

fetch_enum_def(EnumName) ->
  case find_enum_def(EnumName) of
    Es when is_list(Es) -> Es;
    error -> erlang:error({no_such_enum, EnumName})
  end.

find_msg_def('Schema') ->
  [#{name => name, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => schema_data, fnum => 3, rnum => 3,
      type => bytes, occurrence => required, opts => []},
    #{name => type, fnum => 4, rnum => 4,
      type => {enum, 'Schema.Type'}, occurrence => required,
      opts => []},
    #{name => properties, fnum => 5, rnum => 5,
      type => {msg, 'KeyValue'}, occurrence => repeated,
      opts => []}];
find_msg_def('MessageIdData') ->
  [#{name => ledgerId, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => entryId, fnum => 2, rnum => 3, type => uint64,
      occurrence => required, opts => []},
    #{name => partition, fnum => 3, rnum => 4,
      type => int32, occurrence => optional,
      opts => [{default, -1}]},
    #{name => batch_index, fnum => 4, rnum => 5,
      type => int32, occurrence => optional,
      opts => [{default, -1}]}];
find_msg_def('KeyValue') ->
  [#{name => key, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => value, fnum => 2, rnum => 3, type => string,
      occurrence => required, opts => []}];
find_msg_def('KeyLongValue') ->
  [#{name => key, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => value, fnum => 2, rnum => 3, type => uint64,
      occurrence => required, opts => []}];
find_msg_def('EncryptionKeys') ->
  [#{name => key, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => value, fnum => 2, rnum => 3, type => bytes,
      occurrence => required, opts => []},
    #{name => metadata, fnum => 3, rnum => 4,
      type => {msg, 'KeyValue'}, occurrence => repeated,
      opts => []}];
find_msg_def('MessageMetadata') ->
  [#{name => producer_name, fnum => 1, rnum => 2,
    type => string, occurrence => required, opts => []},
    #{name => sequence_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => publish_time, fnum => 3, rnum => 4,
      type => uint64, occurrence => required, opts => []},
    #{name => properties, fnum => 4, rnum => 5,
      type => {msg, 'KeyValue'}, occurrence => repeated,
      opts => []},
    #{name => replicated_from, fnum => 5, rnum => 6,
      type => string, occurrence => optional, opts => []},
    #{name => partition_key, fnum => 6, rnum => 7,
      type => string, occurrence => optional, opts => []},
    #{name => replicate_to, fnum => 7, rnum => 8,
      type => string, occurrence => repeated, opts => []},
    #{name => compression, fnum => 8, rnum => 9,
      type => {enum, 'CompressionType'},
      occurrence => optional, opts => [{default, 'NONE'}]},
    #{name => uncompressed_size, fnum => 9, rnum => 10,
      type => uint32, occurrence => optional,
      opts => [{default, 0}]},
    #{name => num_messages_in_batch, fnum => 11, rnum => 11,
      type => int32, occurrence => optional,
      opts => [{default, 1}]},
    #{name => event_time, fnum => 12, rnum => 12,
      type => uint64, occurrence => optional,
      opts => [{default, 0}]},
    #{name => encryption_keys, fnum => 13, rnum => 13,
      type => {msg, 'EncryptionKeys'}, occurrence => repeated,
      opts => []},
    #{name => encryption_algo, fnum => 14, rnum => 14,
      type => string, occurrence => optional, opts => []},
    #{name => encryption_param, fnum => 15, rnum => 15,
      type => bytes, occurrence => optional, opts => []},
    #{name => schema_version, fnum => 16, rnum => 16,
      type => bytes, occurrence => optional, opts => []},
    #{name => partition_key_b64_encoded, fnum => 17,
      rnum => 17, type => bool, occurrence => optional,
      opts => [{default, false}]},
    #{name => ordering_key, fnum => 18, rnum => 18,
      type => bytes, occurrence => optional, opts => []}];
find_msg_def('SingleMessageMetadata') ->
  [#{name => properties, fnum => 1, rnum => 2,
    type => {msg, 'KeyValue'}, occurrence => repeated,
    opts => []},
    #{name => partition_key, fnum => 2, rnum => 3,
      type => string, occurrence => optional, opts => []},
    #{name => payload_size, fnum => 3, rnum => 4,
      type => int32, occurrence => required, opts => []},
    #{name => compacted_out, fnum => 4, rnum => 5,
      type => bool, occurrence => optional,
      opts => [{default, false}]},
    #{name => event_time, fnum => 5, rnum => 6,
      type => uint64, occurrence => optional,
      opts => [{default, 0}]},
    #{name => partition_key_b64_encoded, fnum => 6,
      rnum => 7, type => bool, occurrence => optional,
      opts => [{default, false}]},
    #{name => ordering_key, fnum => 7, rnum => 8,
      type => bytes, occurrence => optional, opts => []}];
find_msg_def('CommandConnect') ->
  [#{name => client_version, fnum => 1, rnum => 2,
    type => string, occurrence => required, opts => []},
    #{name => auth_method, fnum => 2, rnum => 3,
      type => {enum, 'AuthMethod'}, occurrence => optional,
      opts => []},
    #{name => auth_method_name, fnum => 5, rnum => 4,
      type => string, occurrence => optional, opts => []},
    #{name => auth_data, fnum => 3, rnum => 5,
      type => bytes, occurrence => optional, opts => []},
    #{name => protocol_version, fnum => 4, rnum => 6,
      type => int32, occurrence => optional,
      opts => [{default, 0}]},
    #{name => proxy_to_broker_url, fnum => 6, rnum => 7,
      type => string, occurrence => optional, opts => []},
    #{name => original_principal, fnum => 7, rnum => 8,
      type => string, occurrence => optional, opts => []},
    #{name => original_auth_data, fnum => 8, rnum => 9,
      type => string, occurrence => optional, opts => []},
    #{name => original_auth_method, fnum => 9, rnum => 10,
      type => string, occurrence => optional, opts => []}];
find_msg_def('CommandConnected') ->
  [#{name => server_version, fnum => 1, rnum => 2,
    type => string, occurrence => required, opts => []},
    #{name => protocol_version, fnum => 2, rnum => 3,
      type => int32, occurrence => optional,
      opts => [{default, 0}]}];
find_msg_def('CommandAuthResponse') ->
  [#{name => client_version, fnum => 1, rnum => 2,
    type => string, occurrence => optional, opts => []},
    #{name => response, fnum => 2, rnum => 3,
      type => {msg, 'AuthData'}, occurrence => optional,
      opts => []},
    #{name => protocol_version, fnum => 3, rnum => 4,
      type => int32, occurrence => optional,
      opts => [{default, 0}]}];
find_msg_def('CommandAuthChallenge') ->
  [#{name => server_version, fnum => 1, rnum => 2,
    type => string, occurrence => optional, opts => []},
    #{name => challenge, fnum => 2, rnum => 3,
      type => {msg, 'AuthData'}, occurrence => optional,
      opts => []},
    #{name => protocol_version, fnum => 3, rnum => 4,
      type => int32, occurrence => optional,
      opts => [{default, 0}]}];
find_msg_def('AuthData') ->
  [#{name => auth_method_name, fnum => 1, rnum => 2,
    type => string, occurrence => optional, opts => []},
    #{name => auth_data, fnum => 2, rnum => 3,
      type => bytes, occurrence => optional, opts => []}];
find_msg_def('CommandSubscribe') ->
  [#{name => topic, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => subscription, fnum => 2, rnum => 3,
      type => string, occurrence => required, opts => []},
    #{name => subType, fnum => 3, rnum => 4,
      type => {enum, 'CommandSubscribe.SubType'},
      occurrence => required, opts => []},
    #{name => consumer_id, fnum => 4, rnum => 5,
      type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 5, rnum => 6,
      type => uint64, occurrence => required, opts => []},
    #{name => consumer_name, fnum => 6, rnum => 7,
      type => string, occurrence => optional, opts => []},
    #{name => priority_level, fnum => 7, rnum => 8,
      type => int32, occurrence => optional, opts => []},
    #{name => durable, fnum => 8, rnum => 9, type => bool,
      occurrence => optional, opts => [{default, true}]},
    #{name => start_message_id, fnum => 9, rnum => 10,
      type => {msg, 'MessageIdData'}, occurrence => optional,
      opts => []},
    #{name => metadata, fnum => 10, rnum => 11,
      type => {msg, 'KeyValue'}, occurrence => repeated,
      opts => []},
    #{name => read_compacted, fnum => 11, rnum => 12,
      type => bool, occurrence => optional, opts => []},
    #{name => schema, fnum => 12, rnum => 13,
      type => {msg, 'Schema'}, occurrence => optional,
      opts => []},
    #{name => initialPosition, fnum => 13, rnum => 14,
      type => {enum, 'CommandSubscribe.InitialPosition'},
      occurrence => optional, opts => [{default, 'Latest'}]}];
find_msg_def('CommandPartitionedTopicMetadata') ->
  [#{name => topic, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => original_principal, fnum => 3, rnum => 4,
      type => string, occurrence => optional, opts => []},
    #{name => original_auth_data, fnum => 4, rnum => 5,
      type => string, occurrence => optional, opts => []},
    #{name => original_auth_method, fnum => 5, rnum => 6,
      type => string, occurrence => optional, opts => []}];
find_msg_def('CommandPartitionedTopicMetadataResponse') ->
  [#{name => partitions, fnum => 1, rnum => 2,
    type => uint32, occurrence => optional, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => response, fnum => 3, rnum => 4,
      type =>
      {enum,
        'CommandPartitionedTopicMetadataResponse.LookupType'},
      occurrence => optional, opts => []},
    #{name => error, fnum => 4, rnum => 5,
      type => {enum, 'ServerError'}, occurrence => optional,
      opts => []},
    #{name => message, fnum => 5, rnum => 6, type => string,
      occurrence => optional, opts => []}];
find_msg_def('CommandLookupTopic') ->
  [#{name => topic, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => authoritative, fnum => 3, rnum => 4,
      type => bool, occurrence => optional,
      opts => [{default, false}]},
    #{name => original_principal, fnum => 4, rnum => 5,
      type => string, occurrence => optional, opts => []},
    #{name => original_auth_data, fnum => 5, rnum => 6,
      type => string, occurrence => optional, opts => []},
    #{name => original_auth_method, fnum => 6, rnum => 7,
      type => string, occurrence => optional, opts => []}];
find_msg_def('CommandLookupTopicResponse') ->
  [#{name => brokerServiceUrl, fnum => 1, rnum => 2,
    type => string, occurrence => optional, opts => []},
    #{name => brokerServiceUrlTls, fnum => 2, rnum => 3,
      type => string, occurrence => optional, opts => []},
    #{name => response, fnum => 3, rnum => 4,
      type => {enum, 'CommandLookupTopicResponse.LookupType'},
      occurrence => optional, opts => []},
    #{name => request_id, fnum => 4, rnum => 5,
      type => uint64, occurrence => required, opts => []},
    #{name => authoritative, fnum => 5, rnum => 6,
      type => bool, occurrence => optional,
      opts => [{default, false}]},
    #{name => error, fnum => 6, rnum => 7,
      type => {enum, 'ServerError'}, occurrence => optional,
      opts => []},
    #{name => message, fnum => 7, rnum => 8, type => string,
      occurrence => optional, opts => []},
    #{name => proxy_through_service_url, fnum => 8,
      rnum => 9, type => bool, occurrence => optional,
      opts => [{default, false}]}];
find_msg_def('CommandProducer') ->
  [#{name => topic, fnum => 1, rnum => 2, type => string,
    occurrence => required, opts => []},
    #{name => producer_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 3, rnum => 4,
      type => uint64, occurrence => required, opts => []},
    #{name => producer_name, fnum => 4, rnum => 5,
      type => string, occurrence => optional, opts => []},
    #{name => encrypted, fnum => 5, rnum => 6, type => bool,
      occurrence => optional, opts => [{default, false}]},
    #{name => metadata, fnum => 6, rnum => 7,
      type => {msg, 'KeyValue'}, occurrence => repeated,
      opts => []},
    #{name => schema, fnum => 7, rnum => 8,
      type => {msg, 'Schema'}, occurrence => optional,
      opts => []}];
find_msg_def('CommandSend') ->
  [#{name => producer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => sequence_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => num_messages, fnum => 3, rnum => 4,
      type => int32, occurrence => optional,
      opts => [{default, 1}]}];
find_msg_def('CommandSendReceipt') ->
  [#{name => producer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => sequence_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => message_id, fnum => 3, rnum => 4,
      type => {msg, 'MessageIdData'}, occurrence => optional,
      opts => []}];
find_msg_def('CommandSendError') ->
  [#{name => producer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => sequence_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => error, fnum => 3, rnum => 4,
      type => {enum, 'ServerError'}, occurrence => required,
      opts => []},
    #{name => message, fnum => 4, rnum => 5, type => string,
      occurrence => required, opts => []}];
find_msg_def('CommandMessage') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => message_id, fnum => 2, rnum => 3,
      type => {msg, 'MessageIdData'}, occurrence => required,
      opts => []},
    #{name => redelivery_count, fnum => 3, rnum => 4,
      type => uint32, occurrence => optional,
      opts => [{default, 0}]}];
find_msg_def('CommandAck') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => ack_type, fnum => 2, rnum => 3,
      type => {enum, 'CommandAck.AckType'},
      occurrence => required, opts => []},
    #{name => message_id, fnum => 3, rnum => 4,
      type => {msg, 'MessageIdData'}, occurrence => repeated,
      opts => []},
    #{name => validation_error, fnum => 4, rnum => 5,
      type => {enum, 'CommandAck.ValidationError'},
      occurrence => optional, opts => []},
    #{name => properties, fnum => 5, rnum => 6,
      type => {msg, 'KeyLongValue'}, occurrence => repeated,
      opts => []}];
find_msg_def('CommandActiveConsumerChange') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => is_active, fnum => 2, rnum => 3, type => bool,
      occurrence => optional, opts => [{default, false}]}];
find_msg_def('CommandFlow') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => messagePermits, fnum => 2, rnum => 3,
      type => uint32, occurrence => required, opts => []}];
find_msg_def('CommandUnsubscribe') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandSeek') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []},
    #{name => message_id, fnum => 3, rnum => 4,
      type => {msg, 'MessageIdData'}, occurrence => optional,
      opts => []},
    #{name => message_publish_time, fnum => 4, rnum => 5,
      type => uint64, occurrence => optional, opts => []}];
find_msg_def('CommandReachedEndOfTopic') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandCloseProducer') ->
  [#{name => producer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandCloseConsumer') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandRedeliverUnacknowledgedMessages') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => message_ids, fnum => 2, rnum => 3,
      type => {msg, 'MessageIdData'}, occurrence => repeated,
      opts => []}];
find_msg_def('CommandSuccess') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => schema, fnum => 2, rnum => 3,
      type => {msg, 'Schema'}, occurrence => optional,
      opts => []}];
find_msg_def('CommandProducerSuccess') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => producer_name, fnum => 2, rnum => 3,
      type => string, occurrence => required, opts => []},
    #{name => last_sequence_id, fnum => 3, rnum => 4,
      type => int64, occurrence => optional,
      opts => [{default, -1}]},
    #{name => schema_version, fnum => 4, rnum => 5,
      type => bytes, occurrence => optional, opts => []}];
find_msg_def('CommandError') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => error, fnum => 2, rnum => 3,
      type => {enum, 'ServerError'}, occurrence => required,
      opts => []},
    #{name => message, fnum => 3, rnum => 4, type => string,
      occurrence => required, opts => []}];
find_msg_def('CommandPing') -> [];
find_msg_def('CommandPong') -> [];
find_msg_def('CommandConsumerStats') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => consumer_id, fnum => 4, rnum => 3,
      type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandConsumerStatsResponse') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => error_code, fnum => 2, rnum => 3,
      type => {enum, 'ServerError'}, occurrence => optional,
      opts => []},
    #{name => error_message, fnum => 3, rnum => 4,
      type => string, occurrence => optional, opts => []},
    #{name => msgRateOut, fnum => 4, rnum => 5,
      type => double, occurrence => optional, opts => []},
    #{name => msgThroughputOut, fnum => 5, rnum => 6,
      type => double, occurrence => optional, opts => []},
    #{name => msgRateRedeliver, fnum => 6, rnum => 7,
      type => double, occurrence => optional, opts => []},
    #{name => consumerName, fnum => 7, rnum => 8,
      type => string, occurrence => optional, opts => []},
    #{name => availablePermits, fnum => 8, rnum => 9,
      type => uint64, occurrence => optional, opts => []},
    #{name => unackedMessages, fnum => 9, rnum => 10,
      type => uint64, occurrence => optional, opts => []},
    #{name => blockedConsumerOnUnackedMsgs, fnum => 10,
      rnum => 11, type => bool, occurrence => optional,
      opts => []},
    #{name => address, fnum => 11, rnum => 12,
      type => string, occurrence => optional, opts => []},
    #{name => connectedSince, fnum => 12, rnum => 13,
      type => string, occurrence => optional, opts => []},
    #{name => type, fnum => 13, rnum => 14, type => string,
      occurrence => optional, opts => []},
    #{name => msgRateExpired, fnum => 14, rnum => 15,
      type => double, occurrence => optional, opts => []},
    #{name => msgBacklog, fnum => 15, rnum => 16,
      type => uint64, occurrence => optional, opts => []}];
find_msg_def('CommandGetLastMessageId') ->
  [#{name => consumer_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandGetLastMessageIdResponse') ->
  [#{name => last_message_id, fnum => 1, rnum => 2,
    type => {msg, 'MessageIdData'}, occurrence => required,
    opts => []},
    #{name => request_id, fnum => 2, rnum => 3,
      type => uint64, occurrence => required, opts => []}];
find_msg_def('CommandGetTopicsOfNamespace') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => namespace, fnum => 2, rnum => 3,
      type => string, occurrence => required, opts => []},
    #{name => mode, fnum => 3, rnum => 4,
      type => {enum, 'CommandGetTopicsOfNamespace.Mode'},
      occurrence => optional,
      opts => [{default, 'PERSISTENT'}]}];
find_msg_def('CommandGetTopicsOfNamespaceResponse') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => topics, fnum => 2, rnum => 3, type => string,
      occurrence => repeated, opts => []}];
find_msg_def('CommandGetSchema') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => topic, fnum => 2, rnum => 3, type => string,
      occurrence => required, opts => []},
    #{name => schema_version, fnum => 3, rnum => 4,
      type => bytes, occurrence => optional, opts => []}];
find_msg_def('CommandGetSchemaResponse') ->
  [#{name => request_id, fnum => 1, rnum => 2,
    type => uint64, occurrence => required, opts => []},
    #{name => error_code, fnum => 2, rnum => 3,
      type => {enum, 'ServerError'}, occurrence => optional,
      opts => []},
    #{name => error_message, fnum => 3, rnum => 4,
      type => string, occurrence => optional, opts => []},
    #{name => schema, fnum => 4, rnum => 5,
      type => {msg, 'Schema'}, occurrence => optional,
      opts => []},
    #{name => schema_version, fnum => 5, rnum => 6,
      type => bytes, occurrence => optional, opts => []}];
find_msg_def('BaseCommand') ->
  [#{name => type, fnum => 1, rnum => 2,
    type => {enum, 'BaseCommand.Type'},
    occurrence => required, opts => []},
    #{name => connect, fnum => 2, rnum => 3,
      type => {msg, 'CommandConnect'}, occurrence => optional,
      opts => []},
    #{name => connected, fnum => 3, rnum => 4,
      type => {msg, 'CommandConnected'},
      occurrence => optional, opts => []},
    #{name => subscribe, fnum => 4, rnum => 5,
      type => {msg, 'CommandSubscribe'},
      occurrence => optional, opts => []},
    #{name => producer, fnum => 5, rnum => 6,
      type => {msg, 'CommandProducer'},
      occurrence => optional, opts => []},
    #{name => send, fnum => 6, rnum => 7,
      type => {msg, 'CommandSend'}, occurrence => optional,
      opts => []},
    #{name => send_receipt, fnum => 7, rnum => 8,
      type => {msg, 'CommandSendReceipt'},
      occurrence => optional, opts => []},
    #{name => send_error, fnum => 8, rnum => 9,
      type => {msg, 'CommandSendError'},
      occurrence => optional, opts => []},
    #{name => message, fnum => 9, rnum => 10,
      type => {msg, 'CommandMessage'}, occurrence => optional,
      opts => []},
    #{name => ack, fnum => 10, rnum => 11,
      type => {msg, 'CommandAck'}, occurrence => optional,
      opts => []},
    #{name => flow, fnum => 11, rnum => 12,
      type => {msg, 'CommandFlow'}, occurrence => optional,
      opts => []},
    #{name => unsubscribe, fnum => 12, rnum => 13,
      type => {msg, 'CommandUnsubscribe'},
      occurrence => optional, opts => []},
    #{name => success, fnum => 13, rnum => 14,
      type => {msg, 'CommandSuccess'}, occurrence => optional,
      opts => []},
    #{name => error, fnum => 14, rnum => 15,
      type => {msg, 'CommandError'}, occurrence => optional,
      opts => []},
    #{name => close_producer, fnum => 15, rnum => 16,
      type => {msg, 'CommandCloseProducer'},
      occurrence => optional, opts => []},
    #{name => close_consumer, fnum => 16, rnum => 17,
      type => {msg, 'CommandCloseConsumer'},
      occurrence => optional, opts => []},
    #{name => producer_success, fnum => 17, rnum => 18,
      type => {msg, 'CommandProducerSuccess'},
      occurrence => optional, opts => []},
    #{name => ping, fnum => 18, rnum => 19,
      type => {msg, 'CommandPing'}, occurrence => optional,
      opts => []},
    #{name => pong, fnum => 19, rnum => 20,
      type => {msg, 'CommandPong'}, occurrence => optional,
      opts => []},
    #{name => redeliverUnacknowledgedMessages, fnum => 20,
      rnum => 21,
      type => {msg, 'CommandRedeliverUnacknowledgedMessages'},
      occurrence => optional, opts => []},
    #{name => partitionMetadata, fnum => 21, rnum => 22,
      type => {msg, 'CommandPartitionedTopicMetadata'},
      occurrence => optional, opts => []},
    #{name => partitionMetadataResponse, fnum => 22,
      rnum => 23,
      type =>
      {msg, 'CommandPartitionedTopicMetadataResponse'},
      occurrence => optional, opts => []},
    #{name => lookupTopic, fnum => 23, rnum => 24,
      type => {msg, 'CommandLookupTopic'},
      occurrence => optional, opts => []},
    #{name => lookupTopicResponse, fnum => 24, rnum => 25,
      type => {msg, 'CommandLookupTopicResponse'},
      occurrence => optional, opts => []},
    #{name => consumerStats, fnum => 25, rnum => 26,
      type => {msg, 'CommandConsumerStats'},
      occurrence => optional, opts => []},
    #{name => consumerStatsResponse, fnum => 26, rnum => 27,
      type => {msg, 'CommandConsumerStatsResponse'},
      occurrence => optional, opts => []},
    #{name => reachedEndOfTopic, fnum => 27, rnum => 28,
      type => {msg, 'CommandReachedEndOfTopic'},
      occurrence => optional, opts => []},
    #{name => seek, fnum => 28, rnum => 29,
      type => {msg, 'CommandSeek'}, occurrence => optional,
      opts => []},
    #{name => getLastMessageId, fnum => 29, rnum => 30,
      type => {msg, 'CommandGetLastMessageId'},
      occurrence => optional, opts => []},
    #{name => getLastMessageIdResponse, fnum => 30,
      rnum => 31,
      type => {msg, 'CommandGetLastMessageIdResponse'},
      occurrence => optional, opts => []},
    #{name => active_consumer_change, fnum => 31,
      rnum => 32,
      type => {msg, 'CommandActiveConsumerChange'},
      occurrence => optional, opts => []},
    #{name => getTopicsOfNamespace, fnum => 32, rnum => 33,
      type => {msg, 'CommandGetTopicsOfNamespace'},
      occurrence => optional, opts => []},
    #{name => getTopicsOfNamespaceResponse, fnum => 33,
      rnum => 34,
      type => {msg, 'CommandGetTopicsOfNamespaceResponse'},
      occurrence => optional, opts => []},
    #{name => getSchema, fnum => 34, rnum => 35,
      type => {msg, 'CommandGetSchema'},
      occurrence => optional, opts => []},
    #{name => getSchemaResponse, fnum => 35, rnum => 36,
      type => {msg, 'CommandGetSchemaResponse'},
      occurrence => optional, opts => []},
    #{name => authChallenge, fnum => 36, rnum => 37,
      type => {msg, 'CommandAuthChallenge'},
      occurrence => optional, opts => []},
    #{name => authResponse, fnum => 37, rnum => 38,
      type => {msg, 'CommandAuthResponse'},
      occurrence => optional, opts => []}];
find_msg_def(_) -> error.

find_enum_def('Schema.Type') ->
  [{'None', 0},
    {'String', 1},
    {'Json', 2},
    {'Protobuf', 3},
    {'Avro', 4},
    {'Bool', 5},
    {'Int8', 6},
    {'Int16', 7},
    {'Int32', 8},
    {'Int64', 9},
    {'Float', 10},
    {'Double', 11},
    {'Date', 12},
    {'Time', 13},
    {'Timestamp', 14},
    {'KeyValue', 15}];
find_enum_def('CompressionType') ->
  [{'NONE', 0}, {'LZ4', 1}, {'ZLIB', 2}, {'ZSTD', 3}];
find_enum_def('ServerError') ->
  [{'UnknownError', 0},
    {'MetadataError', 1},
    {'PersistenceError', 2},
    {'AuthenticationError', 3},
    {'AuthorizationError', 4},
    {'ConsumerBusy', 5},
    {'ServiceNotReady', 6},
    {'ProducerBlockedQuotaExceededError', 7},
    {'ProducerBlockedQuotaExceededException', 8},
    {'ChecksumError', 9},
    {'UnsupportedVersionError', 10},
    {'TopicNotFound', 11},
    {'SubscriptionNotFound', 12},
    {'ConsumerNotFound', 13},
    {'TooManyRequests', 14},
    {'TopicTerminatedError', 15},
    {'ProducerBusy', 16},
    {'InvalidTopicName', 17},
    {'IncompatibleSchema', 18},
    {'ConsumerAssignError', 19}];
find_enum_def('AuthMethod') ->
  [{'AuthMethodNone', 0},
    {'AuthMethodYcaV1', 1},
    {'AuthMethodAthens', 2}];
find_enum_def('ProtocolVersion') ->
  [{v0, 0},
    {v1, 1},
    {v2, 2},
    {v3, 3},
    {v4, 4},
    {v5, 5},
    {v6, 6},
    {v7, 7},
    {v8, 8},
    {v9, 9},
    {v10, 10},
    {v11, 11},
    {v12, 12},
    {v13, 13},
    {v14, 14}];
find_enum_def('CommandSubscribe.SubType') ->
  [{'Exclusive', 0},
    {'Shared', 1},
    {'Failover', 2},
    {'Key_Shared', 3}];
find_enum_def('CommandSubscribe.InitialPosition') ->
  [{'Latest', 0}, {'Earliest', 1}];
find_enum_def('CommandPartitionedTopicMetadataResponse.LookupType') ->
  [{'Success', 0}, {'Failed', 1}];
find_enum_def('CommandLookupTopicResponse.LookupType') ->
  [{'Redirect', 0}, {'Connect', 1}, {'Failed', 2}];
find_enum_def('CommandAck.AckType') ->
  [{'Individual', 0}, {'Cumulative', 1}];
find_enum_def('CommandAck.ValidationError') ->
  [{'UncompressedSizeCorruption', 0},
    {'DecompressionError', 1},
    {'ChecksumMismatch', 2},
    {'BatchDeSerializeError', 3},
    {'DecryptionError', 4}];
find_enum_def('CommandGetTopicsOfNamespace.Mode') ->
  [{'PERSISTENT', 0}, {'NON_PERSISTENT', 1}, {'ALL', 2}];
find_enum_def('BaseCommand.Type') ->
  [{'CONNECT', 2},
    {'CONNECTED', 3},
    {'SUBSCRIBE', 4},
    {'PRODUCER', 5},
    {'SEND', 6},
    {'SEND_RECEIPT', 7},
    {'SEND_ERROR', 8},
    {'MESSAGE', 9},
    {'ACK', 10},
    {'FLOW', 11},
    {'UNSUBSCRIBE', 12},
    {'SUCCESS', 13},
    {'ERROR', 14},
    {'CLOSE_PRODUCER', 15},
    {'CLOSE_CONSUMER', 16},
    {'PRODUCER_SUCCESS', 17},
    {'PING', 18},
    {'PONG', 19},
    {'REDELIVER_UNACKNOWLEDGED_MESSAGES', 20},
    {'PARTITIONED_METADATA', 21},
    {'PARTITIONED_METADATA_RESPONSE', 22},
    {'LOOKUP', 23},
    {'LOOKUP_RESPONSE', 24},
    {'CONSUMER_STATS', 25},
    {'CONSUMER_STATS_RESPONSE', 26},
    {'REACHED_END_OF_TOPIC', 27},
    {'SEEK', 28},
    {'GET_LAST_MESSAGE_ID', 29},
    {'GET_LAST_MESSAGE_ID_RESPONSE', 30},
    {'ACTIVE_CONSUMER_CHANGE', 31},
    {'GET_TOPICS_OF_NAMESPACE', 32},
    {'GET_TOPICS_OF_NAMESPACE_RESPONSE', 33},
    {'GET_SCHEMA', 34},
    {'GET_SCHEMA_RESPONSE', 35},
    {'AUTH_CHALLENGE', 36},
    {'AUTH_RESPONSE', 37}];
find_enum_def(_) -> error.

enum_symbol_by_value('Schema.Type', Value) ->
  'enum_symbol_by_value_Schema.Type'(Value);
enum_symbol_by_value('CompressionType', Value) ->
  enum_symbol_by_value_CompressionType(Value);
enum_symbol_by_value('ServerError', Value) ->
  enum_symbol_by_value_ServerError(Value);
enum_symbol_by_value('AuthMethod', Value) ->
  enum_symbol_by_value_AuthMethod(Value);
enum_symbol_by_value('ProtocolVersion', Value) ->
  enum_symbol_by_value_ProtocolVersion(Value);
enum_symbol_by_value('CommandSubscribe.SubType',
    Value) ->
  'enum_symbol_by_value_CommandSubscribe.SubType'(Value);
enum_symbol_by_value('CommandSubscribe.InitialPosition',
    Value) ->
  'enum_symbol_by_value_CommandSubscribe.InitialPosition'(Value);
enum_symbol_by_value('CommandPartitionedTopicMetadataResponse.LookupType',
    Value) ->
  'enum_symbol_by_value_CommandPartitionedTopicMetadataResponse.LookupType'(Value);
enum_symbol_by_value('CommandLookupTopicResponse.LookupType',
    Value) ->
  'enum_symbol_by_value_CommandLookupTopicResponse.LookupType'(Value);
enum_symbol_by_value('CommandAck.AckType', Value) ->
  'enum_symbol_by_value_CommandAck.AckType'(Value);
enum_symbol_by_value('CommandAck.ValidationError',
    Value) ->
  'enum_symbol_by_value_CommandAck.ValidationError'(Value);
enum_symbol_by_value('CommandGetTopicsOfNamespace.Mode',
    Value) ->
  'enum_symbol_by_value_CommandGetTopicsOfNamespace.Mode'(Value);
enum_symbol_by_value('BaseCommand.Type', Value) ->
  'enum_symbol_by_value_BaseCommand.Type'(Value).

enum_value_by_symbol('Schema.Type', Sym) ->
  'enum_value_by_symbol_Schema.Type'(Sym);
enum_value_by_symbol('CompressionType', Sym) ->
  enum_value_by_symbol_CompressionType(Sym);
enum_value_by_symbol('ServerError', Sym) ->
  enum_value_by_symbol_ServerError(Sym);
enum_value_by_symbol('AuthMethod', Sym) ->
  enum_value_by_symbol_AuthMethod(Sym);
enum_value_by_symbol('ProtocolVersion', Sym) ->
  enum_value_by_symbol_ProtocolVersion(Sym);
enum_value_by_symbol('CommandSubscribe.SubType', Sym) ->
  'enum_value_by_symbol_CommandSubscribe.SubType'(Sym);
enum_value_by_symbol('CommandSubscribe.InitialPosition',
    Sym) ->
  'enum_value_by_symbol_CommandSubscribe.InitialPosition'(Sym);
enum_value_by_symbol('CommandPartitionedTopicMetadataResponse.LookupType',
    Sym) ->
  'enum_value_by_symbol_CommandPartitionedTopicMetadataResponse.LookupType'(Sym);
enum_value_by_symbol('CommandLookupTopicResponse.LookupType',
    Sym) ->
  'enum_value_by_symbol_CommandLookupTopicResponse.LookupType'(Sym);
enum_value_by_symbol('CommandAck.AckType', Sym) ->
  'enum_value_by_symbol_CommandAck.AckType'(Sym);
enum_value_by_symbol('CommandAck.ValidationError',
    Sym) ->
  'enum_value_by_symbol_CommandAck.ValidationError'(Sym);
enum_value_by_symbol('CommandGetTopicsOfNamespace.Mode',
    Sym) ->
  'enum_value_by_symbol_CommandGetTopicsOfNamespace.Mode'(Sym);
enum_value_by_symbol('BaseCommand.Type', Sym) ->
  'enum_value_by_symbol_BaseCommand.Type'(Sym).

'enum_symbol_by_value_Schema.Type'(0) -> 'None';
'enum_symbol_by_value_Schema.Type'(1) -> 'String';
'enum_symbol_by_value_Schema.Type'(2) -> 'Json';
'enum_symbol_by_value_Schema.Type'(3) -> 'Protobuf';
'enum_symbol_by_value_Schema.Type'(4) -> 'Avro';
'enum_symbol_by_value_Schema.Type'(5) -> 'Bool';
'enum_symbol_by_value_Schema.Type'(6) -> 'Int8';
'enum_symbol_by_value_Schema.Type'(7) -> 'Int16';
'enum_symbol_by_value_Schema.Type'(8) -> 'Int32';
'enum_symbol_by_value_Schema.Type'(9) -> 'Int64';
'enum_symbol_by_value_Schema.Type'(10) -> 'Float';
'enum_symbol_by_value_Schema.Type'(11) -> 'Double';
'enum_symbol_by_value_Schema.Type'(12) -> 'Date';
'enum_symbol_by_value_Schema.Type'(13) -> 'Time';
'enum_symbol_by_value_Schema.Type'(14) -> 'Timestamp';
'enum_symbol_by_value_Schema.Type'(15) -> 'KeyValue'.

'enum_value_by_symbol_Schema.Type'('None') -> 0;
'enum_value_by_symbol_Schema.Type'('String') -> 1;
'enum_value_by_symbol_Schema.Type'('Json') -> 2;
'enum_value_by_symbol_Schema.Type'('Protobuf') -> 3;
'enum_value_by_symbol_Schema.Type'('Avro') -> 4;
'enum_value_by_symbol_Schema.Type'('Bool') -> 5;
'enum_value_by_symbol_Schema.Type'('Int8') -> 6;
'enum_value_by_symbol_Schema.Type'('Int16') -> 7;
'enum_value_by_symbol_Schema.Type'('Int32') -> 8;
'enum_value_by_symbol_Schema.Type'('Int64') -> 9;
'enum_value_by_symbol_Schema.Type'('Float') -> 10;
'enum_value_by_symbol_Schema.Type'('Double') -> 11;
'enum_value_by_symbol_Schema.Type'('Date') -> 12;
'enum_value_by_symbol_Schema.Type'('Time') -> 13;
'enum_value_by_symbol_Schema.Type'('Timestamp') -> 14;
'enum_value_by_symbol_Schema.Type'('KeyValue') -> 15.

enum_symbol_by_value_CompressionType(0) -> 'NONE';
enum_symbol_by_value_CompressionType(1) -> 'LZ4';
enum_symbol_by_value_CompressionType(2) -> 'ZLIB';
enum_symbol_by_value_CompressionType(3) -> 'ZSTD'.

enum_value_by_symbol_CompressionType('NONE') -> 0;
enum_value_by_symbol_CompressionType('LZ4') -> 1;
enum_value_by_symbol_CompressionType('ZLIB') -> 2;
enum_value_by_symbol_CompressionType('ZSTD') -> 3.

enum_symbol_by_value_ServerError(0) -> 'UnknownError';
enum_symbol_by_value_ServerError(1) -> 'MetadataError';
enum_symbol_by_value_ServerError(2) ->
  'PersistenceError';
enum_symbol_by_value_ServerError(3) ->
  'AuthenticationError';
enum_symbol_by_value_ServerError(4) ->
  'AuthorizationError';
enum_symbol_by_value_ServerError(5) -> 'ConsumerBusy';
enum_symbol_by_value_ServerError(6) ->
  'ServiceNotReady';
enum_symbol_by_value_ServerError(7) ->
  'ProducerBlockedQuotaExceededError';
enum_symbol_by_value_ServerError(8) ->
  'ProducerBlockedQuotaExceededException';
enum_symbol_by_value_ServerError(9) -> 'ChecksumError';
enum_symbol_by_value_ServerError(10) ->
  'UnsupportedVersionError';
enum_symbol_by_value_ServerError(11) -> 'TopicNotFound';
enum_symbol_by_value_ServerError(12) ->
  'SubscriptionNotFound';
enum_symbol_by_value_ServerError(13) ->
  'ConsumerNotFound';
enum_symbol_by_value_ServerError(14) ->
  'TooManyRequests';
enum_symbol_by_value_ServerError(15) ->
  'TopicTerminatedError';
enum_symbol_by_value_ServerError(16) -> 'ProducerBusy';
enum_symbol_by_value_ServerError(17) ->
  'InvalidTopicName';
enum_symbol_by_value_ServerError(18) ->
  'IncompatibleSchema';
enum_symbol_by_value_ServerError(19) ->
  'ConsumerAssignError'.

enum_value_by_symbol_ServerError('UnknownError') -> 0;
enum_value_by_symbol_ServerError('MetadataError') -> 1;
enum_value_by_symbol_ServerError('PersistenceError') ->
  2;
enum_value_by_symbol_ServerError('AuthenticationError') ->
  3;
enum_value_by_symbol_ServerError('AuthorizationError') ->
  4;
enum_value_by_symbol_ServerError('ConsumerBusy') -> 5;
enum_value_by_symbol_ServerError('ServiceNotReady') ->
  6;
enum_value_by_symbol_ServerError('ProducerBlockedQuotaExceededError') ->
  7;
enum_value_by_symbol_ServerError('ProducerBlockedQuotaExceededException') ->
  8;
enum_value_by_symbol_ServerError('ChecksumError') -> 9;
enum_value_by_symbol_ServerError('UnsupportedVersionError') ->
  10;
enum_value_by_symbol_ServerError('TopicNotFound') -> 11;
enum_value_by_symbol_ServerError('SubscriptionNotFound') ->
  12;
enum_value_by_symbol_ServerError('ConsumerNotFound') ->
  13;
enum_value_by_symbol_ServerError('TooManyRequests') ->
  14;
enum_value_by_symbol_ServerError('TopicTerminatedError') ->
  15;
enum_value_by_symbol_ServerError('ProducerBusy') -> 16;
enum_value_by_symbol_ServerError('InvalidTopicName') ->
  17;
enum_value_by_symbol_ServerError('IncompatibleSchema') ->
  18;
enum_value_by_symbol_ServerError('ConsumerAssignError') ->
  19.

enum_symbol_by_value_AuthMethod(0) -> 'AuthMethodNone';
enum_symbol_by_value_AuthMethod(1) -> 'AuthMethodYcaV1';
enum_symbol_by_value_AuthMethod(2) ->
  'AuthMethodAthens'.

enum_value_by_symbol_AuthMethod('AuthMethodNone') -> 0;
enum_value_by_symbol_AuthMethod('AuthMethodYcaV1') -> 1;
enum_value_by_symbol_AuthMethod('AuthMethodAthens') ->
  2.

enum_symbol_by_value_ProtocolVersion(0) -> v0;
enum_symbol_by_value_ProtocolVersion(1) -> v1;
enum_symbol_by_value_ProtocolVersion(2) -> v2;
enum_symbol_by_value_ProtocolVersion(3) -> v3;
enum_symbol_by_value_ProtocolVersion(4) -> v4;
enum_symbol_by_value_ProtocolVersion(5) -> v5;
enum_symbol_by_value_ProtocolVersion(6) -> v6;
enum_symbol_by_value_ProtocolVersion(7) -> v7;
enum_symbol_by_value_ProtocolVersion(8) -> v8;
enum_symbol_by_value_ProtocolVersion(9) -> v9;
enum_symbol_by_value_ProtocolVersion(10) -> v10;
enum_symbol_by_value_ProtocolVersion(11) -> v11;
enum_symbol_by_value_ProtocolVersion(12) -> v12;
enum_symbol_by_value_ProtocolVersion(13) -> v13;
enum_symbol_by_value_ProtocolVersion(14) -> v14.

enum_value_by_symbol_ProtocolVersion(v0) -> 0;
enum_value_by_symbol_ProtocolVersion(v1) -> 1;
enum_value_by_symbol_ProtocolVersion(v2) -> 2;
enum_value_by_symbol_ProtocolVersion(v3) -> 3;
enum_value_by_symbol_ProtocolVersion(v4) -> 4;
enum_value_by_symbol_ProtocolVersion(v5) -> 5;
enum_value_by_symbol_ProtocolVersion(v6) -> 6;
enum_value_by_symbol_ProtocolVersion(v7) -> 7;
enum_value_by_symbol_ProtocolVersion(v8) -> 8;
enum_value_by_symbol_ProtocolVersion(v9) -> 9;
enum_value_by_symbol_ProtocolVersion(v10) -> 10;
enum_value_by_symbol_ProtocolVersion(v11) -> 11;
enum_value_by_symbol_ProtocolVersion(v12) -> 12;
enum_value_by_symbol_ProtocolVersion(v13) -> 13;
enum_value_by_symbol_ProtocolVersion(v14) -> 14.

'enum_symbol_by_value_CommandSubscribe.SubType'(0) ->
  'Exclusive';
'enum_symbol_by_value_CommandSubscribe.SubType'(1) ->
  'Shared';
'enum_symbol_by_value_CommandSubscribe.SubType'(2) ->
  'Failover';
'enum_symbol_by_value_CommandSubscribe.SubType'(3) ->
  'Key_Shared'.

'enum_value_by_symbol_CommandSubscribe.SubType'('Exclusive') ->
  0;
'enum_value_by_symbol_CommandSubscribe.SubType'('Shared') ->
  1;
'enum_value_by_symbol_CommandSubscribe.SubType'('Failover') ->
  2;
'enum_value_by_symbol_CommandSubscribe.SubType'('Key_Shared') ->
  3.

'enum_symbol_by_value_CommandSubscribe.InitialPosition'(0) ->
  'Latest';
'enum_symbol_by_value_CommandSubscribe.InitialPosition'(1) ->
  'Earliest'.

'enum_value_by_symbol_CommandSubscribe.InitialPosition'('Latest') ->
  0;
'enum_value_by_symbol_CommandSubscribe.InitialPosition'('Earliest') ->
  1.

'enum_symbol_by_value_CommandPartitionedTopicMetadataResponse.LookupType'(0) ->
  'Success';
'enum_symbol_by_value_CommandPartitionedTopicMetadataResponse.LookupType'(1) ->
  'Failed'.

'enum_value_by_symbol_CommandPartitionedTopicMetadataResponse.LookupType'('Success') ->
  0;
'enum_value_by_symbol_CommandPartitionedTopicMetadataResponse.LookupType'('Failed') ->
  1.

'enum_symbol_by_value_CommandLookupTopicResponse.LookupType'(0) ->
  'Redirect';
'enum_symbol_by_value_CommandLookupTopicResponse.LookupType'(1) ->
  'Connect';
'enum_symbol_by_value_CommandLookupTopicResponse.LookupType'(2) ->
  'Failed'.

'enum_value_by_symbol_CommandLookupTopicResponse.LookupType'('Redirect') ->
  0;
'enum_value_by_symbol_CommandLookupTopicResponse.LookupType'('Connect') ->
  1;
'enum_value_by_symbol_CommandLookupTopicResponse.LookupType'('Failed') ->
  2.

'enum_symbol_by_value_CommandAck.AckType'(0) ->
  'Individual';
'enum_symbol_by_value_CommandAck.AckType'(1) ->
  'Cumulative'.

'enum_value_by_symbol_CommandAck.AckType'('Individual') ->
  0;
'enum_value_by_symbol_CommandAck.AckType'('Cumulative') ->
  1.

'enum_symbol_by_value_CommandAck.ValidationError'(0) ->
  'UncompressedSizeCorruption';
'enum_symbol_by_value_CommandAck.ValidationError'(1) ->
  'DecompressionError';
'enum_symbol_by_value_CommandAck.ValidationError'(2) ->
  'ChecksumMismatch';
'enum_symbol_by_value_CommandAck.ValidationError'(3) ->
  'BatchDeSerializeError';
'enum_symbol_by_value_CommandAck.ValidationError'(4) ->
  'DecryptionError'.

'enum_value_by_symbol_CommandAck.ValidationError'('UncompressedSizeCorruption') ->
  0;
'enum_value_by_symbol_CommandAck.ValidationError'('DecompressionError') ->
  1;
'enum_value_by_symbol_CommandAck.ValidationError'('ChecksumMismatch') ->
  2;
'enum_value_by_symbol_CommandAck.ValidationError'('BatchDeSerializeError') ->
  3;
'enum_value_by_symbol_CommandAck.ValidationError'('DecryptionError') ->
  4.

'enum_symbol_by_value_CommandGetTopicsOfNamespace.Mode'(0) ->
  'PERSISTENT';
'enum_symbol_by_value_CommandGetTopicsOfNamespace.Mode'(1) ->
  'NON_PERSISTENT';
'enum_symbol_by_value_CommandGetTopicsOfNamespace.Mode'(2) ->
  'ALL'.

'enum_value_by_symbol_CommandGetTopicsOfNamespace.Mode'('PERSISTENT') ->
  0;
'enum_value_by_symbol_CommandGetTopicsOfNamespace.Mode'('NON_PERSISTENT') ->
  1;
'enum_value_by_symbol_CommandGetTopicsOfNamespace.Mode'('ALL') ->
  2.

'enum_symbol_by_value_BaseCommand.Type'(2) -> 'CONNECT';
'enum_symbol_by_value_BaseCommand.Type'(3) ->
  'CONNECTED';
'enum_symbol_by_value_BaseCommand.Type'(4) ->
  'SUBSCRIBE';
'enum_symbol_by_value_BaseCommand.Type'(5) ->
  'PRODUCER';
'enum_symbol_by_value_BaseCommand.Type'(6) -> 'SEND';
'enum_symbol_by_value_BaseCommand.Type'(7) ->
  'SEND_RECEIPT';
'enum_symbol_by_value_BaseCommand.Type'(8) ->
  'SEND_ERROR';
'enum_symbol_by_value_BaseCommand.Type'(9) -> 'MESSAGE';
'enum_symbol_by_value_BaseCommand.Type'(10) -> 'ACK';
'enum_symbol_by_value_BaseCommand.Type'(11) -> 'FLOW';
'enum_symbol_by_value_BaseCommand.Type'(12) ->
  'UNSUBSCRIBE';
'enum_symbol_by_value_BaseCommand.Type'(13) ->
  'SUCCESS';
'enum_symbol_by_value_BaseCommand.Type'(14) -> 'ERROR';
'enum_symbol_by_value_BaseCommand.Type'(15) ->
  'CLOSE_PRODUCER';
'enum_symbol_by_value_BaseCommand.Type'(16) ->
  'CLOSE_CONSUMER';
'enum_symbol_by_value_BaseCommand.Type'(17) ->
  'PRODUCER_SUCCESS';
'enum_symbol_by_value_BaseCommand.Type'(18) -> 'PING';
'enum_symbol_by_value_BaseCommand.Type'(19) -> 'PONG';
'enum_symbol_by_value_BaseCommand.Type'(20) ->
  'REDELIVER_UNACKNOWLEDGED_MESSAGES';
'enum_symbol_by_value_BaseCommand.Type'(21) ->
  'PARTITIONED_METADATA';
'enum_symbol_by_value_BaseCommand.Type'(22) ->
  'PARTITIONED_METADATA_RESPONSE';
'enum_symbol_by_value_BaseCommand.Type'(23) -> 'LOOKUP';
'enum_symbol_by_value_BaseCommand.Type'(24) ->
  'LOOKUP_RESPONSE';
'enum_symbol_by_value_BaseCommand.Type'(25) ->
  'CONSUMER_STATS';
'enum_symbol_by_value_BaseCommand.Type'(26) ->
  'CONSUMER_STATS_RESPONSE';
'enum_symbol_by_value_BaseCommand.Type'(27) ->
  'REACHED_END_OF_TOPIC';
'enum_symbol_by_value_BaseCommand.Type'(28) -> 'SEEK';
'enum_symbol_by_value_BaseCommand.Type'(29) ->
  'GET_LAST_MESSAGE_ID';
'enum_symbol_by_value_BaseCommand.Type'(30) ->
  'GET_LAST_MESSAGE_ID_RESPONSE';
'enum_symbol_by_value_BaseCommand.Type'(31) ->
  'ACTIVE_CONSUMER_CHANGE';
'enum_symbol_by_value_BaseCommand.Type'(32) ->
  'GET_TOPICS_OF_NAMESPACE';
'enum_symbol_by_value_BaseCommand.Type'(33) ->
  'GET_TOPICS_OF_NAMESPACE_RESPONSE';
'enum_symbol_by_value_BaseCommand.Type'(34) ->
  'GET_SCHEMA';
'enum_symbol_by_value_BaseCommand.Type'(35) ->
  'GET_SCHEMA_RESPONSE';
'enum_symbol_by_value_BaseCommand.Type'(36) ->
  'AUTH_CHALLENGE';
'enum_symbol_by_value_BaseCommand.Type'(37) ->
  'AUTH_RESPONSE'.

'enum_value_by_symbol_BaseCommand.Type'('CONNECT') -> 2;
'enum_value_by_symbol_BaseCommand.Type'('CONNECTED') ->
  3;
'enum_value_by_symbol_BaseCommand.Type'('SUBSCRIBE') ->
  4;
'enum_value_by_symbol_BaseCommand.Type'('PRODUCER') ->
  5;
'enum_value_by_symbol_BaseCommand.Type'('SEND') -> 6;
'enum_value_by_symbol_BaseCommand.Type'('SEND_RECEIPT') ->
  7;
'enum_value_by_symbol_BaseCommand.Type'('SEND_ERROR') ->
  8;
'enum_value_by_symbol_BaseCommand.Type'('MESSAGE') -> 9;
'enum_value_by_symbol_BaseCommand.Type'('ACK') -> 10;
'enum_value_by_symbol_BaseCommand.Type'('FLOW') -> 11;
'enum_value_by_symbol_BaseCommand.Type'('UNSUBSCRIBE') ->
  12;
'enum_value_by_symbol_BaseCommand.Type'('SUCCESS') ->
  13;
'enum_value_by_symbol_BaseCommand.Type'('ERROR') -> 14;
'enum_value_by_symbol_BaseCommand.Type'('CLOSE_PRODUCER') ->
  15;
'enum_value_by_symbol_BaseCommand.Type'('CLOSE_CONSUMER') ->
  16;
'enum_value_by_symbol_BaseCommand.Type'('PRODUCER_SUCCESS') ->
  17;
'enum_value_by_symbol_BaseCommand.Type'('PING') -> 18;
'enum_value_by_symbol_BaseCommand.Type'('PONG') -> 19;
'enum_value_by_symbol_BaseCommand.Type'('REDELIVER_UNACKNOWLEDGED_MESSAGES') ->
  20;
'enum_value_by_symbol_BaseCommand.Type'('PARTITIONED_METADATA') ->
  21;
'enum_value_by_symbol_BaseCommand.Type'('PARTITIONED_METADATA_RESPONSE') ->
  22;
'enum_value_by_symbol_BaseCommand.Type'('LOOKUP') -> 23;
'enum_value_by_symbol_BaseCommand.Type'('LOOKUP_RESPONSE') ->
  24;
'enum_value_by_symbol_BaseCommand.Type'('CONSUMER_STATS') ->
  25;
'enum_value_by_symbol_BaseCommand.Type'('CONSUMER_STATS_RESPONSE') ->
  26;
'enum_value_by_symbol_BaseCommand.Type'('REACHED_END_OF_TOPIC') ->
  27;
'enum_value_by_symbol_BaseCommand.Type'('SEEK') -> 28;
'enum_value_by_symbol_BaseCommand.Type'('GET_LAST_MESSAGE_ID') ->
  29;
'enum_value_by_symbol_BaseCommand.Type'('GET_LAST_MESSAGE_ID_RESPONSE') ->
  30;
'enum_value_by_symbol_BaseCommand.Type'('ACTIVE_CONSUMER_CHANGE') ->
  31;
'enum_value_by_symbol_BaseCommand.Type'('GET_TOPICS_OF_NAMESPACE') ->
  32;
'enum_value_by_symbol_BaseCommand.Type'('GET_TOPICS_OF_NAMESPACE_RESPONSE') ->
  33;
'enum_value_by_symbol_BaseCommand.Type'('GET_SCHEMA') ->
  34;
'enum_value_by_symbol_BaseCommand.Type'('GET_SCHEMA_RESPONSE') ->
  35;
'enum_value_by_symbol_BaseCommand.Type'('AUTH_CHALLENGE') ->
  36;
'enum_value_by_symbol_BaseCommand.Type'('AUTH_RESPONSE') ->
  37.

get_service_names() -> [].

get_service_def(_) -> error.

get_rpc_names(_) -> error.

find_rpc_def(_, _) -> error.

-spec fetch_rpc_def(_, _) -> no_return().

fetch_rpc_def(ServiceName, RpcName) ->
  erlang:error({no_such_rpc, ServiceName, RpcName}).

-spec fqbin_to_service_name(_) -> no_return().

fqbin_to_service_name(X) ->
  error({gpb_error, {badservice, X}}).

-spec service_name_to_fqbin(_) -> no_return().

service_name_to_fqbin(X) ->
  error({gpb_error, {badservice, X}}).

-spec fqbins_to_service_and_rpc_name(_,
    _) -> no_return().

fqbins_to_service_and_rpc_name(S, R) ->
  error({gpb_error, {badservice_or_rpc, {S, R}}}).

-spec service_and_rpc_name_to_fqbins(_,
    _) -> no_return().

service_and_rpc_name_to_fqbins(S, R) ->
  error({gpb_error, {badservice_or_rpc, {S, R}}}).

fqbin_to_msg_name(<<"Schema">>) -> 'Schema';
fqbin_to_msg_name(<<"MessageIdData">>) ->
  'MessageIdData';
fqbin_to_msg_name(<<"KeyValue">>) -> 'KeyValue';
fqbin_to_msg_name(<<"KeyLongValue">>) -> 'KeyLongValue';
fqbin_to_msg_name(<<"EncryptionKeys">>) ->
  'EncryptionKeys';
fqbin_to_msg_name(<<"MessageMetadata">>) ->
  'MessageMetadata';
fqbin_to_msg_name(<<"SingleMessageMetadata">>) ->
  'SingleMessageMetadata';
fqbin_to_msg_name(<<"CommandConnect">>) ->
  'CommandConnect';
fqbin_to_msg_name(<<"CommandConnected">>) ->
  'CommandConnected';
fqbin_to_msg_name(<<"CommandAuthResponse">>) ->
  'CommandAuthResponse';
fqbin_to_msg_name(<<"CommandAuthChallenge">>) ->
  'CommandAuthChallenge';
fqbin_to_msg_name(<<"AuthData">>) -> 'AuthData';
fqbin_to_msg_name(<<"CommandSubscribe">>) ->
  'CommandSubscribe';
fqbin_to_msg_name(<<"CommandPartitionedTopicMetadata">>) ->
  'CommandPartitionedTopicMetadata';
fqbin_to_msg_name(<<"CommandPartitionedTopicMetadataResponse">>) ->
  'CommandPartitionedTopicMetadataResponse';
fqbin_to_msg_name(<<"CommandLookupTopic">>) ->
  'CommandLookupTopic';
fqbin_to_msg_name(<<"CommandLookupTopicResponse">>) ->
  'CommandLookupTopicResponse';
fqbin_to_msg_name(<<"CommandProducer">>) ->
  'CommandProducer';
fqbin_to_msg_name(<<"CommandSend">>) -> 'CommandSend';
fqbin_to_msg_name(<<"CommandSendReceipt">>) ->
  'CommandSendReceipt';
fqbin_to_msg_name(<<"CommandSendError">>) ->
  'CommandSendError';
fqbin_to_msg_name(<<"CommandMessage">>) ->
  'CommandMessage';
fqbin_to_msg_name(<<"CommandAck">>) -> 'CommandAck';
fqbin_to_msg_name(<<"CommandActiveConsumerChange">>) ->
  'CommandActiveConsumerChange';
fqbin_to_msg_name(<<"CommandFlow">>) -> 'CommandFlow';
fqbin_to_msg_name(<<"CommandUnsubscribe">>) ->
  'CommandUnsubscribe';
fqbin_to_msg_name(<<"CommandSeek">>) -> 'CommandSeek';
fqbin_to_msg_name(<<"CommandReachedEndOfTopic">>) ->
  'CommandReachedEndOfTopic';
fqbin_to_msg_name(<<"CommandCloseProducer">>) ->
  'CommandCloseProducer';
fqbin_to_msg_name(<<"CommandCloseConsumer">>) ->
  'CommandCloseConsumer';
fqbin_to_msg_name(<<"CommandRedeliverUnacknowledgedMessages">>) ->
  'CommandRedeliverUnacknowledgedMessages';
fqbin_to_msg_name(<<"CommandSuccess">>) ->
  'CommandSuccess';
fqbin_to_msg_name(<<"CommandProducerSuccess">>) ->
  'CommandProducerSuccess';
fqbin_to_msg_name(<<"CommandError">>) -> 'CommandError';
fqbin_to_msg_name(<<"CommandPing">>) -> 'CommandPing';
fqbin_to_msg_name(<<"CommandPong">>) -> 'CommandPong';
fqbin_to_msg_name(<<"CommandConsumerStats">>) ->
  'CommandConsumerStats';
fqbin_to_msg_name(<<"CommandConsumerStatsResponse">>) ->
  'CommandConsumerStatsResponse';
fqbin_to_msg_name(<<"CommandGetLastMessageId">>) ->
  'CommandGetLastMessageId';
fqbin_to_msg_name(<<"CommandGetLastMessageIdResponse">>) ->
  'CommandGetLastMessageIdResponse';
fqbin_to_msg_name(<<"CommandGetTopicsOfNamespace">>) ->
  'CommandGetTopicsOfNamespace';
fqbin_to_msg_name(<<"CommandGetTopicsOfNamespaceResponse">>) ->
  'CommandGetTopicsOfNamespaceResponse';
fqbin_to_msg_name(<<"CommandGetSchema">>) ->
  'CommandGetSchema';
fqbin_to_msg_name(<<"CommandGetSchemaResponse">>) ->
  'CommandGetSchemaResponse';
fqbin_to_msg_name(<<"BaseCommand">>) -> 'BaseCommand';
fqbin_to_msg_name(E) -> error({gpb_error, {badmsg, E}}).

msg_name_to_fqbin('Schema') -> <<"Schema">>;
msg_name_to_fqbin('MessageIdData') ->
  <<"MessageIdData">>;
msg_name_to_fqbin('KeyValue') -> <<"KeyValue">>;
msg_name_to_fqbin('KeyLongValue') -> <<"KeyLongValue">>;
msg_name_to_fqbin('EncryptionKeys') ->
  <<"EncryptionKeys">>;
msg_name_to_fqbin('MessageMetadata') ->
  <<"MessageMetadata">>;
msg_name_to_fqbin('SingleMessageMetadata') ->
  <<"SingleMessageMetadata">>;
msg_name_to_fqbin('CommandConnect') ->
  <<"CommandConnect">>;
msg_name_to_fqbin('CommandConnected') ->
  <<"CommandConnected">>;
msg_name_to_fqbin('CommandAuthResponse') ->
  <<"CommandAuthResponse">>;
msg_name_to_fqbin('CommandAuthChallenge') ->
  <<"CommandAuthChallenge">>;
msg_name_to_fqbin('AuthData') -> <<"AuthData">>;
msg_name_to_fqbin('CommandSubscribe') ->
  <<"CommandSubscribe">>;
msg_name_to_fqbin('CommandPartitionedTopicMetadata') ->
  <<"CommandPartitionedTopicMetadata">>;
msg_name_to_fqbin('CommandPartitionedTopicMetadataResponse') ->
  <<"CommandPartitionedTopicMetadataResponse">>;
msg_name_to_fqbin('CommandLookupTopic') ->
  <<"CommandLookupTopic">>;
msg_name_to_fqbin('CommandLookupTopicResponse') ->
  <<"CommandLookupTopicResponse">>;
msg_name_to_fqbin('CommandProducer') ->
  <<"CommandProducer">>;
msg_name_to_fqbin('CommandSend') -> <<"CommandSend">>;
msg_name_to_fqbin('CommandSendReceipt') ->
  <<"CommandSendReceipt">>;
msg_name_to_fqbin('CommandSendError') ->
  <<"CommandSendError">>;
msg_name_to_fqbin('CommandMessage') ->
  <<"CommandMessage">>;
msg_name_to_fqbin('CommandAck') -> <<"CommandAck">>;
msg_name_to_fqbin('CommandActiveConsumerChange') ->
  <<"CommandActiveConsumerChange">>;
msg_name_to_fqbin('CommandFlow') -> <<"CommandFlow">>;
msg_name_to_fqbin('CommandUnsubscribe') ->
  <<"CommandUnsubscribe">>;
msg_name_to_fqbin('CommandSeek') -> <<"CommandSeek">>;
msg_name_to_fqbin('CommandReachedEndOfTopic') ->
  <<"CommandReachedEndOfTopic">>;
msg_name_to_fqbin('CommandCloseProducer') ->
  <<"CommandCloseProducer">>;
msg_name_to_fqbin('CommandCloseConsumer') ->
  <<"CommandCloseConsumer">>;
msg_name_to_fqbin('CommandRedeliverUnacknowledgedMessages') ->
  <<"CommandRedeliverUnacknowledgedMessages">>;
msg_name_to_fqbin('CommandSuccess') ->
  <<"CommandSuccess">>;
msg_name_to_fqbin('CommandProducerSuccess') ->
  <<"CommandProducerSuccess">>;
msg_name_to_fqbin('CommandError') -> <<"CommandError">>;
msg_name_to_fqbin('CommandPing') -> <<"CommandPing">>;
msg_name_to_fqbin('CommandPong') -> <<"CommandPong">>;
msg_name_to_fqbin('CommandConsumerStats') ->
  <<"CommandConsumerStats">>;
msg_name_to_fqbin('CommandConsumerStatsResponse') ->
  <<"CommandConsumerStatsResponse">>;
msg_name_to_fqbin('CommandGetLastMessageId') ->
  <<"CommandGetLastMessageId">>;
msg_name_to_fqbin('CommandGetLastMessageIdResponse') ->
  <<"CommandGetLastMessageIdResponse">>;
msg_name_to_fqbin('CommandGetTopicsOfNamespace') ->
  <<"CommandGetTopicsOfNamespace">>;
msg_name_to_fqbin('CommandGetTopicsOfNamespaceResponse') ->
  <<"CommandGetTopicsOfNamespaceResponse">>;
msg_name_to_fqbin('CommandGetSchema') ->
  <<"CommandGetSchema">>;
msg_name_to_fqbin('CommandGetSchemaResponse') ->
  <<"CommandGetSchemaResponse">>;
msg_name_to_fqbin('BaseCommand') -> <<"BaseCommand">>;
msg_name_to_fqbin(E) -> error({gpb_error, {badmsg, E}}).

fqbin_to_enum_name(<<"Schema.Type">>) -> 'Schema.Type';
fqbin_to_enum_name(<<"CompressionType">>) ->
  'CompressionType';
fqbin_to_enum_name(<<"ServerError">>) -> 'ServerError';
fqbin_to_enum_name(<<"AuthMethod">>) -> 'AuthMethod';
fqbin_to_enum_name(<<"ProtocolVersion">>) ->
  'ProtocolVersion';
fqbin_to_enum_name(<<"CommandSubscribe.SubType">>) ->
  'CommandSubscribe.SubType';
fqbin_to_enum_name(<<"CommandSubscribe.InitialPosition">>) ->
  'CommandSubscribe.InitialPosition';
fqbin_to_enum_name(<<"CommandPartitionedTopicMetadataResponse.Looku"
"pType">>) ->
  'CommandPartitionedTopicMetadataResponse.LookupType';
fqbin_to_enum_name(<<"CommandLookupTopicResponse.LookupType">>) ->
  'CommandLookupTopicResponse.LookupType';
fqbin_to_enum_name(<<"CommandAck.AckType">>) ->
  'CommandAck.AckType';
fqbin_to_enum_name(<<"CommandAck.ValidationError">>) ->
  'CommandAck.ValidationError';
fqbin_to_enum_name(<<"CommandGetTopicsOfNamespace.Mode">>) ->
  'CommandGetTopicsOfNamespace.Mode';
fqbin_to_enum_name(<<"BaseCommand.Type">>) ->
  'BaseCommand.Type';
fqbin_to_enum_name(E) ->
  error({gpb_error, {badenum, E}}).

enum_name_to_fqbin('Schema.Type') -> <<"Schema.Type">>;
enum_name_to_fqbin('CompressionType') ->
  <<"CompressionType">>;
enum_name_to_fqbin('ServerError') -> <<"ServerError">>;
enum_name_to_fqbin('AuthMethod') -> <<"AuthMethod">>;
enum_name_to_fqbin('ProtocolVersion') ->
  <<"ProtocolVersion">>;
enum_name_to_fqbin('CommandSubscribe.SubType') ->
  <<"CommandSubscribe.SubType">>;
enum_name_to_fqbin('CommandSubscribe.InitialPosition') ->
  <<"CommandSubscribe.InitialPosition">>;
enum_name_to_fqbin('CommandPartitionedTopicMetadataResponse.LookupType') ->
  <<"CommandPartitionedTopicMetadataResponse.Looku"
  "pType">>;
enum_name_to_fqbin('CommandLookupTopicResponse.LookupType') ->
  <<"CommandLookupTopicResponse.LookupType">>;
enum_name_to_fqbin('CommandAck.AckType') ->
  <<"CommandAck.AckType">>;
enum_name_to_fqbin('CommandAck.ValidationError') ->
  <<"CommandAck.ValidationError">>;
enum_name_to_fqbin('CommandGetTopicsOfNamespace.Mode') ->
  <<"CommandGetTopicsOfNamespace.Mode">>;
enum_name_to_fqbin('BaseCommand.Type') ->
  <<"BaseCommand.Type">>;
enum_name_to_fqbin(E) ->
  error({gpb_error, {badenum, E}}).

get_package_name() -> undefined.

uses_packages() -> false.

source_basename() -> "pulsar_api.proto".

get_all_source_basenames() -> ["pulsar_api.proto"].

get_all_proto_names() -> ["pulsar_api"].

get_msg_containment("pulsar_api") ->
  ['AuthData',
    'BaseCommand',
    'CommandAck',
    'CommandActiveConsumerChange',
    'CommandAuthChallenge',
    'CommandAuthResponse',
    'CommandCloseConsumer',
    'CommandCloseProducer',
    'CommandConnect',
    'CommandConnected',
    'CommandConsumerStats',
    'CommandConsumerStatsResponse',
    'CommandError',
    'CommandFlow',
    'CommandGetLastMessageId',
    'CommandGetLastMessageIdResponse',
    'CommandGetSchema',
    'CommandGetSchemaResponse',
    'CommandGetTopicsOfNamespace',
    'CommandGetTopicsOfNamespaceResponse',
    'CommandLookupTopic',
    'CommandLookupTopicResponse',
    'CommandMessage',
    'CommandPartitionedTopicMetadata',
    'CommandPartitionedTopicMetadataResponse',
    'CommandPing',
    'CommandPong',
    'CommandProducer',
    'CommandProducerSuccess',
    'CommandReachedEndOfTopic',
    'CommandRedeliverUnacknowledgedMessages',
    'CommandSeek',
    'CommandSend',
    'CommandSendError',
    'CommandSendReceipt',
    'CommandSubscribe',
    'CommandSuccess',
    'CommandUnsubscribe',
    'EncryptionKeys',
    'KeyLongValue',
    'KeyValue',
    'MessageIdData',
    'MessageMetadata',
    'Schema',
    'SingleMessageMetadata'];
get_msg_containment(P) ->
  error({gpb_error, {badproto, P}}).

get_pkg_containment("pulsar_api") -> undefined;
get_pkg_containment(P) ->
  error({gpb_error, {badproto, P}}).

get_service_containment("pulsar_api") -> [];
get_service_containment(P) ->
  error({gpb_error, {badproto, P}}).

get_rpc_containment("pulsar_api") -> [];
get_rpc_containment(P) ->
  error({gpb_error, {badproto, P}}).

get_enum_containment("pulsar_api") ->
  ['AuthMethod',
    'BaseCommand.Type',
    'CommandAck.AckType',
    'CommandAck.ValidationError',
    'CommandGetTopicsOfNamespace.Mode',
    'CommandLookupTopicResponse.LookupType',
    'CommandPartitionedTopicMetadataResponse.LookupType',
    'CommandSubscribe.InitialPosition',
    'CommandSubscribe.SubType',
    'CompressionType',
    'ProtocolVersion',
    'Schema.Type',
    'ServerError'];
get_enum_containment(P) ->
  error({gpb_error, {badproto, P}}).

get_proto_by_msg_name_as_fqbin(<<"SingleMessageMetadata">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"Schema">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"MessageMetadata">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"MessageIdData">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandPartitionedTopicMetadata">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandGetSchema">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"AuthData">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandSendError">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandProducer">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandError">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandCloseProducer">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandCloseConsumer">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"EncryptionKeys">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandSuccess">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandRedeliverUnacknowledgedMessages">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandReachedEndOfTopic">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandProducerSuccess">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandLookupTopic">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandConsumerStats">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandSendReceipt">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandSend">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandGetLastMessageId">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandConnected">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandConnect">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"BaseCommand">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"KeyValue">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"KeyLongValue">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandUnsubscribe">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandSubscribe">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandPartitionedTopicMetadataResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandMessage">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandLookupTopicResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandGetTopicsOfNamespaceResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandGetTopicsOfNamespace">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandGetSchemaResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandGetLastMessageIdResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandConsumerStatsResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandAuthResponse">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandAuthChallenge">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandActiveConsumerChange">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandPong">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandPing">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandFlow">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandSeek">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(<<"CommandAck">>) ->
  "pulsar_api";
get_proto_by_msg_name_as_fqbin(E) ->
  error({gpb_error, {badmsg, E}}).

-spec
get_proto_by_service_name_as_fqbin(_) -> no_return().

get_proto_by_service_name_as_fqbin(E) ->
  error({gpb_error, {badservice, E}}).

get_proto_by_enum_name_as_fqbin(<<"ServerError">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandAck.ValidationError">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"AuthMethod">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"Schema.Type">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CompressionType">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandSubscribe.SubType">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandPartitionedTopicMetadataResponse.Looku"
"pType">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandLookupTopicResponse.LookupType">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandGetTopicsOfNamespace.Mode">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandAck.AckType">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"BaseCommand.Type">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"ProtocolVersion">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(<<"CommandSubscribe.InitialPosition">>) ->
  "pulsar_api";
get_proto_by_enum_name_as_fqbin(E) ->
  error({gpb_error, {badenum, E}}).

-spec get_protos_by_pkg_name_as_fqbin(_) -> no_return().

get_protos_by_pkg_name_as_fqbin(E) ->
  error({gpb_error, {badpkg, E}}).

gpb_version_as_string() -> "4.10.0".

gpb_version_as_list() -> [4, 10, 0].