%%%-------------------------------------------------------------------
%%% @author root
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. 4月 2021 下午6:04
%%%-------------------------------------------------------------------
-module(pulsar_producers).
-author("root").

-export([start_supervised/3, stop_supervised/1, start_link/3]).

-export([pick_producer/2]).

-export([code_change/3, handle_call/3, handle_cast/2, handle_info/2, init/1, terminate/2]).

-record(state,
{topic,
  client_id,
  workers,
  partitions,
  producer_opts,
  producers = #{}}).


start_supervised(ClientId, Topic, ProducerOpts) ->
%%  开启生产者
  {ok, Pid} = pulsar_producers_sup:ensure_present(ClientId, Topic, ProducerOpts),
  {Partitions, Workers} = gen_server:call(Pid, get_workers, infinity),
  {ok,
    #{client => ClientId, topic => Topic,
      workers => Workers, partitions => Partitions,
      strategy => maps:get(strategy, ProducerOpts, random)}}.
%% 停止
stop_supervised(#{client := ClientId, workers := Workers}) ->
  pulsar_producers_sup:ensure_absence(ClientId, Workers).
%% 启动
start_link(ClientId, Topic, ProducerOpts) ->
  gen_server:start_link({local, get_name(ProducerOpts)}, pulsar_producers, [ClientId, Topic, ProducerOpts], []).

%% 选择生产者
pick_producer(#{workers := Workers, partitions := Partitions, strategy := Strategy}, Batch) ->
  Partition = pick_partition(Partitions, Strategy, Batch),
  do_pick_producer(Strategy, Partition, Partitions, Workers).

do_pick_producer(Strategy, Partition, Partitions, Workers) ->
  Pid = lookup_producer(Workers, Partition),
  case is_pid(Pid) andalso is_process_alive(Pid) of
    true -> {Partition, Pid};
    false when Strategy =:= random ->
      pick_next_alive(Workers, Partition, Partitions);
    false when Strategy =:= roundrobin ->
      R = {Partition, Pid} = pick_next_alive(Workers, Partition, Partitions),
      _ = put(pulsar_roundrobin, (Partition + 1) rem Partitions),
      R;
    false -> erlang:error({producer_down, Pid})
  end.

pick_next_alive(Workers, Partition, Partitions) ->
  pick_next_alive(Workers, (Partition + 1) rem Partitions, Partitions, _Tried = 1).

pick_next_alive(_Workers, _Partition, Partitions, Partitions) ->
  erlang:error(all_producers_down);
pick_next_alive(Workers, Partition, Partitions, Tried) ->
  Pid = lookup_producer(Workers, Partition),
  case is_alive(Pid) of
    true -> {Partition, Pid};
    false ->
      pick_next_alive(Workers, (Partition + 1) rem Partitions, Partitions, Tried + 1)
  end.

is_alive(Pid) ->
  is_pid(Pid) andalso is_process_alive(Pid).

lookup_producer(#{workers := Workers}, Partition) ->
  lookup_producer(Workers, Partition);
lookup_producer(Workers, Partition) when is_map(Workers) ->
  maps:get(Partition, Workers);
lookup_producer(Workers, Partition) ->
  case ets:lookup(Workers, Partition) of
    [{Partition, Pid}] -> Pid;
    _ -> undefined
  end.

pick_partition(Partitions, random, _) ->
  rand:uniform(Partitions) - 1;
pick_partition(Partitions, roundrobin, _) ->
  Partition = case get(pulsar_roundrobin) of
                undefined -> 0;
                Number -> Number
              end,
  _ = put(pulsar_roundrobin, (Partition + 1) rem Partitions), Partition;
pick_partition(Partitions, first_key_dispatch,[#{key := Key} | _]) ->
  murmerl3:hash_32(Key) rem Partitions.

init([ClientId, Topic, ProducerOpts]) ->
  erlang:process_flag(trap_exit, true),
  {ok,
    #state{topic = Topic, client_id = ClientId,
      producer_opts = ProducerOpts,
      workers = ets:new(get_name(ProducerOpts), [protected, named_table, {read_concurrency, true}])},
    0}.

handle_call(get_workers, _From, State = #state{workers = Workers, partitions = Partitions}) ->
  {reply, {Partitions, Workers}, State};
handle_call(_Call, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) -> {noreply, State}.

handle_info(timeout, State = #state{client_id = ClientId, topic = Topic, workers = Workers, producer_opts = ProducerOpts, producers = Producers}) ->
  case pulsar_client_sup:find_client(ClientId) of
    {ok, Pid} ->
      {_, Partitions} = pulsar_client:get_topic_metadata(Pid, Topic),
      PartitionTopics = create_partition_topic(Topic, Partitions),
      NewProducers = lists:foldl(fun ({PartitionTopic, Partition}, Acc) ->
        start_producer(Pid, Partition, PartitionTopic, ProducerOpts, Workers, Acc) end, Producers, PartitionTopics),
      {noreply, State#state{partitions = length(PartitionTopics), producers = NewProducers}};
    {error, Reason} -> {stop, {shutdown, Reason}, State}
  end;
handle_info({'EXIT', Pid, _Error}, State = #state{workers = Workers, producers = Producers}) ->
  case maps:get(Pid, Producers, undefined) of
    undefined ->
      log_error("Not find Pid:~p producer", [Pid]),
      {noreply, State};
    {Partition, PartitionTopic} ->
      ets:delete(Workers, Partition),
      self() ! {restart_producer, Partition, PartitionTopic},
      {noreply, State#state{producers = maps:remove(Pid, Producers)}}
  end;
handle_info({restart_producer, Partition, PartitionTopic}, State = #state{client_id = ClientId, producers = Producers, workers = Workers, producer_opts = ProducerOpts}) ->
  case pulsar_client_sup:find_client(ClientId) of
    {ok, Pid} ->
      NewProducers = start_producer(Pid, Partition, PartitionTopic, ProducerOpts, Workers, Producers),
      {noreply, State#state{producers = NewProducers}};
    {error, Reason} -> {stop, {shutdown, Reason}, State}
  end;
handle_info(_Info, State) ->
  log_error("Receive unknown message:~p~n", [_Info]),
  {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

terminate(_, _St) -> ok.

%% 分区主题
create_partition_topic(Topic, 0) -> [{Topic, 0}];

create_partition_topic(Topic, Partitions) ->
  lists:map(fun (Partition) -> {lists:concat([Topic, "-partition-", Partition]), Partition} end, lists:seq(0, Partitions - 1)).

get_name(ProducerOpts) ->
  maps:get(name, ProducerOpts, pulsar_producers).

log_error(Fmt, Args) ->
  error_logger:error_msg(Fmt, Args).

start_producer(Pid, Partition, PartitionTopic, ProducerOpts, Workers, Producers) ->
  try BrokerServiceUrl = pulsar_client:lookup_topic(Pid, PartitionTopic),
  {ok, Producer} = pulsar_producer:start_link(PartitionTopic, BrokerServiceUrl, ProducerOpts),
  ets:insert(Workers, {Partition, Producer}),
  maps:put(Producer, {Partition, PartitionTopic}, Producers)
  catch
    Error:Reason:Stacktrace ->
      log_error("Start producer: ~p, ~p", [Error, {Reason, Stacktrace}]),
      self() ! {restart_producer, Partition, PartitionTopic},
      Producers
  end.