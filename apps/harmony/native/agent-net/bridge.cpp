#include <napi/native_api.h>
#include "cindy_agent_net.h"

#include <memory>
#include <string>
#include <vector>

namespace {
constexpr size_t MAX_CREATE_BYTES = 128 * 1024;
constexpr size_t MAX_COMMAND_BYTES = 2 * 1024 * 1024;
constexpr napi_type_tag ENGINE_TAG{0x2935a77b42079781, 0xb2121d89f206c179};

struct Engine {
    CindyAgentNetEngine *handle;
    ~Engine() { close(); }

    void close()
    {
        if (!handle) return;
        cindy_agent_net_destroy(handle);
        handle = nullptr;
    }
};

napi_value fail(napi_env env, const char *code)
{
    napi_throw_error(env, code, code);
    return nullptr;
}

bool readInput(napi_env env, napi_value value, size_t limit, std::vector<uint8_t> &buffer)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > limit) return false;
    buffer.resize(length + 1);
    return napi_get_value_string_utf8(env, value, reinterpret_cast<char *>(buffer.data()), buffer.size(), &length)
        == napi_ok;
}

Engine *readEngine(napi_env env, napi_value value)
{
    bool tagged = false;
    void *data = nullptr;
    if (napi_check_object_type_tag(env, value, &ENGINE_TAG, &tagged) != napi_ok || !tagged
        || napi_unwrap(env, value, &data) != napi_ok) return nullptr;
    return static_cast<Engine *>(data);
}

napi_value create(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    std::vector<uint8_t> input;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok
        || argc != 1 || !readInput(env, args[0], MAX_CREATE_BYTES, input)) {
        return fail(env, "AGENT_NET_INVALID_OPTIONS");
    }
    auto handle = cindy_agent_net_create(input.data(), input.size() - 1);
    // Options contain a private seed. Do not leave an additional plaintext copy in the bridge.
    for (volatile uint8_t &byte : input) byte = 0;
    if (!handle) return fail(env, "AGENT_NET_CREATE_FAILED");
    auto engine = std::unique_ptr<Engine>(new Engine{handle});
    napi_value object;
    if (napi_create_object(env, &object) != napi_ok
        || napi_type_tag_object(env, object, &ENGINE_TAG) != napi_ok
        || napi_wrap(env, object, engine.get(), [](napi_env, void *data, void *) {
            delete static_cast<Engine *>(data);
        }, nullptr, nullptr) != napi_ok) return fail(env, "AGENT_NET_CREATE_FAILED");
    engine.release();
    return object;
}

napi_value command(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2];
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        return fail(env, "AGENT_NET_INVALID_COMMAND");
    }
    Engine *engine = readEngine(env, args[0]);
    if (!engine || !engine->handle) return fail(env, "AGENT_NET_ENGINE_CLOSED");
    std::vector<uint8_t> input;
    if (!readInput(env, args[1], MAX_COMMAND_BYTES, input)) return fail(env, "AGENT_NET_INVALID_COMMAND");
    std::unique_ptr<char, decltype(&cindy_agent_net_free_string)> result(
        cindy_agent_net_command(engine->handle, input.data(), input.size() - 1), cindy_agent_net_free_string);
    napi_value value;
    if (!result || napi_create_string_utf8(env, result.get(), NAPI_AUTO_LENGTH, &value) != napi_ok) {
        return fail(env, "AGENT_NET_COMMAND_FAILED");
    }
    return value;
}

napi_value destroy(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        return fail(env, "AGENT_NET_INVALID_HANDLE");
    }
    Engine *engine = readEngine(env, args[0]);
    if (!engine) return fail(env, "AGENT_NET_INVALID_HANDLE");
    engine->close();
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

napi_value registerExports(napi_env env, napi_value exports)
{
    const napi_property_descriptor properties[] = {
        {"create", nullptr, create, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"command", nullptr, command, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroy", nullptr, destroy, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        return fail(env, "AGENT_NET_INIT_FAILED");
    }
    return exports;
}

napi_module module = {1, 0, nullptr, registerExports, "cindy_agent_net", nullptr, {0}};
} // namespace

extern "C" __attribute__((constructor)) void registerCindyAgentNet()
{
    napi_module_register(&module);
}
