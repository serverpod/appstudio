#include "include/webview_cef/webview_cef_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>
#include <deque>
#include <functional>
#include <unordered_map>
#include <unordered_set>
#include <webview_plugin.h>
#include "webview_cef_keyevent.h"
#include "webview_cef_texture.h"

#define WEBVIEW_CEF_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), webview_cef_plugin_get_type(), \
                              WebviewCefPlugin))

struct _WebviewCefPlugin
{
  GObject parent_instance;
  std::shared_ptr<webview_cef::WebviewPlugin> m_plugin;
  FlTextureRegistrar *m_textureRegister;
  int64_t m_window;
};

G_DEFINE_TYPE(WebviewCefPlugin, webview_cef_plugin, g_object_get_type())

std::unordered_map<int64_t, std::shared_ptr<webview_cef::WebviewPlugin>> webviewPlugins;

// Runs [fn] on GTK's main thread: at once when already on it, otherwise as
// soon as the main loop gets to it.
//
// CEF runs its own message loop thread on Linux (multi_threaded_message_loop),
// so its callbacks — a script's result, a page event — arrive there. Flutter's
// Linux engine takes method channel calls and responses on the main thread
// only; from CEF's thread they were lost, so evaluateJavascript never
// answered and App Studio's preview waited on it forever. Windows does the
// same hop with PostMessage.
static void on_main_thread(std::function<void()> fn)
{
  g_main_context_invoke_full(
      nullptr, G_PRIORITY_DEFAULT,
      [](gpointer data) -> gboolean
      {
        (*static_cast<std::function<void()> *>(data))();
        return G_SOURCE_REMOVE;
      },
      new std::function<void()>(std::move(fn)),
      [](gpointer data)
      { delete static_cast<std::function<void()> *>(data); });
}

class WebviewTextureRenderer : public webview_cef::WebviewTexture
{
public:
  WebviewTextureRenderer(FlTextureRegistrar *texture_register)
  {
    register_ = texture_register;
    texture = webview_cef_texture_new();
    fl_texture_registrar_register_texture(register_, FL_TEXTURE(texture));
    textureId = (int64_t)texture;
  }

  // Runs wherever the last reference goes: usually GTK's thread, but CEF's
  // when a close lands while a frame is being copied (the paint holds its
  // own reference). Flutter unregisters textures on GTK's thread, and the
  // texture's GL cleanup needs its context there, so the work is handed over.
  virtual ~WebviewTextureRenderer()
  {
    FlTextureRegistrar *registrar = register_;
    WebviewCefTexture *texture_to_free = texture;
    on_main_thread([registrar, texture_to_free]() {
      fl_texture_registrar_unregister_texture(registrar,
                                              FL_TEXTURE(texture_to_free));
      // The registrar holds its own reference while registered; this drops
      // ours, so the texture and its buffers are freed once Flutter lets go.
      g_object_unref(texture_to_free);
    });
    register_ = nullptr;
  }

  // Called on CEF's thread. The texture copies the frame under its lock; see
  // webview_cef_texture.h for why it is double-buffered.
  virtual void onFrame(const void *buffer, int32_t width, int32_t height) override
  {
    webview_cef_texture_set_frame(texture, buffer, width, height,
                                  webview_cef::SwapBufferFromBgraToRgba);
    fl_texture_registrar_mark_texture_frame_available(register_, FL_TEXTURE(texture));
  }
  FlTextureRegistrar *register_;
  WebviewCefTexture *texture;
};

static FlValue *encode_wavlue_to_flvalue(WValue *args)
{
  WValueType type = webview_value_get_type(args);
  switch (type)
  {
  case Webview_Value_Type_Bool:
    return fl_value_new_bool(webview_value_get_bool(args));
  case Webview_Value_Type_Int:
    return fl_value_new_int(webview_value_get_int(args));
  case Webview_Value_Type_Float:
    return fl_value_new_float(webview_value_get_float(args));
  case Webview_Value_Type_Double:
    return fl_value_new_float(webview_value_get_double(args));
  case Webview_Value_Type_String:
    return fl_value_new_string(webview_value_get_string(args));
  case Webview_Value_Type_Uint8_List:
  {
    size_t len = webview_value_get_len(args);
    const uint8_t *val = webview_value_get_uint8_list(args);
    return fl_value_new_uint8_list(val, len);
  }
  case Webview_Value_Type_Int32_List:
  {
    size_t len = webview_value_get_len(args);
    const int32_t *val = webview_value_get_int32_list(args);
    return fl_value_new_int32_list(val, len);
  }
  case Webview_Value_Type_Int64_List:
  {
    size_t len = webview_value_get_len(args);
    const int64_t *val = webview_value_get_int64_list(args);
    return fl_value_new_int64_list(val, len);
  }
  case Webview_Value_Type_Float_List:
  {
    size_t len = webview_value_get_len(args);
    const float *val = webview_value_get_float_list(args);
    return fl_value_new_float32_list(val, len);
  }
  case Webview_Value_Type_Double_List:
  {
    size_t len = webview_value_get_len(args);
    const double *val = webview_value_get_double_list(args);
    return fl_value_new_float_list(val, len);
  }
  case Webview_Value_Type_List:
  {
    FlValue *ret = fl_value_new_list();
    size_t len = webview_value_get_len(args);
    for (size_t i = 0; i < len; i++)
    {
      FlValue *val = encode_wavlue_to_flvalue(webview_value_get_list_value(args, i));
      fl_value_append(ret, val);
      fl_value_unref(val);
    }
    return ret;
  }
  case Webview_Value_Type_Map:
  {
    FlValue *ret = fl_value_new_map();
    size_t len = webview_value_get_len(args);
    for (size_t i = 0; i < len; i++)
    {
      FlValue *key = encode_wavlue_to_flvalue(webview_value_get_key(args, i));
      FlValue *val = encode_wavlue_to_flvalue(webview_value_get_value(args, i));
      fl_value_set(ret, key, val);
      fl_value_unref(key);
      fl_value_unref(val);
    }
    return ret;
  }
  default:
    return fl_value_new_null();
  }
}

static WValue *encode_flvalue_to_wvalue(FlValue *args)
{
  FlValueType argsType = fl_value_get_type(args);
  switch (argsType)
  {
  case FL_VALUE_TYPE_BOOL:
    return webview_value_new_bool(fl_value_get_bool(args));
  case FL_VALUE_TYPE_INT:
    return webview_value_new_int(fl_value_get_int(args));
  case FL_VALUE_TYPE_FLOAT:
    return webview_value_new_double(fl_value_get_float(args));
  case FL_VALUE_TYPE_STRING:
    return webview_value_new_string(fl_value_get_string(args));
  case FL_VALUE_TYPE_UINT8_LIST:
  {
    size_t len = fl_value_get_length(args);
    const uint8_t *val = fl_value_get_uint8_list(args);
    return webview_value_new_uint8_list(val, len);
  }
  case FL_VALUE_TYPE_INT32_LIST:
  {
    size_t len = fl_value_get_length(args);
    const int32_t *val = fl_value_get_int32_list(args);
    return webview_value_new_int32_list(val, len);
  }
  case FL_VALUE_TYPE_INT64_LIST:
  {
    size_t len = fl_value_get_length(args);
    const int64_t *val = fl_value_get_int64_list(args);
    return webview_value_new_int64_list(val, len);
  }
  case FL_VALUE_TYPE_FLOAT32_LIST:
  {
    size_t len = fl_value_get_length(args);
    const float *val = fl_value_get_float32_list(args);
    return webview_value_new_float_list(val, len);
  }
  case FL_VALUE_TYPE_FLOAT_LIST:
  {
    size_t len = fl_value_get_length(args);
    const double *val = fl_value_get_float_list(args);
    return webview_value_new_double_list(val, len);
  }
  case FL_VALUE_TYPE_LIST:
  {
    WValue *ret = webview_value_new_list();
    size_t len = fl_value_get_length(args);
    for (size_t i = 0; i < len; i++)
    {
      WValue *item = encode_flvalue_to_wvalue(fl_value_get_list_value(args, i));
      webview_value_append(ret, item);
      webview_value_unref(item);
    }
    return ret;
  }
  case FL_VALUE_TYPE_MAP:
  {
    WValue *ret = webview_value_new_map();
    size_t len = fl_value_get_length(args);
    for (size_t i = 0; i < len; i++)
    {
      WValue *key = encode_flvalue_to_wvalue(fl_value_get_map_key(args, i));
      WValue *val = encode_flvalue_to_wvalue(fl_value_get_map_value(args, i));
      webview_value_set(ret, key, val);
      webview_value_unref(key);
      webview_value_unref(val);
    }
    return ret;
  }
  default:
    return webview_value_new_null();
  }
}

// Called when a method call is received from Flutter.
static void webview_cef_plugin_handle_method_call(
    WebviewCefPlugin *self,
    FlMethodCall *method_call)
{
  const gchar *method = fl_method_call_get_name(method_call);
  WValue *encodeArgs = encode_flvalue_to_wvalue(fl_method_call_get_args(method_call));
  g_object_ref(method_call);
  self->m_plugin->HandleMethodCall(method, encodeArgs, [=](int ret, WValue *responseArgs){
    // Encoded here, on whichever thread answers: responseArgs belongs to the
    // caller and is gone once this returns.
    FlValue *response =
        ret == 0 ? nullptr : encode_wavlue_to_flvalue(responseArgs);
    on_main_thread([=]() {
      if (ret > 0){
        fl_method_call_respond_success(method_call, response, nullptr);
      }
      else if (ret < 0){
        fl_method_call_respond_error(method_call, "error", "error", response, nullptr);
      }
      else{
        fl_method_call_respond_not_implemented(method_call, nullptr);
      }
      if (response != nullptr){
        fl_value_unref(response);
      }
      g_object_unref(method_call);
    });
  });
  webview_value_unref(encodeArgs);
}

static void webview_cef_plugin_dispose(GObject *object)
{
  webviewPlugins.erase(WEBVIEW_CEF_PLUGIN(object)->m_window);
  WEBVIEW_CEF_PLUGIN(object)->m_plugin = nullptr; 
  if(webviewPlugins.empty()){
    webview_cef::stopCEF();
  }
  G_OBJECT_CLASS(webview_cef_plugin_parent_class)->dispose(object);
}

static void webview_cef_plugin_class_init(WebviewCefPluginClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = webview_cef_plugin_dispose;
}

static void webview_cef_plugin_init(WebviewCefPlugin *self) {
  self->m_plugin = std::make_shared<webview_cef::WebviewPlugin>();
}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data)
{
  WebviewCefPlugin *plugin = WEBVIEW_CEF_PLUGIN(user_data);
  webview_cef_plugin_handle_method_call(plugin, method_call);
}

void webview_cef_plugin_register_with_registrar(FlPluginRegistrar *registrar)
{
  WebviewCefPlugin *plugin = WEBVIEW_CEF_PLUGIN(
      g_object_new(webview_cef_plugin_get_type(), nullptr));

  plugin->m_window = int64_t(fl_plugin_registrar_get_view(registrar));
  webviewPlugins.emplace(plugin->m_window, plugin->m_plugin);

  plugin->m_textureRegister = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "webview_cef",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  // Kept for the plugin's lifetime: events are sent on it long after this
  // function's g_autoptr has dropped its own reference.
  FlMethodChannel *events = FL_METHOD_CHANNEL(g_object_ref(channel));
  plugin->m_plugin->setInvokeMethodFunc([=](std::string method, WValue *arguments) {
    FlValue *args = encode_wavlue_to_flvalue(arguments);
    on_main_thread([=]() {
      fl_method_channel_invoke_method(events, method.c_str(), args, NULL, NULL, NULL);
      fl_value_unref(args);
    });
  });

  plugin->m_plugin->setCreateTextureFunc([=](){
    std::shared_ptr<WebviewTextureRenderer> renderer = std::make_shared<WebviewTextureRenderer>(plugin->m_textureRegister);
    return std::dynamic_pointer_cast<webview_cef::WebviewTexture>(renderer);
  });

  g_object_unref(plugin);
}

FLUTTER_PLUGIN_EXPORT int initCEFProcesses(int argc, char **argv)
{
  CefMainArgs main_args(argc, argv);
  return webview_cef::initCEFProcesses(main_args);
}

// [text] as a std::wstring, or false when it is not valid UTF-8. wchar_t is
// UTF-32 on Linux, which is what g_utf8_to_ucs4 produces.
static bool utf8_to_wstring(const char *text, std::wstring &out)
{
  glong length = 0;
  gunichar *wide = g_utf8_to_ucs4(text, -1, nullptr, &length, nullptr);
  if (wide == nullptr)
  {
    return false;
  }
  out.clear();
  out.reserve(length);
  for (glong i = 0; i < length; i++)
  {
    out.push_back(static_cast<wchar_t>(wide[i]));
  }
  g_free(wide);
  return true;
}

FLUTTER_PLUGIN_EXPORT void setCEFRootCachePath(const char *path)
{
  if (path == nullptr)
  {
    webview_cef::setRootCachePath(std::wstring());
    return;
  }
  std::wstring root;
  if (!utf8_to_wstring(path, root))
  {
    g_warning("CEF cache folder is not valid UTF-8, using CEF's default: %s",
              path);
    return;
  }
  webview_cef::setRootCachePath(root);
}

// Hardware keycodes whose press went to the app rather than the page, so
// their release goes there too: a key Flutter saw go down must also be seen
// to come up, or it stays pressed in Flutter's HardwareKeyboard.
static std::unordered_set<guint16> appOwnedKeys;

// Keys whose press the plugin handled itself (paste), so their release is
// swallowed too: the page must not see a key come up that never went down.
static std::unordered_set<guint16> pluginOwnedKeys;

// Keys are classified by their Windows key code, as Chromium does, not by
// the layout's keyval. It follows the physical key on layouts without Latin
// letters, where Ctrl+C arrives as Ctrl+Cyrillic_es, and it leaves out the
// keys GDK still gives a character (Backspace, Tab, Enter, Escape, Delete).

// A letter, digit or punctuation key.
static bool isCharacterKey(KeyboardCode code)
{
  return (code >= VKEY_0 && code <= VKEY_9) ||
         (code >= VKEY_A && code <= VKEY_Z) ||
         (code >= VKEY_OEM_1 && code <= VKEY_OEM_3) ||
         (code >= VKEY_OEM_4 && code <= VKEY_OEM_8) ||
         code == VKEY_OEM_102;
}

// Whether [event] is one of the app's own shortcuts: Ctrl on a character key.
// Ctrl+A/C/V/X/Y/Z stay with the page — they are its editing keys — and so
// does Ctrl on any other key (arrows, Backspace, Enter, Tab), which a page
// uses for word movement and the like. AltGr characters are not Ctrl.
static bool isAppShortcut(GdkEventKey *event, KeyboardCode code)
{
  if ((event->state & GDK_CONTROL_MASK) == 0 || event->is_modifier ||
      !isCharacterKey(code))
  {
    return false;
  }
  switch (code)
  {
  case VKEY_A:
  case VKEY_C:
  case VKEY_V:
  case VKEY_X:
  case VKEY_Y:
  case VKEY_Z:
    return false;
  default:
    return true;
  }
}

// The clipboard, through GTK.
//
// On Wayland a client may only set or read the clipboard while one of its
// surfaces has keyboard focus. CEF talks to the compositor over its own
// connection and draws off-screen, so it never has focus: its copies stayed
// inside Chromium ("No serial found for selection") and it never saw what
// other programs copied. GTK's window is the one with focus, so the plugin
// moves the text across itself. Running CEF on X11 through XWayland instead
// was tried: Hyprland does not bridge an unfocused X client's clipboard.
static bool isCopy(GdkEventKey *event, KeyboardCode code)
{
  return (event->state & GDK_CONTROL_MASK) != 0 &&
         (code == VKEY_C || code == VKEY_X || code == VKEY_INSERT);
}

static bool isPaste(GdkEventKey *event, KeyboardCode code)
{
  if ((event->state & GDK_CONTROL_MASK) != 0)
  {
    return code == VKEY_V;
  }
  return (event->state & GDK_SHIFT_MASK) != 0 && code == VKEY_INSERT;
}

// Puts the page's selection on the clipboard. The key itself still goes to
// the page, which copies or cuts as usual; Chromium reports the selection as
// it changes, so it is current when the key arrives.
static void copySelectionToClipboard(webview_cef::WebviewPlugin *plugin)
{
  const std::string text = plugin->focusedSelectedText();
  if (!text.empty())
  {
    gtk_clipboard_set_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),
                           text.c_str(), static_cast<gint>(text.size()));
  }
}

// Inserts the clipboard's text into the focused page, the way an input
// method commits text. The page sees typing rather than a paste event, which
// is what a text field needs; a page that reads paste events (an image, rich
// text) gets nothing.
static void pasteClipboardIntoPage(int64_t id)
{
  gtk_clipboard_request_text(
      gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),
      [](GtkClipboard *, const gchar *text, gpointer data)
      {
        if (text == nullptr || text[0] == '\0')
        {
          return;
        }
        // Looked up again: the clipboard answers later, on the main loop.
        auto it = webviewPlugins.find(reinterpret_cast<int64_t>(data));
        std::wstring wide;
        if (it != webviewPlugins.end() && utf8_to_wstring(text, wide))
        {
          it->second->imeCommitTextNative(wide);
        }
      },
      reinterpret_cast<gpointer>(id));
}

// The modifier flag a modifier key sets. GDK reports the state from before
// the event, so Ctrl's own press arrived without Ctrl down and its release
// with it, and the page's keyboard handling (Flutter web asserts on it) saw a
// modifier go down that its flags said was not.
static int modifierFlagOf(guint keyval)
{
  switch (keyval)
  {
  case GDK_KEY_Control_L:
  case GDK_KEY_Control_R:
    return EVENTFLAG_CONTROL_DOWN;
  case GDK_KEY_Shift_L:
  case GDK_KEY_Shift_R:
    return EVENTFLAG_SHIFT_DOWN;
  case GDK_KEY_Alt_L:
  case GDK_KEY_Alt_R:
  case GDK_KEY_Meta_L:
  case GDK_KEY_Meta_R:
    return EVENTFLAG_ALT_DOWN;
  default:
    return 0;
  }
}

// Events handed on to Flutter, so they are recognised when they come back.
//
// A key the framework does not handle, Flutter puts back into GTK
// (gdk_event_put in fl_view.cc), and it reaches this handler a second time.
// It must not be forwarded to the page again: modifiers would arrive twice,
// and a shortcut key's release, already taken out of appOwnedKeys, would
// reach the page without its press. A handled event never comes back, so
// the list is bounded and the oldest entry goes.
struct PassedKey
{
  guint32 time;
  guint16 keycode;
  GdkEventType type;
};
static std::deque<PassedKey> passedToFlutter;
static constexpr size_t kMaxPassedToFlutter = 32;

static gboolean passToFlutter(GdkEventKey *event)
{
  if (passedToFlutter.size() == kMaxPassedToFlutter)
  {
    passedToFlutter.pop_front();
  }
  passedToFlutter.push_back({event->time, event->hardware_keycode, event->type});
  return FALSE;
}

// Whether [event] is one Flutter has put back; it is forgotten either way.
static bool isComingBack(GdkEventKey *event)
{
  for (auto it = passedToFlutter.begin(); it != passedToFlutter.end(); ++it)
  {
    if (it->time == event->time && it->keycode == event->hardware_keycode &&
        it->type == event->type)
    {
      passedToFlutter.erase(it);
      return true;
    }
  }
  return false;
}

// Hands a key to the focused page, or leaves it to Flutter.
//
// Returns TRUE when the page alone takes the key. With no page focused,
// everything is Flutter's. With one focused, the app keeps its shortcuts
// (isAppShortcut) — they used to be swallowed, so Ctrl+R did nothing while
// the preview had focus — and modifier keys go to both, so Flutter knows
// Ctrl is down when the shortcut's key arrives.
FLUTTER_PLUGIN_EXPORT gboolean processKeyEventForCEF(GtkWidget *widget, GdkEventKey *event, gpointer data)
{
  if (isComingBack(event))
  {
    return FALSE;
  }
  if (event->type == GDK_KEY_PRESS)
  {
    // A press starts the key over: its last release may have gone to
    // another window (a dialog this key opened) and never reached us.
    appOwnedKeys.erase(event->hardware_keycode);
    pluginOwnedKeys.erase(event->hardware_keycode);
  }
  else if (appOwnedKeys.erase(event->hardware_keycode) > 0)
  {
    return passToFlutter(event);
  }
  else if (pluginOwnedKeys.erase(event->hardware_keycode) > 0)
  {
    return TRUE;
  }
  int64_t _id = int64_t(widget);
  if (webviewPlugins.find(_id) != webviewPlugins.end() && webviewPlugins[_id]->getAnyBrowserFocused())
  {
    KeyboardCode windows_key_code = GdkEventToWindowsKeyCode(event);
    if (event->type == GDK_KEY_PRESS && isAppShortcut(event, windows_key_code))
    {
      appOwnedKeys.insert(event->hardware_keycode);
      return passToFlutter(event);
    }
    if (event->type == GDK_KEY_PRESS && isPaste(event, windows_key_code))
    {
      // Not forwarded: Chromium would paste its own, stale copy as well.
      pluginOwnedKeys.insert(event->hardware_keycode);
      pasteClipboardIntoPage(_id);
      return TRUE;
    }
    if (event->type == GDK_KEY_PRESS && isCopy(event, windows_key_code))
    {
      copySelectionToClipboard(webviewPlugins[_id].get());
    }
    CefKeyEvent key_event;
    key_event.windows_key_code =
        GetWindowsKeyCodeWithoutLocation(windows_key_code);
    key_event.native_key_code = event->hardware_keycode;

    key_event.modifiers = GetCefStateModifiers(event->state);
    if (event->type == GDK_KEY_PRESS)
    {
      key_event.modifiers |= modifierFlagOf(event->keyval);
    }
    else
    {
      key_event.modifiers &= ~modifierFlagOf(event->keyval);
    }
    if (event->keyval >= GDK_KP_Space && event->keyval <= GDK_KP_9)
    {
      key_event.modifiers |= EVENTFLAG_IS_KEY_PAD;
    }
    if (key_event.modifiers & EVENTFLAG_ALT_DOWN)
    {
      key_event.is_system_key = true;
    }

    if (windows_key_code == VKEY_RETURN)
    {
      // We need to treat the enter key as a key press of character \r.  This
      // is apparently just how webkit handles it and what it expects.
      key_event.unmodified_character = '\r';
    }
    else {
      // FIXME: fix for non BMP chars
      key_event.unmodified_character =
          static_cast<int>(gdk_keyval_to_unicode(event->keyval));
    }

    // If ctrl key is pressed down, then control character shall be input.
    if (key_event.modifiers & EVENTFLAG_CONTROL_DOWN)
    {
      key_event.character = GetControlCharacter(
          windows_key_code, key_event.modifiers & EVENTFLAG_SHIFT_DOWN);
    }
    else
    {
      key_event.character = key_event.unmodified_character;
    }
    if (event->type == GDK_KEY_PRESS)
    {
      key_event.type = KEYEVENT_RAWKEYDOWN;
      webviewPlugins[_id]->sendKeyEvent(key_event);
      key_event.type = KEYEVENT_CHAR;
    }
    else
    {
      key_event.type = KEYEVENT_KEYUP;
    }
    webviewPlugins[_id]->sendKeyEvent(key_event);

    // Modifiers go to Flutter too: its shortcuts read Ctrl and Shift from
    // its own keyboard state.
    return event->is_modifier ? passToFlutter(event) : TRUE;
  }
  // processKeyEventForFlutter need return FALSE
  return passToFlutter(event);
}
