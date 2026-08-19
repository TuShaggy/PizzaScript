--[[
================================================================================
  PizzaGames  —  punto de entrada
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
-- Arranque
--==============================================================================

blog("INFO", "Iniciando PizzaGames...")

local base = find_base_dir()
if not base then
    blog("ERROR", "NO SE ENCONTRARON LOS MÓDULOS.")
    blog("ERROR", "Coloca los 6 archivos en Documents\\Cherax\\Lua\\" .. FOLDER)
    blog("ERROR", "Si están en otra carpeta, edita FOLDER en la cabecera de este archivo.")
    if GUI and GUI.AddToast then
        GUI.AddToast("PizzaGames", "No se encontraron los módulos. Mira Cherax.log", 6000)
    end
    return
end

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
-- deducida a partir de 'base' (la carpeta donde se encontraron los módulos).
-- El auto-actualizador la necesita para saber dónde escribir. Si los módulos
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
