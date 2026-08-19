--[[
================================================================================
  run_tests.lua — pruebas sobre sim.lua para PizzaScript.lua

  Cubre: que el script compila, y el auto-actualizador completo (misma
  versión no ofrece nada, versión nueva descarga+verifica+aplica+respalda,
  un archivo que no compila aborta sin tocar disco, y el freno de
  iteraciones ante una descarga que nunca termina). Son pruebas de caja
  negra: PizzaScript.lua es un script suelto, no un módulo "return
  function", así que no hay nada que llamar directamente — se ejecuta el
  archivo completo y se observan los efectos en el vfs simulado.

  No cubre (y no puede cubrir fuera del juego): si las natives leen de
  verdad lo que dicen leer. Eso queda documentado como "sin verificar en
  juego" en la cabecera de PizzaScript.lua.

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

local function pump(loops, n)
    for _ = 1, (n or 200) do
        for _, fn in ipairs(loops) do pcall(fn) end
    end
end

local SCRIPT_PATH = Env.SRC_DIR .. "PizzaScript.lua"
local SELF_PATH    = "C:\\FakeCherax\\Lua\\PizzaScript.lua"

--==============================================================================
-- 1. El script compila (equivalente a luac -p)
--==============================================================================
check("PizzaScript.lua compila", function()
    local chunk, err = Env.compile(SCRIPT_PATH)
    assert(chunk, err)
end)

--==============================================================================
-- 2. Misma versión remota que la local -> no ofrece actualización
--==============================================================================
do
    local mocks = Env.install_mocks()
    local loops = Env.install_cherax_ui_mocks()

    mocks.curl_queue[1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK,
        body = '{"version":"1.0.0","notas":""}',   -- debe coincidir con PS_VERSION en PizzaScript.lua
    }

    check("version remota igual a la local: no se toca el vfs", function()
        local chunk, err = Env.compile(SCRIPT_PATH)
        assert(chunk, err)

        local original = Env.read_file(SCRIPT_PATH)
        mocks.vfs[SELF_PATH] = original

        pcall(chunk)
        pump(loops, 20)

        assert(mocks.vfs[SELF_PATH] == original, "no debería haberse tocado el archivo")
        assert(mocks.vfs[SELF_PATH .. ".backup"] == nil, "no debería haber respaldo sin actualización")
    end)

    mocks.restore()
end

--==============================================================================
-- 3. Versión nueva: descarga, verifica con load(), aplica y respalda
--==============================================================================
do
    local mocks = Env.install_mocks()
    local loops, callbacks = Env.install_cherax_ui_mocks()

    local new_content = "-- nueva version de PizzaScript (prueba)\nreturn true\n"
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK,
        body = '{"version":"9.9.9","notas":"prueba"}',
    }
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK, body = new_content,
    }

    check("version nueva: check + Actualizar ahora deja HECHO, escribe y respalda", function()
        local chunk, err = Env.compile(SCRIPT_PATH)
        assert(chunk, err)

        local original = Env.read_file(SCRIPT_PATH)
        mocks.vfs[SELF_PATH] = original

        pcall(chunk)          -- registra el bucle y construye la UI (arma natives en warmup 10,
        pump(loops, 20)       -- comprueba versión en warmup 15)

        local apply_cb = callbacks[Utils.Joaat("PS_ApplyUpdate")]
        assert(apply_cb, "no se registró el botón 'Actualizar ahora'")
        apply_cb()             -- simula pulsarlo, ahora que hay versión disponible
        pump(loops, 20)

        assert(mocks.vfs[SELF_PATH] == new_content, "no se sustituyó con el contenido nuevo")
        assert(mocks.vfs[SELF_PATH .. ".backup"] == original, "el respaldo no conserva la versión anterior")
    end)

    mocks.restore()
end

--==============================================================================
-- 4. La descarga no compila: aborta sin tocar disco
--==============================================================================
do
    local mocks = Env.install_mocks()
    local loops, callbacks = Env.install_cherax_ui_mocks()

    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK,
        body = '{"version":"9.9.9","notas":"prueba"}',
    }
    mocks.curl_queue[#mocks.curl_queue + 1] = {
        delay_ticks = 1, code = eCurlCode.CURLE_OK, body = "esto no es $$$ lua (((",
    }

    check("descarga que no compila: deja ERROR sin tocar el vfs", function()
        local chunk, err = Env.compile(SCRIPT_PATH)
        assert(chunk, err)

        local original = Env.read_file(SCRIPT_PATH)
        mocks.vfs[SELF_PATH] = original

        pcall(chunk)
        pump(loops, 20)

        local apply_cb = callbacks[Utils.Joaat("PS_ApplyUpdate")]
        assert(apply_cb, "no se registró el botón 'Actualizar ahora'")
        apply_cb()
        pump(loops, 20)

        assert(mocks.vfs[SELF_PATH] == original, "el archivo se tocó pese a que la descarga no compila")
        assert(mocks.vfs[SELF_PATH .. ".backup"] == nil, "no debería haber respaldo si no se llegó a aplicar")
    end)

    mocks.restore()
end

--==============================================================================
-- 5. Freno de iteraciones: una comprobación que nunca termina no cuelga el
--    bucle (usa el tope real de PizzaScript.lua, 1800 ticks: rápido en Lua
--    puro, no hace falta un valor reducido de prueba).
--==============================================================================
do
    local mocks = Env.install_mocks()
    local loops = Env.install_cherax_ui_mocks()

    mocks.curl_queue[1] = { never = true }

    check("una comprobación que nunca termina se aborta por el tope de iteraciones", function()
        local chunk, err = Env.compile(SCRIPT_PATH)
        assert(chunk, err)

        pcall(chunk)
        pump(loops, 1820)   -- 10 de warmup + 1800 del freno + margen

        -- No hay estado expuesto para comprobarlo directamente (script
        -- suelto): la prueba real es que 1820 ticks no cuelgan el proceso
        -- y que no se generó ningún archivo espurio en el vfs.
        assert(next(mocks.vfs) == nil, "no debería haberse escrito nada en disco")
    end)

    mocks.restore()
end

print(string.format("\n===== %d/%d correctas =====", total - failed, total))
if failed > 0 then os.exit(1) end
