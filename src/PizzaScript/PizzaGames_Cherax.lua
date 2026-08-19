--[[
================================================================================
  PizzaGames_Cherax  v0.4.0
  Enlace con la API de Cherax. Reescrito contra Documentation.json.

  QUÉ CAMBIÓ RESPECTO A LA VERSIÓN ANTERIOR
  -----------------------------------------
  La documentación real dejó ver que Cherax ofrece envoltorios propios mucho
  mejores que las natives crudas:

    Antes (conjetura)              Ahora (documentado)
    ---------------------------    -----------------------------------------
    feature OnTick como bucle      Script.RegisterLooped + Script.Yield
    MISC.GET_GAME_TIMER()          Time.GetEpocheMs()
    ENTITY.GET_ENTITY_COORDS       GTA.GetLocalPed().Position  (V3)
    OBJECT.CREATE_OBJECT           GTA.CreateObject(...)
    PED.CREATE_PED                 GTA.CreatePed(..., autoCleanup)
    (nada)                         GTA.GetGroundZ(x, y)
    (nada)                         ShouldUnload() -> limpieza al descargar

  Los namespaces de natives (ENTITY, CAM, HUD...) NO aparecen en
  Documentation.json, que sólo cubre la API de clases; las natives van en un
  archivo aparte. Por eso todo lo que no tiene envoltorio propio se resuelve
  con detección: si el namespace existe se usa, si no se degrada y se avisa.

  Uso:  dofile(".../PizzaGames_Cherax.lua")(PG)
================================================================================
]]

return function(PG, NAT, Cinema)

local Log = PG.Log
local API = PG.API

local M = { features = {}, params = {}, loop_id = nil, unloading = false }
-- M.unloading es público a propósito: permite rearmar el bucle en pruebas.

--==============================================================================
-- 0. Comprobación del entorno
--==============================================================================

local function env_check()
    -- OJO: no usar { FeatureMgr = FeatureMgr, ... }. En Lua los valores nil no
    -- se almacenan, así que si faltan TODOS el bucle no itera y la
    -- comprobación pasa justo cuando debía fallar.
    local required = { "FeatureMgr", "ClickGUI", "Utils", "eFeatureType", "GTA", "Script", "Natives" }
    local missing = {}
    for _, name in ipairs(required) do
        if _G[name] == nil then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        Log.error("Cherax", "Entorno incompleto, faltan: %s", table.concat(missing, ", "))
        return false
    end

    -- Opcionales: su ausencia degrada pero no impide funcionar
    local optional = { "Time", "FileMgr", "Logger", "GUI", "eCallbackTrigger" }
    for _, name in ipairs(optional) do
        if _G[name] == nil then
            Log.warn("Cherax", "Opcional ausente: %s (se usará alternativa)", name)
        end
    end

    Log.info("Cherax", "Entorno verificado")
    return true
end

--==============================================================================
-- 1. Enlace de capacidades
--==============================================================================

--- Normaliza un V3 de Cherax a una tabla simple. El resto del framework
--- trabaja con {x,y,z} y no debe depender del tipo concreto.
local function v3(v)
    if not v then return nil end
    return { x = v.x, y = v.y, z = v.z }
end

local function bind_all()
    ------------------------------------------------------------------ tiempo
    if Time and Time.GetEpocheMs then
        API.bind("game_timer", function() return Time.GetEpocheMs() end)
    end
    if Script and Script.Yield then
        API.bind("wait", function(ms) Script.Yield(ms or 0) end)
    end

    ------------------------------------------------------------------ hashes
    API.bind("get_hash", function(name)
        if type(name) == "number" then return name end
        return Utils.Joaat(name)
    end)

    ------------------------------------------------------------------ jugador
    -- GTA.GetLocalPed() devuelve un CPed (puntero), no un handle. Para las
    -- natives que esperan handle hace falta GTA.PointerToHandle.
    API.bind("get_player_ped", function()
        local ped = GTA.GetLocalPed()
        if not ped then return 0 end
        if GTA.PointerToHandle then return GTA.PointerToHandle(ped) end
        return ped
    end)

    -- Position se lee del objeto CPed: sin natives y sin coste de invocación.
    API.bind("get_coords", function()
        local ped = GTA.GetLocalPed()
        if not ped then return nil end
        return v3(ped.Position)
    end)

    if GTA.GetGroundZ then
        API.bind("get_ground_z", function(x, y)
            local ok, z = GTA.GetGroundZ(x, y)
            if ok then return z end
            return nil
        end)
    end

    ------------------------------------------------------------------ props
    -- GTA.CreateObject se encarga del streaming del modelo por su cuenta.
    -- dynamic=false -> estático; isNetworked=false -> local, es un solo jugador.
    -- ERROR DE LA VERSIÓN ANTERIOR: se daba por hecho que GTA.CreateObject
    -- hacía el streaming del modelo. No es así. Los props comunes (barreras)
    -- funcionaban porque ya estaban cargados en el mundo; los raros fallaban
    -- en silencio devolviendo handle 0. Aquí se restaura el streaming real.
    if NAT and NAT.STREAMING then
        API.bind("request_model",    function(h) NAT.STREAMING.REQUEST_MODEL(h) end)
        API.bind("has_model_loaded", function(h) return NAT.STREAMING.HAS_MODEL_LOADED(h) end)
        API.bind("free_model",       function(h) NAT.STREAMING.SET_MODEL_AS_NO_LONGER_NEEDED(h) end)
        API.bind("is_model_valid",   function(h)
            -- IS_MODEL_VALID no basta: hay hashes válidos sin archivo en disco.
            if not NAT.STREAMING.IS_MODEL_VALID(h) then return false end
            return NAT.STREAMING.IS_MODEL_IN_CDIMAGE(h)
        end)
    end

    if GTA.CreateObject then
        API.bind("create_object", function(hash, x, y, z)
            return GTA.CreateObject(hash, x, y, z, false, false)
        end)
    elseif NAT and NAT.OBJECT then
        API.bind("create_object", function(hash, x, y, z)
            return NAT.OBJECT.CREATE_OBJECT(hash, x, y, z, false, false, false)
        end)
    end

    if GTA.CreatePed then
        API.bind("create_ped", function(ptype, hash, x, y, z, heading)
            -- autoCleanup=true: si el script muere de forma inesperada,
            -- Cherax retira los peds igualmente.
            return GTA.CreatePed(hash, ptype, x, y, z, heading or 0.0, false, true)
        end)
    end

    if GTA.SpawnVehicle then
        API.bind("create_vehicle", function(hash, x, y, z, heading)
            return GTA.SpawnVehicle(hash, x, y, z, heading or 0.0, false, true)
        end)
    end

    ------------------------------------------------------------- natives
    -- Cherax NO define los namespaces (ENTITY, CAM, HUD...). Los aporta
    -- PizzaGames_Natives.lua invocando por hash. Si falta ese módulo, todo
    -- esto queda sin resolver y los minijuegos van sin efectos.
    if NAT then
        local E = NAT.ENTITY
        API.bind("set_rotation",  function(e, rx, ry, rz) E.SET_ENTITY_ROTATION(e, rx, ry, rz, 2, true) end)
        API.bind("freeze_entity", function(e, on) E.FREEZE_ENTITY_POSITION(e, on) end)
        API.bind("set_collision", function(e, on) E.SET_ENTITY_COLLISION(e, on, true) end)
        API.bind("set_heading",   function(e, h) E.SET_ENTITY_HEADING(e, h) end)
        API.bind("is_ped_dead",   function(e) return E.IS_ENTITY_DEAD(e, false) end)

        -- DELETE_ENTITY sólo surte efecto si el script es dueño de la entidad.
        -- Sin SET_ENTITY_AS_MISSION_ENTITY los props quedan huérfanos: es la
        -- causa habitual de props fantasma tras salir del minijuego.
        API.bind("delete_entity", function(e)
            if not E.DOES_ENTITY_EXIST(e) then return end
            E.SET_ENTITY_AS_MISSION_ENTITY(e, true, true)
            E.DELETE_ENTITY(e)
        end)

        API.bind("give_weapon", function(ped, wname, ammo)
            NAT.WEAPON.GIVE_DELAYED_WEAPON_TO_PED(ped, Utils.Joaat(wname), ammo or 200, false)
        end)
        API.bind("task_combat", function(ped, target)
            NAT.TASK.TASK_COMBAT_PED(ped, target, 0, 16)
        end)

        API.bind("create_blip",     function(x, y, z) return NAT.HUD.ADD_BLIP_FOR_COORD(x, y, z) end)
        API.bind("remove_blip",     function(b) NAT.HUD.REMOVE_BLIP(b) end)
        API.bind("set_blip_colour", function(b, c) NAT.HUD.SET_BLIP_COLOUR(b, c) end)
        API.bind("set_blip_sprite", function(b, sp) NAT.HUD.SET_BLIP_SPRITE(b, sp) end)

        API.bind("draw_marker", function(t, x,y,z, d1,d2,d3, r1,r2,r3, sx,sy,sz, r,g,b,a)
            NAT.GRAPHICS.DRAW_MARKER(t, x,y,z, d1,d2,d3, r1,r2,r3, sx,sy,sz,
                                     r,g,b,a, false, false, 2, false, 0, 0, false)
        end)

        API.bind("create_cam",     function(name, active) return NAT.CAM.CREATE_CAM(name, active) end)
        API.bind("set_cam_coords", function(c, x, y, z) NAT.CAM.SET_CAM_COORD(c, x, y, z) end)
        API.bind("point_cam_at",   function(c, x, y, z) NAT.CAM.POINT_CAM_AT_COORD(c, x, y, z) end)
        API.bind("render_cam",     function(on) NAT.CAM.RENDER_SCRIPT_CAMS(on, false, 0, true, false) end)
        API.bind("destroy_cam",    function(c) NAT.CAM.DESTROY_CAM(c, true) end)

        if not (Time and Time.GetEpocheMs) then
            API.bind("game_timer", function() return NAT.MISC.GET_GAME_TIMER() end)
        end
        if not (GTA and GTA.GetGroundZ) then
            API.bind("get_ground_z", function(x, y)
                local ok, z = NAT.MISC.GET_GROUND_Z_FOR_3D_COORD(x, y, 1000.0, 0, false, false)
                return ok and z or nil
            end)
        end
    else
        Log.error("Cherax", "PizzaGames_Natives.lua no cargó: sin cámaras, "
               .. "marcadores, blips ni borrado de entidades.")
    end

    ------------------------------------------------------------ notificaciones
    if GUI and GUI.AddToast then
        API.bind("notify", function(msg)
            -- Firma real: AddToast(title, text, duration, pos)
            GUI.AddToast("PizzaGames", tostring(msg), 3000,
                         eToastPos and eToastPos.TOP_RIGHT or nil)
        end)
    end
end

--==============================================================================
-- 2. Features
--==============================================================================

local function feat_hash(id, suffix)
    return Utils.Joaat("PG_" .. id .. (suffix and ("_" .. suffix) or ""))
end

local function register_features()
    local n_act, n_par = 0, 0

    for _, id in ipairs(PG.Runtime.order) do
        local def = PG.Runtime.registry[id]

        local h_start = feat_hash(id, "start")
        FeatureMgr.AddFeature(h_start, "Iniciar " .. def.name, eFeatureType.Button,
            def.description, function()
                -- Arrancar antes de que el bucle arme las natives dejaba el
                -- escenario a medias esperando modelos que nunca cargan.
                if NAT and not NAT.is_armed() then
                    GUI.AddToast("PizzaGames",
                        "Espera un momento: el script aún se está preparando", 3000)
                    Log.warn("Cherax", "start('%s') rechazado: natives sin armar", id)
                    return
                end
                if M.natives_ok == false then
                    GUI.AddToast("PizzaGames",
                        "Las natives no pasaron la verificación. Revisa el log.", 5000)
                    return
                end
                PG.start(id)
            end, true)

        local h_stop = feat_hash(id, "stop")
        FeatureMgr.AddFeature(h_stop, "Detener", eFeatureType.Button,
            "Detiene el minijuego y retira todo lo creado",
            function() PG.stop("usuario") end, true)

        M.features[id] = { start = h_start, stop = h_stop }
        n_act = n_act + 2

        M.params[id] = {}
        for _, p in ipairs(def.params) do
            local h = feat_hash(id, p.key)
            local f = FeatureMgr.AddFeature(h, p.label, eFeatureType.SliderInt, "")
            if f then
                f:SetLimitValues(p.min, p.max)
                f:SetDefaultValue(p.default)
                f:SetSaveable(true)
                f:Reset()
            else
                Log.error("Cherax", "AddFeature devolvió nil para %s.%s", id, p.key)
            end
            M.params[id][p.key] = h
            n_par = n_par + 1
        end
    end

    Log.info("Cherax", "Features: %d acciones, %d parámetros", n_act, n_par)
end

--- La UI es de modo inmediato: los valores viven en las features. Este hook
--- los vuelca a def.settings justo antes de arrancar.
function PG.on_before_start(def)
    local map = M.params[def.id]
    if not map then return end

    local changed = {}
    for _, p in ipairs(def.params) do
        -- FeatureMgr.GetFeatureInt evita tener que recuperar el objeto Feature
        local v = FeatureMgr.GetFeatureInt and FeatureMgr.GetFeatureInt(map[p.key])
        if v == nil then
            local f = FeatureMgr.GetFeature(map[p.key])
            v = f and f:GetIntValue()
        end
        if v ~= nil then
            if def.settings[p.key] ~= v then
                changed[#changed + 1] = string.format("%s=%s", p.key, tostring(v))
            end
            def.settings[p.key] = v
        else
            Log.warn("Cherax", "No se pudo leer el parámetro %s.%s", def.id, p.key)
        end
    end

    if #changed > 0 then
        Log.info("Cherax", "Ajustes de '%s': %s", def.id, table.concat(changed, ", "))
    end
end

--==============================================================================
-- 3. Bucle  (Script.RegisterLooped, el mecanismo propio de Cherax)
--==============================================================================

local function install_loop()
    if not (Script and Script.RegisterLooped) then
        Log.error("Cherax", "Script.RegisterLooped no disponible: nada avanzará")
        return false
    end

    local beat = { last = 0, ticks = 0 }

    -- ARRANQUE DIFERIDO
    -- Todo lo que toca natives ocurre aquí dentro, en el hilo de script.
    -- Hacerlo en install() cerraba el juego: el cuerpo del .lua se ejecuta
    -- en otro hilo y las natives no lo toleran.
    local warmup = 0
    local function deferred_boot()
        warmup = warmup + 1

        -- Unos frames de margen para que el hilo esté plenamente asentado
        if warmup < 10 then return end

        if warmup == 10 then
            NAT_ARMED = true
            if NAT and NAT.arm then
                NAT.arm(function(level, msg)
                    if level == "ERROR" then Log.error("Natives", "%s", msg)
                    else Log.info("Natives", "%s", msg) end
                end)
            end
            return
        end

        if warmup == 12 then
            if NAT and NAT.verify then
                local ok, v = pcall(NAT.verify)
                if not ok then
                    Log.error("Cherax", "La verificación de natives lanzó: %s", tostring(v))
                elseif v.failed > 0 then
                    Log.error("Cherax", "Natives: %d correctas, %d FALLIDAS -> %s",
                              v.ok, v.failed, table.concat(v.problems, "; "))
                    if Logger then
                        Logger.LogError("[PizzaGames] HASHES DE NATIVES INCORRECTOS. "
                                     .. "No inicies ningún minijuego y revisa el log.")
                    end
                    M.natives_ok = false
                else
                    Log.info("Cherax", "Natives verificadas: %d comprobaciones correctas", v.ok)
                    if Logger then
                        Logger.LogInfo(string.format(
                            "[PizzaGames] Natives verificadas (%d/%d). Todo listo.", v.ok, v.ok))
                    end
                    M.natives_ok = true
                end
            end
            return
        end

        if warmup == 20 then
            M.play_boot_intro()
            if PG.Updater and FeatureMgr.IsFeatureToggled(Utils.Joaat("PG_UpdateOnBoot")) then
                PG.Updater.check()
            end
            M.booted = true
        end
    end

    M.loop_id = Script.RegisterLooped(function()
        -- ShouldUnload() se comprueba en CADA iteración. Si el usuario descarga
        -- el script a mitad de partida y no salimos aquí, los props creados se
        -- quedan en el mapa hasta reiniciar el juego.
        if ShouldUnload and ShouldUnload() then
            if not M.unloading then
                M.unloading = true
                Log.info("Cherax", "Descarga solicitada: limpiando...")
                PG.try("Cherax.unload", function() PG.stop("descarga") end)
                if PG.Scene and PG.Scene.Camera then PG.Scene.Camera.stop() end
            end
            return
        end

        beat.ticks = beat.ticks + 1

        if not M.booted then
            -- pcall: si el arranque diferido falla, el bucle debe seguir vivo
            -- para que el botón de emergencia siga siendo accesible.
            local ok, err = pcall(deferred_boot)
            if not ok then
                Log.error("Cherax", "Fallo en el arranque diferido: %s", tostring(err))
                M.booted = true
            end
        end

        PG.tick()

        -- El cine se actualiza SIEMPRE, no sólo durante los minijuegos: así
        -- funcionan también la intro de arranque y el botón de prueba.
        if Cinema then pcall(Cinema.update) end

        -- Igual que el cine: el actualizador sondea su Curl activo (si lo
        -- hay) en cada frame, nunca bloqueando. pcall por si una respuesta
        -- inesperada de la red lanza algo no previsto.
        if PG.Updater then pcall(PG.Updater.tick) end

        pcall(M.draw_hud)

        -- Latido cada 30 s: si el log calla, el bucle está muerto, y eso
        -- explica un "no pasa nada" que si no cuesta horas de localizar.
        local now = PG.now()
        if now - beat.last >= 30 then
            beat.last = now
            Log.debug("Heartbeat", "Bucle vivo: %d iteraciones, estado %s",
                      beat.ticks, PG.Runtime.state)
        end

        Script.Yield()
    end)

    Log.info("Cherax", "Bucle registrado (Script.RegisterLooped id=%s)", tostring(M.loop_id))
    return true
end

--==============================================================================
-- HUD en partida
--   Puntuación, fase y avisos de salud dibujados en pantalla. Evita tener que
--   salir del juego a leer el log para saber qué está pasando.
--==============================================================================

function M.draw_hud()
    if not NAT then return end
    if not FeatureMgr.IsFeatureToggled(Utils.Joaat("PG_HUD")) then return end

    local st  = PG.Runtime.state
    local ctx = PG.Runtime.ctx

    -- Fuera de partida sólo se avisa si hay algo roto: sin ruido innecesario.
    if st == "IDLE" then
        local unresolved = API.unresolved()
        if #unresolved > 0 then
            NAT.draw_rect(0.5, 0.965, 0.42, 0.045, 120, 0, 0, 170)
            NAT.draw_text(string.format("PizzaGames: %d capacidades sin resolver", #unresolved),
                          0.5, 0.952, { scale = 0.38, r = 255, g = 190, b = 190 })
        end
        return
    end

    if st == "ENDING" then
        NAT.draw_rect(0.5, 0.965, 0.42, 0.045, 140, 60, 0, 180)
        NAT.draw_text("PizzaGames: deteniendo...", 0.5, 0.952,
                      { scale = 0.4, r = 255, g = 220, b = 150 })
        return
    end

    if not ctx then return end
    local def   = PG.Runtime.active
    local phase = ctx.data and ctx.data.phase or "?"

    NAT.draw_rect(0.5, 0.955, 0.46, 0.062, 0, 0, 0, 150)
    NAT.draw_text(def and def.name or "PizzaGames", 0.5, 0.928,
                  { scale = 0.46, r = 255, g = 190, b = 40 })

    local detail
    if phase == "PROPS" and ctx.data.scene then
        detail = string.format("Construyendo escenario  %d%%",
                               math.floor(ctx.data.scene:progress() * 100))
    elseif phase == "MODELOS" then
        detail = "Preparando modelos..."
    elseif phase == "INTRO" then
        detail = "Preparados..."
    else
        detail = string.format("Puntuación %s   |   %d recursos",
                               tostring(ctx.score), ctx.res:count())
    end
    NAT.draw_text(detail, 0.5, 0.962, { scale = 0.36, r = 235, g = 235, b = 235 })
end

--==============================================================================
-- 4. Pestaña
--==============================================================================

local function render_category(cat, ids)
    if not ClickGUI.BeginCustomChildWindow(cat) then return end
    for _, id in ipairs(ids) do
        local def = PG.Runtime.registry[id]
        ClickGUI.RenderFeature(M.features[id].start)
        ClickGUI.RenderFeature(M.features[id].stop)
        for _, p in ipairs(def.params) do
            ClickGUI.RenderFeature(M.params[id][p.key])
        end
    end
    ClickGUI.EndCustomChildWindow()
end

--==============================================================================
-- Panel de salud del sistema
--   El log obliga a salir del juego para leerlo. Este panel muestra el estado
--   ahí mismo, con un semáforo, para identificar el problema de un vistazo.
--==============================================================================

local function health_report()
    local rows = {}
    local st   = PG.Runtime.state
    local errs = PG.Log.error_summary()
    local unresolved = API.unresolved()

    local level = "OK"
    local notes = {}

    if #unresolved > 0 then
        level = "FALLO"
        notes[#notes + 1] = #unresolved .. " capacidades sin resolver"
    end
    if st == "ENDING" then
        level = "FALLO"
        notes[#notes + 1] = "estado ENDING atascado"
    end
    if #errs > 0 then
        if level == "OK" then level = "AVISO" end
        local total = 0
        for _, e in ipairs(errs) do total = total + e.count end
        notes[#notes + 1] = total .. " errores registrados"
    end
    if not M.loop_id then
        level = "FALLO"
        notes[#notes + 1] = "bucle no registrado"
    end

    rows[#rows + 1] = { k = "Salud",   v = level }
    rows[#rows + 1] = { k = "Estado",  v = st }
    rows[#rows + 1] = { k = "Activo",  v = PG.Runtime.active and PG.Runtime.active.name or "ninguno" }
    rows[#rows + 1] = { k = "Bucle",   v = M.loop_id and ("id " .. tostring(M.loop_id)) or "NO REGISTRADO" }
    local nat_state
    if not NAT then nat_state = "AUSENTES"
    elseif not NAT.is_armed() then nat_state = "preparando..."
    elseif M.natives_ok == false then nat_state = "VERIFICACIÓN FALLIDA"
    else nat_state = "verificadas" end
    rows[#rows + 1] = { k = "Natives", v = nat_state }

    local blocked = NAT and NAT.blocked_report() or {}
    if #blocked > 0 then
        if level == "OK" then level = "AVISO" end
        rows[#rows + 1] = { k = "Bloqueadas", v = #blocked .. " (error de hilo)" }
        notes[#notes + 1] = "natives llamadas fuera del hilo de script"
    end
    if M.natives_ok == false then
        level = "FALLO"
        notes[#notes + 1] = "hashes de natives incorrectos"
    end
    rows[#rows + 1] = { k = "Cine",    v = Cinema and (Cinema.is_active() and "reproduciendo" or "listo") or "AUSENTE" }

    if PG.Runtime.ctx then
        rows[#rows + 1] = { k = "Recursos vivos", v = tostring(PG.Runtime.ctx.res:count()) }
        rows[#rows + 1] = { k = "Puntuación",     v = tostring(PG.Runtime.ctx.score) }
    end

    if PG.Updater then
        for _, r in ipairs(PG.Updater.status_rows()) do rows[#rows + 1] = r end
        if PG.Updater.state == "ERROR" then
            if level == "OK" then level = "AVISO" end
            notes[#notes + 1] = "el auto-actualizador tuvo un fallo"
        end
    end

    for i = 1, math.min(#errs, 3) do
        rows[#rows + 1] = { k = "Error: " .. errs[i].tag, v = tostring(errs[i].count) }
    end

    return level, rows, notes
end

--- Vuelca el diagnóstico completo al log de Cherax, listo para copiar y pegar.
local function dump_diagnostics()
    local level, rows, notes = health_report()
    Logger.LogInfo("========== DIAGNÓSTICO PIZZAGAMES ==========")
    Logger.LogInfo("[PizzaGames] Salud general: " .. level)
    for _, r in ipairs(rows) do
        Logger.LogInfo(string.format("[PizzaGames]   %-18s %s", r.k, r.v))
    end
    if #notes > 0 then
        Logger.LogInfo("[PizzaGames] Problemas: " .. table.concat(notes, "; "))
    end
    for line in PG.dump_state():gmatch("[^\n]+") do
        Logger.LogInfo("[PizzaGames]   " .. line)
    end
    local un = API.unresolved()
    Logger.LogInfo("[PizzaGames] Capacidades sin resolver: "
                .. (#un == 0 and "ninguna" or table.concat(un, ", ")))
    Logger.LogInfo("[PizzaGames] Últimas líneas del registro interno:")
    for _, l in ipairs(PG.Log.tail(25)) do Logger.LogInfo("[PizzaGames]   " .. l) end
    Logger.LogInfo("============================================")
end

local function build_ui()
    FeatureMgr.AddFeature(Utils.Joaat("PG_SelfTest"), "Ejecutar autotest",
        eFeatureType.Button, "Valida framework, geometría y escenarios sin entrar en partida",
        function()
            -- pcall obligatorio: el autotest provoca excepciones a propósito y
            -- una fuga hacia el menú aborta la feature ("threw an exception").
            local ok, res = pcall(PG.self_test)
            if ok and type(res) == "table" then
                GUI.AddToast("PizzaGames",
                    string.format("Autotest: %d correctas, %d fallidas",
                                  res.passed or 0, res.failed or 0), 5000)
            else
                Logger.LogError("[PizzaGames] El autotest falló: " .. tostring(res))
                GUI.AddToast("PizzaGames", "El autotest falló. Mira el log.", 5000)
            end
        end, true)

    FeatureMgr.AddFeature(Utils.Joaat("PG_DumpState"), "Volcar estado",
        eFeatureType.Button, "Escribe el estado completo en el log de Cherax",
        function()
            for line in PG.dump_state():gmatch("[^\n]+") do Logger.LogInfo("[PizzaGames] " .. line) end
            local u = API.unresolved()
            Logger.LogInfo("[PizzaGames] " .. (#u == 0 and "Todas las capacidades resueltas"
                                            or ("Sin resolver: " .. table.concat(u, ", "))))
        end, true)

    FeatureMgr.AddFeature(Utils.Joaat("PG_Probe"), "Sondear API",
        eFeatureType.Button, "Vuelve a comprobar qué está disponible",
        function()
            API.probe(true); bind_all(); PG.reset_clock()
            local u = API.unresolved()
            Logger.LogInfo("[PizzaGames] " .. (#u == 0 and "Todo resuelto"
                                            or ("Sin resolver: " .. table.concat(u, ", "))))
        end, true)

    FeatureMgr.AddFeature(Utils.Joaat("PG_ClearLog"), "Limpiar log",
        eFeatureType.Button, "", function() PG.Log.clear() end, true)

    -- BOTÓN DE RESCATE. Si algo deja el runtime bloqueado (era el caso: una
    -- excepción durante la parada dejaba el estado en ENDING para siempre),
    -- esto lo devuelve a IDLE y suelta lo que quedara rastreado.
    FeatureMgr.AddFeature(Utils.Joaat("PG_ForceReset"), "REINICIO DE EMERGENCIA",
        eFeatureType.Button,
        "Desbloquea el script si se queda atascado y borra los props huérfanos",
        function()
            local r = PG.force_reset()
            if Cinema then Cinema.abort(); Cinema.clear_titles() end
            GUI.AddToast("PizzaGames",
                string.format("Reiniciado (antes: %s, %d recursos)", r.previous, r.released),
                4000, eToastPos and eToastPos.TOP_RIGHT or nil)
        end, true)

    FeatureMgr.AddFeature(Utils.Joaat("PG_Diagnose"), "Diagnóstico completo",
        eFeatureType.Button,
        "Vuelca todo al log de Cherax: estado, capacidades, errores y registro",
        function()
            dump_diagnostics()
            local level = health_report()
            GUI.AddToast("PizzaGames", "Diagnóstico volcado al log. Salud: " .. level,
                         5000, eToastPos and eToastPos.TOP_RIGHT or nil)
        end, true)

    FeatureMgr.AddFeature(Utils.Joaat("PG_TestIntro"), "Probar intro cinematográfica",
        eFeatureType.Button,
        "Reproduce la secuencia de cámara sin arrancar ningún minijuego",
        function()
            if not Cinema then
                GUI.AddToast("PizzaGames", "El módulo de cine no está cargado", 4000)
                return
            end
            Cinema.play(Cinema.PRESETS.descend(5))
            Cinema.title("PIZZAGAMES", { sub = "Prueba de cámara", secs = 4 })
        end, true)

    local hud = FeatureMgr.AddFeature(Utils.Joaat("PG_HUD"), "Mostrar panel en pantalla",
        eFeatureType.Toggle,
        "Dibuja estado, puntuación y salud del sistema durante la partida",
        function() end, false)
    if hud then hud:SetDefaultValue(true); hud:SetSaveable(true); hud:Reset() end

    local bootcam = FeatureMgr.AddFeature(Utils.Joaat("PG_BootIntro"), "Intro al cargar el script",
        eFeatureType.Toggle,
        "Reproduce la presentación cinematográfica cuando se carga PizzaGames",
        function() end, false)
    if bootcam then bootcam:SetDefaultValue(true); bootcam:SetSaveable(true); bootcam:Reset() end

    if PG.Updater then
        FeatureMgr.AddFeature(Utils.Joaat("PG_CheckUpdate"), "Buscar actualizaciones",
            eFeatureType.Button, "Comprueba si hay una versión nueva en GitHub",
            function() PG.Updater.check() end, true)

        FeatureMgr.AddFeature(Utils.Joaat("PG_ApplyUpdate"), "Actualizar ahora",
            eFeatureType.Button,
            "Descarga y aplica la actualización encontrada (sólo si compila)",
            function() PG.Updater.apply_update() end, true)

        FeatureMgr.AddFeature(Utils.Joaat("PG_RollbackUpdate"), "Revertir a versión anterior",
            eFeatureType.Button,
            "Restaura los archivos de antes de la última actualización aplicada",
            function() PG.Updater.rollback() end, true)

        local upd_boot = FeatureMgr.AddFeature(Utils.Joaat("PG_UpdateOnBoot"), "Buscar al iniciar",
            eFeatureType.Toggle, "Comprueba actualizaciones automáticamente al cargar el script",
            function() end, false)
        if upd_boot then upd_boot:SetDefaultValue(true); upd_boot:SetSaveable(true); upd_boot:Reset() end
    end

    local vf = FeatureMgr.AddFeature(Utils.Joaat("PG_Verbose"), "Log detallado",
        eFeatureType.Toggle, "Sube el nivel a TRACE. Genera mucho volumen.",
        function(f) PG.CONFIG.log_level = f:IsToggled() and "TRACE" or "DEBUG" end, false)
    if vf then vf:SetDefaultValue(false); vf:SetSaveable(true); vf:Reset() end

    local cats, order = {}, {}
    for _, id in ipairs(PG.Runtime.order) do
        local c = PG.Runtime.registry[id].category
        if not cats[c] then cats[c] = {}; order[#order + 1] = c end
        cats[c][#cats[c] + 1] = id
    end
    table.sort(order)

    ClickGUI.AddTab("PizzaGames", function()
        for _, cat in ipairs(order) do render_category(cat, cats[cat]) end
        -- Estado en vivo arriba del todo: el semáforo se ve antes que nada
        local level, rows = health_report()
        local icon = (level == "OK" and "[OK] ") or (level == "AVISO" and "[!] ") or "[X] "
        if ClickGUI.BeginCustomChildWindow(icon .. "Estado del sistema") then
            for _, r in ipairs(rows) do
                ImGui.Text(string.format("%-16s %s", r.k, r.v))
            end
            ClickGUI.EndCustomChildWindow()
        end

        if ClickGUI.BeginCustomChildWindow("Presentación") then
            ClickGUI.RenderFeature(Utils.Joaat("PG_TestIntro"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_BootIntro"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_HUD"))
            ClickGUI.EndCustomChildWindow()
        end

        if PG.Updater and ClickGUI.BeginCustomChildWindow("Actualizaciones") then
            ImGui.Text(string.format("Versión local: %s   |   Estado: %s",
                                     tostring(PG._VERSION), PG.Updater.state))
            if PG.Updater.remote_version then
                ImGui.Text("Última disponible: " .. tostring(PG.Updater.remote_version))
            end
            ClickGUI.RenderFeature(Utils.Joaat("PG_CheckUpdate"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_ApplyUpdate"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_RollbackUpdate"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_UpdateOnBoot"))
            ClickGUI.EndCustomChildWindow()
        end

        if ClickGUI.BeginCustomChildWindow("Diagnóstico") then
            ClickGUI.RenderFeature(Utils.Joaat("PG_Diagnose"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_ForceReset"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_SelfTest"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_DumpState"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_Probe"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_ClearLog"))
            ClickGUI.RenderFeature(Utils.Joaat("PG_Verbose"))
            ClickGUI.EndCustomChildWindow()
        end
    end)

    Log.info("Cherax", "Pestaña 'PizzaGames' con %d categorías: %s",
             #order, table.concat(order, ", "))
end

--==============================================================================
-- 5. Logging hacia la consola de Cherax
--==============================================================================

local function hook_logger()
    if not Logger then return end
    -- Documentation.json: Logger sólo tiene Log, LogError y LogInfo.
    -- No existe LogWarning: los WARN van por LogInfo con prefijo.
    local orig = PG.Log.write
    PG.Log.write = function(level, tag, fmt, ...)
        orig(level, tag, fmt, ...)
        if level ~= "ERROR" and level ~= "WARN" then return end
        local msg = fmt
        if select("#", ...) > 0 then
            local ok, f = pcall(string.format, fmt, ...)
            msg = ok and f or fmt
        end
        local line = string.format("[PizzaGames][%s] %s", tag, msg)
        if level == "ERROR" then Logger.LogError(line) else Logger.LogInfo("[WARN] " .. line) end
    end
    Log.info("Cherax", "Logger enganchado")
end

--==============================================================================
-- Instalación
--==============================================================================

--- Presentación al cargar el script.
function M.play_boot_intro()
    if not Cinema then return end
    if not FeatureMgr.IsFeatureToggled(Utils.Joaat("PG_BootIntro")) then
        Log.debug("Cherax", "Intro de arranque desactivada")
        return
    end

    local ok = Cinema.play(Cinema.PRESETS.boot(), { blend_ms = 1200 })
    if not ok then
        Log.warn("Cherax", "No se pudo reproducir la intro de arranque")
        return
    end

    -- Títulos escalonados: el nombre entra primero y el resto lo acompaña.
    Cinema.title("PIZZAGAMES", { sub = "Minijuegos para un solo jugador",
                                 secs = 3.5, y = 0.33, scale = 1.35 })
    Log.info("Cherax", "Intro de arranque reproduciéndose")
end

function M.install()
    if not env_check() then return false end

    hook_logger()
    API.probe(true)
    bind_all()
    PG.reset_clock()

    local u = API.unresolved()
    if #u > 0 then
        Log.warn("Cherax", "%d capacidades sin resolver: %s", #u, table.concat(u, ", "))
    else
        Log.info("Cherax", "Todas las capacidades resueltas")
    end

    -- La verificación de natives NO se hace aquí: install() corre al cargar el
    -- script, fuera del hilo de script del juego. Se aplaza al bucle.
    register_features()
    build_ui()
    install_loop()

    -- Confirmación visible en Cherax.log. Sin esto el arranque correcto es
    -- indistinguible del fallido, porque sólo WARN/ERROR llegan a la consola.
    if Logger then
        Logger.LogInfo("[PizzaGames] ===== INSTALADO CORRECTAMENTE =====")
        Logger.LogInfo(string.format("[PizzaGames] %d minijuegos | natives: %s | cine: %s",
            #PG.Runtime.order, NAT and "sí" or "NO", Cinema and "sí" or "NO"))
        local un = API.unresolved()
        Logger.LogInfo("[PizzaGames] Capacidades sin resolver: "
                    .. (#un == 0 and "ninguna" or table.concat(un, ", ")))
        Logger.LogInfo("[PizzaGames] Pestaña 'PizzaGames' lista en Lua Content")
    end

    Log.info("Cherax", "PizzaGames instalado correctamente")
    return true
end

return M
end
