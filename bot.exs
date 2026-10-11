Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule Diggominer do
  @moduledoc false

  @my_project "Diggominer Miniapp"
  @base_url "https://diggo.linkpc.net"
  @root __DIR__
  @task_gap_ms 900
  @social_poll_ms 1_500
  @ad_poll_ms 2_000
  @clock_slack_s 2
  @ad_poll_attempts 8
  @store "token.json"

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    if accounts == [] and load_store() == %{} do
      red("File data.txt is empty, please add your initData entries")
      System.halt(1)
    end

    proxies = load_lines("proxy.txt")
    settings = load_settings()

    loop(accounts, proxies, settings, 1)
  end

  defp loop(accounts, proxies, settings, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    accounts
    |> roster()
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> yellow("Running without proxy for this account")
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      try do
        process_account(entry, index + 1, proxy)
      rescue
        _error ->
          red("Account #{index + 1} was skipped after an error")
      end
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    countdown(sleep_seconds(settings), "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, cycle + 1)
  end

  defp roster(accounts) do
    listed =
      Enum.map(accounts, fn line ->
        case identity(line) do
          {:ok, user_id, profile, username} ->
            %{user_id: user_id, init_data: line, profile: profile, username: username}

          {:error, _reason} ->
            %{user_id: nil, init_data: line, profile: %{}, username: ""}
        end
      end)

    seen = for %{user_id: user_id} <- listed, is_binary(user_id), do: user_id

    stored =
      load_store()
      |> Map.keys()
      |> Enum.reject(&(&1 in seen))
      |> Enum.map(fn user_id -> %{user_id: user_id, init_data: nil, profile: %{}, username: ""} end)

    listed ++ stored
  end

  defp process_account(entry, label, proxy) do
    case sign_in(entry, proxy) do
      {:ok, session} ->
        case fetch_state(session, entry.init_data, proxy) do
          {:ok, state} ->
            name = display_name(get(state, "player", %{}), entry.profile)

            green(
              "Signed in #{shorten(clean_text(name, "account"), "account", 20)} with #{money(balance_of(state))} DIGGO"
            )

            process_mining(state, session, entry.init_data, proxy)
            process_tasks(state, session, entry.init_data, proxy)
            process_streak(state, session, entry.init_data, proxy)
            process_referrals(state, session, entry.init_data, proxy)
            process_friends(state, session, entry.init_data, proxy)
            process_rank(state, name, entry.init_data, proxy)

          {:error, reason} ->
            red("Account #{label} state fetch failed with #{short_reason(reason)}")
        end

      {:error, reason} ->
        red("Account #{label} initData refused with #{short_reason(reason)}")
    end
  end

  defp sign_in(%{user_id: nil}, _proxy), do: {:error, "user object missing"}

  defp sign_in(entry, proxy) do
    case stored_session(entry.user_id) do
      {:ok, stored} ->
        case fetch_state(stored, entry.init_data, proxy) do
          {:ok, _state} -> {:ok, stored}
          {:error, _reason} -> fresh_sign_in(entry, proxy)
        end

      :none ->
        fresh_sign_in(entry, proxy)
    end
  end

  defp stored_session(user_id) do
    case fetch_token(user_id) do
      %{token: token} = stored when is_binary(token) and token != "" ->
        if token_live?(stored), do: {:ok, stored}, else: :none

      _other ->
        :none
    end
  end

  defp token_live?(%{expires_at: expires_at}) when is_integer(expires_at) and expires_at > 0 do
    expires_at > System.system_time(:millisecond)
  end

  defp token_live?(_stored), do: true

  defp fresh_sign_in(%{init_data: nil}, _proxy), do: {:error, "no live session token"}

  defp fresh_sign_in(entry, proxy) do
    case auth(entry.init_data, proxy) do
      {:ok, session} ->
        {:ok, Map.put(session, :user_id, entry.user_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_mining(state, session, account, proxy) do
    mining = get(state, "mining", %{})
    left = remaining(get(mining, "nextClaimAt"))

    if left > 0 do
      yellow("Mining cycle is still running with #{format_duration(left)} left")
    else
      claim_mining(session, account, proxy)
    end
  end

  defp claim_mining(session, account, proxy) do
    case call("/api/claims/mining", %{}, session, account, proxy) do
      {:ok, data} ->
        case number(get(data, "amount", 0)) do
          amount when amount > 0 ->
            green("Mining cycle reward of #{money(amount)} DIGGO was claimed")

          _other ->
            yellow("Mining cycle claim was accepted without a confirmed reward")
        end

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        if String.contains?(text, "COOLDOWN") do
          yellow("Mining cycle reward is not ready on the server yet")
        else
          yellow("Mining cycle claim was refused with #{short_reason(reason)}")
        end
    end
  end

  defp process_tasks(state, session, account, proxy) do
    tasks = get(state, "tasks", %{})

    open =
      task_order()
      |> Enum.map(fn id -> {id, get(tasks, id, %{})} end)
      |> Enum.filter(fn {id, record} -> task_open?(id, record) end)

    cond do
      open == [] ->
        green("Every available account task was already completed")

      true ->
        green("Found #{plural(length(open), "account task")} to process")
        Enum.each(open, fn {id, record} -> process_task(id, record, session, account, proxy) end)
    end
  end

  defp task_order,
    do: ["checkin", "telegram", "x_follow", "x_post", "x", "invite", "play", "ad"]

  defp task_open?(_id, record) when not is_map(record), do: false

  defp task_open?(_id, record) do
    get(record, "enabled", true) != false and get(record, "claimed", false) != true and
      remaining(get(record, "nextClaimAt")) <= 0
  end

  defp task_ready?(record) do
    number(get(record, "progress", 0)) >= number(get(record, "total", 1))
  end

  defp process_task("ad", _record, session, account, proxy) do
    ad_flow(session, account, proxy)
  end

  defp process_task("telegram", _record, session, account, proxy) do
    case call("/api/tasks/verify", %{"taskId" => "telegram"}, session, account, proxy) do
      {:ok, _data} ->
        :timer.sleep(@task_gap_ms)
        claim_task("telegram", session, account, proxy)

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        if String.contains?(text, "MEMBER") or String.contains?(text, "NOT_JOIN") do
          yellow("Task Telegram community still needs a manual channel join")
        else
          yellow("Task Telegram community was refused with #{short_reason(reason)}")
        end
    end
  end

  defp process_task(id, record, session, account, proxy) do
    cond do
      task_ready?(record) -> claim_task(id, session, account, proxy)
      get(record, "verification") == "self_reported" -> social_flow(id, session, account, proxy)
      true -> claim_task(id, session, account, proxy)
    end
  end

  defp ad_flow(session, account, proxy) do
    case call("/api/adsgram/start", %{}, session, account, proxy) do
      {:ok, data} ->
        attempt_id = get(data, "attemptId", "")

        cond do
          get(data, "ready") == true ->
            claim_task("ad", session, account, proxy)

          is_binary(attempt_id) and attempt_id != "" ->
            green("Reward ad attempt was opened for this account")
            complete_ad(attempt_id, session, account, proxy)

          true ->
            yellow("Reward ad attempt was refused without an attempt id")
        end

      {:error, reason} ->
        yellow("Reward ad was refused with #{short_reason(reason)}")
    end
  end

  defp complete_ad(attempt_id, session, account, proxy) do
    case call("/api/adsgram/complete", %{"attemptId" => attempt_id}, session, account, proxy) do
      {:ok, data} ->
        record = get(get(get(data, "state", data), "tasks", %{}), "ad", %{})

        if task_ready?(record) do
          claim_task("ad", session, account, proxy)
        else
          ad_poll(attempt_id, session, account, proxy, @ad_poll_attempts)
        end

      {:error, reason} ->
        yellow("Reward ad completion was refused with #{short_reason(reason)}")
    end
  end

  defp ad_poll(attempt_id, session, account, proxy, 0) do
    call("/api/adsgram/cancel", %{"attemptId" => attempt_id}, session, account, proxy)
    yellow("Reward ad was not verified and the attempt was cancelled")
  end

  defp ad_poll(attempt_id, session, account, proxy, left) do
    countdown(div(@ad_poll_ms, 1000), "Waiting for the reward ad confirmation")

    case fetch_state(session, account, proxy) do
      {:ok, state} ->
        record = get(get(state, "tasks", %{}), "ad", %{})

        cond do
          get(record, "claimed") == true ->
            green("Task Reward ad was already credited on this account")

          task_ready?(record) ->
            claim_task("ad", session, account, proxy)

          true ->
            ad_poll(attempt_id, session, account, proxy, left - 1)
        end

      {:error, reason} ->
        yellow("Reward ad confirmation check failed with #{short_reason(reason)}")
    end
  end

  defp social_flow(id, session, account, proxy) do
    case call("/api/tasks/social/start", %{"taskId" => id}, session, account, proxy) do
      {:ok, data} ->
        attempt = get(data, "attempt", %{})
        attempt_id = get(attempt, "attemptId", "")
        wait = social_wait(attempt)

        if is_binary(attempt_id) and attempt_id != "" do
          if wait > 0 do
            green("Task #{task_title(id)} needs a confirmation window of #{plural(wait, "second")}")
          end

          countdown(wait, "Waiting for #{task_title(id)} confirmation")

          case confirm_social(id, attempt_id, session, account, proxy) do
            {:ok, _data} ->
              :timer.sleep(@task_gap_ms)
              claim_task(id, session, account, proxy)

            {:error, reason} ->
              yellow("Task #{task_title(id)} was refused with #{short_reason(reason)}")
          end
        else
          yellow("Task #{task_title(id)} was refused with no confirmation window")
        end

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        if String.contains?(text, "ALREADY") do
          yellow("Task #{task_title(id)} was already completed on this account")
        else
          yellow("Task #{task_title(id)} was refused with #{short_reason(reason)}")
        end
    end
  end

  defp social_wait(attempt) do
    confirm_at = whole(get(attempt, "confirmAt", 0), 0)
    expires_at = whole(get(attempt, "expiresAt", 0), 0)

    case confirm_at do
      0 -> 0
      stamp -> max(div(stamp - now_ms(), 1000), 0) + @clock_slack_s
    end
    |> cap_wait(expires_at, confirm_at)
  end

  defp cap_wait(seconds, expires_at, confirm_at) do
    case expires_at - confirm_at do
      span when span > 0 -> min(seconds, div(span, 1000))
      _other -> seconds
    end
  end

  defp confirm_social(id, attempt_id, session, account, proxy) do
    payload = %{"taskId" => id, "attemptId" => attempt_id, "confirmed" => true}

    case call("/api/tasks/social/confirm", payload, session, account, proxy) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        if String.contains?(text, "EXPIRED") or String.contains?(text, "NOT_READY") or
             String.contains?(text, "WAIT") or String.contains?(text, "PENDING") do
          :timer.sleep(@social_poll_ms)
          confirm_social(id, attempt_id, session, account, proxy)
        else
          {:error, reason}
        end
    end
  end

  defp claim_task(id, session, account, proxy) do
    title = task_title(id)

    case call("/api/tasks/claim", %{"taskId" => id}, session, account, proxy) do
      {:ok, data} ->
        case number(get(data, "amount", 0)) do
          amount when amount > 0 ->
            green("Task #{title} claimed earning #{money(amount)} DIGGO")

          _other ->
            yellow("Task #{title} was accepted without a confirmed reward")
        end

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        cond do
          String.contains?(text, "ALREADY") ->
            yellow("Task #{title} was already completed on this account")

          String.contains?(text, "MEMBER") or String.contains?(text, "NOT_JOIN") ->
            yellow("Task #{title} still needs a manual channel join")

          String.contains?(text, "NOT_VERIFIED") ->
            yellow("Task #{title} still needs verified completion")

          String.contains?(text, "NOT_CONFIGURED") ->
            yellow("Task #{title} is not enabled on the server yet")

          true ->
            yellow("Task #{title} was refused with #{short_reason(reason)}")
        end
    end
  end

  defp task_title("checkin"), do: "Daily check in"
  defp task_title("telegram"), do: "Telegram community"
  defp task_title("x"), do: "X community"
  defp task_title("x_follow"), do: "X follow"
  defp task_title("x_post"), do: "X post"
  defp task_title("invite"), do: "Invite friends"
  defp task_title("play"), do: "Map level two"
  defp task_title("ad"), do: "Reward ad"
  defp task_title(id), do: shorten(clean_text(id, "task"), "task", 18)

  defp process_streak(state, session, account, proxy) do
    days =
      state
      |> get("dayRewards", [])
      |> case do
        list when is_list(list) -> list
        _other -> []
      end
      |> Enum.filter(&(get(&1, "status") == "available"))
      |> Enum.map(&whole(get(&1, "day", 0), 0))
      |> Enum.reject(&(&1 == 0))

    Enum.each(days, fn day ->
      case call("/api/streak/claim", %{"day" => day}, session, account, proxy) do
        {:ok, data} ->
          case number(get(data, "amount", 0)) do
            amount when amount > 0 ->
              green("Daily streak day #{day} claimed earning #{money(amount)} DIGGO")

            _other ->
              yellow("Daily streak day #{day} was accepted without a reward")
          end

        {:error, reason} ->
          yellow("Daily streak day #{day} was refused with #{short_reason(reason)}")
      end

      :timer.sleep(@task_gap_ms)
    end)
  end

  defp process_referrals(_state, session, account, proxy) do
    case call("/api/referrals/claim", %{}, session, account, proxy) do
      {:ok, data} ->
        case number(get(data, "amount", 0)) do
          amount when amount > 0 ->
            green("Referral bonus credited #{money(amount)} DIGGO to this account")

          _other ->
            yellow("No referral commission was pending on this account")
        end

      {:error, reason} ->
        yellow("Referral commission was refused with #{short_reason(reason)}")
    end
  end

  defp process_friends(state, _session, _account, _proxy) do
    friends = get(state, "friends", %{})
    rank = whole(get(friends, "rank", 0), 0)
    count = whole(get(friends, "count", 0), 0)

    if rank > 0 do
      green("Friend rank #{rank} with #{plural(count, "friend")} on this account")
    else
      yellow("This account is not ranked on the friend list yet")
    end
  end

  defp process_rank(state, name, _account, _proxy) do
    player = get(state, "player", %{})
    level = whole(get(player, "level", 0), 0)
    xp = whole(get(player, "xp", 0), 0)

    green(
      "Map level #{level} with #{xp} XP for #{shorten(clean_text(name, "account"), "account", 20)}"
    )
  end

  defp auth(init_data, proxy) do
    case call("/api/auth/telegram", %{"initData" => init_data}, nil, init_data, proxy) do
      {:ok, data} ->
        token = get(data, "token", "")

        if is_binary(token) and token != "" do
          expires_at = whole(get(data, "expiresAt", 0), 0)
          persist_token(init_data, token, expires_at)
          {:ok, %{token: token, expires_at: expires_at}}
        else
          {:error, "no session token"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_state(session, init_data, proxy) do
    case call_get("/api/state", session, init_data, proxy) do
      {:ok, data} ->
        case get(data, "state") do
          %{} = state -> {:ok, state}
          _other -> {:error, "empty account snapshot"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(path, payload, session, init_data, proxy) do
    case request(:post, path, payload, session, init_data, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_get(path, session, init_data, proxy) do
    case request(:get, path, %{}, session, init_data, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap(body) do
    case body do
      %{"error" => error} -> {:error, error}
      %{"state" => _state} = data -> {:ok, data}
      %{} = data -> {:ok, data}
      _other -> {:ok, %{}}
    end
  end

  defp request(method, path, payload, session, init_data, proxy) do
    url = String.to_charlist(String.trim_trailing(@base_url, "/") <> path)
    {profile, auth} = proxy_setup(proxy)

    headers =
      [
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"*/*"},
        {~c"accept-language", ~c"en-US,en;q=0.9"},
        {~c"origin", String.to_charlist(@base_url)},
        {~c"referer", String.to_charlist(@base_url <> "/")},
        {~c"user-agent",
         ~c"Mozilla/5.0 (Linux; Android 13; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"}
      ] ++ session_headers(session, init_data) ++ idempotency_headers(method)

    body = payload |> YuurisanJSON.encode()

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    dispatch(method, url, headers, body, options, profile)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp session_headers(%{token: token}, _init_data) when is_binary(token) do
    [{~c"authorization", String.to_charlist("Bearer " <> token)}]
  end

  defp session_headers(_session, nil), do: []

  defp session_headers(_session, init_data) do
    [{~c"x-telegram-init-data", String.to_charlist(init_data)}]
  end

  defp idempotency_headers(:post) do
    [{~c"idempotency-key", String.to_charlist(random_key())}]
  end

  defp idempotency_headers(_method), do: []

  defp dispatch(:get, url, headers, _body, options, profile) do
    handle(:httpc.request(:get, {url, headers}, options, [body_format: :binary], profile))
  end

  defp dispatch(:post, url, headers, body, options, profile) do
    handle(
      :httpc.request(
        :post,
        {url, headers, ~c"application/json", body},
        options,
        [body_format: :binary],
        profile
      )
    )
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, response}})
       when status >= 200 and status < 300 do
    case YuurisanJSON.decode(response) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "unreadable response"}
    end
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, response}}) do
    case YuurisanJSON.decode(response) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, %{"message" => message}} -> {:error, message}
      {:ok, _value} -> {:error, "HTTP #{status}"}
      {:error, _reason} -> {:error, "HTTP #{status}"}
    end
  end

  defp handle({:error, reason}), do: {:error, reason}

  defp random_key do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _other -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _other -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _other -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _other -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _other -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _other -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _other ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil
  defp proxy_for(proxies, index), do: Enum.at(proxies, rem(index, length(proxies)))

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp load_store do
    case File.read(Path.join(@root, @store)) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, %{} = store} -> store
          _other -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp save_store(store) do
    File.write(Path.join(@root, @store), YuurisanJSON.encode_pretty(store))
  end

  defp fetch_token(user_id) do
    case Map.get(load_store(), user_id) do
      %{"token" => token} = entry when is_binary(token) and token != "" ->
        %{token: token, expires_at: whole(Map.get(entry, "expires_at", 0), 0)}

      _other ->
        nil
    end
  end

  defp persist_token(init_data, token, expires_at) do
    with {:ok, profile, _username} <- identity_of(init_data),
         id when not is_nil(id) <- get(profile, "id") do
      key = "usr_" <> to_string(id)
      store = load_store()

      entry =
        case Map.get(store, key) do
          %{"token" => ^token} = existing -> existing
          _other -> %{}
        end

      entry =
        entry
        |> Map.put("token", token)
        |> Map.put("expires_at", expires_at)

      save_store(Map.put(store, key, entry))
    else
      _other -> :ok
    end
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _reason} -> default_settings()
        end

      {:error, _reason} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode_pretty(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _other -> 3600
    end
  end

  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp display_name(player, profile) do
    value = get(player, "name", "")

    cond do
      is_binary(value) and String.trim(value) != "" -> value
      true -> get(profile, "first_name", "account")
    end
  end

  defp balance_of(state), do: number(get(state, "balance", 0))

  defp clean_text(value, fallback) do
    text =
      value
      |> stringify()
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp short_reason(reason), do: shorten(clean_text(reason, "reason"), "reason", 26)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp stringify({:failed_connect, _reason}), do: "no network connection"
  defp stringify({:timeout, _reason}), do: "the request timed out"
  defp stringify({:failed_connect, _reason, _host}), do: "no network connection"
  defp stringify(value), do: inspect(value)

  defp whole(value, _fallback) when is_integer(value), do: value
  defp whole(value, _fallback) when is_float(value), do: trunc(value)
  defp whole(_value, fallback), do: fallback

  defp number(value) when is_integer(value), do: value
  defp number(value) when is_float(value), do: value
  defp number(_value), do: 0

  defp money(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp money(value), do: to_string(value)

  defp now_ms, do: System.system_time(:millisecond)

  defp remaining(nil), do: 0

  defp remaining(stamp) do
    case whole(stamp, 0) do
      0 -> 0
      millis -> max(div(millis, 1000) - System.system_time(:second), 0)
    end
  end

  defp identity(init_data) do
    with {:ok, profile, username} <- identity_of(init_data),
         id when not is_nil(id) <- get(profile, "id") do
      {:ok, "usr_" <> to_string(id), profile, username}
    else
      nil -> {:error, "user object missing"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "unreadable initData"}
    end
  end

  defp identity_of(init_data) do
    with {:ok, params} <- parse_query(init_data),
         raw when is_binary(raw) <- Map.get(params, "user"),
         {:ok, user} <- YuurisanJSON.decode(URI.decode_www_form(raw)),
         id when not is_nil(id) <- get(user, "id") do
      {:ok, user, to_string(get(user, "username", ""))}
    else
      nil -> {:error, "user object missing"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "unreadable initData"}
    end
  end

  defp parse_query(raw) do
    pairs =
      raw
      |> String.trim()
      |> String.split("&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    if Enum.any?(pairs, fn {key, _value} -> key == "hash" end) do
      {:ok, Map.new(pairs)}
    else
      {:error, "initData has no hash"}
    end
  end

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    for signal <- [:sigterm, :sighup, :sigquit] do
      try do
        System.trap_signal(signal, handler)
      rescue
        _error -> :ok
      end
    end
  end

  defp shorten(value, fallback, limit) do
    text = value |> to_string() |> String.trim()

    case String.slice(text, 0, limit) do
      "" -> fallback
      short -> String.trim(short)
    end
  end

  defp plural(count, word) do
    if count == 1, do: "#{count} #{word}", else: "#{count} #{pluralize(word)}"
  end

  defp pluralize(word) do
    cond do
      String.ends_with?(word, "y") -> String.slice(word, 0, String.length(word) - 1) <> "ies"
      true -> word <> "s"
    end
  end

  defp countdown(seconds, label) do
    left = max(trunc(seconds), 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

Diggominer.run()
