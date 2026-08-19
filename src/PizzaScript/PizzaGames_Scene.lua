--[[
================================================================================
  PizzaGames_Scene  v0.2.0
  Carga de escenarios: modelos, props, físicas y cámaras.

  POR QUÉ CARGA POR LOTES:
  Un circuito son 100-300 props. Instanciarlos en un solo frame congela el
  juego varios segundos y suele provocar crash por saturación del pool de
  objetos. Scene:load_step() instancia unos pocos por frame y devuelve
  progreso, de modo que el minijuego puede mostrar una barra de carga y el
  juego sigue respondiendo.

  POR QUÉ REFERENCIAS CONTADAS EN MODELOS:
  Pedir un modelo lo mantiene en memoria. Si dos escenas usan el mismo prop y
  una lo libera, la otra se queda con props invisibles. El contador impide
  liberar un modelo mientras alguien lo siga usando.

  Uso:  local Scene = dofile("PizzaGames_Scene.lua")(PG)
================================================================================
]]

return function(PG)

local Log = PG.Log
local API = PG.API
local M   = {}

--==============================================================================
-- GESTOR DE MODELOS  (con contador de referencias y timeout)
--==============================================================================

local Models = { refs = {}, hashes = {}, stats = { requested = 0, failed = 0, freed = 0 } }

function Models.hash(model)
    if type(model) == "number" then return model end
    if Models.hashes[model] then return Models.hashes[model] end
    local h = API.call("get_hash", nil, model)
    if not h then
        Log.error("Models", "No se pudo obtener el hash de '%s' "
               .. "(rellena CANDIDATES.get_hash)", tostring(model))
        return nil
    end
    Models.hashes[model] = h
    return h
end

--- Solicita un modelo y espera a que cargue.
--- @param wait_fn función de espera por frame (la aporta el minijuego)
--- @return ok, hash
--- Modelos de recambio por si el preferido no existe en esta versión del
--- juego. Un nombre inválido devuelve handle 0 en cada intento y el escenario
--- sale vacío sin decir por qué; con esto al menos se construye algo.
Models.FALLBACKS = {
    "prop_barrier_work05", "prop_mp_barrier_02b", "prop_boxpile_07d",
}

--- Comprueba con el juego si el modelo existe. Sin esto, un nombre mal escrito
--- sólo se manifiesta como "0 props instanciados" y cuesta atribuirlo.
function Models.is_valid(model)
    local h = Models.hash(model)
    if not h then return false end
    if not API.has("is_model_valid") then return true end   -- sin forma de saberlo
    return API.call("is_model_valid", true, h) and true or false
end

--- Devuelve un modelo utilizable: el pedido, o el primer recambio válido.
function Models.resolve(model)
    if Models.is_valid(model) then return model end

    Log.warn("Models", "Modelo inválido: '%s'. Probando recambios...", tostring(model))
    for _, alt in ipairs(Models.FALLBACKS) do
        if alt ~= model and Models.is_valid(alt) then
            Log.warn("Models", "Sustituido '%s' por '%s'", tostring(model), alt)
            return alt
        end
    end

    Log.error("Models", "Ni '%s' ni ningún recambio son válidos. "
           .. "¿Está disponible IS_MODEL_VALID?", tostring(model))
    return nil
end

function Models.request(model, wait_fn, timeout_ms)
    local h = Models.hash(model)
    if not h then return false, nil end

    -- Ya está cargado por otra escena: sólo incrementamos el contador
    if Models.refs[h] and Models.refs[h] > 0 then
        Models.refs[h] = Models.refs[h] + 1
        Log.trace("Models", "'%s' reutilizado (refs=%d)", tostring(model), Models.refs[h])
        return true, h
    end

    Models.stats.requested = Models.stats.requested + 1
    API.call("request_model", nil, h)

    if not API.has("has_model_loaded") then
        -- Sin forma de confirmar la carga: asumimos y avisamos una vez
        Log.warn("Models", "No hay has_model_loaded; se asume que '%s' cargó", tostring(model))
        Models.refs[h] = 1
        return true, h
    end

    local timeout  = timeout_ms or 3000
    local deadline = PG.now() + (timeout / 1000)
    local spins    = 0

    -- DOS frenos independientes, a propósito.
    -- El plazo por reloj no basta: si la fuente de tiempo se queda parada (por
    -- ejemplo si la native está bloqueada), el bucle no terminaría NUNCA y el
    -- juego se congelaría sin posibilidad de recuperación. El tope de vueltas
    -- garantiza la salida aunque el reloj mienta.
    local MAX_SPINS = 600   -- ~10 s a 60 fps

    while not API.call("has_model_loaded", false, h) do
        spins = spins + 1

        if spins > MAX_SPINS then
            Models.stats.failed = Models.stats.failed + 1
            Log.error("Models", "Abandonado '%s' tras %d vueltas sin confirmación de carga. "
                   .. "Si el reloj no avanza, revisa que las natives estén armadas.",
                      tostring(model), spins)
            return false, nil
        end

        if PG.now() > deadline then
            Models.stats.failed = Models.stats.failed + 1
            Log.error("Models", "TIMEOUT cargando '%s' (hash %s) tras %d ms y %d intentos. "
                   .. "¿Nombre de modelo inválido?", tostring(model), tostring(h), timeout, spins)
            return false, nil
        end

        if wait_fn then wait_fn(0) else break end
    end

    Models.refs[h] = (Models.refs[h] or 0) + 1
    Log.debug("Models", "'%s' cargado en %d intentos (refs=%d)",
              tostring(model), spins, Models.refs[h])
    return true, h
end

function Models.release(model)
    local h = Models.hash(model)
    if not h or not Models.refs[h] then return end

    Models.refs[h] = Models.refs[h] - 1
    if Models.refs[h] <= 0 then
        Models.refs[h] = nil
        Models.stats.freed = Models.stats.freed + 1
        API.call("free_model", nil, h)
        Log.trace("Models", "'%s' liberado", tostring(model))
    end
end

function Models.report()
    local live = 0
    for _ in pairs(Models.refs) do live = live + 1 end
    return string.format("Modelos: %d vivos | %d solicitados, %d fallidos, %d liberados",
        live, Models.stats.requested, Models.stats.failed, Models.stats.freed)
end

M.Models = Models

--==============================================================================
-- ESCENA  (colección de props con carga incremental)
--==============================================================================

local Scene = {}
Scene.__index = Scene

--- @param res  instancia de PG.Resources (para la limpieza automática)
--- @param opts {per_frame=props por frame, frozen=bool, collision=bool}
function M.new(name, res, opts)
    opts = opts or {}
    return setmetatable({
        name       = name,
        res        = res,
        queue      = {},
        spawned    = 0,
        failed     = 0,
        cursor     = 1,
        per_frame  = opts.per_frame or 8,
        frozen     = opts.frozen ~= false,      -- props fijos por defecto
        collision  = opts.collision ~= false,
        models_used= {},
        state      = "PENDING",
        t_start    = nil,
    }, Scene)
end

--- Encola props. Acepta la salida directa de PizzaGames_Prefabs.
function Scene:add(props)
    if not props then return self end
    for _, p in ipairs(props) do
        self.queue[#self.queue + 1] = p
        self.models_used[p.model] = true
    end
    Log.debug("Scene", "[%s] +%d props en cola (total %d)", self.name, #props, #self.queue)
    return self
end

function Scene:total()    return #self.queue end
function Scene:progress()
    if #self.queue == 0 then return 1.0 end
    return (self.cursor - 1) / #self.queue
end

--- Precarga todos los modelos distintos. Llamar una vez antes de load_step.
function Scene:preload(wait_fn)
    local names, ok_n, fail_n = {}, 0, 0
    for name in pairs(self.models_used) do names[#names + 1] = name end

    Log.info("Scene", "[%s] Precargando %d modelos distintos...", self.name, #names)

    -- Validar y sustituir ANTES de pedir nada. Si un modelo no existe se
    -- reemplaza en toda la cola, de modo que el escenario se construye igual.
    local swaps = {}
    for _, name in ipairs(names) do
        local good = Models.resolve(name)
        if good and good ~= name then swaps[name] = good end
    end
    if next(swaps) then
        for _, p in ipairs(self.queue) do
            if swaps[p.model] then p.model = swaps[p.model] end
        end
        local fixed = {}
        for name in pairs(self.models_used) do fixed[swaps[name] or name] = true end
        self.models_used = fixed
        names = {}
        for name in pairs(self.models_used) do names[#names + 1] = name end
        Log.warn("Scene", "[%s] %d modelo(s) sustituidos por recambios", self.name, #names)
    end

    for _, name in ipairs(names) do
        local ok = Models.request(name, wait_fn)
        if ok then ok_n = ok_n + 1 else fail_n = fail_n + 1 end
    end

    self.state = fail_n > 0 and "PARTIAL" or "LOADING"
    self.t_start = PG.now()
    Log.info("Scene", "[%s] Modelos listos: %d correctos, %d fallidos", self.name, ok_n, fail_n)
    return fail_n == 0
end

--- Instancia el siguiente lote. Llamar una vez por frame.
--- @return done, progreso 0..1
function Scene:load_step()
    if self.cursor > #self.queue then
        if self.state ~= "READY" then
            self.state = "READY"
            local secs = self.t_start and (PG.now() - self.t_start) or 0
            Log.info("Scene", "[%s] COMPLETA: %d props instanciados, %d fallos, %.2fs",
                     self.name, self.spawned, self.failed, secs)
            if self.failed > 0 then
                Log.warn("Scene", "[%s] %d props no se instanciaron. Causa habitual: "
                      .. "modelo no cargado o pool de objetos lleno.", self.name, self.failed)
            end
            -- Cero props de N no es una escena degradada: es una escena inexistente.
            -- Jugar un circuito invisible confunde más que un error claro.
            if self.spawned == 0 and #self.queue > 0 then
                self.state = "FAILED"
                Log.error("Scene", "[%s] NINGÚN prop se instanció (%d intentos). "
                       .. "Verifica CANDIDATES.create_object y los nombres de modelo.",
                          self.name, #self.queue)
            end
        end
        return true, 1.0
    end

    local last = math.min(self.cursor + self.per_frame - 1, #self.queue)
    for i = self.cursor, last do
        local p = self.queue[i]
        local h = Models.hash(p.model)
        local handle = h and API.call("create_object", nil, h, p.x, p.y, p.z, false, false, false)

        if handle and handle ~= 0 then
            self.res:track("entity", handle)
            self.spawned = self.spawned + 1
            API.call("set_rotation", nil, handle, p.rx or 0, p.ry or 0, p.rz or 0, 2, true)
            if self.frozen    then API.call("freeze_entity", nil, handle, true) end
            if not self.collision then API.call("set_collision", nil, handle, false, false) end
        else
            self.failed = self.failed + 1
            if self.failed <= 3 then   -- sólo los primeros, para no inundar el log
                Log.error("Scene", "[%s] Falló el prop %d ('%s') en %.1f, %.1f, %.1f",
                          self.name, i, tostring(p.model), p.x, p.y, p.z)
            end
        end
    end

    self.cursor = last + 1
    return false, self:progress()
end

--- Carga bloqueante (sólo para escenas pequeñas, <40 props).
function Scene:load_all(wait_fn)
    self:preload(wait_fn)
    local done = false
    while not done do
        done = self:load_step()
        if wait_fn then wait_fn(0) end
    end
    return self.failed == 0
end

--- Libera los modelos. Los props los libera Resources al parar el minijuego.
function Scene:unload()
    for name in pairs(self.models_used) do Models.release(name) end
    Log.debug("Scene", "[%s] Modelos liberados", self.name)
end

M.Scene = Scene

--==============================================================================
-- CÁMARA  (intro cinemática y liberación garantizada)
--==============================================================================

local Camera = { handle = nil, active = false }

function Camera.start(pos, look_at)
    if Camera.active then Camera.stop() end

    local cam = API.call("create_cam", nil, "DEFAULT_SCRIPTED_CAMERA", true)
    if not cam or cam == 0 then
        Log.warn("Camera", "No se pudo crear la cámara; se continúa sin cinemática")
        return false
    end

    Camera.handle = cam
    Camera.active = true
    API.call("set_cam_coords", nil, cam, pos.x, pos.y, pos.z)
    if look_at then
        API.call("point_cam_at", nil, cam, look_at.x, look_at.y, look_at.z)
    end
    API.call("render_cam", nil, true, false, 0, true, false)
    Log.debug("Camera", "Cámara %s activa en %.1f, %.1f, %.1f", tostring(cam), pos.x, pos.y, pos.z)
    return true
end

--- Interpolación lineal de la posición (llamar por frame durante la intro).
function Camera.move_to(from, to, t)
    if not Camera.active then return end
    t = math.max(0, math.min(1, t))
    -- suavizado (ease in-out) para que no se note el arranque
    local e = t * t * (3 - 2 * t)
    API.call("set_cam_coords", nil, Camera.handle,
             from.x + (to.x - from.x) * e,
             from.y + (to.y - from.y) * e,
             from.z + (to.z - from.z) * e)
end

function Camera.stop()
    if not Camera.active then return end
    API.call("render_cam", nil, false, false, 0, true, false)
    API.call("destroy_cam", nil, Camera.handle, true)
    Log.debug("Camera", "Cámara liberada")
    Camera.handle, Camera.active = nil, false
end

M.Camera = Camera

--==============================================================================
-- AUTOTEST DEL MÓDULO
--==============================================================================

function M.self_test()
    Log.info("SceneTest", "--- Autotest de escenarios ---")
    local passed, failed = 0, 0
    local function check(name, fn)
        local ok, err = pcall(fn)
        if ok then passed = passed + 1; Log.info("SceneTest", "PASA  %s", name)
        else failed = failed + 1; Log.error("SceneTest", "FALLA %s -> %s", name, tostring(err)) end
    end

    check("la cola de escena acumula props", function()
        local res = PG.Resources.new("scenetest")
        local sc  = M.new("test", res)
        sc:add({ { model = "a", x = 0, y = 0, z = 0 }, { model = "b", x = 1, y = 1, z = 1 } })
        assert(sc:total() == 2, "se esperaban 2 props")
    end)

    check("el progreso avanza y termina", function()
        local res = PG.Resources.new("scenetest")
        local sc  = M.new("test", res, { per_frame = 2 })
        -- Modelo real: desde que existe validación, un nombre ficticio se
        -- rechaza (con razón) y la escena saldría vacía.
        local props = {}
        for i = 1, 7 do
            props[i] = { model = "prop_barrier_work05", x = i, y = 0, z = 0 }
        end
        sc:add(props)
        assert(sc:progress() == 0, "el progreso debería empezar en 0")
        local guard, done = 0, false
        while not done and guard < 50 do done = sc:load_step(); guard = guard + 1 end
        assert(done, "la carga nunca terminó")
        assert(sc:progress() == 1.0, "el progreso debería acabar en 1")
        -- IMPRESCINDIBLE: el autotest se ejecuta DENTRO del juego. Sin esto,
        -- cada pulsación de "Ejecutar autotest" dejaría props reales sueltos.
        -- Si create_object no está disponible no se instancia nada; lo que se
        -- exige es que no quede NADA sin liberar, no un número concreto.
        local spawned = sc.spawned
        local freed   = res:release_all()
        assert(freed == spawned,
               string.format("quedan props sin liberar: instanciados=%d liberados=%d",
                             spawned, freed))
        assert(res:count() == 0, "el rastreador debería quedar vacío")
        sc:unload()
    end)

    check("el contador de referencias impide liberar de más", function()
        Models.refs, Models.hashes = {}, {}
        Models.hashes["dup"] = 111
        Models.refs[111] = 0
        Models.request("dup"); Models.request("dup")
        assert(Models.refs[111] == 2, "se esperaban 2 referencias, hay " .. tostring(Models.refs[111]))
        Models.release("dup")
        assert(Models.refs[111] == 1, "aún debería quedar 1 referencia")
        Models.release("dup")
        assert(Models.refs[111] == nil, "debería haberse liberado")
    end)

    Log.info("SceneTest", "--- Fin: %d correctas, %d fallidas ---", passed, failed)
    return { passed = passed, failed = failed }
end

return M
end
