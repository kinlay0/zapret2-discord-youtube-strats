@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"
call service.bat load_game_filter
echo:

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
set "LUA=%~dp0lua\"
cd /d %BIN%

start "zapret: %~n0" /min "%BIN%winws2.exe" --wf-tcp-empty=0 --ctrack-disable=0 ^
--wf-tcp-in=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-in=443,19294-19344,50000-50100,%GameFilterUDP% ^
--wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,19294-19344,50000-50100,%GameFilterUDP% ^

--lua-init=@"%LUA%zapret-lib.lua" ^
--lua-init=@"%LUA%zapret-antidpi.lua" ^
--lua-init=@"%LUA%zapret-auto.lua" ^

--blob=tls_google:@"%BIN%tls_clienthello_www_google_com.bin" ^
--blob=tls_onetrust:@"%BIN%tls_clienthello_max_ru.bin" ^
--blob=quic_google:@"%BIN%quic_initial_www_google_com.bin" ^
--blob=quic_dbankcloud:@"%BIN%quic_initial_dbankcloud_ru.bin" ^
--blob=stun:@"%BIN%stun.bin" ^
--blob=tls_4pda:@"%BIN%tls_clienthello_4pda_to.bin" ^
--blob=quic_4pda:@"%BIN%quic_initial_4pda.to.bin" ^
--blob=quic_steam:@"%BIN%quic_initial_steamcommunity_com.bin" ^
--blob=quic_tencent:@"%BIN%quic_initial_tencent_com.bin" ^
--blob=stun2:@"%BIN%stun2.bin" ^
--blob=rutube:@"%BIN%quic_initial_rutube_ru.bin" ^
--blob=active_discord:@"%BIN%ACTIVE_DISCORD_UDP.bin" ^
--blob=active_game:@"%BIN%ACTIVE_GAME_UDP.bin" ^

--name="domain quic" ^
--filter-udp=443 ^
--hostlist="%LISTS%list-general.txt" ^
--hostlist="%LISTS%list-general-user.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=quic_initial ^
--lua-desync=fake:blob=quic_google:repeats=6 ^
--new ^

--name="discord voice" ^
--filter-udp=19294-19344,50000-50100 ^
--filter-l7=discord,stun ^
--payload=discord_ip_discovery,stun ^
--lua-desync=fake:blob=rutube:repeats=6 ^
--new ^

--name="discord media" ^
--filter-tcp=2053,2083,2087,2096,8443 ^
--hostlist-domains=discord.media ^
--lua-desync=fake:blob=tls_google:repeats=6:tcp_ts=-600000 ^
--lua-desync=fakedsplit:pattern=0x00:repeats=6:tcp_ts=-600000 ^
--new ^

--name="youtube" ^
--filter-tcp=443 ^
--hostlist="%LISTS%list-google.txt" ^
--payload=tls_client_hello ^
--lua-desync=multidisorder:pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1 ^
--new ^

--name="domain tls" ^
--filter-tcp=80,443 ^
--hostlist="%LISTS%list-general.txt" ^
--hostlist="%LISTS%list-general-user.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=tls_onetrust:tls_mod=rnd,dupsid,sni=4pda.to:repeats=6:tcp_ts=-600000 ^
--payload=http_req ^
--lua-desync=fake:blob=tls_onetrust:repeats=6:tcp_ts=-600000 ^
--new ^

--name="ip quic" ^
--filter-udp=443 ^
--ipset="%LISTS%ipset-all.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=quic_initial ^
--lua-desync=fake:blob=quic_google:repeats=6 ^
--new ^

--name="ip tls" ^
--filter-tcp=80,443,8443 ^
--ipset="%LISTS%ipset-all.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=tls_onetrust:tls_mod=rnd,dupsid,sni=4pda.to:repeats=6:tcp_ts=-600000 ^
--payload=http_req ^
--lua-desync=fake:blob=tls_onetrust:repeats=6:tcp_ts=-600000 ^
--new ^

--name="gamefilterTCP" ^
--filter-tcp=%GameFilterTCP% ^
--ipset="%LISTS%ipset-all.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-n5 ^
--payload=tls_client_hello,unknown ^
--lua-desync=fake:blob=tls_onetrust:tls_mod=rnd:repeats=6:tcp_ts=-600000:payload=tls_client_hello,unknown ^
--payload=http_req ^
--lua-desync=fake:blob=tls_onetrust:repeats=6:tcp_ts=-600000 ^
--new ^

--name="gamefilterUDP" ^
--filter-udp=%GameFilterUDP% ^
--ipset="%LISTS%ipset-all.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-n4 ^
--payload=all ^
--lua-desync=fake:blob=quic_dbankcloud:repeats=4:payload=all ^