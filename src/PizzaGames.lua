--[[
================================================================================
  PizzaGames  —  punto de entrada / instalador de un solo archivo
  Ejecuta SÓLO este archivo desde la pestaña Lua Editor de Cherax.

  POR QUÉ FALLABA LA VERSIÓN ANTERIOR
  -----------------------------------
  Usaba loadfile("PizzaGames_Core.lua") con ruta relativa. Cherax no resuelve
  las rutas relativas contra la carpeta del script, así que no encontraba nada.
  Peor aún: el fallo se reportaba con print(), que no llega al log de Cherax.
  Resultado: "Successfully loaded" y luego silencio absoluto.

  Ahora:
   - Se construyen rutas ABSOLUTAS a partir de FileMgr.GetMenuRootPath().
   - Se prueban varias ubicaciones y se registra CADA intento.
   - Todo error va por Logger.LogError, visible en Cherax.log.

  DISTRIBUCIÓN DE UN SOLO ARCHIVO
  --------------------------------
  Si los demás módulos NO están en el disco (primera vez que alguien coloca
  sólo este archivo), se descargan automáticamente desde el repositorio antes
  de arrancar. Cada archivo descargado se verifica con load() antes de
  guardarse — la misma técnica que ya usa load_module() más abajo y que usa
  PizzaGames_Updater.lua para las actualizaciones — así que un archivo roto o
  una descarga a medias nunca deja instalado algo que no compila.

  Una vez que los módulos ya existen en disco, este archivo NO vuelve a
  descargar nada por su cuenta: las actualizaciones posteriores pasan por la
  pestaña "Actualizaciones" (PizzaGames_Updater.lua), que sí compara
  versiones y tiene UI. Este mecanismo es sólo para pasar de "nada instalado"
  a "instalado", una vez.
================================================================================
]]

-- Nombre de la subcarpeta dentro de Documents/Cherax/Lua/
-- Deja "" si prefieres los archivos directamente en Lua/
local FOLDER = "PizzaScript"

local MODULES = {
    "PizzaGames_Core.lua",
    "PizzaGames_Natives.lua",
    "PizzaGames_Cinema.lua",
    "PizzaGames_Prefabs.lua",
    "PizzaGames_Scene.lua",
    "PizzaGames_Games.lua",
    "PizzaGames_Updater.lua",
    "PizzaGames_Cherax.lua",
}

-- Debe coincidir con REPO_RAW en PizzaGames_Updater.lua. Duplicado a
-- propósito: este archivo tiene que poder descargar el resto ÉL SOLO, antes
-- de que PizzaGames_Updater.lua exista siquiera en disco.
local REPO_RAW = "https://raw.githubusercontent.com/TuShaggy/PizzaScript/main/"

--==============================================================================
-- Registro temprano  (antes de que exista el logger del framework)
--==============================================================================

local boot_log = {}
local function blog(level, msg)
    local line = string.format("[PizzaGames][Boot][%s] %s", level, msg)
    boot_log[#boot_log + 1] = line
    if Logger then
        if level == "ERROR" then Logger.LogError(line) else Logger.LogInfo(line) end
    else
        print(line)
    end
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

--- Devuelve la lista de carpetas candidatas, la más probable primero.
local function candidate_dirs()
    local dirs = {}

    if FileMgr and FileMgr.GetMenuRootPath then
        local root = FileMgr.GetMenuRootPath()
        if root and root ~= "" then
            blog("INFO", "Raíz del menú: " .. root)
            dirs[#dirs + 1] = join(root, "Lua", FOLDER)
            dirs[#dirs + 1] = join(root, "Lua")
            dirs[#dirs + 1] = join(root, FOLDER)
            dirs[#dirs + 1] = root
        else
            blog("WARN", "GetMenuRootPath() devolvió vacío")
        end
    else
        blog("WARN", "FileMgr no disponible; sólo se probarán rutas relativas")
    end

    -- Respaldos relativos, por si Cherax sí resuelve contra la carpeta del script
    dirs[#dirs + 1] = FOLDER
    dirs[#dirs + 1] = ""
    return dirs
end

--- Localiza la carpeta que contiene los módulos.
local function find_base_dir()
    local probe = MODULES[1]

    for _, dir in ipairs(candidate_dirs()) do
        local path = (dir == "") and probe or join(dir, probe)

        if FileMgr and FileMgr.DoesFileExist then
            if FileMgr.DoesFileExist(path) then
                blog("INFO", "Módulos encontrados en: " .. (dir == "" and "(relativa)" or dir))
                return dir
            end
            blog("INFO", "No está en: " .. path)
        else
            -- Sin FileMgr sólo queda intentar abrirlo
            local f = io.open and io.open(path, "r")
            if f then f:close(); blog("INFO", "Encontrado (io) en: " .. path); return dir end
        end
    end

    return nil
end

--- Carpeta por defecto donde instalar si no se encuentra nada: el mismo
--- primer candidato que probaría find_base_dir(). Sin FileMgr.GetMenuRootPath()
--- no hay forma fiable de saber dónde escribir nada.
local function default_install_dir()
    if FileMgr and FileMgr.GetMenuRootPath then
        local root = FileMgr.GetMenuRootPath()
        if root and root ~= "" then
            return join(root, "Lua", FOLDER)
        end
    end
    return nil
end

--==============================================================================
-- Carga de módulos
--==============================================================================

local function load_module(dir, filename)
    local path = (dir == "") and filename or join(dir, filename)

    -- Vía preferente: leer el contenido y compilarlo. Funciona siempre que
    -- FileMgr esté disponible y no depende de que loadfile exista en el
    -- sandbox de Lua del menú.
    if FileMgr and FileMgr.ReadFileContent then
        local content = FileMgr.ReadFileContent(path)
        if content and content ~= "" then
            local chunk, err = load(content, "@" .. filename)
            if not chunk then
                blog("ERROR", string.format("Error de sintaxis en '%s': %s", filename, tostring(err)))
                return nil
            end
            local ok, result = pcall(chunk)
            if not ok then
                blog("ERROR", string.format("Error al ejecutar '%s': %s", filename, tostring(result)))
                return nil
            end
            blog("INFO", string.format("Cargado %s (%d bytes)", filename, #content))
            return result
        end
        blog("ERROR", "No se pudo leer: " .. path)
        return nil
    end

    -- Alternativa: loadfile, si está disponible
    if loadfile then
        local chunk, err = loadfile(path)
        if not chunk then
            blog("ERROR", string.format("loadfile falló en '%s': %s", path, tostring(err)))
            return nil
        end
        local ok, result = pcall(chunk)
        if not ok then
            blog("ERROR", string.format("Error al ejecutar '%s': %s", filename, tostring(result)))
            return nil
        end
        blog("INFO", "Cargado (loadfile) " .. filename)
        return result
    end

    blog("ERROR", "No hay forma de cargar archivos: ni FileMgr ni loadfile")
    return nil
end

--==============================================================================
-- Descarga inicial (sólo si no se encontró ningún módulo en disco)
--
--   No puede bloquear (trampa 5.3 de PROYECTO.md), así que se apoya en
--   Script.RegisterLooped igual que el resto del framework, en vez de
--   inventar un mecanismo de espera nuevo. No reutiliza
--   PizzaGames_Updater.lua a propósito: ese módulo es UNO de los que hay
--   que descargar, así que no puede existir todavía. Cada archivo se
--   verifica con load() antes de escribirse; si cualquiera falla, se aborta
--   sin dejar una instalación a medias con módulos mezclados.
--==============================================================================

local function bootstrap_download(target_dir, on_done)
    if not (Curl and Curl.Easy) then
        blog("ERROR", "No se encontraron los módulos y Curl no está disponible para descargarlos")
        on_done(false)
        return
    end
    if not (Script and Script.RegisterLooped) then
        blog("ERROR", "No se encontraron los módulos y Script.RegisterLooped no está disponible")
        on_done(false)
        return
    end
    if not (FileMgr and FileMgr.WriteFileContent) then
        blog("ERROR", "No se encontraron los módulos y FileMgr no puede escribirlos")
        on_done(false)
        return
    end

    blog("INFO", "Módulos no encontrados. Descargando " .. #MODULES .. " archivos a: " .. target_dir)
    if FileMgr.CreateDir then FileMgr.CreateDir(target_dir) end

    -- Dos frenos independientes por archivo (trampa 5.4): ni el reloj ni el
    -- contador de iteraciones pueden ser el único límite.
    local TIMEOUT_S, MAX_TICKS = 20, 2400

    local index = 0
    local curl, ticks, started_at, finished = nil, 0, 0, false

    local function start_next()
        index = index + 1
        local name = MODULES[index]
        if not name then
            finished = true
            blog("INFO", "Descarga inicial completa: " .. #MODULES .. " módulos")
            on_done(true)
            return
        end

        ticks, started_at = 0, os.time()
        local url = REPO_RAW .. "src/PizzaScript/" .. name
        local ok, c_or_err = pcall(function()
            local h = Curl.Easy()
            h:Setopt(eCurlOption.CURLOPT_URL, url)
            h:Setopt(eCurlOption.CURLOPT_USERAGENT, "PizzaGames-Bootstrap")
            h:Perform()
            return h
        end)
        if not ok then
            finished = true
            blog("ERROR", "No se pudo iniciar la descarga de " .. name .. ": " .. tostring(c_or_err))
            on_done(false)
            return
        end
        curl = c_or_err
    end

    Script.RegisterLooped(function()
        if finished or not curl then return end

        ticks = ticks + 1
        local timed_out   = (os.time() - started_at) >= TIMEOUT_S
        local out_of_ticks = ticks >= MAX_TICKS
        if timed_out or out_of_ticks then
            finished = true
            blog("ERROR", "Tiempo agotado descargando " .. tostring(MODULES[index]) .. " ("
                       .. (timed_out and "reloj" or "iteraciones") .. ")")
            on_done(false)
            return
        end

        if not curl:GetFinished() then return end

        local code, body = curl:GetResponse()
        curl = nil
        if code ~= (eCurlCode and eCurlCode.CURLE_OK) or not body or body == "" then
            finished = true
            blog("ERROR", "Fallo de red descargando " .. MODULES[index]
                       .. " (código " .. tostring(code) .. ")")
            on_done(false)
            return
        end

        local name = MODULES[index]
        local chunk, err = load(body, "@" .. name)
        if not chunk then
            finished = true
            blog("ERROR", string.format("El archivo descargado '%s' no compila: %s", name, tostring(err)))
            on_done(false)
            return
        end

        FileMgr.WriteFileContent(join(target_dir, name), body)
        blog("INFO", string.format("Descargado y verificado: %s (%d bytes)", name, #body))
        start_next()
    end)

    start_next()
end

--==============================================================================
-- Resto del arranque, una vez los módulos existen en disco (ya estuvieran o
-- se acaben de descargar).
--==============================================================================

local function finish_boot(base)
    local loaded = {}
    for _, name in ipairs(MODULES) do
        loaded[name] = load_module(base, name)
    end

    local PG = loaded["PizzaGames_Core.lua"]
    if not PG then
        blog("ERROR", "El núcleo no cargó. Abortando.")
        if GUI and GUI.AddToast then
            GUI.AddToast("PizzaGames", "Fallo al cargar el núcleo. Mira Cherax.log", 6000)
        end
        return
    end

    -- A partir de aquí el logger del framework ya existe: volcamos el registro
    -- temprano para tenerlo todo en un mismo sitio.
    for _, line in ipairs(boot_log) do PG.Log.debug("Boot", "%s", line) end

    local Prefabs  = loaded["PizzaGames_Prefabs.lua"]
    local SceneM   = loaded["PizzaGames_Scene.lua"]
    local GamesM   = loaded["PizzaGames_Games.lua"]
    local CheraxM  = loaded["PizzaGames_Cherax.lua"]
    local NAT      = loaded["PizzaGames_Natives.lua"]
    local CinemaM  = loaded["PizzaGames_Cinema.lua"]
    local UpdaterM = loaded["PizzaGames_Updater.lua"]

    if NAT then
        PG.Natives = NAT
        PG.Log.info("Boot", "Natives cargadas (invocación por hash)")
    else
        PG.Log.error("Boot", "PizzaGames_Natives.lua no cargó. Sin él no hay cámaras, "
                  .. "marcadores, blips ni limpieza de props.")
    end

    if not (Prefabs and SceneM and GamesM) then
        PG.Log.error("Boot", "Faltan módulos: prefabs=%s scene=%s games=%s",
                     tostring(Prefabs ~= nil), tostring(SceneM ~= nil), tostring(GamesM ~= nil))
        return
    end

    local Scene = SceneM(PG)
    PG.Scene, PG.Prefabs = Scene, Prefabs
    local Cinema = CinemaM and CinemaM(PG, NAT)
    PG.Cinema = Cinema
    if not Cinema then
        PG.Log.warn("Boot", "Módulo de cine ausente: sin intros ni títulos")
    end

    GamesM(PG, Scene, Prefabs, Cinema)

    -- Autotest ampliado: núcleo + escenarios + geometría de todas las pistas
    local core_self_test = PG.self_test
    function PG.self_test()
        local r  = core_self_test()
        local sc = Scene.self_test()

        local bad = 0
        for _, id in ipairs(Prefabs.track_ids()) do
            local track = Prefabs.TRACKS[id].build({ x = 0, y = 0, z = 0 }, 0)
            local ok, problems, stats = Prefabs.validate(track)
            if ok then
                PG.Log.info("SelfTest", "PASA  pista '%s': %.0f m, %d nodos, cierre %.1f m",
                            id, track.length, stats.nodes, track.gap)
            else
                bad = bad + 1
                PG.Log.error("SelfTest", "FALLA pista '%s': %s", id, table.concat(problems, "; "))
            end
        end

        if NAT and NAT.verify then
            local v = NAT.verify()
            if v.failed == 0 then
                PG.Log.info("SelfTest", "PASA  natives: %d comprobaciones", v.ok)
            else
                bad = bad + 1
                PG.Log.error("SelfTest", "FALLA natives: %s", table.concat(v.problems, "; "))
            end
        end

        PG.Log.info("SelfTest", "%s", Scene.Models.report())
        PG.Log.info("SelfTest", "===== TOTAL: %d correctas, %d fallidas =====",
                    r.passed + sc.passed, r.failed + sc.failed + bad)
        return r
    end

    -- Raíz de instalación (carpeta que contiene ESTE archivo, PizzaGames.lua),
    -- deducida a partir de 'base' (la carpeta donde están los módulos). El
    -- auto-actualizador la necesita para saber dónde escribir. Si los módulos
    -- están en '<raíz>\PizzaScript', la raíz es el nivel de arriba; si están
    -- sueltos junto a PizzaGames.lua, la raíz es la propia 'base'.
    local lua_root = base
    if FOLDER ~= "" then
        local suffix = "\\" .. FOLDER
        if base:sub(-#suffix) == suffix then
            lua_root = base:sub(1, -#suffix - 1)
        end
    end

    if UpdaterM then
        PG.Updater = UpdaterM(PG, { lua_root = lua_root })
        PG.Log.info("Boot", "Auto-actualizador cargado (raíz local: %s)", lua_root)
    else
        PG.Log.warn("Boot", "PizzaGames_Updater.lua no cargó. Sin auto-actualizador.")
    end

    -- El enlace con Cherax va DESPUÉS de registrar los minijuegos: la pestaña se
    -- construye recorriendo el registro y si no, saldría vacía.
    if CheraxM then
        PG.Cherax = CheraxM(PG, NAT, Cinema)
        if PG.Cherax.install() then
            PG.Log.info("Boot", "PizzaGames listo. Pestaña 'PizzaGames' en Lua Content.")
            if GUI and GUI.AddToast then
                GUI.AddToast("PizzaGames", "Cargado. Pestaña 'PizzaGames' disponible.", 4000)
            end
            return PG
        end
        PG.Log.error("Boot", "El enlace con Cherax falló; se prueba el modo genérico")
    end

    return PG.init()
end

--==============================================================================
-- Arranque
--==============================================================================

blog("INFO", "Iniciando PizzaGames...")

local base = find_base_dir()

if base then
    return finish_boot(base)
end

local target = default_install_dir()
if not target then
    blog("ERROR", "NO SE ENCONTRARON LOS MÓDULOS y no se pudo determinar dónde instalarlos.")
    blog("ERROR", "FileMgr.GetMenuRootPath() no está disponible.")
    if GUI and GUI.AddToast then
        GUI.AddToast("PizzaGames", "No se encontraron los módulos. Mira Cherax.log", 6000)
    end
    return
end

bootstrap_download(target, function(ok)
    if ok then
        finish_boot(target)
    else
        blog("ERROR", "La descarga inicial de módulos falló. Revisa la conexión y vuelve a "
                   .. "cargar PizzaGames.lua desde el Lua Editor para reintentarlo.")
        if GUI and GUI.AddToast then
            GUI.AddToast("PizzaGames", "Descarga inicial fallida. Mira Cherax.log", 6000)
        end
    end
end)
