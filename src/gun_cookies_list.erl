%% Copyright (c) 2020, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% A reference cookie store implemented as a list of cookies.
%% This cookie store cannot be shared between connections.
-module(gun_cookies_list).

-export([init/0]).
-export([query/2]).
-export([set_cookie_secure_match/2]).
-export([set_cookie_take_exact_match/2]).
-export([store/2]).

-type state() :: #{
	cookies := [gun_cookies:cookie()]
	%% @todo Options would go here.
}.

-spec init() -> {?MODULE, state()}.
init() ->
	{?MODULE, #{cookies => []}}.

-spec query(State, uri_string:uri_map())
	-> {ok, [{binary(), binary()}], State}
	when State::state().
query(State=#{cookies := Cookies}, URI) ->
	CurrentTime = erlang:universaltime(),
	query(State, URI, Cookies, CurrentTime, [], []).

query(State, _, [], _, CookieList, Cookies) ->
	{ok, CookieList, State#{cookies => Cookies}};
query(State, URI=#{scheme := Scheme, host := Host, path := Path},
		[Cookie|Tail], CurrentTime, CookieList, Acc) ->
	%% @todo This is probably not correct, says "canonicalized request-host"
	%% and currently doesn't include the port number, it probably should?
	Match0 = case Cookie of
		#{host_only := true, domain := Host} ->
			true;
		#{host_only := false, domain := Domain} ->
			gun_cookies:domain_match(Host, Domain);
		_ ->
			false
	end,
	Match1 = Match0 andalso
		gun_cookies:path_match(Path, maps:get(path, Cookie)),
	Match = Match1 andalso
		case {Cookie, Scheme} of
			{#{secure_only := true}, <<"https">>} -> true;
			{#{secure_only := false}, _} -> true;
			_ -> false
		end,
	%% @todo This is where we would check the http_only flag should
	%% we want to implement a non-HTTP interface.
	%% @todo This is where we would check for same-site/cross-site.
	case Match of
		true ->
			UpdatedCookie = Cookie#{last_access_time => CurrentTime},
			query(State, URI, Tail, CurrentTime,
				[UpdatedCookie|CookieList],
				[UpdatedCookie|Acc]);
		false ->
			query(State, URI, Tail, CurrentTime, CookieList, [Cookie|Acc])
	end.

-spec set_cookie_secure_match(state(), #{
	name := binary(),
%	secure_only := true,
	domain := binary(),
	path := binary()
}) -> match | nomatch.
set_cookie_secure_match(#{cookies := Cookies},
		#{name := Name, domain := Domain, path := Path}) ->
	Result = [Cookie || Cookie=#{name := CookieName, secure_only := true} <- Cookies,
		CookieName =:= Name,
		gun_cookies:domain_match(Domain, maps:get(domain, Cookie))
			orelse gun_cookies:domain_match(maps:get(domain, Cookie), Domain),
		gun_cookies:path_match(Path, maps:get(path, Cookie))],
	case Result of
		[] -> nomatch;
		_ -> match
	end.

-spec set_cookie_take_exact_match(State, #{
	name := binary(),
	domain := binary(),
	host_only := boolean(),
	path := binary()
}) -> {ok, gun_cookies:cookie(), State} | error when State::state().
set_cookie_take_exact_match(State=#{cookies := Cookies0}, Match) ->
	Result = [Cookie || Cookie <- Cookies0,
		Match =:= maps:with([name, domain, host_only, path], Cookie)],
	Cookies = [Cookie || Cookie <- Cookies0,
		Match =/= maps:with([name, domain, host_only, path], Cookie)],
	case Result of
		[] -> error;
		[Cookie] -> {ok, Cookie, State#{cookies => Cookies}}
	end.

-spec store(State, gun_cookies:cookie())
	-> {ok, State} | {error, any()}
	when State::state().
store(State=#{cookies := Cookies}, NewCookie=#{expiry_time := ExpiryTime}) ->
	CurrentTime = erlang:universaltime(),
	if
		%% Do not store cookies with an expiry time in the past.
		ExpiryTime =/= infinity, CurrentTime >= ExpiryTime ->
			{ok, State};
		true ->
			{ok, State#{cookies => [NewCookie|Cookies]}}
	end.
