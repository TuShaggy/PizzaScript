--[[
================================================================================
  sim.lua — simulador mínimo de la API de Cherax, para probar PizzaScript.lua
  fuera de GTA con un intérprete Lua 5.4 normal.

  Cubre: compilar el script y ejercitar su lógica de auto-actualización
  (descarga, verificación con load(), respaldo) sin tocar disco de verdad ni
  red de verdad. NO simula lectura de stats/natives de verdad — eso sólo
  puede confirmarse dentro del propio juego (ver la cabecera de
  PizzaScript.lua para qué está verificado y qué no).

  Uso:  local Env = dofile("sim.lua")  (ejecutado desde la carpeta sim/, o
        con el intérprete apuntando aquí)
================================================================================
]]

local Env = {}

-- Rutas relativas a la ubicación de este archivo, no al directorio de trabajo
-- actual: así `lua sim/run_tests.lua` y `cd sim && lua run_tests.lua`
-- funcionan igual. Barra normal, no contrabarra: esto son rutas de disco
-- reales que lee/compila el propio simulador (io.open/load), y tienen que
-- funcionar igual en Windows (donde se desarrolla) que en el runner de CI
-- (Linux, donde '\' no separa carpetas). Las rutas *dentro* de la
-- simulación (vfs, GetMenuRootPath) sí usan '\', porque representan una
-- instalación real de Cherax en Windows y el propio código bajo prueba las
-- construye así.
local SIM_DIR   = (debug.getinfo(1, "S").source:match("@?(.*[/\\])")) or "./"
Env.SIM_DIR     = SIM_DIR
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
-- Mocks de la API global de Cherax: FileMgr/Curl/GUI/Logger/Utils
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
-- Mocks de la superficie de Cherax que PizzaScript.lua necesita para
-- arrancar (env_check exige FeatureMgr/ClickGUI/Utils/eFeatureType/Script/
-- Natives): FeatureMgr/ClickGUI/eFeatureType/Natives/Script/ImGui. No están
-- en install_mocks() porque las pruebas de auto-actualización son las
-- únicas que necesitan que el script llegue a arrancar de verdad.
--==============================================================================

--- Devuelve (loops, callbacks, teardown). 'loops' recoge las funciones
--- registradas con Script.RegisterLooped (para poder "avanzar frames" a
--- mano); 'callbacks' permite invocar el callback de un botón por su hash,
--- como si el usuario lo hubiera pulsado.
function Env.install_cherax_ui_mocks()
    local loops, callbacks = {}, {}

    _G.Script = {
        RegisterLooped = function(fn) loops[#loops + 1] = fn; return #loops end,
        Yield = function(_) end,
    }
    _G.Natives = {
        InvokeInt = function() return 0 end,
        InvokeBool = function() return false end,
        InvokeVoid = function() end,
        InvokeString = function() return nil end,
        InvokeFloat = function() return 0.0 end,
        InvokeV3 = function() return nil end,
    }
    _G.eFeatureType = { Button = 1, Toggle = 2 }
    _G.FeatureMgr = {
        AddFeature = function(hash, _name, _ftype, _desc, cb, _thread)
            assert(type(hash) == "number", "FeatureMgr.AddFeature: el hash debe ser un número, se recibió " .. type(hash))
            callbacks[hash] = cb
            local f = {}
            function f:SetDefaultValue(_) return f end
            function f:SetSaveable(_) return f end
            function f:Reset() return f end
            function f:IsToggled() return false end
            return f
        end,
        -- Siempre activado a propósito: las pruebas quieren que el toggle
        -- "buscar al iniciar" dispare la comprobación de versión.
        IsFeatureToggled = function(hash)
            assert(type(hash) == "number", "FeatureMgr.IsFeatureToggled: el hash debe ser un número, se recibió " .. type(hash))
            return true
        end,
    }
    _G.ClickGUI = {
        AddTab = function(_name, _fn) end,
        BeginCustomChildWindow = function(_) return false end,
        EndCustomChildWindow = function() end,
        -- El error real que motivó esto: pasar el objeto Feature (lo que
        -- devuelve AddFeature) en vez de su hash revienta en Cherax de
        -- verdad ("sol: no matching function call...") y mata la corrutina
        -- de la pestaña. El mock lo valida para que un fallo así se vea en
        -- las pruebas, no sólo jugando.
        RenderFeature = function(hash)
            assert(type(hash) == "number", "ClickGUI.RenderFeature: se esperaba el hash (número), se recibió " .. type(hash) .. " — ¿se pasó el objeto Feature por error?")
        end,
    }
    _G.ImGui = { Text = function(_) end }

    local function teardown()
        _G.Script, _G.Natives, _G.eFeatureType = nil, nil, nil
        _G.FeatureMgr, _G.ClickGUI, _G.ImGui = nil, nil, nil
    end

    return loops, callbacks, teardown
end

--==============================================================================
-- Compilación
--==============================================================================

--- Compila (NO ejecuta) el contenido de un archivo, igual que hace
--- PizzaScript.lua al verificar una descarga antes de sustituirse. Devuelve
--- (chunk) o (nil, error).
function Env.compile(path)
    local content, err = read_file(path)
    if not content then return nil, "no se pudo leer: " .. tostring(err) end
    return load(content, "@" .. path)
end

return Env
