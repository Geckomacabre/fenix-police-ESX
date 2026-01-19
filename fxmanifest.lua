fx_version 'cerulean'
game 'gta5'

author 'Fenix'
description 'Police'
version '1.0.0'

-- IMPORTANT: config MUST load first so Config table exists everywhere
shared_scripts {
    'config.lua'
}

client_scripts {
    '@es_extended/locale.lua',     -- Support ESX Legacy (only loads if ESX is started before)
    '@qb-core/shared/locale.lua',  -- Support QBCore (only loads if QBCore is started)
    'client/client.lua'
}

server_scripts {
    'server/server.lua'
}

-- Optional: enable this if you use lua 5.4 features
-- lua54 'yes'
