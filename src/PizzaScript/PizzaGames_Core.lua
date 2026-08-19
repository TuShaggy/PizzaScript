--[[
================================================================================
  PizzaGames  v0.1.0
  Framework de minijuegos para Cherax (un solo jugador)

  ARQUITECTURA EN 4 CAPAS
    1. Diagnostics  -> logging, xpcall+traceback, perfilado, ring buffer
    2. Adapter      -> ÚNICA capa que toca la API de Cherax. Todo lo demás
                       es Lua puro y portable.
    3. Resources    -> rastreo y liberación de entidades/blips/modelos
    4. Runtime      -> registro de minijuegos, máquina de estados, tick loop

  IMPORTANTE: la sección [ADAPTER] contiene suposiciones SIN VERIFICAR sobre
  la API de Cherax. Todas están marcadas con  --@VERIFY  y con detección de
  capacidades: si un símbolo no existe, se registra el fallo y se degrada
  con elegancia en vez de reventar el script.
================================================================================
]]

local PG = {}
-- Versión de todo el paquete (los 9 archivos), comparada por
-- PizzaGames_Updater.lua contra version.json del repo. Antes de esta sesión
-- no existía un número de versión único: cada archivo llevaba el suyo en la
-- cabecera, sin relación entre ellos. Éste es el primero que de verdad se usa
-- para algo (el auto-actualizador) y se sube en cada release junto al repo.
PG._VERSION = "1.0.0"
PG._NAME    = "PizzaGames"

--==============================================================================
-- CONFIGURACIÓN
--==============================================================================

local CONFIG = {
    log_level        = "DEBUG",  -- TRACE | DEBUG | INFO | WARN | ERROR | OFF
    log_to_console   = true,
    log_to_file      = true,
    log_file         = "pizzagames.log",
    log_buffer_size  = 600,      -- líneas en memoria para el visor in-game
    strict_mode      = false,    -- true: los errores propagan; false: se capturan
    max_tick_errors  = 5,        -- errores seguidos antes de abortar un minijuego
    profile_enabled  = true,
    profile_warn_ms  = 8.0,      -- avisar si un tick supera este tiempo
}

--==============================================================================
-- CAPA 1: DIAGNOSTICS
--==============================================================================

local Log = {}
do
    local LEVELS = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5, OFF = 99 }
    local buffer, buf_head, buf_count = {}, 1, 0
    local error_counts = {}   -- [tag] = n, para detectar fallos recurrentes
    local file_handle

    local function threshold()
        return LEVELS[CONFIG.log_level] or LEVELS.DEBUG
    end

    local function timestamp()
        return os.date("%H:%M:%S")
    end

    local function push_buffer(line)
        buffer[buf_head] = line
        buf_head = (buf_head % CONFIG.log_buffer_size) + 1
        if buf_count < CONFIG.log_buffer_size then buf_count = buf_count + 1 end
    end

    local function write_file(line)
        if not CONFIG.log_to_file then return end
        if not file_handle then
            local ok, fh = pcall(io.open, CONFIG.log_file, "a")
            if not ok or not fh then CONFIG.log_to_file = false; return end
            file_handle = fh
        end
        file_handle:write(line, "\n")
        file_handle:flush()   -- flush inmediato: si el juego crashea, el log sobrevive
    end

    function Log.write(level, tag, fmt, ...)
        if (LEVELS[level] or 0) < threshold() then return end

        local msg = fmt
        if select("#", ...) > 0 then
            local ok, formatted = pcall(string.format, fmt, ...)
            msg = ok and formatted or (fmt .. " <<ERROR DE FORMATO>>")
        end

        local line = string.format("[%s][%-5s][%s] %s", timestamp(), level, tag, msg)

        push_buffer(line)
        write_file(line)
        if CONFIG.log_to_console then print(line) end

        if level == "ERROR" then
            error_counts[tag] = (error_counts[tag] or 0) + 1
        end
    end

    function Log.trace(tag, fmt, ...) Log.write("TRACE", tag, fmt, ...) end
    function Log.debug(tag, fmt, ...) Log.write("DEBUG", tag, fmt, ...) end
    function Log.info (tag, fmt, ...) Log.write("INFO",  tag, fmt, ...) end
    function Log.warn (tag, fmt, ...) Log.write("WARN",  tag, fmt, ...) end
    function Log.error(tag, fmt, ...) Log.write("ERROR", tag, fmt, ...) end

    -- Devuelve las últimas N líneas en orden cronológico (para el visor in-game)
    function Log.tail(n)
        n = math.min(n or 40, buf_count)
        local out = {}
        for i = n - 1, 0, -1 do
            local idx = ((buf_head - 2 - i) % CONFIG.log_buffer_size) + 1
            out[#out + 1] = buffer[idx]
        end
        return out
    end

    function Log.error_summary()
        local rows = {}
        for tag, n in pairs(error_counts) do rows[#rows + 1] = { tag = tag, count = n } end
        table.sort(rows, function(a, b) return a.count > b.count end)
        return rows
    end

    function Log.clear()
        buffer, buf_head, buf_count = {}, 1, 0
        error_counts = {}
        Log.info("Log", "Buffer de log limpiado")
    end
end

PG.Log = Log
PG.CONFIG = CONFIG

--------------------------------------------------------------------------------
-- Ejecución protegida: NINGUNA llamada a la API del juego debe correr desnuda.
--------------------------------------------------------------------------------

local function traceback_handler(err)
    return debug.traceback(tostring(err), 3)
end

-- Declaración adelantada: PG.now() usa API, definida más abajo en [ADAPTER].
-- Sin esto, API se resolvería como variable global (nil) dentro de PG.now.
local API

--- FUENTE DE TIEMPO INYECTABLE.
--- os.clock() mide tiempo de CPU, no de reloj: en un bucle de juego rápido
--- apenas avanza y las cuentas atrás nunca vencen. Si Cherax expone un
--- temporizador de milisegundos real, engánchalo aquí y todo el framework
--- (fases, cuentas atrás, cronómetros) pasa a usarlo.
--- Usa automáticamente el temporizador del juego (milisegundos) si el
--- adaptador lo resuelve; si no, cae a os.time(), que sólo tiene resolución
--- de 1 segundo y basta para cuentas atrás pero no para cronometrar vueltas.
local _clock_source = nil   -- se fija en la primera llamada y NO cambia
PG.now = function()
    if _clock_source == nil then
        _clock_source = API.has("game_timer") and "game" or "os"
        Log.info("Clock", "Fuente de reloj fijada: %s%s", _clock_source,
                 _clock_source == "os" and " (resolución de 1 s; engancha game_timer para milisegundos)" or "")
    end
    -- Cambiar de fuente a mitad de partida produce saltos de miles de millones
    -- de segundos: los cronómetros se vuelven negativos. Por eso se fija una vez.
    if _clock_source == "game" then
        -- Puede devolver nil si la native está bloqueada por la barrera de
        -- hilo; sin esta comprobación, nil/1000 lanzaría en pleno bucle.
        local ms = API.call("game_timer", nil)
        if type(ms) == "number" then return ms / 1000 end
        return os.time()
    end
    return os.time()
end

--- Reinicia la fuente de reloj. Llamar sólo tras un probe() del adaptador.
function PG.reset_clock() _clock_source = nil end

--- Ejecuta fn de forma segura. Devuelve (ok, resultado_o_error).
function PG.try(context, fn, ...)
    if CONFIG.strict_mode then
        return true, fn(...)
    end
    local args = table.pack(...)
    local ok, res = xpcall(function() return fn(table.unpack(args, 1, args.n)) end,
                           traceback_handler)
    if not ok then
        Log.error(context, "EXCEPCIÓN CAPTURADA:\n%s", res)
    end
    return ok, res
end

--- Igual que try, pero devuelve un valor por defecto si falla.
function PG.try_or(context, default, fn, ...)
    local ok, res = PG.try(context, fn, ...)
    if not ok or res == nil then return default end
    return res
end

--- Perfilado sencillo: mide y avisa si algo tarda demasiado.
function PG.profile(label, fn, ...)
    if not CONFIG.profile_enabled then return fn(...) end
    local t0 = os.clock()
    local results = table.pack(fn(...))
    local ms = (os.clock() - t0) * 1000
    if ms >= CONFIG.profile_warn_ms then
        Log.warn("Profile", "%s tardó %.2f ms (umbral %.1f ms)", label, ms, CONFIG.profile_warn_ms)
    else
        Log.trace("Profile", "%s: %.3f ms", label, ms)
    end
    return table.unpack(results, 1, results.n)
end

--==============================================================================
-- CAPA 2: ADAPTER  ← TODA la dependencia de Cherax vive aquí
--==============================================================================
--
--  @VERIFY: cada entrada de CANDIDATES es una conjetura sobre cómo expone
--  Cherax esa funcionalidad. Al tener la documentación, sustituye la lista de
--  candidatos por la ruta real. El resto del archivo NO necesita cambios.
--
--  El probe recorre los candidatos en orden y se queda con el primero que
--  resuelva a una función. Si ninguno existe, marca la capacidad como ausente,
--  lo registra UNA vez, y devuelve un valor por defecto seguro.
--==============================================================================

API = {}
do
    local resolved   = {}   -- [capability] = function  (resueltas por ruta)
    local bound      = {}   -- [capability] = function  (enlaces directos)
    local missing    = {}   -- [capability] = true
    local warned     = {}   -- para no spamear el log

    -- 'bound' y 'resolved' están separados a propósito. probe() reconstruye
    -- 'resolved' desde cero; si los enlaces directos vivieran ahí, cada sondeo
    -- (y el autotest hace uno) los borraría y todo dejaría de funcionar.

    -- Resuelve una ruta tipo "menu.add_feature" desde _G
    local function resolve_path(path)
        local node = _G
        for part in path:gmatch("[^%.]+") do
            if type(node) ~= "table" then return nil end
            node = node[part]
            if node == nil then return nil end
        end
        return (type(node) == "function") and node or nil
    end

    --@VERIFY -- Sustituir por los nombres reales de la API de Cherax
    local CANDIDATES = {
        -- Interfaz / notificaciones
        notify          = { "cherax.notify", "menu.notify", "gui.show_message", "notification" },
        -- Construcción de UI
        create_tab      = { "menu.add_tab", "gui.add_tab", "cherax.ui.add_tab" },
        add_button      = { "menu.add_button", "gui.add_button", "cherax.ui.add_button" },
        add_toggle      = { "menu.add_toggle", "gui.add_toggle", "cherax.ui.add_toggle" },
        add_slider      = { "menu.add_slider", "gui.add_slider", "cherax.ui.add_slider" },
        add_text        = { "menu.add_text", "gui.add_text", "cherax.ui.add_text" },
        -- Jugador / mundo
        get_player_ped  = { "player.get_ped", "cherax.player.ped", "PLAYER.PLAYER_PED_ID" },
        get_coords      = { "entity.get_coords", "ENTITY.GET_ENTITY_COORDS" },
        set_coords      = { "entity.set_coords", "ENTITY.SET_ENTITY_COORDS" },
        get_health      = { "entity.get_health", "ENTITY.GET_ENTITY_HEALTH" },
        -- Blips
        create_blip     = { "hud.add_blip_for_coord", "HUD.ADD_BLIP_FOR_COORD" },
        remove_blip     = { "hud.remove_blip", "HUD.REMOVE_BLIP" },
        set_blip_colour = { "hud.set_blip_colour", "HUD.SET_BLIP_COLOUR" },
        set_blip_sprite = { "hud.set_blip_sprite", "HUD.SET_BLIP_SPRITE" },
        -- Entidades
        delete_entity   = { "entity.delete", "ENTITY.DELETE_ENTITY" },
        -- Modelos (imprescindible antes de instanciar cualquier cosa)
        game_timer      = { "misc.get_game_timer", "MISC.GET_GAME_TIMER", "utils.time_ms" },
        get_hash        = { "misc.get_hash_key", "MISC.GET_HASH_KEY", "joaat" },
        request_model   = { "streaming.request_model", "STREAMING.REQUEST_MODEL" },
        has_model_loaded= { "streaming.has_model_loaded", "STREAMING.HAS_MODEL_LOADED" },
        free_model      = { "streaming.set_model_as_no_longer_needed", "STREAMING.SET_MODEL_AS_NO_LONGER_NEEDED" },
        -- Props y físicas
        create_object   = { "object.create_object", "OBJECT.CREATE_OBJECT" },
        set_rotation    = { "entity.set_rotation", "ENTITY.SET_ENTITY_ROTATION" },
        set_heading     = { "entity.set_heading", "ENTITY.SET_ENTITY_HEADING" },
        freeze_entity   = { "entity.freeze", "ENTITY.FREEZE_ENTITY_POSITION" },
        set_collision   = { "entity.set_collision", "ENTITY.SET_ENTITY_COLLISION" },
        set_gravity     = { "entity.set_has_gravity", "ENTITY.SET_ENTITY_HAS_GRAVITY" },
        place_on_ground = { "entity.place_on_ground", "ENTITY.PLACE_OBJECT_ON_GROUND_PROPERLY" },
        get_ground_z    = { "misc.get_ground_z", "MISC.GET_GROUND_Z_FOR_3D_COORD" },
        -- Vehículos y peds
        create_vehicle  = { "vehicle.create_vehicle", "VEHICLE.CREATE_VEHICLE" },
        create_ped      = { "ped.create_ped", "PED.CREATE_PED" },
        set_into_vehicle= { "ped.set_into_vehicle", "PED.SET_PED_INTO_VEHICLE" },
        give_weapon     = { "weapon.give_delayed_weapon", "WEAPON.GIVE_DELAYED_WEAPON_TO_PED" },
        task_combat     = { "ai.task_combat_ped", "TASK.TASK_COMBAT_PED" },
        is_ped_dead     = { "ped.is_dead", "ENTITY.IS_ENTITY_DEAD" },
        -- Cámaras
        create_cam      = { "cam.create_cam", "CAM.CREATE_CAM" },
        set_cam_coords  = { "cam.set_cam_coord", "CAM.SET_CAM_COORD" },
        set_cam_rot     = { "cam.set_cam_rot", "CAM.SET_CAM_ROT" },
        point_cam_at    = { "cam.point_cam_at_coord", "CAM.POINT_CAM_AT_COORD" },
        render_cam      = { "cam.render_script_cams", "CAM.RENDER_SCRIPT_CAMS" },
        destroy_cam     = { "cam.destroy_cam", "CAM.DESTROY_CAM" },
        -- HUD en mundo
        draw_marker     = { "graphics.draw_marker", "GRAPHICS.DRAW_MARKER" },
        -- Scheduling
        create_thread   = { "script.register_looped", "cherax.create_thread", "menu.create_thread" },
        wait            = { "script.wait", "cherax.wait", "system.wait" },
    }

    -- Capacidades que bajo Cherax se resuelven por API.bind() o que
    -- pertenecen al camino genérico de respaldo. Su ausencia es normal y no
    -- merece un WARN: avisar de ellas sólo ensucia la consola del menú.
    local OPTIONAL = {
        create_tab=true, add_button=true, add_toggle=true, add_slider=true,
        add_text=true, create_thread=true, notify=true,
        set_into_vehicle=true, get_health=true, set_heading=true,
        place_on_ground=true, get_ground_z=true, create_vehicle=true,
        set_gravity=true, set_blip_sprite=true,
        set_coords=true, set_cam_rot=true,
    }

    --- Sondea el entorno y reporta qué está disponible.
    --- @param quiet  si es true, no avisa de las ausencias todavía. Se usa
    ---   cuando después vendrá un bind_all() que resolverá varias de ellas:
    ---   avisar antes de eso produce falsos positivos en la consola.
    function API.probe(quiet)
        -- No se toca 'bound': los enlaces directos sobreviven al sondeo.
        resolved, missing, warned = {}, {}, {}
        local found_n, missing_n = 0, 0

        for capability, paths in pairs(CANDIDATES) do
            local hit
            for _, path in ipairs(paths) do
                local fn = resolve_path(path)
                if fn then
                    resolved[capability] = fn
                    hit = path
                    break
                end
            end
            if hit then
                found_n = found_n + 1
                Log.debug("Adapter", "OK      %-16s -> %s", capability, hit)
            else
                missing[capability] = true
                missing_n = missing_n + 1
                if quiet or OPTIONAL[capability] then
                    Log.debug("Adapter", "sin resolver por ruta: %-16s", capability)
                else
                    Log.warn("Adapter", "AUSENTE %-16s (probado: %s)",
                             capability, table.concat(paths, ", "))
                end
            end
        end

        Log.info("Adapter", "Sondeo completo: %d resueltas, %d ausentes", found_n, missing_n)
        return { found = found_n, missing = missing_n, missing_list = missing }
    end

    --- Invoca una capacidad de forma segura. Nunca lanza.
    function API.call(capability, default, ...)
        local fn = bound[capability] or resolved[capability]
        if not fn then
            if not warned[capability] then
                warned[capability] = true
                Log.error("Adapter", "Llamada a capacidad no resuelta: '%s'. "
                       .. "Rellena CANDIDATES.%s con la ruta real de la API.",
                          capability, capability)
            end
            return default
        end
        local ok, res = PG.try("Adapter." .. capability, fn, ...)
        if not ok then return default end
        return res
    end

    function API.has(capability)
        return (bound[capability] or resolved[capability]) ~= nil
    end

    --- Enlaza una implementación concreta, saltándose la resolución por ruta.
    --- Se usa cuando la llamada real no es un simple acceso a función
    --- (p. ej. GUI.AddToast necesita 3 argumentos donde nosotros pasamos 1).
    function API.bind(capability, fn)
        bound[capability]   = fn
        missing[capability] = nil
        warned[capability]  = nil
        Log.debug("Adapter", "ENLAZADA %s (implementación directa)", capability)
    end

    function API.unresolved(include_optional)
        local out = {}
        for cap in pairs(missing) do
            if bound[cap] == nil and (include_optional or not OPTIONAL[cap]) then
                out[#out + 1] = cap
            end
        end
        table.sort(out)
        return out
    end
end

PG.API = API

-- Envoltorios de conveniencia (el código de minijuegos usa SOLO estos)
local function notify(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    Log.info("Notify", "%s", msg)
    API.call("notify", nil, msg)
end

local function player_ped()   return API.call("get_player_ped", 0) end
local function player_pos()   return API.call("get_coords", { x = 0, y = 0, z = 0 }, player_ped()) end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--==============================================================================
-- CAPA 3: RESOURCES  (evitar fugas de entidades es crítico en GTA)
--==============================================================================

local Resources = {}
Resources.__index = Resources

function Resources.new(owner)
    return setmetatable({ owner = owner, items = {} }, Resources)
end

--- kind: "entity" | "blip"
function Resources:track(kind, handle)
    if not handle or handle == 0 then
        Log.warn("Resources", "[%s] Intento de rastrear handle inválido (%s)",
                 self.owner, tostring(handle))
        return handle
    end
    self.items[#self.items + 1] = { kind = kind, handle = handle }
    Log.trace("Resources", "[%s] +%s #%s (total %d)",
              self.owner, kind, tostring(handle), #self.items)
    return handle
end

function Resources:release_all()
    local n = #self.items
    if n == 0 then
        Log.debug("Resources", "[%s] Nada que liberar", self.owner)
        return 0
    end

    local freed, failed = 0, 0
    for i = n, 1, -1 do
        local item = self.items[i]
        local ok
        if item.kind == "blip" then
            ok = select(1, PG.try("Resources.remove_blip",
                                   function() API.call("remove_blip", nil, item.handle) end))
        else
            ok = select(1, PG.try("Resources.delete_entity",
                                   function() API.call("delete_entity", nil, item.handle) end))
        end
        if ok then freed = freed + 1 else failed = failed + 1 end
        self.items[i] = nil
    end

    Log.info("Resources", "[%s] Liberados %d/%d (%d fallos)", self.owner, freed, n, failed)
    return freed
end

function Resources:count() return #self.items end

PG.Resources = Resources

--==============================================================================
-- CAPA 4: RUNTIME  (registro + máquina de estados)
--==============================================================================

local STATE = { IDLE = "IDLE", RUNNING = "RUNNING", ENDING = "ENDING" }

local Runtime = {
    registry     = {},      -- [id] = definición
    order        = {},      -- para UI estable
    active       = nil,     -- definición en curso
    state        = STATE.IDLE,
    ctx          = nil,     -- contexto de la partida actual
    tick_errors  = 0,
    tick_count   = 0,
}

--- Registra un minijuego.
--- def = { id, name, description, params, on_start, on_tick, on_stop }
function PG.register(def)
    assert(type(def) == "table",     "register(): se esperaba una tabla")
    assert(type(def.id) == "string", "register(): falta 'id'")
    assert(type(def.on_tick) == "function", "register(): falta 'on_tick'")

    if Runtime.registry[def.id] then
        Log.warn("Runtime", "Sobrescribiendo minijuego ya registrado: '%s'", def.id)
    else
        Runtime.order[#Runtime.order + 1] = def.id
    end

    def.name        = def.name or def.id
    def.description = def.description or ""
    def.params      = def.params or {}
    def.category    = def.category or "Otros"
    Runtime.registry[def.id] = def

    Log.info("Runtime", "Registrado '%s' (%s) [%s] con %d parámetros",
             def.id, def.name, def.category, #def.params)
    return def
end

function PG.start(id)
    if Runtime.state ~= STATE.IDLE then
        Log.warn("Runtime", "start('%s') ignorado: ya hay '%s' en estado %s",
                 id, Runtime.active and Runtime.active.id or "?", Runtime.state)
        notify("Ya hay un minijuego en curso.")
        return false
    end

    local def = Runtime.registry[id]
    if not def then
        Log.error("Runtime", "start(): minijuego desconocido '%s'", tostring(id))
        return false
    end

    -- Rechazar el arranque si falta algo imprescindible: mejor un mensaje claro
    -- que un minijuego que "funciona" con el jugador en las coordenadas 0,0,0.
    local needed = def.requires or { "get_coords", "get_player_ped" }
    local absent = {}
    for _, cap in ipairs(needed) do
        if not API.has(cap) then absent[#absent + 1] = cap end
    end
    if #absent > 0 then
        Log.error("Runtime", "No se puede iniciar '%s': faltan %d capacidades -> %s. "
               .. "Rellena esas entradas en CANDIDATES.", id, #absent, table.concat(absent, ", "))
        notify("No se puede iniciar %s: falta %s", def.name or id, absent[1])
        return false
    end

    -- La UI es de modo inmediato: los valores viven en las features, no en
    -- def.settings. Este hook los vuelca antes de arrancar.
    if PG.on_before_start then
        PG.try("Runtime.on_before_start", PG.on_before_start, def)
    end

    Log.info("Runtime", "=== INICIANDO '%s' ===", id)

    Runtime.ctx = {
        id        = id,
        res       = Resources.new(id),
        started_at= PG.now(),
        score     = 0,
        data      = {},          -- espacio libre para el minijuego
        log       = function(fmt, ...) Log.debug("MG:" .. id, fmt, ...) end,
        notify    = notify,
        player_pos= player_pos,
        dist3     = dist3,
    }

    Runtime.active      = def
    Runtime.state       = STATE.RUNNING
    Runtime.tick_errors = 0
    Runtime.tick_count  = 0

    if def.on_start then
        local ok = PG.try("MG:" .. id .. ".on_start", def.on_start, Runtime.ctx)
        if not ok then
            Log.error("Runtime", "on_start falló para '%s'; abortando arranque", id)
            PG.stop("error_en_arranque")
            return false
        end
    end

    notify("Minijuego iniciado: %s", def.name)
    return true
end

--- Detiene el minijuego activo.
---
--- BLINDADO A PROPÓSITO. En la versión anterior una excepción a mitad de
--- stop() dejaba el estado en ENDING para siempre: los recursos quedaban
--- huérfanos y TODOS los start() posteriores se rechazaban. Un solo fallo
--- inutilizaba el script hasta recargarlo.
---
--- Ahora cada fase va protegida por separado y el retorno a IDLE está
--- garantizado pase lo que pase.
function PG.stop(reason)
    if Runtime.state == STATE.IDLE then
        Log.debug("Runtime", "stop() ignorado: no hay minijuego activo")
        return false
    end

    local def, ctx = Runtime.active, Runtime.ctx
    local id = def and def.id or "?"
    Runtime.state = STATE.ENDING

    Log.info("Runtime", "=== DETENIENDO '%s' (motivo: %s) ===", id, tostring(reason or "manual"))

    local failures = {}

    -- Fase 1: callback del minijuego
    if def and def.on_stop then
        local ok = PG.try("MG:" .. id .. ".on_stop", def.on_stop, ctx, reason)
        if not ok then failures[#failures + 1] = "on_stop" end
    end

    -- Fase 2: liberar entidades. Es la fase que más puede fallar (natives
    -- sobre entidades ya inexistentes), así que va doblemente protegida.
    local freed = 0
    if ctx and ctx.res then
        local ok, n = PG.try("Runtime.release", function() return ctx.res:release_all() end)
        if ok then freed = n or 0 else failures[#failures + 1] = "liberación de recursos" end
    end

    -- Fase 3: resumen (nunca debe impedir el reinicio)
    PG.try("Runtime.summary", function()
        if not ctx then return end
        local elapsed = PG.now() - ctx.started_at
        if elapsed < 0 then elapsed = 0 end
        Log.info("Runtime", "'%s' finalizado: %.1fs, %d ticks, puntuación %s, %d recursos liberados",
                 id, elapsed, Runtime.tick_count, tostring(ctx.score), freed)
        notify("%s finalizado — Puntuación: %s", def and def.name or id, tostring(ctx.score))
    end)

    -- Fase 4: reinicio del estado. ESTO SIEMPRE OCURRE.
    Runtime.active, Runtime.ctx = nil, nil
    Runtime.tick_errors = 0
    Runtime.state = STATE.IDLE

    if #failures > 0 then
        Log.warn("Runtime", "'%s' se detuvo con fallos en: %s. El estado se reinició "
              .. "igualmente, puedes volver a jugar.", id, table.concat(failures, ", "))
    end

    return true
end

--- Reinicio de emergencia: fuerza IDLE y suelta lo que quede rastreado.
--- Es la salida cuando algo deja el runtime en un estado imposible.
function PG.force_reset()
    local prev  = Runtime.state
    local ctx   = Runtime.ctx
    local alive = (ctx and ctx.res) and ctx.res:count() or 0

    Log.warn("Runtime", "REINICIO DE EMERGENCIA (estado previo: %s, %d recursos vivos)",
             prev, alive)

    if ctx and ctx.res then
        PG.try("ForceReset.release", function() ctx.res:release_all() end)
    end
    if PG.Scene and PG.Scene.Camera then
        PG.try("ForceReset.camera", function() PG.Scene.Camera.stop() end)
    end
    if PG.Cinema then
        PG.try("ForceReset.cinema", function() PG.Cinema.abort() end)
    end

    Runtime.active, Runtime.ctx = nil, nil
    Runtime.tick_errors, Runtime.tick_count = 0, 0
    Runtime.state = STATE.IDLE

    Log.info("Runtime", "Reinicio completado. Estado: IDLE")
    notify("Reinicio de emergencia completado")
    return { previous = prev, released = alive }
end

--- Vigilante de estados atascados.
--- ENDING es una fase transitoria que dura milisegundos. Si persiste, algo se
--- rompió a mitad de la parada y sin esto el script quedaría bloqueado.
local WATCHDOG_SECS = 5
local watchdog = { since = nil, last_state = nil }

local function watchdog_check()
    local st = Runtime.state

    if st ~= watchdog.last_state then
        watchdog.last_state = st
        watchdog.since = PG.now()
        return
    end

    if st ~= STATE.ENDING then return end

    local stuck = PG.now() - (watchdog.since or PG.now())
    if stuck >= WATCHDOG_SECS then
        Log.error("Watchdog", "Estado ENDING atascado %.1fs. Forzando reinicio. "
               .. "Causa probable: excepción durante la parada.", stuck)
        PG.force_reset()
        watchdog.since = PG.now()
    end
end

--- Llamar una vez por frame desde el hilo del menú.
function PG.tick()
    watchdog_check()
    if Runtime.state ~= STATE.RUNNING then return end

    Runtime.tick_count = Runtime.tick_count + 1
    local def, ctx = Runtime.active, Runtime.ctx

    local ok, result = PG.try("MG:" .. def.id .. ".on_tick", def.on_tick, ctx)

    if not ok then
        Runtime.tick_errors = Runtime.tick_errors + 1
        Log.error("Runtime", "Error de tick %d/%d en '%s'",
                  Runtime.tick_errors, CONFIG.max_tick_errors, def.id)

        if Runtime.tick_errors >= CONFIG.max_tick_errors then
            Log.error("Runtime", "Límite de errores alcanzado. Volcado de estado:\n%s",
                      PG.dump_state())
            PG.stop("demasiados_errores")
        end
        return
    end

    Runtime.tick_errors = 0            -- sólo cuentan los errores consecutivos
    if result == false then            -- el minijuego pide terminar
        PG.stop("completado")
    end
end

PG.STATE   = STATE
PG.Runtime = Runtime
PG.notify  = notify
PG.dist3   = dist3
PG.player_ped = player_ped
PG.player_pos = player_pos

--==============================================================================
-- DIAGNÓSTICOS: volcado de estado y autotest
--==============================================================================

function PG.dump_state()
    local lines = {
        string.format("%s v%s", PG._NAME, PG._VERSION),
        string.format("Estado        : %s", Runtime.state),
        string.format("Activo        : %s", Runtime.active and Runtime.active.id or "ninguno"),
        string.format("Ticks         : %d", Runtime.tick_count),
        string.format("Errores segdos: %d", Runtime.tick_errors),
        string.format("Registrados   : %d", #Runtime.order),
    }

    if Runtime.ctx then
        lines[#lines + 1] = string.format("Recursos vivos: %d", Runtime.ctx.res:count())
        lines[#lines + 1] = string.format("Tiempo activo : %.1fs", PG.now() - Runtime.ctx.started_at)
        lines[#lines + 1] = string.format("Puntuación    : %s", tostring(Runtime.ctx.score))
    end

    local errs = Log.error_summary()
    if #errs > 0 then
        lines[#lines + 1] = "-- Errores por etiqueta --"
        for i = 1, math.min(#errs, 8) do
            lines[#lines + 1] = string.format("  %-28s %d", errs[i].tag, errs[i].count)
        end
    end

    return table.concat(lines, "\n")
end

--- Autotest: valida el framework sin tocar el juego.
function PG.self_test()
    Log.info("SelfTest", "===== INICIO DEL AUTOTEST =====")
    local passed, failed = 0, 0

    local function check(name, fn)
        local ok, err = pcall(fn)
        if ok then
            passed = passed + 1
            Log.info("SelfTest", "PASA  %s", name)
        else
            failed = failed + 1
            Log.error("SelfTest", "FALLA %s -> %s", name, tostring(err))
        end
    end

    check("logging con formato", function()
        Log.debug("SelfTest", "valor=%d texto=%s", 42, "ok")
    end)

    check("logging tolera formato inválido", function()
        Log.debug("SelfTest", "esto %d no casa", "no-es-numero")
    end)

    check("try captura excepciones", function()
        local ok = PG.try("SelfTest", function() error("fallo intencionado") end)
        assert(ok == false, "try debería devolver false")
    end)

    check("try_or devuelve el valor por defecto", function()
        local v = PG.try_or("SelfTest", 99, function() error("boom") end)
        assert(v == 99, "se esperaba 99, se obtuvo " .. tostring(v))
    end)

    check("rastreo de recursos", function()
        local r = Resources.new("selftest")
        r:track("entity", 1234)
        r:track("blip", 5678)
        assert(r:count() == 2, "se esperaban 2 recursos")
        r:track("entity", 0)                    -- handle inválido: no debe contar
        assert(r:count() == 2, "el handle inválido no debería rastrearse")
        r:release_all()
        assert(r:count() == 0, "los recursos deberían estar liberados")
    end)

    check("el buffer de log devuelve líneas", function()
        assert(#Log.tail(5) > 0, "el tail debería devolver líneas")
    end)

    check("dump_state no lanza", function()
        assert(type(PG.dump_state()) == "string")
    end)

    -- No se vuelve a sondear aquí: probe() reconstruye la tabla de resueltas y
    -- ejecutar el autotest dejaría el script inservible. Sólo se informa.
    local un = API.unresolved()
    Log.info("SelfTest", "===== FIN: %d correctas, %d fallidas | %d capacidades sin resolver%s =====",
             passed, failed, #un, #un > 0 and (": " .. table.concat(un, ", ")) or "")

    return { passed = passed, failed = failed, unresolved = un }
end

--==============================================================================
-- CONSTRUCCIÓN DE LA PESTAÑA
--   @VERIFY: la forma exacta de estas llamadas depende de la API de Cherax.
--   Toda la lógica de arriba es independiente de esta sección.
--==============================================================================

function PG.build_tab()
    Log.info("UI", "Construyendo pestaña...")

    local tab = API.call("create_tab", nil, "Minijuegos")
    if not tab then
        Log.error("UI", "No se pudo crear la pestaña. Rellena CANDIDATES.create_tab. "
               .. "El framework sigue siendo utilizable desde la consola: PG.start('id')")
        return nil
    end

    -- Agrupar por categoría, manteniendo el orden de registro dentro de cada una
    local cats, cat_order = {}, {}
    for _, id in ipairs(Runtime.order) do
        local c = Runtime.registry[id].category
        if not cats[c] then cats[c] = {}; cat_order[#cat_order + 1] = c end
        cats[c][#cats[c] + 1] = id
    end
    table.sort(cat_order)

    for _, cat in ipairs(cat_order) do
        API.call("add_text", nil, tab, string.format("=== %s ===", cat:upper()))

        for _, id in ipairs(cats[cat]) do
            local def = Runtime.registry[id]

            API.call("add_text",   nil, tab, def.name)
            API.call("add_button", nil, tab, "  Iniciar",  function() PG.start(id) end)
            API.call("add_button", nil, tab, "  Detener",  function() PG.stop("usuario") end)

            for _, p in ipairs(def.params) do
                API.call("add_slider", nil, tab, "  " .. p.label, p.min, p.max, p.default,
                    function(value)
                        def.settings[p.key] = value
                        Log.debug("UI", "%s.%s = %s", id, p.key, tostring(value))
                    end)
            end
        end
    end
    Log.debug("UI", "%d categorías: %s", #cat_order, table.concat(cat_order, ", "))

    -- Submenú de diagnóstico
    API.call("add_text",   nil, tab, "--- Diagnóstico ---")
    API.call("add_button", nil, tab, "Ejecutar autotest", function() PG.self_test() end)
    API.call("add_button", nil, tab, "Sondear API",       function() API.probe() end)
    API.call("add_button", nil, tab, "Volcar estado",     function()
        for line in PG.dump_state():gmatch("[^\n]+") do notify("%s", line) end
    end)
    API.call("add_button", nil, tab, "Últimas 20 líneas", function()
        for _, line in ipairs(Log.tail(20)) do print(line) end
    end)
    API.call("add_button", nil, tab, "Limpiar log",       function() Log.clear() end)
    API.call("add_toggle", nil, tab, "Log detallado (TRACE)", false, function(on)
        CONFIG.log_level = on and "TRACE" or "DEBUG"
        Log.info("UI", "Nivel de log -> %s", CONFIG.log_level)
    end)

    Log.info("UI", "Pestaña construida con %d minijuegos", #Runtime.order)
    return tab
end

--==============================================================================
-- ARRANQUE
--==============================================================================

function PG.init()
    Log.info("Init", "%s v%s arrancando...", PG._NAME, PG._VERSION)

    local probe = API.probe()
    if probe.missing > 0 then
        Log.warn("Init", "%d capacidades sin resolver. Revisa la sección [ADAPTER]. "
              .. "Los minijuegos funcionarán de forma degradada.", probe.missing)
    end

    PG.build_tab()

    -- @VERIFY: registrar el bucle. Alternativa: while true do PG.tick(); wait(0) end
    if API.has("create_thread") then
        API.call("create_thread", nil, function() PG.tick() end)
        Log.info("Init", "Bucle de tick registrado vía create_thread")
    else
        Log.error("Init", "No hay planificador disponible: PG.tick() NO se llamará. "
               .. "Rellena CANDIDATES.create_thread o llama a PG.tick() manualmente.")
    end

    Log.info("Init", "Listo.")
    return PG
end

return PG
