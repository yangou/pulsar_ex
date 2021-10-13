defmodule PulsarEx.PartitionedProducer do
  defmodule State do
    @enforce_keys [
      :brokers,
      :admin_port,
      :topic,
      :topic_name,
      :broker,
      :connection,
      :producer_id,
      :producer_name,
      :producer_access_mode,
      :last_sequence_id,
      :max_message_size,
      :properties,
      :batch_enabled,
      :batch_size,
      :flush_interval,
      :refresh_interval,
      :termination_timeout,
      :queue
    ]
    defstruct [
      :brokers,
      :admin_port,
      :topic,
      :topic_name,
      :broker,
      :connection,
      :producer_id,
      :producer_name,
      :producer_access_mode,
      :last_sequence_id,
      :max_message_size,
      :properties,
      :batch_enabled,
      :batch_size,
      :flush_interval,
      :refresh_interval,
      :termination_timeout,
      :queue
    ]
  end

  use GenServer

  require Logger

  alias PulsarEx.{Topic, Admin, ConnectionManager, Connection, ProducerMessage}

  @refresh_interval 60_000
  @batch_enabled false
  @batch_size 100
  @flush_interval 100
  @termination_timeout 3_000

  def produce(pid, payload, message_opts, true) do
    GenServer.call(pid, {:produce, payload, message_opts})
  end

  def produce(pid, payload, message_opts, false) do
    GenServer.cast(pid, {:produce, payload, message_opts})
  end

  def start_link({%Topic{} = topic, producer_opts}) do
    GenServer.start_link(__MODULE__, {topic, producer_opts})
  end

  @impl true
  def init({%Topic{} = topic, producer_opts}) do
    Process.flag(:trap_exit, true)

    brokers = Application.fetch_env!(:pulsar_ex, :brokers)
    admin_port = Application.fetch_env!(:pulsar_ex, :admin_port)

    with {:ok, broker} <- Admin.lookup_topic(brokers, admin_port, topic),
         {:ok, pool} <- ConnectionManager.get_connection(broker),
         {:ok, reply} <-
           :poolboy.transaction(
             pool,
             &Connection.create_producer(&1, Topic.to_name(topic), producer_opts)
           ) do
      %{
        topic: topic_name,
        producer_id: producer_id,
        producer_name: producer_name,
        producer_access_mode: producer_access_mode,
        last_sequence_id: last_sequence_id,
        max_message_size: max_message_size,
        properties: properties,
        connection: connection
      } = reply

      Process.monitor(connection)

      Logger.debug("Started producer for topic #{topic_name}")

      refresh_interval =
        max(Keyword.get(producer_opts, :refresh_interval, @refresh_interval), 10_000)

      Process.send_after(self(), :refresh, refresh_interval + :rand.uniform(refresh_interval))

      state = %State{
        brokers: brokers,
        admin_port: admin_port,
        topic: topic,
        topic_name: topic_name,
        broker: broker,
        connection: connection,
        producer_id: producer_id,
        producer_name: producer_name,
        producer_access_mode: producer_access_mode,
        last_sequence_id: last_sequence_id,
        max_message_size: max_message_size,
        properties: properties,
        batch_enabled: Keyword.get(producer_opts, :batch_enabled, @batch_enabled),
        batch_size: max(Keyword.get(producer_opts, :batch_size, @batch_size), 1),
        flush_interval: max(Keyword.get(producer_opts, :flush_interval, @flush_interval), 100),
        refresh_interval: refresh_interval,
        termination_timeout:
          min(Keyword.get(producer_opts, :termination_timeout, @termination_timeout), 5_000),
        queue: :queue.new()
      }

      if state.batch_enabled do
        Process.send_after(self(), :flush, state.flush_interval)
      end

      {:ok, state}
    else
      err ->
        {:stop, err}
    end
  end

  @impl true
  def handle_info({:DOWN, _, _, _, _}, %{topic_name: topic_name} = state) do
    Logger.error("Connection down for producer with topic #{topic_name}")

    {:stop, {:error, :connection_down}, state}
  end

  @impl true
  def handle_info(:refresh, %{broker: broker, topic_name: topic_name} = state) do
    Logger.debug("Refreshing broker connection for topic #{topic_name}")

    case Admin.lookup_topic(state.brokers, state.admin_port, state.topic) do
      {:ok, ^broker} ->
        Logger.debug("Unerlying broker unchanged for topic #{topic_name}")

        Process.send_after(
          self(),
          :refresh,
          state.refresh_interval + :rand.uniform(state.refresh_interval)
        )

        {:noreply, state}

      {:error, err} ->
        Logger.error(
          "Error refreshing topic broker from producer for topic #{topic_name}, #{inspect(err)}"
        )

        {:stop, {:error, err}, state}

      _ ->
        Logger.warn("Unerlying broker changed for producer with topic #{topic_name}")

        {:stop, {:error, :broker_changed}, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    if :queue.len(state.queue) > 0 do
      {messages, froms} = :queue.to_list(state.queue) |> Enum.unzip()

      reply = Connection.send_messages(state.connection, messages)
      Task.async_stream(froms, &reply(&1, reply)) |> Enum.count()

      Process.send_after(self(), :flush, state.flush_interval)

      {:noreply, %{state | queue: :queue.new()}}
    else
      Process.send_after(self(), :flush, state.flush_interval)

      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:produce, payload, message_opts}, from, state) when is_list(message_opts) do
    handle_call({:produce, payload, map_message_opts(message_opts)}, from, state)
  end

  @impl true
  def handle_call({:produce, payload, %{} = message_opts}, _from, %{batch_enabled: false} = state) do
    {message, state} = create_message(payload, message_opts, state)
    reply = Connection.send_message(state.connection, message)

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:produce, payload, %{deliver_at_time: nil} = message_opts}, from, state) do
    {message, state} = create_message(payload, message_opts, state)
    queue = :queue.in({message, from}, state.queue)

    cond do
      :queue.len(queue) < state.batch_size ->
        {:noreply, %{state | queue: queue}}

      true ->
        {messages, froms} = :queue.to_list(queue) |> Enum.unzip()

        reply = Connection.send_messages(state.connection, messages)
        Task.async_stream(froms, &reply(&1, reply)) |> Enum.count()

        {:noreply, %{state | queue: :queue.new()}}
    end
  end

  @impl true
  def handle_call({:produce, payload, message_opts}, _from, state) do
    {message, state} = create_message(payload, message_opts, state)
    reply = Connection.send_message(state.connection, message)

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:close, %{topic_name: topic_name} = state) do
    Logger.warn("Received close command from connection for topic #{topic_name}")

    {:stop, {:shutdown, :close}, state}
  end

  @impl true
  def handle_cast({:produce, payload, message_opts}, state) when is_list(message_opts) do
    handle_cast({:produce, payload, map_message_opts(message_opts)}, state)
  end

  @impl true
  def handle_cast({:produce, payload, %{} = message_opts}, %{batch_enabled: false} = state) do
    {message, state} = create_message(payload, message_opts, state)
    Connection.send_message(state.connection, message)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:produce, payload, %{deliver_at_time: nil} = message_opts}, state) do
    {message, state} = create_message(payload, message_opts, state)
    queue = :queue.in({message, nil}, state.queue)

    cond do
      :queue.len(queue) < state.batch_size ->
        {:noreply, %{state | queue: queue}}

      true ->
        {messages, froms} = :queue.to_list(queue) |> Enum.unzip()

        reply = Connection.send_messages(state.connection, messages)
        Task.async_stream(froms, &reply(&1, reply)) |> Enum.count()

        {:noreply, %{state | queue: :queue.new()}}
    end
  end

  @impl true
  def handle_cast({:produce, payload, message_opts}, state) do
    {message, state} = create_message(payload, message_opts, state)
    Connection.send_message(state.connection, message)

    {:noreply, state}
  end

  defp map_message_opts(%{} = message_opts), do: map_message_opts(Enum.into(message_opts, []))

  defp map_message_opts(message_opts) do
    deliver_at_time =
      case Keyword.get(message_opts, :delay) do
        nil ->
          Keyword.get(message_opts, :deliver_at_time)

        delay when is_integer(delay) ->
          Timex.add(Timex.now(), Timex.Duration.from_milliseconds(delay))

        %Timex.Duration{} = delay ->
          Timex.add(Timex.now(), delay)
      end

    %{
      properties: Keyword.get(message_opts, :properties),
      partition_key: Keyword.get(message_opts, :partition_key),
      ordering_key: Keyword.get(message_opts, :ordering_key),
      event_time: Keyword.get(message_opts, :event_time),
      deliver_at_time: deliver_at_time
    }
  end

  defp create_message(payload, message_opts, state) do
    message = %ProducerMessage{
      producer_id: state.producer_id,
      producer_name: state.producer_name,
      sequence_id: state.last_sequence_id + 1,
      payload: payload,
      properties: Map.get(message_opts, :properties),
      partition_key: Map.get(message_opts, :partition_key),
      ordering_key: Map.get(message_opts, :ordering_key),
      event_time: Map.get(message_opts, :event_time),
      deliver_at_time: Map.get(message_opts, :deliver_at_time)
    }

    state = %{state | last_sequence_id: state.last_sequence_id + 1}

    {message, state}
  end

  @impl true
  def terminate(reason, %{topic_name: topic_name} = state) do
    len = :queue.len(state.queue)

    if len > 0 do
      Logger.error(
        "Sending closed error to #{len} remaining message in producer for topic #{
          state.topic_name
        }"
      )

      fast_fail(state.queue, state)
    end

    state = %{state | queue: :queue.new()}

    case reason do
      :shutdown ->
        Logger.debug("Stopping producer for topic #{topic_name}, #{inspect(reason)}")
        state

      :normal ->
        Logger.debug("Stopping producer for topic #{topic_name}, #{inspect(reason)}")
        state

      {:shutdown, _} ->
        Logger.debug("Stopping producer for topic #{topic_name}, #{inspect(reason)}")
        state

      _ ->
        Logger.error("Stopping producer for topic #{topic_name}, #{inspect(reason)}")
        # avoid immediate recreate on broker
        Process.sleep(state.termination_timeout)
        state
    end
  end

  defp fast_fail(queue, state) do
    case :queue.out(queue) do
      {:empty, {[], []}} ->
        nil

      {{:value, {_, from}}, queue} ->
        reply(from, {:error, :closed})
        fast_fail(queue, state)
    end
  end

  defp reply(nil, _), do: nil
  defp reply(from, reply), do: GenServer.reply(from, reply)
end