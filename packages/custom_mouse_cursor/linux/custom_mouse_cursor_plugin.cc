// ICARUS PATCH: rewritten from upstream 1.1.3's Linux plugin. Every channel
// argument is type-checked before use, decoded images are released, the
// cursors go with the plugin, a cursor registered again under the same name
// replaces the old one, and unknown methods answer not-implemented.

#include "include/custom_mouse_cursor/custom_mouse_cursor_plugin.h"

#include <cmath>
#include <cstring>

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#define CUSTOM_MOUSE_CURSOR_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), custom_mouse_cursor_plugin_get_type(), \
                              CustomMouseCursorPlugin))

struct _CustomMouseCursorPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  // Cursor name to GdkCursor; the table owns both.
  GHashTable* cursors;
};

G_DEFINE_TYPE(CustomMouseCursorPlugin, custom_mouse_cursor_plugin,
              g_object_get_type())

// The value under [key] in the map [args] when it has [type], else nullptr.
static FlValue* lookup(FlValue* args, const gchar* key, FlValueType type) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != type) {
    return nullptr;
  }
  return value;
}

static FlMethodResponse* invalid_arguments(const gchar* message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("invalid_arguments", message, nullptr));
}

// Null tells the Dart side the image could not be turned into a cursor;
// registerCursor() reports that as a descriptive StateError.
static FlMethodResponse* no_cursor() {
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_null()));
}

// The window Flutter draws into, whose cursor the engine also sets for the
// system cursors.
static GdkWindow* flutter_window(CustomMouseCursorPlugin* self) {
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr) {
    return nullptr;
  }
  return gtk_widget_get_window(GTK_WIDGET(view));
}

// args: name (String), buffer (PNG bytes), hotX and hotY (bitmap pixels),
// scale (bitmap pixels per logical pixel). width and height are not needed:
// the PNG carries its own size.
static FlMethodResponse* create_cursor(CustomMouseCursorPlugin* self,
                                       FlValue* args) {
  FlValue* name = lookup(args, "name", FL_VALUE_TYPE_STRING);
  FlValue* buffer = lookup(args, "buffer", FL_VALUE_TYPE_UINT8_LIST);
  FlValue* hot_x = lookup(args, "hotX", FL_VALUE_TYPE_FLOAT);
  FlValue* hot_y = lookup(args, "hotY", FL_VALUE_TYPE_FLOAT);
  if (name == nullptr || buffer == nullptr || hot_x == nullptr ||
      hot_y == nullptr) {
    return invalid_arguments(
        "createCustomCursor needs name, buffer, hotX and hotY.");
  }
  double scale = 1.0;
  FlValue* scale_value = lookup(args, "scale", FL_VALUE_TYPE_FLOAT);
  if (scale_value != nullptr) {
    scale = fl_value_get_float(scale_value);
  }
  if (!std::isfinite(scale) || scale <= 0) {
    return invalid_arguments("scale must be a finite, positive number.");
  }

  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) {
    return no_cursor();
  }

  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  const gboolean written =
      gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(buffer),
                              fl_value_get_length(buffer), nullptr);
  // Closed either way: a loader released open warns.
  const gboolean closed = gdk_pixbuf_loader_close(loader, nullptr);
  // Owned by the loader.
  GdkPixbuf* pixbuf =
      written && closed ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
  if (pixbuf == nullptr) {
    return no_cursor();
  }

  // The bitmap is drawn at the devicePixelRatio. Its device scale makes GDK
  // show it at its logical size, sharp on a scaled display, and the hotspot
  // is given in the same logical units.
  cairo_surface_t* surface =
      gdk_cairo_surface_create_from_pixbuf(pixbuf, 1, nullptr);
  cairo_surface_set_device_scale(surface, scale, scale);
  GdkCursor* cursor = gdk_cursor_new_from_surface(
      display, surface, fl_value_get_float(hot_x) / scale,
      fl_value_get_float(hot_y) / scale);
  cairo_surface_destroy(surface);
  if (cursor == nullptr) {
    return no_cursor();
  }

  // Replaces, and releases, a cursor registered earlier under this name.
  g_hash_table_replace(self->cursors, g_strdup(fl_value_get_string(name)),
                       cursor);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(
      fl_value_new_string(fl_value_get_string(name))));
}

static FlMethodResponse* set_cursor(CustomMouseCursorPlugin* self,
                                    FlValue* args) {
  FlValue* name = lookup(args, "name", FL_VALUE_TYPE_STRING);
  if (name == nullptr) {
    return invalid_arguments("setCustomCursor needs a name.");
  }
  GdkCursor* cursor = static_cast<GdkCursor*>(
      g_hash_table_lookup(self->cursors, fl_value_get_string(name)));
  GdkWindow* window = flutter_window(self);
  if (cursor != nullptr && window != nullptr) {
    gdk_window_set_cursor(window, cursor);
  }
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(cursor != nullptr)));
}

static FlMethodResponse* delete_cursor(CustomMouseCursorPlugin* self,
                                       FlValue* args) {
  FlValue* name = lookup(args, "name", FL_VALUE_TYPE_STRING);
  if (name == nullptr) {
    return invalid_arguments("deleteCustomCursor needs a name.");
  }
  // A window still showing the cursor keeps its own reference to it.
  const gboolean removed =
      g_hash_table_remove(self->cursors, fl_value_get_string(name));
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(removed)));
}

static void handle_method_call(CustomMouseCursorPlugin* self,
                               FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "createCustomCursor") == 0) {
    response = create_cursor(self, args);
  } else if (strcmp(method, "setCustomCursor") == 0) {
    response = set_cursor(self, args);
  } else if (strcmp(method, "deleteCustomCursor") == 0) {
    response = delete_cursor(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void custom_mouse_cursor_plugin_dispose(GObject* object) {
  CustomMouseCursorPlugin* self = CUSTOM_MOUSE_CURSOR_PLUGIN(object);
  g_clear_pointer(&self->cursors, g_hash_table_unref);
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(custom_mouse_cursor_plugin_parent_class)->dispose(object);
}

static void custom_mouse_cursor_plugin_class_init(
    CustomMouseCursorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = custom_mouse_cursor_plugin_dispose;
}

static void custom_mouse_cursor_plugin_init(CustomMouseCursorPlugin* self) {
  self->cursors =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  handle_method_call(CUSTOM_MOUSE_CURSOR_PLUGIN(user_data), method_call);
}

void custom_mouse_cursor_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  CustomMouseCursorPlugin* plugin = CUSTOM_MOUSE_CURSOR_PLUGIN(
      g_object_new(custom_mouse_cursor_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "custom_mouse_cursor",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
