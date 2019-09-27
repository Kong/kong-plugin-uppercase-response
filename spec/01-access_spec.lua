local helpers = require "spec.helpers"
local cjson = require "cjson"

--
-- Our mock server adds an entry which uses escaped json characters:
--
-- { ...
--   "binary_remote_addr": \u007f\u0000\u0000\u0001"
-- }
--
-- This is problematic because our plugin uppercases every character it "sees".
-- For Lua those escaped characters are two characters: the backslash followed by lowercase u.
--
-- So the response get transformed into:
-- { ...
--   "BINARY_REMOTE_ADDR": \U007f\U0000\U0000\U0001"
-- }
--
-- Unfortunately \U (with uppercase) is not a valid escape sequence in JSON, and cjson will
-- throw an error if it sees that. So we must undo this particular uppercase in order to
-- parse the generated json
local function lowercase_escape_sequences(str)
  return (str:gsub("\\U", "\\u"))
end


for _, strategy in helpers.each_strategy() do
  describe("Plugin: uppercase-response (body_filter) [#" .. strategy .. "]", function()
    local proxy_client

    setup(function()
      local bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, { "uppercase-response" })

      local service = bp.services:insert {
        host = helpers.mock_upstream_host,
        port = helpers.mock_upstream_port,
        protocol = helpers.mock_upstream_protocol,
      }

      bp.routes:insert {
        protocols = { "http" },
        hosts = { "service.test" },
        service = { id = service.id },
      }

      bp.plugins:insert {
        name = "uppercase-response",
        service = { id = service.id },
      }

      assert(helpers.start_kong {
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled,uppercase-response",
      })
      proxy_client = helpers.proxy_client()
    end)

    teardown(function()
      if proxy_client then
        proxy_client:close()
      end

      helpers.stop_kong()
    end)

    it("sends data immediately after a request", function()
      local res = proxy_client:post("/status/200", {
        headers = {
          host = "service.test",
          ["Content-Type"] = "application/json",
        },
        body = { foo = "bar", baz = "cux" }
      })
      local body = assert.res_status(200, res)
      local json = cjson.decode(lowercase_escape_sequences(body))
      assert.same({ FOO = "BAR", BAZ = "CUX" }, json.POST_DATA.PARAMS)
    end)
  end)
end
