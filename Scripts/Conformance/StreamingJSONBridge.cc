#include <node_api.h>
#include <cstdint>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>
#include "HeapObserver.h"

extern "C" {
void *pi_streaming_json_create(int32_t);
void pi_streaming_json_release(void *);
void pi_streaming_json_append(void *, const uint16_t *, intptr_t);
void *pi_streaming_json_snapshot(void *);
void *pi_streaming_json_result(void *);
void *pi_streaming_json_text(void *);
void pi_streaming_json_replace(void *, const uint16_t *, intptr_t);
void *pi_streaming_json_finish(void *);
intptr_t pi_streaming_json_change_count(void *);
void *pi_streaming_json_change_value(void *, intptr_t);
int32_t pi_streaming_json_change_append(void *, intptr_t);
intptr_t pi_streaming_json_change_path_count(void *, intptr_t);
intptr_t pi_streaming_json_change_path_index(void *, intptr_t, intptr_t);
intptr_t pi_streaming_json_change_path_key(void *, intptr_t, intptr_t, uint16_t *);
intptr_t pi_streaming_json_released(void *, uint64_t *);
uint64_t pi_json_node_id(void *);
int32_t pi_json_node_kind(void *);
void pi_json_node_track_cache(void *);
intptr_t pi_streaming_json_live_nodes(void);
double pi_json_node_number(void *);
void *pi_json_node_prefix(void *);
intptr_t pi_json_node_units(void *, uint16_t *);
intptr_t pi_json_node_count(void *);
void *pi_json_node_child(void *, intptr_t);
intptr_t pi_json_node_key(void *, intptr_t, uint16_t *);
}

static void check(napi_status status) {
  if (status != napi_ok) throw std::runtime_error("Native JSON bridge could not project a value");
}

static napi_value text(napi_env env, const std::vector<uint16_t> &units) {
  napi_value result;
  check(napi_create_string_utf16(env, units.empty() ? u"" : reinterpret_cast<const char16_t *>(units.data()), units.size(), &result));
  return result;
}

static void own(napi_env env, napi_value object, napi_value key, napi_value value) {
  napi_property_descriptor property = {};
  property.name = key;
  property.value = value;
  property.attributes = static_cast<napi_property_attributes>(napi_writable | napi_enumerable | napi_configurable);
  check(napi_define_properties(env, object, 1, &property));
}

struct Handle {
  struct Reference { napi_ref value; bool boxed; };
  napi_env env;
  void *native;
  bool tool;
  uint64_t initialAllocatedBytes = 0;
  napi_ref concat;
  std::unordered_map<uint64_t, Reference> cache;

  Handle(napi_env env, bool tool, bool measure) : env(env), native(nullptr), tool(tool) {
    if (measure) pi_heap_thread_begin();
    native = pi_streaming_json_create(tool);
    if (measure) initialAllocatedBytes = pi_heap_thread_end();
    napi_value global, constructor, prototype, function;
    check(napi_get_global(env, &global));
    check(napi_get_named_property(env, global, "String", &constructor));
    check(napi_get_named_property(env, constructor, "prototype", &prototype));
    check(napi_get_named_property(env, prototype, "concat", &function));
    check(napi_create_reference(env, function, 1, &concat));
  }

  void close() {
    if (!native) return;
    pi_streaming_json_release(native);
    native = nullptr;
    for (const auto &entry : cache) napi_delete_reference(env, entry.second.value);
    cache.clear();
    napi_delete_reference(env, concat);
  }

  ~Handle() { close(); }

  void prune() {
    std::vector<uint64_t> ids(pi_streaming_json_released(native, nullptr));
    if (ids.empty()) return;
    pi_streaming_json_released(native, ids.data());
    for (auto id : ids) {
      auto entry = cache.find(id);
      if (entry == cache.end()) continue;
      check(napi_delete_reference(env, entry->second.value));
      cache.erase(entry);
    }
  }

  napi_value cached(void *node) {
    auto entry = cache.find(pi_json_node_id(node));
    if (entry == cache.end()) return nullptr;
    napi_value value;
    check(napi_get_reference_value(env, entry->second.value, &value));
    if (entry->second.boxed) check(napi_get_named_property(env, value, "value", &value));
    return value;
  }

  void remember(void *node, napi_value value, bool boxed = false) {
    if (boxed) {
      napi_value box;
      check(napi_create_object(env, &box));
      check(napi_set_named_property(env, box, "value", value));
      value = box;
    }
    napi_ref reference;
    check(napi_create_reference(env, value, 1, &reference));
    cache.emplace(pi_json_node_id(node), Reference{reference, boxed});
    pi_json_node_track_cache(node);
  }

  std::pair<napi_value, bool> shallow(void *node, bool root = false) {
    napi_value value;
    if (!node) { check(napi_get_undefined(env, &value)); return {value, false}; }
    int descriptor = pi_json_node_kind(node);
    bool transient = (descriptor & 256) && !root;
    if (!transient) if (auto previous = cached(node)) return {previous, false};
    int kind = descriptor & 255;
    if (kind == 0) check(napi_get_null(env, &value));
    else if (kind == 1) check(napi_get_boolean(env, pi_json_node_number(node) != 0, &value));
    else if (kind == 2) check(napi_create_double(env, pi_json_node_number(node), &value));
    else if (kind == 3) {
      std::vector<void *> parts;
      void *cursor = node;
      while (cursor && !(value = cached(cursor))) {
        parts.push_back(cursor);
        cursor = pi_json_node_prefix(cursor);
      }
      if (!cursor) value = text(env, {});
      napi_value concatenate;
      check(napi_get_reference_value(env, concat, &concatenate));
      for (auto part = parts.rbegin(); part != parts.rend(); ++part) {
        std::vector<uint16_t> units(pi_json_node_units(*part, nullptr));
        pi_json_node_units(*part, units.data());
        napi_value suffix = text(env, units);
        check(napi_call_function(env, value, concatenate, 1, &suffix, &value));
        remember(*part, value, true);
      }
    } else {
      if (kind == 4) check(napi_create_object(env, &value));
      else check(napi_create_array_with_length(env, pi_json_node_count(node), &value));
      if (!transient) remember(node, value);
      return {value, true};
    }
    return {value, false};
  }

  napi_value materialize(void *root) {
    auto initial = shallow(root, true);
    if (!initial.second) return initial.first;
    struct Frame { void *node; napi_value value; intptr_t next; };
    std::vector<Frame> stack{{root, initial.first, 0}};
    while (!stack.empty()) {
      auto &frame = stack.back();
      if (frame.next == pi_json_node_count(frame.node)) { stack.pop_back(); continue; }
      intptr_t index = frame.next++;
      void *child = pi_json_node_child(frame.node, index);
      auto projected = shallow(child);
      if ((pi_json_node_kind(frame.node) & 255) == 5) {
        check(napi_set_element(env, frame.value, index, projected.first));
      } else {
        std::vector<uint16_t> key(pi_json_node_key(frame.node, index, nullptr));
        pi_json_node_key(frame.node, index, key.data());
        own(env, frame.value, text(env, key), projected.first);
      }
      if (projected.second) stack.push_back({child, projected.first, 0});
    }
    return initial.first;
  }

  napi_value changes() {
    napi_value result;
    intptr_t count = pi_streaming_json_change_count(native);
    check(napi_create_array_with_length(env, count, &result));
    for (intptr_t index = 0; index < count; ++index) {
      napi_value change, kind, path;
      bool append = pi_streaming_json_change_append(native, index);
      check(napi_create_object(env, &change));
      check(napi_create_string_utf8(env, append ? "append" : "set", NAPI_AUTO_LENGTH, &kind));
      check(napi_set_named_property(env, change, "kind", kind));
      intptr_t length = pi_streaming_json_change_path_count(native, index);
      check(napi_create_array_with_length(env, length, &path));
      for (intptr_t component = 0; component < length; ++component) {
        intptr_t element = pi_streaming_json_change_path_index(native, index, component);
        napi_value key;
        if (element >= 0) check(napi_create_double(env, element, &key));
        else {
          std::vector<uint16_t> units(pi_streaming_json_change_path_key(native, index, component, nullptr));
          pi_streaming_json_change_path_key(native, index, component, units.data());
          key = text(env, units);
        }
        check(napi_set_element(env, path, component, key));
      }
      check(napi_set_named_property(env, change, "path", path));
      check(napi_set_named_property(env, change, append ? "text" : "value", materialize(pi_streaming_json_change_value(native, index))));
      check(napi_set_element(env, result, index, change));
    }
    return result;
  }
};

static napi_value create(napi_env env, napi_callback_info info) {
  try {
    napi_value arguments[2], result;
    size_t count = 2;
    check(napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr));
    bool tool, measure = false;
    check(napi_get_value_bool(env, arguments[0], &tool));
    if (count > 1) check(napi_get_value_bool(env, arguments[1], &measure));
    auto handle = new Handle(env, tool, measure);
    check(napi_create_external(env, handle, [](napi_env, void *value, void *) { delete static_cast<Handle *>(value); }, nullptr, &result));
    napi_value output, allocated;
    check(napi_create_object(env, &output));
    check(napi_set_named_property(env, output, "value", result));
    check(napi_create_double(env, handle->initialAllocatedBytes, &allocated));
    check(napi_set_named_property(env, output, "allocatedBytes", allocated));
    return output;
  } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

static napi_value liveNodes(napi_env env, napi_callback_info) {
  napi_value result;
  napi_create_double(env, pi_streaming_json_live_nodes(), &result);
  return result;
}

static napi_value dispose(napi_env env, napi_callback_info info) {
  napi_value argument, result;
  size_t count = 1;
  napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr);
  Handle *handle;
  napi_get_value_external(env, argument, reinterpret_cast<void **>(&handle));
  handle->close();
  napi_get_undefined(env, &result);
  return result;
}

enum Operation { Append, Snapshot, Replace, Finish, Text };

static napi_value operation(napi_env env, napi_callback_info info) {
  try {
    napi_value arguments[3];
    size_t count = 3;
    void *data;
    check(napi_get_cb_info(env, info, &count, arguments, nullptr, &data));
    Handle *handle;
    check(napi_get_value_external(env, arguments[0], reinterpret_cast<void **>(&handle)));
    auto op = static_cast<Operation>(reinterpret_cast<intptr_t>(data));
    bool measure = false;
    if (count > 2) check(napi_get_value_bool(env, arguments[2], &measure));
    std::vector<uint16_t> units;
    if (op == Append || op == Replace) {
      size_t length;
      check(napi_get_value_string_utf16(env, arguments[1], nullptr, 0, &length));
      units.resize(length + 1);
      check(napi_get_value_string_utf16(env, arguments[1], reinterpret_cast<char16_t *>(units.data()), units.size(), &length));
      units.resize(length);
    }
    if (measure) pi_heap_thread_begin();
    void *result = nullptr;
    if (op == Append) { pi_streaming_json_append(handle->native, units.data(), units.size()); result = pi_streaming_json_result(handle->native); }
    else if (op == Snapshot) result = pi_streaming_json_snapshot(handle->native);
    else if (op == Replace) { pi_streaming_json_replace(handle->native, units.data(), units.size()); result = pi_streaming_json_result(handle->native); }
    else if (op == Finish) result = pi_streaming_json_finish(handle->native);
    else result = pi_streaming_json_text(handle->native);
    uint64_t bytes = measure ? pi_heap_thread_end() : 0;
    handle->prune();
    napi_value projected = op == Append && !handle->tool ? handle->changes() : handle->materialize(result);
    napi_value output, allocated;
    check(napi_create_object(env, &output));
    check(napi_set_named_property(env, output, "value", projected));
    check(napi_create_double(env, bytes, &allocated));
    check(napi_set_named_property(env, output, "allocatedBytes", allocated));
    return output;
  } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}

NAPI_MODULE_INIT() {
  try {
    if (pi_heap_begin_threaded() != 0) throw std::runtime_error("Native allocation observer is unavailable");
    napi_value constructor;
    check(napi_create_function(env, "create", NAPI_AUTO_LENGTH, create, nullptr, &constructor));
    check(napi_set_named_property(env, exports, "create", constructor));
    napi_value diagnostics;
    check(napi_create_function(env, "liveNodes", NAPI_AUTO_LENGTH, liveNodes, nullptr, &diagnostics));
    check(napi_set_named_property(env, exports, "liveNodes", diagnostics));
    napi_value cleanup;
    check(napi_create_function(env, "dispose", NAPI_AUTO_LENGTH, dispose, nullptr, &cleanup));
    check(napi_set_named_property(env, exports, "dispose", cleanup));
    const char *names[] = {"append", "snapshot", "replace", "finish", "text"};
    for (intptr_t index = 0; index < 5; ++index) {
      napi_value function;
      check(napi_create_function(env, names[index], NAPI_AUTO_LENGTH, operation, reinterpret_cast<void *>(index), &function));
      check(napi_set_named_property(env, exports, names[index], function));
    }
    return exports;
  } catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
}
