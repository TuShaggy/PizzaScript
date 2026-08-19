--[[
================================================================================
  PizzaGames_Updater  v1.0.0
  Auto-actualizador desde GitHub. Todo lo específico de red/disco vive aquí,
  igual que todo lo específico de Cherax vive en PizzaGames_Cherax.lua (regla
  de oro de PROYECTO.md).

  Fuente de la versión: PG._VERSION (PizzaGames_Core.lua), comparada contra
  version.json del repo. No hay hashes ni firmas criptográficas: Cherax no
  expone nada de eso. La única garantía de integridad es "¿compila con
  load()?", que es el requisito no negociable que pidió el usuario.

  Máquina de estados: IDLE -> CHECKING -> (IDLE si no hay nada nuevo, o
  DISPONIBLE) -> DESCARGANDO (descarga+verifica cada archivo con load(),
  secuencial) -> APLICANDO (respalda y escribe) -> HECHO. Cualquier fallo va
  a ERROR sin dejar el disco a medias.

  Uso:  dofile(".../PizzaGames_Updater.lua")(PG, { lua_root = "..." })
================================================================================
]]

return function(PG, opts)

opts = opts or {}
local Log = PG.Log

local REPO_RAW    = "https://raw.githubusercontent.com/TuShaggy/PizzaScript/main/"
local VERSION_URL = REPO_RAW .. "version.json"

-- Dos frenos independientes por descarga (trampa 5.4 de PROYECTO.md): ni el
-- reloj ni el contador de iteraciones pueden ser el único límite. Ajustables
-- por opts sólo para que el simulador pueda probar el freno de iteraciones
-- sin esperar segundos reales; en producción se usan los valores por defecto.
local DOWNLOAD_TIMEOUT_S = opts.download_timeout_s or 15
local DOWNLOAD_MAX_TICKS = opts.download_max_ticks or 1800

local U = {
    state          = "IDLE",
    lua_root       = opts.lua_root or "",
    remote_version = nil,
    remote_files   = nil,
    remote_notes   = nil,
    last_check     = nil,
    last_error     = nil,
    last_backup_dir= nil,
    applied_version= nil,

    -- El objeto Curl vive en el módulo, NUNCA en una variable local de
    -- función: si el recolector de basura lo libera a medio camino, la
    -- petición muere sin avisar (advertencia explícita de PROYECTO.md §7).
    _curl            = nil,
    _deadline_started= nil,
    _ticks           = 0,
    _download_index  = 0,
    _download_results= nil,
    _current_relpath = nil,
}

if not U.lua_root or U.lua_root == "" then
    Log.warn("Updater", "Ruta local de instalación desconocida: el "
          .. "auto-actualizador podrá comprobar versiones pero no escribir archivos")
end

--==============================================================================
-- Comparador de versiones (semver simplificado: sólo números separados por '.')
--==============================================================================

local function parse_version(v)
    local parts = {}
    for n in tostring(v):gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end

local function version_gt(a, b)
    local pa, pb = parse_version(a), parse_version(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end
U.version_gt = version_gt

--==============================================================================
-- version.json: no es un parser JSON general. Cherax no ofrece ninguno y
-- escribir uno completo sería una capacidad que este proyecto no necesita:
-- el esquema es fijo (3 claves) y lo controlamos nosotros mismos.
--==============================================================================

local function parse_version_json(body)
    assert(type(body) == "string" and #body > 0, "cuerpo vacío")

    local version = body:match('"version"%s*:%s*"([^"]+)"')
    assert(version, "no se encontró \"version\"")

    local files = {}
    local files_block = body:match('"files"%s*:%s*%[(.-)%]')
    assert(files_block, "no se encontró \"files\"")
    for entry in files_block:gmatch('"([^"]+)"') do
        files[#files + 1] = entry
    end
    assert(#files > 0, "\"files\" está vacío")

    local notas = body:match('"notas"%s*:%s*"([^"]*)"')

    return version, files, notas
end
U.parse_version_json = parse_version_json

--==============================================================================
-- Rutas locales
--==============================================================================

function U._local_path(relpath)
    return U.lua_root .. "\\" .. (relpath:gsub("/", "\\"))
end

--==============================================================================
-- Curl: arranque de una petición
--==============================================================================

local function start_request(url)
    if not (Curl and Curl.Easy) then
        Log.error("Updater", "Curl no está disponible en este Cherax")
        return nil
    end
    local ok, c = pcall(function()
        local h = Curl.Easy()
        h:Setopt(eCurlOption.CURLOPT_URL, url)
        h:Setopt(eCurlOption.CURLOPT_USERAGENT, "PizzaGames-Updater")
        h:Perform()
        return h
    end)
    if not ok then
        Log.error("Updater", "Curl.Easy() falló para %s: %s", url, tostring(c))
        return nil
    end
    return c
end

function U._fail(msg)
    U.state = "ERROR"
    U.last_error = msg
    U._curl = nil
    Log.error("Updater", "%s", msg)
    if GUI and GUI.AddToast then
        GUI.AddToast("PizzaGames", "Actualizador: " .. msg, 6000)
    end
end

--==============================================================================
-- Fase 1: comprobar versión
--==============================================================================

function U.check()
    local busy = U.state == "CHECKING" or U.state == "DESCARGANDO" or U.state == "APLICANDO"
    if busy then
        Log.warn("Updater", "check() ignorado: operación en curso (%s)", U.state)
        return false
    end
    if not (Curl and Curl.Easy) then
        Log.warn("Updater", "Curl no disponible; no se puede comprobar actualizaciones")
        return false
    end

    U.state             = "CHECKING"
    U._ticks            = 0
    U._deadline_started = PG.now()
    U._curl              = start_request(VERSION_URL)
    if not U._curl then
        U._fail("check: no se pudo iniciar la petición")
        return false
    end
    Log.info("Updater", "Comprobando actualizaciones (versión local: %s)", PG._VERSION)
    return true
end

local function pump_check()
    local c = U._curl
    if not c then U._fail("check: sin petición activa"); return end

    U._ticks = U._ticks + 1
    local timed_out    = (PG.now() - U._deadline_started) >= DOWNLOAD_TIMEOUT_S
    local out_of_ticks  = U._ticks >= DOWNLOAD_MAX_TICKS
    if timed_out or out_of_ticks then
        U._fail("check: tiempo agotado esperando version.json ("
              .. (timed_out and "reloj" or "iteraciones") .. ")")
        return
    end

    if not c:GetFinished() then return end

    local code, body = c:GetResponse()
    U._curl = nil
    if code ~= (eCurlCode and eCurlCode.CURLE_OK) then
        U._fail("check: fallo de red al pedir version.json (código " .. tostring(code) .. ")")
        return
    end

    local ok, version, files, notas = pcall(parse_version_json, body)
    if not ok then
        U._fail("check: version.json no se pudo interpretar (" .. tostring(version) .. ")")
        return
    end

    U.remote_version, U.remote_files, U.remote_notes = version, files, notas
    U.last_check = PG.now()

    if version_gt(version, PG._VERSION) then
        U.state = "DISPONIBLE"
        Log.info("Updater", "Actualización disponible: %s -> %s", PG._VERSION, version)
        if GUI and GUI.AddToast then
            GUI.AddToast("PizzaGames", "Actualización disponible: " .. version, 6000)
        end
    else
        U.state = "IDLE"
        Log.info("Updater", "Ya tienes la última versión (%s)", PG._VERSION)
    end
end

--==============================================================================
-- Fase 2: descargar + verificar cada archivo (secuencial, un Curl a la vez)
--==============================================================================

function U._start_next_download()
    U._download_index = U._download_index + 1
    local relpath = U.remote_files[U._download_index]

    if not relpath then
        U._apply_files()
        return
    end

    U._current_relpath  = relpath
    U._ticks             = 0
    U._deadline_started  = PG.now()
    U._curl               = start_request(REPO_RAW .. "src/" .. relpath)
    if not U._curl then
        U._fail("descarga de '" .. relpath .. "': no se pudo iniciar la petición")
    end
end

local function pump_download()
    local c = U._curl
    if not c then U._fail("descarga: sin petición activa"); return end

    U._ticks = U._ticks + 1
    local timed_out   = (PG.now() - U._deadline_started) >= DOWNLOAD_TIMEOUT_S
    local out_of_ticks = U._ticks >= DOWNLOAD_MAX_TICKS
    if timed_out or out_of_ticks then
        U._fail("descarga de '" .. tostring(U._current_relpath) .. "': tiempo agotado ("
              .. (timed_out and "reloj" or "iteraciones") .. ")")
        return
    end

    if not c:GetFinished() then return end

    local code, body = c:GetResponse()
    U._curl = nil
    if code ~= (eCurlCode and eCurlCode.CURLE_OK) or not body or body == "" then
        U._fail("descarga de '" .. U._current_relpath .. "': fallo de red (código " .. tostring(code) .. ")")
        return
    end

    -- Verificación exigida por PROYECTO.md §7 paso 4: la MISMA técnica que ya
    -- usa PizzaGames.lua para cargar módulos. Sólo compila, nunca ejecuta.
    local chunk, err = load(body, "@" .. U._current_relpath)
    if not chunk then
        U._fail(string.format("descarga de '%s': no compila -> %s", U._current_relpath, tostring(err)))
        return
    end

    U._download_results[U._current_relpath] = body
    Log.info("Updater", "Descargado y verificado: %s (%d bytes)", U._current_relpath, #body)
    U._start_next_download()
end

--==============================================================================
-- Fase 3: aplicar (respaldar y escribir). Si falla a mitad, restaura desde el
-- respaldo que acaba de crear: la actualización nunca deja el script peor de
-- lo que estaba (misma filosofía que stop(), trampa 5.5 de PROYECTO.md).
--==============================================================================

function U._restore_from(backup_dir, relpaths)
    for _, relpath in ipairs(relpaths) do
        local backup_path = backup_dir .. "\\" .. relpath:gsub("[/\\]", "_")
        local content = FileMgr.ReadFileContent(backup_path)
        if content and content ~= "" then
            pcall(FileMgr.WriteFileContent, U._local_path(relpath), content)
        end
    end
end

function U._apply_files()
    U.state = "APLICANDO"
    Log.info("Updater", "Todos los archivos verifican. Aplicando actualización...")

    if not (FileMgr and FileMgr.WriteFileContent and FileMgr.ReadFileContent) then
        U._fail("apply: FileMgr no disponible, no se puede escribir en disco")
        return
    end

    local backup_dir = U.lua_root .. "\\PizzaScript\\_backup\\" .. tostring(PG._VERSION)
    if FileMgr.CreateDir then FileMgr.CreateDir(backup_dir) end

    local backed_up, written = {}, {}
    local ok, err = pcall(function()
        for _, relpath in ipairs(U.remote_files) do
            local old = FileMgr.ReadFileContent(U._local_path(relpath))
            if old and old ~= "" then
                local backup_path = backup_dir .. "\\" .. relpath:gsub("[/\\]", "_")
                FileMgr.WriteFileContent(backup_path, old)
                backed_up[#backed_up + 1] = relpath
            end
        end
        for _, relpath in ipairs(U.remote_files) do
            FileMgr.WriteFileContent(U._local_path(relpath), U._download_results[relpath])
            written[#written + 1] = relpath
        end
    end)

    if not ok then
        Log.error("Updater", "Fallo aplicando la actualización a mitad: %s. Restaurando...", tostring(err))
        U._restore_from(backup_dir, written)
        U._fail("apply: fallo a mitad de la escritura, restaurado desde el respaldo")
        return
    end

    U.last_backup_dir = backup_dir
    U.applied_version = U.remote_version
    U.state = "HECHO"
    Log.info("Updater", "Actualización aplicada: %s -> %s. Recarga PizzaGames.lua desde el "
          .. "Lua Editor para que surta efecto.", PG._VERSION, U.remote_version)
    if GUI and GUI.AddToast then
        GUI.AddToast("PizzaGames", "Actualizado a " .. U.remote_version .. ". Recarga el script.", 8000)
    end
end

--- Botón "Actualizar ahora". Rechaza si hay un minijuego en curso: no se toca
--- disco a mitad de una partida activa.
function U.apply_update()
    if U.state ~= "DISPONIBLE" then
        Log.warn("Updater", "apply_update() ignorado: estado actual %s", U.state)
        return false
    end
    if PG.Runtime.state ~= PG.STATE.IDLE then
        Log.warn("Updater", "apply_update() rechazado: hay un minijuego en curso")
        if GUI and GUI.AddToast then
            GUI.AddToast("PizzaGames", "Termina o detén el minijuego antes de actualizar", 4000)
        end
        return false
    end
    if not U.remote_files or #U.remote_files == 0 then
        U._fail("apply_update: no hay lista de archivos remota")
        return false
    end

    U.state              = "DESCARGANDO"
    U._download_index    = 0
    U._download_results  = {}
    U._start_next_download()
    return true
end

--==============================================================================
-- Reversión manual
--==============================================================================

function U.rollback()
    if not U.last_backup_dir then
        Log.warn("Updater", "rollback() ignorado: no hay respaldo registrado en esta sesión")
        if GUI and GUI.AddToast then
            GUI.AddToast("PizzaGames", "No hay ninguna actualización que revertir en esta sesión", 4000)
        end
        return false
    end
    if PG.Runtime.state ~= PG.STATE.IDLE then
        Log.warn("Updater", "rollback() rechazado: hay un minijuego en curso")
        return false
    end

    local ok, err = pcall(function()
        for _, relpath in ipairs(U.remote_files) do
            local backup_path = U.last_backup_dir .. "\\" .. relpath:gsub("[/\\]", "_")
            local content = FileMgr.ReadFileContent(backup_path)
            if content and content ~= "" then
                local chunk, cerr = load(content, "@" .. relpath)
                if not chunk then
                    error("respaldo de '" .. relpath .. "' no compila: " .. tostring(cerr))
                end
                FileMgr.WriteFileContent(U._local_path(relpath), content)
            end
        end
    end)

    if not ok then
        Log.error("Updater", "rollback() falló: %s", tostring(err))
        if GUI and GUI.AddToast then GUI.AddToast("PizzaGames", "Revertir falló. Mira el log.", 5000) end
        return false
    end

    Log.info("Updater", "Reversión completada. Recarga PizzaGames.lua para volver a la versión anterior.")
    if GUI and GUI.AddToast then GUI.AddToast("PizzaGames", "Revertido. Recarga el script.", 6000) end
    return true
end

--==============================================================================
-- Bucle: llamar una vez por tick desde Script.RegisterLooped (nunca bloquea)
--==============================================================================

function U.tick()
    if U.state == "CHECKING" then
        pump_check()
    elseif U.state == "DESCARGANDO" then
        pump_download()
    end
end

--==============================================================================
-- Panel de salud
--==============================================================================

function U.status_rows()
    local rows = {
        { k = "Versión local",  v = tostring(PG._VERSION) },
        { k = "Actualizador",   v = U.state },
    }
    if U.remote_version then
        rows[#rows + 1] = { k = "Última remota", v = tostring(U.remote_version) }
    end
    if U.last_error then
        rows[#rows + 1] = { k = "Últ. error act.", v = tostring(U.last_error) }
    end
    return rows
end

return U
end
