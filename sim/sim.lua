--[[
================================================================================
  sim.lua — simulador mínimo de la API de Cherax, para probar PizzaGames
  fuera de GTA con un intérprete Lua 5.4 normal.

  Se reconstruyó desde cero para esta sesión (no existía antes, pese a que
  PROYECTO.md lo mencionaba como si ya existiera). Cubre lo que necesita este
  encargo: compilar los 9 archivos de /src y ejercitar la lógica del
  auto-actualizador (PizzaGames_Updater.lua) sin tocar disco de verdad ni red
  de verdad. NO simula FeatureMgr/ClickGUI/GTA/natives ni el ciclo de los
  cuatro minijuegos — eso queda para una sesión futura si hace falta.

  Uso:  local Env = require("sim")  (ejecutado desde la carpeta sim/, o con
        el intérprete apuntando aquí)
================================================================================
]]

local Env = {}

-- Rutas relativas a la ubicación de este archivo, no al directorio de trabajo
-- actual: así `lua sim/sim.lua` y `cd sim && lua run_tests.lua` funcionan igual.
local SIM_DIR   = (debug.getinfo(1, "S").source:match("@?(.*[/\\])")) or "./"
Env.SIM_DIR     = SIM_DIR
-- Barra normal, no contrabarra: esto son rutas de disco reales que
-- lee/compila el propio simulador (io.open/load), y tienen que funcionar
-- igual en Windows (donde se desarrolla) que en el runner de CI (Linux,
-- donde '\' no separa carpetas). Las rutas *dentro* de la simulación (vfs,
-- GetMenuRootPath) sí usan '\', porque representan una instalación real de
-- Cherax en Windows y el propio código bajo prueba las construye así.
Env.REPO_ROOT   = SIM_DIR .. "../"
Env.SRC_DIR     = Env.REPO_ROOT .. "src/"

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("a")
    f:close()
    return content
end
Env.read_file = read_file

--==============================================================================
-- Mocks de la API global de Cherax
--==============================================================================

--- Instala los mocks en _G. Devuelve un "handle" con inspección para los
--- tests (vfs, cola de curl, toasts, llamadas) y una función restore() que
--- deja _G como estaba (útil si se llama varias veces en el mismo proceso).
function Env.install_mocks()
    local saved = {}
    local NAMES = { "Utils", "FileMgr", "Curl", "GUI", "Logger",
                     "eCurlOption", "eCurlCode", "ShouldUnload" }
    for _, n in ipairs(NAMES) do saved[n] = _G[n] end

    local handle = { vfs = {}, curl_queue = {}, curl_calls = {}, toasts = {} }

    -- Utils.Joaat: no necesita coincidir con el hash real de GTA (JOAAT), sólo
    -- ser determinista para que el mismo nombre produzca siempre el mismo
    -- valor dentro de la simulación.
    _G.Utils = { Joaat = function(s)
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
        return h
    end }

    -- FileMgr: sistema de archivos en memoria. Las claves son las rutas tal
    -- cual las pide el código (con backslashes de Windows).
    _G.FileMgr = {
        WriteFileContent = function(path, content) handle.vfs[path] = content; return true end,
        ReadFileContent  = function(path) return handle.vfs[path] end,
        DoesFileExist    = function(path) return handle.vfs[path] ~= nil end,
        CreateDir        = function(_) return true end,
        GetMenuRootPath  = function() return "C:\\FakeCherax" end,
    }

    -- Curl: async simulado por ticks. Cada Perform() consume la siguiente
    -- entrada de curl_queue (FIFO); si no hay ninguna, falla como si no
    -- hubiera red. { delay_ticks=N, code=eCurlCode.CURLE_OK, body="...",
    --                 never=true (nunca termina, para probar el freno de
    --                 iteraciones) }
    _G.eCurlOption = { CURLOPT_URL = "URL", CURLOPT_USERAGENT = "UA" }
    _G.eCurlCode   = { CURLE_OK = 0 }

    _G.Curl = { Easy = function()
        local self = { _ticks = 0 }
        function self:Setopt(opt, val)
            if opt == _G.eCurlOption.CURLOPT_URL then self._url = val end
        end
        function self:Perform()
            handle.curl_calls[#handle.curl_calls + 1] = self._url
            self._resp = table.remove(handle.curl_queue, 1)
                      or { delay_ticks = 0, code = 99, body = nil }
        end
        function self:GetFinished()
            if self._resp.never then return false end
            self._ticks = self._ticks + 1
            return self._ticks > (self._resp.delay_ticks or 0)
        end
        function self:GetResponse()
            return self._resp.code, self._resp.body
        end
        return self
    end }

    _G.GUI = { AddToast = function(title, text, ms, pos)
        handle.toasts[#handle.toasts + 1] = { title = title, text = text }
    end }

    _G.Logger = {
        LogInfo  = function(_) end,
        LogError = function(msg) io.stderr:write("[Logger ERROR] " .. tostring(msg) .. "\n") end,
    }

    _G.ShouldUnload = function() return false end

    function handle.restore()
        for _, n in ipairs(NAMES) do _G[n] = saved[n] end
    end

    return handle
end

--==============================================================================
-- Carga de módulos reales
--==============================================================================

--- Compila (NO ejecuta) el contenido de un archivo, igual que hace
--- PizzaGames.lua al cargar módulos y PizzaGames_Updater.lua al verificar
--- descargas. Devuelve (chunk) o (nil, error).
function Env.compile(path)
    local content, err = read_file(path)
    if not content then return nil, "no se pudo leer: " .. tostring(err) end
    return load(content, "@" .. path)
end

--- Carga y ejecuta PizzaGames_Core.lua real para obtener un PG de verdad
--- (no un mock): Core.lua es Lua puro salvo por PG.now(), que ya degrada
--- solas a os.time() si no hay 'game_timer' resuelto, así que funciona
--- igual aquí que dentro de Cherax cuando faltan capacidades.
function Env.load_core()
    local chunk, err = Env.compile(Env.SRC_DIR .. "PizzaScript/PizzaGames_Core.lua")
    if not chunk then error("PizzaGames_Core.lua no compila: " .. tostring(err)) end
    return chunk()
end

--- Carga PizzaGames_Updater.lua real y lo instancia contra un PG dado.
function Env.load_updater(PG, opts)
    local chunk, err = Env.compile(Env.SRC_DIR .. "PizzaScript/PizzaGames_Updater.lua")
    if not chunk then error("PizzaGames_Updater.lua no compila: " .. tostring(err)) end
    local factory = chunk()
    return factory(PG, opts)
end

--- Todos los archivos listados en version.json, ruta completa dentro de /src.
function Env.all_src_files(U)
    local body = read_file(Env.REPO_ROOT .. "version.json")
    assert(body, "no se pudo leer version.json")
    local version, files = U.parse_version_json(body)
    local out = {}
    for _, rel in ipairs(files) do
        out[#out + 1] = { rel = rel, path = Env.SRC_DIR .. rel }
    end
    return version, out
end

return Env
