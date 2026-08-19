--[[
================================================================================
  run_tests.lua — pruebas sobre sim.lua

  Cubre: que los 9 archivos de /src compilan, el comparador de versiones, el
  parser de version.json, y el auto-actualizador completo (check, descarga,
  verificación por load(), aplicación con respaldo, reversión, y los dos
  frenos de las esperas de red). No abre GTA ni necesita Cherax instalado.

  Uso:  lua run_tests.lua   (desde esta carpeta, o "lua sim/run_tests.lua"
        desde la raíz del repo)
================================================================================
]]

local DIR = (debug.getinfo(1, "S").source:match("@?(.*[/\\])")) or "./"
local Env = dofile(DIR .. "sim.lua")

local total, failed = 0, 0
local function check(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        print("PASA  " .. name)
    else
        failed = failed + 1
        print("FALLA " .. name .. " -> " .. tostring(err))
    end
end

local function pump(U, n)
    for _ = 1, (n or 200) do U.tick() end
end

--==============================================================================
-- 1. Los 9 archivos de /src compilan (equivalente a luac -p)
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, { lua_root = "C:\\FakeInstall\\Lua" })
    local _, files = Env.all_src_files(U)
    for _, f in ipairs(files) do
        check("compila: " .. f.rel, function()
            local chunk, err = Env.compile(f.path)
            assert(chunk, err)
        end)
    end
    mocks.restore()
end

--==============================================================================
-- 2. Comparador de versiones
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, {})
    check("version_gt: 1.0.1 > 1.0.0", function() assert(U.version_gt("1.0.1", "1.0.0") == true) end)
    check("version_gt: 1.0.0 > 1.0.0 es falso", function() assert(U.version_gt("1.0.0", "1.0.0") == false) end)
    check("version_gt: 0.9.9 > 1.0.0 es falso", function() assert(U.version_gt("0.9.9", "1.0.0") == false) end)
    check("version_gt es numerico, no lexicografico (1.2 vs 1.10)", function()
        assert(U.version_gt("1.2", "1.10") == false)
        assert(U.version_gt("1.10", "1.2") == true)
    end)
    mocks.restore()
end

--==============================================================================
-- 3. Parser de version.json (extractor propio, no JSON general — ver Updater)
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, {})
    check("parse_version_json extrae version, files y notas", function()
        local body = [[{
          "version": "2.3.4",
          "files": ["a.lua", "b/c.lua"],
          "notas": "prueba"
        }]]
        local version, files, notas = U.parse_version_json(body)
        assert(version == "2.3.4", version)
        assert(#files == 2, #files)
        assert(files[1] == "a.lua" and files[2] == "b/c.lua")
        assert(notas == "prueba")
    end)
    check("parse_version_json lanza con JSON incompleto", function()
        local ok = pcall(U.parse_version_json, "{}")
        assert(ok == false)
    end)
    mocks.restore()
end

--==============================================================================
-- 4. check(): sin Curl disponible no revienta
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, { lua_root = "C:\\FakeInstall\\Lua" })
    local real_curl = Curl
    _G.Curl = nil
    check("check() sin Curl devuelve false y deja el estado en IDLE", function()
        assert(U.check() == false)
        assert(U.state == "IDLE")
    end)
    _G.Curl = real_curl
    mocks.restore()
end

--==============================================================================
-- 5. check(): version remota igual a la local -> no ofrece nada
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, { lua_root = "C:\\FakeInstall\\Lua" })
    mocks.curl_queue[1] = {
        delay_ticks = 2, code = eCurlCode.CURLE_OK,
        body = string.format('{"version":"%s","files":["x.lua"],"notas":""}', PG._VERSION),
    }
    check("check() con la misma version deja el estado en IDLE", function()
        assert(U.check() == true)
        pump(U, 10)
        assert(U.state == "IDLE", U.state)
        assert(U.remote_version == PG._VERSION)
    end)
    mocks.restore()
end

--==============================================================================
-- 6. Ciclo feliz completo: version nueva -> descarga -> aplica -> revierte
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, { lua_root = "C:\\FakeInstall\\Lua" })
    local _, files = Env.all_src_files(U)

    -- "Disco" sembrado con contenido antiguo distinto, para comprobar después
    -- que el respaldo lo conservó tal cual.
    for _, f in ipairs(files) do
        mocks.vfs[U._local_path(f.rel)] = "-- version vieja de " .. f.rel
    end

    local files_json = {}
    for _, f in ipairs(files) do files_json[#files_json + 1] = '"' .. f.rel .. '"' end

    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK,
        body = string.format('{"version":"9.9.9","files":[%s],"notas":"prueba"}',
                              table.concat(files_json, ",")),
    }
    for _, f in ipairs(files) do
        mocks.curl_queue[#mocks.curl_queue + 1] = {
            delay_ticks = 1, code = eCurlCode.CURLE_OK, body = Env.read_file(f.path),
        }
    end

    check("check() + apply_update() deja HECHO y escribe el vfs con el contenido real", function()
        assert(U.check() == true)
        pump(U, 10)
        assert(U.state == "DISPONIBLE", U.state)

        assert(U.apply_update() == true)
        pump(U, 400)
        assert(U.state == "HECHO", U.state .. " / " .. tostring(U.last_error))

        for _, f in ipairs(files) do
            assert(mocks.vfs[U._local_path(f.rel)] == Env.read_file(f.path),
                   "no se escribió correctamente: " .. f.rel)
        end
    end)

    check("el respaldo conserva el contenido antiguo de cada archivo", function()
        for _, f in ipairs(files) do
            local backup_path = U.last_backup_dir .. "\\" .. f.rel:gsub("[/\\]", "_")
            assert(mocks.vfs[backup_path] == "-- version vieja de " .. f.rel,
                   "respaldo ausente o incorrecto para " .. f.rel)
        end
    end)

    check("rollback() restaura el contenido anterior", function()
        assert(U.rollback() == true)
        for _, f in ipairs(files) do
            assert(mocks.vfs[U._local_path(f.rel)] == "-- version vieja de " .. f.rel,
                   "rollback no restauró " .. f.rel)
        end
    end)

    mocks.restore()
end

--==============================================================================
-- 7. Un archivo que no compila aborta el lote entero sin tocar disco
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, { lua_root = "C:\\FakeInstall\\Lua" })

    mocks.vfs[U._local_path("a.lua")] = "-- vieja a"
    mocks.vfs[U._local_path("b.lua")] = "-- vieja b"

    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK,
        body = '{"version":"9.9.9","files":["a.lua","b.lua"],"notas":""}',
    }
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK, body = "return 1",   -- a.lua: OK
    }
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK, body = "this is not $$$ lua (((", -- b.lua: roto
    }

    check("archivo que no compila deja ERROR sin tocar el vfs", function()
        assert(U.check() == true)
        pump(U, 10)
        assert(U.state == "DISPONIBLE")
        assert(U.apply_update() == true)
        pump(U, 20)
        assert(U.state == "ERROR", U.state)
        assert(mocks.vfs[U._local_path("a.lua")] == "-- vieja a", "a.lua se tocó pese al fallo")
        assert(mocks.vfs[U._local_path("b.lua")] == "-- vieja b", "b.lua se tocó pese al fallo")
    end)

    mocks.restore()
end

--==============================================================================
-- 8. Freno de iteraciones: una descarga que nunca termina no cuelga el bucle
--==============================================================================
do
    local mocks = Env.install_mocks()
    local PG = Env.load_core()
    local U  = Env.load_updater(PG, { lua_root = "C:\\FakeInstall\\Lua",
                                        download_max_ticks = 5, download_timeout_s = 999999 })
    mocks.curl_queue[1] = { never = true }

    check("una peticion que nunca termina se aborta por el tope de iteraciones", function()
        assert(U.check() == true)
        pump(U, 5)
        assert(U.state == "ERROR", U.state)
        assert(tostring(U.last_error):find("agotado"), tostring(U.last_error))
    end)

    mocks.restore()
end

--==============================================================================
-- 9. Instalador de un solo archivo: PizzaGames.lua descarga todo si no
--    encuentra nada instalado (sin necesitar PizzaGames_Updater.lua, que es
--    justo uno de los archivos que hay que descargar)
--==============================================================================
do
    local mocks = Env.install_mocks()   -- vfs vacío: nada "instalado" todavía

    -- Script.RegisterLooped: PizzaGames.lua es el propio script de arranque,
    -- no un módulo "return function(PG)", así que no pasa por
    -- Env.load_updater/load_core y necesita este mock aparte.
    local loops = {}
    _G.Script = {
        RegisterLooped = function(fn) loops[#loops + 1] = fn; return #loops end,
        Yield = function(_) end,
    }

    local order = {
        "PizzaGames_Core.lua", "PizzaGames_Natives.lua", "PizzaGames_Cinema.lua",
        "PizzaGames_Prefabs.lua", "PizzaGames_Scene.lua", "PizzaGames_Games.lua",
        "PizzaGames_Updater.lua", "PizzaGames_Cherax.lua",
    }
    for _, name in ipairs(order) do
        mocks.curl_queue[#mocks.curl_queue + 1] = {
            delay_ticks = 1, code = eCurlCode.CURLE_OK,
            body = Env.read_file(Env.SRC_DIR .. "PizzaScript/" .. name),
        }
    end

    check("PizzaGames.lua descarga los 8 modulos cuando no hay nada instalado", function()
        local chunk, err = Env.compile(Env.SRC_DIR .. "PizzaGames.lua")
        assert(chunk, err)

        -- pcall: más allá de la descarga, finish_boot() intenta instalar en
        -- Cherax (FeatureMgr/ClickGUI/GTA no están simulados aquí, fuera del
        -- alcance de este simulador). El propio adaptador de Core.lua está
        -- pensado para degradarse sin lanzar, pero el pcall es la red de
        -- seguridad: lo único que esta prueba necesita verificar es la
        -- descarga, no el arranque completo dentro de Cherax.
        pcall(chunk)

        for _ = 1, 50 do
            for _, fn in ipairs(loops) do pcall(fn) end
        end

        for _, name in ipairs(order) do
            local expected = Env.read_file(Env.SRC_DIR .. "PizzaScript/" .. name)
            local got = mocks.vfs["C:\\FakeCherax\\Lua\\PizzaScript\\" .. name]
            assert(got == expected, "no se descargó/escribió correctamente: " .. name)
        end
    end)

    _G.Script = nil
    mocks.restore()
end

--==============================================================================
-- 10. PizzaProfile.lua: se autoactualiza (descarga, verifica con load(),
--     respalda la version anterior). Prueba de caja negra igual que la del
--     instalador de PizzaGames: no hay nada expuesto para llamar
--     directamente (es un script suelto, no un modulo "return function"),
--     asi que se ejecuta el archivo completo y se observan los efectos en
--     el vfs simulado.
--==============================================================================
do
    local mocks = Env.install_mocks()

    -- PizzaProfile.lua necesita una superficie minima de Cherax que
    -- sim.lua no mockea por defecto (FeatureMgr/ClickGUI/eFeatureType/
    -- Natives/Script/ImGui): se añade solo para esta prueba.
    local loops = {}
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
    local function fake_feature()
        local f = {}
        function f:SetDefaultValue(_) return f end
        function f:SetSaveable(_) return f end
        function f:Reset() return f end
        function f:IsToggled() return false end
        return f
    end
    local callbacks = {}
    _G.FeatureMgr = {
        AddFeature = function(hash, _name, _ftype, _desc, cb, _thread)
            callbacks[hash] = cb
            return fake_feature()
        end,
        -- Siempre activado a proposito: en esta prueba se quiere que el
        -- toggle "Buscar actualizaciones al iniciar" dispare la comprobacion.
        IsFeatureToggled = function(_hash) return true end,
    }
    _G.ClickGUI = {
        AddTab = function(_name, _fn) end,
        BeginCustomChildWindow = function(_) return false end,
        EndCustomChildWindow = function() end,
        RenderFeature = function(_) end,
    }
    _G.ImGui = { Text = function(_) end }

    local new_content = "-- nueva version de PizzaProfile (prueba)\nreturn true\n"
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK,
        body = '{"version":"9.9.9","notas":"prueba"}',
    }
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK, body = new_content,
    }

    check("PizzaProfile.lua se autoactualiza: descarga, verifica y respalda", function()
        local chunk, err = Env.compile(Env.SRC_DIR .. "PizzaProfile.lua")
        assert(chunk, err)

        local self_path = "C:\\FakeCherax\\Lua\\PizzaProfile.lua"
        mocks.vfs[self_path] = Env.read_file(Env.SRC_DIR .. "PizzaProfile.lua")

        pcall(chunk)   -- registra el bucle (Script.RegisterLooped) y construye la UI

        -- Suficientes ticks para pasar el warmup (arma en 10, comprueba
        -- actualizacion en 15) y que la comprobacion de version.json termine.
        for _ = 1, 20 do
            for _, fn in ipairs(loops) do pcall(fn) end
        end

        local apply_cb = callbacks[Utils.Joaat("PP_ApplyUpdate")]
        assert(apply_cb, "no se registro el boton 'Actualizar ahora'")
        apply_cb()   -- simula pulsar el boton, ahora que hay version disponible

        for _ = 1, 20 do
            for _, fn in ipairs(loops) do pcall(fn) end
        end

        assert(mocks.vfs[self_path] == new_content,
               "PizzaProfile.lua no se sustituyo con el contenido nuevo")
        assert(mocks.vfs[self_path .. ".backup"] ~= nil,
               "no se guardo copia de seguridad de la version anterior")
    end)

    _G.Script, _G.Natives, _G.eFeatureType = nil, nil, nil
    _G.FeatureMgr, _G.ClickGUI, _G.ImGui = nil, nil, nil
    mocks.restore()
end

print(string.format("\n===== %d/%d correctas =====", total - failed, total))
if failed > 0 then os.exit(1) end
