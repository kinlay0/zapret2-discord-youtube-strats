local log = DLOG or print
local count = 0

local function load(file)
	local path = file
	local f = io.open(path, "rb")
	if not f then
		path = "bin/" .. file
		f = io.open(path, "rb")
	end
	if not f then
		error("blobs.lua: cannot find " .. file .. " (inside bin folder)", 0)
	end
	local data = f:read("*a")
	f:close()
	return data, path
end

-- шаблон
for name, file in pairs{
	tls_google      = "tls_clienthello_www_google_com.bin",
	tls_onetrust    = "tls_clienthello_max_ru.bin",
	tls_4pda        = "tls_clienthello_4pda_to.bin",
	tls_5ka         = "tls_clienthello_5ka_ru.bin",
	quic_5ka        = "quic_initial_5ka_ru.bin",
	quic_google     = "quic_initial_www_google_com.bin",
	quic_dbankcloud = "quic_initial_dbankcloud_ru.bin",
	quic_4pda       = "quic_initial_4pda.to.bin",
	quic_steam      = "quic_initial_steamcommunity_com.bin",
	quic_tencent    = "quic_initial_tencent_com.bin",
	quic_rutube     = "quic_initial_rutube_ru.bin",
	stun            = "stun.bin",
	stun2           = "stun2.bin",
	active_discord  = "ACTIVE_DISCORD_UDP.bin",
	active_game     = "ACTIVE_GAME_UDP.bin",
} do
	local data, path = load(file)
	_G[name] = data
	count = count + 1
	log(string.format("blobs.lua: %s = %s (%d bytes)", name, path, #data))
end

log(string.format("blobs.lua: %d blobs loaded", count))
