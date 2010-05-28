%% -------------------------------------------------------------------
%%
%% basho_bench: Benchmarking Suite
%%
%% Copyright (c) 2009-2010 Basho Techonologies
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(basho_bench_driver_http_raw).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

-record(url, {abspath, host, port, username, password, path, protocol}).

-record(state, { client_id,          % Tuple client ID for HTTP requests
                 base_urls,          % Tuple of #url -- one for each IP
                 base_urls_index,    % #url to use for next request
                 path_params }).     % Params to append on the path

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->
    %% Make sure ibrowse is available
    case code:which(ibrowse) of
        non_existing ->
            ?FAIL_MSG("~s requires ibrowse to be installed.\n", [?MODULE]);
        _ ->
            ok
    end,

    %% Setup client ID by base-64 encoding the ID
    ClientId = {'X-Riak-ClientId', base64:encode(<<Id:32/unsigned>>)},
    ?DEBUG("Client ID: ~p\n", [ClientId]),

    application:start(ibrowse),

    %% The IPs, port and path we'll be testing
    Ips  = basho_bench_config:get(http_raw_ips, ["127.0.0.1"]),
    Port = basho_bench_config:get(http_raw_port, 8098),
    Path = basho_bench_config:get(http_raw_path, "/riak/test"),
    Params = basho_bench_config:get(http_raw_params, ""),

    %% If there are multiple URLs, convert the list to a tuple so we can efficiently
    %% round-robin through them.
    case length(Ips) of
        1 ->
            [Ip] = Ips,
            BaseUrls = #url { host = Ip, port = Port, path = Path },
            BaseUrlsIndex = 1;
        _ ->
            BaseUrls = list_to_tuple([ #url { host = Ip, port = Port, path = Path }
                                       || Ip <- Ips]),
            BaseUrlsIndex = random:uniform(tuple_size(BaseUrls))
    end,

    {ok, #state { client_id = ClientId,
                  base_urls = BaseUrls,
                  base_urls_index = BaseUrlsIndex,
                  path_params = Params }}.


run(get, KeyGen, _ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    case do_get(url(NextUrl, KeyGen, State#state.path_params)) of
        {not_found, _Url} ->
            {ok, S2};
        {ok, _Url, _Headers} ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end;
run(update, KeyGen, ValueGen, State) ->
    {NextUrl, S2} = next_url(State),
    case do_get(url(NextUrl, KeyGen, State#state.path_params)) of
        {error, Reason} ->
            {error, Reason, S2};

        {not_found, Url} ->
            case do_put(Url, [], ValueGen) of
                ok ->
                    {ok, S2};
                {error, Reason} ->
                    {error, Reason, S2}
            end;

        {ok, Url, Headers} ->
            Vclock = lists:keyfind("X-Riak-Vclock", 1, Headers),
            case do_put(Url, [State#state.client_id, Vclock], ValueGen) of
                ok ->
                    {ok, S2};
                {error, Reason} ->
                    {error, Reason, S2}
            end
    end;
run(insert, KeyGen, ValueGen, State) ->
    %% Go ahead and evaluate the keygen so that we can use the
    %% sequential_int_gen to do a controlled # of inserts (if we desire). Note
    %% that the actual insert randomly generates a key (server-side), so the
    %% output of the keygen is ignored.
    KeyGen(),
    {NextUrl, S2} = next_url(State),
    case do_post(url(NextUrl, State#state.path_params), [], ValueGen) of
        ok ->
            {ok, S2};
        {error, Reason} ->
            {error, Reason, S2}
    end.



%% ====================================================================
%% Internal functions
%% ====================================================================

next_url(State) when is_record(State#state.base_urls, url) ->
    {State#state.base_urls, State};
next_url(State) when State#state.base_urls_index > tuple_size(State#state.base_urls) ->
    { element(1, State#state.base_urls),
      State#state { base_urls_index = 1 } };
next_url(State) ->
    { element(State#state.base_urls_index, State#state.base_urls),
      State#state { base_urls_index = State#state.base_urls_index + 1 }}.

url(BaseUrl, Params) ->
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, Params]) }.
url(BaseUrl, KeyGen, Params) ->
    BaseUrl#url { path = lists:concat([BaseUrl#url.path, '/', KeyGen(), Params]) }.


do_get(Url) ->
    case send_request(Url, [], get, [], [{response_format, binary}]) of
        {ok, "404", _Headers, _Body} ->
            {not_found, Url};
        {ok, "300", Headers, _Body} ->
            {ok, Url, Headers};
        {ok, "200", Headers, _Body} ->
            {ok, Url, Headers};
        {ok, Code, _Headers, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_put(Url, Headers, ValueGen) ->
    case send_request(Url, Headers ++ [{'Content-Type', 'application/octet-stream'}],
                      put, ValueGen(), [{response_format, binary}]) of
        {ok, "204", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

do_post(Url, Headers, ValueGen) ->
    case send_request(Url, Headers ++ [{'Content-Type', 'application/octet-stream'}],
                      post, ValueGen(), [{response_format, binary}]) of
        {ok, "201", _Header, _Body} ->
            ok;
        {ok, "204", _Header, _Body} ->
            ok;
        {ok, Code, _Header, _Body} ->
            {error, {http_error, Code}};
        {error, Reason} ->
            {error, Reason}
    end.


connect(Url) ->
    case erlang:get({ibrowse_pid, Url#url.host}) of
        undefined ->
            {ok, Pid} = ibrowse_http_client:start({Url#url.host, Url#url.port}),
            erlang:put({ibrowse_pid, Url#url.host}, Pid),
            Pid;
        Pid ->
            case is_process_alive(Pid) of
                true ->
                    Pid;
                false ->
                    erlang:erase({ibrowse_pid, Url#url.host}),
                    connect(Url)
            end
    end.


disconnect(Url) ->
    case erlang:get({ibrowse_pid, Url#url.host}) of
        undefined ->
            ok;
        OldPid ->
            catch(ibrowse_http_client:stop(OldPid))
    end,
    erlang:erase({ibrowse_pid, Url#url.host}),
    ok.


send_request(Url, Headers, Method, Body, Options) ->
    send_request(Url, Headers, Method, Body, Options, 3).

send_request(_Url, _Headers, _Method, _Body, _Options, 0) ->
    {error, max_retries};
send_request(Url, Headers, Method, Body, Options, Count) ->
    Pid = connect(Url),
    case catch(ibrowse_http_client:send_req(Pid, Url, Headers, Method, Body, Options, 5000)) of
        {ok, Status, RespHeaders, RespBody} ->
            {ok, Status, RespHeaders, RespBody};

        Error ->
            disconnect(Url),
            case should_retry(Error) of
                true ->
                    send_request(Url, Headers, Method, Body, Options, Count-1);

                false ->
                    normalize_error(Method, Error)
            end
    end.


should_retry({error, send_failed})       -> true;
should_retry({error, connection_closed}) -> true;
should_retry({'EXIT', {normal, _}})      -> true;
should_retry({'EXIT', {noproc, _}})      -> true;
should_retry(_)                          -> false.

normalize_error(Method, {'EXIT', {timeout, _}})  -> {error, {Method, timeout}};
normalize_error(Method, {'EXIT', Reason})        -> {error, {Method, 'EXIT', Reason}};
normalize_error(Method, {error, Reason})         -> {error, {Method, Reason}}.