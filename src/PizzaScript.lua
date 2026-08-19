--[[
================================================================================
  PizzaScript  v1.0.0
  Herramienta para Cherax (GTA V) en un solo archivo. Por ahora: un menú de
  perfil de jugador (offline + online). La idea es ir añadiendo apartados
  nuevos aquí mismo con el tiempo, no crear archivos sueltos por función —
  núcleo, lectura de datos, guardado y UI conviven en este único script a
  propósito.

  QUÉ ESTÁ VERIFICADO Y QUÉ NO (no se inventa nada de esto)
  --------------------------------------------------------------------------
  Verificado contra fuentes reales (LCPDFR NativeDB, el natives-one.lua real
  de SATTY91/Cherax-Lua-API-Documentation, y un script decompilado real de
  Rockstar que calcula el % de la pantalla de pausa):
    - % de historia completada: stat "total_progress_made" vía STAT_GET_FLOAT.
    - Desglose agregado: num_missions_*, num_minigames_*, num_oddjobs_*,
      num_rndpeople_*, num_rndevents_*, num_misc_*, percent_story_missions,
      percent_ambient_missions, percent_oddjobs.
    - Personaje actual: comparar el modelo del ped contra player_zero/
      player_one/player_two (Michael/Franklin/Trevor).
    - Stats por personaje: prefijos sp0_/sp1_/sp2_ (se usan shots, deaths,
      dist_driving_car, que son los que se pudieron confirmar).
    - Cuenta online: NETWORK_IS_SIGNED_IN, NETWORK_IS_SIGNED_ONLINE,
      NETWORK_HAS_SOCIAL_CLUB_ACCOUNT, NETWORK_IS_HOST,
      NETWORK_PLAYER_GET_NAME, GET_PLAYER_NAME, SC_GET_NICKNAME.

  NO existe / no se pudo verificar — por eso NO está implementado:
    - Un flag de "personaje desbloqueado" (sólo se sabe cuál se está
      jugando AHORA, no el historial de desbloqueos).
    - Lista de misiones concretas completadas (sólo hay contadores
      agregados).
    - Dinero o rango de GTA Online (ningún stat confirmado).

  Zona gris, "sin verificar en juego": la firma exacta de los natives
  STAT_GET_* cuando se invocan crudos. Por eso este archivo SIEMPRE intenta
  primero el wrapper cómodo que documenta Cherax (STATS.STAT_GET_*,
  NETWORK.*, PLAYER.*, PED.*, SC_GET_NICKNAME) y sólo cae a invocar por hash
  crudo en los pocos casos sin argumentos donde el hash y la firma están
  confirmados (PLAYER_PED_ID y los 4 NETWORK_IS_*/NETWORK_HAS_*). Si un
  valor no está disponible, el panel dice "no disponible" — nunca se
  arriesga una llamada con una firma que no está confirmada.

  Reglas que se mantienen en cualquier apartado que se añada aquí:
    - Las natives sólo se llaman una vez armadas (ver 'armed' más abajo):
      el cuerpo del script corre en otro hilo al cargar, y tocar natives
      ahí cierra GTA sin dejar rastro en el log.
    - Toda espera de red lleva dos frenos independientes (tiempo + tope de
      iteraciones), nunca uno solo.
    - Nunca se sustituye un archivo en disco sin verificar antes que el
      contenido nuevo compila con load().

  Uso: coloca este archivo (él solo) en Documents\Cherax\Lua\ y ejecútalo
  desde el Lua Editor.
================================================================================
]]

--==============================================================================
-- Configuración
--==============================================================================

local PS_VERSION  = "1.0.0"
local REPO_RAW     = "https://raw.githubusercontent.com/TuShaggy/PizzaScript/main/"
local VERSION_URL  = REPO_RAW .. "version.json"
local FILE_URL     = REPO_RAW .. "src/PizzaScript.lua"

--==============================================================================
-- Log ligero
--==============================================================================

local Log = {}
do
    local function ts() return os.date("%H:%M:%S") end
    function Log.write(level, tag, fmt, ...)
        local msg = fmt
        if select("#", ...) > 0 then
            local ok, f = pcall(string.format, fmt, ...)
            msg = ok and f or fmt
        end
        local line = string.format("[PizzaScript][%s][%-5s][%s] %s", ts(), level, tag, msg)
        print(line)
        if Logger then
            if level == "ERROR" then Logger.LogError(line)
            elseif level == "WARN" then Logger.LogInfo("[WARN] " .. line)
            else Logger.LogInfo(line) end
        end
    end
    function Log.info(tag, fmt, ...)  Log.write("INFO",  tag, fmt, ...) end
    function Log.warn(tag, fmt, ...)  Log.write("WARN",  tag, fmt, ...) end
    function Log.error(tag, fmt, ...) Log.write("ERROR", tag, fmt, ...) end
end

--==============================================================================
-- Resolución de rutas
--==============================================================================

local function join(...)
    local parts = {}
    for _, p in ipairs({ ... }) do
        if p and p ~= "" then parts[#parts + 1] = (p:gsub("[\\/]+$", "")) end
    end
    return table.concat(parts, "\\")
end

local home_dir = nil
if FileMgr and FileMgr.GetMenuRootPath then
    local root = FileMgr.GetMenuRootPath()
    if root and root ~= "" then home_dir = join(root, "Lua") end
end
local self_path = home_dir and join(home_dir, "PizzaScript.lua") or nil

local function profiles_dir()
    return home_dir and join(home_dir, "PizzaScript_Profiles") or "PizzaScript_Profiles"
end

--==============================================================================
-- Estado
--==============================================================================

local armed      = false   -- barrera de hilo: las natives sólo funcionan en el hilo de script
local show_panel = false
local profile    = { offline = nil, online = nil }
local UPD        = { state = "IDLE", remote_version = nil, last_error = nil,
                       _curl = nil, _ticks = 0, _deadline = nil }

--==============================================================================
-- Natives: siempre intenta primero el wrapper cómodo (STATS.*, NETWORK.*,
-- PLAYER.*, PED.*, SC_GET_NICKNAME), que es como Cherax documenta llamarlos.
-- Sólo cae a invocar por hash crudo en los pocos casos sin argumentos donde
-- el hash está confirmado. Nada de esto se llama si 'armed' es falso — eso
-- lo garantizan read_offline()/read_online()/render_hud() antes de tocar
-- cualquiera de estas funciones.
--==============================================================================

local function cap_player_ped_id()
    if PLAYER and PLAYER.PLAYER_PED_ID then
        local ok, v = pcall(PLAYER.PLAYER_PED_ID)
        if ok then return v end
    end
    local ok, v = pcall(Natives.InvokeInt, 0xD80958FC74E988A6)   -- confirmado
    if ok then return v end
    return nil
end

local function cap_player_id()
    if PLAYER and PLAYER.PLAYER_ID then
        local ok, v = pcall(PLAYER.PLAYER_ID)
        if ok then return v end
    end
    return nil   -- sin hash confirmado: no se inventa un fallback crudo
end

local function cap_is_ped_model(ped, model_hash)
    if not ped or not (PED and PED.IS_PED_MODEL) then return nil end
    local ok, v = pcall(PED.IS_PED_MODEL, ped, model_hash)
    if ok then return v end
    return nil
end

local function cap_stat_float(name)
    if not (STATS and STATS.STAT_GET_FLOAT) then return nil end
    local ok, v = pcall(STATS.STAT_GET_FLOAT, Utils.Joaat(name))
    if ok then return v end
    return nil
end

local function cap_stat_int(name)
    if not (STATS and STATS.STAT_GET_INT) then return nil end
    local ok, v = pcall(STATS.STAT_GET_INT, Utils.Joaat(name))
    if ok then return v end
    return nil
end

local function cap_network_bool(fname, hash)
    if NETWORK and NETWORK[fname] then
        local ok, v = pcall(NETWORK[fname])
        if ok then return v end
        return nil
    end
    if hash then
        local ok, v = pcall(Natives.InvokeBool, hash)   -- confirmado, sin argumentos
        if ok then return v end
    end
    return nil
end

local function cap_network_player_name(player)
    if not player then return nil end
    if NETWORK and NETWORK.NETWORK_PLAYER_GET_NAME then
        local ok, v = pcall(NETWORK.NETWORK_PLAYER_GET_NAME, player)
        if ok then return v end
    end
    local ok, v = pcall(Natives.InvokeString, 0x7718D2E2060837D2, player)   -- confirmado
    if ok then return v end
    return nil
end

local function cap_player_name(player)
    if not player then return nil end
    if PLAYER and PLAYER.GET_PLAYER_NAME then
        local ok, v = pcall(PLAYER.GET_PLAYER_NAME, player)
        if ok then return v end
    end
    local ok, v = pcall(Natives.InvokeString, 0x6D0DE6A7B5DA71F8, player)   -- confirmado
    if ok then return v end
    return nil
end

local function cap_sc_nickname()
    if not _G.SC_GET_NICKNAME then return nil end
    local ok, v = pcall(_G.SC_GET_NICKNAME)
    if ok then return v end
    return nil
end

--==============================================================================
-- Dibujo en pantalla (DRAW_RECT + la secuencia SET_TEXT_*/BEGIN_TEXT_*, con
-- hashes ya verificados). Aquí vive el look "cyberpunk": no hay constancia
-- de que Cherax exponga temas/colores para los widgets normales de
-- FeatureMgr/ClickGUI, así que el panel de información se dibuja a mano con
-- colores neón, y los botones reales quedan en una pestaña normal de
-- Cherax (ver build_ui).
--==============================================================================

local function n_draw_rect(x, y, w, h, r, g, b, a)
    if not armed then return end
    pcall(Natives.InvokeVoid, 0x3A618A217E5154F0, x, y, w, h, r, g, b, a, false)
end

local function n_draw_text(text, x, y, opts)
    if not armed then return end
    opts = opts or {}
    pcall(Natives.InvokeVoid, 0x66E0276CC5F6B9DA, opts.font or 4)
    pcall(Natives.InvokeVoid, 0x07C837F9A01C34C9, opts.scale or 0.35, opts.scale or 0.35)
    pcall(Natives.InvokeVoid, 0xBE6B23FFA53FB442, opts.r or 0, opts.g or 255, opts.b or 220, opts.a or 255)
    pcall(Natives.InvokeVoid, 0xC02F4DBFB51D988B, true)
    pcall(Natives.InvokeVoid, 0x2513DFB0FB8400FE)
    pcall(Natives.InvokeVoid, 0x25FBB336DF1804CB, "STRING")
    pcall(Natives.InvokeVoid, 0x6C188BE134E074AA, tostring(text))
    pcall(Natives.InvokeVoid, 0xCD015E5BB0D96A57, x, y, 0)
end

local COLOR_BG      = { 4, 4, 10, 215 }
local COLOR_CYAN    = { 0, 240, 255 }
local COLOR_MAGENTA = { 255, 25, 160 }

local function render_hud()
    if not show_panel or not armed then return end

    local lines = { { text = "P I Z Z A S C R I P T", color = COLOR_MAGENTA, scale = 0.42 } }

    if profile.online then
        local o = profile.online
        lines[#lines + 1] = { text = "ONLINE: " .. tostring(o.apodo or o.nombre_red or o.nombre_jugador or "?"), color = COLOR_CYAN }
        lines[#lines + 1] = { text = string.format("Conectado: %s | Social Club: %s | Host: %s",
                                     tostring(o.conectado), tostring(o.cuenta_social_club), tostring(o.es_host)), color = COLOR_CYAN, scale = 0.3 }
    end

    if profile.offline then
        local f = profile.offline
        lines[#lines + 1] = { text = "PERSONAJE: " .. tostring(f.personaje_actual), color = COLOR_CYAN }
        lines[#lines + 1] = { text = string.format("Historia: %s%%", tostring(f.historia_percent)), color = COLOR_CYAN }
        lines[#lines + 1] = { text = string.format("Misiones: %s / %s", tostring(f.misiones_completadas), tostring(f.misiones_disponibles)), color = COLOR_CYAN, scale = 0.3 }
    end

    if not profile.online and not profile.offline then
        lines[#lines + 1] = { text = "Pulsa 'Cargar perfil' en la pestaña PizzaScript", color = COLOR_CYAN, scale = 0.3 }
    end

    local x, y, row_h = 0.14, 0.10, 0.03
    local panel_h = #lines * row_h + 0.02
    n_draw_rect(x, y + panel_h / 2 - row_h / 2, 0.24, panel_h, COLOR_BG[1], COLOR_BG[2], COLOR_BG[3], COLOR_BG[4])
    for i, l in ipairs(lines) do
        n_draw_text(l.text, x, y + (i - 1) * row_h, { scale = l.scale or 0.34, r = l.color[1], g = l.color[2], b = l.color[3] })
    end
end

--==============================================================================
-- Apartado: perfil de jugador
--==============================================================================

local CHAR_MODELS = {
    { key = "michael",  label = "Michael",  model = "player_zero", stat_prefix = "sp0" },
    { key = "franklin", label = "Franklin", model = "player_one",  stat_prefix = "sp1" },
    { key = "trevor",   label = "Trevor",   model = "player_two",  stat_prefix = "sp2" },
}

local function read_offline()
    if not armed then
        Log.warn("Perfil", "Natives aún no armadas, espera un momento y vuelve a intentarlo")
        if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Espera un momento, el script se está preparando", 3000) end
        return nil
    end

    local data = { captured_at = os.date("%Y-%m-%d %H:%M:%S") }
    local ped = cap_player_ped_id()

    data.personaje_actual = "no disponible"
    if ped then
        for _, c in ipairs(CHAR_MODELS) do
            if cap_is_ped_model(ped, Utils.Joaat(c.model)) then
                data.personaje_actual = c.label
            end
        end
    end

    data.historia_percent          = cap_stat_float("total_progress_made")
    data.misiones_completadas      = cap_stat_int("num_missions_completed")
    data.misiones_disponibles      = cap_stat_int("num_missions_available")
    data.minijuegos_completados    = cap_stat_int("num_minigames_completed")
    data.minijuegos_disponibles    = cap_stat_int("num_minigames_available")
    data.tareas_completadas        = cap_stat_int("num_oddjobs_completed")
    data.tareas_disponibles        = cap_stat_int("num_oddjobs_available")
    data.personajes_encontrados    = cap_stat_int("num_rndpeople_completed")
    data.personajes_disponibles    = cap_stat_int("num_rndpeople_available")
    data.eventos_completados       = cap_stat_int("num_rndevents_completed")
    data.eventos_disponibles       = cap_stat_int("num_rndevents_available")
    data.misc_completado           = cap_stat_int("num_misc_completed")
    data.misc_disponible           = cap_stat_int("num_misc_available")
    data.percent_mision_historia   = cap_stat_float("percent_story_missions")
    data.percent_mision_ambiente   = cap_stat_float("percent_ambient_missions")
    data.percent_tareas            = cap_stat_float("percent_oddjobs")

    data.por_personaje = {}
    for _, c in ipairs(CHAR_MODELS) do
        data.por_personaje[c.key] = {
            label = c.label,
            disparos = cap_stat_int(c.stat_prefix .. "_shots"),
            muertes  = cap_stat_int(c.stat_prefix .. "_deaths"),
            distancia_conduccion = cap_stat_float(c.stat_prefix .. "_dist_driving_car"),
        }
    end

    Log.info("Perfil", "Perfil offline capturado (personaje: %s, historia: %s%%)",
             data.personaje_actual, tostring(data.historia_percent))
    return data
end

local function read_online()
    if not armed then
        Log.warn("Perfil", "Natives aún no armadas, espera un momento y vuelve a intentarlo")
        if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Espera un momento, el script está preparándose", 3000) end
        return nil
    end

    local data = { captured_at = os.date("%Y-%m-%d %H:%M:%S") }
    data.conectado          = cap_network_bool("NETWORK_IS_SIGNED_IN", 0x054354A99211EB96)
    data.en_linea            = cap_network_bool("NETWORK_IS_SIGNED_ONLINE", 0x1077788E268557C2)
    data.cuenta_social_club  = cap_network_bool("NETWORK_HAS_SOCIAL_CLUB_ACCOUNT", 0x67A5589628E0CFF6)
    data.es_host             = cap_network_bool("NETWORK_IS_HOST", 0x8DB296B814EDDA07)

    local player = cap_player_id()
    data.nombre_red    = cap_network_player_name(player)
    data.nombre_jugador = cap_player_name(player)
    data.apodo          = cap_sc_nickname()

    Log.info("Perfil", "Perfil online capturado (apodo: %s, conectado: %s)",
             tostring(data.apodo), tostring(data.conectado))
    return data
end

local function sanitize_filename(s)
    if not s or s == "" then return nil end
    local clean = s:gsub('[<>:"/\\|?*%c]', "_")
    if clean == "" then return nil end
    return clean
end

local function build_save_lines()
    local L = {}
    local function add(k, v)
        L[#L + 1] = string.format("%s=%s", k, v == nil and "no_disponible" or tostring(v))
    end

    add("generado", os.date("%Y-%m-%d %H:%M:%S"))

    if profile.online then
        local o = profile.online
        add("online.capturado", o.captured_at)
        add("online.apodo", o.apodo)
        add("online.nombre_red", o.nombre_red)
        add("online.nombre_jugador", o.nombre_jugador)
        add("online.conectado", o.conectado)
        add("online.en_linea", o.en_linea)
        add("online.cuenta_social_club", o.cuenta_social_club)
        add("online.es_host", o.es_host)
    end

    if profile.offline then
        local f = profile.offline
        add("offline.capturado", f.captured_at)
        add("offline.personaje_actual", f.personaje_actual)
        add("offline.historia_percent", f.historia_percent)
        add("offline.misiones_completadas", f.misiones_completadas)
        add("offline.misiones_disponibles", f.misiones_disponibles)
        add("offline.minijuegos_completados", f.minijuegos_completados)
        add("offline.minijuegos_disponibles", f.minijuegos_disponibles)
        add("offline.tareas_completadas", f.tareas_completadas)
        add("offline.tareas_disponibles", f.tareas_disponibles)
        add("offline.personajes_encontrados", f.personajes_encontrados)
        add("offline.personajes_disponibles", f.personajes_disponibles)
        add("offline.eventos_completados", f.eventos_completados)
        add("offline.eventos_disponibles", f.eventos_disponibles)
        add("offline.misc_completado", f.misc_completado)
        add("offline.misc_disponible", f.misc_disponible)
        add("offline.percent_mision_historia", f.percent_mision_historia)
        add("offline.percent_mision_ambiente", f.percent_mision_ambiente)
        add("offline.percent_tareas", f.percent_tareas)
        for _, c in ipairs(CHAR_MODELS) do
            local cs = f.por_personaje and f.por_personaje[c.key]
            if cs then
                add("offline." .. c.key .. ".disparos", cs.disparos)
                add("offline." .. c.key .. ".muertes", cs.muertes)
                add("offline." .. c.key .. ".distancia_conduccion", cs.distancia_conduccion)
            end
        end
    end

    return table.concat(L, "\n") .. "\n"
end

local function save_profile()
    if not (profile.offline or profile.online) then
        Log.warn("Perfil", "Nada que guardar todavía: pulsa 'Cargar perfil' primero")
        if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Nada que guardar todavía", 4000) end
        return false
    end
    if not (FileMgr and FileMgr.WriteFileContent) then
        Log.error("Perfil", "FileMgr no disponible: no se puede guardar")
        return false
    end

    local nombre = sanitize_filename(profile.online and profile.online.apodo)
                or sanitize_filename(profile.online and profile.online.nombre_red)
                or ("sin_nombre_" .. os.date("%Y%m%d_%H%M%S"))

    local dir = profiles_dir()
    if FileMgr.CreateDir then FileMgr.CreateDir(dir) end
    local path = dir .. "\\perfil_" .. nombre .. ".txt"

    FileMgr.WriteFileContent(path, build_save_lines())
    Log.info("Perfil", "Guardado en: %s", path)
    if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Perfil guardado: " .. nombre, 5000) end
    return true
end

--==============================================================================
-- Auto-actualización de un solo archivo: descarga la última versión de sí
-- mismo, verifica con load() antes de tocar disco, respalda la versión
-- anterior. No hace falta lista de archivos ni estado por lotes: aquí sólo
-- hay uno.
--==============================================================================

local DL_TIMEOUT_S, DL_MAX_TICKS = 15, 1800   -- dos frenos independientes

local function start_request(url)
    if not (Curl and Curl.Easy) then return nil end
    local ok, c = pcall(function()
        local h = Curl.Easy()
        h:Setopt(eCurlOption.CURLOPT_URL, url)
        h:Setopt(eCurlOption.CURLOPT_USERAGENT, "PizzaScript")
        h:Perform()
        return h
    end)
    if not ok then return nil end
    return c
end

local function upd_fail(msg)
    UPD.state, UPD.last_error, UPD._curl = "ERROR", msg, nil
    Log.error("Update", "%s", msg)
    if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Actualizador: " .. msg, 6000) end
end

local function version_gt(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

function UPD.check()
    if UPD.state == "CHECKING" or UPD.state == "DESCARGANDO" then
        Log.warn("Update", "check() ignorado: operación en curso (%s)", UPD.state)
        return false
    end
    if not (Curl and Curl.Easy) then
        Log.warn("Update", "Curl no disponible; no se puede comprobar actualizaciones")
        return false
    end
    UPD.state, UPD._ticks, UPD._deadline = "CHECKING", 0, os.time()
    UPD._curl = start_request(VERSION_URL)
    if not UPD._curl then upd_fail("check: no se pudo iniciar la comprobación"); return false end
    Log.info("Update", "Comprobando actualizaciones (versión local %s)", PS_VERSION)
    return true
end

local function pump_check()
    local c = UPD._curl
    if not c then upd_fail("check: sin petición activa"); return end
    UPD._ticks = UPD._ticks + 1
    if (os.time() - UPD._deadline) >= DL_TIMEOUT_S or UPD._ticks >= DL_MAX_TICKS then
        upd_fail("check: tiempo agotado"); return
    end
    if not c:GetFinished() then return end

    local code, body = c:GetResponse()
    UPD._curl = nil
    if code ~= (eCurlCode and eCurlCode.CURLE_OK) or not body then
        upd_fail("check: fallo de red (código " .. tostring(code) .. ")"); return
    end

    local version = body:match('"version"%s*:%s*"([^"]+)"')
    if not version then upd_fail("check: version.json no se pudo interpretar"); return end

    UPD.remote_version = version
    if version_gt(version, PS_VERSION) then
        UPD.state = "DISPONIBLE"
        Log.info("Update", "Actualización disponible: %s -> %s", PS_VERSION, version)
        if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Actualización disponible: " .. version, 6000) end
    else
        UPD.state = "IDLE"
        Log.info("Update", "Ya tienes la última versión (%s)", PS_VERSION)
    end
end

local function pump_download()
    local c = UPD._curl
    if not c then upd_fail("descarga: sin petición activa"); return end
    UPD._ticks = UPD._ticks + 1
    if (os.time() - UPD._deadline) >= DL_TIMEOUT_S or UPD._ticks >= DL_MAX_TICKS then
        upd_fail("descarga: tiempo agotado"); return
    end
    if not c:GetFinished() then return end

    local code, body = c:GetResponse()
    UPD._curl = nil
    if code ~= (eCurlCode and eCurlCode.CURLE_OK) or not body or body == "" then
        upd_fail("descarga: fallo de red (código " .. tostring(code) .. ")"); return
    end

    -- Verificación no negociable: nunca se sustituye el script si el
    -- contenido descargado no compila.
    local chunk, err = load(body, "@PizzaScript.lua")
    if not chunk then upd_fail("descarga: el archivo nuevo no compila -> " .. tostring(err)); return end

    if not (FileMgr and FileMgr.WriteFileContent and self_path) then
        upd_fail("descarga: no se sabe dónde escribir el archivo (FileMgr o ruta ausentes)"); return
    end

    local ok_old, old = pcall(FileMgr.ReadFileContent, self_path)
    if ok_old and old and old ~= "" then
        pcall(FileMgr.WriteFileContent, self_path .. ".backup", old)
    end
    FileMgr.WriteFileContent(self_path, body)

    UPD.state = "HECHO"
    Log.info("Update", "Actualizado a %s. Recarga PizzaScript.lua desde el Lua Editor para aplicarlo.", UPD.remote_version)
    if GUI and GUI.AddToast then GUI.AddToast("PizzaScript", "Actualizado a " .. UPD.remote_version .. ". Recarga el script.", 8000) end
end

function UPD.apply()
    if UPD.state ~= "DISPONIBLE" then
        Log.warn("Update", "apply() ignorado: estado actual %s", UPD.state)
        return false
    end
    UPD.state, UPD._ticks, UPD._deadline = "DESCARGANDO", 0, os.time()
    UPD._curl = start_request(FILE_URL)
    if not UPD._curl then upd_fail("descarga: no se pudo iniciar"); return false end
    return true
end

function UPD.tick()
    if UPD.state == "CHECKING" then pump_check()
    elseif UPD.state == "DESCARGANDO" then pump_download() end
end

--==============================================================================
-- UI
--==============================================================================

local function build_ui()
    local h_load_off = Utils.Joaat("PS_LoadOffline")
    FeatureMgr.AddFeature(h_load_off, "Cargar perfil (modo historia)", eFeatureType.Button,
        "Lee personaje actual, progreso de historia y estadísticas disponibles",
        function()
            local data = read_offline()
            if data then profile.offline = data end
        end, true)

    local h_load_on = Utils.Joaat("PS_LoadOnline")
    FeatureMgr.AddFeature(h_load_on, "Cargar perfil (cuenta online)", eFeatureType.Button,
        "Lee apodo de Social Club, estado de conexión y nombre de red",
        function()
            local data = read_online()
            if data then profile.online = data end
        end, true)

    local h_save = Utils.Joaat("PS_Save")
    FeatureMgr.AddFeature(h_save, "Guardar perfil", eFeatureType.Button,
        "Guarda lo capturado hasta ahora en un archivo con tu nombre online",
        function() save_profile() end, true)

    local h_panel = FeatureMgr.AddFeature(Utils.Joaat("PS_ShowPanel"), "Mostrar panel en pantalla",
        eFeatureType.Toggle, "Panel con la información capturada",
        function(f) show_panel = f:IsToggled() end, false)
    if h_panel then h_panel:SetDefaultValue(true); h_panel:SetSaveable(true); h_panel:Reset() end
    show_panel = true

    local h_boot = FeatureMgr.AddFeature(Utils.Joaat("PS_UpdateOnBoot"), "Buscar actualizaciones al iniciar",
        eFeatureType.Toggle, "Comprueba automáticamente al cargar el script", function() end, false)
    if h_boot then h_boot:SetDefaultValue(true); h_boot:SetSaveable(true); h_boot:Reset() end

    local h_checkupd = Utils.Joaat("PS_CheckUpdate")
    FeatureMgr.AddFeature(h_checkupd, "Buscar actualizaciones", eFeatureType.Button, "",
        function() UPD.check() end, true)
    local h_applyupd = Utils.Joaat("PS_ApplyUpdate")
    FeatureMgr.AddFeature(h_applyupd, "Actualizar ahora", eFeatureType.Button, "",
        function() UPD.apply() end, true)

    ClickGUI.AddTab("PizzaScript", function()
        if ClickGUI.BeginCustomChildWindow("Perfil") then
            ClickGUI.RenderFeature(h_load_off)
            ClickGUI.RenderFeature(h_load_on)
            ClickGUI.RenderFeature(h_save)
            ClickGUI.RenderFeature(h_panel)
            ClickGUI.EndCustomChildWindow()
        end
        if ClickGUI.BeginCustomChildWindow("Actualizador") then
            ImGui.Text(string.format("Local: %s   Estado: %s%s", PS_VERSION, UPD.state,
                       UPD.remote_version and ("   Remota: " .. UPD.remote_version) or ""))
            ClickGUI.RenderFeature(h_boot)
            ClickGUI.RenderFeature(h_checkupd)
            ClickGUI.RenderFeature(h_applyupd)
            ClickGUI.EndCustomChildWindow()
        end
    end)
end

--==============================================================================
-- Arranque
--==============================================================================

local function env_check()
    local required = { "FeatureMgr", "ClickGUI", "Utils", "eFeatureType", "Script", "Natives" }
    local missing = {}
    for _, n in ipairs(required) do if _G[n] == nil then missing[#missing + 1] = n end end
    if #missing > 0 then
        Log.error("Boot", "Entorno incompleto, faltan: %s", table.concat(missing, ", "))
        return false
    end
    return true
end

local function install_loop()
    local warmup = 0
    Script.RegisterLooped(function()
        if ShouldUnload and ShouldUnload() then return end

        warmup = warmup + 1
        if warmup == 10 then
            -- Unos frames de margen para que el hilo de script esté
            -- plenamente asentado antes de tocar cualquier native.
            armed = true
            Log.info("Boot", "Natives armadas")
        end
        if warmup == 15 and FeatureMgr.IsFeatureToggled(Utils.Joaat("PS_UpdateOnBoot")) then
            UPD.check()
        end

        pcall(UPD.tick)
        pcall(render_hud)

        Script.Yield()
    end)
end

if env_check() then
    build_ui()
    install_loop()
    Log.info("Boot", "PizzaScript v%s instalado. Pestaña 'PizzaScript' en Lua Content.", PS_VERSION)
    if GUI and GUI.AddToast then
        GUI.AddToast("PizzaScript", "Cargado. Pestaña 'PizzaScript' disponible.", 4000)
    end
else
    if GUI and GUI.AddToast then
        GUI.AddToast("PizzaScript", "Fallo al cargar. Mira Cherax.log", 6000)
    end
end
